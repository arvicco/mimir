# frozen_string_literal: true

# M2-3: Publish::Pipeline -- the orchestrator, fully injected (no real
# subprocesses, no network). Producers are canned runner lambdas; tails
# read a synthetic BTC_DATA_DIR; KV goes through a fake BTC::Http
# transport. Pins the dry-run file layout, the envelope + index contents,
# skip semantics, tail windowing, the /tmp/publish.status --tmux contract,
# and the real-mode 'v1:'-prefixed PUTs incl. the 403 abort.

require_relative '../test_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../../publish/pipeline'

class TestPublishPipeline < Minitest::Test
  NOW = Time.utc(2026, 7, 4, 12, 0, 0)
  DAY = 86_400

  # A healthy gex payload, printed PRETTY (multi-line) so a lines.last
  # parse would break -- proving the full-stdout JSON parse.
  GEX = { 'flip' => 108_500, 'walls' => [110_000, 105_000] }.freeze
  # Fail-soft: valid JSON carrying 'unavailable' -- MUST be published.
  SCN = { 'unavailable' => true, 'headline' => 'source down' }.freeze

  def setup
    @dir = Dir.mktmpdir('mimir-pub')
    @prev_data_dir = ENV['BTC_DATA_DIR']
    ENV['BTC_DATA_DIR'] = @dir
    write_history
    write_ledger
  end

  def teardown
    ENV['BTC_DATA_DIR'] = @prev_data_dir
    BTC::Http.transport = nil
    FileUtils.remove_entry(@dir)
  end

  # -- synthetic tails -----------------------------------------------------
  # scenario history: one line OUTSIDE the 90d window, two inside.
  def write_history
    d = File.join(@dir, 'scenario')
    FileUtils.mkdir_p(d)
    lines = [
      { 'ts' => iso(NOW - 100 * DAY), 'composite' => -0.1 }, # dropped (>90d)
      { 'ts' => iso(NOW - 89 * DAY),  'composite' => 0.2 },  # kept
      { 'ts' => iso(NOW - 1 * DAY),   'composite' => 0.5 }   # kept
    ]
    File.write(File.join(d, 'history.jsonl'), lines.map { |h| JSON.generate(h) }.join("\n") + "\n")
  end

  # lppl ledger: one line OUTSIDE the 365d window, two inside.
  def write_ledger
    d = File.join(@dir, 'lppl')
    FileUtils.mkdir_p(d)
    lines = [
      { 'ts' => iso(NOW - 400 * DAY), 'bf' => 1.0 }, # dropped (>365d)
      { 'ts' => iso(NOW - 300 * DAY), 'bf' => 2.0 }, # kept
      { 'ts' => iso(NOW - 10 * DAY),  'bf' => 3.0 }  # kept
    ]
    File.write(File.join(d, 'ledger.jsonl'), lines.map { |h| JSON.generate(h) }.join("\n") + "\n")
  end

  def iso(t) = t.utc.iso8601

  # Runner: one healthy, one fail-soft, one raising, one garbage. Keyed
  # off the script path in argv (the runner never sees the artifact key).
  def mixed_runner
    lambda do |argv, _timeout|
      case argv.find { |a| a.end_with?('.rb') }
      when 'scripts/gex_btc_combined.rb' then JSON.pretty_generate(GEX)
      when 'scripts/scenario/scenario.rb' then JSON.pretty_generate(SCN)
      when 'scripts/lppl/lppl.rb' then raise 'boom (nonzero exit)'
      when 'scripts/btco/btco.rb' then "this is not json {{{"
      else raise "unexpected argv #{argv.inspect}"
      end
    end
  end

  # The committed suite payload fixtures -- the exact, deterministic
  # inputs the chart builders expect (test/fixtures/payloads/README.md).
  FIXTURES = File.expand_path('../fixtures/payloads', __dir__)

  def fixture(name) = File.read(File.join(FIXTURES, name))

  # Healthy runner backed by the real payload fixtures, so all four chart
  # builders succeed (a minimal canned payload would crash gex_profile on
  # its missing 'profiles' -- see the explicit skip test below).
  def fixture_runner
    map = {
      'scripts/gex_btc_combined.rb'  => 'payload_gex_combined.json',
      'scripts/scenario/scenario.rb' => 'payload_scenario_latest.json',
      'scripts/lppl/lppl.rb'         => 'payload_lppl_latest.json',
      'scripts/btco/btco.rb'         => 'payload_btco_latest.json'
    }
    ->(argv, _t) { fixture(map.fetch(argv.find { |a| a.end_with?('.rb') })) }
  end

  # Overwrite the synthetic tails with the fixture entries so the tail
  # payloads match what the scenario_strip / lppl_regime builders expect.
  def write_fixture_tails
    hist = JSON.parse(fixture('payload_scenario_history.json'))['entries']
    File.write(File.join(@dir, 'scenario', 'history.jsonl'),
               hist.map { |h| JSON.generate(h) }.join("\n") + "\n")
    ledger = JSON.parse(fixture('payload_lppl_ledger.json'))['entries']
    File.write(File.join(@dir, 'lppl', 'ledger.jsonl'),
               ledger.map { |h| JSON.generate(h) }.join("\n") + "\n")
  end

  def fixture_dry_run
    write_fixture_tails
    Publish::Pipeline.run(now: NOW, source: 'testhost', dry_run: true,
                          runner: fixture_runner, out_dir: out_dir)
  end

  def out_dir = File.join(@dir, 'preview')

  def dry_run(runner: mixed_runner)
    Publish::Pipeline.run(now: NOW, source: 'testhost', dry_run: true,
                          runner: runner, out_dir: out_dir)
  end

  # -- dry-run file layout -------------------------------------------------

  def test_preview_file_set_and_names
    dry_run
    got = Dir.children(out_dir).sort
    # scenario_strip still builds from the fail-soft scenario + history;
    # gex_profile (minimal GEX, no 'profiles'), lppl_regime + btco_table
    # (missing sources) all SKIP.
    assert_equal %w[chart_scenario_strip.json gex_combined.json index.json
                    lppl_ledger.json scenario_history.json scenario_latest.json], got
  end

  def test_summary_keys_and_skips
    s = dry_run
    # gex published, scenario fail-soft published, both tails published,
    # scenario_strip chart built, plus the index. lppl (raise) + btco
    # (garbage) producers skipped; gex_profile (no 'profiles'), lppl_regime
    # + btco_table (absent sources) charts skipped.
    assert_equal %w[gex:combined scenario:latest scenario:history lppl:ledger
                    chart:scenario_strip index], s[:keys]
    assert_equal %w[lppl:latest btco:latest chart:gex_profile
                    chart:lppl_regime chart:btco_table], s[:skipped]
    assert_equal 'DRY', s[:mode]
    assert_equal out_dir, s[:out_dir]
  end

  # -- envelope of a written artifact --------------------------------------

  def test_written_envelope_fields
    dry_run
    env = JSON.parse(File.read(File.join(out_dir, 'gex_combined.json')))
    assert_equal 1, env['v']
    assert_equal 'gex:combined', env['key']
    assert_equal '2026-07-04T12:00:00Z', env['generated_at']
    assert_equal 1_800, env['ttl_hint_s']
    assert_equal 'testhost', env['source']
    assert_equal GEX, env['payload']
  end

  def test_failsoft_producer_is_published_as_is
    dry_run
    env = JSON.parse(File.read(File.join(out_dir, 'scenario_latest.json')))
    assert_equal SCN, env['payload']
    assert_equal true, env['payload']['unavailable']
  end

  # -- index contents ------------------------------------------------------

  def test_index_lists_sorted_keys_with_min_ttl
    dry_run
    idx = JSON.parse(File.read(File.join(out_dir, 'index.json')))
    assert_equal 'index', idx['key']
    # MIN ttl across published members: scenario/gex 1800 beat lppl 86400.
    assert_equal 1_800, idx['ttl_hint_s']
    keys = idx['payload']['keys'].map { |r| r['key'] }
    # the built chart:scenario_strip is listed too (sorted in).
    assert_equal %w[chart:scenario_strip gex:combined lppl:ledger
                    scenario:history scenario:latest], keys
    # lppl:latest + btco:latest never made it into the index.
    refute_includes keys, 'lppl:latest'
    refute_includes keys, 'btco:latest'
  end

  # -- tail windowing (pinned cutoff) --------------------------------------

  def test_history_tail_keeps_only_within_90d_ascending
    dry_run
    env = JSON.parse(File.read(File.join(out_dir, 'scenario_history.json')))
    entries = env['payload']['entries']
    assert_equal 2, entries.size # the -100d line is outside the window
    assert_equal [iso(NOW - 89 * DAY), iso(NOW - 1 * DAY)], entries.map { |e| e['ts'] }
  end

  def test_ledger_tail_keeps_only_within_365d
    dry_run
    env = JSON.parse(File.read(File.join(out_dir, 'lppl_ledger.json')))
    tss = env['payload']['entries'].map { |e| e['ts'] }
    assert_equal [iso(NOW - 300 * DAY), iso(NOW - 10 * DAY)], tss
  end

  def test_missing_tail_file_is_skipped
    FileUtils.rm(File.join(@dir, 'lppl', 'ledger.jsonl'))
    s = dry_run
    refute_includes s[:keys], 'lppl:ledger'
    assert_includes s[:skipped], 'lppl:ledger'
    refute File.exist?(File.join(out_dir, 'lppl_ledger.json'))
  end

  # -- status line (NEW frozen --tmux contract) ----------------------------

  def test_status_line_format
    dry_run
    line = File.read('/tmp/publish.status')
    # 6 written (gex, scenario:latest, 2 tails, chart:scenario_strip,
    # index) of 11 expected (4 producers + 2 tails + 4 charts + 1 index).
    assert_equal "PUB DRY 6/11 keys 12:00 UTC\n", line
  end

  def test_status_line_live_label
    inject_kv { FakeRes.new('200', 'ok') }
    Publish::Pipeline.run(now: NOW, source: 'testhost', dry_run: false,
                          runner: fixture_runner, env: ENV_OK)
    # all four sources + two tails + four charts + index publish cleanly.
    assert_equal "PUB LIVE 11/11 keys 12:00 UTC\n", File.read('/tmp/publish.status')
  end

  # -- real mode: v1:-prefixed PUTs + 403 abort ----------------------------

  FakeRes = Struct.new(:code, :body)
  ENV_OK = { 'CF_ACCOUNT_ID' => 'acct1', 'CF_KV_NAMESPACE_ID' => 'ns1',
             'CF_API_TOKEN' => 'cf-secret' }.freeze

  def inject_kv(&blk)
    calls = []
    BTC::Http.transport = lambda do |uri, req, opts|
      calls << { uri: uri.to_s, req: req, opts: opts }
      blk.call(calls.size)
    end
    calls
  end

  def test_real_mode_puts_v1_prefixed_keys
    calls = inject_kv { FakeRes.new('200', '{"success":true}') }
    s = Publish::Pipeline.run(now: NOW, source: 'testhost', dry_run: false,
                              runner: fixture_runner, env: ENV_OK)
    # every producer + tail + chart + index put exactly once, v1:-prefixed.
    assert_equal 11, calls.size
    assert(calls.all? { |c| c[:uri].include?('/values/v1%3A') })
    # the chart keys are PUT as 'v1:chart:<name>' (colons url-encoded).
    assert(calls.any? { |c| c[:uri].include?('/values/v1%3Achart%3A') })
    assert s[:keys].include?('chart:gex_profile')
    assert s[:keys].include?('index')
    assert_nil s[:out_dir] # no preview dir in real mode
    refute Dir.exist?(out_dir)
  end

  def test_real_mode_403_aborts_nonzero_via_error
    inject_kv { FakeRes.new('403', 'denied') }
    assert_raises(Publish::KV::Error) do
      Publish::Pipeline.run(now: NOW, source: 'testhost', dry_run: false,
                            runner: fixture_runner, env: ENV_OK)
    end
  end

  # -- chart envelopes (M3-5) ----------------------------------------------

  # With the real fixture payloads all four charts build; pin their
  # preview files, keys, and ttl INHERITANCE (min of the input ttls).
  def test_chart_envelopes_written_with_inherited_ttls
    s = fixture_dry_run
    %w[chart:gex_profile chart:scenario_strip
       chart:lppl_regime chart:btco_table].each { |k| assert_includes s[:keys], k }

    gex = JSON.parse(File.read(File.join(out_dir, 'chart_gex_profile.json')))
    assert_equal 'chart:gex_profile', gex['key']
    assert_equal 1_800, gex['ttl_hint_s'] # inherits gex:combined (1800)
    assert gex['payload'].key?('series')  # a real ECharts option
    # additive 2026-07-05: hover-help meta rides the chart envelope
    assert_equal Publish::Charts::CHARTS['gex_profile'][:meta], gex['meta']

    lppl = JSON.parse(File.read(File.join(out_dir, 'chart_lppl_regime.json')))
    assert_equal 86_400, lppl['ttl_hint_s'] # min(86400, 86400)

    btco = JSON.parse(File.read(File.join(out_dir, 'chart_btco_table.json')))
    assert_equal 3_600, btco['ttl_hint_s'] # inherits btco:latest (3600)
  end

  def test_index_lists_chart_keys
    fixture_dry_run
    idx = JSON.parse(File.read(File.join(out_dir, 'index.json')))
    keys = idx['payload']['keys'].map { |r| r['key'] }
    %w[chart:gex_profile chart:scenario_strip
       chart:lppl_regime chart:btco_table].each { |k| assert_includes keys, k }
    # index lists every published member but not itself: 4 sources + 2
    # tails + 4 charts.
    assert_equal 10, keys.size
  end

  # A builder crash SKIPs only that chart; the source key survives and the
  # run completes. Minimal GEX (no 'profiles') crashes gex_profile.
  def test_chart_builder_crash_skips_chart_not_source
    s = dry_run # mixed_runner: GEX = { flip, walls }, no 'profiles'
    assert_includes s[:skipped], 'chart:gex_profile'
    assert_includes s[:keys], 'gex:combined' # the source still published
    refute File.exist?(File.join(out_dir, 'chart_gex_profile.json'))
    assert File.exist?(File.join(out_dir, 'gex_combined.json'))
  end
end
