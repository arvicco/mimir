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
      when 'scripts/gex_us.rb' then fixture('payload_gex_mstr.json') # healthy MSTR
      when 'scripts/scenario/scenario.rb' then JSON.pretty_generate(SCN)
      when 'scripts/lppl/lppl.rb' then raise 'boom (nonzero exit)'
      when 'scripts/btco/btco.rb' then "this is not json {{{"
      # M8-6 producers: skipped in the mixed-failure path (exercised
      # healthy via fixture_runner), so the mixed run's published set is
      # unchanged and only the expected denominator grows.
      when 'scripts/vol.rb', 'scripts/vol_spread.rb', 'scripts/basis.rb',
           'scripts/gex_trend.rb', 'scripts/gex_check.rb'
        raise 'boom (M8-6 producer skipped in the mixed path)'
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
      'scripts/gex_us.rb'            => 'payload_gex_mstr.json',
      'scripts/scenario/scenario.rb' => 'payload_scenario_latest.json',
      'scripts/lppl/lppl.rb'         => 'payload_lppl_latest.json',
      'scripts/btco/btco.rb'         => 'payload_btco_latest.json',
      'scripts/vol.rb'               => 'payload_vol_latest.json',
      'scripts/vol_spread.rb'        => 'payload_vol_spread.json',
      'scripts/basis.rb'             => 'payload_basis_latest.json',
      'scripts/gex_trend.rb'         => 'payload_gex_trend.json',
      'scripts/gex_check.rb'         => 'payload_gex_check.json'
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
                          runner: fixture_runner, out_dir: out_dir, status_dir: @dir)
  end

  def out_dir = File.join(@dir, 'preview')

  def dry_run(runner: mixed_runner)
    Publish::Pipeline.run(now: NOW, source: 'testhost', dry_run: true,
                          runner: runner, out_dir: out_dir, status_dir: @dir)
  end

  # -- dry-run file layout -------------------------------------------------

  def test_preview_file_set_and_names
    dry_run
    got = Dir.children(out_dir).sort
    # only gex_mstr (healthy MSTR fixture) builds; scenario_strip SKIPS
    # (its scenario:latest input is fail-soft 'unavailable' -- the
    # 2026-07-07 junk-chart guard), gex_profile (minimal GEX, no
    # 'profiles'), lppl_regime + btco_table (missing sources) all SKIP.
    assert_equal %w[chart_gex_mstr.json gex_combined.json
                    gex_mstr.json index.json lppl_ledger.json
                    scenario_history.json scenario_latest.json], got
  end

  def test_summary_keys_and_skips
    s = dry_run
    # gex:combined + gex:mstr published, scenario fail-soft published
    # (the SUITE envelope: honest status), both tails published,
    # chart:gex_mstr built, plus the index. lppl (raise) + btco (garbage)
    # producers skipped; chart:scenario_strip skipped (fail-soft input --
    # junk-chart guard), gex_profile (no 'profiles'), lppl_regime +
    # btco_table (absent sources) charts skipped.
    assert_equal %w[gex:combined gex:mstr scenario:latest scenario:history
                    lppl:ledger chart:gex_mstr index], s[:keys]
    assert_equal %w[lppl:latest btco:latest vol:latest vol:spread basis:latest
                    gex:trend gex:check chart:gex_profile
                    chart:scenario_strip chart:lppl_regime chart:btco_table
                    chart:vol_surface chart:vol_spread chart:vol_spread_trend
                    chart:vol_basis chart:gex_trend], s[:skipped]
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
    # the built chart:gex_mstr is listed too (sorted in); scenario_strip
    # skipped (fail-soft input) and there is no previous index to carry from.
    assert_equal %w[chart:gex_mstr gex:combined gex:mstr
                    lppl:ledger scenario:history scenario:latest], keys
    # lppl:latest + btco:latest never made it into the index.
    refute_includes keys, 'lppl:latest'
    refute_includes keys, 'btco:latest'
  end

  # -- index carry: keep-last-good membership (2026-07-07 incident) --------

  # Run 1: everything healthy -> full index in the preview dir. Run 2
  # (2h later): gex:combined raises (the Deribit outage shape) -> the new
  # index CARRIES the last-good rows for gex:combined and
  # chart:gex_profile at their RUN-1 generated_at instead of dropping them.
  def test_index_carries_last_good_rows_for_skipped_keys
    fixture_dry_run
    later = NOW + 2 * 3600
    outage = lambda do |argv, t|
      raise 'HTTP 503 (deribit down)' if argv.include?('scripts/gex_btc_combined.rb')

      fixture_runner.call(argv, t)
    end
    Publish::Pipeline.run(now: later, source: 'testhost', dry_run: true,
                          runner: outage, out_dir: out_dir, status_dir: @dir)

    rows = JSON.parse(File.read(File.join(out_dir, 'index.json')))['payload']['keys']
    carried = rows.select { |r| %w[gex:combined chart:gex_profile].include?(r['key']) }
    assert_equal 2, carried.size, 'skipped keys must stay in the index'
    carried.each { |r| assert_equal iso(NOW), r['generated_at'], 'carried row keeps the OLD stamp' }
    # live keys carry the new stamp; the index stays sorted.
    fresh = rows.find { |r| r['key'] == 'gex:mstr' }
    assert_equal iso(later), fresh['generated_at']
    assert_equal rows.map { |r| r['key'] }.sort, rows.map { |r| r['key'] }
  end

  def test_index_carry_ignores_keys_no_longer_expected
    fixture_dry_run
    # doctor the previous index: add a retired key -- it must NOT haunt.
    path = File.join(out_dir, 'index.json')
    prev = JSON.parse(File.read(path))
    prev['payload']['keys'] << { 'key' => 'retired:key', 'generated_at' => iso(NOW) }
    File.write(path, JSON.pretty_generate(prev))

    outage = lambda do |argv, t|
      raise 'boom' if argv.include?('scripts/gex_btc_combined.rb')

      fixture_runner.call(argv, t)
    end
    Publish::Pipeline.run(now: NOW + 3600, source: 'testhost', dry_run: true,
                          runner: outage, out_dir: out_dir, status_dir: @dir)
    keys = JSON.parse(File.read(File.join(out_dir, 'index.json')))['payload']['keys']
           .map { |r| r['key'] }
    refute_includes keys, 'retired:key'
    assert_includes keys, 'gex:combined' # the expected skip IS carried
  end

  def test_no_previous_index_means_no_carry_and_no_crash
    s = dry_run # mixed runner, fresh out_dir -- several keys skipped
    keys = JSON.parse(File.read(File.join(out_dir, 'index.json')))['payload']['keys']
           .map { |r| r['key'] }
    refute_includes keys, 'lppl:latest'
    assert_includes s[:skipped], 'lppl:latest'
  end

  # -- junk-chart guard (2026-07-07 incident) -------------------------------

  def test_chart_skipped_when_input_payload_is_fail_soft
    err = capture_subprocess_io { dry_run }[1]
    assert_match(/SKIP chart:scenario_strip \(input scenario:latest unavailable\)/, err)
    refute File.exist?(File.join(out_dir, 'chart_scenario_strip.json')),
           'no chart artifact may be built from a fail-soft payload'
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
    line = File.read(File.join(@dir, 'publish.status'))
    # 7 written (gex:combined, gex:mstr, scenario:latest, 2 tails,
    # chart:gex_mstr, index) of 23 expected (10 producers + 2 tails +
    # 10 charts + 1 index); scenario_strip skipped on fail-soft input, the
    # five M8-6 producers skipped in the mixed path (so both vol_spread and
    # vol_spread_trend, which read the same skipped vol:spread key, skip too).
    # The synthetic tails demonstrate the M7-5 content-recency guard IN
    # ONE LINE: scenario:history's newest entry is NOW-1d (24h < 30h, FRESH,
    # no marker) but lppl:ledger's newest is NOW-10d (> 30h) -> ` OLD:...`.
    assert_equal "PUB DRY 7/23 keys 12:00 UTC OLD:lppl:ledger\n", line
  end

  def test_status_line_live_label
    # Fresh tails (< 30h) so this pin isolates the LIVE label: it is
    # byte-identical to the pre-M7-5 line, proving the OLD marker is
    # additive and stays quiet when the evidence is current.
    fresh = iso(NOW - 5 * 3600)
    File.write(File.join(@dir, 'scenario', 'history.jsonl'),
               JSON.generate('ts' => fresh, 'composite' => 0.1) + "\n")
    File.write(File.join(@dir, 'lppl', 'ledger.jsonl'),
               JSON.generate('ts' => fresh, 'bf' => 1.0) + "\n")
    inject_kv { FakeRes.new('200', 'ok') }
    Publish::Pipeline.run(now: NOW, source: 'testhost', dry_run: false,
                          runner: fixture_runner, env: ENV_OK, status_dir: @dir)
    # all ten sources + two tails + ten charts + index publish cleanly.
    assert_equal "PUB LIVE 23/23 keys 12:00 UTC\n", File.read(File.join(@dir, 'publish.status'))
  end

  # -- content-recency guard (M7-5, 2026-07-07 frozen-evidence incident) ---

  # Age BOTH synthetic tails past 30h -> the marker names BOTH keys, in
  # TAILS order (scenario:history before lppl:ledger).
  def test_status_line_marks_both_stale_tails
    stale = iso(NOW - 40 * 3600) # 40h > 30h
    File.write(File.join(@dir, 'scenario', 'history.jsonl'),
               JSON.generate('ts' => stale, 'composite' => 0.1) + "\n")
    File.write(File.join(@dir, 'lppl', 'ledger.jsonl'),
               JSON.generate('ts' => stale, 'bf' => 1.0) + "\n")
    dry_run
    assert_equal "PUB DRY 7/23 keys 12:00 UTC OLD:scenario:history,lppl:ledger\n",
                 File.read(File.join(@dir, 'publish.status'))
  end

  # Both tails fresh (< 30h) -> no marker at all.
  def test_status_line_no_marker_when_all_tails_fresh
    fresh = iso(NOW - 5 * 3600) # 5h < 30h
    File.write(File.join(@dir, 'scenario', 'history.jsonl'),
               JSON.generate('ts' => fresh, 'composite' => 0.1) + "\n")
    File.write(File.join(@dir, 'lppl', 'ledger.jsonl'),
               JSON.generate('ts' => fresh, 'bf' => 1.0) + "\n")
    dry_run
    assert_equal "PUB DRY 7/23 keys 12:00 UTC\n", File.read(File.join(@dir, 'publish.status'))
  end

  # -- BLIND data-integrity marker (M8-10, blind-zero incident) ------------

  # Freshest scenario entry blind + freshest lppl entry stale_input -> the
  # additive ` BLIND:<suite>` marker names both (BLIND_MARKERS order). Fresh
  # ts (< 30h) isolates BLIND from the OLD marker.
  def test_status_line_marks_blind_freshest_tails
    fresh = iso(NOW - 5 * 3600)
    File.write(File.join(@dir, 'scenario', 'history.jsonl'),
               JSON.generate('ts' => fresh, 'composite' => 0.0, 'blind' => true) + "\n")
    File.write(File.join(@dir, 'lppl', 'ledger.jsonl'),
               JSON.generate('ts' => fresh, 'bf' => 1.0, 'stale_input' => true) + "\n")
    dry_run
    assert_equal "PUB DRY 7/23 keys 12:00 UTC BLIND:scenario,lppl\n",
                 File.read(File.join(@dir, 'publish.status'))
  end

  # BLIND rides AFTER any OLD suffix when a tail is both stale AND blind.
  def test_status_line_blind_composes_with_old
    stale = iso(NOW - 40 * 3600) # 40h > 30h -> OLD too
    File.write(File.join(@dir, 'scenario', 'history.jsonl'),
               JSON.generate('ts' => stale, 'composite' => 0.0, 'blind' => true) + "\n")
    File.write(File.join(@dir, 'lppl', 'ledger.jsonl'),
               JSON.generate('ts' => stale, 'bf' => 1.0, 'stale_input' => true) + "\n")
    dry_run
    assert_equal "PUB DRY 7/23 keys 12:00 UTC " \
                 "OLD:scenario:history,lppl:ledger BLIND:scenario,lppl\n",
                 File.read(File.join(@dir, 'publish.status'))
  end

  # The marker reads the FRESHEST entry only: an older blind row followed by a
  # fresh healthy print is a permanent gap, NOT a live BLIND condition.
  def test_status_line_blind_only_on_freshest_entry
    File.write(File.join(@dir, 'scenario', 'history.jsonl'),
               [JSON.generate('ts' => iso(NOW - 2 * DAY), 'composite' => 0.0, 'blind' => true),
                JSON.generate('ts' => iso(NOW - 5 * 3600), 'composite' => 0.1)].join("\n") + "\n")
    File.write(File.join(@dir, 'lppl', 'ledger.jsonl'),
               JSON.generate('ts' => iso(NOW - 5 * 3600), 'bf' => 1.0) + "\n")
    dry_run
    refute_includes File.read(File.join(@dir, 'publish.status')), 'BLIND'
  end

  # A SKIPPED tail (no file) earns NO OLD marker -- the n/m shortfall
  # already flags it; only a PUBLISHED-but-stale tail is marked.
  def test_status_line_skipped_tail_is_not_marked_old
    FileUtils.rm(File.join(@dir, 'lppl', 'ledger.jsonl'))       # lppl:ledger SKIPPED
    fresh = iso(NOW - 5 * 3600)
    File.write(File.join(@dir, 'scenario', 'history.jsonl'),
               JSON.generate('ts' => fresh, 'composite' => 0.1) + "\n")
    dry_run
    # 6/23 now (one tail gone); no OLD marker (skip, not stale).
    assert_equal "PUB DRY 6/23 keys 12:00 UTC\n", File.read(File.join(@dir, 'publish.status'))
  end

  # -- real mode: v1:-prefixed PUTs + 403 abort ----------------------------

  FakeRes = Struct.new(:code, :body)
  ENV_OK = { 'CLOUDFLARE_ACCOUNT_ID' => 'acct1', 'CLOUDFLARE_KV_NAMESPACE_ID' => 'ns1',
             'CLOUDFLARE_API_TOKEN' => 'cf-secret' }.freeze

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
                              runner: fixture_runner, env: ENV_OK, status_dir: @dir)
    # every producer + tail + chart + index put exactly once, v1:-prefixed.
    assert_equal 23, calls.size
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
                            runner: fixture_runner, env: ENV_OK, status_dir: @dir)
    end
  end

  # -- chart envelopes (M3-5) ----------------------------------------------

  # With the real fixture payloads all ten charts build; pin their
  # preview files, keys, and ttl INHERITANCE (min of the input ttls).
  def test_chart_envelopes_written_with_inherited_ttls
    s = fixture_dry_run
    %w[chart:gex_profile chart:gex_mstr chart:scenario_strip
       chart:lppl_regime chart:btco_table chart:vol_surface chart:vol_spread
       chart:vol_spread_trend chart:vol_basis chart:gex_trend].each { |k| assert_includes s[:keys], k }

    mstr = JSON.parse(File.read(File.join(out_dir, 'chart_gex_mstr.json')))
    assert_equal 'chart:gex_mstr', mstr['key']
    assert_equal 1_800, mstr['ttl_hint_s'] # inherits gex:mstr (1800)

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

    # M8-6/M8-16 vol charts each inherit their single input's 1800s ttl
    # (vol_spread_trend shares vol_spread's vol:spread input).
    %w[vol_surface vol_spread vol_spread_trend vol_basis].each do |n|
      env = JSON.parse(File.read(File.join(out_dir, "chart_#{n}.json")))
      assert_equal 1_800, env['ttl_hint_s'], n
    end
    # gex_trend has TWO inputs (gex:trend 86400 + gex:check 1800) -> MIN 1800.
    trend = JSON.parse(File.read(File.join(out_dir, 'chart_gex_trend.json')))
    assert_equal 1_800, trend['ttl_hint_s']
    assert trend['payload']['title']['text'].include?('MP Δ') # cross-check suffix present
  end

  def test_index_lists_chart_keys
    fixture_dry_run
    idx = JSON.parse(File.read(File.join(out_dir, 'index.json')))
    keys = idx['payload']['keys'].map { |r| r['key'] }
    %w[chart:gex_profile chart:gex_mstr chart:scenario_strip
       chart:lppl_regime chart:btco_table chart:vol_surface chart:vol_spread
       chart:vol_spread_trend chart:vol_basis chart:gex_trend].each { |k| assert_includes keys, k }
    # index lists every published member but not itself: 10 sources + 2
    # tails + 10 charts.
    assert_equal 22, keys.size
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
