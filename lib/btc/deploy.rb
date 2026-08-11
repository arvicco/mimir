# frozen_string_literal: true
#
# deploy.rb -- owner-run Cloudflare Worker deploy automation (M4-5,
# ARCHITECTURE.md section 6 Phase 4).
#
#   rake deploy                     # OWNER-RUN: code + DATA live + smoke
#   DEPLOY_DRY_RUN=1 rake deploy    # assemble everything, run nothing
#   DEPLOY_SKIP_CHECKS=1 rake deploy  # skip tree-clean + rake-gate (re-runs)
#   DEPLOY_SKIP_PUBLISH=1 rake deploy # code-only push, no data publish
#
# Golden Rule 3 (CLAUDE.md): deploys are HUMAN actions. This task is
# never run by the loop and REFUSES under CI (ENV['CI'] set -> abort with
# the rule quoted). It is deny-listed for the loop like fixtures:record.
#
# Pipeline (see docs/DEPLOY.md):
#   1. pre-flight -- wrangler present, CF_* env present, tree clean, gate
#      green (the last two skippable together via DEPLOY_SKIP_CHECKS=1).
#      In DRY RUN the table is informational (never blocks): a dev box
#      without wrangler / a dirty tree still proves the pipeline.
#   1b. sync live runtime (M9-12) -- REFUSE unless the deployed HEAD is
#      pushed to origin, then bring the app-managed clone at
#      BTC::Env.live_dir onto that exact sha (clone from the local repo
#      if absent, pointing origin at the real remote URL; fetch +
#      checkout --detach <sha>). Production agents and this deploy's own
#      publish run FROM that clone, so the dev checkout stays stateless.
#      DRY RUN prints the sync plan and mutates nothing.
#   2. generate config -- substitute CLOUDFLARE_KV_NAMESPACE_ID into the
#      committed wrangler.toml template, write wrangler.generated.toml
#      AT THE REPO ROOT (gitignored by name): wrangler resolves main /
#      [assets].directory relative to the CONFIG FILE, so the generated
#      copy must sit beside the template or every path breaks (found
#      live at Gate 4: a data/ copy hunted for data/web/worker.mjs).
#   3. deploy -- `wrangler deploy -c wrangler.generated.toml`;
#      wrangler reads CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID from
#      the inherited env (one-token ruling); the legacy CF_API_TOKEN
#      name is unset in the child in case a stale env file exports it.
#   4. publish -- PUBLISH_DRY_RUN=0 ruby publish/publish.rb (deploy means
#      LIVE, data included -- owner ruling at Gate 4; skippable via
#      DEPLOY_SKIP_PUBLISH=1 for code-only pushes; cron owns routine
#      publishing from Phase 5).
#   5. smoke -- GET /healthz (200 {ok:true}), /api/v1/index (200 envelope,
#      age sane AND the four chart:* keys listed -- content, not just
#      freshness), /api/v1/definitely:missing (404), GET / (dashboard
#      shell), via BTC::Http; a PASS/FAIL line each, nonzero exit on FAIL.
#
# The SAME deploy ships the static dashboard: wrangler.toml's [assets]
# block serves web/ on the worker's host (owner feedback at Gate 4 --
# one surface, same-origin by construction; the earlier separate Pages
# step is gone). DEPLOY_NAME optionally renames the worker (= hostname).
#
# SECURITY: CLOUDFLARE_* values are never printed. Env checks say 'set'
# or 'MISSING' only; the generated config's id line is written, never
# echoed; all external output passes BTC::Env.redact as defense in
# depth.

require 'json'
require 'time'
require 'fileutils'
require 'shellwords'
require_relative 'env'
require_relative 'http'

