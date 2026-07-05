# frozen_string_literal: true
#
# deploy.rb -- owner-run Cloudflare Worker deploy automation (M4-5,
# ARCHITECTURE.md section 6 Phase 4).
#
#   rake deploy                     # OWNER-RUN full deploy + smoke
#   DEPLOY_DRY_RUN=1 rake deploy    # assemble everything, run nothing
#   DEPLOY_SKIP_CHECKS=1 rake deploy  # skip tree-clean + rake-gate (re-runs)
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
#   2. generate config -- substitute CF_KV_NAMESPACE_ID into the committed
#      wrangler.toml template, write data/wrangler.generated.toml (data/
#      is gitignored, so the filled config is never committable).
#   3. deploy -- `wrangler deploy -c data/wrangler.generated.toml`, with
#      CLOUDFLARE_ACCOUNT_ID exported from CF_ACCOUNT_ID for the child
#      process ONLY.
#   4. smoke -- GET /healthz (200 {ok:true}), /api/v1/index (200 envelope,
#      age sane), /api/v1/definitely:missing (404), via BTC::Http; a
#      PASS/FAIL line each, nonzero exit on any FAIL.
#
# Pages publish (the static web/ files) is a SEPARATE owner step and is
# deliberately NOT automated here (docs/DEPLOY.md section 2).
#
# SECURITY: CF_* values are never printed. Env checks say 'set' or
# 'MISSING' only; the generated config's id line is written, never
# echoed; the dry-run "would run" line shows CLOUDFLARE_ACCOUNT_ID as a
# <placeholder>, not the value; all external output passes BTC::Env.redact
# as defense in depth.

require 'json'
require 'time'
require 'fileutils'
require_relative 'env'
require_relative 'http'

module BTC
  module Deploy
    class Error < StandardError; end

    TEMPLATE_PATH  = 'wrangler.toml'
    GENERATED_PATH = 'data/wrangler.generated.toml'
    PLACEHOLDER    = 'FILLED_FROM_CF_KV_NAMESPACE_ID_BY_RAKE_DEPLOY'
    CF_ENV         = %w[CF_ACCOUNT_ID CF_KV_NAMESPACE_ID].freeze
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

    def pages_reminder
      'REMINDER: Pages publish (the static web/ files) is a SEPARATE owner ' \
      'step -- not automated here. See docs/DEPLOY.md section 2.'
    end

    # ---- pre-flight ----------------------------------------------------

    # Env rows for the pre-flight table: 'set' / 'MISSING' only, NEVER the
    # value (values are secret-adjacent -- CF_ACCOUNT_ID/CF_KV_NAMESPACE_ID).
    def env_rows(env)
      CF_ENV.map do |name|
        set = !env[name].to_s.empty?
        [name, set ? 'set' : 'MISSING', set]
      end
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

    def generate_config(env: ENV, template_path: TEMPLATE_PATH, out_path: GENERATED_PATH)
      ns = env['CF_KV_NAMESPACE_ID'].to_s
      raise Error, 'CF_KV_NAMESPACE_ID not set' if ns.empty?

      content = substitute_template(File.read(template_path), ns)
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

    def verdict_index(code, body, now)
      return [false, "expected 200, got #{code || 'error'}"] unless code == 200

      env = JSON.parse(body)
      gen = env['generated_at']
      return [false, 'envelope has no generated_at'] if gen.to_s.empty?

      age = now - Time.parse(gen)
      return [false, 'generated_at is in the future'] if age < -SKEW_S
      return [false, format('stale: age %.1f days > 7', age / 86_400.0)] if age > MAX_AGE_S

      [true, format('200 envelope, age %.1fh', age / 3600.0)]
    rescue JSON::ParserError, ArgumentError, TypeError
      [false, 'not a valid envelope (parse/age failed)']
    end

    def verdict_missing(code, _body)
      code == 404 ? [true, '404 as expected'] : [false, "expected 404, got #{code || 'error'}"]
    end

    # Run the three probes against `host`; -> [[name, ok, detail], ...].
    def smoke(host, http: BTC::Http, now: Time.now.utc)
      base = host.to_s.chomp('/')
      [
        ['GET /healthz', *verdict_healthz(*get_result(http, "#{base}/healthz"))],
        ['GET /api/v1/index', *verdict_index(*get_result(http, "#{base}/api/v1/index"), now)],
        ['GET /api/v1/definitely:missing', *verdict_missing(*get_result(http, "#{base}/api/v1/definitely:missing"))]
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

    # ---- orchestrator --------------------------------------------------

    def print_table(io, title, rows)
      io.puts "#{title}:"
      rows.each do |label, status, ok|
        io.puts format('  [%-4s] %-20s %s', ok ? 'ok' : 'FAIL', label, status)
      end
    end

    # Returns an exit code (0 ok / dry, 1 smoke FAIL). Raises Error for CI
    # refusal, blocking pre-flight failure, missing config, deploy failure,
    # or an undiscoverable host -- the rake task turns those into aborts.
    def run(env: ENV, runner: method(:run_cmd), http: BTC::Http, io: $stdout,
            now: Time.now.utc, template_path: TEMPLATE_PATH, out_path: GENERATED_PATH)
      raise Error, ci_refusal_message if ci?(env)

      dry  = truthy(env['DEPLOY_DRY_RUN'])
      skip = truthy(env['DEPLOY_SKIP_CHECKS']) || dry

      pf = preflight(env: env, runner: runner, skip_checks: skip)
      print_table(io, dry ? 'pre-flight (dry run -- informational)' : 'pre-flight', pf.rows)
      unless pf.ok
        raise Error, 'pre-flight failed -- fix the FAIL rows above (or DEPLOY_SKIP_CHECKS=1 to skip tree/gate)' unless dry

        io.puts 'pre-flight has warnings; continuing (dry run does not block).'
      end

      path = generate_config(env: env, template_path: template_path, out_path: out_path)
      io.puts format('generated config: %s (gitignored; namespace id from CF_KV_NAMESPACE_ID)', path)
      cmd = deploy_command(path)

      if dry
        io.puts ''
        io.puts 'DRY RUN (DEPLOY_DRY_RUN=1) -- wrangler and smoke probes NOT run.'
        io.puts format('would run: CLOUDFLARE_ACCOUNT_ID=<from CF_ACCOUNT_ID> %s', cmd.join(' '))
        io.puts pages_reminder
        return 0
      end

      io.puts ''
      io.puts "deploying: #{cmd.join(' ')}"
      ok, out = runner.call(cmd, { 'CLOUDFLARE_ACCOUNT_ID' => env['CF_ACCOUNT_ID'].to_s })
      unless ok
        io.puts BTC::Env.redact(out.to_s).lines.last(5).join
        raise Error, 'wrangler deploy failed (see output above)'
      end

      host = env['DEPLOY_HOST'].to_s
      host = parse_deploy_url(out).to_s if host.empty?
      if host.empty?
        raise Error, 'could not determine deployed host (set DEPLOY_HOST=https://... and re-run with DEPLOY_SKIP_CHECKS=1)'
      end

      io.puts format('deployed host: %s', host)
      io.puts ''
      io.puts 'post-deploy smoke:'
      results = smoke(host, http: http, now: now)
      results.each do |name, probe_ok, detail|
        io.puts format('  [%-4s] %-32s %s', probe_ok ? 'PASS' : 'FAIL', name, detail)
      end
      io.puts pages_reminder

      results.count { |_, probe_ok, _| !probe_ok }.zero? ? 0 : 1
    end
  end
end
