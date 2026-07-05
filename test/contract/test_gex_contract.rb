# frozen_string_literal: true
#
# M1-7: --json / --tmux field-set contracts for the gex family
# (gex.rb, gex_us.rb single + multi shapes, gex_btc_combined.rb),
# running the real scripts offline against recorded fixtures. Field
# sets are frozen contracts: additive changes must update these pins
# in the same commit.

require_relative 'contract_helper'
require_relative '../../lib/btc/options'

class TestGexContract < Minitest::Test
  GEX_KEYS = %w[ccy spot ts net_gex_usd_per_1pct regime gamma_flip
                call_wall put_wall put_call_oi instruments profile].freeze
  GEX_US_KEYS = %w[ticker spot ts net_gex_usd_per_1pct regime gamma_flip
                   gamma_flip_btc call_wall put_wall put_call_oi
                   instruments profile].freeze
  COMBINED_KEYS = %w[ts btc_spot bin venues combined profile profiles].freeze
  VENUE_KEYS    = %w[name net_gex_usd_per_1pct instruments put_call_oi_btc].freeze
  COMBINED_SUB  = %w[net_gex_usd_per_1pct regime gamma_flip call_wall
                     put_wall put_call_oi_btc instruments].freeze

  # F-20: the pre-fix recording captured a parser-dead CBOE board; the
  # gex_us pins self-enable once the owner re-records under the fixed trim.
  def cboe_fixture_live?
    data = JSON.parse(File.read(File.join(ROOT, 'test/fixtures/cboe_options.json')))['data']
    now = Time.parse(RECORDED_NOW)
    data['options'].to_a.any? do |o|
      o['open_interest'].to_f > 0 && (o['iv'].to_f > 0 || o['gamma'].to_f > 0) &&
        (p = BTC::Options.parse_osi(o['option'])) && p[0] > now
    end
  end

  def skip_unless_cboe_live
    return if cboe_fixture_live?

    skip 'cboe_options.json is parser-dead (F-20) -- owner: rake fixtures:record'
  end

  def assert_wall(wall, level_key)
    return if wall.nil?

    assert_kind_of Integer, wall[level_key]
    assert_kind_of Integer, wall['gex']
  end

  # ---- gex.rb (Deribit) ------------------------------------------------

  def test_gex_json_contract
    j = run_json('scripts/gex.rb', '--json')
    assert_contract_keys GEX_KEYS, j, 'gex.rb'
    assert_equal 'BTC', j['ccy']
    assert_kind_of Numeric, j['spot']
    assert_equal RECORDED_NOW, Time.iso8601(j['ts']).iso8601 # frozen clock
    assert_kind_of Integer, j['net_gex_usd_per_1pct']
    assert_includes %w[short_gamma long_gamma], j['regime']
    assert j['gamma_flip'].nil? || j['gamma_flip'].is_a?(Integer)
    assert_wall j['call_wall'], 'strike'
    assert_wall j['put_wall'], 'strike'
    assert_kind_of Float, j['put_call_oi']
    assert_operator j['instruments'], :>, 0
    assert_kind_of Hash, j['profile']
    j['profile'].each do |k, v|
      assert_match(/\A\d+\z/, k)
      assert_kind_of Integer, v
    end
  end

  def test_gex_tmux_contract
    _, err, st = run_script('scripts/gex.rb', '--tmux')
    assert st.success?, err
    line = File.read('/tmp/gex_btc.status')
    assert_match(%r{\AGEX BTC \S+ flip \S+ PW \S+ CW \S+ P/C \d+\.\d\d\n\z}, line)
  end

  def test_gex_aborts_nonzero_when_deribit_down
    _, err, st = run_script('scripts/gex.rb', '--json',
                            env: { 'FAKE_HTTP_DENY' => 'deribit.com' })
    refute st.success?, 'documented failure mode: abort, no fail-soft JSON'
    assert_match(/deribit/, err)
  end

  # ---- gex_us.rb (CBOE) ------------------------------------------------

  def test_gex_us_single_ticker_is_one_object
    skip_unless_cboe_live
    j = run_json('scripts/gex_us.rb', 'IBIT', '--json')
    assert_kind_of Hash, j # F-10: single ticker -> ONE OBJECT
    assert_contract_keys GEX_US_KEYS, j, 'gex_us.rb'
    assert_equal 'IBIT', j['ticker']
    assert_includes %w[short_gamma long_gamma], j['regime']
    %w[call_wall put_wall].each do |w|
      next if j[w].nil?

      assert_equal %w[btc gex strike], j[w].keys.sort
    end
    assert_kind_of Float, j['put_call_oi']
    assert_operator j['instruments'], :>, 0
  end

  def test_gex_us_multi_ticker_is_array
    skip_unless_cboe_live
    j = run_json('scripts/gex_us.rb', 'IBIT', 'IBIT', '--json')
    assert_kind_of Array, j # F-10: multiple tickers -> ARRAY
    assert_equal 2, j.size
    j.each { |o| assert_contract_keys GEX_US_KEYS, o, 'gex_us.rb[]' }
  end

  def test_gex_us_tmux_contract
    skip_unless_cboe_live
    _, err, st = run_script('scripts/gex_us.rb', 'IBIT', '--tmux')
    assert st.success?, err
    line = File.read('/tmp/gex_ibit.status')
    assert_match(%r{\AGEX IBIT \S+ flip .+ PW .+ CW .+ P/C \d+\.\d\d\n\z}, line)
  end

  def test_gex_us_aborts_nonzero_when_cboe_down
    _, err, st = run_script('scripts/gex_us.rb', 'IBIT', '--json',
                            env: { 'FAKE_HTTP_DENY' => 'cboe.com' })
    refute st.success?, 'documented failure mode: abort, no fail-soft JSON'
    assert_match(/cboe/, err)
  end

  # ---- gex_btc_combined.rb ---------------------------------------------

  def test_combined_json_contract
    j = run_json('scripts/gex_btc_combined.rb', '--json')
    assert_contract_keys COMBINED_KEYS, j, 'gex_btc_combined.rb'
    assert_kind_of Numeric, j['btc_spot']
    assert_kind_of Integer, j['bin']

    assert_kind_of Array, j['venues']
    names = j['venues'].map { |v| v['name'] }
    assert_includes names, 'Deribit'
    assert_includes names, 'IBIT' if cboe_fixture_live?
    j['venues'].each { |v| assert_contract_keys VENUE_KEYS, v, 'venues[]' }

    c = j['combined']
    assert_contract_keys COMBINED_SUB, c, 'combined{}'
    assert_includes %w[short_gamma long_gamma], c['regime']
    assert_wall c['call_wall'], 'level'
    assert_wall c['put_wall'], 'level'
    assert_kind_of Float, c['put_call_oi_btc']
    assert_operator c['instruments'], :>, 0

    j['profile'].each do |k, v|
      assert_match(/\A-?\d+\z/, k)
      assert_kind_of Integer, v
    end

    # additive 2026-07-05: per-venue put/call split; call+put sums back
    # to the net profile by construction (same gex_at per instrument)
    assert_equal names.sort, j['profiles'].keys.sort
    j['profiles'].each_value do |per|
      per.each do |k, v|
        assert_match(/\A-?\d+\z/, k)
        assert_equal %w[call put], v.keys.sort
      end
    end
    summed = Hash.new(0)
    j['profiles'].each_value { |per| per.each { |k, v| summed[k] += v['call'] + v['put'] } }
    j['profile'].each do |k, net|
      assert_in_delta net, summed[k], j['profiles'].size + 1, "profile[#{k}] != sum of splits"
    end
  end

  def test_combined_tmux_contract
    _, err, st = run_script('scripts/gex_btc_combined.rb', '--tmux')
    assert st.success?, err
    line = File.read('/tmp/gex_btc_combined.status')
    assert_match(%r{\AGEXsum \S+ flip \S+ PW \S+ CW \S+ P/C \d+\.\d\d\n\z}, line)
  end

  def test_combined_aborts_nonzero_when_index_down
    _, err, st = run_script('scripts/gex_btc_combined.rb', '--json',
                            env: { 'FAKE_HTTP_DENY' => 'deribit.com' })
    refute st.success?, 'index abort is the documented hard-failure mode'
    assert_match(/deribit index/, err)
  end
end
