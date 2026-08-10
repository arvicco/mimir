# frozen_string_literal: true
#
# M1-8: --json contracts for the seven scenario modules and the
# aggregator, running the real scripts offline against recorded
# fixtures. Pins the frozen conventions: one-JSON-line stdout
# discipline (F-9), the funding/onchain self-reported name quirks
# (F-11), the fail-soft shape with 'unavailable': true (F-12), and
# exact per-module field sets (additive changes update these pins in
# the same commit). One generated test per module and mode.

require_relative 'contract_helper'
require_relative '../../lib/btc/fixtures'

class TestScenarioContract < Minitest::Test
  BASE_KEYS      = %w[headline name score ts].freeze
  FAIL_SOFT_KEYS = %w[headline name score ts unavailable].freeze
  REGIMES        = %w[FLUSH LEAN-FLUSH NEUTRAL BASE RECOVERY].freeze

  # module file -> [self-reported name (F-11), URL fragment to deny,
  #                 optional extra keys in the success shape]
  MODULES = {
    'etf_flows'     => ['etf_flows',    'farside',        %w[as_of last_5_days_usd_m source]],
    'funding_basis' => ['funding',      'fapi.binance',   %w[note]], # note only when basis < 0
    'cb_premium'    => ['cb_premium',   'coinbase',       []],
    'hash_ribbons'  => ['hash_ribbons', 'mempool',        []],
    'onchain_value' => ['onchain',      'coinmetrics',    []],
    'stables'       => ['stables',      'llama.fi',       []],
    'macro'         => ['macro',        'stlouisfed',     []]
  }.freeze

  FRED_ENV = { 'FRED_API_KEY' => 'contract-test-key' }.freeze

  # F-9: exactly one stdout line in --json mode, parsing as one object.
  def module_json(mod, env: {})
    out, err, st = run_script("scripts/scenario/#{mod}.rb", '--json', env: env)
    assert st.success?, "#{mod} exit #{st.exitstatus}: #{err}"
    assert_equal 1, out.lines.size, "#{mod}: stdout discipline (F-9) -- got: #{out.inspect}"
    JSON.parse(out)
  end

  def assert_base_shape(j, expected_name)
    assert_equal expected_name, j['name'] # F-11 quirks pinned here
    assert_includes [-1, 0, 1], j['score']
    assert_kind_of String, j['headline']
    assert_equal RECORDED_NOW, Time.iso8601(j['ts']).iso8601
  end

  # F-21/F-22: pre-fix recordings miss binance_spot and under-trim
  # farside; these success pins self-enable on the owner's re-record.
  def skip_if_fixture_pending(mod)
    case mod
    when 'cb_premium'
      unless File.exist?(File.join(ROOT, 'test/fixtures/binance_spot.json'))
        skip 'binance_spot.json not yet recorded (F-21) -- owner: rake fixtures:record'
      end
    when 'etf_flows'
      rows = BTC::Flows.parse_flows(File.read(File.join(ROOT, 'test/fixtures/farside_flows.html')))
      if rows.size < 10
        skip 'farside_flows.html parses below 10 rows (F-22) -- owner: rake fixtures:record'
      end
    end
  end

  MODULES.each do |mod, (name, deny, extras)|
    define_method("test_#{mod}_success_shape") do
      skip_if_fixture_pending(mod)
      j = module_json(mod, env: mod == 'macro' ? FRED_ENV : {})
      assert_base_shape j, name
      surplus = j.keys - BASE_KEYS - extras
      assert_empty surplus, "#{mod}: unpinned --json fields #{surplus} (frozen contract)"
      refute j.key?('unavailable'), "#{mod}: healthy run must not carry the F-12 marker"
    end

    define_method("test_#{mod}_fail_soft_shape") do
      env = { 'FAKE_HTTP_DENY' => deny }
      env = env.merge(FRED_ENV) if mod == 'macro'
      # etf_flows: 'farside' also denies the archive proxy (URL contains
      # farside.co.uk); the keyed leg must be off in the test env too.
      env['COINGLASS_API_KEY'] = nil if mod == 'etf_flows'
      j = module_json(mod, env: env)
      assert_contract_keys FAIL_SOFT_KEYS, j, "#{mod} fail-soft"
      assert_base_shape j, name
      assert_equal 0, j['score']
      assert_equal true, j['unavailable'] # F-12
      assert_match(/unavailable/, j['headline'])
    end
  end

  # F-23 leg 3: with both farside legs denied and a key set, etf_flows
  # answers from the CoinGlass fixture and reports its source.
  def test_etf_flows_coinglass_fallback_shape
    unless File.exist?(File.join(ROOT, 'test/fixtures/coinglass_flows.json'))
      skip 'coinglass_flows.json not yet recorded (F-23) -- owner: rake fixtures:record'
    end
    j = module_json('etf_flows', env: { 'FAKE_HTTP_DENY' => 'farside',
                                        'COINGLASS_API_KEY' => 'contract-test-key' })
    assert_base_shape j, 'etf_flows'
    assert_equal 'coinglass', j['source']
    refute j.key?('unavailable')
  end

  def test_macro_fail_soft_without_key
    j = module_json('macro', env: { 'FRED_API_KEY' => nil })
    assert_contract_keys FAIL_SOFT_KEYS, j, 'macro no-key'
    assert_equal 0, j['score']
    assert_match(/FRED_API_KEY not set/, j['headline'])
  end

  # ---- aggregator ------------------------------------------------------

  def test_aggregator_json_contract
    j = run_json('scripts/scenario/scenario.rb', '--json', env: FRED_ENV)
    assert_contract_keys %w[composite modules regime ts], j, 'scenario.rb'
    assert_kind_of Float, j['composite']
    assert_includes REGIMES, j['regime']

    assert_equal 7, j['modules'].size
    # the aggregator keys modules by FILENAME (the F-11 quirks stay module-local)
    assert_equal MODULES.keys.sort, j['modules'].map { |m| m['mod'] }.sort
    j['modules'].each do |m|
      # M8-8: `unavailable` is now an additive per-module boolean.
      assert_contract_keys %w[headline mod score unavailable w], m, 'modules[]'
      assert_includes [-1, 0, 1], m['score']
      assert_kind_of Integer, m['w']
      assert_includes [true, false], m['unavailable']
      assert_equal false, m['unavailable'], 'healthy fixtures: no module is unavailable'
    end
  end

  # ---- M8-8: --history line data-integrity markers ---------------------

  # Run scenario.rb --history against an isolated data dir; return the
  # single appended JSONL line, parsed. +deny+ is the FAKE_HTTP_DENY value.
  def history_line(deny: nil)
    root = Dir.mktmpdir('mimir-scn-history')
    env = FRED_ENV.merge('BTC_DATA_DIR' => root,
                         # a real COINGLASS_API_KEY inherited from the shell
                         # activates etf_flows' third fallback, whose host is
                         # not in any deny list -- one live module un-blinds
                         # the day and the blind/partial expectations flip
                         # (found 2026-08-10: rake deploy pre-flight runs the
                         # gate with the owner env sourced). nil = unset.
                         'COINGLASS_API_KEY' => nil)
    env['FAKE_HTTP_DENY'] = deny if deny
    _, err, st = run_script('scripts/scenario/scenario.rb', '--json', '--history',
                            env: env)
    assert st.success?, err
    hist = File.join(root, 'scenario', 'history.jsonl')
    assert File.exist?(hist), 'history.jsonl not written on --history'
    JSON.parse(File.readlines(hist).last)
  ensure
    FileUtils.remove_entry(root) if root && Dir.exist?(root)
  end

  HISTORY_BASE = %w[composite regime scores ts].freeze

  # Healthy day: neither marker key -- old lines stay valid.
  def test_history_line_healthy_carries_no_marker
    line = history_line
    assert_contract_keys HISTORY_BASE, line, 'scenario history line'
    assert_equal MODULES.keys.sort, line['scores'].keys.sort
    refute line.key?('blind')
    refute line.key?('unavailable')
  end

  # Blind day: EVERY source denied -> every module fail-soft -> blind:true
  # (and no partial `unavailable` list).
  def test_history_line_blind_when_all_modules_unavailable
    deny = %w[farside fapi.binance coinbase mempool coinmetrics llama.fi stlouisfed].join(',')
    line = history_line(deny: deny)
    assert_equal true, line['blind']
    refute line.key?('unavailable')
    assert_contract_keys(HISTORY_BASE + %w[blind], line, 'scenario blind line')
  end

  # Partial degradation: a strict subset denied -> unavailable:[names], no blind.
  def test_history_line_unavailable_list_when_some_modules_down
    line = history_line(deny: 'coinbase,mempool') # cb_premium + hash_ribbons
    refute line.key?('blind')
    assert_equal %w[cb_premium hash_ribbons], line['unavailable']
    assert_contract_keys(HISTORY_BASE + %w[unavailable], line, 'scenario partial line')
  end

  def test_aggregator_tmux_contract
    _, err, st = run_script('scripts/scenario/scenario.rb', '--tmux', env: FRED_ENV)
    assert st.success?, err
    line = File.read('/tmp/scenario.status')
    assert_match(
      /\ASCN (FLUSH|LEAN-FLUSH|NEUTRAL|BASE|RECOVERY) [+-]\d+\.\d\d etf[+-]\d fnd[+-]\d cbp[+-]\d mac[+-]\d hsh[+-]\d mvrv[+-]\d stb[+-]\d\n\z/,
      line
    )
  end
end
