# frozen_string_literal: true

# M10-6: loader/formatting units for scripts/scorecard.rb -- the ledger
# readers that feed BTC::Scorecard (the M10-5 engine, tested separately).
# Pure functions only, exercised on inline synthetic rows shaped exactly
# like the recorded ledgers: ts -> UTC date, -1/0/+1 -> '+1'/'0'/'-1',
# dedup-to-last-per-UTC-day, prices.csv parsing, and the per-source signal
# extraction (lppl / scenario / gex). No files, no network.

require_relative '../test_helper'
require_relative '../../scripts/scorecard'

class TestScorecardCli < Minitest::Test
  # -- ts_to_date: UTC date of a timestamp ---------------------------

  def test_ts_to_date_takes_the_utc_calendar_day
    assert_equal '2026-08-12', SignalScorecard.ts_to_date('2026-08-12T04:47:16Z')
  end

  def test_ts_to_date_normalizes_offset_timestamps_to_utc
    # 01:00 at +05:00 is 20:00 the previous UTC day.
    assert_equal '2026-08-11', SignalScorecard.ts_to_date('2026-08-12T01:00:00+05:00')
  end

  # -- fmt_score: integer score -> band label ------------------------

  def test_fmt_score_labels_are_signed_except_zero
    assert_equal '+1', SignalScorecard.fmt_score(1)
    assert_equal '0',  SignalScorecard.fmt_score(0)
    assert_equal '-1', SignalScorecard.fmt_score(-1)
  end

  def test_fmt_score_is_nil_for_a_missing_score
    assert_nil SignalScorecard.fmt_score(nil)
  end

  # -- dedup_last_per_day: engine wants one row per date -------------

  def test_dedup_keeps_the_last_row_for_a_repeated_date
    series = [
      { 'date' => '2026-01-01', 'band' => 'A' },
      { 'date' => '2026-01-01', 'band' => 'B' }, # same day, later -> wins
      { 'date' => '2026-01-02', 'band' => 'C' }
    ]
    out = SignalScorecard.dedup_last_per_day(series)
    assert_equal 2, out.length
    by_date = out.to_h { |r| [r['date'], r['band']] }
    assert_equal 'B', by_date['2026-01-01']
    assert_equal 'C', by_date['2026-01-02']
  end

  # -- parse_prices: date,close CSV ----------------------------------

  def test_parse_prices_skips_header_and_dust_rows
    lines = ["date,close\n", "2010-07-18,0.08584\n",
             "2026-08-11,63547.4365920514\n", "2013-01-01,0.02\n"]
    px = SignalScorecard.parse_prices(lines)
    assert_in_delta 0.08584, px['2010-07-18'], 1e-9
    assert_in_delta 63_547.4365920514, px['2026-08-11'], 1e-6
    refute px.key?('date')            # header dropped
    refute px.key?('2013-01-01')      # < 0.05 dust dropped
  end

  # -- lppl_signals: verdict + trend/envelope/fit --------------------

  def test_lppl_signals_extract_verdict_and_scored_modules
    rows = [
      { 'ts' => '2026-08-11T04:00:00Z', 'verdict' => 'NEUTRAL',
        'scores' => { 'trend' => 0, 'envelope' => 1, 'fit' => -1 } },
      { 'ts' => '2026-08-12T04:47:16Z', 'verdict' => 'STRESSED',
        'scores' => { 'trend' => -1, 'envelope' => 1, 'fit' => -1 } }
    ]
    sig = SignalScorecard.lppl_signals(rows)
    assert_equal %w[lppl_verdict lppl_trend lppl_envelope lppl_fit], sig.keys
    assert_equal %w[NEUTRAL STRESSED], sig['lppl_verdict'].map { |r| r['band'] }
    assert_equal %w[0 -1], sig['lppl_trend'].map { |r| r['band'] }
    assert_equal %w[+1 +1], sig['lppl_envelope'].map { |r| r['band'] }
  end

  # -- scenario_signals: regime + one signal per scores key ----------

  def test_scenario_signals_derive_a_signal_per_module_key
    rows = [
      { 'ts' => '2026-08-12T04:47:27Z', 'regime' => 'NEUTRAL',
        'scores' => { 'etf_flows' => 1, 'macro' => -1, 'stables' => 0 } }
    ]
    sig = SignalScorecard.scenario_signals(rows)
    assert_equal %w[scenario_regime scenario_etf_flows scenario_macro scenario_stables], sig.keys
    assert_equal 'NEUTRAL', sig['scenario_regime'].first['band']
    assert_equal '+1', sig['scenario_etf_flows'].first['band']
    assert_equal '-1', sig['scenario_macro'].first['band']
    assert_equal '0',  sig['scenario_stables'].first['band']
  end

  # -- gex_signals: sign of spot vs gamma flip -----------------------

  def test_gex_signal_is_pos_when_spot_above_flip_else_neg
    snaps = [
      { 'date' => '2026-07-06',
        'btc_combined' => { 'btc_spot' => 63_581.2, 'combined' => { 'gamma_flip' => 62_888 } } },
      { 'date' => '2026-07-07',
        'btc_combined' => { 'btc_spot' => 60_000.0, 'combined' => { 'gamma_flip' => 61_000 } } }
    ]
    sig = SignalScorecard.gex_signals(snaps)
    assert_equal %w[gex_gamma_sign], sig.keys
    assert_equal %w[POS NEG], sig['gex_gamma_sign'].map { |r| r['band'] }
  end

  def test_gex_signal_skips_a_snapshot_missing_spot_or_flip
    snaps = [
      { 'date' => '2026-07-06',
        'btc_combined' => { 'btc_spot' => 63_000.0, 'combined' => {} } },      # no flip
      { 'date' => '2026-07-07',
        'btc_combined' => { 'combined' => { 'gamma_flip' => 61_000 } } }        # no spot
    ]
    assert_empty SignalScorecard.gex_signals(snaps)['gex_gamma_sign']
  end
end
