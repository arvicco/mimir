# frozen_string_literal: true
#
# M8-2: BTC::GexHistory -- exact-value tests for the descriptive time-series
# math over the daily GEX snapshots. Pure functions, no IO: every input is a
# hand-built array of parsed-snapshot hashes (date-ascending), so the values
# are checked exactly. Covers regime runs/transitions, wall migration counts,
# flip-distance min/max/last, and the fail-soft skip of malformed daily files.

require_relative '../test_helper'
require_relative '../../lib/btc/gex_history'

class TestGexHistory < Minitest::Test
  # A well-formed daily snapshot (only the fields #series reads matter).
  def snap(date, spot:, flip:, cw:, pw:, regime:, net_gex: 100)
    { 'date' => date, 'captured_at' => "#{date}T06:15:05Z",
      'btc_combined' => {
        'ts' => "#{date}T06:15:06Z", 'btc_spot' => spot,
        'combined' => {
          'net_gex_usd_per_1pct' => net_gex, 'regime' => regime,
          'gamma_flip' => flip,
          'call_wall' => cw.nil? ? nil : { 'level' => cw, 'gex' => 1 },
          'put_wall' => pw.nil? ? nil : { 'level' => pw, 'gex' => -1 },
          'put_call_oi_btc' => 0.6, 'instruments' => 4000
        }
      } }
  end

  # Four clean days: spot fixed at 100000 so flip_dist_pct is exact.
  def four_days
    [
      snap('2026-07-06', spot: 100_000, flip: 99_000,  cw: 64_000, pw: 60_000, regime: 'long_gamma',  net_gex: 100),
      snap('2026-07-07', spot: 100_000, flip: 101_000, cw: 64_000, pw: 60_000, regime: 'long_gamma',  net_gex: 110),
      snap('2026-07-08', spot: 100_000, flip: 97_500,  cw: 65_000, pw: 60_000, regime: 'short_gamma', net_gex: -50),
      snap('2026-07-09', spot: 100_000, flip: 95_000,  cw: 65_000, pw: 61_000, regime: 'short_gamma', net_gex: -60)
    ]
  end

  # ---- series -------------------------------------------------------------

  def test_series_row_shape_and_exact_values
    rows = BTC::GexHistory.series(four_days)
    assert_equal 4, rows.length

    r0 = rows[0]
    assert_equal %w[cw date flip flip_dist_pct net_gex pw regime spot], r0.keys.sort
    assert_equal '2026-07-06', r0['date']
    assert_equal 100_000, r0['spot']
    assert_equal 99_000, r0['flip']
    assert_in_delta 1.00, r0['flip_dist_pct'], 1e-9
    assert_equal 64_000, r0['cw']
    assert_equal 60_000, r0['pw']
    assert_equal 100, r0['net_gex']
    assert_equal 'long_gamma', r0['regime']
  end

  def test_series_flip_dist_pct_is_signed_two_dp
    dists = BTC::GexHistory.series(four_days).map { |r| r['flip_dist_pct'] }
    assert_equal [1.00, -1.00, 2.50, 5.00], dists
  end

  def test_series_skips_days_missing_btc_combined_or_combined
    snaps = [
      snap('2026-07-06', spot: 100_000, flip: 99_000, cw: 64_000, pw: 60_000, regime: 'long_gamma'),
      { 'date' => '2026-07-07', 'errors' => { 'x' => 'y' } },                 # no btc_combined
      { 'date' => '2026-07-08', 'btc_combined' => { 'btc_spot' => 100_000 } } # no combined
    ]
    rows = BTC::GexHistory.series(snaps)
    assert_equal 1, rows.length
    assert_equal '2026-07-06', rows.first['date']
  end

  def test_series_flip_dist_pct_nil_when_flip_missing
    snaps = [snap('2026-07-06', spot: 100_000, flip: nil, cw: 64_000, pw: 60_000, regime: 'long_gamma')]
    row = BTC::GexHistory.series(snaps).first
    assert_nil row['flip']
    assert_nil row['flip_dist_pct']
  end

  def test_series_carries_nil_walls_through
    snaps = [snap('2026-07-06', spot: 100_000, flip: 99_000, cw: nil, pw: nil, regime: 'long_gamma')]
    row = BTC::GexHistory.series(snaps).first
    assert_nil row['cw']
    assert_nil row['pw']
  end

  def test_series_empty_for_empty_or_nil_input
    assert_empty BTC::GexHistory.series([])
    assert_empty BTC::GexHistory.series(nil)
  end

  # ---- stats --------------------------------------------------------------

  def test_stats_exact_over_four_days
    st = BTC::GexHistory.stats(BTC::GexHistory.series(four_days))
    assert_equal 4, st['days']
    assert_equal 'short_gamma', st['regime']
    assert_equal 2, st['regime_days']    # terminal run of short_gamma
    assert_equal 1, st['transitions']    # long -> short once
    assert_equal 1, st['cw_moves']       # 64000 -> 65000
    assert_equal 1, st['pw_moves']       # 60000 -> 61000
    assert_in_delta(-1.00, st['flip_dist_pct_min'], 1e-9)
    assert_in_delta 5.00, st['flip_dist_pct_max'], 1e-9
    assert_in_delta 5.00, st['flip_dist_pct_last'], 1e-9
  end

  def test_stats_terminal_run_of_single_regime
    snaps = Array.new(3) do |i|
      snap(format('2026-07-%02d', 6 + i), spot: 100_000, flip: 99_000,
           cw: 64_000, pw: 60_000, regime: 'long_gamma')
    end
    st = BTC::GexHistory.stats(BTC::GexHistory.series(snaps))
    assert_equal 3, st['regime_days']
    assert_equal 0, st['transitions']
  end

  def test_stats_counts_a_wall_move_from_nil_to_level
    snaps = [
      snap('2026-07-06', spot: 100_000, flip: 99_000, cw: nil,    pw: 60_000, regime: 'long_gamma'),
      snap('2026-07-07', spot: 100_000, flip: 99_000, cw: 64_000, pw: 60_000, regime: 'long_gamma')
    ]
    st = BTC::GexHistory.stats(BTC::GexHistory.series(snaps))
    assert_equal 1, st['cw_moves']
    assert_equal 0, st['pw_moves']
  end

  def test_stats_empty_series
    st = BTC::GexHistory.stats([])
    assert_equal 0, st['days']
    assert_nil st['regime']
    assert_equal 0, st['regime_days']
    assert_equal 0, st['transitions']
    assert_equal 0, st['cw_moves']
    assert_equal 0, st['pw_moves']
    assert_nil st['flip_dist_pct_min']
    assert_nil st['flip_dist_pct_max']
    assert_nil st['flip_dist_pct_last']
  end

  def test_stats_flip_dist_extremes_ignore_nil_days
    snaps = [
      snap('2026-07-06', spot: 100_000, flip: 99_000, cw: 64_000, pw: 60_000, regime: 'long_gamma'),
      snap('2026-07-07', spot: 100_000, flip: 97_000, cw: 64_000, pw: 60_000, regime: 'long_gamma'),
      snap('2026-07-08', spot: 100_000, flip: nil,    cw: 64_000, pw: 60_000, regime: 'long_gamma')
    ]
    st = BTC::GexHistory.stats(BTC::GexHistory.series(snaps))
    assert_in_delta 1.00, st['flip_dist_pct_min'], 1e-9
    assert_in_delta 3.00, st['flip_dist_pct_max'], 1e-9
    assert_nil st['flip_dist_pct_last'] # last day's flip was missing
  end
end
