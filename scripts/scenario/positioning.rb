#!/usr/bin/env ruby
# frozen_string_literal: true
#
# positioning.rb -- P-6 crowd-positioning module. Reads the derivatives
# crowd's stance (retail long/short, top-trader position, open interest
# momentum, aggressive taker flow, liquidation skew) and looks for the
# classic over-crowded "flush setup": everyone long, OI climbing, longs
# already getting liquidated -- the fuel and the spark for a wash-out.
#
# GOVERNANCE -- this module enters the scenario composite at WEIGHT 0
# (display only). Its score is reported and charted, never weighted, until
# the owner rules on the scorecard (SHADOW-FIRST, Golden Rule 4). The
# semantics below are FIXED by owner rulings D10-b (2026-08-12); do not
# tune them without a new ruling.
#
# USAGE
#   ruby positioning.rb            # aligned table (five sub-signal bands)
#   ruby positioning.rb --json     # one machine line (frozen contract)
#   ruby positioning.rb --history  # append one row per UTC day to
#                                  #   <data>/positioning/history.jsonl
#
# --json ADDITIVE `series` (M10-4, for v1:chart:positioning): a `series`
# object carrying trailing 120 daily [date, value] points of six card
# metrics, each scaled at build time to the unit a human reads (design
# ruling): oi_close in $B (1dp), global_ls / top_ls ratios (2dp), taker_buy
# BUY-share in % (1dp), long_liq / short_liq in $M (1dp). A day with no
# usable input for a metric is an OMITTED point (never a spurious zero).
# --json only -- the human table stays the five band rows.
#
# SEMANTICS (D10-b, FIXED)
#   Five daily sub-signals, one Coinglass endpoint each (interval 1d).
#   BAND = today's value placed in the trailing-90-day distribution of its
#   OWN history (the previous 90 daily values, EXCLUDING today), cutoffs at
#   the 80th / 20th percentiles. Percentile = the share of the 90 window
#   values STRICTLY BELOW today, in percent (linear rank). A value landing
#   exactly ON a cutoff is IN the extreme band (>= 80th, <= 20th).
#   Fewer than 90 trailing values => band 'WARMUP' (no percentile).
#     1. crowding    global_account_long_short_ratio     LONG / BALANCED / SHORT
#     2. top_traders top_position_long_short_ratio        LONG / BALANCED / SHORT
#     3. oi_7d       7-day % change of OI close           RISING / FLAT / FALLING
#     4. taker_bias  taker_buy_usd / (buy + sell)         BUY / BALANCED / SELL
#     5. liq_skew    long_liq_usd / (long + short)        LONGS-HIT / BAL / SHORTS-HIT
#
#   SCORE (-1/0/+1, display only, no tunable weights):
#     -1  ONLY when crowding==LONG  AND oi_7d==RISING  AND liq_skew==LONGS-HIT
#     +1  ONLY when crowding==SHORT AND oi_7d==FALLING AND liq_skew==SHORTS-HIT
#      0  otherwise. Any sub-signal WARMUP or unavailable can never complete
#         a lineup, so the score is 0. top_traders / taker_bias are shown
#         for context but do NOT enter the score.
#
# KILL CRITERIA (pre-registered, D10-b): this module is REMOVED, not tuned,
# if (a) the source is dead for 14+ consecutive days, or (b) after 120 days
# the signal scorecard shows its score bands do not separate 30d forward
# returns from the unconditional row.
#
# DATA SOURCE
#   Coinglass v4 via the BTC::Coinglass M10-2 wrappers (health-registered),
#   one fetch per endpoint, each routed through the SourceCache seam with a
#   24h ttl so the bi-hourly scenario loop hits the API at most once a day.
#   Key: ENV['COINGLASS_API_KEY'] (owned by lib/btc/coinglass.rb). Fail-soft:
#   any Coinglass error (TierGated => reason 'tier-gated') or transport
#   failure reports score 0 with a reason and exits 0 -- a dead API must
#   never break the aggregate.
#
# CAVEATS
#   Several Coinglass numeric fields arrive as STRINGS (e.g. taker volume
#   "38813.338", OI close "46794137466"); every metric is normalized with
#   to_f. Below 90 trailing days a sub-signal is WARMUP and cannot score.
#   The long/short ratio + top-position series are per-exchange (Binance
#   BTCUSDT perpetual), not aggregated -- the tier-safe series M10-2 probed.

require_relative 'common'
require_relative '../../lib/btc/coinglass'
require_relative '../../lib/btc/env'
require 'json'
require 'time'
require 'fileutils'

