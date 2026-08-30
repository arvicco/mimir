#!/usr/bin/env ruby
# frozen_string_literal: true
#
# reserves.rb -- P-8 exchange-reserve module (M11-7). Watches BTC sitting
# on exchanges: coins leaving (self-custody drain) historically precede or
# accompany accumulation; coins piling up are sellable supply overhang.
#
# GOVERNANCE -- this module enters the scenario composite at WEIGHT 0
# (display only). Its score is reported and charted, never weighted, until
# the owner rules on the scorecard (SHADOW-FIRST, Golden Rule 4). The
# semantics below are FIXED by owner ruling R-11 / D11-a (2026-08-29); do
# not tune them without a new ruling.
#
# USAGE
#   ruby reserves.rb            # aligned table (band + delta + total)
#   ruby reserves.rb --json     # one machine line (frozen contract)
#   ruby reserves.rb --history  # append one row per UTC day to
#                               #   <data>/reserves/history.jsonl
#
# SEMANTICS (R-11 / D11-a, FIXED)
#   Source series: Coinglass exchange/balance/chart -- daily per-exchange
#   BTC balances (~676 days x 22 venues at adoption).
#   Signal: the 30-DAY PERCENT CHANGE of AGGREGATE reserves (delta
#   framing, ruled over level -- levels drift with listings and the
#   secular self-custody trend). Window consistency: each 30d delta sums
#   ONLY the exchanges with data at BOTH endpoints of its window, so a
#   venue delisting (nil tail) can never fake a drain.
#   BAND = today's delta placed in the trailing-90-day distribution of
#   the delta series' own history (previous 90 values, EXCLUDING today),
#   cutoffs 80/20 (linear rank, positioning.rb pattern):
#     pct >= 80  BUILDING  (reserves rising unusually fast -> overhang)
#     pct <= 20  DRAINING  (falling unusually fast -> supply drain)
#     else       FLAT
#   SCORE (-1/0/+1, display only): BUILDING -> -1, DRAINING -> +1, else 0.
#   Fewer than 91 trailing deltas => WARMUP, score 0 (not expected live:
#   the source serves ~676 days, so bands are real from day one).
#
# KILL CRITERIA (pre-registered, R-11): this module is REMOVED, not
# tuned, if (a) the source is dead for 14+ consecutive days, or (b) after
# 120 days the signal scorecard shows its score bands do not separate 30d
# forward returns from the unconditional row.
#
# --json ADDITIVE `series` (for v1:chart:positioning -- owner ruling
# 2026-08-29: the reserves history rides the positioning card's OI panel
# on a right axis, not its own card): trailing 365 daily [date, value]
# points of aggregate reserves in M BTC (3dp), summed over the exchanges
# reporting on each date. NOTE this display series is the plain daily
# total, so a venue delisting shows as an honest level step; the SCORE's
# windowed delta is immune to it (above).
#
# DATA SOURCE
#   BTC::Coinglass.exchange_balance_chart (health-registered), routed
#   through SourceCache with a 24h ttl -- at most one API hit per day.
#   Key: ENV['COINGLASS_API_KEY']. Fail-soft: any Coinglass error
#   (TierGated => 'tier-gated') or transport failure reports score 0 with
#   a reason and exits 0 -- a dead API must never break the aggregate.
#
# CAVEATS
#   data_map series are nil-padded for defunct venues (FTX, Bittrex...).
#   Balances arrive numeric; everything is normalized with to_f. The
#   aggregate covers the venues Coinglass tracks, not all custody.

require_relative 'common'
require_relative '../../lib/btc/coinglass'
require_relative '../../lib/btc/env'
require 'json'
require 'time'
require 'fileutils'

