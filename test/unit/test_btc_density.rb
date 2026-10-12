# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/btc/density'

# M13-3: SVI slice fits + no-arb checks + the thin-slice fallback.
# The contract under test is the fitted total-variance CURVE (SVI
# params are near-degenerate and never pinned).
class TestBtcDensitySlices < Minitest::Test
  D = BTC::Density

  # Build both sides at each strike with iv given by the block (of k).
  def book(strikes, t:, fwd:, &iv_of_k)
    strikes.flat_map do |strike|
      k = Math.log(strike / fwd)
      iv = iv_of_k.call(k)
      %w[C P].map { |cp| { k: strike, cp: cp, t: t, iv: iv, oi: 100.0, u: fwd } }
    end
  end

  def test_flat_vol_slice_recovers_constant_total_variance
    t = 30 / 365.25
    b = book((60_000..160_000).step(10_000), t: t, fwd: 100_000.0) { |_k| 0.6 }
    sl = D.slices(b).first
    assert_equal 'svi', sl[:method]
    refute sl[:degraded]
    w_true = 0.36 * t
    [-0.3, 0.0, 0.3].each do |k|
      assert_in_delta w_true, D.total_variance(sl, k), w_true * 1e-3
    end
    assert sl[:butterfly_ok]
  end

  def test_known_svi_surface_round_trips
    t = 0.25
    p = { a: 0.02, b: 0.08, rho: -0.4, m: 0.05, s: 0.15 }
    strikes = (-6..6).map { |i| 100_000.0 * Math.exp(i * 0.08) }
    b = book(strikes, t: t, fwd: 100_000.0) { |k| Math.sqrt(D.svi_w(p, k) / t) }
    sl = D.slices(b).first
    assert_equal 'svi', sl[:method]
    [-0.4, -0.2, 0.0, 0.2, 0.4].each do |k|
      w_true = D.svi_w(p, k)
      assert_in_delta w_true, D.total_variance(sl, k), w_true * 0.01
    end
  end

  def test_thin_slice_falls_back_to_nearest_strike
    t = 0.1
    rows = [90_000.0, 100_000.0, 110_000.0].flat_map do |strike|
      %w[C P].map { |cp| { k: strike, cp: cp, t: t, iv: 0.5, oi: 1.0, u: 100_000.0 } }
    end
    sl = D.slices(rows).first
    assert_equal 'nearest', sl[:method]
    assert sl[:degraded]
    assert_match(/thin slice/, sl[:reason])
    assert_in_delta 0.25 * t, D.total_variance(sl, 0.01), 1e-12
  end

  def test_durrleman_g_is_one_for_flat_smile
    p = { a: 0.04, b: 0.0, rho: 0.0, m: 0.0, s: 0.1 }
    assert_in_delta 1.0, D.durrleman_g(p, 0.0), 1e-12
    assert_in_delta 1.0, D.durrleman_g(p, 0.5), 1e-12
  end

  def test_calendar_violations_flag_inverted_term_structure
    near = book((80_000..120_000).step(5_000), t: 0.1, fwd: 100_000.0) { |_k| 0.8 }
    far  = book((80_000..120_000).step(5_000), t: 0.3, fwd: 100_000.0) { |_k| 0.3 }
    sls = D.slices(near + far)
    refute_empty D.calendar_violations(sls) # w_near = .064 > w_far = .027

    ok_far = book((80_000..120_000).step(5_000), t: 0.3, fwd: 100_000.0) { |_k| 0.8 }
    assert_empty D.calendar_violations(D.slices(near + ok_far))
  end

  def test_slices_are_deterministic_and_time_ordered
    t1 = 0.1
    t2 = 0.3
    b = book((80_000..120_000).step(5_000), t: t2, fwd: 100_000.0) { |_k| 0.6 } +
        book((80_000..120_000).step(5_000), t: t1, fwd: 100_000.0) { |_k| 0.55 }
    a = D.slices(b)
    assert_equal [t1, t2], a.map { |sl| sl[:t] }
    assert_equal a.map { |sl| sl[:params] }, D.slices(b).map { |sl| sl[:params] }
  end
end

