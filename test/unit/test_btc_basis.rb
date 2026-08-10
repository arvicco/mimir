# frozen_string_literal: true
#
# M8-4: exact-value unit tests for BTC::Basis pure math (annualized basis,
# perpetual premium, trailing means). No IO, no fixtures -- clean synthetic
# inputs chosen so the arithmetic is verifiable by hand.

require 'minitest/autorun'
require_relative '../../lib/btc/basis'

class TestBtcBasis < Minitest::Test
  def test_annualized_basis_full_year
    # 10% rich over exactly one Julian year annualizes to 10%.
    assert_in_delta 10.0, BTC::Basis.annualized_basis_pct(110.0, 100.0, 365.25), 1e-9
  end

  def test_annualized_basis_half_year_doubles
    # 5% rich over half a year annualizes to 10%.
    assert_in_delta 10.0, BTC::Basis.annualized_basis_pct(105.0, 100.0, 182.625), 1e-9
  end

  def test_annualized_basis_backwardation_negative
    assert_in_delta(-10.0, BTC::Basis.annualized_basis_pct(90.0, 100.0, 365.25), 1e-9)
  end

  def test_annualized_basis_flat_is_zero
    assert_in_delta 0.0, BTC::Basis.annualized_basis_pct(100.0, 100.0, 30.0), 1e-9
  end

  def test_annualized_basis_guards
    assert_nil BTC::Basis.annualized_basis_pct(100.0, 0.0, 30.0)
    assert_nil BTC::Basis.annualized_basis_pct(100.0, -5.0, 30.0)
    assert_nil BTC::Basis.annualized_basis_pct(100.0, 100.0, 0.0)
    assert_nil BTC::Basis.annualized_basis_pct(100.0, 100.0, -3.0)
    assert_nil BTC::Basis.annualized_basis_pct(100.0, nil, 30.0)
    assert_nil BTC::Basis.annualized_basis_pct(100.0, 100.0, nil)
  end

  def test_perp_premium
    assert_in_delta 1.0, BTC::Basis.perp_premium_pct(101.0, 100.0), 1e-9
    assert_in_delta 0.0, BTC::Basis.perp_premium_pct(100.0, 100.0), 1e-9
    assert_in_delta(-0.5, BTC::Basis.perp_premium_pct(99.5, 100.0), 1e-9)
  end

  def test_perp_premium_guards
    assert_nil BTC::Basis.perp_premium_pct(100.0, 0.0)
    assert_nil BTC::Basis.perp_premium_pct(100.0, nil)
  end

  def test_trailing_mean_last_n
    assert_in_delta 3.0, BTC::Basis.trailing_mean([1.0, 2.0, 3.0, 4.0], 3), 1e-9
  end

  def test_trailing_mean_fewer_than_n_uses_all
    assert_in_delta 1.5, BTC::Basis.trailing_mean([1.0, 2.0], 5), 1e-9
  end

  def test_trailing_mean_single_window
    assert_in_delta 4.0, BTC::Basis.trailing_mean([1.0, 2.0, 3.0, 4.0], 1), 1e-9
  end

  def test_trailing_mean_empty_is_nil
    assert_nil BTC::Basis.trailing_mean([], 3)
  end
end