module Reserves
  module_function

  NAME    = 'reserves'
  WINDOW  = 90       # trailing daily deltas that define the distribution
  DELTA_D = 30       # the scored delta horizon, days
  TTL     = 86_400   # 24h source-cache freshness -- one API hit per day
  HI, LO  = 80.0, 20.0
  SERIES_TAIL = 365  # trailing daily points published to the card (365
                     # since the 2026-08-29 zoomable-axes ruling; the
                     # source serves ~676 days)

  # Linear rank of `value` among `window` (share strictly below, %).
  def percentile(value, window)
    100.0 * window.count { |v| v < value } / window.size
  end

  # Band today's delta (last element) against the 90 immediately preceding
  # deltas. ['WARMUP', nil, today] below WINDOW+1 values.
  def band_for(deltas)
    today = deltas.last
    return ['WARMUP', nil, today] if deltas.size < WINDOW + 1

    pct = percentile(today, deltas[-(WINDOW + 1)...-1])
    band = if pct >= HI
             'BUILDING'
           elsif pct <= LO
             'DRAINING'
           else
             'FLAT'
           end
    [band, pct, today]
  end

  # BUILDING (fast supply build-up) -> -1; DRAINING (fast drain) -> +1.
  def score(band)
    { 'BUILDING' => -1, 'DRAINING' => 1 }.fetch(band, 0)
  end

  # The 30d-percent-change series of aggregate reserves. For each index i,
  # sums ONLY exchanges with data at BOTH i and i-DELTA_D (window
  # consistency: a delisting never fakes a drain). nil when no venue spans
  # the window or the base sum is zero -- such days are OMITTED.
  def delta_pct_series(chart)
    n   = (chart['time_list'] || []).size
    map = (chart['data_map'] || {}).values
    (DELTA_D...n).filter_map do |i|
      now_sum = base_sum = 0.0
      any = false
      map.each do |series|
        a = series[i]
        b = series[i - DELTA_D]
        next if a.nil? || b.nil?

        now_sum  += a.to_f
        base_sum += b.to_f
        any = true
      end
      (now_sum - base_sum) / base_sum * 100.0 if any && base_sum.positive?
    end
  end

  # Aggregate daily total in M BTC over the venues reporting that day, as
  # trailing-SERIES_TAIL [date, value] pairs for the card. A day where no
  # venue reports is omitted (a gap, never a zero).
  def total_series(chart)
    times = chart['time_list'] || []
    map   = (chart['data_map'] || {}).values
    times.each_index.filter_map do |i|
      vals = map.filter_map { |s| s[i] }
      next if vals.empty?

      date = Time.at(times[i].to_i / 1000).utc.strftime('%Y-%m-%d')
      [date, (vals.sum(&:to_f) / 1e6).round(3)]
    end.last(SERIES_TAIL)
  end

  def failsoft_reason(err)
    err.is_a?(BTC::Coinglass::TierGated) ? 'tier-gated' : err.message
  end

  # Replay (M12-1): drop every column dated on/after the replay day --
  # complete days only, the common.rb truncation contract applied to the
  # {time_list, price_list, data_map} shape.
  def truncate_chart(chart)
    return chart unless Scenario.replay?

    cut  = Scenario.as_of.to_i * 1000
    keep = (chart['time_list'] || []).each_index.select { |i| chart['time_list'][i].to_i < cut }
    { 'time_list'  => keep.map { |i| chart['time_list'][i] },
      'price_list' => keep.map { |i| (chart['price_list'] || [])[i] },
      'data_map'   => (chart['data_map'] || {}).transform_values { |s| keep.map { |i| s[i] } } }
  end

  def compute
    chart = truncate_chart(
      BTC::Coinglass.exchange_balance_chart(cache: 'cg_exchange_balance_chart',
                                            ttl: TTL))
    deltas = delta_pct_series(chart)
    raise 'no reserve data in the chart response' if deltas.empty?

    band, pct, today = band_for(deltas)
    totals = total_series(chart)
    { band: band, pct: pct, delta: today, totals: totals,
      total_now: totals.last && totals.last[1] }
  end

  # ---- daily history: append one row per UTC day (positioning pattern) --

  def history_file
    dir = BTC::Env.data_dir('reserves', File.join(__dir__, 'data', 'reserves'))
    File.join(dir, 'history.jsonl')
  end

  def append_history(file, row)
    last = File.file?(file) ? (JSON.parse(File.readlines(file).last.to_s) rescue nil) : nil
    return false if last && last['date'] == row['date']

    FileUtils.mkdir_p(File.dirname(file))
    File.open(file, 'a') { |f| f.puts JSON.generate(row) }
    true
  end

  def history_row(result, ts)
    { 'date' => ts.strftime('%Y-%m-%d'), 'ts' => ts.iso8601,
      'band' => result[:band], 'pct' => result[:pct]&.round(2),
      'delta_30d_pct' => result[:delta]&.round(3),
      'total_mbtc' => result[:total_now], 'score' => score(result[:band]) }
  end

  # ---- runnable surface -----------------------------------------------

  def run
    ts = Scenario.now_utc

    result = begin
      compute
    rescue StandardError => e # incl. Coinglass::Error/TierGated + transport
      Scenario.fail_soft(NAME, failsoft_reason(e)) # reports score 0, exits 0
    end

    # replay never writes the live history (staging is the backfill's job)
    append_history(history_file, history_row(result, ts)) if ARGV.include?('--history') && !Scenario.replay?

    s = score(result[:band])
    headline = format('score %+d | 30d %+.2f%% | band %s%s | total %.3fM BTC',
                      s, result[:delta],
                      result[:band],
                      result[:pct] ? format(' (pct %.0f)', result[:pct]) : '',
                      result[:total_now].to_f)

    detail = { 'band' => result[:band],
               'delta_30d_pct' => result[:delta]&.round(3),
               'total_mbtc' => result[:total_now] }
    detail['series'] = { 'total_mbtc' => result[:totals] } if ARGV.include?('--json')
    Scenario.report(NAME, s, headline, detail)
  end
end

Reserves.run if __FILE__ == $PROGRAM_NAME
