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
#   rake ops:tmux         # OWNER-RUN, interactive: inspect the LIVE tmux
#                         # status bar and install the publish health token.
#                         # Probes the running server (never edits any file),
#                         # proposes ONE fitted status-format change, optionally
#                         # applies it live (reversible set -g), and ALWAYS
#                         # prints the exact ~/.tmux.conf line(s) to persist.
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
    # The BTCo discovery-alert token rides the same right-align run as the
    # publish health token (D8-a: joins the mimir status cluster). Written
    # by ops/btco_alert.rb -> /tmp/ingest.status, empty on quiet days.
    INGEST_STATUS_CMD   = '#(cat /tmp/ingest.status 2>/dev/null)'
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
       timeout: 90, kind: :snapshot],
      # com.mimir.btco-alert RETIRED 2026-08-10 (owner ruling: BTCo frozen,
      # "No alert"). Removed from the install/status set so a reinstall
      # cannot resurrect it; the live instance is booted out by hand
      # (commands in .docs/BACKLOG.md, post-Gate-7 rulings).
      ['com.mimir.suite-history', 'run_suite_history.sh',
       log: 'suite_history.log', marker: '=== run_suite_history',
       success_re: %r{suite-history OK: \d+/\d+ suites updated},
       timeout: 660, kind: :history]
    ].freeze

    # One-time data migration (M9-12): every runtime dir the agents read
    # or write, mapped [suite_key, dev-tree relative path]. The suite_key
    # is EXACTLY what BTC::Env.data_dir('<suite>', ...) appends to the data
    # home, so a copy into data_home/<suite> lands where the agents look
    # once BTC_DATA_DIR points there. This is the full inventory of the
    # data_dir call sites in scripts/ + ops/ + publish/ (grep-verified);
    # btco's capstruct/ is a COMMITTED audit trail (travels with the clone,
    # env.rb's deliberate exception) and /tmp status files are ephemeral --
    # neither is migrated.
    MIGRATION_SUITES = [
      ['lppl',         File.join('scripts', 'lppl', 'data')],
      ['scenario',     File.join('scripts', 'scenario', 'data')],
      ['gex_history',  File.join('data', 'gex_history')],
      ['vol_history',  File.join('data', 'vol_history')],
      ['vol_spread',   File.join('data', 'vol_spread')],
      ['source_cache', File.join('data', 'source_cache')]
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

    # Where the gex-snapshot agent's dated files land. The wrappers pin
    # BTC_DATA_DIR at the data home (M9-12), so verification/status look
    # under data_home/gex_history -- honoring an explicit BTC_DATA_DIR in
    # THIS process only as a test/override seam.
    def gex_history_dir(home, env)
      base = env['BTC_DATA_DIR']
      base && !base.empty? ? File.join(base, 'gex_history') : File.join(BTC::Env.data_home(home), 'gex_history')
    end

    # ---- data migration (M9-12) ----------------------------------------

    # Files under a source dir, as sorted paths relative to it ([] if the
    # dir is absent). Pure listing -- the planner and the copier share it.
    def migration_source_files(src)
      return [] unless Dir.exist?(src)

      Dir.glob('**/*', base: src).select { |f| File.file?(File.join(src, f)) }.sort
    end

    # Never clobber newer data: skip when the destination exists and is at
    # least as new as the source (cp preserves mtime, so a re-run of an
    # already-migrated file skips -- the migration is idempotent).
    def migration_skip?(sfile, dfile)
      File.exist?(dfile) && File.mtime(dfile) >= File.mtime(sfile)
    end

    # Plan (apply:false) or perform (apply:true) the dev-tree -> data_home
    # copy for every suite. Returns one row hash per suite with the file
    # count and the copy/skip/error breakdown -- the inventory table's data.
    # apply:false is a pure dry plan (no IO writes); apply:true copies,
    # honoring skip-if-destination-newer per file.
    def migration_rows(repo:, data_home:, apply:)
      MIGRATION_SUITES.map do |suite, rel|
        src   = File.join(repo, rel)
        dest  = File.join(data_home, suite)
        files = migration_source_files(src)
        copied = skipped = errors = 0
        files.each do |rf|
          sfile = File.join(src, rf)
          dfile = File.join(dest, rf)
          if migration_skip?(sfile, dfile)
            skipped += 1
            next
          end
          unless apply
            copied += 1
            next
          end
          begin
            FileUtils.mkdir_p(File.dirname(dfile))
            FileUtils.cp(sfile, dfile, preserve: true)
            copied += 1
          rescue SystemCallError
            errors += 1
          end
        end
        { suite: suite, source: src, dest: dest, files: files.size,
          copied: copied, skipped: skipped, errors: errors, present: Dir.exist?(src) }
      end
    end

    def print_migration_table(io, rows)
      io.puts 'migration inventory (dev tree -> data home):'
      rows.each do |r|
        detail = if r[:present]
                   format('%3d file(s), %d to copy / %d skip%s', r[:files], r[:copied], r[:skipped],
                          r[:errors].positive? ? format(' / %d ERROR', r[:errors]) : '')
                 else
                   '(no source dir -- nothing to migrate)'
                 end
        io.puts format('  %-13s %s', r[:suite], detail)
        io.puts format('    %s -> %s', r[:source], r[:dest])
      end
    end

    # Interactive migration step inside install: print the inventory,
    # then (only when something needs copying) confirm and apply.
    def migrate_install(repo:, home:, io:, input:)
      data_home = BTC::Env.data_home(home)
      io.puts ''
      io.puts format('one-time data migration -> %s', data_home)
      planned = migration_rows(repo: repo, data_home: data_home, apply: false)
      print_migration_table(io, planned)

      pending = planned.sum { |r| r[:copied] }
      if pending.zero?
        io.puts 'nothing to migrate (destination already current) -- skipping.'
        return
      end

      unless ask?(io, input, format('copy %d file(s) into the data home now? [y/N]', pending))
        io.puts 'migration skipped -- agents will use the data home as-is (re-run install to migrate).'
        return
      end

      applied = migration_rows(repo: repo, data_home: data_home, apply: true)
      io.puts format('migrated: %d copied, %d skipped (newer at destination), %d error(s).',
                     applied.sum { |r| r[:copied] }, applied.sum { |r| r[:skipped] },
                     applied.sum { |r| r[:errors] })
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

      # M9-12: the agents exec from the app-managed live clone, so it must
      # exist (rake deploy creates/syncs it) and carry each wrapper.
      live      = BTC::Env.live_dir(home)
      live_git  = File.directory?(File.join(live, '.git'))
      live_wraps = AGENTS.all? { |_, wrapper, _| File.exist?(File.join(live, 'ops', wrapper)) }
      live_ok = live_git && live_wraps
      live_detail = if live_ok
                      "present #{live}"
                    elsif !live_git
                      "MISSING (#{live}) -- run rake deploy first to create the live runtime"
                    else
                      "incomplete (#{live}/ops missing a wrapper) -- re-run rake deploy"
                    end
      rows << ['live runtime', live_detail, live_ok]

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

      # One-time data migration into the data home BEFORE the agents go
      # live, so their first tick continues the SAME histories (Golden Rule
      # 3: interactive, owner-confirmed; idempotent, skip-if-newer).
      migrate_install(repo: repo, home: home, io: io, input: input)

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
      # M9-12: the program line points at the app-managed LIVE clone, not
      # the dev checkout -- the plist template (read from the dev tree,
      # identical to LIVE at the deployed commit) has its __REPO__ filled
      # with the live path.
      live         = BTC::Env.live_dir(home)
      wrapper_path = File.join(live, 'ops', wrapper)

      template = File.read(File.join(repo, 'ops', "#{label}.plist"))
      rendered = template.gsub(REPO_PLACEHOLDER, live)
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
        rows << snapshot_file_row(label, home, env, clock)
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
    def snapshot_file_row(label, home, env, clock)
      dir  = gex_history_dir(home, env)
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

      dir    = gex_history_dir(home, env)
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

    # ---- tmux health line ----------------------------------------------

    # The command tmux runs to draw the token, and its dedicated-line form
    # (own right-aligned section). ALWAYS the REAL absolute repo path -- a
    # placeholder left in is the #1 silent failure, so there is no
    # placeholder here to leave in. The BTCo discovery-alert token
    # (ING n!, empty on quiet days) rides the SAME right-align run,
    # immediately after the publish health token (D8-a).
    def tmux_health_cmd(repo)
      "#(ruby #{File.join(repo, 'ops', 'publish_health.rb')})#{INGEST_STATUS_CMD}"
    end

    def tmux_dedicated_value(repo)
      "#[align=right]#{tmux_health_cmd(repo)}"
    end

    # `tmux show -gv status` prints a count, or 'on'/'off' on older configs
    # (treat 'on' as 1, 'off' as 0). Unset/parse-fail -> 1 (the default).
    def tmux_status_count(runner)
      ok, out = runner.call(['tmux', 'show', '-gv', 'status'])
      return 1 unless ok

      v = out.to_s.strip
      return 1 if v.empty? || v == 'on'
      return 0 if v == 'off'

      Integer(v)
    rescue ArgumentError
      1
    end

    def tmux_status_interval(runner)
      ok, out = runner.call(['tmux', 'show', '-gv', 'status-interval'])
      ok ? out.to_s.strip : ''
    end

    # An unset status-format[i] for i>=1 comes back empty or an error --
    # both mean "free".
    def tmux_status_format(runner, idx)
      ok, out = runner.call(['tmux', 'show', '-gv', "status-format[#{idx}]"])
      return '' unless ok

      out.to_s.chomp
    end

    def tmux_interval_active?(interval)
      n = Integer(interval.to_s.strip)
      n.positive?
    rescue ArgumentError
      false
    end

    # Inspect the LIVE server and install the publish health token. NEVER
    # writes any file -- it drives the running server via `set -g` (which
    # the owner can undo by reload) and prints the persistence line(s) to
    # paste by hand. Fully injectable (runner/io/input) for tests.
    def tmux(home:, repo:, env:, runner:, io:, input:)
      _ = home # never touched: this command writes NO file (pinned in tests)
      _ = env
      health_cmd = tmux_health_cmd(repo)

      # 1a. tmux on PATH.
      tmux_ok, = runner.call(['which', 'tmux'])
      unless tmux_ok
        io.puts 'tmux: not found on PATH -- install tmux (or add it to PATH), then re-run.'
        return 1
      end

      # 1b. server running? A dead server can only take the static snippet.
      up, = runner.call(['tmux', 'display', '-p', 'ok'])
      unless up
        io.puts 'tmux: no server running -- start tmux, then re-run to inspect the live bar.'
        io.puts 'For now add this to ~/.tmux.conf by hand (real repo path baked in):'
        print_tmux_persist(io, ["set -g status 2",
                                "set -g status-format[1] '#{tmux_dedicated_value(repo)}'",
                                'set -g status-interval 30'])
        return 0
      end

      # 1c. show the token the bar will draw + its current output.
      tok_ok, tok_out = runner.call(['ruby', File.join(repo, 'ops', 'publish_health.rb')])
      io.puts "health command: #{health_cmd}"
      io.puts format('current output: %s', tok_ok ? tok_out.to_s.strip : '(publish_health.rb did not run)')

      # 2. inspect the live status bar.
      count    = tmux_status_count(runner)
      interval = tmux_status_interval(runner)
      formats  = {}
      # scan 0..count-1 plus a couple beyond for the token / free lines.
      (0...(count + 2)).each { |i| formats[i] = tmux_status_format(runner, i) }
      io.puts format('status bar: status=%d, status-interval=%s', count,
                     interval.empty? ? '(unset)' : interval)

      # 2b. already present? Fully idempotent only when BOTH tokens ride
      # the line; a bar installed before M7-2 carries the health token
      # without the ingest fragment -- offer the in-place upgrade (the
      # fragment appended right after the health command) instead of
      # "nothing to do" (review catch: the gold bar predates the alert).
      present = formats.keys.sort.find { |i| formats[i].include?('publish_health.rb') }
      if present && formats[present].include?('/tmp/ingest.status')
        io.puts format('both tokens already present in status-format[%d] -- nothing to do.', present)
        io.puts 'For reference, the line that carries them:'
        print_tmux_persist(io, ["set -g status-format[#{present}] '#{formats[present]}'"])
        return 0
      end
      if present
        index   = present
        value   = formats[present].sub(/(#\(ruby [^)]*publish_health\.rb\))/) { "#{Regexp.last_match(1)}#{INGEST_STATUS_CMD}" }
        variant = 'append ingest token to the existing line'
        return tmux_offer(io, input, runner, interval, index, value, variant)
      end

      # 3. propose ONE variant fitted to what we found. Prefer a dedicated
      # line on the first FREE index at the current status count (never grow
      # the bar unprompted); else merge onto the last occupied line.
      free_index = (1...count).find { |i| formats[i].to_s.empty? }
      occupied   = (0...count).select { |i| !formats[i].to_s.empty? }
      if free_index
        index   = free_index
        value   = tmux_dedicated_value(repo)
        variant = 'dedicated line'
      elsif occupied.empty?
        index   = 1 # degenerate: no occupied line -- fall back to a fresh 2nd line
        value   = tmux_dedicated_value(repo)
        variant = 'dedicated line (new)'
      else
        index   = occupied.max
        value   = formats[index] + tmux_dedicated_value(repo)
        variant = 'merge onto last line'
      end
      tmux_offer(io, input, runner, interval, index, value, variant)
    end

    # The shared offer tail: print the ONE proposed variant, apply live on
    # y (reversible set -g, nothing persisted), then ALWAYS print the
    # paste-to-persist lines. Used by the fresh proposal AND the M7-2
    # append-ingest-token upgrade path.
    def tmux_offer(io, input, runner, interval, index, value, variant)
      io.puts ''
      io.puts format('proposed change (%s, index %d):', variant, index)
      io.puts "  status-format[#{index}] = '#{value}'"

      eff_interval = tmux_interval_active?(interval) ? interval : '30'
      if ask?(io, input, 'apply live now? [y/N]')
        runner.call(['tmux', 'set', '-g', "status-format[#{index}]", value])
        unless tmux_interval_active?(interval)
          if ask?(io, input, 'status-interval is 0/unset; set it to 30s now? [y/N]')
            runner.call(['tmux', 'set', '-g', 'status-interval', '30'])
          end
        end
        io.puts ''
        io.puts format("EXPECT: the mimir token(s) at the bar's right edge within %ss " \
                       '(PUB always; ING only when new filings exist).', eff_interval)
      end

      lines = ["set -g status-format[#{index}] '#{value}'"]
      lines << 'set -g status-interval 30' unless tmux_interval_active?(interval)
      print_tmux_persist(io, lines)
      0
    end

    # Print the persistence block (paste into ~/.tmux.conf). The script
    # itself NEVER writes the file -- this is copy-paste only.
    def print_tmux_persist(io, lines)
      io.puts ''
      io.puts 'Persist across restarts -- paste into ~/.tmux.conf:'
      io.puts ''
      lines.each { |l| io.puts "  #{l}" }
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
      when 'tmux'
        tmux(home: home, repo: repo, env: env, runner: runner, io: io, input: input)
      else
        raise Error, "unknown ops command: #{argv.first.inspect} (expected install|status|uninstall|tmux)"
      end
    end
  end
end