# M13-4: BL density pipeline oracles. A flat smile must round-trip to
# the analytic lognormal everywhere -- density values, integral,
# digitals, quantiles -- and the wings must recover the SAME lognormal.
class TestBtcDensityPipeline < Minitest::Test
  D = BTC::Density
  F = 100_000.0
  T = 30 / 365.25
  W = 0.36 * T # sigma = 0.6

  def flat_slices
    strikes = (50_000..200_000).step(5_000)
    book = strikes.flat_map do |strike|
      %w[C P].map { |cp| { k: strike.to_f, cp: cp, t: T, iv: 0.6, oi: 1.0, u: F } }
    end
    D.slices(book)
  end

  def analytic_pdf(x)
    z = (Math.log(x / F) + 0.5 * W) / Math.sqrt(W)
    Math.exp(-0.5 * z * z) / (x * Math.sqrt(W) * Math.sqrt(2 * Math::PI))
  end

  def analytic_digital(strike)
    BTC::Options.norm_cdf((Math.log(F / strike) - 0.5 * W) / Math.sqrt(W))
  end

  def analytic_quantile(tau)
    # inverse normal via bisection on norm_cdf (test-side helper)
    lo = -8.0
    hi = 8.0
    60.times do
      mid = 0.5 * (lo + hi)
      BTC::Options.norm_cdf(mid) < tau ? lo = mid : hi = mid
    end
    F * Math.exp(-0.5 * W + Math.sqrt(W) * 0.5 * (lo + hi))
  end

  def test_flat_smile_density_matches_analytic_lognormal
    den = D.expiry_density(flat_slices.first)
    assert_in_delta 1.0, den[:integral_raw], 5e-3
    [80_000.0, 95_000.0, 100_000.0, 110_000.0, 125_000.0].each do |x|
      i = den[:xs].index { |v| v >= x }
      assert_in_delta analytic_pdf(den[:xs][i]), den[:pdf][i],
                      analytic_pdf(den[:xs][i]) * 0.01
    end
  end

  def test_flat_smile_digitals_match_normal_cdf
    den = D.expiry_density(flat_slices.first)
    [85_000.0, 100_000.0, 120_000.0].each do |strike|
      assert_in_delta analytic_digital(strike), D.digital(den, strike), 2e-3
    end
  end

  def test_flat_smile_quantiles_match_analytic_including_wing_region
    den = D.expiry_density(flat_slices.first)
    den[:quantiles].each do |tau, q|
      assert_in_delta analytic_quantile(tau), q, analytic_quantile(tau) * 0.005
    end
    # the 1% quantile lives in the LEFT WING -> the wing lognormal must
    # have recovered the true tail
    assert den[:wing_matched][:left]
    assert den[:wing_matched][:right]
  end

  def test_quantiles_are_monotone_and_wing_mass_reported
    den = D.expiry_density(flat_slices.first)
    qs = den[:quantiles].map(&:last)
    assert_equal qs.sort, qs
    assert_operator den[:wing_mass][:left], :>, 0.0
    assert_operator den[:wing_mass][:right], :>, 0.0
    assert_operator den[:wing_mass][:left] + den[:wing_mass][:right], :<, 0.5
  end

  def test_touch_is_capped_double_digital
    den = D.expiry_density(flat_slices.first)
    strike = 120_000.0
    assert_in_delta 2.0 * D.digital(den, strike), D.touch(den, strike), 1e-12
    assert_in_delta 1.0, D.touch(den, 100_100.0), 0.2 # near-ATM touches ~always
  end

  def test_horizon_interpolates_flat_vol_exactly
    strikes = (60_000..160_000).step(5_000)
    mk = lambda do |t|
      strikes.flat_map do |strike|
        %w[C P].map { |cp| { k: strike.to_f, cp: cp, t: t, iv: 0.5, oi: 1.0, u: F } }
      end
    end
    sls = D.slices(mk.call(0.1) + mk.call(0.3))
    h = D.horizon(sls, 0.2)
    refute h[:extrapolated]
    # flat 0.5 vol: w(0.2y) = 0.25 * 0.2 = 0.05, linear interp of 0.025/0.075
    assert_in_delta 0.05, h[:w_fn].call(0.0), 0.05 * 2e-3
    assert_in_delta F, h[:forward], 1e-6
  end

  def test_horizon_beyond_last_expiry_is_flagged_extrapolated
    h = D.horizon(flat_slices, T * 4)
    assert h[:extrapolated]
    assert_in_delta W * 4, h[:w_fn].call(0.0), W * 4 * 2e-3
    refute D.horizon(flat_slices, T)[:extrapolated]
  end
end
