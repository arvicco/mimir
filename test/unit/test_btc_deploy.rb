# frozen_string_literal: true

# M4-5: BTC::Deploy -- owner-run deploy automation. Pure pieces
# (template substitution, pre-flight table, smoke verdicts) plus a
# thin orchestrator driven by an injected runner. NO network, NO real
# wrangler: the subprocess runner is a recording lambda and HTTP goes
# through an injected BTC::Http transport. Secret discipline is asserted:
# CF_* values never appear, only 'set' / 'MISSING'.

require_relative '../test_helper'
require_relative '../../lib/btc/deploy'
require 'stringio'
require 'tmpdir'

class TestBtcDeploy < Minitest::Test
  FakeRes = Struct.new(:code, :body)

  ACCOUNT   = 'acct-SECRET-1234'
  NAMESPACE = 'ns-SECRET-5678'
  ENV_OK = { 'CLOUDFLARE_ACCOUNT_ID' => ACCOUNT, 'CLOUDFLARE_KV_NAMESPACE_ID' => NAMESPACE }.freeze

  def teardown
    BTC::Http.transport = nil
  end

  # A runner that always succeeds with empty output (clean tree, wrangler
  # present, gate green) and records every invocation.
  def ok_runner(calls)
    lambda do |cmd, overrides = {}|
      calls << { cmd: cmd, env: overrides }
      [true, cmd.first == 'wrangler' ? 'wrangler 3.99.0' : '']
    end
  end

  # ---- CI refusal ----------------------------------------------------

  def test_run_refuses_under_ci
    e = assert_raises(BTC::Deploy::Error) do
      BTC::Deploy.run(env: ENV_OK.merge('CI' => '1'), io: StringIO.new)
    end
    assert_match(/Golden Rule 3/, e.message)
    assert_match(/REFUSES/, e.message)
  end

  def test_ci_predicate_ignores_empty_and_falsey
    refute BTC::Deploy.ci?({})
    refute BTC::Deploy.ci?('CI' => '')
    refute BTC::Deploy.ci?('CI' => '0')
    refute BTC::Deploy.ci?('CI' => 'false')
    assert BTC::Deploy.ci?('CI' => '1')
    assert BTC::Deploy.ci?('CI' => 'true')
  end

  # ---- template substitution -----------------------------------------

  def test_substitute_replaces_only_the_placeholder
    template = <<~TOML
      name = "mimir"
      [[kv_namespaces]]
      binding = "MIMIR"
      id = "#{BTC::Deploy::PLACEHOLDER}"
    TOML
    out = BTC::Deploy.substitute_template(template, 'real-ns-id')
    assert_includes out, 'id = "real-ns-id"'
    refute_includes out, BTC::Deploy::PLACEHOLDER
    # everything else byte-identical
    assert_equal template.sub(BTC::Deploy::PLACEHOLDER, 'real-ns-id'), out
    assert_includes out, 'binding = "MIMIR"'
    assert_includes out, 'name = "mimir"'
  end

  # ---- DEPLOY_NAME worker rename (ruling D4-c: unguessable hostname) --

  def test_substitute_name_replaces_only_the_name_line
    content = %(name = "mimir"\nmain = "web/worker.mjs"\n)
    out = BTC::Deploy.substitute_name(content, 'mimir-a7f3k9')
    assert_includes out, 'name = "mimir-a7f3k9"'
    assert_includes out, 'main = "web/worker.mjs"'
    refute_includes out, %(name = "mimir"\n)
  end

  def test_substitute_name_noop_when_unset
    content = %(name = "mimir"\n)
    assert_equal content, BTC::Deploy.substitute_name(content, nil)
    assert_equal content, BTC::Deploy.substitute_name(content, '')
  end

  def test_substitute_name_rejects_invalid_worker_names
    ['Has Space', 'UPPER', 'a' * 60, 'semi;colon'].each do |bad|
      assert_raises(BTC::Deploy::Error) { BTC::Deploy.substitute_name('name = "x"', bad) }
    end
  end

  def test_substitute_raises_when_placeholder_absent
    e = assert_raises(BTC::Deploy::Error) { BTC::Deploy.substitute_template('no marker here', 'x') }
    assert_match(/missing/, e.message)
  end

  def test_generate_config_writes_filled_toml_to_gitignored_path
    Dir.mktmpdir do |dir|
      tmpl = File.join(dir, 'wrangler.toml')
      out  = File.join(dir, 'data', 'wrangler.generated.toml')
      File.write(tmpl, %(id = "#{BTC::Deploy::PLACEHOLDER}"\n))
      path = BTC::Deploy.generate_config(env: ENV_OK, template_path: tmpl, out_path: out)
      assert_equal out, path
      assert_equal %(id = "#{NAMESPACE}"\n), File.read(out)
    end
  end

  def test_generate_config_requires_namespace
    e = assert_raises(BTC::Deploy::Error) { BTC::Deploy.generate_config(env: {}) }
    assert_match(/CLOUDFLARE_KV_NAMESPACE_ID/, e.message)
  end

  # ---- pre-flight report shape ---------------------------------------

  def test_preflight_missing_env_reports_MISSING_never_the_value
    calls = []
    pf = BTC::Deploy.preflight(env: {}, runner: ok_runner(calls), skip_checks: true)
    account = pf.rows.find { |r| r[0] == 'CLOUDFLARE_ACCOUNT_ID' }
    ns      = pf.rows.find { |r| r[0] == 'CLOUDFLARE_KV_NAMESPACE_ID' }
    assert_equal 'MISSING', account[1]
    assert_equal 'MISSING', ns[1]
    refute pf.ok # missing env fails the table
  end

  def test_preflight_present_env_says_set_not_the_value
    calls = []
    pf = BTC::Deploy.preflight(env: ENV_OK, runner: ok_runner(calls), skip_checks: true)
    text = pf.rows.map { |r| r.join(' ') }.join("\n")
    refute_includes text, ACCOUNT
    refute_includes text, NAMESPACE
    assert(pf.rows.select { |r| BTC::Deploy::CF_ENV.include?(r[0]) }.all? { |r| r[1] == 'set' })
    assert pf.ok
  end

  def test_preflight_skip_checks_skips_tree_and_gate
    calls = []
    BTC::Deploy.preflight(env: ENV_OK, runner: ok_runner(calls), skip_checks: true)
    ran = calls.map { |c| c[:cmd].first }
    refute_includes ran, 'git'
    refute_includes ran, 'rake'
    assert_includes ran, 'wrangler'
  end

  def test_preflight_runs_tree_and_gate_when_not_skipped
    calls = []
    pf = BTC::Deploy.preflight(env: ENV_OK, runner: ok_runner(calls), skip_checks: false)
    ran = calls.map { |c| c[:cmd] }
    assert_includes ran, %w[git status --porcelain]
    assert_includes ran, %w[rake]
    assert pf.ok # clean tree + green gate
  end

  def test_preflight_dirty_tree_fails
    runner = lambda do |cmd, _ = {}|
      return [true, " M lib/btc/deploy.rb\n"] if cmd.first == 'git'

      [true, cmd.first == 'wrangler' ? 'wrangler 3.99.0' : '']
    end
    pf = BTC::Deploy.preflight(env: ENV_OK, runner: runner, skip_checks: false)
    refute pf.ok
    tree = pf.rows.find { |r| r[0] == 'working tree' }
    assert_match(/dirty/, tree[1])
  end

  # ---- deploy command assembly ---------------------------------------

  def test_deploy_command_array
    assert_equal ['wrangler', 'deploy', '-c', 'data/wrangler.generated.toml'],
                 BTC::Deploy.deploy_command
    assert_equal ['wrangler', 'deploy', '-c', 'x.toml'], BTC::Deploy.deploy_command('x.toml')
  end

  def test_parse_deploy_url
    out = "Total Upload: 3 KiB\nUploaded mimir\nPublished mimir\n  https://mimir.example.workers.dev\n"
    assert_equal 'https://mimir.example.workers.dev', BTC::Deploy.parse_deploy_url(out)
    assert_nil BTC::Deploy.parse_deploy_url('no url printed')
  end

  # ---- dry run: assembles the command, executes nothing --------------

  def test_dry_run_prints_command_and_never_executes_wrangler
    Dir.mktmpdir do |dir|
      tmpl = File.join(dir, 'wrangler.toml')
      out  = File.join(dir, 'data', 'wrangler.generated.toml')
      File.write(tmpl, %(id = "#{BTC::Deploy::PLACEHOLDER}"\n))
      calls = []
      io = StringIO.new
      code = BTC::Deploy.run(env: ENV_OK.merge('DEPLOY_DRY_RUN' => '1'),
                             runner: ok_runner(calls), io: io,
                             template_path: tmpl, out_path: out)
      assert_equal 0, code
      # wrangler deploy NEVER invoked in dry run
      refute(calls.any? { |c| c[:cmd].first == 'wrangler' && c[:cmd][1] == 'deploy' })
      text = io.string
      assert_includes text, 'wrangler deploy -c ' + out
      assert_includes text, 'DRY RUN'
      assert_includes text, 'would run: wrangler deploy -c '
      assert_includes text, 'ships IN this deploy' # dashboard-in-same-deploy note
      # secret discipline: no CF_* value anywhere in output
      refute_includes text, ACCOUNT
      refute_includes text, NAMESPACE
    end
  end

  def test_dry_run_is_non_blocking_when_wrangler_absent
    Dir.mktmpdir do |dir|
      tmpl = File.join(dir, 'wrangler.toml')
      out  = File.join(dir, 'data', 'wrangler.generated.toml')
      File.write(tmpl, %(id = "#{BTC::Deploy::PLACEHOLDER}"\n))
      runner = ->(cmd, _ = {}) { cmd.first == 'wrangler' ? [false, 'not found'] : [true, ''] }
      io = StringIO.new
      code = BTC::Deploy.run(env: ENV_OK.merge('DEPLOY_DRY_RUN' => '1'),
                             runner: runner, io: io, template_path: tmpl, out_path: out)
      assert_equal 0, code
      assert_includes io.string, 'MISSING (not on PATH)'
      assert_includes io.string, 'does not block'
    end
  end

  # ---- smoke verdicts against a fake transport -----------------------

  def transport_for(map)
    BTC::Http.transport = lambda do |uri, _req, _opts|
      path = uri.request_uri
      key = map.keys.find { |k| path.end_with?(k) }
      map.fetch(key, FakeRes.new('500', 'unexpected'))
    end
  end

  def test_smoke_all_pass
    now = Time.utc(2026, 7, 5, 12, 0, 0)
    gen = (now - 3600).iso8601
    transport_for(
      '/healthz' => FakeRes.new('200', '{"ok":true,"worker_ts":"x"}'),
      '/api/v1/index' => FakeRes.new('200', %({"v":1,"generated_at":"#{gen}","payload":{}})),
      '/api/v1/definitely:missing' => FakeRes.new('404', '{"error":"unknown key"}'),
      '/' => FakeRes.new('200', '<html><head><title>mimir</title></head></html>')
    )
    results = BTC::Deploy.smoke('https://mimir.example.workers.dev', now: now)
    assert_equal 4, results.size # healthz, index, 404 path, dashboard
    assert(results.all? { |_, ok, _| ok }, results.inspect)
  end

  def test_real_deploy_child_env_strips_only_the_legacy_token_name
    # One token, one name (Gate 4 ruling): wrangler reads
    # CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID from the inherited
    # env untouched. The child override must clear ONLY the legacy
    # CF_API_TOKEN alias (a stale env line would make wrangler warn or,
    # if it holds an old narrow token, hijack auth) -- and must NEVER
    # unset the canonical token name.
    now = Time.utc(2026, 7, 5, 12, 0, 0)
    gen = (now - 60).iso8601
    transport_for(
      '/healthz' => FakeRes.new('200', '{"ok":true,"worker_ts":"x"}'),
      '/api/v1/index' => FakeRes.new('200', %({"generated_at":"#{gen}"})),
      '/api/v1/definitely:missing' => FakeRes.new('404', '{}'),
      '/' => FakeRes.new('200', '<title>mimir</title>')
    )
    Dir.mktmpdir do |dir|
      tmpl = File.join(dir, 'wrangler.toml')
      out  = File.join(dir, 'data', 'wrangler.generated.toml')
      File.write(tmpl, %(id = "#{BTC::Deploy::PLACEHOLDER}"\n))
      calls = []
      runner = lambda do |cmd, overrides = {}|
        calls << { cmd: cmd, env: overrides }
        [true, cmd[1] == 'deploy' ? 'https://mimir.acct.workers.dev' : 'wrangler 4.0.0']
      end
      code = BTC::Deploy.run(env: ENV_OK.merge('DEPLOY_SKIP_CHECKS' => '1'),
                             runner: runner, io: StringIO.new, now: now,
                             template_path: tmpl, out_path: out)
      assert_equal 0, code
      dep = calls.find { |c| c[:cmd][1] == 'deploy' }
      assert_equal({ 'CF_API_TOKEN' => nil }, dep[:env])
      refute dep[:env].key?('CLOUDFLARE_API_TOKEN'),
             'canonical token name must pass through untouched'
    end
  end

  def test_smoke_dashboard_verdict
    assert BTC::Deploy.verdict_dashboard(200, '<title>mimir</title>').first
    ok, detail = BTC::Deploy.verdict_dashboard(200, '<html>somebody else</html>')
    refute ok
    assert_match(/not the dashboard shell/, detail)
    refute BTC::Deploy.verdict_dashboard(404, '').first
  end

  def test_smoke_healthz_wrong_body_fails
    ok, = BTC::Deploy.verdict_healthz(200, '{"ok":false}')
    refute ok
    ok2, = BTC::Deploy.verdict_healthz(200, 'not json')
    refute ok2
    ok3, = BTC::Deploy.verdict_healthz(500, 'boom')
    refute ok3
  end

  def test_smoke_index_stale_fails
    now = Time.utc(2026, 7, 5, 12, 0, 0)
    old = (now - (8 * 24 * 3600)).iso8601
    ok, detail = BTC::Deploy.verdict_index(200, %({"generated_at":"#{old}"}), now)
    refute ok
    assert_match(/stale/, detail)
  end

  def test_smoke_index_bad_envelope_fails
    now = Time.utc(2026, 7, 5, 12, 0, 0)
    ok, = BTC::Deploy.verdict_index(200, 'not json', now)
    refute ok
    ok2, d2 = BTC::Deploy.verdict_index(200, '{"payload":{}}', now) # no generated_at
    refute ok2
    assert_match(/generated_at/, d2)
    ok3, = BTC::Deploy.verdict_index(404, '{}', now)
    refute ok3
  end

  def test_smoke_index_fresh_passes
    now = Time.utc(2026, 7, 5, 12, 0, 0)
    gen = (now - 1800).iso8601
    ok, detail = BTC::Deploy.verdict_index(200, %({"generated_at":"#{gen}"}), now)
    assert ok
    assert_match(/age 0\.5h/, detail)
  end

  def test_smoke_missing_verdict
    assert BTC::Deploy.verdict_missing(404, '').first
    refute BTC::Deploy.verdict_missing(200, '').first
    refute BTC::Deploy.verdict_missing(nil, '').first
  end
end
