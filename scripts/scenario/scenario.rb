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
# Ruby >= 2.5, stdlib only.

require 'json'
require 'time'
require 'timeout'
require_relative '../../lib/btc/env'

DIR = File.expand_path(__dir__)

MODULES = [
  ['etf_flows',     3],
  ['funding_basis', 2],
  ['cb_premium',    2],
  ['macro',         2],
  ['hash_ribbons',  1],
  ['onchain_value', 1],
  ['stables',       1]
].freeze

LABELS = {
  'etf_flows' => 'etf', 'funding_basis' => 'fnd', 'cb_premium' => 'cbp',
  'macro' => 'mac', 'hash_ribbons' => 'hsh', 'onchain_value' => 'mvrv',
  'stables' => 'stb'
}.freeze

results = MODULES.map do |mod, w|
  begin
    out = nil
    Timeout.timeout(45) do
      out = IO.popen(['ruby', File.join(DIR, "#{mod}.rb"), '--json'], &:read)
    end
    r = JSON.parse(out.to_s.lines.last.to_s)
    { mod: mod, w: w, score: r['score'].to_i, headline: r['headline'].to_s }
  rescue StandardError => e
    { mod: mod, w: w, score: 0, headline: "module failed (#{e.class})" }
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

ts = Time.now.utc

if ARGV.include?('--history')
  require 'fileutils'
  hist_dir = BTC::Env.data_dir('scenario', File.join(DIR, 'data'))
  FileUtils.mkdir_p(hist_dir)
  hist = File.join(hist_dir, 'history.jsonl')
  # one-time migration from the pre-2026-07 location
  legacy = File.join(ENV['HOME'].to_s, '.scenario_history.jsonl')
  FileUtils.mv(legacy, hist) if File.exist?(legacy) && !File.exist?(hist)
  File.open(hist, 'a') do |f|
    f.puts JSON.generate(ts: ts.iso8601, composite: composite.round(3),
                         regime: regime,
                         scores: Hash[results.map { |r| [r[:mod], r[:score]] }])
  end
end

line = format('SCN %s %+.2f %s', regime, composite,
              results.map { |r| "#{LABELS[r[:mod]]}#{format('%+d', r[:score])}" }
                     .join(' '))

if ARGV.include?('--tmux')
  File.write('/tmp/scenario.status', line + "\n")
  exit
end

if ARGV.include?('--json')
  puts JSON.pretty_generate(ts: ts.iso8601, composite: composite.round(3),
                            regime: regime, modules: results)
  exit
end

puts format('%-15s %3s %4s  %s', 'module', 'wt', 'scr', 'headline')
results.each do |r|
  puts format('%-15s %3d %+4d  %s', r[:mod], r[:w], r[:score], r[:headline])
end
puts '-' * 72
puts format('COMPOSITE %+.2f  ->  %s   (%s)', composite, regime,
            ts.strftime('%Y-%m-%d %H:%M UTC'))
