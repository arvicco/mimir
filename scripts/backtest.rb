#!/usr/bin/env ruby
# frozen_string_literal: true
#
# backtest.rb -- CURRENT-vs-PROPOSED signal backtests over the scenario
# history (M12-3, Q-20). The "proposals arrive with a backtest" tool:
# every future Golden-Rule-4 threshold/band proposal attaches this
# script's output instead of arriving as opinion.
#
# USAGE
#   ruby scripts/backtest.rb                          # sanity: PROPOSED = CURRENT
#   ruby scripts/backtest.rb --bands "-0.4,-0.1,0.1,0.4"   # propose regime cutoffs
#   ruby scripts/backtest.rb --json                   # machine form
#
# WHAT IT DOES (v1 scope -- composite-band proposals)
#   Loads the scenario history from BOTH the live evidence trail and the
#   staged backfill (data/scenario_backfill_staging/; organic rows WIN on
#   shared dates -- they are what was actually seen), joins each day's
#   regime band to realized forward BTC log-returns (7/30/90d, the
#   lib/btc/scorecard engine against the lppl price cache), and prints
#   the CURRENT regime bands next to a PROPOSED re-banding of the SAME
#   composites under --bands cutoffs (<=a FLUSH | <=b LEAN-FLUSH |
#   <c NEUTRAL | <d BASE | >=d RECOVERY; current: -0.40/-0.10/0.10/0.40).
#   Rows without a composite are skipped; the provenance line counts
#   organic vs replayed rows so nobody mistakes a backfilled read for an
#   observed one.
#
# EXTENSION PATH (documented, not v1): per-module threshold proposals
# need the module re-run with overrides across the backfill window --
# the --as-of machinery supports it; the override plumbing is a future
# packet. LPPL variants score via scripts/scorecard.rb already.
#
# HONESTY
#   Descriptive only -- no p-values, no verdicts (the engine emits
#   none); n_eff (n / horizon) says how few INDEPENDENT observations an
#   overlapping-window mean really has. Staged rows carry every D12-b
#   fidelity caveat (complete-days windows, cb_premium proxy, revised
#   FRED); the output says so. This script publishes nothing and
#   changes no semantics.

require 'json'
require 'date'
require_relative '../lib/btc/env'
require_relative '../lib/btc/scorecard'
require_relative 'scorecard' # SignalScorecard loaders (band_row, prices, jsonl)
require_relative 'scenario/backfill'

module Backtest
  CURRENT_BANDS = [-0.40, -0.10, 0.10, 0.40].freeze
  REGIMES = %w[FLUSH LEAN-FLUSH NEUTRAL BASE RECOVERY].freeze

  module_function

  def regime_for(composite, bands)
    a, b, c, d = bands
    return 'FLUSH'      if composite <= a
    return 'LEAN-FLUSH' if composite <= b
    return 'NEUTRAL'    if composite < c
    return 'BASE'       if composite < d

    'RECOVERY'
  end

  # live + staged rows -> one row per date with a composite; organic wins
  # on shared dates. Returns [rows({date, composite, replayed}), counts].
  def merged_rows(live_rows, staged_rows)
    by_date = {}
    staged_rows.each do |r|
      next unless r['ts'] && r['composite']

      by_date[r['ts'][0, 10]] = { 'date' => r['ts'][0, 10],
                                  'composite' => r['composite'].to_f,
                                  'replayed' => true }
    end
    live_rows.each do |r|
      next unless r['ts'] && r['composite']

      by_date[r['ts'][0, 10]] = { 'date' => r['ts'][0, 10],
                                  'composite' => r['composite'].to_f,
                                  'replayed' => false }
    end
    rows = by_date.values.sort_by { |r| r['date'] }
    [rows, { organic: rows.count { |r| !r['replayed'] },
             replayed: rows.count { |r| r['replayed'] } }]
  end

  def band_series(rows, bands)
    rows.map { |r| { 'date' => r['date'], 'band' => regime_for(r['composite'], bands) } }
  end

  def run(bands:, lppl_dir:, scenario_dir:, staged_path:, io: $stdout, json: false)
    prices = SignalScorecard.load_prices(File.join(lppl_dir, 'prices.csv'))
    live   = SignalScorecard.load_jsonl(File.join(scenario_dir, 'history.jsonl'))
    staged = SignalScorecard.load_jsonl(staged_path)
    rows, counts = merged_rows(live, staged)
    abort 'backtest: no scenario rows with composites' if rows.empty?

    current  = BTC::Scorecard.score(band_series(rows, CURRENT_BANDS), prices)
    proposed = BTC::Scorecard.score(band_series(rows, bands), prices)

    if json
      io.puts JSON.pretty_generate(
        'rows' => rows.size, 'organic' => counts[:organic], 'replayed' => counts[:replayed],
        'current_bands' => CURRENT_BANDS, 'proposed_bands' => bands,
        'current' => current, 'proposed' => proposed)
      return
    end

    io.puts format('backtest: %d days (%d organic + %d replayed -- D12-b fidelity ' \
                   'caveats apply to replayed rows)', rows.size, counts[:organic], counts[:replayed])
    io.puts format('bands: CURRENT %s | PROPOSED %s%s',
                   CURRENT_BANDS.join('/'), bands.join('/'),
                   bands == CURRENT_BANDS ? ' (sanity run: identical)' : '')
    BTC::Scorecard::HORIZONS.each do |h|
      io.puts format('%dd forward log-return · mean%% (share positive%%) [n]', h)
      io.puts format('  %-11s %-26s %s', 'band', 'CURRENT', 'PROPOSED')
      cc = current[h.to_s]
      pc = proposed[h.to_s]
      unless cc['eligible'] || pc['eligible']
        io.puts format('  -- ineligible (n=%d, %s)', cc['n'], cc['reason'])
        next
      end
      io.puts format('  %-11s %-26s %s', 'ALL', fmt_stats(cc['eligible'] && cc['all']),
                     fmt_stats(pc['eligible'] && pc['all']))
      REGIMES.each do |b|
        cs = cc['eligible'] && (cc['bands'] || {})[b]
        ps = pc['eligible'] && (pc['bands'] || {})[b]
        next unless cs || ps

        io.puts format('  %-11s %-26s %s', b, fmt_stats(cs), fmt_stats(ps))
      end
      io.puts format('  n_eff ~%s independent windows',
                     (cc['eligible'] ? cc['n_eff'] : pc['n_eff']).to_s)
    end
  end

  def fmt_stats(s)
    return '--' unless s

    format('%+0.2f%% (%0.0f%% pos) [%d]', s['mean_pct'], s['pos_pct'], s['n'])
  end

  def parse_bands(argv)
    i = argv.index('--bands')
    return CURRENT_BANDS.dup unless i

    v = argv[i + 1].to_s.split(',').map(&:strip)
    abort 'backtest: --bands wants four ascending cutoffs a,b,c,d' unless
      v.size == 4 && v.all? { |x| x.match?(/\A-?\d+(\.\d+)?\z/) }
    bands = v.map(&:to_f)
    abort 'backtest: --bands cutoffs must ascend' unless bands.each_cons(2).all? { |x, y| x < y }
    bands
  end

  def main
    run(bands: parse_bands(ARGV),
        lppl_dir: BTC::Env.data_dir('lppl', 'scripts/lppl/data'),
        scenario_dir: BTC::Env.data_dir('scenario', 'scripts/scenario/data'),
        staged_path: ScenarioBackfill.staged_history,
        json: ARGV.include?('--json'))
    0
  end
end

exit Backtest.main if $PROGRAM_NAME == __FILE__
