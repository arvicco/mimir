# frozen_string_literal: true
#
# M8-4: --json field-set contract for scripts/basis.rb, run as the real
# script offline against test/fixtures/deribit_futures.json (basis leg) and
# test/fixtures/coinglass_funding_oi.json (funding leg) via the fake-transport
# shim, clock frozen to RECORDED_NOW (~2026-07-04) so the fixture's future
# expiries stay in the future. The --json field set is a FROZEN contract from
# birth: additive changes must update these pins in the same commit
# (Golden Rule 5). Every field is always present, null where unavailable.

require_relative 'contract_helper'

class TestBasisContract < Minitest::Test
  TOP_KEYS     = %w[ts spot basis funding].freeze
  BASIS_KEYS   = %w[tenors perp_premium_pct reason].freeze
  TENOR_KEYS   = %w[instrument days mark basis_ann_pct].freeze
  FUNDING_KEYS = %w[latest_pct d1_pct d7_pct d30_pct points reason].freeze

  KEY = 'contract-test-key' # funding leg needs A key present (value unused)

  def test_basis_json_contract
    j = run_json('scripts/basis.rb', '--json', env: { 'COINGLASS_API_KEY' => KEY })
    assert_contract_keys TOP_KEYS, j, 'basis.rb'
    assert_equal RECORDED_NOW, Time.iso8601(j['ts']).iso8601 # frozen clock
    assert_kind_of Numeric, j['spot'] # both legs healthy here

    # basis leg
    b = j['basis']
    assert_contract_keys BASIS_KEYS, b, 'basis.rb basis'
    assert_nil b['reason'] # healthy
    assert_kind_of Numeric, b['perp_premium_pct']
    assert_kind_of Array, b['tenors']
    refute_empty b['tenors']
    # sorted by expiry (soonest first)
    days = b['tenors'].map { |t| t['days'] }
    assert_equal days.sort, days
    b['tenors'].each do |t|
      assert_contract_keys TENOR_KEYS, t, 'basis.rb tenors[]'
      assert_kind_of String, t['instrument']
      assert_kind_of Numeric, t['days']
      assert t['days'] > 0
      assert_kind_of Numeric, t['mark']
      assert t['basis_ann_pct'].nil? || t['basis_ann_pct'].is_a?(Numeric)
    end

    # funding leg
    f = j['funding']
    assert_contract_keys FUNDING_KEYS, f, 'basis.rb funding'
    assert_nil f['reason'] # healthy
    assert_equal 30, f['points'] # fixture carries 30 OHLC rows
    %w[latest_pct d1_pct d7_pct d30_pct].each do |k|
      assert_kind_of Numeric, f[k], "funding #{k}"
    end
  end

  # Deribit down => basis leg nulled with a reason, funding leg still alive,
  # exit 0. (Independent legs.)
  def test_basis_fail_soft_deribit_down
    j = run_json('scripts/basis.rb', '--json',
                 env: { 'FAKE_HTTP_DENY' => 'deribit.com', 'COINGLASS_API_KEY' => KEY })
    assert_contract_keys TOP_KEYS, j, 'basis.rb (deribit down)'
    assert_nil j['spot']
    b = j['basis']
    assert_empty b['tenors']
    assert_nil b['perp_premium_pct']
    assert_kind_of String, b['reason']
    assert_match(/deribit/, b['reason'])
    # funding still populated
    f = j['funding']
    assert_nil f['reason']
    assert_equal 30, f['points']
    assert_kind_of Numeric, f['latest_pct']
  end

  # Coinglass down => funding leg nulled, basis leg alive, exit 0.
  def test_basis_fail_soft_coinglass_down
    j = run_json('scripts/basis.rb', '--json',
                 env: { 'FAKE_HTTP_DENY' => 'coinglass', 'COINGLASS_API_KEY' => KEY })
    assert_contract_keys TOP_KEYS, j, 'basis.rb (coinglass down)'
    f = j['funding']
    assert_contract_keys FUNDING_KEYS, f, 'basis.rb funding (down)'
    assert_equal 0, f['points']
    %w[latest_pct d1_pct d7_pct d30_pct].each { |k| assert_nil f[k] }
    assert_kind_of String, f['reason']
    assert_match(/coinglass/, f['reason'])
    # basis still populated
    assert_kind_of Numeric, j['spot']
    refute_empty j['basis']['tenors']
    assert_nil j['basis']['reason']
  end

  # No COINGLASS_API_KEY => funding leg nulled (seam raises), basis alive,
  # exit 0.
  def test_basis_fail_soft_no_coinglass_key
    j = run_json('scripts/basis.rb', '--json',
                 env: { 'COINGLASS_API_KEY' => nil })
    f = j['funding']
    assert_equal 0, f['points']
    assert_nil f['latest_pct']
    assert_kind_of String, f['reason']
    # basis still populated
    assert_kind_of Numeric, j['spot']
    refute_empty j['basis']['tenors']
  end
end
