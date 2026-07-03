# frozen_string_literal: true

# Characterization tests for Btco.convert_split (extracted from
# btco.rb). USD-listing behavior is pinned here and must never change;
# the non-USD case is covered by the F-1 regression tests below it.

require_relative '../test_helper'
require_relative '../../scripts/btco/metrics'

class TestConvertSplitUsd < Minitest::Test
  def tranche(face, conv_price)
    { 'face' => face, 'conv_price' => conv_price }
  end

  def test_itm_tranche_becomes_shares_at_conversion_price
    itm, otm = Btco.convert_split([tranche(1_000_000, 100.0)], 150.0, 1.0)
    assert_close 10_000.0, itm
    assert_close 0.0, otm
  end

  def test_otm_tranche_stays_as_face
    itm, otm = Btco.convert_split([tranche(1_000_000, 100.0)], 50.0, 1.0)
    assert_close 0.0, itm
    assert_close 1_000_000.0, otm
  end

  def test_at_the_money_is_otm_strict_inequality
    itm, otm = Btco.convert_split([tranche(1_000_000, 100.0)], 100.0, 1.0)
    assert_close 0.0, itm
    assert_close 1_000_000.0, otm
  end

  def test_zero_conversion_price_goes_to_otm_bucket
    itm, otm = Btco.convert_split([tranche(500_000, 0.0)], 150.0, 1.0)
    assert_close 0.0, itm
    assert_close 500_000.0, otm
  end

  def test_mixed_tranches_split_independently
    tranches = [tranche(1_000_000, 100.0),   # ITM at 150
                tranche(2_000_000, 200.0)]   # OTM at 150
    itm, otm = Btco.convert_split(tranches, 150.0, 1.0)
    assert_close 10_000.0, itm
    assert_close 2_000_000.0, otm
  end

  def test_nil_and_empty_converts
    assert_equal [0.0, 0.0], Btco.convert_split(nil, 150.0, 1.0)
    assert_equal [0.0, 0.0], Btco.convert_split([], 150.0, 1.0)
  end
end

# F-1 regression (TOOL-REVIEW.md): face is USD, conv_price is listing ccy.
# shares = face_usd / conv_usd. The pre-fix code divided by rate twice,
# understating ITM shares by rate^2 for non-USD listings.
class TestConvertSplitFx < Minitest::Test
  def tranche(face, conv_price)
    { 'face' => face, 'conv_price' => conv_price }
  end

  def test_jpy_itm_shares_use_usd_face_over_usd_conv_price
    # rate 150 JPY/USD; conv 1500 JPY = 10 USD; px 3000 JPY -> ITM.
    # 1,000,000 USD face / 10 USD conv = 100,000 shares.
    itm, otm = Btco.convert_split([tranche(1_000_000, 1_500.0)], 3_000.0, 150.0)
    assert_close 100_000.0, itm
    assert_close 0.0, otm
  end

  def test_jpy_itm_test_compares_in_listing_ccy
    # px 1200 JPY < conv 1500 JPY -> OTM regardless of rate.
    itm, otm = Btco.convert_split([tranche(1_000_000, 1_500.0)], 1_200.0, 150.0)
    assert_close 0.0, itm
    assert_close 1_000_000.0, otm
  end

  def test_usd_unchanged_by_fix
    itm, = Btco.convert_split([tranche(1_000_000, 100.0)], 150.0, 1.0)
    assert_close 10_000.0, itm
  end
end
