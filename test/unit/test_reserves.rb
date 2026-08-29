# frozen_string_literal: true
#
# M11-7 (owner ruling R-11/D11-a, 2026-08-29): the exchange-reserve
# module's pure math -- window-consistent 30d delta over nil-padded
# per-exchange series, the 80/20 trailing-percentile band, the
# BUILDING -> -1 / DRAINING -> +1 score mapping, the card total series,
# and the same-day history dedup. No network: everything runs on
# synthetic chart hashes.

require_relative '../test_helper'
require_relative '../../scripts/scenario/reserves'
require 'tmpdir'
require 'json'

class TestReserves < Minitest::Test
  D = Reserves::DELTA_D
  W = Reserves::WINDOW

  # A chart hash of one exchange with balance b(i) = base + step*i.
  def chart(n, base: 1_000_000.0, step: 0.0)
    { 'time_list' => (0...n).map { |i| 1_700_000_000_000 + i * 86_400_000 },
      'price_list' => (0...n).map { 50_000.0 },
      'data_map' => { 'Ex1' => (0...n).map { |i| base + step * i } } }
  end

  def test_delta_series_exact_flat_and_linear
    flat = Reserves.delta_pct_series(chart(D + 3))
    assert_equal 3, flat.size
    flat.each { |v| assert_in_delta 0.0, v, 1e-9 }

    # linear growth: delta at i = step*D / (base + step*(i-D)) * 100
    lin = Reserves.delta_pct_series(chart(D + 1, base: 1000.0, step: 10.0))
    assert_equal 1, lin.size
    assert_in_delta 10.0 * D / 1000.0 * 100, lin.first, 1e-9 # +30%
  end

  def test_delisting_never_fakes_a_drain
    # Ex2 dies (nil) halfway: its disappearance must not read as coins
    # leaving -- windows it doesn't fully span exclude it entirely.
    n = D + 10
    c = chart(n)
    c['data_map']['Ex2'] = (0...n).map { |i| i < D + 2 ? 500_000.0 : nil }
    deltas = Reserves.delta_pct_series(c)
    deltas.each { |v| assert_in_delta 0.0, v, 1e-9, 'flat balances must stay 0% through the delisting' }
  end

  def test_band_warmup_below_window
    assert_equal 'WARMUP', Reserves.band_for([0.1] * W).first
    assert_equal 0, Reserves.score('WARMUP')
  end

  def test_band_building_and_draining_and_score
    base = (1..W).map { |i| i / 100.0 } # 0.01 .. 0.90
    band, pct, today = Reserves.band_for(base + [2.0]) # above everything
    assert_equal 'BUILDING', band
    assert_in_delta 100.0, pct, 1e-9
    assert_in_delta 2.0, today, 1e-9
    assert_equal(-1, Reserves.score(band))

    band2, pct2, = Reserves.band_for(base + [-1.0]) # below everything
    assert_equal 'DRAINING', band2
    assert_in_delta 0.0, pct2, 1e-9
    assert_equal 1, Reserves.score(band2)

    band3, = Reserves.band_for(base + [0.45]) # mid-distribution
    assert_equal 'FLAT', band3
    assert_equal 0, Reserves.score(band3)
  end

  def test_total_series_scales_sums_and_omits_empty_days
    c = chart(3, base: 1_500_000.0)
    c['data_map']['Ex2'] = [500_000.0, nil, 500_000.0]
    c['data_map']['Ex3'] = [nil, nil, nil]
    t = Reserves.total_series(c)
    assert_equal 3, t.size
    assert_equal 2.0,   t[0][1] # (1.5M + 0.5M) / 1e6
    assert_equal 1.5,   t[1][1] # Ex2's nil day: only Ex1 counts
    assert_equal 2.0,   t[2][1]
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, t[0][0])

    all_nil = { 'time_list' => [1], 'price_list' => [1.0], 'data_map' => { 'Ex' => [nil] } }
    assert_empty Reserves.total_series(all_nil)
  end

  def test_history_append_dedups_same_day
    Dir.mktmpdir do |dir|
      f = File.join(dir, 'history.jsonl')
      row = { 'date' => '2026-08-29', 'band' => 'FLAT', 'score' => 0 }
      assert Reserves.append_history(f, row)
      refute Reserves.append_history(f, row.merge('band' => 'BUILDING')),
             'second same-day append is a no-op (first run of the day wins)'
      assert_equal 1, File.readlines(f).size
      assert Reserves.append_history(f, row.merge('date' => '2026-08-30'))
      assert_equal 2, File.readlines(f).size
    end
  end
end
