# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/btc/dist_scoring'

# M13-2: proper scoring rules on quantile grids. Exact-value pins on
# closed-form cases plus the properties the resolution job leans on.
class TestBtcDistScoring < Minitest::Test
  S = BTC::DistScoring

  # A symmetric 3-level point mass at 100: CRPS must equal |y - 100|.
  def test_crps_point_mass_is_absolute_error
    pm = [[0.25, 100.0], [0.5, 100.0], [0.75, 100.0]]
    assert_in_delta 7.0, S.crps(pm, 107.0), 1e-12
    assert_in_delta 3.0, S.crps(pm, 97.0), 1e-12
    assert_in_delta 0.0, S.crps(pm, 100.0), 1e-12
  end

  # Uniform(0,1), y = 0: true CRPS = integral of F(x)^2 = 1/3. A dense
  # symmetric grid must converge to it.
  def test_crps_converges_to_uniform_closed_form
    grid = (1..99).map { |i| [i / 100.0, i / 100.0] }
    assert_in_delta 1.0 / 3.0, S.crps(grid, 0.0), 5e-3
  end

  # Hand-computed small case: grid [[0.25, 1], [0.5, 2], [0.75, 3]], y = 2.5:
  # rho(1) = 1.5*0.25, rho(2) = 0.5*0.5, rho(3) = 0.5*0.25 -> sum 0.75
  # -> crps = 2/3 * 0.75 = 0.5
  def test_crps_hand_computed
    grid = [[0.25, 1.0], [0.5, 2.0], [0.75, 3.0]]
    assert_in_delta 0.5, S.crps(grid, 2.5), 1e-12
  end

  def test_crps_is_nonnegative
    grid = [[0.1, 90.0], [0.5, 100.0], [0.9, 130.0]]
    [50.0, 90.0, 101.3, 500.0].each do |y|
      assert_operator S.crps(grid, y), :>=, 0.0
    end
  end

  def test_pit_median_is_half_and_interpolates
    grid = [[0.25, 1.0], [0.5, 2.0], [0.75, 4.0]]
    assert_in_delta 0.5, S.pit(grid, 2.0), 1e-12
    assert_in_delta 0.625, S.pit(grid, 3.0), 1e-12 # halfway 2..4 in q
  end

  def test_pit_clamps_to_edge_taus
    grid = [[0.01, 10.0], [0.99, 20.0]]
    assert_in_delta 0.01, S.pit(grid, 5.0), 1e-12
    assert_in_delta 0.99, S.pit(grid, 25.0), 1e-12
  end

  # Uniform(0,1) encoded as quantiles (q = tau): density 1 -> ln = 0.
  def test_log_score_uniform_density_is_zero
    grid = (1..9).map { |i| [i / 10.0, i / 10.0] }
    assert_in_delta 0.0, S.log_score(grid, 0.55), 1e-12
  end

  # Bracket 0.5..0.75 spanning q 2..4: density 0.125 -> ln(0.125).
  def test_log_score_hand_computed_bracket
    grid = [[0.25, 1.0], [0.5, 2.0], [0.75, 4.0]]
    assert_in_delta Math.log(0.125), S.log_score(grid, 3.0), 1e-12
  end

  def test_log_score_nil_off_grid_and_on_point_mass
    grid = [[0.25, 1.0], [0.75, 3.0]]
    assert_nil S.log_score(grid, 0.5)
    assert_nil S.log_score(grid, 3.5)
    assert_nil S.log_score([[0.25, 2.0], [0.75, 2.0]], 2.0)
  end

  def test_brier_exact
    assert_in_delta 0.09, S.brier(0.7, true), 1e-12
    assert_in_delta 0.49, S.brier(0.7, false), 1e-12
    assert_in_delta 0.0, S.brier(1.0, true), 1e-12
  end
end
