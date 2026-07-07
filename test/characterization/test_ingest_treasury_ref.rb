# frozen_string_literal: true
#
# M7-9: --review renders the independent third-party BTC-holdings sanity
# line (BTC::TreasuryRef). Sandbox harness like test_ingest_flow's -- the
# REAL ingest.rb runs from a per-test tmpdir copy of scripts/btco with a
# synthetic universe, driven as a subprocess with BTC::Http's transport
# replaced by the fixture-backed fake (RUBYOPT). The bitcointreasuries.net
# table is served from the trimmed fixture; BTC_DATA_DIR points at the
# sandbox so BTC::SourceCache writes there, never the real data/. lib/ is
# SYMLINKED (not copied) so the fake transport is not defeated -- see the
# test_ingest_flow header for why.
#
# Covers: proposal-matches line, divergence line + the 2% threshold
# boundary, and the two SILENT cases (unknown company; proposal with no
# btc figure) -- the reference must never block or clutter review.

require_relative '../test_helper'
require 'open3'
require 'tmpdir'
require 'fileutils'

class TestIngestTreasuryRef < Minitest::Test
  ROOT      = File.expand_path('../..', __dir__)
  SUPPORT   = File.join(ROOT, 'test', 'support')
  REAL_BTCO = File.join(ROOT, 'scripts', 'btco')
  FROZEN_NOW = '2026-07-07T00:00:00Z'
  AS_OF      = '2026-07-07' # fetched-through-fake -> cached at FROZEN_NOW

  # NAKA is in BOTH the synthetic universe AND the fixture (Nakamoto,
  # btc_balance 4467). TST is in the universe but NOT the fixture (silent).
  def synthetic_universe
    { 'companies' => [
      { 'name' => 'Naka', 'ticker' => 'NAKA', 'ccy' => 'USD', 'cik' => nil,
        'btc' => 500, 'btc_as_of' => '2020-01-01', 'shares_basic' => 100,
        'shares_diluted' => 100, 'debt_face' => 0, 'pref_liq' => 0,
        'converts' => [], 'placeholder' => true },
      { 'name' => 'Test Co', 'ticker' => 'TST', 'ccy' => 'USD', 'cik' => nil,
        'btc' => 100, 'btc_as_of' => '2020-01-01', 'shares_basic' => 1_000,
        'shares_diluted' => 1_000, 'debt_face' => 0, 'pref_liq' => 0,
        'converts' => [], 'placeholder' => true }
    ] }
  end

  def setup
    @sandbox = Dir.mktmpdir('mimir-ingest-tref-')
    @btco    = File.join(@sandbox, 'scripts', 'btco')
    FileUtils.mkdir_p(File.join(@sandbox, 'scripts'))
    FileUtils.cp_r(REAL_BTCO, @btco)
    FileUtils.rm_rf(File.join(@btco, 'capstruct'))
    File.symlink(File.join(ROOT, 'lib'), File.join(@sandbox, 'lib'))
    File.write(File.join(@btco, 'universe.json'), JSON.pretty_generate(synthetic_universe))
    @ingest  = File.join(@btco, 'ingest.rb')
    @btcdata = File.join(@sandbox, 'btcdata')
  end

  def teardown
    FileUtils.remove_entry(@sandbox) if @sandbox && Dir.exist?(@sandbox)
  end

  def cap(*parts)
    File.join(@btco, 'capstruct', *parts)
  end

  def write_proposal(name, ticker:, diff:, extraction: { 'confidence' => 'low', 'summary' => 's' })
    FileUtils.mkdir_p(cap('pending'))
    File.write(cap('pending', name), JSON.pretty_generate(
                 'ticker' => ticker, 'accession' => "acc-#{name}", 'form' => 'MANUAL',
                 'filing_date' => '2026-07-01', 'url' => 'u', 'mode' => 'ai',
                 'analysed_at' => FROZEN_NOW, 'extraction' => extraction, 'diff' => diff
               ))
  end

  def review
    env = { 'RUBYOPT'      => "-I#{SUPPORT} -rfake_transport",
            'FAKE_NOW'     => FROZEN_NOW,
            'BTC_DATA_DIR' => @btcdata,
            'http_proxy'   => 'http://127.0.0.1:9',
            'https_proxy'  => 'http://127.0.0.1:9' }
    out, err, st = Open3.capture3(env, RbConfig.ruby, @ingest, '--review', chdir: @btco)
    assert st.success?, "review exit #{st.exitstatus}: #{err}\n#{out}"
    out
  end

  # ---- match / divergence rendering -----------------------------------

  def test_ref_line_proposal_matches
    write_proposal('NAKA_match.json', ticker: 'NAKA',
                                      diff: { 'btc' => { 'from' => 500, 'to' => 4_467 } })
    out = review
    assert_includes out,
                    "ref:     4,467 BTC (bitcointreasuries.net, as-of #{AS_OF}) -- proposal matches"
  end

  def test_ref_line_divergence
    write_proposal('NAKA_diverge.json', ticker: 'NAKA',
                                        diff: { 'btc' => { 'from' => 500, 'to' => 5_000 } })
    out = review
    # 5000 vs 4467 -> 11.9%
    assert_match(/ref:\s+4,467 BTC \(bitcointreasuries\.net, as-of #{AS_OF}\) -- ⚠ proposal diverges 11\.9%/,
                 out)
  end

  def test_divergence_threshold_boundary
    # ref 4467; 2% band is +-89.34. 4550 -> 1.86% (matches); 4557 -> 2.01%
    # (just over -> diverges). Pins the strict `> 0.02` boundary.
    write_proposal('NAKA_under.json', ticker: 'NAKA',
                                      diff: { 'btc' => { 'from' => 500, 'to' => 4_550 } })
    write_proposal('NAKA_over.json', ticker: 'NAKA',
                                     diff: { 'btc' => { 'from' => 500, 'to' => 4_557 } })
    out = review
    # pending files sort by name: NAKA_over.json block prints before
    # NAKA_under.json. Split on the under header to isolate each block.
    over_part, under_part = out.split('NAKA_under.json', 2)
    assert under_part, 'under-band proposal listed'
    assert_match(/⚠ proposal diverges 2\.0%/, over_part)  # just over -> diverges
    assert_match(/proposal matches/, under_part)          # just under -> matches
    refute_match(/diverges/, under_part)
  end

  def test_ref_line_via_extraction_btc_when_diff_has_no_btc
    write_proposal('NAKA_ext.json', ticker: 'NAKA',
                                    diff: { 'shares_basic' => { 'from' => 100, 'to' => 200 } },
                                    extraction: { 'confidence' => 'high', 'summary' => 's',
                                                  'btc' => 4_467 })
    out = review
    assert_includes out, 'proposal matches'
  end

  # ---- silent cases ---------------------------------------------------

  def test_no_ref_line_for_unknown_company
    write_proposal('TST_x.json', ticker: 'TST',
                                 diff: { 'btc' => { 'from' => 100, 'to' => 999 } })
    out = review
    refute_includes out, 'ref:'
    refute_includes out, 'bitcointreasuries'
  end

  def test_no_ref_line_when_proposal_carries_no_btc
    write_proposal('NAKA_noref.json', ticker: 'NAKA',
                                      diff: { 'shares_basic' => { 'from' => 100, 'to' => 200 } })
    out = review
    assert_includes out, 'NAKA_noref.json' # proposal still shown
    refute_includes out, 'ref:'            # but no reference line
  end
end
