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

  def healthy_runner
    payloads = {
      'scripts/gex_btc_combined.rb'  => { 'flip' => 1 },
      'scripts/scenario/scenario.rb' => { 'composite' => 0.1 },
      'scripts/lppl/lppl.rb'         => { 'bf' => 2 },
      'scripts/btco/btco.rb'         => { 'stress' => 3 }
    }
    ->(argv, _t) { JSON.pretty_generate(payloads.fetch(argv.find { |a| a.end_with?('.rb') })) }
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
    assert_equal %w[gex_combined.json index.json lppl_ledger.json
                    scenario_history.json scenario_latest.json], got
  end

  def test_summary_keys_and_skips
    s = dry_run
    # gex published, scenario fail-soft published, both tails published,
    # plus the index. lppl (raise) + btco (garbage) skipped.
    assert_equal %w[gex:combined scenario:latest scenario:history lppl:ledger index], s[:keys]
    assert_equal %w[lppl:latest btco:latest], s[:skipped]
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
    assert_equal %w[gex:combined lppl:ledger scenario:history scenario:latest], keys
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
    # 5 written (gex, scenario:latest, 2 tails, index) of 7 expected
    # (4 producers + 2 tails + 1 index).
    assert_equal "PUB DRY 5/7 keys 12:00 UTC\n", line
  end

  def test_status_line_live_label
    inject_kv { FakeRes.new('200', 'ok') }
    Publish::Pipeline.run(now: NOW, source: 'testhost', dry_run: false,
                          runner: healthy_runner, env: ENV_OK)
    assert_equal "PUB LIVE 7/7 keys 12:00 UTC\n", File.read('/tmp/publish.status')
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
                              runner: healthy_runner, env: ENV_OK)
    # every producer + tail + index put exactly once, all v1:-prefixed.
    assert_equal 7, calls.size
    assert(calls.all? { |c| c[:uri].include?('/values/v1%3A') })
    assert s[:keys].include?('index')
    assert_nil s[:out_dir] # no preview dir in real mode
    refute Dir.exist?(out_dir)
  end

  def test_real_mode_403_aborts_nonzero_via_error
    inject_kv { FakeRes.new('403', 'denied') }
    assert_raises(Publish::KV::Error) do
      Publish::Pipeline.run(now: NOW, source: 'testhost', dry_run: false,
                            runner: healthy_runner, env: ENV_OK)
    end
  end
end
