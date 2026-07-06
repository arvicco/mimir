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

    def initialize(repo:, loaded: {}, on_kickstart: nil)
      @repo = repo
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
      label == 'com.mimir.publish' ? 'run_publish.sh' : 'run_gex_snapshot.sh'
    end

    def print_result(label)
      return [false, "Could not find service #{label}"] unless @loaded[label]

      [true, "#{label} = {\n\tstate = not running\n\tlast exit code = 0\n" \
             "\tprogram = #{@repo}/ops/#{wrapper_for(label)}\n}\n"]
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
    File.join(@repo, 'data', 'gex_history')
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
    fake = FakeLaunchctl.new(repo: @repo)
    code = install(fake, input: StringIO.new("n\nn\n")) # decline both kickstarts
    assert_equal 0, code

    installed = File.join(@home, 'Library', 'LaunchAgents', 'com.mimir.publish.plist')
    assert File.exist?(installed), 'installed plist should exist'
    content = File.read(installed)
    refute_includes content, '__REPO__'
    assert_includes content, "#{@repo}/ops/run_publish.sh"
  end

  def test_install_aborts_when_preflight_fails
    # no env file written -> pre-flight fails -> no launchctl calls, exit 1
    fake = FakeLaunchctl.new(repo: @repo)
    code = install(fake, input: StringIO.new("n\nn\n"))
    assert_equal 1, code
    refute(fake.calls.any? { |c| c[0] == 'launchctl' }, 'must not touch launchctl on a failed pre-flight')
  end

  # ---- install: already-loaded reinstall -> bootout THEN bootstrap ---

  def test_reinstall_bootouts_before_bootstrap
    write_env
    fake = FakeLaunchctl.new(repo: @repo,
                             loaded: { 'com.mimir.publish' => true, 'com.mimir.gex-snapshot' => true })
    code = install(fake, input: StringIO.new("n\nn\n"))
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
    fake = FakeLaunchctl.new(repo: @repo) # nothing loaded
    install(fake, input: StringIO.new("n\nn\n"))
    refute(fake.calls.any? { |c| c[0, 2] == %w[launchctl bootout] },
           'a fresh install must not bootout')
  end

  # ---- install: declined kickstart skips verification ----------------

  def test_declined_kickstart_skips_verification
    write_env
    fake = FakeLaunchctl.new(repo: @repo)
    io = StringIO.new
    code = install(fake, input: StringIO.new("n\nn\n"), io: io)
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
      if label == 'com.mimir.publish'
        append_log('publish.log', "=== run_publish 2026-07-06T12:00:00Z\n" \
                                  "publish LIVE: 11 written, 0 skipped -> KV\n")
        write_status('PUB LIVE 11/11 keys 12:00 UTC', @now)
      else
        append_log('gex_snapshot.log', "=== run_gex_snapshot 2026-07-06T12:00:00Z\n" \
                                       "written: #{gdir}/2026-07-06.json\n")
        FileUtils.mkdir_p(gdir)
        File.write(File.join(gdir, '2026-07-06.json'), '{}')
      end
    end
    fake = FakeLaunchctl.new(repo: @repo, on_kickstart: on_kick)
    io = StringIO.new
    code = install(fake, input: StringIO.new("y\ny\n"), io: io, clock: fixed_clock)

    assert_equal 0, code, io.string
    assert_includes io.string, 'publish LIVE: 11 written'
    assert_includes io.string, "written: #{gdir}/2026-07-06.json"
    # every verification row PASSed, none FAILed
    refute_includes io.string.split('verification:').last, '[FAIL]'
    assert(fake.calls.any? { |c| c[0, 3] == %w[launchctl kickstart -k] })
  end

  # ---- install: log never grows -> timeout FAIL, sleeper called ------

  def test_kickstart_timeout_fail_row_and_sleeper_called
    write_env
    sleeps = []
    fake = FakeLaunchctl.new(repo: @repo, on_kickstart: ->(_l) {}) # log never grows
    io = StringIO.new
    # advancing clock: 100s per call, publish timeout 240s -> times out
    code = install(fake, input: StringIO.new("y\nn\n"), io: io,
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
    fake = FakeLaunchctl.new(repo: @repo, on_kickstart: on_kick)
    io = StringIO.new
    code = install(fake, input: StringIO.new("y\nn\n"), io: io, clock: fixed_clock)
    assert_equal 1, code
    assert_includes io.string, 'FAIL'
    assert_includes io.string, 'ABORT'
  end

  # ---- status --------------------------------------------------------

  def test_status_reports_loaded_and_not_loaded_without_error
    write_env
    fake = FakeLaunchctl.new(repo: @repo, loaded: { 'com.mimir.publish' => true })
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
    fake = FakeLaunchctl.new(repo: @repo)
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
    %w[com.mimir.publish com.mimir.gex-snapshot].each do |l|
      File.write(File.join(la, "#{l}.plist"), 'x')
    end
    fake = FakeLaunchctl.new(repo: @repo,
                             loaded: { 'com.mimir.publish' => true, 'com.mimir.gex-snapshot' => true })
    code = BTC::Ops.uninstall(home: @home, runner: fake.method(:call), io: StringIO.new,
                              input: StringIO.new("y\n"), uid: UID)
    assert_equal 0, code
    %w[com.mimir.publish com.mimir.gex-snapshot].each do |l|
      assert(fake.calls.any? { |c| c[0, 2] == %w[launchctl bootout] && c[2].end_with?(l) },
             "expected bootout of #{l}")
      refute File.exist?(File.join(la, "#{l}.plist")), "#{l}.plist must be deleted"
    end
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
