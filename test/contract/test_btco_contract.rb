# frozen_string_literal: true
#
# M1-10: --json / --tmux contracts for btco.rb on a SYNTHETIC universe
# (via --universe) priced from recorded fixtures: the US leg quotes off
# cboe_options.json (ticker IBIT so the shim serves it), the JPY leg
# prices via manual_px + the frankfurter fixture, exercising the FX
# path plus the STALE and placeholder flags. Values are irrelevant --
# these pins are field sets, flags and formats.

require_relative 'contract_helper'
require 'tmpdir'
require 'fileutils'

class TestBtcoContract < Minitest::Test
  TOP_KEYS = %w[aggregate_leverage band below_1_btc_weighted btc_spot
                companies headline median_mnav median_net_mnav name score
                stale_entries stress ts].freeze
  COMPANY_KEYS = %w[btc btc_as_of cebe_sats_sh ccy ev_per_btc leverage
                    mnav net_mnav placeholder px sats_sh_diluted stale
                    ticker verdict].freeze
  FAIL_SOFT_KEYS = %w[headline name score ts unavailable].freeze
  BANDS    = %w[CALM ELEVATED STRESSED CRITICAL].freeze
  VERDICTS = %w[DEEP-DISC UNDER FAIR RICH OVER N/A].freeze

  # Fresh vs stale is judged against the frozen clock (the fixtures'
  # recording day): IBIT's as-of is weeks old, the JPY leg's > 120d.
  UNIVERSE = {
    'companies' => [
      { 'name' => 'Test US', 'ticker' => 'IBIT', 'ccy' => 'USD', 'cik' => '1050446',
        'btc' => 10_000, 'btc_as_of' => '2026-06-01',
        'shares_basic' => 100_000_000, 'shares_diluted' => 120_000_000,
        'debt_face' => 100_000_000, 'pref_liq' => 0,
        'converts' => [{ 'face' => 50_000_000, 'conv_price' => 20.0, 'label' => 'itm' },
                       { 'face' => 50_000_000, 'conv_price' => 500.0, 'label' => 'otm' }] },
      { 'name' => 'Test JP', 'ticker' => '9999', 'ccy' => 'JPY', 'cik' => nil,
        'btc' => 2_000, 'btc_as_of' => '2025-12-01',
        'shares_basic' => 50_000_000, 'shares_diluted' => 60_000_000,
        'debt_face' => 0, 'pref_liq' => 0, 'converts' => [],
        'manual_px' => 4_800, 'placeholder' => true }
    ]
  }.freeze

  UNI_DIR = File.join(Dir.tmpdir, "mimir-btco-contract-#{Process.pid}")
  Minitest.after_run { FileUtils.rm_rf(UNI_DIR) }

  def universe_path
    FileUtils.mkdir_p(UNI_DIR)
    path = File.join(UNI_DIR, 'universe.json')
    File.write(path, JSON.generate(UNIVERSE)) unless File.exist?(path)
    path
  end

  def run_btco(*argv, env: {})
    run_script('scripts/btco/btco.rb', '--universe', universe_path, *argv, env: env)
  end

  def test_json_contract
    out, err, st = run_btco('--json')
    assert st.success?, err
    j = JSON.parse(out)
    assert_contract_keys TOP_KEYS, j, 'btco.rb'
    assert_equal 'btco', j['name']
    assert_includes [-1, 0, 1], j['score']
    assert_equal RECORDED_NOW, Time.iso8601(j['ts']).iso8601
    assert_kind_of Integer, j['stress']
    assert_includes 0..100, j['stress']
    assert_includes BANDS, j['band']
    assert_kind_of Integer, j['stale_entries']

    assert_equal 2, j['companies'].size
    j['companies'].each do |c|
      assert_contract_keys COMPANY_KEYS, c, 'companies[]'
      assert_includes VERDICTS, c['verdict']
      assert_kind_of Float, c['leverage']
      assert_includes [true, false], c['stale']
      assert_includes [true, false], c['placeholder']
    end

    us = j['companies'].find { |c| c['ticker'] == 'IBIT' }
    jp = j['companies'].find { |c| c['ticker'] == '9999' }
    assert_equal false, us['stale']
    assert_equal false, us['placeholder']
    assert_equal 'JPY', jp['ccy']
    assert_equal true, jp['stale'], 'as-of > 120d behind the frozen clock'
    assert_equal true, jp['placeholder']
  end

  def test_tmux_contract
    _, err, st = run_btco('--tmux')
    assert st.success?, err
    line = File.read('/tmp/btco.status')
    assert_match(/\ABTCO \d+ (CALM|ELEVATED|STRESSED|CRITICAL) <1:\d+% med \d+\.\d\d lev \d+%( stale:\d+)?\n\z/,
                 line)
    assert_match(/ stale:1\n\z/, line) # the JPY leg is stale by construction
  end

  def assert_fail_soft(out, st, reason_re)
    assert st.success?, 'fail-soft must exit 0'
    assert_equal 1, out.lines.size, "stdout discipline (F-9) -- got: #{out.inspect}"
    j = JSON.parse(out)
    assert_contract_keys FAIL_SOFT_KEYS, j, 'btco fail-soft'
    assert_equal 'btco', j['name']
    assert_equal 0, j['score']
    assert_equal true, j['unavailable'] # F-12
    assert_match reason_re, j['headline']
  end

  def test_fail_soft_on_missing_universe
    out, _, st = run_script('scripts/btco/btco.rb', '--universe',
                            File.join(UNI_DIR, 'nope.json'), '--json')
    assert_fail_soft out, st, /universe/
  end

  def test_fail_soft_when_deribit_down
    out, _, st = run_btco('--json', env: { 'FAKE_HTTP_DENY' => 'deribit.com' })
    assert_fail_soft out, st, /deribit index/
  end

  def test_fail_soft_when_nothing_priced
    FileUtils.mkdir_p(UNI_DIR)
    path = File.join(UNI_DIR, 'unpriced.json')
    File.write(path, JSON.generate('companies' => [
      { 'name' => 'No Quote', 'ticker' => 'ZZZZ', 'ccy' => 'USD',
        'btc' => 1, 'btc_as_of' => '2026-06-01',
        'shares_basic' => 1_000, 'shares_diluted' => 1_000,
        'debt_face' => 0, 'pref_liq' => 0, 'converts' => [] }
    ]))
    out, _, st = run_script('scripts/btco/btco.rb', '--universe', path, '--json')
    assert_fail_soft out, st, /no companies priced/
  end
end
