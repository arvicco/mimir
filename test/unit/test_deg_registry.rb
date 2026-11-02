# frozen_string_literal: true

# test_deg_registry.rb -- characterization of publish/deg_registry.rb
# against the REAL payload fixtures: exact leg names, alive on real data,
# not-alive on a surgically degraded copy, and every registered key is
# one the publish pipeline actually publishes. Pure: no IO beyond fixture
# reads, no network.

require_relative '../test_helper'
require_relative '../../publish/deg_registry'
require_relative '../../publish/pipeline'

class TestDegRegistry < Minitest::Test
  PAYLOADS = File.expand_path('../fixtures/payloads', __dir__)
  REG = Publish::DegRegistry::DEG_REGISTRY

  def load_payload(key)
    JSON.parse(File.read(File.join(PAYLOADS, "payload_#{key.tr(':', '_')}.json")))
  end

  def census(key, payload)
    Publish::DegRegistry.census(key, payload).to_h
  end

  def test_registry_keys_are_exactly_the_reviewed_set
    assert_equal %w[basis:latest gex:check gex:combined positioning:latest
                    reserves:latest vol:spread], REG.keys.sort
  end

  def test_registry_keys_are_published_by_the_pipeline
    published = (Publish::Pipeline::PRODUCERS + Publish::Pipeline::TAILS).map(&:first)
    assert_empty REG.keys - published
  end

  def test_every_entry_has_the_full_shape
    REG.each do |key, e|
      assert_kind_of String, e[:why], key
      %i[legs leg_data alive].each { |m| assert_respond_to e[m], :call, "#{key} #{m}" }
    end
  end

  def test_only_reserves_is_optional
    assert_equal ['reserves:latest'], REG.select { |_, e| e[:optional] }.keys
  end

  # ---- gex:combined ----------------------------------------------------

  def test_gex_combined_legs_are_the_nine_venues
    legs = REG['gex:combined'][:legs].call(load_payload('gex:combined'))
    assert_equal %w[Deribit IBIT FBTC BITB ARKB GBTC HODL BTCO EZBC], legs
  end

  def test_gex_combined_all_alive_on_real_data
    assert census('gex:combined', load_payload('gex:combined')).values.all?
  end

  def test_gex_combined_dropped_venue_shrinks_legs_and_dead_venue_is_flagged
    p = load_payload('gex:combined')
    p['venues'].reject! { |v| v['name'] == 'IBIT' }
    refute_includes REG['gex:combined'][:legs].call(p), 'IBIT'
    p['venues'].find { |v| v['name'] == 'FBTC' }.merge!('net_gex_usd_per_1pct' => nil, 'instruments' => 0)
    c = census('gex:combined', p)
    assert_equal false, c['FBTC']
    assert_equal true, c['Deribit']
  end

  # ---- vol:spread ------------------------------------------------------

  def test_vol_spread_legs_and_alive_on_real_data
    p = load_payload('vol:spread')
    assert_equal %w[mstr btc], REG['vol:spread'][:legs].call(p)
    assert_equal({ 'mstr' => true, 'btc' => true }, census('vol:spread', p))
  end

  def test_vol_spread_all_null_mstr_leg_is_dead_btc_stays_alive
    p = load_payload('vol:spread')
    p['tenors'].each { |t| t['mstr'].merge!('atm_iv' => nil, 'reason' => 'no live MSTR instruments parsed') }
    assert_equal({ 'mstr' => false, 'btc' => true }, census('vol:spread', p))
  end

  def test_vol_spread_one_null_tenor_does_not_kill_the_leg
    p = load_payload('vol:spread')
    p['tenors'][0]['mstr']['atm_iv'] = nil
    assert_equal true, census('vol:spread', p)['mstr']
  end

  # ---- positioning:latest ----------------------------------------------

  def test_positioning_legs_are_the_six_series
    legs = REG['positioning:latest'][:legs].call(load_payload('positioning:latest'))
    assert_equal %w[oi_close global_ls top_ls taker_buy long_liq short_liq], legs
  end

  def test_positioning_alive_on_real_data_and_dead_when_empty_or_null_tail
    p = load_payload('positioning:latest')
    assert census('positioning:latest', p).values.all?
    p['series']['top_ls'] = []
    p['series']['taker_buy'][-1][1] = nil
    c = census('positioning:latest', p)
    assert_equal false, c['top_ls']
    assert_equal false, c['taker_buy']
    assert_equal true, c['oi_close']
  end

  # ---- reserves:latest (optional) --------------------------------------

  def test_reserves_leg_alive_on_real_data_and_dead_when_empty
    p = load_payload('reserves:latest')
    assert_equal ['total_mbtc'], REG['reserves:latest'][:legs].call(p)
    assert_equal({ 'total_mbtc' => true }, census('reserves:latest', p))
    p['series']['total_mbtc'] = []
    assert_equal({ 'total_mbtc' => false }, census('reserves:latest', p))
  end

  # ---- basis:latest ----------------------------------------------------

  def test_basis_legs_alive_and_degraded
    p = load_payload('basis:latest')
    assert_equal({ 'basis' => true, 'funding' => true }, census('basis:latest', p))
    p['funding'].merge!('latest_pct' => nil, 'reason' => 'binance: timeout')
    p['basis'].merge!('tenors' => [])
    assert_equal({ 'basis' => false, 'funding' => false }, census('basis:latest', p))
  end

  # ---- gex:check -------------------------------------------------------

  def test_gex_check_legs_alive_and_degraded
    p = load_payload('gex:check')
    assert_equal({ 'ours' => true, 'theirs' => true }, census('gex:check', p))
    p['theirs'] = { 'nearest' => nil, 'oi_weighted_max_pain' => nil, 'expiries' => nil, 'deribit_oi_share' => nil }
    p['ours'] = { 'flip' => nil, 'cw' => nil, 'pw' => nil }
    assert_equal({ 'ours' => false, 'theirs' => false }, census('gex:check', p))
  end
end
