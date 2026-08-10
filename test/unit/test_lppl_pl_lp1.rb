# frozen_string_literal: true
#
# M9-9: PL+LP1 rival machinery. Lppl::PlLp1Reg is the prefix-sum O(1)-per-fit
# least squares for the FIXED 4-column design [1, ln(age), cos(w*ln age),
# sin(w*ln age)] (omega rigid). Report-only -- feeds a separate trend cache and
# never the frozen rival set. Deterministic, offline.

require_relative '../test_helper'
require_relative '../../scripts/lppl/common'

class TestLpplPlLp1Reg < Minitest::Test
  OMEGA = 8.7

  def build(u_from: 2000, n: 300)
    u = (1..n).map { |k| Math.log(u_from.to_f + k) }
    # y = 2 + 0.5*u + 0.3*cos - 0.2*sin, an exact PL+LP1 signal
    y = u.map { |x| 2.0 + 0.5 * x + 0.3 * Math.cos(OMEGA * x) - 0.2 * Math.sin(OMEGA * x) }
    [u, y]
  end

  def test_recovers_exact_coefficients
    u, y = build
    f = Lppl::PlLp1Reg.new(u, y, OMEGA).fit(u.size - 1)
    assert_in_delta 2.0,  f[:coef][0], 1e-6
    assert_in_delta 0.5,  f[:coef][1], 1e-6
    assert_in_delta 0.3,  f[:coef][2], 1e-6
    assert_in_delta(-0.2, f[:coef][3], 1e-6)
    assert_in_delta 0.0,  f[:sigma2], 1e-12
  end

  def test_forecast_row_matches_signal
    u, y = build
    reg = Lppl::PlLp1Reg.new(u, y, OMEGA)
    f   = reg.fit(u.size - 1)
    mu  = f[:coef].each_index.inject(0.0) { |s, a| s + f[:coef][a] * reg.row(u.size - 1)[a] }
    assert_in_delta y[-1], mu, 1e-6
  end

  # prefix fit on [0, b] must equal a direct normal-equations solve on that slice
  def test_prefix_fit_matches_direct_slice
    u, y = build(n: 400)
    reg  = Lppl::PlLp1Reg.new(u, y, OMEGA)
    b    = 250
    f    = reg.fit(b)
    # direct solve on rows 0..b
    cols = [Array.new(b + 1, 1.0), u[0..b],
            u[0..b].map { |x| Math.cos(OMEGA * x) },
            u[0..b].map { |x| Math.sin(OMEGA * x) }]
    xtx = Array.new(4) { |a| Array.new(4) { |c| (0..b).inject(0.0) { |s, i| s + cols[a][i] * cols[c][i] } } }
    xty = Array.new(4) { |a| (0..b).inject(0.0) { |s, i| s + cols[a][i] * y[i] } }
    direct = Lppl.gauss_solve(xtx, xty)
    (0...4).each { |a| assert_in_delta direct[a], f[:coef][a], 1e-6 }
  end

  def test_too_few_rows_returns_nil
    u, y = build(n: 4)
    assert_nil Lppl::PlLp1Reg.new(u, y, OMEGA).fit(4)
  end

  # sigma2 uses n-4 dof and reflects genuine misfit when a mode is missing
  def test_sigma2_positive_when_signal_has_extra_noise
    u, _ = build
    rng  = Random.new(11)
    y    = u.map { |x| 2.0 + 0.5 * x + 0.3 * Math.cos(OMEGA * x) + (rng.rand - 0.5) * 0.1 }
    f    = Lppl::PlLp1Reg.new(u, y, OMEGA).fit(u.size - 1)
    assert_operator f[:sigma2], :>, 0.0
  end
end
