# frozen_string_literal: true
#
# M8-3: --json field-set contract for scripts/gex_check.rb (the options-
# positioning cross-check), run as the real script offline against the
# recorded fixtures via the fake_transport shim. RUBYOPT carries the shim
# into the child gex.rb subprocess too, so BOTH our view and the Coinglass
# view are served from fixtures with no network.
#
# Field sets are frozen from birth (Golden Rule 5): every field is always
# present, null where an input was unavailable. The fail-soft cases pin
# the advisory contract -- Coinglass down / no key => theirs & deltas
# null + a reason, EXIT 0, never breaking anything.

require_relative 'contract_helper'

class TestGexCheckContract < Minitest::Test
  TOP_KEYS     = %w[ts spot ours theirs deltas reason].freeze
  OURS_KEYS    = %w[flip cw pw].freeze
  THEIRS_KEYS  = %w[nearest oi_weighted_max_pain expiries deribit_oi_share].freeze
  NEAREST_KEYS = %w[date max_pain].freeze
  DELTA_KEYS   = %w[nearest_vs_pw_pct nearest_vs_cw_pct
                    nearest_vs_spot_pct oiw_vs_flip_pct].freeze

  # A cross-check run needs the key present (read through the seam); the
  # fake transport ignores its value and serves the recorded fixtures.
  KEYED = { 'COINGLASS_API_KEY' => 'test-key' }.freeze

  def test_json_contract_success
    j = run_json('scripts/gex_check.rb', '--json', env: KEYED)
    assert_contract_keys TOP_KEYS, j, 'gex_check.rb'

    assert_equal RECORDED_NOW, Time.iso8601(j['ts']).iso8601 # frozen clock
    assert_kind_of Numeric, j['spot']
    assert_nil j['reason'], 'full success => reason null'

    assert_contract_keys OURS_KEYS, j['ours'], 'ours'
    assert_kind_of Integer, j['ours']['cw']
    assert_kind_of Integer, j['ours']['pw']
    assert j['ours']['flip'].nil? || j['ours']['flip'].is_a?(Integer)

    assert_contract_keys THEIRS_KEYS, j['theirs'], 'theirs'
    assert_contract_keys NEAREST_KEYS, j['theirs']['nearest'], 'theirs.nearest'
    # Fixture expiries (2026-07-11..14) are all future vs the frozen clock,
    # so the nearest deterministically resolves to the soonest, 07-11.
    assert_equal '2026-07-11', j['theirs']['nearest']['date']
    assert_kind_of Numeric, j['theirs']['nearest']['max_pain']
    assert_kind_of Numeric, j['theirs']['oi_weighted_max_pain']
    assert_kind_of Integer, j['theirs']['expiries']
    assert_kind_of Numeric, j['theirs']['deribit_oi_share']

    assert_contract_keys DELTA_KEYS, j['deltas'], 'deltas'
    # nearest-vs-{pw,cw,spot} always computable here (our walls present);
    # oiw_vs_flip is null because this board has no gamma flip in +/-30%.
    assert_kind_of Numeric, j['deltas']['nearest_vs_pw_pct']
    assert_kind_of Numeric, j['deltas']['nearest_vs_cw_pct']
    assert_kind_of Numeric, j['deltas']['nearest_vs_spot_pct']
    assert_nil j['deltas']['oiw_vs_flip_pct']
  end

  # Coinglass denied at the transport: advisory check nulls theirs/deltas,
  # explains itself, and STILL exits 0 (our own gex leg is untouched).
  def test_fail_soft_coinglass_down
    out, err, st = run_script('scripts/gex_check.rb', '--json',
                              env: KEYED.merge('FAKE_HTTP_DENY' => 'coinglass'))
    assert st.success?, "advisory check must exit 0: #{err}"
    j = JSON.parse(out)
    assert_contract_keys TOP_KEYS, j, 'gex_check.rb (coinglass down)'
    assert_nil j['theirs']
    assert_nil j['deltas']
    assert_kind_of String, j['reason']
    assert_match(/coinglass/i, j['reason'])
    # our own view still resolves from the deribit fixture
    assert_contract_keys OURS_KEYS, j['ours'], 'ours (coinglass down)'
  end

  # No COINGLASS_API_KEY: same shape, reason names the key, exit 0.
  def test_fail_soft_missing_key
    out, err, st = run_script('scripts/gex_check.rb', '--json',
                              env: { 'COINGLASS_API_KEY' => nil })
    assert st.success?, "missing key must exit 0: #{err}"
    j = JSON.parse(out)
    assert_contract_keys TOP_KEYS, j, 'gex_check.rb (no key)'
    assert_nil j['theirs']
    assert_nil j['deltas']
    assert_match(/COINGLASS_API_KEY/, j['reason'])
  end
end
