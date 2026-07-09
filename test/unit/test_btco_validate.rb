# frozen_string_literal: true
#
# M7-15: Btco::Validate -- the objective per-ticker reconciliation math.
# All offline: the recorded published payload (btco_latest_payload.json,
# 2026-07-09 KV read) and the trimmed StrategyTracker feed are the two
# real fixtures; the universe entries are synthetic stubs pinned to the
# recording day's values. The reconcile invariant under test: our mNAV
# and the tracker's are the same formula, so the four input factors must
# multiply to the observed ratio (residual ~1) -- and the dominant
# factor NAMES the divergent input (for the recorded day: MSTR's share
# count, Apr cover 350.4M vs tracker 371.6M).

require_relative '../test_helper'
require 'json'
require_relative '../../scripts/btco/validate_core'

class TestBtcoValidate < Minitest::Test
  PAYLOAD = JSON.parse(File.read(File.expand_path('../fixtures/btco_latest_payload.json',
                                                  __dir__)))['payload']
  TRACKER = JSON.parse(File.read(File.expand_path('../fixtures/strategytracker_treasury.json',
                                                  __dir__)))['companies']

  MSTR = { 'ticker' => 'MSTR', 'name' => 'Strategy', 'stooq' => 'mstr.us',
           'btc' => 843_775, 'btc_as_of' => '2026-07-05',
           'shares_basic' => 350_447_872, 'placeholder' => false }.freeze

  # ---- our_view -----------------------------------------------------------

  def test_our_view_joins_payload_row_with_universe_shares
    v = Btco::Validate.our_view(PAYLOAD, MSTR)
    assert_in_delta 94.53, v['px']
    assert_in_delta 843_775.0, v['btc']
    assert_in_delta 0.629, v['mnav']
    assert_in_delta 62_464.0, v['btc_px']
    assert_equal 350_447_872, v['shares']
    assert_equal false, v['stale']
  end

  def test_our_view_nil_for_company_without_row
    v = Btco::Validate.our_view(PAYLOAD, { 'ticker' => '3350' })
    assert_nil v, '3350 has no dashboard row (no price source) -> nil'
  end

  # ---- tracker_view -------------------------------------------------------

  def test_tracker_view_resolves_exchange_qualified_keys
    tv = Btco::Validate.tracker_view(TRACKER, 'MSTR')
    assert_equal 'MSTR', tv['key']
    assert_in_delta 0.6828634, tv['mnav_basic'], 1e-6
    assert_equal 371_614_000, tv['shares']
    assert_equal '2026-07-06', tv['shares_as_of']

    tokyo = Btco::Validate.tracker_view(TRACKER, '3350')
    assert_equal '3350.T', tokyo['key']
    assert_in_delta 43_000.0, tokyo['btc']
  end

  def test_tracker_view_nil_for_unlisted_company
    assert_nil Btco::Validate.tracker_view(TRACKER, 'XXI')
    assert_nil Btco::Validate.tracker_view(nil, 'MSTR')
  end

  # ---- reconcile: the factor decomposition invariant ----------------------

  def test_reconcile_factors_multiply_to_the_actual_ratio
    ours = Btco::Validate.our_view(PAYLOAD, MSTR)
    ext  = Btco::Validate.tracker_view(TRACKER, 'MSTR')
    rec  = Btco::Validate.reconcile(ours, ext)

    f = rec['factors']
    assert_in_delta 94.53 / 97.36,                    f['px'],     1e-9
    assert_in_delta 350_447_872.0 / 371_614_000,      f['shares'], 1e-9
    assert_in_delta 1.0,                              f['btc'],    1e-9
    assert_in_delta 62_793.13 / 62_464,               f['btc_px'], 1e-9

    # the invariant: same formula both sides -> residual ~ 1 (definitions
    # agree; mnav rounding in the payload is the only slack)
    assert_in_delta 1.0, rec['residual'], 0.02
    # the recorded day's divergence is DRIVEN by the share count
    assert_equal 'shares', rec['dominant']
    assert_in_delta ours['mnav'] / ext['mnav_basic'], rec['actual_ratio'], 1e-9
  end

  def test_reconcile_nil_without_both_mnavs
    assert_nil Btco::Validate.reconcile(nil, {})
    assert_nil Btco::Validate.reconcile({ 'mnav' => 0.6 }, { 'mnav_basic' => nil })
  end

  def test_reconcile_survives_missing_inputs_as_nil_factors
    ours = { 'mnav' => 0.6, 'px' => 10.0, 'shares' => nil, 'btc' => 100.0, 'btc_px' => 60_000.0 }
    ext  = { 'mnav_basic' => 0.65, 'px' => 10.0, 'shares' => 500, 'btc' => 100.0,
             'btc_px' => 60_000.0 }
    rec = Btco::Validate.reconcile(ours, ext)
    assert_nil rec['factors']['shares']
    assert_in_delta 1.0, rec['explained_ratio'], 1e-9, 'known factors all 1'
  end

  # ---- needs: plain-words to-do lines --------------------------------------

  def test_needs_missing_row_names_the_price_source
    co = { 'ticker' => '3350', 'stooq' => '3350.jp', 'btc' => 43_000 }
    lines = Btco::Validate.needs(co, nil, {}, nil)
    assert(lines.any? { |l| l.include?('NOT ON THE DASHBOARD') && l.include?('3350.jp') })
  end

  def test_needs_placeholder_line
    co = { 'ticker' => 'XXI', 'btc' => 43_514, 'shares_basic' => 346_000_000,
           'placeholder' => true }
    ours = { 'stale' => false }
    lines = Btco::Validate.needs(co, ours, { 'a' => 43_514, 'b' => 43_514 }, nil)
    assert(lines.any? { |l| l.include?('placeholder flag set') })
    refute(lines.any? { |l| l.include?('BTC count off') }, 'refs concur -> no btc line')
  end

  def test_needs_btc_divergent_vs_every_ref
    co = { 'ticker' => 'NAKA', 'btc' => 5_342, 'shares_basic' => 690_018_254 }
    lines = Btco::Validate.needs(co, { 'stale' => true, 'btc_as_of' => '2025-12-31' },
                                 { 'bitcointreasuries.net' => 4_467, 'coingecko' => 4_467 }, nil)
    assert(lines.any? { |l| l.include?('BTC count off vs EVERY ref') && l.include?('--ticker NAKA') })
    assert(lines.any? { |l| l.include?('older than 120d') })
  end

  def test_needs_null_shares_line
    co = { 'ticker' => 'BLSH', 'btc' => 24_000, 'shares_basic' => nil }
    lines = Btco::Validate.needs(co, { 'stale' => false }, {}, nil)
    assert(lines.any? { |l| l.include?('shares unknown') && l.include?('--ticker BLSH') })
  end

  def test_needs_stale_share_count_vs_tracker
    co = { 'ticker' => 'MSTR', 'btc' => 843_775, 'shares_basic' => 350_447_872 }
    tracker = { 'shares' => 371_614_000, 'shares_as_of' => '2026-07-06' }
    lines = Btco::Validate.needs(co, { 'stale' => false }, {}, tracker)
    assert(lines.any? { |l| l.include?('share count stale') && l.include?('371,614,000') })
  end

  def test_needs_empty_when_everything_agrees
    co = { 'ticker' => 'ASST', 'btc' => 19_864, 'shares_basic' => 82_725_831 }
    ours = { 'stale' => false }
    lines = Btco::Validate.needs(co, ours, { 'coingecko' => 19_864 }, nil)
    assert_empty lines
  end
end
