#!/usr/bin/env ruby
# frozen_string_literal: true
#
# scenario.rb -- runs all signal modules and weights their -1/0/+1 scores
# into a composite regime reading for the BTC scenario tree:
#
#   composite <= -0.40   FLUSH       (A' active)
#   -0.40 .. -0.10       LEAN-FLUSH
#   -0.10 .. +0.10       NEUTRAL
#   +0.10 .. +0.40       BASE        (B' forming)
#   >= +0.40             RECOVERY    (C' engaging)
#
#   ruby scenario.rb              # table + composite
#   ruby scenario.rb --json       # full machine dump
#   ruby scenario.rb --tmux       # one line -> /tmp/scenario.status
#   ruby scenario.rb --history    # append data/history.jsonl (legacy
#                                 #   ~/.scenario_history.jsonl auto-migrates)
#
# Modules run as subprocesses: a crash/hang in any one degrades it to
# score 0 without breaking the composite. Each module is independently
# runnable for its own detailed view. Weights reflect lead time and
# reliability: flows > positioning/premium/macro > slow on-chain gauges.
# Module stdout discipline: in --json mode a module must print exactly
# one JSON line (this aggregator parses the LAST stdout line; anything
# else degrades that module to score 0).
#
# DATA-INTEGRITY MARKERS (M8-8, additive). A fail-soft module carries
# 'unavailable': true in its --json (BTC::Report.fail_soft, F-12); a
# crashed subprocess is treated the same. That signal rides through to:
#   * --json:  every element of `modules` gains a boolean `unavailable`.
#   * --history: the appended line gains, ONLY when degraded --
#       "blind": true            when every WEIGHTED module is unavailable
#                                (a "blind zero" -- composite 0.0 is data
#                                absence, not a real neutral day; a live
#                                weight-0 module cannot rescue it, owner
#                                ruling 2026-08-18), OR
#       "unavailable": [names]   when some (not all weighted) are down.
#     A fully healthy line grows neither key (old lines stay valid).
# These are markers only; composite math is unchanged (Golden Rule 4).
#
# Ruby >= 2.5, stdlib only.

require 'json'
require 'time'
require_relative '../../lib/btc/env'
require_relative '../../lib/btc/suite'
require_relative '../../lib/btc/report'
require_relative 'common' # M12-2: the --as-of replay seam (Scenario.as_of)

DIR = File.expand_path(__dir__)

MODULES = [
  ['etf_flows',     3],
  ['funding_basis', 2],
  ['cb_premium',    2],
  ['macro',         2],
  ['hash_ribbons',  1],
  ['onchain_value', 1],
  ['stables',       1],
  ['positioning',   0], # M10-3: display-only under shadow-first (D10-b);
                        # weight 0 -- cannot move the composite (Golden Rule 4)
  ['reserves',      0]  # M11-7: exchange reserves, display-only (R-11/D11-a
                        # 2026-08-29); weight 0 -- same shadow-first governance
].freeze

LABELS = {
  'etf_flows' => 'etf', 'funding_basis' => 'fnd', 'cb_premium' => 'cbp',
  'macro' => 'mac', 'hash_ribbons' => 'hsh', 'onchain_value' => 'mvrv',
  'stables' => 'stb', 'positioning' => 'pos', 'reserves' => 'rsv'
}.freeze

# M12-2 (Q-20): under --as-of every module replays the same day (the
# flag passes through; each module's fidelity note is the D12-b table).
# --tmux is refused under replay so a backfill can never clobber the
# live status token; the live history append is likewise guarded below.
abort 'scenario: --tmux is refused under --as-of (replay)' if Scenario.replay? && ARGV.include?('--tmux')
extra = Scenario.replay? ? ['--as-of', Scenario.as_of.strftime('%Y-%m-%d')] : []
# replay day-runs fetch bigger (cached) histories; give modules headroom
mod_timeout = Scenario.replay? ? 120 : 45

results = MODULES.map do |mod, w|
  begin
    r = BTC::Suite.run_module(DIR, mod, mod_timeout, extra)
    { mod: mod, w: w, score: r['score'].to_i, headline: r['headline'].to_s,
      unavailable: r['unavailable'] == true } # M8-8: F-12 fail-soft marker
  rescue StandardError => e
    # A crashed/hung/unparseable subprocess is a live data absence too.
    { mod: mod, w: w, score: 0, headline: "module failed (#{e.class})",
      unavailable: true }
  end
end

wsum      = MODULES.inject(0) { |a, (_, w)| a + w }
composite = results.inject(0.0) { |a, r| a + r[:w] * r[:score] } / wsum

regime = if composite <= -0.40
           'FLUSH'
         elsif composite <= -0.10
           'LEAN-FLUSH'
         elsif composite < 0.10
           'NEUTRAL'
         elsif composite < 0.40
           'BASE'
         else
           'RECOVERY'
         end

ts = Scenario.now_utc

if ARGV.include?('--history') && !Scenario.replay?
  require 'fileutils'
  hist_dir = BTC::Env.data_dir('scenario', File.join(DIR, 'data'))
  FileUtils.mkdir_p(hist_dir)
  hist = File.join(hist_dir, 'history.jsonl')
  # one-time migration from the pre-2026-07 location
  legacy = File.join(ENV['HOME'].to_s, '.scenario_history.jsonl')
  FileUtils.mv(legacy, hist) if File.exist?(legacy) && !File.exist?(hist)
  row = { ts: ts.iso8601, composite: composite.round(3), regime: regime,
          scores: Hash[results.map { |r| [r[:mod], r[:score]] }] }
  # M8-8: mark degraded rows so a data-absence zero is never mistaken for a
  # real neutral day. blind == every WEIGHTED module down (a weight-0
  # display-only module cannot rescue a composite computed from zero live
  # inputs -- owner ruling 2026-08-18, after positioning defeated the
  # marker); unavailable == some down. Mirrored in ops/repair.rb.
  down = results.select { |r| r[:unavailable] }.map { |r| r[:mod] }
  weighted = results.reject { |r| r[:w].zero? }
  if !down.empty? && !weighted.empty? && weighted.all? { |r| r[:unavailable] }
    row[:blind] = true
  elsif !down.empty?
    row[:unavailable] = down
  end
  File.open(hist, 'a') { |f| f.puts JSON.generate(row) }
end

line = format('SCN %s %+.2f %s', regime, composite,
              results.map { |r| "#{LABELS[r[:mod]]}#{format('%+d', r[:score])}" }
                     .join(' '))

if ARGV.include?('--tmux')
  BTC::Report.status('scenario', line)
  exit
end

if ARGV.include?('--json')
  out = { ts: ts.iso8601, composite: composite.round(3),
          regime: regime, modules: results }
  # additive under replay only (the lppl precedent): absent on live runs
  out = { as_of: Scenario.as_of.strftime('%Y-%m-%d') }.merge(out) if Scenario.replay?
  puts JSON.pretty_generate(out)
  exit
end

puts format('%-15s %3s %4s  %s', 'module', 'wt', 'scr', 'headline')
results.each do |r|
  puts format('%-15s %3d %+4d  %s', r[:mod], r[:w], r[:score], r[:headline])
end
puts '-' * 72
puts format('COMPOSITE %+.2f  ->  %s   (%s)', composite, regime,
            ts.strftime('%Y-%m-%d %H:%M UTC'))
