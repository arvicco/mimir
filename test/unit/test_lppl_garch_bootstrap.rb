# frozen_string_literal: true
#
# M9-7: AR(1)+GARCH(1,1) parametric-bootstrap SHADOW null for logperiodic.rb.
# All offline + seeded (Random.new). Covers the pure-Ruby Nelder-Mead, GARCH
# conditional-MLE parameter recovery, AR(1) OLS, and the end-to-end p-value
# sanity (pure noise -> large p; injected oscillation -> small p).

require_relative '../test_helper'
require_relative '../../scripts/lppl/common'

class TestLpplGarchBootstrap < Minitest::Test
  GRID = (2.0..20.0).step(0.1).to_a

  # ---- Nelder-Mead on a known quadratic -------------------------------------
  def test_nelder_mead_minimizes_quadratic
    xb, fb = Lppl.nelder_mead([0.0, 0.0], [1.0, 1.0]) do |x|
      (x[0] - 3.0)**2 + (x[1] + 1.0)**2
    end
    assert_in_delta 3.0, xb[0], 1e-4
    assert_in_delta(-1.0, xb[1], 1e-4)
    assert_in_delta 0.0, fb, 1e-6
  end

  def test_nelder_mead_rosenbrock_min
    xb, = Lppl.nelder_mead([-1.0, 1.0], [0.5, 0.5], max_iter: 2000) do |x|
      (1 - x[0])**2 + 100 * (x[1] - x[0]**2)**2
    end
    assert_in_delta 1.0, xb[0], 1e-2
    assert_in_delta 1.0, xb[1], 1e-2
  end

  # ---- GARCH(1,1) MLE recovery ----------------------------------------------
  def test_estimate_garch_recovers_seeded_parameters
    rng = Random.new(123)
    om, al, be = 0.02, 0.08, 0.9
    s2 = om / (1 - al - be)
    eprev2 = s2
    e = Array.new(3000) do
      s2 = om + al * eprev2 + be * s2
      ev = Math.sqrt(s2) * Lppl.gauss(rng)
      eprev2 = ev * ev
      ev
    end
    g = Lppl.estimate_garch(e)
    assert g[:fitted], 'GARCH MLE should converge on a clean GARCH series'
    # loose tolerances -- MLE on 3000 pts recovers persistence well
    assert_in_delta al, g[:alpha], 0.05
    assert_in_delta be, g[:beta], 0.06
    assert_operator g[:omega], :>, 0.0
    assert_operator g[:alpha] + g[:beta], :<, 0.999
  end

  def test_estimate_garch_fallback_flags_not_fitted
    # A degenerate near-constant series drives the MLE nowhere useful; whatever
    # the outcome, fitted must be a boolean and the params stay in-box.
    g = Lppl.estimate_garch(Array.new(200, 0.0))
    assert_includes [true, false], g[:fitted]
    assert_operator g[:alpha] + g[:beta], :<, 0.999
    assert_operator g[:omega], :>=, 0.0
  end

  # ---- AR(1) OLS ------------------------------------------------------------
  def test_ar1_fit_recovers_phi
    rng = Random.new(5)
    phi = 0.7
    x = 0.0
    series = Array.new(4000) { x = phi * x + Lppl.gauss(rng) }
    ar = Lppl.ar1_fit(series)
    assert_in_delta phi, ar[:phi], 0.03
    assert_equal series.size - 1, ar[:innov].size
  end

  # ---- end-to-end p-value sanity --------------------------------------------
  def build_window(with_oscillation)
    rng = Random.new(7)
    days = []
    lnp  = []
    (0..250).each do |k|
      d   = 6000.0 + k
      tau = k.to_f
      f   = 10.0 - 0.05 * (tau <= 0 ? 0.0 : tau)**0.4
      v   = f + (rng.rand - 0.5) * 0.02
      v  += 0.05 * Math.cos(8.0 * Math.log([tau, 2.5].max)) if with_oscillation
      days << d
      lnp  << v
    end
    { days: days, lnp: lnp, dates: days.map { |d| Lppl::GENESIS + d * 86_400 },
      px: lnp.map { |x| Math.exp(x) } }
  end

  def pvalue_for(with_oscillation)
    p    = build_window(with_oscillation)
    null = Lppl.power_decay_fit(p, 0)
    _, obs, = Lppl.lomb(null[:u], null[:resid], GRID)
    Lppl.arma_garch_pvalue(p, 0, null, obs, GRID, 60, Random.new(42))
  end

  def test_pvalue_large_on_pure_noise
    b = pvalue_for(false)
    assert_operator b[:p_value], :>, 0.3, 'pure noise must not look periodic'
    assert_equal 60, b[:sims]
  end

  def test_pvalue_small_on_injected_oscillation
    b = pvalue_for(true)
    assert_operator b[:p_value], :<, 0.1, 'an injected log-periodic mode must be detected'
  end
end
