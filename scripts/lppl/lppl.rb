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
# The weighted composite is an EVIDENCE INDEX, not a probability: a bounded
# [-1, +1] weighted vote over the tests, read by band, never as "N% chance".
# Verdict bands:
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
#   ruby lppl.rb --as-of DATE  # replay: verdict as of wall-clock day DATE
#                              # (YYYY-MM-DD) from the cache alone; implies
#                              # --skip-update, refuses --tmux, adds as_of
#                              # to --json. Read-only on all cache files.
#
# Module stdout discipline: in --json mode a test must print exactly one
# JSON line (this aggregator parses the LAST stdout line; anything else
# degrades that test to score 0).
#
# DATA-INTEGRITY MARKER (M8-8, additive). A live run on UTC day D expects
# the price cache to carry the close for D-1: prices.rb excludes today's
# incomplete row, and the Coin Metrics reference rate is 24/7 (no weekend
# slack). Both the --history ledger line AND the --json output gain
# "stale_input": true when the cache's newest dated row predates D-1 --
# e.g. an overnight outage left prices.rb unable to fetch, so the cache
# never advanced and the composite is computed from frozen prices.
# Read-only on the cache; the key is omitted on a fresh run, so old ledger
# lines / --json consumers stay valid. M8-9's repair reads the --json
# marker to decide whether a stale ledger tail can be healed same-day.
# Marker only -- the composite/verdict math is unchanged (Golden Rule 4).
#
# OMEGA CROSS-CHECK (M9-3, additive). --json also carries omega_xcheck
# {fit_omega, ls_omega, delta} -- the suite's two independent estimates of the
# oscillation frequency (fit.rb's LPPLS grid vs logperiodic.rb's Lomb-Scargle
# peak) and their gap -- plus trough_stability (fit.rb's projected-trough std
# over recent history, null until enough --history runs accumulate). Additive
# report-only fields; the verdict math is unchanged.
#
# Ruby >= 2.5, stdlib only.

require 'json'
require 'time'
require_relative 'common' # Lppl.as_of / Lppl.now_utc (same regex + abort)
require_relative '../../lib/btc/env'
require_relative '../../lib/btc/suite'
require_relative '../../lib/btc/report'

# Replay clock: parse (and validate) --as-of once. AS_OF is the frozen wall
# clock; ASOF_ARG is passed through to every module subprocess so they see the
# same day. --as-of never coexists with --tmux (would clobber the live token).
AS_OF    = Lppl.as_of
ASOF_ARG = AS_OF ? ['--as-of', AS_OF.strftime('%Y-%m-%d')] : []
if AS_OF && ARGV.include?('--tmux')
  warn 'as-of: --tmux replay is refused (it would clobber the live ' \
       '/tmp/lppl.status token). Use --json or the table.'
  exit 2
end
if AS_OF && ARGV.include?('--history') && !BTC::Env.data_dir_override?
  warn 'as-of: --history replay against the live data dir is refused ' \
       '(it would append backdated ledger entries). Point BTC_DATA_DIR ' \
       'at a staging directory first (see rake lppl:backfill).'
  exit 2
end

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
  BTC::Suite.run_module(DIR, name, timeout, extra)
rescue StandardError => e
  { 'name' => name, 'score' => 0, 'headline' => "module failed (#{e.class})" }
end

# M8-8: newest dated row in the price cache (ISO YYYY-MM-DD), or nil when the
# cache is absent. Read-only; the file is written sorted, but scan defensively.
def price_cache_last_date
  return nil unless File.exist?(Lppl::PRICES)

  last = nil
  File.foreach(Lppl::PRICES) do |ln|
    d = ln[/\A(\d{4}-\d{2}-\d{2})/, 1]
    last = d if d && (last.nil? || d > last)
  end
  last
end

# In as-of mode there is nothing to fetch -- replay works from the cache only,
# so the update is skipped exactly as --skip-update does.
unless ARGV.include?('--skip-update') || AS_OF
  up = run_module('prices', 120)
  warn "prices: #{up['headline']}" if up['headline'].to_s.include?('unavailable')
end

results = TESTS.map do |name, w, to|
  # fit.rb's stability tracker only appends on --history runs; pass the
  # flag through so the daily cron run keeps feeding it. ASOF_ARG threads the
  # replay day into every module.
  extra = name == 'fit' && ARGV.include?('--history') ? ['--history'] : []
  extra += ASOF_ARG
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
ts = Lppl.now_utc

# M8-8: stale_input when the price cache never reached D-1 (see header). Computed
# once so the --history ledger line AND the --json marker agree; M8-9's repair
# reads the --json marker to decide whether a stale ledger tail can be healed.
last_px      = price_cache_last_date
expected_px  = (Time.utc(ts.year, ts.month, ts.day) - 86_400).strftime('%Y-%m-%d')
stale_input  = last_px.nil? || last_px < expected_px

# M9-3 (additive, report-only): the suite estimates the log-periodic angular
# frequency omega TWICE and never surfaced that they agree -- fit.rb's LPPLS
# grid optimum vs logperiodic.rb's Lomb-Scargle peak. Cross-check them so a
# divergence (two methods disagreeing on the oscillation) is visible. And lift
# fit.rb's trough-projection stability (std of the projected trough over recent
# --history runs) to a first-class top-level field. Both are additive markers;
# the composite/verdict math is unchanged (Golden Rule 4).
fit_omega = d['fit']['omega']
ls_omega  = d['logperiodic']['omega_peak']
omega_xcheck = { 'fit_omega' => fit_omega, 'ls_omega' => ls_omega,
                 'delta' => (fit_omega && ls_omega ? (fit_omega - ls_omega).round(2) : nil) }
trough_stability = d['fit']['trough_std_days']

if ARGV.include?('--history')
  require 'fileutils'
  FileUtils.mkdir_p(File.dirname(LEDGER))
  row = {
    ts: ts.iso8601, composite: composite.round(3), verdict: verdict,
    bf: d['trend']['bf'], ratio: d['envelope']['ratio'],
    days_below_strong: d['envelope']['days_below_strong'],
    trough_date: d['fit']['trough_date'], trough_px: d['fit']['trough_px'],
    omega: d['fit']['omega'], p_lp: d['logperiodic']['p_value'],
    z: d['percentile']['z'], pct_emp: d['percentile']['pct_emp'],
    z_record: d['percentile']['record'],
    days_le_p01: d['percentile']['days_le_p01'],
    scores: Hash[results.map { |r| [r[:name], r[:score]] }]
  }
  row[:stale_input] = true if stale_input
  File.open(LEDGER, 'a') { |f| f.puts JSON.generate(row) }
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
  BTC::Report.status('lppl', line)
  exit
end

if ARGV.include?('--json')
  out = { ts: ts.iso8601, composite: composite.round(3),
          verdict: verdict, status_line: line, tests: results,
          omega_xcheck: omega_xcheck,      # M9-3 additive cross-check
          trough_stability: trough_stability } # M9-3 additive (null until history)
  out[:as_of] = AS_OF.strftime('%Y-%m-%d') if AS_OF # additive; absent when live
  out[:stale_input] = true if stale_input # M8-8 additive; absent when fresh
  puts JSON.pretty_generate(out)
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
