# frozen_string_literal: true
#
# test_btco_alert.rb -- ops/btco_alert.rb, the daily BTCo discovery-alert
# job (M7-2). Two layers:
#
#   1. Fast in-process unit tests with an INJECTED runner + injected status
#      dir (never the real /tmp): every token form (ING n!, empty, ING ?),
#      always-clean behavior, and the no-fetch/no-state PROOF that the
#      runner is invoked with `--dry --json` ONLY.
#   2. One subprocess integration test that drives the REAL btco_alert.rb
#      against an ingest sandbox (fixture-backed fake transport, lib/
#      SYMLINKED per the M7-1 finding-C lesson), asserting the EDGAR
#      submissions endpoint is the ONLY URL requested, no state.json is
#      written, and the job exits 0.
#
# No network, no ANTHROPIC_API_KEY.

require_relative '../test_helper'
require_relative '../../ops/btco_alert'
require 'open3'
require 'tmpdir'
require 'fileutils'

class TestBtcoAlert < Minitest::Test
  ROOT       = File.expand_path('../..', __dir__)
  SUPPORT    = File.join(ROOT, 'test', 'support')
  REAL_BTCO  = File.join(ROOT, 'scripts', 'btco')
  FROZEN_NOW = '2026-06-30T00:00:00Z'

  def setup
    @dir = Dir.mktmpdir('mimir-btco-alert-')
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  # ---- helpers ---------------------------------------------------------

  # Read /tmp/ingest.status from the injected dir; the alert ALWAYS writes it.
  def status_line
    path = File.join(@dir, 'ingest.status')
    assert File.exist?(path), 'the alert must always write ingest.status'
    File.read(path)
  end

  # Canned ingest --dry --json output with n filings.
  def json_out(n)
    filings = Array.new(n) do |i|
      { 'ticker' => 'TST', 'form' => '8-K',
        'date' => format('2026-06-%02d', i + 1), 'accession' => format('000-%02d', i) }
    end
    JSON.generate('new' => n, 'filings' => filings)
  end

  # Injected runner that records the argv it received and returns canned IO.
  def recording_runner(ok:, out:)
    seen = []
    [->(argv) { seen << argv; [ok, out] }, seen]
  end

  # ---- token forms (injected runner + injected dir) --------------------

  def test_new_filings_writes_bang_token_and_uses_dry_json_only
    runner, seen = recording_runner(ok: true, out: json_out(3))
    note = Ops::BtcoAlert.run(status_dir: @dir, runner: runner)

    assert_equal "ING 3!\n", status_line
    assert_includes note, 'ING 3!'
    # PROOF: discovery is invoked with --dry --json ONLY (no fetch, no AI,
    # no --apply, no state write).
    assert_equal [%w[--dry --json]], seen
  end

  def test_zero_filings_writes_empty_file
    runner, = recording_runner(ok: true, out: json_out(0))
    Ops::BtcoAlert.run(status_dir: @dir, runner: runner)
    # empty line -> the tmux #() collapses to nothing (quiet bar, D8-a).
    assert_equal "\n", status_line
  end

  def test_nonzero_exit_writes_error_token
    runner, = recording_runner(ok: false, out: '')
    Ops::BtcoAlert.run(status_dir: @dir, runner: runner)
    assert_equal "ING ?\n", status_line
  end

  def test_unparseable_output_writes_error_token
    runner, = recording_runner(ok: true, out: "not json at all\n")
    Ops::BtcoAlert.run(status_dir: @dir, runner: runner)
    assert_equal "ING ?\n", status_line
  end

  def test_shape_mismatch_writes_error_token
    # count disagrees with the filings array length -> unparseable shape.
    runner, = recording_runner(ok: true, out: JSON.generate('new' => 5, 'filings' => []))
    Ops::BtcoAlert.run(status_dir: @dir, runner: runner)
    assert_equal "ING ?\n", status_line
  end

  def test_runner_that_raises_is_survived_as_error_token
    Ops::BtcoAlert.run(status_dir: @dir, runner: ->(_argv) { raise 'spawn failed' })
    assert_equal "ING ?\n", status_line
  end

  # ---- pure token/render helpers ---------------------------------------

  def test_token_forms
    assert_equal 'ING 3!', Ops::BtcoAlert.token(3)
    assert_equal '',       Ops::BtcoAlert.token(0)
    assert_equal 'ING ?',  Ops::BtcoAlert.token(nil)
  end

  # ---- integration: real subprocess against the ingest sandbox ---------

  def test_integration_only_submissions_requested_no_state_exit_0
    sandbox = Dir.mktmpdir('mimir-btco-alert-int-')
    btco    = File.join(sandbox, 'scripts', 'btco')
    FileUtils.mkdir_p(File.join(sandbox, 'scripts'))
    FileUtils.mkdir_p(File.join(sandbox, 'ops'))
    FileUtils.cp_r(REAL_BTCO, btco)
    FileUtils.rm_rf(File.join(btco, 'capstruct'))
    # SYMLINK lib/, never copy: the child ingest's require_relative must
    # resolve to the SAME BTC::Http realpath the fake transport preloaded
    # (M7-1 finding C -- a copy reopens BTC::Http and hits the real SEC).
    File.symlink(File.join(ROOT, 'lib'), File.join(sandbox, 'lib'))
    File.write(File.join(btco, 'universe.json'), JSON.generate(
                 'companies' => [
                   { 'name' => 'Test Co', 'ticker' => 'TST', 'ccy' => 'USD',
                     'cik' => '1050446', 'btc' => 100, 'btc_as_of' => '2020-01-01',
                     'shares_basic' => 1_000, 'shares_diluted' => 1_000,
                     'debt_face' => 0, 'pref_liq' => 0, 'converts' => [],
                     'placeholder' => true }
                 ]
               ))
    # The real alert script; its INGEST resolves to sandbox/scripts/btco.
    FileUtils.cp(File.join(ROOT, 'ops', 'btco_alert.rb'), File.join(sandbox, 'ops', 'btco_alert.rb'))

    url_log    = File.join(sandbox, 'urls.log')
    status_dir = File.join(sandbox, 'status')
    FileUtils.mkdir_p(status_dir)
    env = { 'RUBYOPT'           => "-I#{SUPPORT} -rfake_transport",
            'FAKE_NOW'          => FROZEN_NOW,
            'FAKE_HTTP_LOG'     => url_log,        # record every requested URL
            'ANTHROPIC_API_KEY' => nil,            # heuristic path never reached under --dry
            'http_proxy'        => 'http://127.0.0.1:9', # any real fetch fails fast
            'https_proxy'       => 'http://127.0.0.1:9' }
    _out, err, st = Open3.capture3(env, RbConfig.ruby,
                                   File.join(sandbox, 'ops', 'btco_alert.rb'), status_dir)

    assert_equal 0, st.exitstatus, "alert must exit 0 (stderr: #{err})"

    # Token written for the fixture's new filings.
    token = File.read(File.join(status_dir, 'ingest.status'))
    assert_match(/\AING \d+!\n\z/, token, "expected an ING n! token, got #{token.inspect}")

    # ONLY the EDGAR submissions endpoint was requested -- no document
    # fetch (Archives/edgar), no AI (anthropic).
    urls = File.exist?(url_log) ? File.readlines(url_log).map(&:strip).reject(&:empty?) : []
    refute_empty urls, 'discovery must have queried the submissions endpoint'
    urls.each { |u| assert_includes u, 'data.sec.gov/submissions/CIK', "unexpected URL requested: #{u}" }
    refute(urls.any? { |u| u.include?('Archives/edgar') }, 'must NOT fetch any filing document')
    refute(urls.any? { |u| u.include?('anthropic') }, 'must NOT call the AI endpoint')

    # No state mutation: --dry never writes state.json.
    refute File.exist?(File.join(btco, 'capstruct', 'state.json'))
  ensure
    FileUtils.remove_entry(sandbox) if sandbox && Dir.exist?(sandbox)
  end
end
