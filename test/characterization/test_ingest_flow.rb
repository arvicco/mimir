# frozen_string_literal: true
#
# M7-1: characterization of the UNTESTED ingest.rb flow -- everything past
# the pure text helpers (M0-8) and the proposal-schema pin (M1-11). Pins
# CURRENT behavior of the propose -> review -> apply pipeline before the
# Phase 7 shakedown relies on it; oddities found are pinned, NOT fixed
# (see FINDINGS). No network, no ANTHROPIC_API_KEY.
#
# Harness. ingest.rb resolves universe.json / capstruct/ relative to its
# own __dir__, so each test runs the REAL script from a per-test tmpdir
# copy of scripts/btco with a synthetic universe.json, driven as a
# subprocess with BTC::Http's transport replaced by the fixture-backed
# fake (test/support/fake_transport.rb, injected via RUBYOPT). EDGAR
# discovery is served by the recorded edgar_submissions.json /
# edgar_filing.html fixtures; Time.now is frozen (FAKE_NOW) so backup
# stamps and ledger timestamps are deterministic.
#
# lib/ is SYMLINKED into the sandbox rather than copied: ingest.rb's
# `require_relative '../../lib/btc/http'` then resolves to the SAME
# realpath the fake_transport preload already loaded, so BTC::Http is not
# reopened. A COPY would re-execute `@transport = nil` (http.rb) and
# silently defeat the fake, letting discovery hit the real SEC -- see
# FINDING C. A broken http(s)_proxy is also set so any transport
# regression fails fast (connection refused) instead of reaching the wire.
#
# FINDINGS (pinned, not fixed -- flagged for the owner):
#   A. [FIXED same phase] --file dedup against PENDING was broken. The manual accession is
#      "manual-<hash>" (with a dash) but the pending filename strips all
#      dashes ("TST_manual<hash>.json"), so
#      `pending_files.any? { |f| f.include?(acc) }` never matches:
#      re-ingesting the same document while its proposal is still pending
#      re-writes the proposal (exit 0) instead of aborting. Dedup against
#      the LEDGER works (accession stored verbatim). Pinned in
#      the dedup test (pins the FIX now).
#   B. [FIXED same phase] universe.json.bak-<stamp> used second granularity. Two applies in
#      the same wall-clock second (here: a frozen clock in --apply-all-high)
#      collide on the backup filename and FileUtils.cp overwrites, so only
#      ONE backup survives a multi-apply batch. Pinned in
#      test_apply_all_high_*.
#   C. test/contract/test_ingest_contract.rb#test_dry_discovery_lists_
#      fixture_filings silently hits the real SEC network: its sandbox
#      copies lib/, which reopens BTC::Http and resets the injected
#      transport to nil. It passes only because dev/CI hosts have network
#      (Golden Rule 6 violation). This suite avoids it via the symlink
#      above. Not fixed here (out of M7-1 scope); flagged.

require_relative '../test_helper'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'digest'

