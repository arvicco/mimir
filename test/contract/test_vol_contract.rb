# frozen_string_literal: true
#
# M8-1: --json field-set contract for scripts/vol.rb, run as the real
# script offline against test/fixtures/deribit_book_summary.json via the
# fake-transport shim with the clock frozen to the fixtures' recording
# moment (RECORDED_NOW, ~2026-07-04). The --json field set is a FROZEN
# contract from birth: additive changes must update these pins in the
# same commit (Golden Rule 5).

require_relative 'contract_helper'

class TestVolContract < Minitest::Test
  TOP_KEYS   = %w[ts btc_spot tenors].freeze
  TENOR_KEYS = %w[tenor_d expiry_d atm_iv rr25 fly25 n_calls n_puts reason].freeze

  def test_vol_json_contract
    j = run_json('scripts/vol.rb', '--json')
    assert_contract_keys TOP_KEYS, j, 'vol.rb'
    assert_equal RECORDED_NOW, Time.iso8601(j['ts']).iso8601 # frozen clock
    assert_kind_of Numeric, j['btc_spot']

    assert_kind_of Array, j['tenors']
    refute_empty j['tenors']
    # gex.rb requests 7/30/90 -> exactly three tenor rows, in order.
    assert_equal [7, 30, 90], j['tenors'].map { |t| t['tenor_d'] }

    j['tenors'].each do |t|
      assert_contract_keys TENOR_KEYS, t, 'vol.rb tenors[]'
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

  def test_vol_aborts_nonzero_when_deribit_down
    _, err, st = run_script('scripts/vol.rb', '--json',
                            env: { 'FAKE_HTTP_DENY' => 'deribit.com' })
    refute st.success?, 'documented failure mode: abort, no fail-soft JSON'
    assert_match(/deribit/, err)
  end
end
