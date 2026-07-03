# frozen_string_literal: true

# Seed characterization test for Phase 0: pins the numerical behavior of
# Common::RangeReg and Common.gauss_solve from scripts/lppl/common.rb.
# Pattern to replicate for bs_gamma, instrument parsing, envelope fits,
# and Lomb-Scargle (synthetic sinusoid).

require_relative '../test_helper'
require_relative '../../scripts/lppl/common'

class TestRangeReg < Minitest::Test
  def test_recovers_exact_line
    xs = (1..50).map { |i| Math.log(i.to_f) }
    ys = xs.map { |x| 2.5 + 1.7 * x }
    f  = Common::RangeReg.new(xs, ys).fit(0, xs.size - 1)

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
    f   = Common::RangeReg.new(xs, ys).fit(a, b)

    direct = (a..b).inject(0.0) do |s, i|
      s + (ys[i] - f[:icept] - f[:slope] * xs[i])**2
    end
    assert_close direct, f[:sse], 1e-8
  end

  def test_range_subset_differs_from_full
    xs = (1..100).map { |i| Math.log(i.to_f) }
    ys = xs.each_with_index.map { |x, i| x * (i < 50 ? 1.0 : 2.0) }
    r  = Common::RangeReg.new(xs, ys)
    refute_equal r.fit(0, 49)[:slope].round(6), r.fit(50, 99)[:slope].round(6)
  end

  def test_degenerate_range_returns_nil
    xs = [1.0, 2.0]
    assert_nil Common::RangeReg.new(xs, xs).fit(0, 1)
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

    x = Common.gauss_solve(a, b)
    x.each_with_index { |v, i| assert_close x_true[i], v, 1e-9 }
  end

  def test_singular_returns_nil
    a = [[1.0, 2.0], [2.0, 4.0]]
    assert_nil Common.gauss_solve(a, [1.0, 2.0])
  end
end
