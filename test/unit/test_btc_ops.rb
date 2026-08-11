# frozen_string_literal: true

# M5-6: BTC::Ops -- owner-run launchd installer/verifier. Fully injectable:
# a stateful fake launchctl runner, StringIO io/input, tmp HOME + tmp repo
# (the real ops/ files copied in), and injected clock/sleeper so poll
# timeouts are exercised without real time. NO network, NO real launchctl:
# every launchctl call is asserted against the fake. Secret discipline is
# checked: env-file keys are reported present/MISSING only.

require_relative '../test_helper'
require_relative '../../lib/btc/ops'
require 'stringio'
require 'tmpdir'
require 'fileutils'

class TestBtcOps < Minitest::Test
  REAL_OPS = File.expand_path('../../ops', __dir__)
  KEYS = %w[CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID
            CLOUDFLARE_KV_NAMESPACE_ID FRED_API_KEY].freeze
  UID = 501

  # Stateful fake launchctl: tracks per-label loaded state so a reinstall
  # sees the service already loaded, and records every command it received.
  class FakeLaunchctl
    attr_reader :calls

    # program_root = the app-managed LIVE clone the plists point at (M9-12).
    def initialize(program_root:, loaded: {}, on_kickstart: nil)
      @program_root = program_root
      @loaded = loaded
      @on_kickstart = on_kickstart
      @calls = []
    end

    def call(cmd, _overrides = {})
      @calls << cmd
      return [true, '/bin/launchctl'] if cmd == ['which', 'launchctl']
      return [true, ''] unless cmd[0] == 'launchctl'

      case cmd[1]
      when 'print'    then print_result(cmd[2].split('/').last)
      when 'bootout'  then bootout(cmd[2].split('/').last)
      when 'bootstrap' then bootstrap(File.basename(cmd[3], '.plist'))
      when 'kickstart' then kickstart(cmd[3].split('/').last)
      else [true, '']
      end
    end

    private

    def wrapper_for(label)
      case label
      when 'com.mimir.publish'       then 'run_publish.sh'
      when 'com.mimir.gex-snapshot'  then 'run_gex_snapshot.sh'
      when 'com.mimir.suite-history' then 'run_suite_history.sh'
      else 'run_btco_alert.sh'
      end
    end

    def print_result(label)
      return [false, "Could not find service #{label}"] unless @loaded[label]

      [true, "#{label} = {\n\tstate = not running\n\tlast exit code = 0\n" \
             "\tprogram = #{@program_root}/ops/#{wrapper_for(label)}\n}\n"]
    end

    def bootout(label)
      was = @loaded[label]
      @loaded[label] = false
      [!!was, was ? '' : 'Boot-out failed: 3: No such process']
    end

    def bootstrap(label)
      @loaded[label] = true
      [true, '']
    end

    def kickstart(label)
      @on_kickstart&.call(label)
      [true, '']
    end
  end

  def setup
    @home = Dir.mktmpdir
    @repo = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@repo, 'ops'))
    Dir.glob(File.join(REAL_OPS, '*')).each { |f| FileUtils.cp(f, File.join(@repo, 'ops')) }
    # M9-12: the app-managed live clone the agents exec from -- a .git dir
    # plus the ops/ wrappers, exactly what `rake deploy` leaves behind.
    @live = BTC::Env.live_dir(@home)
    FileUtils.mkdir_p(File.join(@live, '.git'))
    FileUtils.mkdir_p(File.join(@live, 'ops'))
    Dir.glob(File.join(REAL_OPS, '*')).each { |f| FileUtils.cp(f, File.join(@live, 'ops')) }
    @envpath = File.join(@home, '.config', 'mimir', 'env')
    FileUtils.mkdir_p(File.dirname(@envpath))
    @now = Time.utc(2026, 7, 6, 12, 0, 0)
    @status_path = File.join(@home, 'publish.status')
  end

  def teardown
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@repo)
  end

  # ---- helpers -------------------------------------------------------

  def write_env(keys: KEYS, export: true, mode: 0o600)
    lines = keys.map { |k| "#{export ? 'export ' : ''}#{k}=value-#{k}" }
    File.write(@envpath, lines.join("\n") + "\n")
    File.chmod(mode, @envpath)
  end

  def fixed_clock
    -> { @now }
  end

  def advancing_clock(step)
    n = -1
    -> { n += 1; @now + (n * step) }
  end

  def append_log(name, text)
    dir = File.join(@home, 'Library', 'Logs', 'mimir')
    FileUtils.mkdir_p(dir)
    File.open(File.join(dir, name), 'a') { |f| f.write(text) }
  end

  def write_status(line, mtime)
    File.write(@status_path, line + "\n")
    File.utime(mtime, mtime, @status_path)
  end

  def gex_dir
    # Agents write under the data home now (wrapper pins BTC_DATA_DIR).
    File.join(BTC::Env.data_home(@home), 'gex_history')
  end

  def row(rows, label)
    rows.find { |r| r[0] == label }
  end

  # ---- pre-flight ----------------------------------------------------

  def test_preflight_fails_on_missing_env_file
    rows = BTC::Ops.preflight(home: @home, repo: @repo, env: {},
                              runner: ->(_c, _o = {}) { [true, ''] }, uid: UID)
    r = row(rows, 'env file')
    assert_match(/MISSING/, r[1])
    refute r[2]
  end

  def test_preflight_fails_on_wrong_mode
    write_env(mode: 0o644)
    rows = BTC::Ops.preflight(home: @home, repo: @repo, env: {},
                              runner: ->(_c, _o = {}) { [true, ''] }, uid: UID)
    r = row(rows, 'env file')
    assert_match(/must be 0600/, r[1])
    refute r[2]
  end

  def test_preflight_fails_on_missing_key
    write_env(keys: KEYS - ['FRED_API_KEY'])
    rows = BTC::Ops.preflight(home: @home, repo: @repo, env: {},
                              runner: ->(_c, _o = {}) { [true, ''] }, uid: UID)
    assert_equal 'MISSING', row(rows, 'env: FRED_API_KEY')[1]
    refute row(rows, 'env: FRED_API_KEY')[2]
    assert row(rows, 'env: CLOUDFLARE_API_TOKEN')[2] # the others still present
  end

  def test_preflight_passes_on_export_form
    write_env(export: true) # `export KEY=value`
    rows = BTC::Ops.preflight(home: @home, repo: @repo, env: {},
                              runner: ->(_c, _o = {}) { [true, '/bin/launchctl'] }, uid: UID)
    KEYS.each { |k| assert row(rows, "env: #{k}")[2], "#{k} should be present" }
    assert(rows.all? { |r| r[2] }, "all pre-flight rows should pass: #{rows.inspect}")
  end

  def test_preflight_never_prints_env_values
    write_env
    rows = BTC::Ops.preflight(home: @home, repo: @repo, env: {},
                              runner: ->(_c, _o = {}) { [true, ''] }, uid: UID)
    text = rows.map { |r| r.join(' ') }.join("\n")
    KEYS.each { |k| refute_includes text, "value-#{k}" }
  end

  def test_preflight_flags_launchctl_missing
    write_env
    rows = BTC::Ops.preflight(home: @home, repo: @repo, env: {},
                              runner: ->(_c, _o = {}) { [false, 'not found'] }, uid: UID)
    refute row(rows, 'launchctl')[2]
  end

  # ---- install: plist rendering + LaunchAgents write -----------------

  def test_install_renders_plist_without_placeholder_into_launchagents
    write_env
    fake = FakeLaunchctl.new(program_root: @live)
    code = install(fake, input: StringIO.new("n\nn\nn\nn\n")) # decline all kickstarts
    assert_equal 0, code

    installed = File.join(@home, 'Library', 'LaunchAgents', 'com.mimir.publish.plist')
    assert File.exist?(installed), 'installed plist should exist'
    content = File.read(installed)
    refute_includes content, '__REPO__'
    # M9-12: the program line points at the LIVE clone, not the dev tree.
    assert_includes content, "#{@live}/ops/run_publish.sh"
    refute_includes content, "#{@repo}/ops/run_publish.sh"
  end

  def test_install_aborts_when_preflight_fails
    # no env file written -> pre-flight fails -> no launchctl calls, exit 1
    fake = FakeLaunchctl.new(program_root: @live)
    code = install(fake, input: StringIO.new("n\nn\n"))
    assert_equal 1, code
    refute(fake.calls.any? { |c| c[0] == 'launchctl' }, 'must not touch launchctl on a failed pre-flight')
  end

  # ---- install: already-loaded reinstall -> bootout THEN bootstrap ---

  def test_reinstall_bootouts_before_bootstrap
    write_env
    fake = FakeLaunchctl.new(program_root: @live,
                             loaded: { 'com.mimir.publish' => true, 'com.mimir.gex-snapshot' => true })
    code = install(fake, input: StringIO.new("n\nn\nn\nn\n"))
    assert_equal 0, code

    bootout_i = fake.calls.index do |c|
      c[0, 2] == %w[launchctl bootout] && c[2].end_with?('com.mimir.publish')
    end
    bootstrap_i = fake.calls.index do |c|
      c[0, 2] == %w[launchctl bootstrap] && c[3].to_s.end_with?('com.mimir.publish.plist')
    end
    refute_nil bootout_i, 'expected a bootout for the already-loaded service'
    refute_nil bootstrap_i, 'expected a bootstrap'
    assert_operator bootout_i, :<, bootstrap_i, 'bootout must precede bootstrap'
  end

  def test_fresh_install_does_not_bootout
    write_env
    fake = FakeLaunchctl.new(program_root: @live) # nothing loaded
    install(fake, input: StringIO.new("n\nn\nn\nn\n"))
    refute(fake.calls.any? { |c| c[0, 2] == %w[launchctl bootout] },
           'a fresh install must not bootout')
  end

  # ---- install: declined kickstart skips verification ----------------

  def test_declined_kickstart_skips_verification
    write_env
    fake = FakeLaunchctl.new(program_root: @live)
    io = StringIO.new
    code = install(fake, input: StringIO.new("n\nn\nn\nn\n"), io: io)
    assert_equal 0, code
    refute(fake.calls.any? { |c| c[0, 2] == %w[launchctl kickstart] },
           'declined kickstart must not run launchctl kickstart')
    assert_includes io.string, 'skipped (declined)'
    refute_includes io.string, ': run' # no run verification rows
  end

  # ---- install: accepted kickstart, log grows -> PASS rows -----------

  def test_accepted_kickstart_pass_rows
    write_env
    gdir = gex_dir
    on_kick = lambda do |label|
      case label
      when 'com.mimir.publish'
        append_log('publish.log', "=== run_publish 2026-07-06T12:00:00Z\n" \
                                  "publish LIVE: 11 written, 0 skipped -> KV\n")
        write_status('PUB LIVE 11/11 keys 12:00 UTC', @now)
      when 'com.mimir.gex-snapshot'
        append_log('gex_snapshot.log', "=== run_gex_snapshot 2026-07-06T12:00:00Z\n" \
                                       "written: #{gdir}/2026-07-06.json\n")
        FileUtils.mkdir_p(gdir)
        File.write(File.join(gdir, '2026-07-06.json'), '{}')
      when 'com.mimir.btco-alert'
        append_log('btco_alert.log', "=== run_btco_alert 2026-07-06T12:00:00Z\n" \
                                     "alert: no new filings -> quiet\n")
      else # com.mimir.suite-history
        append_log('suite_history.log', "=== run_suite_history 2026-07-06T12:00:00Z\n" \
                                        "suite-history: lppl updated -- LPPL SUPPORTED +0.55\n" \
                                        "suite-history: scenario updated -- COMPOSITE +0.20\n" \
                                        "suite-history OK: 2/2 suites updated (lppl, scenario)\n")
      end
    end
    fake = FakeLaunchctl.new(program_root: @live, on_kickstart: on_kick)
    io = StringIO.new
    code = install(fake, input: StringIO.new("y\ny\ny\ny\n"), io: io, clock: fixed_clock)

    assert_equal 0, code, io.string
    assert_includes io.string, 'publish LIVE: 11 written'
    assert_includes io.string, "written: #{gdir}/2026-07-06.json"
    # btco-alert retired 2026-08-10 -- its row must be gone
    refute_includes io.string, 'alert:'
    assert_includes io.string, 'suite-history OK: 2/2 suites updated'
    # every verification row PASSed, none FAILed
    refute_includes io.string.split('verification:').last, '[FAIL]'
    assert(fake.calls.any? { |c| c[0, 3] == %w[launchctl kickstart -k] })
  end

  # ---- install: log never grows -> timeout FAIL, sleeper called ------

  def test_kickstart_timeout_fail_row_and_sleeper_called
    write_env
    sleeps = []
    fake = FakeLaunchctl.new(program_root: @live, on_kickstart: ->(_l) {}) # log never grows
    io = StringIO.new
    # advancing clock: 100s per call, publish timeout 240s -> times out
    code = install(fake, input: StringIO.new("y\nn\nn\nn\n"), io: io,
                   clock: advancing_clock(100), sleeper: ->(s) { sleeps << s })
    assert_equal 1, code
    assert_includes io.string, 'TIMEOUT'
    refute_empty sleeps, 'the poll must have slept while waiting'
    assert_equal [5], sleeps.uniq, 'poll steps are 5s'
  end

  # ---- install: failure signature (ABORT) -> FAIL row ----------------

  def test_kickstart_failure_signature_fail_row
    write_env
    on_kick = lambda do |label|
      append_log('publish.log', "=== run_publish 2026-07-06T12:00:00Z\nABORT: producer crashed\n") if label == 'com.mimir.publish'
    end
    fake = FakeLaunchctl.new(program_root: @live, on_kickstart: on_kick)
    io = StringIO.new
    code = install(fake, input: StringIO.new("y\nn\nn\nn\n"), io: io, clock: fixed_clock)
    assert_equal 1, code
    assert_includes io.string, 'FAIL'
    assert_includes io.string, 'ABORT'
  end

  # ---- status --------------------------------------------------------

  def test_status_reports_loaded_and_not_loaded_without_error
    write_env
    fake = FakeLaunchctl.new(program_root: @live, loaded: { 'com.mimir.publish' => true })
    write_status('PUB LIVE 11/11 keys 12:00 UTC', @now - 120)
    io = StringIO.new
    code = BTC::Ops.status(home: @home, repo: @repo, env: {}, runner: fake.method(:call),
                           io: io, clock: fixed_clock, uid: UID, status_path: @status_path)
    assert_equal 0, code
    assert_includes io.string, 'com.mimir.publish'
    assert_includes io.string, 'loaded' # publish loaded
    assert_includes io.string, 'not loaded' # gex-snapshot not loaded (a row, not an error)
    assert_includes io.string, 'PUB LIVE 11/11 keys 12:00 UTC'
  end

  # ---- uninstall -----------------------------------------------------

  def test_uninstall_declined_does_nothing
    la = File.join(@home, 'Library', 'LaunchAgents')
    FileUtils.mkdir_p(la)
    File.write(File.join(la, 'com.mimir.publish.plist'), 'x')
    fake = FakeLaunchctl.new(program_root: @live)
    io = StringIO.new
    code = BTC::Ops.uninstall(home: @home, runner: fake.method(:call), io: io,
                              input: StringIO.new("n\n"), uid: UID)
    assert_equal 0, code
    assert_includes io.string, 'cancelled'
    refute(fake.calls.any? { |c| c[0, 2] == %w[launchctl bootout] })
    assert File.exist?(File.join(la, 'com.mimir.publish.plist')), 'plist must remain'
  end

  def test_uninstall_accepted_bootouts_and_deletes
    la = File.join(@home, 'Library', 'LaunchAgents')
    FileUtils.mkdir_p(la)
    labels = %w[com.mimir.publish com.mimir.gex-snapshot com.mimir.suite-history]
    labels.each { |l| File.write(File.join(la, "#{l}.plist"), 'x') }
    fake = FakeLaunchctl.new(program_root: @live, loaded: labels.to_h { |l| [l, true] })
    code = BTC::Ops.uninstall(home: @home, runner: fake.method(:call), io: StringIO.new,
                              input: StringIO.new("y\n"), uid: UID)
    assert_equal 0, code
    labels.each do |l|
      assert(fake.calls.any? { |c| c[0, 2] == %w[launchctl bootout] && c[2].end_with?(l) },
             "expected bootout of #{l}")
      refute File.exist?(File.join(la, "#{l}.plist")), "#{l}.plist must be deleted"
    end
  end

  def test_agents_list_covers_three_agents_btco_alert_retired
    # btco-alert retired 2026-08-10 (owner ruling: BTCo frozen) -- its
    # absence here is what keeps ops:install from resurrecting it.
    labels = BTC::Ops::AGENTS.map(&:first)
    assert_equal %w[com.mimir.publish com.mimir.gex-snapshot
                    com.mimir.suite-history], labels
  end

  # ---- M9-12: live-runtime pre-flight --------------------------------

  def test_preflight_flags_missing_live_runtime
    write_env
    FileUtils.remove_entry(File.join(@live, '.git')) # deploy hasn't run
    rows = BTC::Ops.preflight(home: @home, repo: @repo, env: {},
                              runner: ->(_c, _o = {}) { [true, '/bin/launchctl'] }, uid: UID)
    r = row(rows, 'live runtime')
    refute r[2]
    assert_match(/run rake deploy first/, r[1])
  end

  def test_preflight_live_runtime_present_passes
    write_env
    rows = BTC::Ops.preflight(home: @home, repo: @repo, env: {},
                              runner: ->(_c, _o = {}) { [true, '/bin/launchctl'] }, uid: UID)
    r = row(rows, 'live runtime')
    assert r[2], 'live runtime row must pass when the clone is present'
    assert_includes r[1], @live
  end

  # ---- M9-12: data migration planner ---------------------------------

  # Seed a dev-tree suite dir with +files+ (name => body); returns the dir.
  def seed_dev(rel, files)
    dir = File.join(@repo, rel)
    FileUtils.mkdir_p(dir)
    files.each { |name, body| File.write(File.join(dir, name), body) }
    dir
  end

  def data_home
    BTC::Env.data_home(@home)
  end

  def test_migration_maps_each_suite_to_the_data_dir_seam_layout
    rows = BTC::Ops.migration_rows(repo: @repo, data_home: data_home, apply: false)
    got = rows.to_h { |r| [r[:suite], r[:dest]] }
    BTC::Ops::MIGRATION_SUITES.each do |suite, rel|
      assert_equal File.join(data_home, suite), got[suite]
      assert_equal File.join(@repo, rel), rows.find { |r| r[:suite] == suite }[:source]
    end
  end

  def test_migration_copies_all_files_then_is_idempotent
    seed_dev(File.join('scripts', 'lppl', 'data'), 'ledger.jsonl' => "a\n", 'params.json' => '{}')
    seed_dev(File.join('data', 'gex_history'), '2026-07-06.json' => '{}')

    first = BTC::Ops.migration_rows(repo: @repo, data_home: data_home, apply: true)
    assert_equal 3, first.sum { |r| r[:copied] }
    assert_equal 0, first.sum { |r| r[:errors] }
    assert_equal "a\n", File.read(File.join(data_home, 'lppl', 'ledger.jsonl'))
    assert File.exist?(File.join(data_home, 'gex_history', '2026-07-06.json'))

    # cp preserved mtime, so a second apply copies nothing (idempotent).
    second = BTC::Ops.migration_rows(repo: @repo, data_home: data_home, apply: true)
    assert_equal 0, second.sum { |r| r[:copied] }
    assert_equal 3, second.sum { |r| r[:skipped] }
  end

  def test_migration_never_clobbers_a_newer_destination
    src = seed_dev(File.join('scripts', 'scenario', 'data'), 'history.jsonl' => "old\n")
    dst_dir = File.join(data_home, 'scenario')
    FileUtils.mkdir_p(dst_dir)
    dst = File.join(dst_dir, 'history.jsonl')
    File.write(dst, "newer\n")
    # make destination strictly newer than source
    File.utime(Time.now + 60, Time.now + 60, dst)
    File.utime(Time.now - 60, Time.now - 60, File.join(src, 'history.jsonl'))

    rows = BTC::Ops.migration_rows(repo: @repo, data_home: data_home, apply: true)
    scen = rows.find { |r| r[:suite] == 'scenario' }
    assert_equal 0, scen[:copied]
    assert_equal 1, scen[:skipped]
    assert_equal "newer\n", File.read(dst), 'newer destination data must survive'
  end

  def test_migration_dry_plan_writes_nothing
    seed_dev(File.join('data', 'vol_spread'), 'history.jsonl' => "x\n")
    rows = BTC::Ops.migration_rows(repo: @repo, data_home: data_home, apply: false)
    vs = rows.find { |r| r[:suite] == 'vol_spread' }
    assert_equal 1, vs[:copied] # planned
    refute File.exist?(File.join(data_home, 'vol_spread', 'history.jsonl')),
           'a dry plan must not write to the data home'
  end

  # ---- M9-12: install runs the migration interactively ---------------

  def test_install_migrates_when_confirmed
    write_env
    seed_dev(File.join('scripts', 'lppl', 'data'), 'ledger.jsonl' => "row\n")
    fake = FakeLaunchctl.new(program_root: @live)
    io = StringIO.new
    # inputs: migration 'y', then decline the three kickstarts
    code = install(fake, input: StringIO.new("y\nn\nn\nn\n"), io: io)
    assert_equal 0, code
    assert_includes io.string, 'migration inventory'
    assert_includes io.string, 'migrated: 1 copied'
    assert_equal "row\n", File.read(File.join(data_home, 'lppl', 'ledger.jsonl'))
  end

  def test_install_skips_migration_when_declined
    write_env
    seed_dev(File.join('scripts', 'lppl', 'data'), 'ledger.jsonl' => "row\n")
    fake = FakeLaunchctl.new(program_root: @live)
    io = StringIO.new
    code = install(fake, input: StringIO.new("n\nn\nn\nn\n"), io: io)
    assert_equal 0, code
    assert_includes io.string, 'migration skipped'
    refute File.exist?(File.join(data_home, 'lppl', 'ledger.jsonl')),
           'a declined migration must copy nothing'
  end

  # ---- tmux health line ----------------------------------------------

  # Fake tmux server: answers the PATH check, the running probe, `show -gv`
  # queries (status count / interval / each status-format[i]) and the
  # publish_health.rb execution, and records every command -- including any
  # `tmux set -g` (which must NOT appear when the prompt is declined).
  class FakeTmux
    attr_reader :calls

    def initialize(running: true, on_path: true, status: '1', interval: '15',
                   formats: {}, health: 'PUB 11/11 0:37')
      @running = running
      @on_path = on_path
      @status = status
      @interval = interval
      @formats = formats
      @health = health
      @calls = []
    end

    def call(cmd, _overrides = {})
      @calls << cmd
      return [@on_path, @on_path ? '/usr/bin/tmux' : ''] if cmd == ['which', 'tmux']
      return [true, @health] if cmd[0] == 'ruby'
      return [true, ''] unless cmd[0] == 'tmux'

      case cmd[1]
      when 'display' then @running ? [true, 'ok'] : [false, 'no server running on /tmp/tmux-501/default']
      when 'show'    then show(cmd[3])
      when 'set'     then [true, '']
      else [true, '']
      end
    end

    private

    def show(key)
      case key
      when 'status'          then [true, @status]
      when 'status-interval' then [true, @interval]
      when /\Astatus-format\[(\d+)\]\z/
        i = Regexp.last_match(1).to_i
        @formats.key?(i) ? [true, @formats[i]] : [true, '']
      else [true, '']
      end
    end
  end

  def dedicated_value
    "#[align=right]#(ruby #{@repo}/ops/publish_health.rb)#(cat /tmp/ingest.status 2>/dev/null)"
  end

  def run_tmux(fake, input: "n\n", home: @home)
    io = StringIO.new
    code = BTC::Ops.tmux(home: home, repo: @repo, env: {}, runner: fake.method(:call),
                         io: io, input: StringIO.new(input))
    [code, io]
  end

  def set_calls(fake)
    fake.calls.select { |c| c[0, 3] == %w[tmux set -g] }
  end

  def test_tmux_no_server_prints_static_snippet_with_real_repo_path
    fake = FakeTmux.new(running: false)
    code, io = run_tmux(fake)
    assert_equal 0, code
    assert_includes io.string, "#{@repo}/ops/publish_health.rb"
    refute_includes io.string, '<you>'
    assert_includes io.string, 'set -g status 2'
    assert(set_calls(fake).empty?, 'a dead server must not receive set -g')
  end

  def test_tmux_missing_binary_returns_1
    fake = FakeTmux.new(on_path: false)
    code, io = run_tmux(fake)
    assert_equal 1, code
    assert_includes io.string, 'not found on PATH'
  end

  def test_tmux_token_already_present_is_idempotent
    fake = FakeTmux.new(status: '2', formats: { 1 => dedicated_value })
    code, io = run_tmux(fake)
    assert_equal 0, code
    assert_includes io.string, 'already present in status-format[1]'
    assert_includes io.string, 'nothing to do'
    assert(set_calls(fake).empty?, 'present token must trigger no set -g')
    assert_includes io.string, 'set -g status-format[1]' # persistence reference still printed
  end

  # A bar installed BEFORE M7-2 carries the health token without the
  # ingest fragment: ops:tmux must offer the in-place append, not claim
  # "nothing to do" (review catch on the M7-2 packet -- the gold bar).
  def test_tmux_health_only_line_offers_ingest_append
    old_line = "#[bold]#S#[align=right]#(ruby #{@repo}/ops/publish_health.rb)"
    fake = FakeTmux.new(status: '2', formats: { 1 => old_line })
    code, io = run_tmux(fake, input: "y\n")
    assert_equal 0, code
    refute_includes io.string, 'nothing to do'
    assert_includes io.string, 'append ingest token to the existing line'
    upgraded = "#{old_line}#(cat /tmp/ingest.status 2>/dev/null)"
    assert_includes io.string, "status-format[1] = '#{upgraded}'"
    set = set_calls(fake).find { |c| c[3] == 'status-format[1]' }
    refute_nil set, 'apply must set the upgraded format'
    assert_equal upgraded, set[4]
  end

  def test_tmux_free_line_proposes_dedicated_form_at_index_1
    fake = FakeTmux.new(status: '2', formats: { 0 => 'main line', 1 => '' })
    code, io = run_tmux(fake) # decline the apply prompt
    assert_equal 0, code
    assert_includes io.string, "status-format[1] = '#{dedicated_value}'"
    assert_includes io.string, 'dedicated line'
  end

  def test_tmux_no_free_line_merges_onto_last_occupied
    user_fmt = '#[align=left]my status'
    fake = FakeTmux.new(status: '2', formats: { 0 => 'main line', 1 => user_fmt })
    code, io = run_tmux(fake)
    assert_equal 0, code
    assert_includes io.string, "status-format[1] = '#{user_fmt}#{dedicated_value}'"
    assert_includes io.string, 'merge onto last line'
  end

  # The proposed fragment carries the BTCo discovery-alert token in the
  # SAME right-align run as the publish health command (D8-a).
  def test_tmux_fragment_carries_the_ingest_token
    fake = FakeTmux.new(status: '2', formats: { 0 => 'main line', 1 => '' })
    code, io = run_tmux(fake)
    assert_equal 0, code
    assert_includes io.string, '#(cat /tmp/ingest.status 2>/dev/null)'
    assert_includes io.string,
                    "#[align=right]#(ruby #{@repo}/ops/publish_health.rb)#(cat /tmp/ingest.status 2>/dev/null)"
  end

  def test_tmux_declined_prompt_makes_no_set_but_prints_persistence
    fake = FakeTmux.new(status: '2', formats: { 1 => '' })
    code, io = run_tmux(fake, input: "n\n")
    assert_equal 0, code
    assert(set_calls(fake).empty?, 'declined apply must run no set -g')
    assert_includes io.string, "set -g status-format[1] '#{dedicated_value}'"
  end

  def test_tmux_accepted_prompt_sets_format_then_offers_interval
    fake = FakeTmux.new(status: '2', interval: '0', formats: { 1 => '' })
    code, io = run_tmux(fake, input: "y\ny\n") # apply yes, interval-offer yes
    assert_equal 0, code
    sets = set_calls(fake)
    fmt_i = sets.index { |c| c[3] == 'status-format[1]' && c[4] == dedicated_value }
    int_i = sets.index { |c| c[3] == 'status-interval' && c[4] == '30' }
    refute_nil fmt_i, 'expected a set -g status-format[1] on apply'
    refute_nil int_i, 'expected the interval offer to set status-interval 30'
    assert_operator fmt_i, :<, int_i, 'format must be set before the interval'
    assert_includes io.string, 'EXPECT:'
  end

  def test_tmux_never_writes_any_file
    empty = Dir.mktmpdir
    before = Dir.glob(File.join(empty, '**', '*'), File::FNM_DOTMATCH).sort
    fake = FakeTmux.new(status: '2', interval: '0', formats: { 1 => '' })
    BTC::Ops.tmux(home: empty, repo: @repo, env: {}, runner: fake.method(:call),
                  io: StringIO.new, input: StringIO.new("y\ny\n"))
    after = Dir.glob(File.join(empty, '**', '*'), File::FNM_DOTMATCH).sort
    assert_equal before, after, 'ops:tmux must never create a file under HOME'
  ensure
    FileUtils.remove_entry(empty)
  end

  # ---- run(): refusals ----------------------------------------------

  def test_run_refuses_under_ci
    e = assert_raises(BTC::Ops::Error) do
      BTC::Ops.run(['status'], env: { 'CI' => '1' }, io: StringIO.new, input: StringIO.new)
    end
    assert_match(/Golden Rule 3/, e.message)
    assert_match(/REFUSES/, e.message)
  end

  def test_run_refuses_without_a_tty
    # StringIO#tty? is false -> owner-interactive command refuses
    e = assert_raises(BTC::Ops::Error) do
      BTC::Ops.run(['status'], env: {}, io: StringIO.new, input: StringIO.new(''))
    end
    assert_match(/TTY/, e.message)
  end

  private

  # Shared install invocation with the tmp home/repo, a fake launchctl, and
  # injected io/input/clock/sleeper.
  def install(fake, input:, io: StringIO.new, clock: fixed_clock, sleeper: ->(_s) {})
    BTC::Ops.install(home: @home, repo: @repo, env: {}, runner: fake.method(:call),
                     io: io, input: input, clock: clock, sleeper: sleeper,
                     uid: UID, status_path: @status_path)
  end
end
