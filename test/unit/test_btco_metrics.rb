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

# M0-7: pin the full per-company row math (CEBE / mNAV / netNAV /
# EV/BTC / leverage / staleness) on a hand-built synthetic universe,
# every branch exercised. BTC spot fixed at 100_000 USD.
class TestCompanyRow < Minitest::Test
  NOW = Time.utc(2026, 7, 4)
  BTC_PX = 100_000.0

  def base_company
    { 'ticker' => 'TST', 'ccy' => 'USD',
      'btc' => 100.0, 'btc_as_of' => '2026-06-01',
      'shares_basic' => 1_000_000, 'shares_diluted' => 1_200_000,
      'debt_face' => 0, 'pref_liq' => 0, 'converts' => [],
      'placeholder' => false }
  end

  def row(over = {})
    Btco.company_row(base_company.merge(over), 50.0, 1.0, BTC_PX, NOW)
  end

  def test_unlevered_baseline
    r = row
    # nav 10M; mcap 50 * 1M basic = 50M; sats/shD = 100e8/1.2M
    assert_close 10_000_000.0, r[:nav]
    assert_close 5.0, r[:mnav]
    assert_close 5.0, r[:netm]           # no senior -> netNAV == mNAV
    assert_close 8_333.333333, r[:sats_d], 1e-4
    assert_close 8_333.333333, r[:cebe], 1e-4 # no senior, no ITM shares
    assert_close 500_000.0, r[:ev]       # (50M + 0) / 100 BTC
    assert_close 0.0, r[:lev]
    refute r[:stale]
  end

  def test_straight_debt_nets_against_cebe_and_levers
    r = row('debt_face' => 4_000_000)
    assert_close 5.0, r[:mnav]                    # mNAV ignores senior
    assert_close 50.0 / 6.0, r[:netm], 1e-9       # 50M / (10M - 4M)
    assert_close 6_000_000.0 / BTC_PX * 1e8 / 1_200_000, r[:cebe], 1e-6
    assert_close 0.4, r[:lev]
    assert_close 540_000.0, r[:ev]                # (50M + 4M) / 100
  end

  def test_itm_convert_adds_shares_drops_face
    # conv 25 < px 50 -> ITM: 1M face -> 40k shares; senior stays 0.
    r = row('converts' => [{ 'face' => 1_000_000, 'conv_price' => 25.0 }])
    assert_close 0.0, r[:lev]
    assert_close 100.0 * 1e8 / 1_240_000, r[:cebe], 1e-6 # diluted + ITM shares
    assert_close 5.0, r[:netm] # face gone from the stack
  end

  def test_otm_convert_is_senior_debt
    r = row('converts' => [{ 'face' => 1_000_000, 'conv_price' => 75.0 }])
    assert_close 50.0 / 9.0, r[:netm], 1e-9 # 50M / (10M - 1M)
    assert_close 0.1, r[:lev]
    assert_close 9_000_000.0 / BTC_PX * 1e8 / 1_200_000, r[:cebe], 1e-6
  end

  def test_senior_exceeding_nav_negative_equity
    r = row('debt_face' => 12_000_000)
    assert_nil r[:netm]           # negative net NAV -> no meaningful multiple
    assert_close 0.0, r[:cebe]    # clamped at zero, not negative
    assert_close 1.2, r[:lev]
  end

  def test_zero_btc_company
    r = row('btc' => 0)
    assert_nil r[:mnav]
    assert_nil r[:ev]
    assert_close 0.0, r[:lev]
    assert_close 0.0, r[:sats_d]
  end

  def test_missing_fields_default_to_zero
    r = Btco.company_row({ 'ticker' => 'BARE' }, 50.0, 1.0, BTC_PX, NOW)
    assert_nil r[:mnav]
    assert_equal 'USD', r[:ccy]
    assert_nil r[:stale] # no btc_as_of -> stale nil (falsy), pinned as-is
  end

  def test_diluted_floor_is_basic_count
    r = row('shares_diluted' => 500_000) # below basic 1M -> floored
    assert_close 100.0 * 1e8 / 1_000_000, r[:sats_d], 1e-6
  end

  def test_staleness_after_120_days
    assert row('btc_as_of' => '2026-01-01')[:stale]
    refute row('btc_as_of' => '2026-06-01')[:stale]
  end

  def test_non_usd_listing_converts_mcap_only
    # JPY: px 7500 JPY, rate 150 -> px_usd 50; same numbers as baseline.
    r = Btco.company_row(base_company.merge('ccy' => 'JPY'), 7_500.0, 150.0,
                         BTC_PX, NOW)
    assert_close 5.0, r[:mnav]
    assert_equal 'JPY', r[:ccy]
    assert_close 7_500.0, r[:px] # row keeps the listing-ccy price
  end
end
