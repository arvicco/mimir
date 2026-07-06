# frozen_string_literal: true
#
# ops.rb -- owner-run launchd agent installer / verifier (M5-6, Phase 5).
#
#   rake ops:install      # OWNER-RUN, interactive: pre-flight, install both
#                         # launchd agents, verify, optionally kickstart +
#                         # poll each first run to PASS/FAIL
#   rake ops:status       # one-shot report: agent state, log markers,
#                         # status-file age, newest snapshot
#   rake ops:uninstall    # confirm, bootout both agents, remove installed
#                         # plists
#
# Golden Rule 3 (CLAUDE.md): installing launchd agents, real publishes and
# KV mutation are HUMAN actions. These tasks are never run by the loop and
# REFUSE (a) under CI (ENV['CI'] set) and (b) when stdin is not a TTY --
# the second refusal is ALSO what locks the automation loop out, since its
# shell has no controlling terminal.
#
# This module mirrors lib/btc/deploy.rb's house pattern: an injectable
# `runner` lambda(argv) -> [ok, output] for every launchctl/system call, an
# injectable `io`/`input` for prompts, `home`/`repo`/`env`/`clock`/`sleeper`
# so the whole flow runs under tests with NO real launchctl, NO network and
# NO real install. The offline ops/ artifact audit is REUSED from
# BTC::Health.scan_ops, never duplicated here.
#
# SECURITY: the env file is checked for presence + mode 0600 and, per key,
# a line-anchored `^(export +)?KEY=.` presence regex ONLY -- values are
# never read beyond that boolean, never printed. Every line bound for
# output passes BTC::Env.redact as defense in depth.

require 'time'
require 'fileutils'
require_relative 'env'
require_relative 'health'

