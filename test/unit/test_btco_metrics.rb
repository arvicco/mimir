# frozen_string_literal: true

# Characterization tests for BtcoMetrics.convert_split (extracted from
# btco.rb). USD-listing behavior is pinned here and must never change;
# the non-USD case is covered by the F-1 regression tests below it.

require_relative '../test_helper'
require_relative '../../scripts/btco/metrics'

class TestConvertSplitUsd < Minitest::Test
  def tranche(face, conv_price)
    { 'face' => face, 'conv_price' => conv_price }
  end

  def test_itm_tranche_becomes_shares_at_conversion_price
    itm, otm = BtcoMetrics.convert_split([tranche(1_000_000, 100.0)], 150.0, 1.0)
    assert_close 10_000.0, itm
    assert_close 0.0, otm
  end

  def test_otm_tranche_stays_as_face
    itm, otm = BtcoMetrics.convert_split([tranche(1_000_000, 100.0)], 50.0, 1.0)
    assert_close 0.0, itm
    assert_close 1_000_000.0, otm
  end

  def test_at_the_money_is_otm_strict_inequality
    itm, otm = BtcoMetrics.convert_split([tranche(1_000_000, 100.0)], 100.0, 1.0)
    assert_close 0.0, itm
    assert_close 1_000_000.0, otm
  end

  def test_zero_conversion_price_goes_to_otm_bucket
    itm, otm = BtcoMetrics.convert_split([tranche(500_000, 0.0)], 150.0, 1.0)
    assert_close 0.0, itm
    assert_close 500_000.0, otm
  end

  def test_mixed_tranches_split_independently
    tranches = [tranche(1_000_000, 100.0),   # ITM at 150
                tranche(2_000_000, 200.0)]   # OTM at 150
    itm, otm = BtcoMetrics.convert_split(tranches, 150.0, 1.0)
    assert_close 10_000.0, itm
    assert_close 2_000_000.0, otm
  end

  def test_nil_and_empty_converts
    assert_equal [0.0, 0.0], BtcoMetrics.convert_split(nil, 150.0, 1.0)
    assert_equal [0.0, 0.0], BtcoMetrics.convert_split([], 150.0, 1.0)
  end
end
