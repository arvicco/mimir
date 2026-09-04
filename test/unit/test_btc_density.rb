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
