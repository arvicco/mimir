# frozen_string_literal: true

# Seed characterization test for Phase 0: pins the numerical behavior of
# Lppl::RangeReg and Lppl.gauss_solve from scripts/lppl/common.rb.
# Pattern to replicate for bs_gamma, instrument parsing, envelope fits,
# and Lomb-Scargle (synthetic sinusoid).

require_relative '../test_helper'
require_relative '../../scripts/lppl/common'

class TestRangeReg < Minitest::Test
  def test_recovers_exact_line
    xs = (1..50).map { |i| Math.log(i.to_f) }
    ys = xs.map { |x| 2.5 + 1.7 * x }
    f  = Lppl::RangeReg.new(xs, ys).fit(0, xs.size - 1)

    assert_close 1.7, f[:slope], 1e-9
    assert_close 2.5, f[:icept], 1e-9
    assert_close 0.0, f[:sse],   1e-9
  end

  def test_sse_matches_direct_computation
    rng = Random.new(7)
    xs  = (1..200).map { |i| Math.log(i + 1.0) }
    ys  = xs.map { |x| 1.0 + 0.5 * x + (rng.rand - 0.5) * 0.2 }
    a   = 40
    b   = 160
    f   = Lppl::RangeReg.new(xs, ys).fit(a, b)

    direct = (a..b).inject(0.0) do |s, i|
      s + (ys[i] - f[:icept] - f[:slope] * xs[i])**2
    end
    assert_close direct, f[:sse], 1e-8
  end

  def test_range_subset_differs_from_full
    xs = (1..100).map { |i| Math.log(i.to_f) }
    ys = xs.each_with_index.map { |x, i| x * (i < 50 ? 1.0 : 2.0) }
    r  = Lppl::RangeReg.new(xs, ys)
    refute_equal r.fit(0, 49)[:slope].round(6), r.fit(50, 99)[:slope].round(6)
  end

  def test_degenerate_range_returns_nil
    xs = [1.0, 2.0]
    assert_nil Lppl::RangeReg.new(xs, xs).fit(0, 1)
  end
end

class TestGaussSolve < Minitest::Test
  def test_solves_known_4x4_system
    a = [[2.0, 1.0, 0.0, 0.0],
         [1.0, 3.0, 1.0, 0.0],
         [0.0, 1.0, 4.0, 1.0],
         [0.0, 0.0, 1.0, 5.0]]
    x_true = [1.0, -2.0, 3.0, -4.0]
    b = a.map { |row| row.each_with_index.inject(0.0) { |s, (v, j)| s + v * x_true[j] } }

    x = Lppl.gauss_solve(a, b)
    x.each_with_index { |v, i| assert_close x_true[i], v, 1e-9 }
  end

  def test_singular_returns_nil
    a = [[1.0, 2.0], [2.0, 4.0]]
    assert_nil Lppl.gauss_solve(a, [1.0, 2.0])
  end
end

# M0-6 tolerance policy: detected frequencies are pinned to the scan
# grid (step 0.1 -> exact grid-point equality for on-grid tones);
# powers/parameters pinned to 1e-9 of precomputed references.
class TestLomb < Minitest::Test
  GRID = (2.0..20.0).step(0.1).to_a # logperiodic.rb's grid

  def test_pure_tone_peak_lands_on_true_frequency
    u = Array.new(300) { |i| Math.log(3.0 + i * 1.3) }
    r = u.map { |x| Math.cos(7.5 * x) }
    _, power, w_peak = Lppl.lomb(u, r, GRID)
    assert_close 7.5, w_peak, 1e-12
    assert_close 146.81424555, power, 1e-6
  end

  def test_seeded_white_noise_peak_stays_insignificant
    rng = Random.new(42)
    u = Array.new(200) { |i| Math.log(3.0 + i * 1.7) }
    r = Array.new(200) { rng.rand - 0.5 }
    _, power, = Lppl.lomb(u, r, GRID)
    assert_close 2.95047054749, power, 1e-6
    assert_operator power, :<, 10.0 # far below any tone; guards the pval logic
  end

  def test_zero_variance_returns_empty
    u = Array.new(10) { |i| Math.log(2.0 + i) }
    assert_equal [[], 0.0, 0.0], Lppl.lomb(u, Array.new(10, 1.0), GRID)
  end
end

class TestReciprocalEnvelope < Minitest::Test
  def test_recovers_exact_on_grid_decay
    ages  = (1..60).map { |i| i * 0.25 }
    abs_r = ages.map { |a| 2.0 / (a + 3.0) }
    f = Lppl.reciprocal_envelope(abs_r, ages)
    assert_close 3.0, f[:b]
    assert_close 2.0, f[:a], 1e-9
    assert_close 0.0, f[:sse], 1e-12
  end

  def test_off_grid_b_picks_nearest_grid_point
    ages  = (1..60).map { |i| i * 0.25 }
    abs_r = ages.map { |a| 2.0 / (a + 3.2) }
    f = Lppl.reciprocal_envelope(abs_r, ages)
    assert_close 3.0, f[:b] # nearest 0.5-grid point below 3.2
    assert_close 1.92816511287, f[:a], 1e-9
    assert_operator f[:sse], :>, 0.0
  end

  def test_empty_input_returns_nil
    assert_nil Lppl.reciprocal_envelope([], [])
  end
end
