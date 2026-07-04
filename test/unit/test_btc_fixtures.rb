# frozen_string_literal: true

# M1-6: the fixture recorder against an injected fake transport --
# layout, trims, provenance and redaction verified without any network.

require_relative '../test_helper'
require_relative '../../lib/btc/fixtures'
require 'tmpdir'

class TestBtcFixtures < Minitest::Test
  FakeRes = Struct.new(:code, :body)

  def teardown
    BTC::Http.transport = nil
  end

  # Canned bodies keyed by a distinctive URL fragment.
  CANNED = {
    'get_index_price'    => '{"result":{"index_price":62000.0}}',
    # far-future canned expiries (2036/37) so the unit test itself does
    # not age; the expired 2020 row pins the F-20 exclusion.
    'kind=option'        => JSON.generate('result' =>
      (1..6).map { |i| { 'instrument_name' => "BTC-26DEC36-#{90 + i}000-C", 'open_interest' => 5.0, 'mark_iv' => 55.0 } } +
      (1..6).map { |i| { 'instrument_name' => "BTC-25SEP37-#{60 + i}000-P", 'open_interest' => 3.0, 'mark_iv' => 60.0 } } +
      [{ 'instrument_name' => 'BTC-27MAR20-50000-C', 'open_interest' => 9.0, 'mark_iv' => 40.0 }] +
      (1..3).map { |i| { 'instrument_name' => "BTC-26JUN37-#{50 + i}000-C", 'open_interest' => 0.0 } }),
    'kind=future'        => JSON.generate('result' => (1..9).map { |i| { 'instrument_name' => "F#{i}" } }),
    'delayed_quotes'     => JSON.generate('data' => {
      'current_price' => 34.8, 'close' => 34.7, 'extra' => 'drop-me',
      'options' => (1..5).map { |i| { 'option' => "IBIT361218C0010#{i}000", 'iv' => 0.5, 'gamma' => 0.01, 'open_interest' => 9, 'theta' => -1 } } +
                   (1..5).map { |i| { 'option' => "IBIT361218P0009#{i}000", 'iv' => 0.5, 'gamma' => 0.01, 'open_interest' => 9, 'theta' => -1 } } +
                   # the two F-20 dead shapes: expired-with-OI, zero-OI
                   [{ 'option' => 'IBIT260702C00020000', 'iv' => 0.0, 'gamma' => 0.0, 'open_interest' => 71 },
                    { 'option' => 'IBIT361218C00200000', 'iv' => 0.5, 'gamma' => 0.01, 'open_interest' => 0 }] }),
    'metrics=PriceUSD'   => '{"data":[{"PriceUSD":"62000"}],"next_page_url":"x"}',
    'metrics=CapMVRVCur' => '{"data":[{"CapMVRVCur":"1.18","PriceUSD":"62000"}],"next_page_url":"x"}',
    'fundingRate'        => JSON.generate((1..21).map { { 'fundingRate' => '0.0001' } }),
    'premiumIndex'       => '{"lastFundingRate":"0.0001"}',
    'ticker/price'       => '{"symbol":"BTCUSDT","price":"62000.00"}',
    'BTC-USD/ticker'     => '{"price":"62000.0"}',
    'hashrate/6m'        => JSON.generate('hashrates' => (1..200).map { |i| { 'avgHashrate' => i } },
                                          'difficulty' => (1..9).map { |i| { 'difficulty' => i } }),
    'stablecoins'        => JSON.generate('peggedAssets' => [
      { 'symbol' => 'USDT', 'circulating' => { 'peggedUSD' => 1 }, 'circulatingPrevWeek' => {}, 'circulatingPrevMonth' => {}, 'chains' => %w[big list] },
      { 'symbol' => 'DAI',  'circulating' => { 'peggedUSD' => 1 } },
      { 'symbol' => 'USDC', 'circulating' => { 'peggedUSD' => 1 }, 'circulatingPrevWeek' => {}, 'circulatingPrevMonth' => {} }]),
    # 28 <tr> data rows; the per-row parser (F-22 fix) yields all 28.
    'farside'            => ('<tr><td>x</td></tr>' * 400) +
                            (1..28).map { |i| "<tr><td>#{i} Jun 2026</td><td>1.0</td><td>2.5</td></tr>" }.join +
                            ('<p>tail</p>' * 5_000),
    'flow-history'       => JSON.generate('code' => '0', 'msg' => 'success',
                                          'data' => (1..40).map { |i| { 'timestamp' => 1_700_000_000_000 + i * 86_400_000, 'flow_usd' => i * 1e6, 'price_usd' => 60_000, 'etf_flows' => [{ 'etf_ticker' => 'IBIT', 'flow_usd' => 1 }] } }),
    'frankfurter'        => '{"rates":{"JPY":161.15}}',
    'stlouisfed'         => JSON.generate('observations' => (1..30).map { |i| { 'value' => i.to_s } }),
    'submissions/CIK'    => JSON.generate('cik' => '1050446', 'name' => 'Strategy',
                                          'filings' => { 'recent' => {
                                            'form' => ['10-Q', '8-K'] + ['4'] * 30,
                                            'accessionNumber' => ['0001-05-001', '0001-05-002'] + ['x'] * 30,
                                            'primaryDocument' => ['q.htm', 'k.htm'] + ['x'] * 30,
                                            'filingDate' => ['2026-07-01', '2026-06-15'] + ['x'] * 30 } }),
    'Archives/edgar'     => 'FILING BODY ' + ('z' * 100_000)
  }.freeze

  def inject
    BTC::Http.transport = lambda do |uri, req, _opts|
      frag = CANNED.keys.find { |k| (uri.to_s + req.path).include?(k) }
      raise "no canned body for #{uri}" unless frag

      FakeRes.new('200', CANNED[frag])
    end
  end

  def record
    inject
    Dir.mktmpdir do |dir|
      results = BTC::Fixtures.record_all(dir)
      yield dir, results
    end
  end

  def test_all_fixtures_written_with_env_present
    old = ENV.to_hash.slice('FRED_API_KEY', 'COINGLASS_API_KEY')
    ENV['FRED_API_KEY'] = 'testkey123'
    ENV['COINGLASS_API_KEY'] = 'cgkey456'
    record do |dir, results|
      assert results.all? { |_, s, _| s == :ok }, results.inspect
      assert_equal BTC::Fixtures::FIXTURES.size,
                   Dir.glob(File.join(dir, '*.{json,html}')).size
    end
  ensure
    %w[FRED_API_KEY COINGLASS_API_KEY].each do |k|
      old.key?(k) ? ENV[k] = old[k] : ENV.delete(k)
    end
  end

  def test_fred_skipped_without_key_and_url_redacted_with_it
    old = ENV.delete('FRED_API_KEY')
    record do |_, results|
      assert(results.count { |_, s, _| s == :skip } >= 4)
    end
    ENV['FRED_API_KEY'] = 'sekret99'
    record do |dir, results|
      walcl = results.find { |f, _, _| f == 'fred_walcl.json' }
      refute_includes walcl[2], 'sekret99'
      assert_includes walcl[2], 'api_key=[REDACTED]'
      refute_includes File.read(File.join(dir, 'README.md')), 'sekret99'
    end
  ensure
    old.nil? ? ENV.delete('FRED_API_KEY') : ENV['FRED_API_KEY'] = old
  end

  def test_trims_book_cboe_stables_and_submissions
    record do |dir, _|
      book = JSON.parse(File.read(File.join(dir, 'deribit_book_summary.json')))['result']
      assert_equal 10, book.size # 4 live calls + 4 live puts + 2 dead
      names = book.map { |r| r['instrument_name'] }
      assert_equal 4, names.count { |n| n.include?('DEC36') && n.end_with?('-C') }
      assert_equal 4, names.count { |n| n.include?('SEP37') && n.end_with?('-P') }
      # F-20: expired-with-OI row lands in the dead tail, never the live picks
      assert_includes names.last(2), 'BTC-27MAR20-50000-C'
      refute_includes names.first(8), 'BTC-27MAR20-50000-C'

      cboe = JSON.parse(File.read(File.join(dir, 'cboe_options.json')))['data']
      assert_equal 10, cboe['options'].size # 4 live calls + 4 live puts + 2 dead
      codes = cboe['options'].map { |o| o['option'] }
      assert(codes.first(8).all? { |c| c.include?('3612') }) # far-dated live only
      assert_includes codes.last(2), 'IBIT260702C00020000' # expired weekly = dead
      refute cboe.key?('extra')
      refute cboe['options'].first.key?('theta') # slimmed to parser fields

      stables = JSON.parse(File.read(File.join(dir, 'defillama_stables.json')))['peggedAssets']
      assert_equal %w[USDT USDC], stables.map { |a| a['symbol'] }
      refute stables.first.key?('chains')

      sub = JSON.parse(File.read(File.join(dir, 'edgar_submissions.json')))
      recent = sub['filings']['recent']
      assert recent.values.all? { |v| !v.is_a?(Array) || v.size == 15 } # consistent slice
    end
  end

  def test_mempool_and_farside_and_filing_trims
    record do |dir, _|
      mem = JSON.parse(File.read(File.join(dir, 'mempool_hashrate.json')))
      assert_equal 80, mem['hashrates'].size
      assert_equal 3, mem['difficulty'].size

      html = File.read(File.join(dir, 'farside_flows.html'))
      # F-22: the trim counts rows the per-row parser yields
      assert_operator BTC::Flows.parse_flows(html).size, :>=, 12
      assert_operator html.size, :<, CANNED['farside'].size # actually trimmed

      filing = File.read(File.join(dir, 'edgar_filing.html'))
      assert_equal 60_000, filing.size
      assert filing.start_with?('FILING BODY')
    end
  end

  def test_coinglass_trim_keeps_30_slim_rows
    old = ENV['COINGLASS_API_KEY']
    ENV['COINGLASS_API_KEY'] = 'cgkey456'
    record do |dir, results|
      row = results.find { |f, _, _| f == 'coinglass_flows.json' }
      assert_equal :ok, row[1]
      j = JSON.parse(File.read(File.join(dir, 'coinglass_flows.json')))
      assert_equal 30, j['data'].size
      refute j['data'].first.key?('etf_flows') # slimmed to module fields
      assert_equal %w[flow_usd price_usd timestamp], j['data'].first.keys.sort
    end
  ensure
    old.nil? ? ENV.delete('COINGLASS_API_KEY') : ENV['COINGLASS_API_KEY'] = old
  end

  # F-23 guardrail: a Cloudflare challenge page parses to zero rows and
  # must fail the recording, never record silently.
  def test_farside_trim_raises_on_challenge_page
    trim = BTC::Fixtures::FARSIDE_TRIM
    err = assert_raises(RuntimeError) { trim.call('<html><body>Just a moment...</body></html>') }
    assert_match(/parseable farside rows/, err.message)
  end

  # F-20 guardrail: a board with zero parser-live rows must raise (surfacing
  # as FAIL in rake fixtures:record), never record a dead fixture silently.
  def test_trim_raises_on_parser_dead_board
    dead = JSON.generate('data' => { 'current_price' => 1.0, 'close' => 1.0,
                                     'options' => [{ 'option' => 'IBIT200101C00010000', 'iv' => 0.0,
                                                     'gamma' => 0.0, 'open_interest' => 5 }] })
    trim = BTC::Fixtures::FIXTURES.find { |f| f[:file] == 'cboe_options.json' }[:trim]
    err = assert_raises(RuntimeError) { trim.call(dead) }
    assert_match(/parser-live/, err.message)
  end

  def test_readme_provenance_written
    record do |dir, _|
      readme = File.read(File.join(dir, 'README.md'))
      assert_includes readme, 'deribit_book_summary.json'
      assert_includes readme, 'rake fixtures:record'
    end
  end
end
