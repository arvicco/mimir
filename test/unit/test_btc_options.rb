# frozen_string_literal: true

# Characterization tests for BTC::Options -- the math/parsing previously
# duplicated across gex.rb / gex_us.rb / gex_btc_combined.rb (F-14).
# Values pin current behavior exactly; M0-4/M0-5 extend coverage.

require_relative '../test_helper'
require_relative '../../lib/btc/options'

class TestBsGamma < Minitest::Test
  def test_atm_reference_value
    assert_close 0.01583350747779, BTC::Options.bs_gamma(100.0, 100.0, 0.25, 0.5), 1e-12
  end

  def test_itm_reference_value
    assert_close 0.00637718584974986, BTC::Options.bs_gamma(120.0, 100.0, 0.5, 0.6), 1e-12
  end

  def test_btc_scale_reference_value
    assert_close 2.06249330170753e-05, BTC::Options.bs_gamma(100_000.0, 110_000.0, 0.1, 0.55), 1e-15
  end

  def test_degenerate_inputs_return_zero
    assert_equal 0.0, BTC::Options.bs_gamma(100.0, 100.0, 0.0, 0.5)
    assert_equal 0.0, BTC::Options.bs_gamma(100.0, 100.0, 0.25, 0.0)
    assert_equal 0.0, BTC::Options.bs_gamma(0.0, 100.0, 0.25, 0.5)
    assert_equal 0.0, BTC::Options.bs_gamma(100.0, 0.0, 0.25, 0.5)
  end

  def test_norm_pdf_at_zero
    assert_close 0.398942280401433, BTC::Options.norm_pdf(0.0), 1e-12
  end

  def test_dealer_sign_convention
    assert_equal 1.0, BTC::Options.sign('C')
    assert_equal(-1.0, BTC::Options.sign('P'))
  end

  def test_gamma_at_uses_bs_when_iv_present_else_static
    o = { k: 100.0, t: 0.25, iv: 0.5, gp: 0.123 }
    assert_close BTC::Options.bs_gamma(100.0, 100.0, 0.25, 0.5),
                 BTC::Options.gamma_at(o, 100.0)
    assert_equal 0.123, BTC::Options.gamma_at(o.merge(iv: 0.0), 100.0)
  end

  # ---- M0-4: deeper characterization ----------------------------------

  def test_put_call_gamma_identical
    # BS gamma is cp-independent; the sign convention is applied by the
    # callers via Options.sign, never inside the greek.
    g = BTC::Options.bs_gamma(100.0, 110.0, 0.5, 0.4)
    assert_close g * BTC::Options.sign('C'), g
    assert_close g * BTC::Options.sign('P'), -g
  end

  def test_scale_invariance_gamma_halves_when_price_axis_doubles
    assert_close BTC::Options.bs_gamma(100.0, 110.0, 0.5, 0.4) / 2,
                 BTC::Options.bs_gamma(200.0, 220.0, 0.5, 0.4), 1e-15
  end

  def test_s_phi_d1_equals_k_phi_d2_identity
    s = 100.0
    k = 110.0
    sq = 0.4 * Math.sqrt(0.5)
    d1 = (Math.log(s / k) + 0.5 * 0.4 * 0.4 * 0.5) / sq
    assert_close s * BTC::Options.norm_pdf(d1),
                 k * BTC::Options.norm_pdf(d1 - sq), 1e-10
  end

  def test_deep_otm_gamma_vanishes
    assert_close 5.51105245799875e-31,
                 BTC::Options.bs_gamma(100.0, 300.0, 0.1, 0.3), 1e-40
  end

  def test_expiry_limit_gamma_zero_away_from_strike_spikes_atm
    assert_equal 0.0, BTC::Options.bs_gamma(100.0, 110.0, 1e-8, 0.5)
    assert_close 79.7884560553527, BTC::Options.bs_gamma(100.0, 100.0, 1e-8, 0.5), 1e-9
  end

  def test_gamma_peaks_near_the_money
    atm = BTC::Options.bs_gamma(100.0, 100.0, 0.25, 0.5)
    assert_operator atm, :>, BTC::Options.bs_gamma(100.0, 130.0, 0.25, 0.5)
    assert_operator atm, :>, BTC::Options.bs_gamma(100.0, 75.0, 0.25, 0.5)
  end

  def test_inst_gex_composes_sign_gamma_oi_mult_s_squared
    o = { cp: 'P', k: 100.0, t: 0.25, iv: 0.5, oi: 10.0, gp: 0.0 }
    expected = -1.0 * BTC::Options.bs_gamma(95.0, 100.0, 0.25, 0.5) *
               10.0 * 100.0 * 95.0 * 95.0 * 0.01
    assert_close expected, BTC::Options.inst_gex(o, 95.0, 100.0), 1e-9
    # default multiplier 1.0 (Deribit-style)
    assert_close expected / 100.0, BTC::Options.inst_gex(o, 95.0), 1e-9
  end

  def test_put_call_ratio_with_weights
    book = [{ cp: 'P', oi: 30.0, w: 3.0 }, { cp: 'C', oi: 60.0, w: 1.0 },
            { cp: 'C', oi: 40.0, w: 1.0 }]
    assert_close 0.3, BTC::Options.put_call_ratio(book) { |o| o[:oi] }
    assert_close 0.9, BTC::Options.put_call_ratio(book) { |o| o[:oi] * o[:w] }
    calls_only = book.reject { |o| o[:cp] == 'C' }
    assert_equal 0.0, BTC::Options.put_call_ratio(calls_only) { |o| o[:oi] }
  end
