# frozen_string_literal: true

# M10-5: BTC::Scorecard -- the pure forward-return scoring engine behind
# the signal scorecard (P-19). Definitions are the D10-a owner ruling
# (2026-08-12): entry close(t) / exit close(t+h) join, log returns as %,
# per-band n/mean/%positive vs the same-window unconditional row, n_eff
# overlap honesty, and the n >= min_n AND span >= span_factor*h cell
# floor. All exact-value on synthetic prices; no network, no files.

require_relative '../test_helper'
require_relative '../../lib/btc/scorecard'

class TestBtcScorecard < Minitest::Test
  LN2 = Math.log(2)

  # n daily closes from 2026-01-01: close(i) = 100 * 2**i -- every 1d
  # log return is exactly ln2, every 7d return 7*ln2.
  def doubling_prices(n)
    (0...n).to_h { |i| [(Date.new(2026, 1, 1) + i).iso8601, 100.0 * (2**i)] }
  end

  # closes alternate 100, 200, 100, ... : 1d log return is +ln2 from an
  # even index, -ln2 from an odd one.
  def sawtooth_prices(n)
    (0...n).to_h { |i| [(Date.new(2026, 1, 1) + i).iso8601, i.even? ? 100.0 : 200.0] }
  end

  def series(dates_bands)
    dates_bands.map { |d, b| { 'date' => d, 'band' => b } }
  end

  # -- forward_return ------------------------------------------------

  def test_forward_return_is_log_return_between_entry_and_exit_close
    prices = { '2026-01-01' => 100.0, '2026-01-08' => 110.0 }
    r = BTC::Scorecard.forward_return(prices, '2026-01-01', 7)
    assert_in_delta Math.log(1.1), r, 1e-12
  end

  def test_forward_return_nil_when_entry_or_exit_close_missing
    prices = { '2026-01-01' => 100.0, '2026-01-08' => 110.0 }
    assert_nil BTC::Scorecard.forward_return(prices, '2026-01-02', 6)
    assert_nil BTC::Scorecard.forward_return(prices, '2026-01-01', 6)
  end

  # -- score: aggregates ---------------------------------------------

  def test_bands_get_exact_mean_pct_and_pos_pct
    prices = sawtooth_prices(41)
    rows   = (0...40).map do |i|
      d = (Date.new(2026, 1, 1) + i).iso8601
      [d, i.even? ? 'UP' : 'DOWN']
    end
    out = BTC::Scorecard.score(series(rows), prices,
                               horizons: [1], min_n: 10, span_factor: 2)
    h1 = out['1']
    assert h1['eligible']
    assert_equal 40, h1['n']
    assert_in_delta((LN2 * 100).round(2),  h1['bands']['UP']['mean_pct'],   1e-9)
    assert_in_delta((-LN2 * 100).round(2), h1['bands']['DOWN']['mean_pct'], 1e-9)
    assert_in_delta 100.0, h1['bands']['UP']['pos_pct'],   1e-9
    assert_in_delta 0.0,   h1['bands']['DOWN']['pos_pct'], 1e-9
    assert_equal 20, h1['bands']['UP']['n']
    assert_equal 20, h1['bands']['DOWN']['n']
  end

  def test_all_row_is_the_unconditional_same_window_benchmark
    prices = sawtooth_prices(41)
    rows   = (0...40).map { |i| [(Date.new(2026, 1, 1) + i).iso8601, i.even? ? 'UP' : 'DOWN'] }
    h1 = BTC::Scorecard.score(series(rows), prices,
                              horizons: [1], min_n: 10, span_factor: 2)['1']
    assert_in_delta 0.0,  h1['all']['mean_pct'], 1e-9 # +ln2/-ln2 cancel
    assert_in_delta 50.0, h1['all']['pos_pct'],  1e-9
    assert_equal 40, h1['all']['n']
  end

  def test_rows_without_a_price_join_are_skipped_not_counted
    prices = doubling_prices(15)
    rows   = (0...14).map { |i| [(Date.new(2026, 1, 1) + i).iso8601, 'A'] }
    rows << ['2026-03-01', 'A'] # no such price date
    h7 = BTC::Scorecard.score(series(rows), prices,
                              horizons: [7], min_n: 5, span_factor: 0)['7']
    assert_equal 8, h7['n'] # entries 0..7 have an exit within day 14
    assert_in_delta((7 * LN2 * 100).round(2), h7['bands']['A']['mean_pct'], 1e-9)
  end

  def test_input_order_does_not_matter
    prices = sawtooth_prices(41)
    rows   = (0...40).map { |i| [(Date.new(2026, 1, 1) + i).iso8601, i.even? ? 'UP' : 'DOWN'] }
    a = BTC::Scorecard.score(series(rows), prices, horizons: [1], min_n: 10, span_factor: 2)
    b = BTC::Scorecard.score(series(rows.shuffle(random: Random.new(42))), prices,
                             horizons: [1], min_n: 10, span_factor: 2)
    assert_equal a, b
  end

  # -- score: honesty machinery --------------------------------------

  def test_n_eff_reports_overlap_deflated_count
    prices = doubling_prices(40)
    rows   = (0...39).map { |i| [(Date.new(2026, 1, 1) + i).iso8601, 'A'] }
    h7 = BTC::Scorecard.score(series(rows), prices,
                              horizons: [7], min_n: 5, span_factor: 2)['7']
    assert_equal 33, h7['n']            # entries 0..32 exit by day 39
    assert_in_delta 4.7, h7['n_eff'], 1e-9 # (33/7).round(1)
  end

  def test_cell_below_min_n_is_ineligible_with_reason_and_no_stats
    prices = doubling_prices(15)
    rows   = (0...14).map { |i| [(Date.new(2026, 1, 1) + i).iso8601, 'A'] }
    h7 = BTC::Scorecard.score(series(rows), prices,
                              horizons: [7], min_n: 30, span_factor: 0)['7']
    refute h7['eligible']
    assert_equal 'n too small', h7['reason']
    assert_equal 8, h7['n']
    refute h7.key?('bands')
    refute h7.key?('all')
  end

  def test_cell_with_enough_n_but_short_span_is_ineligible
    # 60 daily rows -> span 59d; h=30 needs span >= 60. n(valid) = 30.
    prices = doubling_prices(60)
    rows   = (0...60).map { |i| [(Date.new(2026, 1, 1) + i).iso8601, 'A'] }
    h30 = BTC::Scorecard.score(series(rows), prices,
                               horizons: [30], min_n: 30, span_factor: 2)['30']
    assert_equal 30, h30['n']
    refute h30['eligible']
    assert_equal 'n too small', h30['reason']
  end

  def test_empty_series_is_ineligible_everywhere
    out = BTC::Scorecard.score([], doubling_prices(10), horizons: [7, 30])
    %w[7 30].each do |h|
      refute out[h]['eligible']
      assert_equal 0, out[h]['n']
    end
  end

  def test_defaults_are_the_d10a_ruling
    assert_equal [7, 30, 90], BTC::Scorecard::HORIZONS
    assert_equal 30, BTC::Scorecard::MIN_N
    assert_equal 2,  BTC::Scorecard::SPAN_FACTOR
  end
end