module Positioning
  module_function

  NAME   = 'positioning'
  WINDOW = 90         # trailing daily values that define the distribution
  TTL    = 86_400     # 24h source-cache freshness -- one API hit per day
  HI, LO = 80.0, 20.0 # percentile cutoffs (inclusive to the extreme band)
  SERIES_TAIL = 120   # trailing daily points published to the card (M10-4)

  # Linear rank of `value` among `window`: the share of window values
  # STRICTLY BELOW it, in percent (0..100).
  def percentile(value, window)
    100.0 * window.count { |v| v < value } / window.size
  end

  # Map a percentile to one of three labels; the cutoffs are inclusive to
  # the extreme bands (pct >= 80 -> high, pct <= 20 -> low).
  def classify(pct, high, mid, low)
    if pct >= HI
      high
    elsif pct <= LO
      low
    else
      mid
    end
  end

  # Band today's value (the series' last element) against the 90 values
  # immediately preceding it. Returns [band, pct_or_nil, today_value].
  # Fewer than 90 trailing values => ['WARMUP', nil, today].
  def band_for(series, high, mid, low)
    today = series.last
    return ['WARMUP', nil, today] if series.size < WINDOW + 1

    window = series[-(WINDOW + 1)...-1] # the 90 immediately-preceding values
    pct    = percentile(today, window)
    [classify(pct, high, mid, low), pct, today]
  end

  # Rows chronological by 'time' (defensive -- the API returns ascending,
  # but banding is order-sensitive so we never trust the wire order).
  def by_time(rows)
    rows.to_a.sort_by { |r| r['time'].to_i }
  end

  # ---- per-sub-signal metric series + band ----------------------------

  def crowding_band(rows)
    series = by_time(rows).map { |r| r['global_account_long_short_ratio'].to_f }
    band_for(series, 'LONG', 'BALANCED', 'SHORT')
  end

  def top_traders_band(rows)
    series = by_time(rows).map { |r| r['top_position_long_short_ratio'].to_f }
    band_for(series, 'LONG', 'BALANCED', 'SHORT')
  end

  # Daily series of the 7-day % change of OI close (derived, so shorter by 7).
  def oi7d_series(rows)
    closes = by_time(rows).map { |r| r['close'].to_f }
    (7...closes.size).filter_map do |i|
      base = closes[i - 7]
      (closes[i] - base) / base * 100.0 if base.positive?
    end
  end

  def oi7d_band(rows)
    band_for(oi7d_series(rows), 'RISING', 'FLAT', 'FALLING')
  end

  def taker_bias_band(rows)
    series = by_time(rows).filter_map do |r|
      buy  = r['taker_buy_volume_usd'].to_f
      sell = r['taker_sell_volume_usd'].to_f
      total = buy + sell
      buy / total if total.positive?
    end
    band_for(series, 'BUY', 'BALANCED', 'SELL')
  end

  def liq_skew_band(rows)
    series = by_time(rows).filter_map do |r|
      long  = r['aggregated_long_liquidation_usd'].to_f
      short = r['aggregated_short_liquidation_usd'].to_f
      total = long + short
      long / total if total.positive?
    end
    band_for(series, 'LONGS-HIT', 'BALANCED', 'SHORTS-HIT')
  end

  # The flush lineup (-1) and its exact mirror (+1); everything else 0.
  # A WARMUP/unavailable band never matches a lineup, so it scores 0.
  def score(crowding, oi_7d, liq_skew)
    return -1 if crowding == 'LONG'  && oi_7d == 'RISING'  && liq_skew == 'LONGS-HIT'
    return  1 if crowding == 'SHORT' && oi_7d == 'FALLING' && liq_skew == 'SHORTS-HIT'

    0
  end

  # Reason string for a fail-soft headline: an explicit 'tier-gated' for an
  # above-tier endpoint, otherwise the exception's (already redacted) message.
  def failsoft_reason(err)
    err.is_a?(BTC::Coinglass::TierGated) ? 'tier-gated' : err.message
  end

  # ---- card series (M10-4): trailing daily [date, value] points ---------

  # UTC calendar date (YYYY-MM-DD) of a row's ms-epoch 'time'.
  def row_date(row)
    Time.at(row['time'].to_i / 1000).utc.strftime('%Y-%m-%d')
  end

  # Trailing-SERIES_TAIL [date, value] pairs for +rows+ (chronological),
  # value produced by the block; a block returning nil DROPS that point (a
  # missing day is a gap, never a spurious zero). Empty rows -> [].
  def date_series(rows)
    by_time(rows).last(SERIES_TAIL).filter_map do |r|
      v = yield(r)
      [row_date(r), v] unless v.nil?
    end
  end

  # Taker BUY share as a percent (buy / (buy+sell) * 100, 1dp), or nil when
  # the day carries no taker volume (a gap, never a false 0/50).
  def taker_buy_pct(row)
    buy   = row['taker_buy_volume_usd'].to_f
    sell  = row['taker_sell_volume_usd'].to_f
    total = buy + sell
    return nil unless total.positive?

    (buy / total * 100).round(1)
  end

  # The six card series, each scaled to its human unit at build time (design
  # ruling): OI in $B (1dp), the two L/S ratios (2dp), taker BUY-share in %
  # (1dp), long/short liquidations in $M (1dp).
  def build_series(global, top, oi, taker, liq)
    { 'oi_close'  => date_series(oi)     { |r| (r['close'].to_f / 1e9).round(1) },
      'global_ls' => date_series(global) { |r| r['global_account_long_short_ratio'].to_f.round(2) },
      'top_ls'    => date_series(top)    { |r| r['top_position_long_short_ratio'].to_f.round(2) },
      'taker_buy' => date_series(taker)  { |r| taker_buy_pct(r) },
      'long_liq'  => date_series(liq)    { |r| (r['aggregated_long_liquidation_usd'].to_f / 1e6).round(1) },
      'short_liq' => date_series(liq)    { |r| (r['aggregated_short_liquidation_usd'].to_f / 1e6).round(1) } }
  end

  # Fetch every sub-signal series through the 24h-cached Coinglass wrappers
  # and compute the five bands + score + the card series. Returns the
  # structured result; raises on any Coinglass/transport error for the
  # caller to fail soft. Rows are fetched ONCE and shared by the band and
  # series computations (no double hit).
  def compute
    global = BTC::Coinglass.global_long_short_ratio(cache: 'cg_global_ls', ttl: TTL)
    top    = BTC::Coinglass.top_position_ratio(cache: 'cg_top_position', ttl: TTL)
    oi     = BTC::Coinglass.oi_aggregated_history(cache: 'cg_oi_aggregated', ttl: TTL)
    taker  = BTC::Coinglass.taker_buy_sell_history(cache: 'cg_taker_volume', ttl: TTL)
    liq    = BTC::Coinglass.liquidation_history(cache: 'cg_liquidation', ttl: TTL)

    crowding    = crowding_band(global)
    top_traders = top_traders_band(top)
    oi_7d       = oi7d_band(oi)
    taker_bias  = taker_bias_band(taker)
    liq_skew    = liq_skew_band(liq)

    subs = { 'crowding' => crowding, 'top_traders' => top_traders, 'oi_7d' => oi_7d,
             'taker_bias' => taker_bias, 'liq_skew' => liq_skew }
    { subs: subs, score: score(crowding[0], oi_7d[0], liq_skew[0]),
      series: build_series(global, top, oi, taker, liq) }
  end

  # ---- daily history: append one row per UTC day ----------------------

  def history_file
    dir = BTC::Env.data_dir('positioning', File.join(__dir__, 'data', 'positioning'))
    File.join(dir, 'history.jsonl')
  end

  # Append `row` to `file` unless the last line already carries the same
  # date (dedup: first run of the UTC day wins; a later same-day run is a
  # no-op). Returns true when a line was written. vol_spread.rb pattern.
  def append_history(file, row)
    last = File.file?(file) ? (JSON.parse(File.readlines(file).last.to_s) rescue nil) : nil
    return false if last && last['date'] == row['date']

    FileUtils.mkdir_p(File.dirname(file))
    File.open(file, 'a') { |f| f.puts JSON.generate(row) }
    true
  end

  # Structured history row: the five bands + raw values + percentiles + score.
  def history_row(result, ts)
    row = { 'date' => ts.strftime('%Y-%m-%d'), 'ts' => ts.iso8601 }
    result[:subs].each do |name, (band, pct, value)|
      row[name] = { 'band' => band, 'value' => value&.round(6), 'pct' => pct&.round(2) }
    end
    row['score'] = result[:score]
    row
  end

  # ---- runnable surface -----------------------------------------------

  def run
    ts = Time.now.utc

    result = begin
      compute
    rescue StandardError => e # incl. Coinglass::Error/TierGated + transport
      Scenario.fail_soft(NAME, failsoft_reason(e)) # reports score 0, exits 0
    end

    append_history(history_file, history_row(result, ts)) if ARGV.include?('--history')

    subs  = result[:subs]
    bands = Hash[subs.map { |name, (band, _pct, _v)| [name, band] }]
    headline = format('score %+d | crowd %s top %s oi7d %s taker %s liq %s',
                      result[:score], bands['crowding'], bands['top_traders'],
                      bands['oi_7d'], bands['taker_bias'], bands['liq_skew'])

    # M10-4: the card series ride the --json output only; the human table
    # stays the five band rows (a series dump would swamp it).
    detail = ARGV.include?('--json') ? bands.merge('series' => result[:series]) : bands
    Scenario.report(NAME, result[:score], headline, detail)
  end
end

Positioning.run if $PROGRAM_NAME == __FILE__