end

class TestInstrumentParsing < Minitest::Test
  def test_deribit_expiry_two_digit_day
    assert_equal Time.utc(2026, 3, 27, 8), BTC::Options.deribit_expiry('27MAR26')
  end

  def test_deribit_expiry_one_digit_day
    assert_equal Time.utc(2026, 7, 3, 8), BTC::Options.deribit_expiry('3JUL26')
  end

  def test_deribit_expiry_rejects_garbage
    assert_nil BTC::Options.deribit_expiry(nil)
    assert_nil BTC::Options.deribit_expiry('PERPETUAL')
    assert_nil BTC::Options.deribit_expiry('27XXX26')
    assert_nil BTC::Options.deribit_expiry('MAR26')
  end

  def test_parse_osi
    exp, cp, k = BTC::Options.parse_osi('IBIT260327C00100000')
    assert_equal Time.utc(2026, 3, 27, 21), exp
    assert_equal 'C', cp
    assert_close 100.0, k
  end

  def test_parse_osi_decimal_strike_and_put
    exp, cp, k = BTC::Options.parse_osi('MSTR251219P00417500')
    assert_equal Time.utc(2025, 12, 19, 21), exp
    assert_equal 'P', cp
    assert_close 417.5, k
  end

  def test_parse_osi_tolerates_spaces_and_rejects_garbage
    exp, = BTC::Options.parse_osi('IBIT 260327C00100000')
    assert_equal Time.utc(2026, 3, 27, 21), exp
    assert_nil BTC::Options.parse_osi('not-an-osi')
    assert_nil BTC::Options.parse_osi(nil)
  end

  # ---- M0-5: deeper characterization ----------------------------------

  def test_deribit_month_map_all_twelve
    %w[JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC].each_with_index do |m, i|
      assert_equal Time.utc(2026, i + 1, 15, 8),
                   BTC::Options.deribit_expiry("15#{m}26")
    end
  end

  def test_deribit_expiry_century_assumption
    assert_equal Time.utc(2099, 12, 31, 8), BTC::Options.deribit_expiry('31DEC99')
  end

  def test_deribit_expiry_malformed_day_raises_pinned_behavior
    # Pinned current behavior: pattern-valid but calendar-invalid input
    # raises (Time.utc). Upstream never emits this; a change here is a
    # behavior change, not a cleanup.
    assert_raises(ArgumentError) { BTC::Options.deribit_expiry('32MAR26') }
  end

  def test_parse_osi_small_strike_and_long_ticker
    exp, cp, k = BTC::Options.parse_osi('EZBC260116C00007500')
    assert_equal Time.utc(2026, 1, 16, 21), exp
    assert_equal 'C', cp
    assert_close 7.5, k
  end

  def test_parse_osi_rejects_lowercase_and_short_fields
    assert_nil BTC::Options.parse_osi('ibit260327C00100000')
    assert_nil BTC::Options.parse_osi('IBIT26032C00100000')   # 5-digit date
    assert_nil BTC::Options.parse_osi('IBIT260327X00100000')  # bad cp
    assert_nil BTC::Options.parse_osi('IBIT260327C0010000')   # 7-digit strike
  end
