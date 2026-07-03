#!/usr/bin/env ruby
# frozen_string_literal: true
#
# lppl.rb -- LPPL regime evidence aggregator. Updates the price cache, runs
# the four tests, produces a composite verdict, and keeps the evidence
# ledger that accumulates the case over time.
#
#   trend        wt 3   prequential BF: is the global power law the best
#                       out-of-sample description of the trend?
#   envelope     wt 3   is the damped trough envelope holding?
#   fit          wt 2   does a qualified, stable anti-bubble LPPLS fit exist?
#   logperiodic  wt 2   is the oscillation statistically real?
#
# Verdict bands on the weighted composite in [-1, +1]:
#   >= +0.50 REGIME-INTACT | >= +0.15 SUPPORTED | > -0.15 INDETERMINATE
#   > -0.50 STRESSED | else FALSIFIED
# Overrides: trend AND envelope both -1 -> FALSIFIED outright;
#            either one -1 -> verdict capped at STRESSED.
#
#   ruby lppl.rb                # table + verdict
#   ruby lppl.rb --json        # machine dump
#   ruby lppl.rb --tmux        # one line -> /tmp/lppl.status
#   ruby lppl.rb --history     # append data/ledger.jsonl (+ fit history)
#   ruby lppl.rb --skip-update # use cached prices (offline/backtest)
#
# Ruby >= 2.5, stdlib only.

require 'json'
require 'time'
require 'timeout'
require_relative '../../lib/btc/env'

DIR    = File.expand_path(__dir__)
LEDGER = File.join(BTC::Env.data_dir('lppl', File.join(DIR, 'data')),
                   'ledger.jsonl')

TESTS = [
  ['trend',       3, 400],
  ['envelope',    3, 120],
  ['fit',         2, 300],
  ['logperiodic', 2, 300],
  ['percentile',  0, 120] # monitor: reported and ledgered, no verdict weight
].freeze

def run_module(name, timeout, extra = [])
  out = nil
  Timeout.timeout(timeout) do
    out = IO.popen(['ruby', File.join(DIR, "#{name}.rb"), '--json'] + extra, &:read)
  end
  JSON.parse(out.to_s.lines.last.to_s)
rescue StandardError => e
  { 'name' => name, 'score' => 0, 'headline' => "module failed (#{e.class})" }
end

unless ARGV.include?('--skip-update')
  up = run_module('prices', 120)
  warn "prices: #{up['headline']}" if up['headline'].to_s.include?('unavailable')
end

results = TESTS.map do |name, w, to|
  # fit.rb's stability tracker only appends on --history runs; pass the
  # flag through so the daily cron run keeps feeding it.
  extra = name == 'fit' && ARGV.include?('--history') ? ['--history'] : []
  r = run_module(name, to, extra)
  { name: name, w: w, score: r['score'].to_i,
    headline: r['headline'].to_s, detail: r }
end

wsum      = TESTS.inject(0) { |a, (_, w, _)| a + w }
composite = results.inject(0.0) { |a, r| a + r[:w] * r[:score] } / wsum

t_score = results.find { |r| r[:name] == 'trend' }[:score]
e_score = results.find { |r| r[:name] == 'envelope' }[:score]

verdict = if composite >= 0.50
            'REGIME-INTACT'
          elsif composite >= 0.15
            'SUPPORTED'
          elsif composite > -0.15
            'INDETERMINATE'
          elsif composite > -0.50
            'STRESSED'
          else
            'FALSIFIED'
          end
verdict = 'FALSIFIED' if t_score == -1 && e_score == -1
verdict = 'STRESSED' if verdict != 'FALSIFIED' &&
                        (t_score == -1 || e_score == -1) &&
                        %w[REGIME-INTACT SUPPORTED INDETERMINATE].include?(verdict)

d = {}
results.each { |r| d[r[:name]] = r[:detail] }
ts = Time.now.utc

if ARGV.include?('--history')
  require 'fileutils'
  FileUtils.mkdir_p(File.dirname(LEDGER))
  File.open(LEDGER, 'a') do |f|
    f.puts JSON.generate(
      ts: ts.iso8601, composite: composite.round(3), verdict: verdict,
      bf: d['trend']['bf'], ratio: d['envelope']['ratio'],
      days_below_strong: d['envelope']['days_below_strong'],
      trough_date: d['fit']['trough_date'], trough_px: d['fit']['trough_px'],
      omega: d['fit']['omega'], p_lp: d['logperiodic']['p_value'],
      z: d['percentile']['z'], pct_emp: d['percentile']['pct_emp'],
      z_record: d['percentile']['record'],
      days_le_p01: d['percentile']['days_le_p01'],
      scores: Hash[results.map { |r| [r[:name], r[:score]] }]
    )
  end
end

line = format('LPPL %s %+.2f BF%s r%s trough %s/%s w%s p%s Z%s@%s%s',
              verdict, composite,
              d['trend']['bf'] ? format('%+.1f', d['trend']['bf']) : '?',
              d['envelope']['ratio'] ? format('%.2f', d['envelope']['ratio']) : '?',
              d['fit']['trough_date'] || '--',
              d['fit']['trough_px'] ? "#{(d['fit']['trough_px'] / 1000.0).round}k" : '--',
              d['fit']['omega'] ? format('%.1f', d['fit']['omega']) : '?',
              d['logperiodic']['p_value'] ? format('%.2f', d['logperiodic']['p_value']) : '?',
              d['percentile']['z'] ? format('%.1f', d['percentile']['z']) : '?',
              d['percentile']['pct_emp'] ? format('%.1f%%', d['percentile']['pct_emp']) : '?',
              d['percentile']['record'] ? '!' : '')

if ARGV.include?('--tmux')
  File.write('/tmp/lppl.status', line + "\n")
  exit
end

if ARGV.include?('--json')
  puts JSON.pretty_generate(ts: ts.iso8601, composite: composite.round(3),
                            verdict: verdict, status_line: line,
                            tests: results)
  exit
end

puts format('%-13s %3s %4s  %s', 'test', 'wt', 'scr', 'headline')
results.each do |r|
  puts format('%-13s %3d %+4d  %s', r[:name], r[:w], r[:score], r[:headline])
end
puts '-' * 78
puts format('COMPOSITE %+.2f  ->  %s   (%s)', composite, verdict,
            ts.strftime('%Y-%m-%d %H:%M UTC'))
puts line
