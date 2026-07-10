# frozen_string_literal: true
#
# M8-5: --json field-set contract for scripts/vol_spread.rb.
#
# FAKE_NOW = "2026-07-04T19:00:00Z" -- chosen to keep BOTH fixtures' expiries
# in the future simultaneously:
#   * MSTR fixture (recorded 2026-07-10 ~21:10 UTC): expiries at 2026-07-17,
#     07-24, and 07-31 (all at 21:00 UTC per OSI convention). At 07-04T19:00Z
#     these are 13.1d, 20.1d, and 27.1d away -- all comfortably in the future.
#   * Deribit fixture (recorded 2026-07-04 18:27Z): expiries are 25JUN27
#     (355d future), 25SEP26 (83d future), and 5JUL26 (filtered out; OI=0).
#     Deribit options settle at 08:00 UTC, so no same-day conflict at 19:00Z.
#   This overrides RECORDED_NOW (2026-07-04T18:27:00Z) by 33 minutes to land
#   both fixture sets in the future under one frozen clock.
#
# The --json field set is a FROZEN contract from birth (Golden Rule 5):
# any additive change must update this test in the same commit.

require_relative 'contract_helper'

class TestVolSpreadContract < Minitest::Test
  # See file header for clock-choice rationale.
  FAKE_NOW_STR = '2026-07-04T19:00:00Z'.freeze

  TOP_KEYS   = %w[ts mstr_spot btc_spot tenors].freeze
  TENOR_KEYS = %w[tenor_d mstr btc spread_atm].freeze
  LEG_KEYS   = %w[expiry_d atm_iv reason].freeze

  # Base env for all vol_spread tests: freeze the clock to FAKE_NOW_STR.
  # Callers may merge additional knobs (e.g. FAKE_HTTP_DENY).
  def spread_env(extra = {})
    { 'FAKE_NOW' => FAKE_NOW_STR }.merge(extra)
  end

  # ---- normal run: both legs alive ------------------------------------------

  def test_vol_spread_json_contract
    j = run_json('scripts/vol_spread.rb', '--json', env: spread_env)

    assert_contract_keys TOP_KEYS, j, 'vol_spread.rb'
    assert_equal FAKE_NOW_STR, Time.iso8601(j['ts']).iso8601 # frozen clock
    assert j['mstr_spot'].nil? || j['mstr_spot'].is_a?(Numeric)
    assert j['btc_spot'].nil?  || j['btc_spot'].is_a?(Numeric)

    assert_kind_of Array, j['tenors']
    assert_equal [7, 30, 90], j['tenors'].map { |t| t['tenor_d'] }

    j['tenors'].each_with_index do |t, i|
      assert_contract_keys TENOR_KEYS, t, "vol_spread.rb tenors[#{i}]"
      assert_kind_of Integer, t['tenor_d']
      assert t['spread_atm'].nil? || t['spread_atm'].is_a?(Numeric)

      %w[mstr btc].each do |leg|
        assert_contract_keys LEG_KEYS, t[leg],
                             "vol_spread.rb tenors[#{i}].#{leg}"
        assert t[leg]['expiry_d'].nil? || t[leg]['expiry_d'].is_a?(Numeric)
        assert t[leg]['atm_iv'].nil?   || t[leg]['atm_iv'].is_a?(Numeric)
        assert t[leg]['reason'].nil?   || t[leg]['reason'].is_a?(String)
      end
    end
  end

  # ---- fail-soft 1: CBOE MSTR denied -> MSTR leg null, BTC alive, exit 0 ---

  def test_cboe_mstr_down_mstr_null_btc_alive
    out, _err, st = run_script('scripts/vol_spread.rb', '--json',
                               env: spread_env(
                                 'FAKE_HTTP_DENY' => 'delayed_quotes/options/MSTR'
                               ))
    assert st.success?,
           "expected exit 0 when CBOE is down, got #{st.exitstatus}"
    j = JSON.parse(out)

    assert_nil j['mstr_spot'], 'mstr_spot should be null when CBOE is down'
    assert_kind_of Numeric, j['btc_spot']

    j['tenors'].each_with_index do |t, i|
      assert_nil  t['mstr']['atm_iv'],
                  "tenors[#{i}].mstr.atm_iv should be null when CBOE is down"
      assert_kind_of String, t['mstr']['reason']

      # BTC leg alive: Deribit fixture has 25JUN27 with 4C/4P (>= MIN_SIDE);
      # reason must be nil (no thin-tenor or failure reason).
      assert_nil t['btc']['reason'],
                 "tenors[#{i}].btc.reason should be nil when BTC is alive"
      assert_nil t['spread_atm'],
                 "tenors[#{i}].spread_atm should be nil with one leg down"
    end
  end

  # ---- fail-soft 2: Deribit denied -> BTC leg null, MSTR alive, exit 0 -----

  def test_deribit_down_btc_null_mstr_alive
    out, _err, st = run_script('scripts/vol_spread.rb', '--json',
                               env: spread_env('FAKE_HTTP_DENY' => 'deribit.com'))
    assert st.success?,
           "expected exit 0 when Deribit is down, got #{st.exitstatus}"
    j = JSON.parse(out)

    assert_nil j['btc_spot'], 'btc_spot should be null when Deribit is down'
    assert_kind_of Numeric, j['mstr_spot']

    j['tenors'].each_with_index do |t, i|
      assert_nil  t['btc']['atm_iv'],
                  "tenors[#{i}].btc.atm_iv should be null when Deribit is down"
      assert_kind_of String, t['btc']['reason']

      # MSTR leg alive: fixture has 3 expiries with 8C/8P each (>= MIN_SIDE).
      assert_nil t['mstr']['reason'],
                 "tenors[#{i}].mstr.reason should be nil when MSTR is alive"
      assert_nil t['spread_atm'],
                 "tenors[#{i}].spread_atm should be nil with one leg down"
    end
  end

  # ---- fail-soft 3: both denied -> nonzero exit, no valid JSON ---------------

  def test_both_down_nonzero_exit
    _out, _err, st = run_script(
      'scripts/vol_spread.rb', '--json',
      env: spread_env(
        'FAKE_HTTP_DENY' => 'deribit.com,delayed_quotes/options/MSTR'
      )
    )
    refute st.success?,
           'expected nonzero exit when both BTC and MSTR legs fail'
  end
end
