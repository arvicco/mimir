# frozen_string_literal: true
#
# M1-11: contracts for the ingest pipeline -- the pending-proposal JSON
# schema, --dry EDGAR discovery against the recorded fixtures, the
# excerpt pipeline on the recorded 8-K, and a VERBATIM pin of the AI
# extraction prompt + schema text (Golden Rule 5 tripwire: editing the
# prompt without updating this test in the same commit goes red).
#
# ingest.rb resolves everything relative to its own directory (it owns
# the in-tree capstruct/ audit trail), so the run tests execute it from
# a sandbox copy of scripts/btco + lib with a synthetic universe. No
# ANTHROPIC_API_KEY, no network (heuristic mode; the shim serves EDGAR
# fixtures for discovery).

require_relative 'contract_helper'
require_relative '../../scripts/btco/ingest_text'
require 'tmpdir'
require 'fileutils'

class TestIngestContract < Minitest::Test
  PROPOSAL_KEYS   = %w[accession analysed_at diff extraction filing_date
                       form mode ticker url].freeze
  HEURISTIC_KEYS  = %w[btc confidence no_material_change shares_basic summary].freeze

  SANDBOX = File.join(Dir.tmpdir, "mimir-ingest-contract-#{Process.pid}")
  Minitest.after_run { FileUtils.rm_rf(SANDBOX) }

  UNIVERSE = {
    'companies' => [
      { 'name' => 'Test Co', 'ticker' => 'TST', 'ccy' => 'USD',
        'cik' => '1050446', # the recorded submissions fixture's CIK
        'btc' => 10_000, 'btc_as_of' => '2020-01-01', # old floor: fixture filings are all newer
        'shares_basic' => 1_000, 'shares_diluted' => 1_000,
        'debt_face' => 0, 'pref_liq' => 0, 'converts' => [],
        'placeholder' => true }
    ]
  }.freeze

  NO_AI = { 'ANTHROPIC_API_KEY' => nil }.freeze

  def sandbox_ingest
    unless Dir.exist?(SANDBOX)
      FileUtils.mkdir_p(File.join(SANDBOX, 'scripts'))
      FileUtils.cp_r(File.join(ROOT, 'scripts/btco'), File.join(SANDBOX, 'scripts/btco'))
      # SYMLINK lib/, never copy it: ingest.rb's require_relative must
      # resolve to the SAME realpath the fake-transport preload loaded.
      # A copy re-executes BTC::Http and resets the injected transport,
      # silently letting discovery reach the real SEC (M7-1 finding C).
      File.symlink(File.join(ROOT, 'lib'), File.join(SANDBOX, 'lib'))
      FileUtils.rm_rf(File.join(SANDBOX, 'scripts/btco/capstruct'))
      File.write(File.join(SANDBOX, 'scripts/btco/universe.json'),
                 JSON.generate(UNIVERSE))
    end
    File.join(SANDBOX, 'scripts/btco/ingest.rb')
  end

  # ---- proposal schema (heuristic --file ingestion) --------------------

  def test_manual_file_proposal_schema
    ingest = sandbox_ingest
    doc = File.join(SANDBOX, 'doc.txt')
    File.write(doc, 'The Company held 12,345 bitcoin as of June 30, 2026. ' \
                    'There were 123,456,789 shares of common stock issued and outstanding.')

    out, err, st = run_script(ingest, '--file', doc, '--ticker', 'TST', env: NO_AI)
    assert st.success?, "ingest --file exit #{st.exitstatus}: #{err}\n#{out}"

    pending = Dir.glob(File.join(SANDBOX, 'scripts/btco/capstruct/pending/*.json'))
    assert_equal 1, pending.size, "expected exactly one proposal, got #{pending}"
    pr = JSON.parse(File.read(pending.first))

    assert_contract_keys PROPOSAL_KEYS, pr, 'proposal'
    assert_equal 'TST', pr['ticker']
    assert_equal 'MANUAL', pr['form']
    assert_match(/\Amanual-[0-9a-f]{12}\z/, pr['accession']) # content-hash dedup key
    assert_equal 'heuristic', pr['mode'] # no ANTHROPIC_API_KEY in the test env
    assert_equal RECORDED_NOW, Time.iso8601(pr['analysed_at']).iso8601

    assert_contract_keys HEURISTIC_KEYS, pr['extraction'], 'extraction'
    assert_equal 'low', pr['extraction']['confidence']
    assert_equal false, pr['extraction']['no_material_change']

    assert_equal({ 'from' => 10_000, 'to' => 12_345 }, pr['diff']['btc'])
    assert_equal({ 'from' => 1_000, 'to' => 123_456_789 }, pr['diff']['shares_basic'])
    pr['diff'].each_value { |v| assert_equal %w[from to], v.keys.sort }
  end

  # ---- --dry discovery against the recorded EDGAR fixtures -------------

  def test_dry_discovery_lists_fixture_filings
    out, err, st = run_script(sandbox_ingest, '--dry', env: NO_AI)
    assert st.success?, "ingest --dry exit #{st.exitstatus}: #{err}"
    assert_match(/TST\s+\d+ new filing\(s\)/, out)
    assert_match(%r{https://www\.sec\.gov/Archives/edgar/data/}, out)
    # NEWEST first (2026-07-07 owner session: oldest-first + --limit made a
    # year-long catch-up apply stale data; absolute-number schema means the
    # latest filing supersedes older ones)
    dates = out.scan(/\b(\d{4}-\d{2}-\d{2})\b/).flatten
    assert_operator dates.size, :>=, 2, 'fixture should list several filings'
    assert_equal dates.sort.reverse, dates, 'discovery must analyse newest first'
    # --dry must not write state or proposals for the discovered filings
    refute File.exist?(File.join(SANDBOX, 'scripts/btco/capstruct/state.json'))
  end

  # ---- --dry --json alert surface (M7-2, additive contract) ------------

  DRY_JSON_KEYS = %w[filings new].freeze
  FILING_KEYS   = %w[accession date form ticker].freeze

  def test_dry_json_surface_one_line_field_sets_and_no_state
    out, err, st = run_script(sandbox_ingest, '--dry', '--json', env: NO_AI)
    assert st.success?, "ingest --dry --json exit #{st.exitstatus}: #{err}"

    # exactly ONE line of stdout, and it is the JSON document (no human lines).
    lines = out.strip.lines
    assert_equal 1, lines.size, "expected one JSON line, got:\n#{out}"
    doc = JSON.parse(lines.first)

    assert_contract_keys DRY_JSON_KEYS, doc, 'dry-json'
    assert_kind_of Integer, doc['new']
    assert_kind_of Array, doc['filings']
    assert_equal doc['new'], doc['filings'].size
    assert_operator doc['new'], :>, 0, 'the recorded submissions carry new filings'

    doc['filings'].each do |f|
      assert_contract_keys FILING_KEYS, f, 'filing'
      assert_match(/\A\d{10}-\d{2}-\d{6}\z/, f['accession']) # dashed EDGAR accession
    end
    # stable sort: ticker then date.
    assert_equal doc['filings'].sort_by { |f| [f['ticker'], f['date']] }, doc['filings']

    # --dry --json must persist NO state (load-bearing for the alert job).
    refute File.exist?(File.join(SANDBOX, 'scripts/btco/capstruct/state.json'))
  end

  # ---- excerpt pipeline on the recorded 8-K -----------------------------

  def test_excerpt_pipeline_on_fixture_filing
    text = Btco.strip_html(fixture('edgar_filing.html'))
    refute_match(/<[a-z]/i, text[0, 5_000]) # tags gone
    ex = Btco.excerpt(text)
    assert_operator ex.size, :>, 0
    assert_operator ex.size, :<=, 40_000 # the documented prompt cap
  end

  # ---- Golden Rule 5 tripwire: prompt + schema text pinned VERBATIM ----

  SCHEMA_SOURCE = <<~'SRC'
    SCHEMA_NOTE = <<~SCHEMA
      Respond with ONLY a JSON object (no markdown fences, no prose) with this
      exact schema. Use null for anything the document does not state. Numbers
      are absolute (not deltas), in units of coins / shares / USD face value.
      {"no_material_change": bool,
       "btc": number|null, "btc_as_of": "YYYY-MM-DD"|null,
       "shares_basic": number|null, "shares_diluted": number|null,
       "debt_face": number|null, "pref_liq": number|null,
       "converts_add": [{"face": n, "conv_price": n, "label": "str"}],
       "converts_remove": ["label"],
       "atm_note": "str"|null,
       "confidence": "high"|"medium"|"low",
       "summary": "1-2 sentences on what changed"}
    SCHEMA
  SRC

  PROMPT_FRAGMENTS = [
    'You are extracting capital-structure changes for a Bitcoin ',
    'treasury company from a filing.',
    'Report ONLY facts stated in the document; if it does not ',
    'change the capital structure or BTC holdings, set ',
    'no_material_change true.'
  ].freeze

  def test_extraction_prompt_and_schema_pinned_verbatim
    src = File.read(File.join(ROOT, 'scripts/btco/ingest.rb'))
    assert_includes src, SCHEMA_SOURCE,
                    'ingest.rb extraction SCHEMA_NOTE drifted (Golden Rule 5): ' \
                    'update this pin in the same commit as the prompt change'
    PROMPT_FRAGMENTS.each do |frag|
      assert_includes src, frag, "ingest.rb extraction prompt drifted at: #{frag.inspect}"
    end
  end

  # KEYRE and the excerpt window/cap shape what the model sees -- also
  # contract (see ingest_text.rb header).
  def test_excerpt_parameters_pinned
    src = File.read(File.join(ROOT, 'scripts/btco/ingest_text.rb'))
    assert_includes src, "NUMKEYS = %w[btc shares_basic shares_diluted debt_face pref_liq].freeze"
    assert_includes src, 'KEYRE = /bitcoin|\bbtc\b|shares? of (?:class [ab] )?common|issued and outstanding|'
    assert_includes src, 'def excerpt(text, cap = 40_000)'
    assert_includes src, 'spans << [[i - 1500, 0].max, [i + 1500, text.size].min]'
  end
end
