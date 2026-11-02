# frozen_string_literal: true
#
# deg_detector.rb -- the leg-degradation detector (M14-2). Per LIVE publish
# run, walks Publish::DegRegistry::DEG_REGISTRY over THIS run's payloads,
# finds degraded legs, counts consecutive degraded runs per key, and names
# the keys that crossed the threshold. Publish::Pipeline appends them to the
# status line as an additive ` DEG:<key>[,<key>...]` marker (after any
# ` OLD:` / ` BLIND:` suffix); ops/publish_health.rb surfaces a bare `DEG`.
#
# WHY: a venue can die INSIDE a still-fresh payload (the incident: two weeks
# of a Deribit-only gex:combined and all-null MSTR vol:spread legs, every
# envelope fresh, every producer exit 0). See deg_registry.rb's header.
#
# Usage (from the pipeline; everything injectable for tests):
#   Publish::DegDetector.run(envelopes, now: now, dry_run: false)
#     # => ['gex:combined', 'vol:spread']   keys at/over the streak threshold
#   Publish::DegDetector.evaluate(state, payloads, now: now)  # pure core
#
# SEMANTICS (owner-blessed 2026-10-12; constants below, do not tune here):
# - A key is evaluated only when it was PUBLISHED this run. An absent key
#   (skipped producer, or an optional:true entry absent by design) is
#   skipped entirely: no streak change, no leg bookkeeping. A skipped
#   producer already shows in the status line's n/m shortfall.
# - missing legs = legs seen within the last WINDOW_DAYS days (last-seen
#   date at most WINDOW_DAYS days before today, UTC) but absent now.
#   dead legs = present now but alive? == false. Degraded this run iff
#   missing + dead is non-empty. A leg unseen for MORE than WINDOW_DAYS
#   falls out of the norm (pruned): a genuinely delisted venue stops
#   alarming after the window.
# - A census that raises (unexpected payload shape) counts as degraded this
#   run; its leg bookkeeping is left untouched.
# - streak += 1 on a degraded run, reset to 0 on a clean run. A key whose
#   streak reaches STREAK_RUNS enters the marker (DEG_REGISTRY order).
# - DRY runs never write or advance state, but they still REPORT keys
#   whose saved streak already tripped (read-only): OLD/BLIND appear on
#   dry runs too, and the one time the owner stares at a PUB! DRY line
#   is exactly when the marker must not go quiet.
#
# STATE FILE: <data>/ops/deg_state.json, where <data> is resolved exactly
# like every other runtime artifact (BTC::Env.data_dir('ops', 'data/ops');
# production sets BTC_DATA_DIR to the data home). Shape:
#   { "v": 1,
#     "keys": { "gex:combined": { "legs": { "Deribit": "2026-10-12", ... },
#                                 "streak": 3 }, ... } }
# Written atomically (tmp + rename). Missing file -> empty state; corrupt
# or wrong-shaped file -> warn (error class only) and start empty.
#
# CAVEATS: the detector never raises into the publish run -- the pipeline
# rescues at the integration point and warns the error class only. Leg
# names are the registry's stable identifiers; renaming one there resets
# that leg's history here.

require 'json'
require 'date'
require 'fileutils'
require_relative 'deg_registry'
require_relative '../lib/btc/env'

module Publish
  module DegDetector
    # Owner-blessed 2026-10-12: a leg unseen for MORE than this many days
    # falls out of the expected set.
    WINDOW_DAYS = 14
    # Owner-blessed 2026-10-12: consecutive degraded LIVE runs before a key
    # enters the DEG marker (6 bi-hourly runs = ~12h).
    STREAK_RUNS = 6

    STATE_VERSION = 1

    module_function

    def state_path
      File.join(BTC::Env.data_dir('ops', 'data/ops'), 'deg_state.json')
    end

    # Integration entry. +envelopes+ = the pipeline's key => envelope map.
    # Returns the marked keys (DEG_REGISTRY order). A DRY run never
    # advances or writes state, but it still REPORTS keys whose saved
    # streak already tripped -- OLD/BLIND show on dry runs, and the
    # marker going quiet exactly during a DRY misconfig would be a lie
    # (review fix on the original packet, 2026-10-12).
    def run(envelopes, now:, dry_run:, path: state_path)
      if dry_run
        saved = load_state(path)['keys'] || {}
        return DegRegistry::DEG_REGISTRY.keys.select do |k|
          saved.dig(k, 'streak').to_i >= STREAK_RUNS
        end
      end

      payloads = envelopes.transform_values { |e| e.is_a?(Hash) ? e['payload'] : nil }
      state, marked = evaluate(load_state(path), payloads, now: now)
      save_state(path, state)
      marked
    end

    # Pure core: (state, key => payload, now) -> [new_state, marked_keys].
    # Never mutates +state+.
    def evaluate(state, payloads, now:)
      today = now.utc.to_date
      keys  = (state['keys'] || {}).transform_values { |v| deep_dup(v) }
      marked = []
      DegRegistry::DEG_REGISTRY.each_key do |key|
        next unless payloads.key?(key) # absent (incl. optional) -> skipped

        ks = keys[key]
        ks = keys[key] = { 'legs' => {}, 'streak' => 0 } unless ks.is_a?(Hash)
        ks['legs'] = {} unless ks['legs'].is_a?(Hash)
        degraded = assess(key, payloads[key], ks['legs'], today)
        ks['streak'] = degraded ? ks['streak'].to_i + 1 : 0
        marked << key if ks['streak'] >= STREAK_RUNS
      end
      [{ 'v' => STATE_VERSION, 'keys' => keys }, marked]
    end

    # Updates +legs+ (name => last-seen ISO date) in place; true iff the key
    # is degraded this run (missing or dead legs, or census raised).
    def assess(key, payload, legs, today)
      census = begin
        DegRegistry.census(key, payload)
      rescue StandardError
        return true # unexpected shape = degraded (registry CAVEATS)
      end
      legs.select! { |_, d| in_window?(d, today) }
      present = census.map(&:first)
      missing = legs.keys - present
      dead    = census.reject { |_, alive| alive }.map(&:first)
      present.each { |n| legs[n] = today.iso8601 }
      !(missing.empty? && dead.empty?)
    end

    # Last-seen date within WINDOW_DAYS of today (inclusive); a bad date
    # falls out of the norm.
    def in_window?(date_s, today)
      (today - Date.iso8601(date_s.to_s)).to_i <= WINDOW_DAYS
    rescue ArgumentError, TypeError
      false
    end

    def load_state(path)
      return {} unless File.file?(path)

      st = JSON.parse(File.read(path))
      raise TypeError, 'state is not an object' unless st.is_a?(Hash) && st.fetch('keys', {}).is_a?(Hash)

      st
    rescue StandardError => e
      warn format('publish: deg state reset (%s)', e.class)
      {}
    end

    def save_state(path, state)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = path + '.tmp'
      File.write(tmp, JSON.pretty_generate(state) + "\n")
      File.rename(tmp, path)
    end

    def deep_dup(obj) = JSON.parse(JSON.generate(obj))
  end
end
