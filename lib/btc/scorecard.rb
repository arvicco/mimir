# frozen_string_literal: true
#
# scorecard.rb -- pure forward-return scoring engine for the signal
# scorecard (P-19 / M10-5). Joins a dated, band-labelled signal series
# against a daily close series and reports, per horizon, how each band
# fared -- descriptive track record only, no significance verdicts.
#
#   prices = { 'YYYY-MM-DD' => close, ... }               # daily closes
#   series = [{ 'date' => 'YYYY-MM-DD', 'band' => 'X' }]  # one row/day
#   BTC::Scorecard.score(series, prices)
#   # => { '7' => { 'n' =>, 'n_eff' =>, 'eligible' => true,
#   #               'all'   => { 'n' =>, 'mean_pct' =>, 'pos_pct' => },
#   #               'bands' => { 'X' => { ... } } },
#   #      '30' => { 'eligible' => false, 'reason' => 'n too small',
#   #                'n' => ... }, ... }
#
# SEMANTICS (owner ruling D10-a, 2026-08-12 -- every point a parameter):
#   join      entry = close(t) for a signal stamped during day t, exit =
#             close(t+h); rows missing either close are skipped, not
#             counted. Signals are computed intraday, closes are end of
#             UTC day, so the entry close postdates the signal (no
#             lookahead).
#   returns   log returns, reported as mean_pct = mean * 100 (~ percent
#             for small moves); pos_pct = share of positive outcomes.
#   verdicts  NONE. No declared per-band direction, no p-values; the
#             benchmark is the same-window unconditional 'all' row and
#             the reader compares bands against it.
#   overlap   daily-sampled h-day returns overlap; n_eff = n/h (1dp)
#             rides every eligible cell so n never overstates evidence.
#   floor     a cell renders stats only when n >= MIN_N and the series
#             spans >= SPAN_FACTOR*h days; otherwise it is explicitly
#             ineligible ('n too small') and carries no stats at all.
#
# CAVEATS
#   One row per date is the caller's contract (loaders dedup to the last
#   record of each day). Output keys are strings (JSON-shaped, like every
#   published payload). Pure: no IO, no clock, deterministic.

require 'date'

module BTC
  module Scorecard
    HORIZONS    = [7, 30, 90].freeze
    MIN_N       = 30
    SPAN_FACTOR = 2

    module_function

    # Log return from close(date) to close(date + h days); nil when
    # either close is missing from the price map.
    def forward_return(prices, date, horizon)
      entry = prices[date]
      exit_ = prices[(Date.iso8601(date) + horizon).iso8601]
      return nil unless entry && exit_

      Math.log(exit_ / entry)
    end

    # Score one band-labelled series against daily closes. See header.
    def score(series, prices, horizons: HORIZONS, min_n: MIN_N,
              span_factor: SPAN_FACTOR)
      dates = series.map { |r| r['date'] }.sort
      span  = dates.empty? ? 0 : (Date.iso8601(dates.last) - Date.iso8601(dates.first)).to_i

      horizons.to_h do |h|
        joined = series.filter_map do |row|
          r = forward_return(prices, row['date'], h)
          [row['band'], r] if r
        end
        [h.to_s, cell(joined, h, span, min_n, span_factor)]
      end
    end

    # One horizon's cell: eligibility gate, then per-band + 'all' stats.
    def cell(joined, horizon, span, min_n, span_factor)
      n = joined.length
      unless n >= min_n && span >= span_factor * horizon
        return { 'n' => n, 'eligible' => false, 'reason' => 'n too small' }
      end

      {
        'n'        => n,
        'n_eff'    => (n / horizon.to_f).round(1),
        'eligible' => true,
        'all'      => stats(joined.map { |_, r| r }),
        'bands'    => joined.group_by { |b, _| b }
                            .sort.to_h { |b, rows| [b, stats(rows.map { |_, r| r })] }
      }
    end

    # n / mean log return as % / share of positive outcomes as %.
    def stats(returns)
      n = returns.length
      {
        'n'        => n,
        'mean_pct' => (returns.sum / n * 100).round(2),
        'pos_pct'  => (returns.count(&:positive?) * 100.0 / n).round(1)
      }
    end
  end
end