end

class TestFlipAndWalls < Minitest::Test
  def test_gamma_flip_interpolates_linear_crossing
    # net(x) = x - 103.4: exact linear interpolation recovers 103.4.
    flip = BTC::Options.gamma_flip(100.0) { |x| x - 103.4 }
    assert_close 103.4, flip, 1e-9
  end

  def test_gamma_flip_nil_when_no_crossing
    assert_nil BTC::Options.gamma_flip(100.0) { |x| x + 1000.0 }
  end

  def test_walls_max_min_within_band
    profile = { 80.0 => -5.0, 95.0 => -10.0, 105.0 => 12.0, 128.0 => 20.0,
                200.0 => 99.0 } # 200 is outside +-30% of spot 100
    near, call_wall, put_wall = BTC::Options.walls(profile, 100.0)
    assert_equal 4, near.size
    assert_equal [128.0, 20.0], call_wall
    assert_equal [95.0, -10.0], put_wall
  end
end

# M8-1: Black-Scholes delta and the standard-normal CDF that backs it.
class TestBsDelta < Minitest::Test
  def test_norm_cdf_at_zero_is_exactly_half
    assert_equal 0.5, BTC::Options.norm_cdf(0.0)
  end

  def test_norm_cdf_symmetry_sums_to_one
    [-2.7, -0.3, 0.1, 1.4, 3.0].each do |x|
      assert_close 1.0, BTC::Options.norm_cdf(x) + BTC::Options.norm_cdf(-x), 1e-15
    end
  end

  # N(0.1) = 0.5398278372770290 (standard normal table / erf identity).
  def test_norm_cdf_reference_value
    assert_close 0.5398278372770290, BTC::Options.norm_cdf(0.1), 1e-15
  end

  # ATM call: s=k, t=1, v=0.2 -> d1 = 0.5*v^2*t / (v*sqrt(t)) = 0.1, so
  # the call delta is exactly N(0.1) (independently pinned above).
  def test_atm_call_delta_reference_value
    assert_close 0.5398278372770290, BTC::Options.bs_delta(100.0, 100.0, 1.0, 0.2, 'C'), 1e-12
  end

  def test_deep_itm_call_delta_approaches_one
    assert_close 1.0, BTC::Options.bs_delta(100_000.0, 1_000.0, 1.0, 0.5, 'C'), 1e-6
  end

  def test_deep_otm_call_delta_approaches_zero
    assert_close 0.0, BTC::Options.bs_delta(1_000.0, 100_000.0, 1.0, 0.5, 'C'), 1e-6
  end

  def test_deep_itm_put_delta_approaches_minus_one
    assert_close(-1.0, BTC::Options.bs_delta(1_000.0, 100_000.0, 1.0, 0.5, 'P'), 1e-6)
  end

  def test_put_delta_is_negative_atm
    d = BTC::Options.bs_delta(100.0, 100.0, 1.0, 0.2, 'P')
    assert_operator d, :<, 0.0
  end

  # Put-call parity of deltas (r = 0): call_delta - put_delta == 1 exactly.
  def test_call_minus_put_delta_is_one
    args = [65_000.0, 70_000.0, 0.25, 0.55]
    c = BTC::Options.bs_delta(*args, 'C')
    p = BTC::Options.bs_delta(*args, 'P')
    assert_close 1.0, c - p, 1e-15
  end

  def test_degenerate_inputs_return_zero
    assert_equal 0.0, BTC::Options.bs_delta(100.0, 100.0, 0.0, 0.5, 'C')
    assert_equal 0.0, BTC::Options.bs_delta(100.0, 100.0, 0.25, 0.0, 'P')
    assert_equal 0.0, BTC::Options.bs_delta(0.0, 100.0, 0.25, 0.5, 'C')
    assert_equal 0.0, BTC::Options.bs_delta(100.0, 0.0, 0.25, 0.5, 'C')
  end
end