class TestIngestFlow < Minitest::Test
  ROOT    = File.expand_path('../..', __dir__)
  SUPPORT = File.join(ROOT, 'test', 'support')
  REAL_BTCO = File.join(ROOT, 'scripts', 'btco')

  # FAKE_NOW: Time.now is frozen here, so bak stamps / ledger ts are exact.
  FROZEN_NOW = '2026-06-30T00:00:00Z'

  PROPOSAL_KEYS  = %w[accession analysed_at diff extraction filing_date
                      form mode ticker url].freeze
  HEURISTIC_KEYS = %w[btc confidence no_material_change shares_basic summary].freeze
  LEDGER_KEYS    = %w[accession confidence diff filing_date form mode
                      summary ts url].freeze

  # A material-change document: heuristic regexes pick up both the BTC
  # count and the share count (same doc shape as the M1-11 contract test).
  MATERIAL_DOC = 'The Company held 12,345 bitcoin as of June 30, 2026. ' \
                 'There were 123,456,789 shares of common stock issued ' \
                 'and outstanding.'

  # Guard: the real in-tree files must be byte-untouched by the whole
  # suite. Captured at load, before any test mutates a tmpdir.
  REAL_UNIVERSE_SHA = Digest::SHA256.hexdigest(File.read(File.join(REAL_BTCO, 'universe.json')))
  REAL_CAP_FILES    = Dir.glob(File.join(REAL_BTCO, 'capstruct', '**', '*'))
                         .select { |f| File.file?(f) }.sort.freeze

  def synthetic_universe
    { 'companies' => [
      # cik = the recorded edgar_submissions.json fixture's CIK; btc_as_of
      # is the discovery floor and the fixture filings are all newer (2026).
      { 'name' => 'Test Co', 'ticker' => 'TST', 'ccy' => 'USD',
        'cik' => '1050446', 'btc' => 100, 'btc_as_of' => '2020-01-01',
        'shares_basic' => 1_000, 'shares_diluted' => 1_000,
        'debt_face' => 0, 'pref_liq' => 0, 'converts' => [],
        'placeholder' => true, 'note' => 'keep me byte-identical' },
      # cik:null -> never discovered via EDGAR; manual --file only (NAKA-shaped).
      { 'name' => 'Naka', 'ticker' => 'NAKA', 'ccy' => 'USD',
        'cik' => nil, 'btc' => 500, 'btc_as_of' => '2020-01-01',
        'shares_basic' => 100, 'shares_diluted' => 100,
        'debt_face' => 0, 'pref_liq' => 0, 'converts' => [],
        'placeholder' => true }
    ] }
  end

  def setup
    @sandbox = Dir.mktmpdir('mimir-ingest-flow-')
    @btco    = File.join(@sandbox, 'scripts', 'btco')
    FileUtils.mkdir_p(File.join(@sandbox, 'scripts'))
    FileUtils.cp_r(REAL_BTCO, @btco)
    FileUtils.rm_rf(File.join(@btco, 'capstruct'))
    # a live owner session leaves real universe.json.bak-* in scripts/btco/
    # -- scrub them from the SANDBOX copy or the bak-count pins misfire
    Dir.glob(File.join(@btco, 'universe.json.bak-*')).each { |f| File.delete(f) }
    File.symlink(File.join(ROOT, 'lib'), File.join(@sandbox, 'lib')) # see header
    write_universe(synthetic_universe)
    @ingest = File.join(@btco, 'ingest.rb')
  end

  def teardown
    FileUtils.remove_entry(@sandbox) if @sandbox && Dir.exist?(@sandbox)
  end

  # ---- sandbox helpers --------------------------------------------------

  def universe_path
    File.join(@btco, 'universe.json')
  end

  def cap(*parts)
    File.join(@btco, 'capstruct', *parts)
  end

  def pending_files
    Dir.glob(cap('pending', '*.json')).sort
  end

  def bak_files
    Dir.glob(File.join(@btco, 'universe.json.bak-*')).sort
  end

  def write_universe(u)
    File.write(universe_path, JSON.pretty_generate(u))
  end

  def read_universe
    JSON.parse(File.read(universe_path))
  end

  def company(uni, ticker)
    uni['companies'].find { |c| c['ticker'] == ticker }
  end

  def seed_state(hash)
    FileUtils.mkdir_p(cap)
    File.write(cap('state.json'), JSON.pretty_generate(hash))
  end

  def read_state
    JSON.parse(File.read(cap('state.json')))
  end

  def write_proposal_file(name, hash)
    FileUtils.mkdir_p(cap('pending'))
    File.write(cap('pending', name), JSON.pretty_generate(hash))
  end

  def write_doc(text = MATERIAL_DOC)
    path = File.join(@sandbox, "doc-#{rand(1 << 32)}.txt")
    File.write(path, text)
    path
  end

  # Drive ingest.rb as a subprocess. key: nil unsets ANTHROPIC_API_KEY in
  # the child (heuristic mode); the broken proxy makes any real fetch fail
  # fast (the fixtures answer through the injected transport instead).
  def run_ingest(*argv, key: nil)
    env = { 'RUBYOPT'           => "-I#{SUPPORT} -rfake_transport",
            'FAKE_NOW'          => FROZEN_NOW,
            'ANTHROPIC_API_KEY' => key,
            'http_proxy'        => 'http://127.0.0.1:9',
            'https_proxy'       => 'http://127.0.0.1:9' }
    Open3.capture3(env, RbConfig.ruby, @ingest, *argv, chdir: @btco)
  end

  # ---- surface 1: proposal round-trip (--file -> --review -> --apply) ----

  def test_proposal_round_trip_file_review_apply
    naka_before = JSON.generate(company(read_universe, 'NAKA'))

    out, err, st = run_ingest('--file', write_doc, '--ticker', 'TST')
    assert st.success?, "ingest --file exit #{st.exitstatus}: #{err}\n#{out}"

    assert_equal 1, pending_files.size, "expected one proposal, got #{pending_files}"
    pr = JSON.parse(File.read(pending_files.first))
    assert_equal PROPOSAL_KEYS, pr.keys.sort
    assert_equal 'TST', pr['ticker']
    assert_equal 'MANUAL', pr['form']
    assert_equal 'heuristic', pr['mode'] # no ANTHROPIC_API_KEY -> heuristic dispatch
    assert_equal HEURISTIC_KEYS, pr['extraction'].keys.sort
    assert_equal 'low', pr['extraction']['confidence']
    assert_equal FROZEN_NOW, pr['analysed_at']
    assert_equal({ 'from' => 100, 'to' => 12_345 }, pr['diff']['btc'])
    assert_equal({ 'from' => 1_000, 'to' => 123_456_789 }, pr['diff']['shares_basic'])

    # --review lists the pending proposal with its summary + diff rows.
    rout, _rerr, rst = run_ingest('--review')
    assert rst.success?
    assert_match(/1 pending:/, rout)
    assert_match(/TST\s+MANUAL/, rout)
    assert_includes rout, pr['extraction']['summary']
    # whitespace-agnostic around =>: Hash#inspect prints {"k"=>v} on the
    # 3.3 CI target but {"k" => v} on newer local rubies (CI red 07-06/07)
    assert_match(/btc\s+\{.*"from"\s*=>\s*100.*"to"\s*=>\s*12345/, rout)
    assert_match(/shares_basic\s+\{.*123456789/, rout)

    # --apply mutates universe.json in place.
    aout, aerr, ast = run_ingest('--apply', pending_files.first)
    assert ast.success?, "apply exit #{ast.exitstatus}: #{aerr}"
    assert_match(/applied .*\(backup universe\.json\.bak-20260630000000\)/, aout)

    after = read_universe
    tst = company(after, 'TST')
    assert_equal 12_345, tst['btc']
    assert_equal 123_456_789, tst['shares_basic']
    assert_equal 1_000, tst['shares_diluted'] # untouched field stays
    assert_equal false, tst['placeholder']    # placeholder flips false

    # OTHER company byte-identical (same serialized bytes, not just ==).
    assert_equal naka_before, JSON.generate(company(after, 'NAKA'))

    # timestamped backup created (frozen clock -> exact name).
    assert_equal [File.join(@btco, 'universe.json.bak-20260630000000')], bak_files

    # exactly one ledger line, pinned key set + values.
    lines = File.readlines(cap('TST.jsonl'))
    assert_equal 1, lines.size
    led = JSON.parse(lines.first)
    assert_equal LEDGER_KEYS, led.keys.sort
    assert_equal FROZEN_NOW, led['ts']
    assert_equal 'MANUAL', led['form']
    assert_equal 'heuristic', led['mode']
    assert_equal 'low', led['confidence']
    assert_match(/\Amanual-[0-9a-f]{12}\z/, led['accession'])
    assert_equal({ 'from' => 100, 'to' => 12_345 }, led['diff']['btc'])

    # proposal file deleted on apply.
    assert_empty pending_files
  end

  # ---- surface 2: --dismiss ---------------------------------------------

  def test_dismiss_removes_proposal_without_touching_universe_or_ledger
    run_ingest('--file', write_doc, '--ticker', 'TST')
    assert_equal 1, pending_files.size
    acc = JSON.parse(File.read(pending_files.first))['accession']
    uni_before = File.read(universe_path)

    out, err, st = run_ingest('--dismiss', acc)
    assert st.success?, "dismiss exit #{st.exitstatus}: #{err}"
    assert_match(/dismissed /, out)

    assert_empty pending_files                       # proposal gone
    assert_equal uni_before, File.read(universe_path) # universe untouched
    refute File.exist?(cap('TST.jsonl'))              # no ledger line written
    assert_empty bak_files                            # no backup
  end

  # ---- surface 3: --apply-all-high (AI/high only + reload between) -------

  # As-of guard (owner catch, 2026-07-07): applying an OLDER filing's
  # proposal after a newer btc count is in the model must not regress
  # btc/btc_as_of; the other diffed fields still apply.
  def test_apply_skips_btc_older_than_model
    uni = synthetic_universe
    company(uni, 'TST')['btc'] = 843_775
    company(uni, 'TST')['btc_as_of'] = '2026-07-05'
    write_universe(uni)
    write_proposal_file('TST_accold.json',
                        'ticker' => 'TST', 'accession' => 'acc-old', 'form' => '10-Q',
                        'filing_date' => '2026-05-10', 'url' => 'u', 'mode' => 'ai',
                        'extraction' => { 'btc' => 568_840, 'btc_as_of' => '2026-03-31',
                                          'shares_basic' => 5_000,
                                          'confidence' => 'high', 'summary' => 's' },
                        'diff' => { 'btc' => { 'from' => 843_775, 'to' => 568_840 },
                                    'btc_as_of' => { 'from' => '2026-07-05', 'to' => '2026-03-31' },
                                    'shares_basic' => { 'from' => 1_000, 'to' => 5_000 } })

    out, err, st = run_ingest('--apply', 'acc-old')
    assert st.success?, err
    assert_match(/btc\/btc_as_of SKIPPED: model already newer/, out)
    after = company(read_universe, 'TST')
    assert_equal 843_775, after['btc'], 'older filing must not regress btc'
    assert_equal '2026-07-05', after['btc_as_of']
    assert_equal 5_000, after['shares_basic'], 'other fields still apply'
  end

  def test_apply_all_high_applies_only_ai_high_and_reloads_between
    write_universe('companies' => [company(synthetic_universe, 'TST')])

    # Two AI/high proposals for the SAME ticker: proposal 2's 'from' is
    # proposal 1's result, and each adds a distinct convert -> if the loop
    # reloads universe.json between applies, both share bumps AND both
    # converts land. (AI-mode shapes are built directly: the Claude call
    # is not injectable and heuristic mode can never yield confidence
    # high; the apply machinery reads the proposal file regardless of how
    # it was produced.)
    write_proposal_file('TST_acc0001.json',
                        'ticker' => 'TST', 'accession' => 'acc-0001', 'form' => '8-K',
                        'filing_date' => '2026-06-01', 'url' => 'u1', 'mode' => 'ai',
                        'analysed_at' => FROZEN_NOW,
                        'extraction' => { 'confidence' => 'high', 'summary' => 's1' },
                        'diff' => { 'shares_basic' => { 'from' => 1_000, 'to' => 2_000 },
                                    'converts_add' => [{ 'face' => 1, 'conv_price' => 2, 'label' => 'A' }] })
    write_proposal_file('TST_acc0002.json',
                        'ticker' => 'TST', 'accession' => 'acc-0002', 'form' => '8-K',
                        'filing_date' => '2026-06-02', 'url' => 'u2', 'mode' => 'ai',
                        'analysed_at' => FROZEN_NOW,
                        'extraction' => { 'confidence' => 'high', 'summary' => 's2' },
                        'diff' => { 'shares_basic' => { 'from' => 2_000, 'to' => 3_000 },
                                    'converts_add' => [{ 'face' => 3, 'conv_price' => 4, 'label' => 'B' }] })
    # Must NOT apply: heuristic/low, and an ai/medium.
    write_proposal_file('TST_acc0003.json',
                        'ticker' => 'TST', 'accession' => 'acc-0003', 'form' => '8-K',
                        'filing_date' => '2026-06-03', 'url' => 'u3', 'mode' => 'heuristic',
                        'analysed_at' => FROZEN_NOW,
                        'extraction' => { 'confidence' => 'low', 'summary' => 's3' },
                        'diff' => { 'btc' => { 'from' => 100, 'to' => 999 } })
    write_proposal_file('TST_acc0004.json',
                        'ticker' => 'TST', 'accession' => 'acc-0004', 'form' => '8-K',
                        'filing_date' => '2026-06-04', 'url' => 'u4', 'mode' => 'ai',
                        'analysed_at' => FROZEN_NOW,
                        'extraction' => { 'confidence' => 'medium', 'summary' => 's4' },
                        'diff' => { 'btc' => { 'from' => 100, 'to' => 777 } })

    _out, err, st = run_ingest('--apply-all-high')
    assert st.success?, "apply-all-high exit #{st.exitstatus}: #{err}"

    tst = company(read_universe, 'TST')
    assert_equal 3_000, tst['shares_basic'] # 1000 -> 2000 -> 3000 (reload proven)
    assert_equal 100, tst['btc']            # low + medium proposals NOT applied
    assert_equal [{ 'face' => 1, 'conv_price' => 2, 'label' => 'A' },
                  { 'face' => 3, 'conv_price' => 4, 'label' => 'B' }],
                 tst['converts'] # both converts accumulate -> reload between applies
    assert_equal false, tst['placeholder']

    ledger = File.readlines(cap('TST.jsonl')).map { |l| JSON.parse(l)['accession'] }
    assert_equal %w[acc-0001 acc-0002], ledger

    # only the two low/medium proposals remain pending.
    remaining = pending_files.map { |f| File.basename(f) }.sort
    assert_equal %w[TST_acc0003.json TST_acc0004.json], remaining

    # Finding B FIXED: same-second applies uniquify the backup name
    # (-2 suffix), so a batch keeps EVERY backup.
    assert_equal 2, bak_files.size
    assert_match(/bak-20260630000000-2\z/, bak_files.last)
  end

  # ---- surface 4: --status shape ----------------------------------------

  def test_status_output_shape
    seed_state('TST' => { 'seen' => %w[a b c], 'floor' => '2025-05-05' })
    File.write(cap('TST.jsonl'),
               "#{JSON.generate('accession' => 'led-1')}\n" \
               "#{JSON.generate('accession' => 'led-2')}\n")
    write_proposal_file('TST_x.json', {})

    out, _err, st = run_ingest('--status')
    assert st.success?
    lines = out.lines.map(&:rstrip)

    # per-company column layout, floor from state, last = newest ledger acc.
    assert_match(/\ATST\s+cik 1050446\s+floor 2025-05-05 seen 3\s+pending 1\s+applied 2\s+last led-2\z/,
                 lines[0])
    # NAKA has no state/ledger: cik '--', floor falls back to btc_as_of, zeros.
    assert_match(/\ANAKA\s+cik --\s+floor 2020-01-01 seen 0\s+pending 0\s+applied 0\z/,
                 lines[1])
  end

  # ---- surface 5: state.json lifecycle ----------------------------------

  def test_state_json_created_floor_from_btc_as_of_and_seen_grows
    _out, err, st = run_ingest('--limit', '2')
    assert st.success?, "ingest exit #{st.exitstatus}: #{err}"

    assert File.exist?(cap('state.json'))
    tst = read_state['TST']
    assert_equal '2020-01-01', tst['floor'] # initialized from btc_as_of
    assert_equal 2, tst['seen'].size        # --limit 2 filings marked seen
    tst['seen'].each { |a| assert_match(/\A\d{10}-\d{2}-\d{6}\z/, a) } # real EDGAR accessions
  end

  def test_dry_persists_nothing
    _out, _err, st = run_ingest('--dry')
    assert st.success?
    refute File.exist?(cap('state.json')) # load-bearing for the Phase 7 alert job
    assert_empty pending_files
    assert_empty bak_files
  end

  def test_seen_array_capped_at_500
    dummies = Array.new(500) { |i| format('dummy-%04d', i) }
    seed_state('TST' => { 'seen' => dummies, 'floor' => '2020-01-01' })

    _out, _err, st = run_ingest('--limit', '5')
    assert st.success?

    seen = read_state['TST']['seen']
    assert_equal 500, seen.size                 # capped
    refute_includes seen, 'dummy-0000'          # oldest shifted out
    assert seen.any? { |a| a.start_with?('0001193125') } # newest real acc kept
  end

  # ---- surface 6: dedupe tripod -----------------------------------------

  def test_dedupe_state_seen_accession_skipped
    skip_acc = '0001193125-26-286871' # newest fixture filing
    seed_state('TST' => { 'seen' => [skip_acc], 'floor' => '2020-01-01' })

    out, _err, st = run_ingest('--dry')
    assert st.success?
    refute_includes out, skip_acc.delete('-') # skipped acc absent from discovery
    assert_match(/TST\s+\d+ new filing\(s\)/, out) # others still discovered
  end

  def test_dedupe_ledger_accession_skipped_with_empty_state
    skip_acc = '0001193125-26-286871'
    FileUtils.mkdir_p(cap)
    File.write(cap('TST.jsonl'), "#{JSON.generate('accession' => skip_acc)}\n")

    out, _err, st = run_ingest('--dry') # no state.json at all
    assert st.success?
    refute_includes out, skip_acc.delete('-') # ledger dedup applies even w/o state
  end

  def test_file_dedup_pending_and_ledger_both_abort
    doc = write_doc
    o1, _e1, s1 = run_ingest('--file', doc, '--ticker', 'TST')
    assert s1.success?
    assert_equal 1, pending_files.size
    acc = JSON.parse(File.read(pending_files.first))['accession']

    # Finding A FIXED: re-ingesting while the proposal is still pending
    # aborts (dedup now matches the dash-stripped pending filename).
    _o2, e2, s2 = run_ingest('--file', doc, '--ticker', 'TST')
    refute s2.success?, 'pending dedup must abort (finding A fix)'
    assert_match(/already ingested/, e2)
    assert_equal 1, pending_files.size # untouched, not re-written
    refute_equal '', o1                # (touch o1 to keep it meaningful)

    # Ledger dedup DOES work: seed the accession into the ledger, clear
    # pending, re-ingest -> abort with nonzero exit.
    FileUtils.rm_f(pending_files)
    File.write(cap('TST.jsonl'), "#{JSON.generate('accession' => acc)}\n")
    _o3, e3, s3 = run_ingest('--file', doc, '--ticker', 'TST')
    refute s3.success?, 'ledger dedup must abort'
    assert_match(/already ingested \(#{Regexp.escape(acc)}\)/, e3) # abort -> stderr
    assert_empty pending_files
  end

  # ---- surface 7: --file manual ingestion for a cik:null company --------

  def test_manual_file_ingestion_for_null_cik_company
    out, err, st = run_ingest('--file', write_doc, '--ticker', 'NAKA')
    assert st.success?, "ingest --file NAKA exit #{st.exitstatus}: #{err}\n#{out}"

    assert_equal 1, pending_files.size
    pr = JSON.parse(File.read(pending_files.first))
    assert_equal 'NAKA', pr['ticker']
    assert_equal 'MANUAL', pr['form']
    assert_equal 'heuristic', pr['mode']
    assert_equal({ 'from' => 500, 'to' => 12_345 }, pr['diff']['btc'])
    assert_equal({ 'from' => 100, 'to' => 123_456_789 }, pr['diff']['shares_basic'])
  end

  # ---- guard: real in-tree files untouched by the whole suite ----------

  def test_real_universe_and_capstruct_byte_untouched
    assert_equal REAL_UNIVERSE_SHA,
                 Digest::SHA256.hexdigest(File.read(File.join(REAL_BTCO, 'universe.json'))),
                 'real scripts/btco/universe.json changed during the suite'
    now = Dir.glob(File.join(REAL_BTCO, 'capstruct', '**', '*'))
             .select { |f| File.file?(f) }.sort
    assert_equal REAL_CAP_FILES, now,
                 'real scripts/btco/capstruct/ gained or lost files during the suite'
  end
end
