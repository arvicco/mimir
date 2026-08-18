# frozen_string_literal: true

# envelope.rb -- pure builders for the KV envelope wrapped around every
# published value (ARCHITECTURE.md section 4.2) and the v1:index summary
# (section 4.1). No IO, no ENV, no network: the caller injects `now:` and
# `source:` so the output is a deterministic function of its inputs and
# the tests can pin exact literals.
#
# ENVELOPE CONTRACT (FROZEN -- additive only, and only alongside an update
# to test/unit/test_publish_envelope.rb in the same commit):
#
#   { "v": 1, "key": "gex:combined", "generated_at": "2026-07-04T12:00:00Z",
#     "ttl_hint_s": 1800, "source": "novo", "payload": { } }
#
# `key` carries NO "v1:" prefix -- the version lives in `v` and in the KV
# key namespace; the envelope stores the bare artifact key. Hash keys are
# strings so JSON.generate/JSON.parse round-trip identically.
#
# `ttl_hint_s` drives the dashboard staleness badge (owner ruling
# 2026-08-18): age <= ttl -> green, <= 2x ttl -> amber (yellow), <= 3x ttl
# -> orange, else red. Every key ships ttl_hint_s 3600 (the bi-hourly
# publisher re-stamps all of them each tick), so the dot walks one band
# per hour since the last publish. For v1:index the hint is the MIN across
# published keys, so the index reads stale as soon as its freshest-cadence
# member does.
#
# Usage:
#   env = Publish.wrap('gex:combined', payload, 1800,
#                      now: Time.now.utc, source: 'novo')
#   idx = Publish.build_index([env, ...], now: Time.now.utc, source: 'novo')

require 'time'

module Publish
  module_function

  # Wrap a payload in the frozen envelope. Raises ArgumentError on an
  # empty key, nil payload, or non-positive ttl_hint_s. `meta:` is the
  # 2026-07-05 ADDITIVE field (owner design review): a hash of
  # human-facing description strings (desc/axes/help) rendered as hover
  # bubbles by preview.html and the dashboard; only chart envelopes
  # carry it, and the key is absent entirely when meta is nil.
  def wrap(key, payload, ttl_hint_s, now:, source:, meta: nil)
    raise ArgumentError, 'key must not be empty' if key.nil? || key.empty?
    raise ArgumentError, 'payload must not be nil' if payload.nil?
    raise ArgumentError, 'ttl_hint_s must be positive' unless ttl_hint_s.is_a?(Integer) && ttl_hint_s.positive?

    env = {
      'v' => 1,
      'key' => key,
      'generated_at' => now.utc.iso8601,
      'ttl_hint_s' => ttl_hint_s,
      'source' => source,
      'payload' => payload
    }
    env['meta'] = meta if meta
    env
  end

  # Build the v1:index envelope from already-wrapped entries: one row per
  # key (sorted), ttl_hint_s = MIN across entries. Raises ArgumentError on
  # empty entries. +carry+ (2026-07-07 incident fix): last-good rows
  # ({key, generated_at}) for keys SKIPPED this run -- keep-last-good
  # extends to index membership, so a transient upstream outage AGES a
  # key on the dashboard instead of vanishing it. ttl derives from the
  # live entries only.
  def build_index(entries, now:, source:, carry: [])
    raise ArgumentError, 'entries must not be empty' if entries.nil? || entries.empty?

    keys = entries
           .map { |e| { 'key' => e['key'], 'generated_at' => e['generated_at'] } }
           .concat(carry.map { |r| { 'key' => r['key'], 'generated_at' => r['generated_at'] } })
           .sort_by { |row| row['key'] }
    ttl = entries.map { |e| e['ttl_hint_s'] }.min
    wrap('index', { 'keys' => keys }, ttl, now: now, source: source)
  end
end
