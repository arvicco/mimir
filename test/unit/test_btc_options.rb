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