module BTC
  module Deploy
    class Error < StandardError; end

    TEMPLATE_PATH  = 'wrangler.toml'
    GENERATED_PATH = 'wrangler.generated.toml'
    PLACEHOLDER    = 'FILLED_FROM_CLOUDFLARE_KV_NAMESPACE_ID_BY_RAKE_DEPLOY'
    CF_ENV         = %w[CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID
                        CLOUDFLARE_KV_NAMESPACE_ID].freeze
    NAME_RE        = /\A[a-z0-9-]{1,54}\z/ # valid worker name = public hostname
    MAX_AGE_S      = 7 * 24 * 3600 # index envelope older than a week -> stale
    SKEW_S         = 300           # tolerate small clock skew on "future" ages

    Result = Struct.new(:rows, :ok, keyword_init: true)

    module_function

    # ---- ENV / mode helpers (pure) -------------------------------------

    def truthy(val)
      s = val.to_s.strip.downcase
      !s.empty? && s != '0' && s != 'false'
    end

    def ci?(env = ENV)
      truthy(env['CI'])
    end

    def ci_refusal_message
      'rake deploy REFUSES to run under CI (ENV["CI"] is set). Golden ' \
      'Rule 3: wrangler deploy, Pages publish, and the first real publish ' \
      'are HUMAN actions -- never run by the loop or CI. Run this by hand.'
    end

    def dashboard_note
      'The dashboard ships IN this deploy ([assets] serves web/ on the ' \
      'same host) -- open the deployed host in a browser to see it.'
    end

    # ---- pre-flight ----------------------------------------------------

    # Env rows for the pre-flight table. Credentials/ids print 'set' /
    # 'MISSING' only, NEVER the value. DEPLOY_NAME is REQUIRED (owner
    # ruling D4-c: the worker name IS the public hostname and must be
    # chosen deliberately -- no silent 'mimir' default; a guessable name
    # is picked by setting it explicitly). It is not a secret, so its
    # value is shown for confirmation.
    def env_rows(env)
      rows = CF_ENV.map do |name|
        set = !env[name].to_s.empty?
        [name, set ? 'set' : 'MISSING', set]
      end
      name = env['DEPLOY_NAME'].to_s
      rows << if name.empty?
                ['DEPLOY_NAME', 'MISSING -- set the public worker name (D4-c: unguessable, e.g. mimir-a7f3k9)', false]
              elsif !name.match?(NAME_RE)
                ['DEPLOY_NAME', "invalid #{name.inspect} (lowercase/digits/hyphens, max 54)", false]
              else
                ['DEPLOY_NAME', name, true]
              end
      rows
    end

    # Build the pre-flight table. `runner` is a lambda(cmd_array,
    # env_overrides={}) -> [ok_bool, combined_output]; injected in tests.
    # skip_checks drops the tree-clean + gate rows (DEPLOY_SKIP_CHECKS or
    # dry run). Returns Result(rows: [[label, status, ok]], ok:).
    def preflight(env: ENV, runner: method(:run_cmd), skip_checks: false)
      rows = []

      wr_ok, wr_out = runner.call(%w[wrangler --version])
      version = BTC::Env.redact(wr_out.to_s).strip.split("\n").first.to_s
      rows << ['wrangler', wr_ok ? (version.empty? ? 'present' : version) : 'MISSING (not on PATH)', wr_ok]

      rows.concat(env_rows(env))

      if skip_checks
        rows << ['working tree', 'skipped', true]
        rows << ['rake gate', 'skipped', true]
      else
        git_ok, git_out = runner.call(%w[git status --porcelain])
        clean = git_ok && git_out.to_s.strip.empty?
        status = if !git_ok then 'git failed'
                 elsif clean then 'clean'
                 else format('dirty (%d files)', git_out.to_s.lines.size)
                 end
        rows << ['working tree', status, clean]

        gate_ok, = runner.call(%w[rake])
        rows << ['rake gate', gate_ok ? 'green' : 'FAILED', gate_ok]
      end

      Result.new(rows: rows, ok: rows.all? { |r| r[2] })
    end

    # ---- config generation (pure substitution + thin IO) ---------------

    # Replace the single namespace placeholder, touching nothing else.
    def substitute_template(template, namespace_id)
      unless template.include?(PLACEHOLDER)
        raise Error, "template #{TEMPLATE_PATH} missing #{PLACEHOLDER}"
      end

      template.sub(PLACEHOLDER, namespace_id)
    end

    # Optional worker rename (DEPLOY_NAME): the worker name IS the public
    # hostname, and ruling D4-c wants it unguessable. Replaces only the
    # `name = "..."` line; empty/absent name leaves the template's default.
    def substitute_name(content, name)
      return content if name.to_s.empty?
      raise Error, "DEPLOY_NAME #{name.inspect} is not a valid worker name" unless name.match?(NAME_RE)

      content.sub(/^name = ".*"$/, "name = \"#{name}\"")
    end

    def generate_config(env: ENV, template_path: TEMPLATE_PATH, out_path: GENERATED_PATH)
      ns = env['CLOUDFLARE_KV_NAMESPACE_ID'].to_s
      raise Error, 'CLOUDFLARE_KV_NAMESPACE_ID not set' if ns.empty?

      content = substitute_template(File.read(template_path), ns)
      content = substitute_name(content, env['DEPLOY_NAME'])
      FileUtils.mkdir_p(File.dirname(out_path))
      File.write(out_path, content)
      out_path
    end

    # ---- deploy command + host discovery -------------------------------

    def deploy_command(out_path = GENERATED_PATH)
      ['wrangler', 'deploy', '-c', out_path]
    end

    # Pull the workers.dev URL wrangler prints on a successful publish.
    def parse_deploy_url(stdout)
      stdout.to_s[%r{https://[^\s'"]+\.workers\.dev\S*}]
    end

    # ---- post-deploy smoke (pure verdicts + BTC::Http probes) ----------

    # One HTTP GET -> [code, body]; non-200 collapses StatusError to its
    # code, transport errors to [nil, class_name].
    def get_result(http, url)
      [200, http.get(url)]
    rescue BTC::Http::StatusError => e
      [e.code, e.body]
    rescue StandardError => e
      [nil, e.class.name]
    end

    def verdict_healthz(code, body)
      return [false, "expected 200, got #{code || 'error'}"] unless code == 200

      ok = (JSON.parse(body)['ok'] == true rescue false)
      ok ? [true, '200 {ok:true}'] : [false, '200 but body is not {ok:true}']
    end

    # Chart keys the published index MUST list -- an index without them
    # is a pre-Phase-3 publish and the dashboard renders no charts
    # (found live at Gate 4: age alone passed while the site looked
    # broken; content matters, not just freshness).
    CHART_KEYS = %w[chart:gex_btc chart:scenario_strip
                    chart:lppl_regime chart:btco_table].freeze

    def verdict_index(code, body, now)
      return [false, "expected 200, got #{code || 'error'}"] unless code == 200

      env = JSON.parse(body)
      gen = env['generated_at']
      return [false, 'envelope has no generated_at'] if gen.to_s.empty?

      age = now - Time.parse(gen)
      return [false, 'generated_at is in the future'] if age < -SKEW_S
      return [false, format('stale: age %.1f days > 7', age / 86_400.0)] if age > MAX_AGE_S

      keys = (env.dig('payload', 'keys') || []).map { |r| r['key'] }
      missing = CHART_KEYS - keys
      unless missing.empty?
        return [false, "index lists no #{missing.join('/')} -- old publish? re-publish and re-run"]
      end

      [true, format('200 envelope, age %.1fh, %d keys incl. charts', age / 3600.0, keys.size)]
    rescue JSON::ParserError, ArgumentError, TypeError
      [false, 'not a valid envelope (parse/age failed)']
    end

    def verdict_missing(code, _body)
      code == 404 ? [true, '404 as expected'] : [false, "expected 404, got #{code || 'error'}"]
    end

    # The same deploy ships the static dashboard ([assets] in
    # wrangler.toml): GET / must answer with the index.html shell.
    def verdict_dashboard(code, body)
      return [false, "expected 200, got #{code || 'error'}"] unless code == 200

      body.to_s.include?('<title>mimir</title>') ? [true, '200 dashboard html'] : [false, '200 but not the dashboard shell']
    end

    # Run the four probes against `host`; -> [[name, ok, detail], ...].
    def smoke(host, http: BTC::Http, now: Time.now.utc)
      base = host.to_s.chomp('/')
      [
        ['GET /healthz', *verdict_healthz(*get_result(http, "#{base}/healthz"))],
        ['GET /api/v1/index', *verdict_index(*get_result(http, "#{base}/api/v1/index"), now)],
        ['GET /api/v1/definitely:missing', *verdict_missing(*get_result(http, "#{base}/api/v1/definitely:missing"))],
        ['GET / (dashboard)', *verdict_dashboard(*get_result(http, "#{base}/"))]
      ]
    end

    # ---- default subprocess runner -------------------------------------

    # lambda(cmd_array, env_overrides={}) -> [ok, combined_stdout+stderr].
    # env_overrides apply to the child ONLY (Open3 passes them through).
    def run_cmd(cmd, env_overrides = {})
      require 'open3'
      out, status = Open3.capture2e(env_overrides, *cmd)
      [status.success?, out]
    rescue StandardError => e
      [false, e.class.name]
    end

    # ---- live runtime sync (M9-12) -------------------------------------

    # HEAD sha of the repo the deploy runs from. -> [ok, sha_string].
    def head_sha(runner)
      ok, out = runner.call(%w[git rev-parse HEAD])
      [ok, out.to_s.strip]
    end

    # Is +sha+ reachable from an origin remote-tracking ref? `git push`
    # updates origin/<branch> locally, so right after a push this is true
    # without any network -- exactly the "push, then deploy" flow. A commit
    # only on a local branch has no origin/* ref containing it.
    def head_pushed?(runner, sha)
      ok, out = runner.call(['git', 'branch', '-r', '--contains', sha])
      ok && out.to_s.lines.any? { |l| l.strip.start_with?('origin/') }
    end

    # URL of the dev repo's origin -- baked into the live clone as its own
    # origin so future `git -C LIVE fetch origin` reaches the real remote
    # (the clone itself is seeded from the fast local path). -> [ok, url].
    def origin_url_of(runner)
      ok, out = runner.call(%w[git remote get-url origin])
      [ok, out.to_s.strip]
    end

    # The ordered git steps that bring the live clone onto +sha+. Absent
    # clone: seed from the local repo (fast, offline) then repoint origin
    # at the real URL; always fetch (verifies remote connectivity) then
    # detach onto the exact deployed sha. Pure -- returns [{cmd:, label:}].
    def sync_steps(sha:, live:, local_repo:, origin_url:, live_present:)
      steps = []
      unless live_present
        steps << { cmd: ['git', 'clone', local_repo, live], label: "clone live runtime from #{local_repo}" }
        steps << { cmd: ['git', '-C', live, 'remote', 'set-url', 'origin', origin_url], label: "point origin at #{origin_url}" }
      end
      steps << { cmd: ['git', '-C', live, 'fetch', 'origin'], label: 'fetch origin' }
      steps << { cmd: ['git', '-C', live, 'checkout', '--detach', sha], label: "checkout --detach #{sha[0, 7]}" }
      steps
    end

    # The deploy's own publish runs FROM the live clone (its cwd), with
    # BTC_DATA_DIR pinned at the data home -- same code + data as the
    # scheduled agents. sh -c so the recorded runner still handles it and
    # the spaced "Application Support" path is quoted safely.
    def publish_from_live_command(live)
      ['/bin/sh', '-c', "cd #{live.shellescape} && exec ruby publish/publish.rb"]
    end

    # Refuse-if-unpushed + bring the live clone onto the deployed sha.
    # Every git call goes through the injected runner (no real git in
    # tests). DRY prints the plan and mutates nothing. Returns the live
    # path. Raises Error on an unpushed HEAD or a failed sync step.
    def sync_live(runner:, io:, home:, repo:, dry:)
      live = BTC::Env.live_dir(home)

      ok, sha = head_sha(runner)
      if !ok || sha.empty?
        raise Error, 'could not resolve HEAD (git rev-parse failed)' unless dry

        io.puts ''
        io.puts 'live runtime sync (dry run): HEAD unresolved by this runner -- plan skipped.'
        return live
      end
      short = sha[0, 7]

      pushed       = head_pushed?(runner, sha)
      live_present = File.directory?(File.join(live, '.git'))
      ourl_ok, ourl = origin_url_of(runner)
      steps = sync_steps(sha: sha, live: live, local_repo: repo,
                         origin_url: ourl.to_s, live_present: live_present)

      if dry
        io.puts ''
        io.puts format('live runtime sync plan (dry run) -> %s', live)
        io.puts(pushed ? format('  HEAD %s is pushed to origin', short)
                       : format('  WARNING: HEAD %s is NOT on origin -- a real deploy REFUSES until pushed', short))
        steps.each { |s| io.puts format('  would run: %s', BTC::Env.redact(s[:cmd].join(' '))) }
        io.puts format('  would sync: live runtime -> %s', short)
        return live
      end

      unless pushed
        raise Error, format('refusing to deploy: HEAD %s is not pushed to origin -- push the ' \
                            'deployed commit first (git push), then re-run', short)
      end
      raise Error, 'could not read origin URL (git remote get-url origin failed)' unless ourl_ok

      steps.each do |s|
        sok, sout = runner.call(s[:cmd])
        next if sok

        raise Error, format('live runtime sync failed at "%s": %s', s[:label],
                            BTC::Env.redact(sout.to_s).lines.first.to_s.strip)
      end
      io.puts format('live runtime -> %s', short)
      live
    end

    # ---- orchestrator --------------------------------------------------

    def print_table(io, title, rows)
      io.puts "#{title}:"
      rows.each do |label, status, ok|
        io.puts format('  [%-4s] %-27s %s', ok ? 'ok' : 'FAIL', label, status)
      end
    end

    # Returns an exit code (0 ok / dry, 1 smoke FAIL). Raises Error for CI
    # refusal, blocking pre-flight failure, missing config, deploy failure,
    # or an undiscoverable host -- the rake task turns those into aborts.
    def run(env: ENV, runner: method(:run_cmd), http: BTC::Http, io: $stdout,
            now: Time.now.utc, template_path: TEMPLATE_PATH, out_path: GENERATED_PATH,
            home: Dir.home, repo: Dir.pwd)
      raise Error, ci_refusal_message if ci?(env)

      dry  = truthy(env['DEPLOY_DRY_RUN'])
      skip = truthy(env['DEPLOY_SKIP_CHECKS']) || dry

      pf = preflight(env: env, runner: runner, skip_checks: skip)
      print_table(io, dry ? 'pre-flight (dry run -- informational)' : 'pre-flight', pf.rows)
      unless pf.ok
        raise Error, 'pre-flight failed -- fix the FAIL rows above (or DEPLOY_SKIP_CHECKS=1 to skip tree/gate)' unless dry

        io.puts 'pre-flight has warnings; continuing (dry run does not block).'
      end

      # Bring the app-managed live clone onto the deployed sha (refuses an
      # unpushed HEAD) BEFORE wrangler/publish, so the publish below and the
      # scheduled agents all run the exact released commit.
      live      = sync_live(runner: runner, io: io, home: home, repo: repo, dry: dry)
      data_home = BTC::Env.data_home(home)

      path = generate_config(env: env, template_path: template_path, out_path: out_path)
      io.puts format('generated config: %s (gitignored; namespace id from CLOUDFLARE_KV_NAMESPACE_ID)', path)
      cmd = deploy_command(path)

      if dry
        io.puts ''
        io.puts 'DRY RUN (DEPLOY_DRY_RUN=1) -- wrangler, publish and smoke probes NOT run.'
        io.puts format('would run: %s', cmd.join(' '))
        io.puts 'would run: PUBLISH_DRY_RUN=0 ruby publish/publish.rb  (skip with DEPLOY_SKIP_PUBLISH=1)'
        io.puts dashboard_note
        return 0
      end

      io.puts ''
      io.puts "deploying: #{cmd.join(' ')}"
      # One token, one name (owner ruling, Gate 4): wrangler reads
      # CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID natively from the
      # inherited env -- nothing to map. The only override UNSETS the
      # legacy CF_API_TOKEN name (nil removes it in the child) in case a
      # stale env file still exports it: wrangler would adopt it as a
      # deprecated alias and warn (or, if it is an old narrow token,
      # fail to deploy).
      ok, out = runner.call(cmd, { 'CF_API_TOKEN' => nil })
      unless ok
        # 15 lines: wrangler leads with the actual [ERROR] and pads with
        # advice -- a 5-line tail cut off the root cause (Gate 4 lesson)
        io.puts BTC::Env.redact(out.to_s).lines.last(15).join
        raise Error, 'wrangler deploy failed (see output above)'
      end

      host = env['DEPLOY_HOST'].to_s
      host = parse_deploy_url(out).to_s if host.empty?
      if host.empty?
        raise Error, 'could not determine deployed host (set DEPLOY_HOST=https://... and re-run with DEPLOY_SKIP_CHECKS=1)'
      end

      io.puts format('deployed host: %s', host)

      # Deploy means LIVE, data included (owner ruling at Gate 4: a
      # deploy that leaves the site rendering stale/chart-less data is
      # broken by the owner's definition). A real publish runs before
      # the smoke so the probes validate fresh data. Skippable for
      # code-only pushes; cron owns routine publishing from Phase 5.
      unless truthy(env['DEPLOY_SKIP_PUBLISH'])
        io.puts ''
        io.puts format('publishing data from live runtime %s (BTC_DATA_DIR=%s)', live, data_home)
        pub_ok, pub_out = runner.call(publish_from_live_command(live),
                                      { 'PUBLISH_DRY_RUN' => '0', 'BTC_DATA_DIR' => data_home })
        io.puts BTC::Env.redact(pub_out.to_s).lines.last(3).join
        raise Error, 'publish failed -- the worker is deployed but KV data was not refreshed' unless pub_ok
      end

      io.puts ''
      io.puts 'post-deploy smoke:'
      results = smoke(host, http: http, now: now)
      results.each do |name, probe_ok, detail|
        io.puts format('  [%-4s] %-32s %s', probe_ok ? 'PASS' : 'FAIL', name, detail)
      end
      io.puts dashboard_note

      results.count { |_, probe_ok, _| !probe_ok }.zero? ? 0 : 1
    end
  end
end