module BTC
  module Ops
    class Error < StandardError; end

    REPO_PLACEHOLDER    = '__REPO__'
    DEFAULT_STATUS_PATH = '/tmp/publish.status'
    # Mirror of Ops::PublishHealth's frozen status-line contract (kept local
    # so lib/ does not depend backwards on ops/): PUB LIVE|DRY n/m keys ...
    PUBLISH_STATUS_RE   = %r{\APUB (\w+) (\d+)/(\d+) keys}
    # A run that aborts before/at the summary. `exit 78` = the wrapper's
    # EX_CONFIG (unreadable env file); ABORT = a producer bail.
    FAILURE_RE          = /ABORT|exit 78/
    STATUS_FRESH_S      = 600 # /tmp/publish.status mtime must be within 10 min

    REQUIRED_KEYS = %w[CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID
                       CLOUDFLARE_KV_NAMESPACE_ID FRED_API_KEY].freeze

    # Each agent: [label, wrapper_basename, opts]. opts drives the log tail
    # scan (marker + success_re), the kickstart poll timeout, and the kind
    # of post-run freshness check. Content mirrors the committed ops/ files.
    AGENTS = [
      ['com.mimir.publish', 'run_publish.sh',
       log: 'publish.log', marker: '=== run_publish',
       success_re: /publish LIVE: \d+ written/, timeout: 240, kind: :publish],
      ['com.mimir.gex-snapshot', 'run_gex_snapshot.sh',
       log: 'gex_snapshot.log', marker: '=== run_gex_snapshot',
       success_re: /\b(written|skipped \(today's file exists\)|partial)/,
       timeout: 90, kind: :snapshot]
    ].freeze

    module_function

    # ---- ENV / mode helpers (pure) -------------------------------------

    def truthy(val)
      s = val.to_s.strip.downcase
      !s.empty? && s != '0' && s != 'false'
    end

    def ci_refusal_message
      'rake ops:* REFUSES to run under CI (ENV["CI"] is set). Golden Rule 3: ' \
      'installing launchd agents, real publishes and KV mutation are HUMAN ' \
      'actions -- never run by the loop or CI. Run this by hand on the box.'
    end

    def tty_refusal_message
      'rake ops:* is an owner-interactive command (it prompts for kickstart ' \
      'and uninstall confirmation) and needs a TTY on stdin. This shell has ' \
      'none -- which is ALSO what locks the automation loop out. Run it by ' \
      'hand in a terminal on the box.'
    end

    def env_file_path(home, env)
      override = env['MIMIR_ENV_FILE']
      override && !override.empty? ? override : File.join(home, '.config', 'mimir', 'env')
    end

    # Line-anchored presence check ONLY -- reports whether the key is set,
    # never what to. Both `KEY=value` and `export KEY=value` forms count
    # (the wrappers source either).
    def key_present?(content, key)
      content.match?(/^(?:export +)?#{Regexp.escape(key)}=./)
    end

    def service(uid, label)
      "gui/#{uid}/#{label}"
    end

    def service_domain(uid)
      "gui/#{uid}"
    end

    def gex_history_dir(repo, env)
      base = env['BTC_DATA_DIR']
      base && !base.empty? ? File.join(base, 'gex_history') : File.join(repo, 'data', 'gex_history')
    end

    # ---- pre-flight ----------------------------------------------------

    # Rows [[label, detail, ok]]. Presence-only for secrets; scan_ops REUSED.
    def preflight(home:, repo:, env:, runner:, uid: Process.uid)
      rows = []
      path = env_file_path(home, env)
      content = ''
      if File.exist?(path)
        mode = File.stat(path).mode & 0o777
        ok   = mode == 0o600
        rows << ['env file', ok ? format('present, mode %04o', mode) : format('mode %04o (must be 0600)', mode), ok]
        content = begin
          File.read(path)
        rescue SystemCallError
          ''
        end
      else
        rows << ['env file', "MISSING (#{path})", false]
      end

      REQUIRED_KEYS.each do |k|
        present = !content.empty? && key_present?(content, k)
        rows << ["env: #{k}", present ? 'present' : 'MISSING', present]
      end

      rv_ok = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3')
      rows << ['ruby', rv_ok ? RUBY_VERSION : "#{RUBY_VERSION} (need >= 3.3)", rv_ok]

      AGENTS.each do |_, wrapper, _|
        wpath = File.join(repo, 'ops', wrapper)
        exist = File.exist?(wpath)
        rows << ["wrapper #{wrapper}", exist ? 'present' : "MISSING (#{wpath})", exist]
      end
      AGENTS.each do |label, _, _|
        ppath = File.join(repo, 'ops', "#{label}.plist")
        exist = File.exist?(ppath)
        rows << ["plist #{label}", exist ? 'present' : "MISSING (#{ppath})", exist]
      end

      problems = BTC::Health.scan_ops(File.join(repo, 'ops'))
      rows << ['ops/ audit (scan_ops)', problems.empty? ? 'clean' : format('%d problem(s)', problems.size), problems.empty?]

      lc_ok, = runner.call(['which', 'launchctl'])
      rows << ['launchctl', lc_ok ? 'present' : 'MISSING (not on PATH)', !!lc_ok]

      rows
    end

    # ---- install -------------------------------------------------------

    def install(home:, repo:, env:, runner:, io:, input:, clock:, sleeper:,
                uid: Process.uid, status_path: DEFAULT_STATUS_PATH)
      pf = preflight(home: home, repo: repo, env: env, runner: runner, uid: uid)
      print_table(io, 'pre-flight', pf, pass: 'ok')
      unless pf.all? { |r| r[2] }
        io.puts 'pre-flight failed -- fix the FAIL rows above before installing.'
        return 1
      end

      rows = []
      AGENTS.each do |agent|
        rows.concat(install_agent(agent, home: home, repo: repo, env: env, runner: runner, io: io,
                                   input: input, clock: clock, sleeper: sleeper,
                                   uid: uid, status_path: status_path))
      end

      io.puts ''
      print_table(io, 'verification', rows, pass: 'PASS')
      rows.all? { |r| r[2] } ? 0 : 1
    end

    # Render + write the plist, (re)bootstrap idempotently, verify the
    # program line, then the interactive kickstart. Returns verification
    # rows for this agent.
    def install_agent(agent, home:, repo:, env:, runner:, io:, input:, clock:, sleeper:, uid:, status_path:)
      label, wrapper, opts = agent
      rows = []
      svc          = service(uid, label)
      wrapper_path = File.join(repo, 'ops', wrapper)

      template = File.read(File.join(repo, 'ops', "#{label}.plist"))
      rendered = template.gsub(REPO_PLACEHOLDER, repo)
      installed = File.join(home, 'Library', 'LaunchAgents', "#{label}.plist")
      FileUtils.mkdir_p(File.dirname(installed))
      File.write(installed, rendered)
      clean = !rendered.include?(REPO_PLACEHOLDER)
      rows << ["#{label}: plist", clean ? "installed #{installed}" : 'still contains __REPO__', clean]

      # Idempotent reinstall: if the service is already loaded, bootout
      # before bootstrap (a second bootstrap of a live label errors).
      loaded, = runner.call(['launchctl', 'print', svc])
      runner.call(['launchctl', 'bootout', svc]) if loaded

      boot_ok, boot_out = runner.call(['launchctl', 'bootstrap', service_domain(uid), installed])

      # Verify by the program line only. State ('not running' is the healthy
      # idle state for an interval agent) is informational -- NOT asserted.
      print_ok, print_out = runner.call(['launchctl', 'print', svc])
      program_ok = print_ok && print_out.to_s.match?(/program\s*=\s*#{Regexp.escape(wrapper_path)}/)
      detail = if program_ok
                 "program = #{wrapper_path}"
               elsif !boot_ok
                 "bootstrap failed: #{BTC::Env.redact(boot_out.to_s).lines.first.to_s.strip}"
               else
                 'program line not found in launchctl print'
               end
      rows << ["#{label}: bootstrap", detail, !!program_ok]

      if ask?(io, input, "kickstart #{label} now? [y/N]")
        rows.concat(kickstart_agent(agent, home: home, runner: runner, clock: clock,
                                    sleeper: sleeper, uid: uid, status_path: status_path, env: env, repo: repo))
      else
        rows << ["#{label}: kickstart", 'skipped (declined) -- verify a scheduled run later', true]
      end
      rows
    end

    # Kickstart the agent, then poll its log for a NEW run beyond the
    # recorded offset. For publish, additionally check /tmp/publish.status
    # freshness; for snapshot the summary line already names the dated file.
    def kickstart_agent(agent, home:, runner:, clock:, sleeper:, uid:, status_path:, env:, repo:)
      label, _, opts = agent
      rows = []
      log_path = File.join(home, 'Library', 'Logs', 'mimir', opts[:log])
      offset   = File.exist?(log_path) ? File.size(log_path) : 0

      runner.call(['launchctl', 'kickstart', '-k', service(uid, label)])

      status, detail = poll_run(path: log_path, offset: offset, marker: opts[:marker],
                                success_re: opts[:success_re], timeout: opts[:timeout],
                                clock: clock, sleeper: sleeper)
      run_ok  = status == :pass
      run_txt = run_ok ? BTC::Env.redact(detail) : format('%s: %s', status.to_s.upcase, BTC::Env.redact(detail))
      rows << ["#{label}: run", run_txt, run_ok]

      case opts[:kind]
      when :publish
        rows << publish_status_row(label, status_path, clock)
      when :snapshot
        rows << snapshot_file_row(label, repo, env, clock)
      end
      rows
    end

    # Read the log beyond +offset+ each step; on a new marker line, look for
    # the success_re (PASS) or FAILURE_RE (FAIL) after it. Times out via the
    # injected clock/sleeper (5s steps) -- no real sleeping in tests.
    def poll_run(path:, offset:, marker:, success_re:, timeout:, clock:, sleeper:)
      start = clock.call
      loop do
        chunk = read_since(path, offset)
        res = scan_chunk(chunk, marker, success_re)
        return res if res
        return [:timeout, format('no completed run within %ds', timeout)] if clock.call - start >= timeout

        sleeper.call(5)
      end
    end

    # -> [:pass, line] | [:fail, line] | nil (marker/summary not yet there).
    def scan_chunk(chunk, marker, success_re)
      idx = chunk.index(marker)
      return nil unless idx

      after = chunk[idx..]
      if (line = after.lines.find { |l| l.match?(success_re) })
        return [:pass, line.strip]
      end
      if (line = after.lines.find { |l| l.match?(FAILURE_RE) })
        return [:fail, line.strip]
      end

      nil
    end

    def read_since(path, offset)
      return '' unless File.exist?(path)

      File.open(path, 'rb') do |f|
        f.seek(offset)
        f.read.to_s
      end
    rescue SystemCallError
      ''
    end

    # /tmp/publish.status must parse (frozen PUB line) AND be fresh (mtime
    # within 10 min of the clock) -- proves the run actually reached KV.
    def publish_status_row(label, status_path, clock)
      return ["#{label}: status file", "MISSING (#{status_path})", false] unless File.exist?(status_path)

      line  = File.foreach(status_path).first.to_s.chomp
      age_s = clock.call - File.mtime(status_path)
      parsed = PUBLISH_STATUS_RE.match(line)
      fresh  = age_s.abs <= STATUS_FRESH_S
      ok     = !parsed.nil? && fresh
      detail = if parsed.nil?
                 "unparseable status line (#{status_path})"
               else
                 format('%s (age %dm%s)', line, (age_s / 60).to_i, fresh ? '' : ', STALE > 10m')
               end
      ["#{label}: status file", detail, ok]
    rescue SystemCallError
      ["#{label}: status file", "unreadable (#{status_path})", false]
    end

    # Report today's dated snapshot file if present (the log summary line
    # also names it; this confirms it landed on disk).
    def snapshot_file_row(label, repo, env, clock)
      dir  = gex_history_dir(repo, env)
      date = clock.call.utc.strftime('%Y-%m-%d')
      path = File.join(dir, "#{date}.json")
      exist = File.exist?(path)
      ["#{label}: snapshot file", exist ? "present #{path}" : "not yet on disk (#{path})", exist]
    end

    # ---- status --------------------------------------------------------

    def status(home:, repo:, env:, runner:, io:, clock: -> { Time.now }, uid: Process.uid,
               status_path: DEFAULT_STATUS_PATH)
      rows = []
      AGENTS.each do |label, _, opts|
        print_ok, print_out = runner.call(['launchctl', 'print', service(uid, label)])
        if print_ok
          out   = print_out.to_s
          state = out[/state\s*=\s*(\S+)/, 1] || '?'
          last  = out[/last exit code\s*=\s*(\S+)/, 1] || '(never exited)'
          rows << [label, format('loaded; state=%s; last exit=%s', state, last), true]
        else
          rows << [label, 'not loaded (install via rake ops:install)', true]
        end

        log_path = File.join(home, 'Library', 'Logs', 'mimir', opts[:log])
        marker_line, summary_line = log_tail_info(log_path, opts[:marker], opts[:success_re])
        detail = if marker_line
                   [marker_line, summary_line].compact.join('  |  ')
                 else
                   'no log yet'
                 end
        rows << ["#{label} log", detail, true]
      end

      if File.exist?(status_path)
        line  = File.foreach(status_path).first.to_s.chomp
        age_m = ((clock.call - File.mtime(status_path)) / 60).to_i
        rows << ['status file', format('%s (age %dm)', line, age_m), true]
      else
        rows << ['status file', "missing (#{status_path})", true]
      end

      dir    = gex_history_dir(repo, env)
      newest = Dir.glob(File.join(dir, '*.json')).map { |f| File.basename(f) }.sort.last
      rows << ['newest gex snapshot', newest || "none yet (#{dir})", true]

      print_table(io, 'ops status', rows, pass: 'ok')
      0
    end

    # Last marker line + last summary line from the log tail (~50 lines).
    def log_tail_info(path, marker, success_re)
      return [nil, nil] unless File.exist?(path)

      lines = begin
        File.readlines(path).last(50)
      rescue SystemCallError
        []
      end
      marker_line  = lines.reverse.find { |l| l.include?(marker) }
      summary_line = lines.reverse.find { |l| l.match?(success_re) }
      [marker_line && BTC::Env.redact(marker_line.strip),
       summary_line && BTC::Env.redact(summary_line.strip)]
    end

    # ---- uninstall -----------------------------------------------------

    def uninstall(home:, runner:, io:, input:, uid: Process.uid)
      unless ask?(io, input, 'bootout + remove installed plists? [y/N]')
        io.puts 'uninstall cancelled.'
        return 0
      end

      rows = []
      AGENTS.each do |label, _, _|
        boot_ok, = runner.call(['launchctl', 'bootout', service(uid, label)])
        installed = File.join(home, 'Library', 'LaunchAgents', "#{label}.plist")
        existed = File.exist?(installed)
        File.delete(installed) if existed
        rows << [label,
                 format('%s; %s', boot_ok ? 'booted out' : 'was not loaded',
                        existed ? 'installed plist removed' : 'no installed plist'),
                 true]
      end
      print_table(io, 'uninstall', rows, pass: 'ok')
      0
    end

    # ---- prompt + table + default runner -------------------------------

    # Ask a [y/N] question on +io+/+input+; only an explicit y/yes is true.
    def ask?(io, input, prompt)
      io.print("#{prompt} ")
      io.flush if io.respond_to?(:flush)
      answer = input.gets.to_s.strip.downcase
      answer == 'y' || answer == 'yes'
    end

    def print_table(io, title, rows, pass: 'PASS')
      io.puts "#{title}:"
      rows.each do |label, detail, ok|
        io.puts format('  [%-4s] %-32s %s', ok ? pass : 'FAIL', label, detail)
      end
    end

    # lambda(argv, _overrides={}) -> [ok, combined_stdout+stderr].
    def run_cmd(cmd, _overrides = {})
      require 'open3'
      out, status = Open3.capture2e(*cmd)
      [status.success?, out]
    rescue StandardError => e
      [false, e.class.name]
    end

    # ---- CLI dispatcher (rake tasks) -----------------------------------

    def run(argv, home: Dir.home, repo: Dir.pwd, env: ENV, runner: method(:run_cmd),
            io: $stdout, input: $stdin, clock: -> { Time.now }, sleeper: ->(s) { sleep(s) },
            uid: Process.uid, status_path: DEFAULT_STATUS_PATH)
      raise Error, ci_refusal_message if truthy(env['CI'])
      raise Error, tty_refusal_message unless input.respond_to?(:tty?) && input.tty?

      case argv.first
      when 'install'
        install(home: home, repo: repo, env: env, runner: runner, io: io, input: input,
                clock: clock, sleeper: sleeper, uid: uid, status_path: status_path)
      when 'status'
        status(home: home, repo: repo, env: env, runner: runner, io: io, clock: clock,
               uid: uid, status_path: status_path)
      when 'uninstall'
        uninstall(home: home, runner: runner, io: io, input: input, uid: uid)
      else
        raise Error, "unknown ops command: #{argv.first.inspect} (expected install|status|uninstall)"
      end
    end
  end
end
