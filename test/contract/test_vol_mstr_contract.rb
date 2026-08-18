# frozen_string_literal: true
#
# M8-17: --json field-set contract for scripts/vol_mstr.rb, run as the real
# script offline against test/fixtures/cboe_options_mstr.json via the
# fake-transport shim. The MSTR sibling of the vol.rb contract: same
# per-tenor field set, a different underlying (CBOE MSTR chain) and top-level
# spot key (mstr_spot).
#
# FAKE_NOW = "2026-07-04T19:00:00Z" -- the same clock the vol_spread contract
# uses to keep the MSTR fixture's expiries (2026-07-17/24/31) in the future
# (13.1d / 20.1d / 27.1d away), so the recorded chain never ages out.
#
# The --json field set is a FROZEN contract from birth (Golden Rule 5): any
# additive change must update this test in the same commit.

require_relative 'contract_helper'

class TestVolMstrContract < Minitest::Test
  FAKE_NOW_STR = '2026-07-04T19:00:00Z'.freeze

  TOP_KEYS   = %w[ts mstr_spot tenors].freeze
  TENOR_KEYS = %w[tenor_d expiry_d atm_iv rr25 fly25 n_calls n_puts reason].freeze

  def mstr_env(extra = {})
    { 'FAKE_NOW' => FAKE_NOW_STR }.merge(extra)
  end

  def test_vol_mstr_json_contract
    j = run_json('scripts/vol_mstr.rb', '--json', env: mstr_env)
    assert_contract_keys TOP_KEYS, j, 'vol_mstr.rb'
    assert_equal FAKE_NOW_STR, Time.iso8601(j['ts']).iso8601 # frozen clock
    assert_kind_of Numeric, j['mstr_spot']

    assert_kind_of Array, j['tenors']
    refute_empty j['tenors']
    # DEFAULT_TARGETS 7/14/21/30/45/90 (owner rulings 2026-08-18: the surface
    # shares vol_spread's tenor paradigm; 30d kept as the standard 1-month anchor) -> six rows.
    assert_equal [7, 14, 21, 30, 45, 90], j['tenors'].map { |t| t['tenor_d'] }

    j['tenors'].each do |t|
      assert_contract_keys TENOR_KEYS, t, 'vol_mstr.rb tenors[]'
      assert_kind_of Integer, t['tenor_d']
      # fail-soft fields are nil-or-typed; reason is nil-or-String
      assert t['expiry_d'].nil? || t['expiry_d'].is_a?(Numeric)
      assert t['atm_iv'].nil?   || t['atm_iv'].is_a?(Numeric)
      assert t['rr25'].nil?     || t['rr25'].is_a?(Numeric)
      assert t['fly25'].nil?    || t['fly25'].is_a?(Numeric)
      assert_kind_of Integer, t['n_calls']
      assert_kind_of Integer, t['n_puts']
      assert t['reason'].nil?   || t['reason'].is_a?(String)
    end
  end

  def test_vol_mstr_aborts_nonzero_when_cboe_down
    _, err, st = run_script('scripts/vol_mstr.rb', '--json',
                            env: mstr_env('FAKE_HTTP_DENY' => 'delayed_quotes/options/MSTR'))
    refute st.success?, 'documented failure mode: abort, no fail-soft JSON'
    assert_match(/cboe/, err)
  end
end
