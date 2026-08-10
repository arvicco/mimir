# frozen_string_literal: true
#
# M9-6: symmetric-null SHADOW. Lppl.power_decay_fit_v2 gives the pure
# power-decay null the same coarse+refined pass the LPPLS fit gets and selects
# tc/m on RMSE (sqrt(SSE/rows)) instead of raw SSE, so tc-dependent row counts
# cannot tilt the choice late. It is REPORT-ONLY and must not disturb the
# frozen original Lppl.power_decay_fit -- pinned here as a characterization
# guard (the original is untouched by this wave; this pin proves it).

require_relative '../test_helper'
require_relative '../../scripts/lppl/common'

class TestLpplNullV2 < Minitest::Test
  PEAK_DAY = 6000.0

  # Deterministic post-peak power decay ln P = 10 - 0.05 * tau^0.4 with tiny
  # seeded noise; peak at index 0, true tc = PEAK_DAY (an interior tc).
  def build_series
    rng   = Random.new(42)
    days  = []
    lnp   = []
    dates = []
    (0...400).each do |k|
      d   = PEAK_DAY + k
      tau = k.to_f
      ln  = 10.0 - 0.05 * (tau <= 0 ? 0.0 : tau)**0.4 + (rng.rand - 0.5) * 0.01
      days  << d
      lnp   << ln
      dates << (Lppl::GENESIS + d * 86_400)
    end
    { days: days, lnp: lnp, dates: dates, px: lnp.map { |v| Math.exp(v) } }
  end

  # CHARACTERIZATION: the frozen original null is byte-identical (Golden Rule 4).
  def test_original_power_decay_fit_pinned
    n0 = Lppl.power_decay_fit(build_series, 0)
    assert_in_delta 6000.0, n0[:tc], 1e-9
    assert_in_delta 0.4,    n0[:m],  1e-9
    assert_in_delta 0.0029269245, n0[:rmse], 1e-9
    assert_equal 397, n0[:resid].size
  end

  def test_v2_shape_and_fields
    v2 = Lppl.power_decay_fit_v2(build_series, 0)
    refute_nil v2
    assert_kind_of Float, v2[:tc]
    assert_kind_of Float, v2[:rmse]
    assert_includes [true, false], v2[:at_grid_edge]
  end

  # v2 selects on RMSE = sqrt(SSE/rows): its reported rmse is exactly that of
  # its chosen fit (row count comes from the tau>2d window at the chosen tc).
  def test_v2_rmse_is_sse_over_rows
    p  = build_series
    v2 = Lppl.power_decay_fit_v2(p, 0)
    rows = p[:days].count { |d| d - v2[:tc] > 2.0 }
    assert_in_delta Math.sqrt(v2[:sse] / rows), v2[:rmse], 1e-12
  end

  # On a clean interior-tc series neither null pins at a boundary; the two
  # selectors agree because there is no row-count bias to exploit.
  def test_clean_series_not_at_grid_edge_and_agrees_with_original
    p  = build_series
    n0 = Lppl.power_decay_fit(p, 0)
    v2 = Lppl.power_decay_fit_v2(p, 0)
    assert_equal false, v2[:at_grid_edge]
    assert_in_delta n0[:tc], v2[:tc], 1e-9
    assert_in_delta n0[:rmse], v2[:rmse], 1e-9
  end
end
