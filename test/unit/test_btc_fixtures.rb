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
    'kind=option'        => JSON.generate('result' =>
      (1..6).map { |i| { 'instrument_name' => "BTC-27MAR26-#{90 + i}000-C", 'open_interest' => 5.0 } } +
      (1..6).map { |i| { 'instrument_name' => "BTC-27MAR26-#{60 + i}000-P", 'open_interest' => 3.0 } } +
      (1..4).map { |i| { 'instrument_name' => "BTC-26JUN26-#{50 + i}000-C", 'open_interest' => 0.0 } }),
    'kind=future'        => JSON.generate('result' => (1..9).map { |i| { 'instrument_name' => "F#{i}" } }),
    'delayed_quotes'     => JSON.generate('data' => {
      'current_price' => 34.8, 'close' => 34.7, 'extra' => 'drop-me',
      'options' => (1..5).map { |i| { 'option' => "IBIT260327C0010#{i}000", 'iv' => 0.5, 'gamma' => 0.01, 'open_interest' => 9, 'theta' => -1 } } +
                   (1..5).map { |i| { 'option' => "IBIT260327P0009#{i}000", 'iv' => 0.5, 'gamma' => 0.01, 'open_interest' => 9, 'theta' => -1 } } +
                   [{ 'option' => 'IBIT260327C00200000', 'iv' => 0.5, 'gamma' => 0.01, 'open_interest' => 0 }] }),
    'metrics=PriceUSD'   => '{"data":[{"PriceUSD":"62000"}],"next_page_url":"x"}',
    'metrics=CapMVRVCur' => '{"data":[{"CapMVRVCur":"1.18","PriceUSD":"62000"}],"next_page_url":"x"}',
    'fundingRate'        => JSON.generate((1..21).map { { 'fundingRate' => '0.0001' } }),
    'premiumIndex'       => '{"lastFundingRate":"0.0001"}',
    'BTC-USD/ticker'     => '{"price":"62000.0"}',
    'hashrate/6m'        => JSON.generate('hashrates' => (1..200).map { |i| { 'avgHashrate' => i } },
                                          'difficulty' => (1..9).map { |i| { 'difficulty' => i } }),
    'stablecoins'        => JSON.generate('peggedAssets' => [
      { 'symbol' => 'USDT', 'circulating' => { 'peggedUSD' => 1 }, 'circulatingPrevWeek' => {}, 'circulatingPrevMonth' => {}, 'chains' => %w[big list] },
      { 'symbol' => 'DAI',  'circulating' => { 'peggedUSD' => 1 } },
      { 'symbol' => 'USDC', 'circulating' => { 'peggedUSD' => 1 }, 'circulatingPrevWeek' => {}, 'circulatingPrevMonth' => {} }]),
    'farside'            => ('<tr><td>x</td></tr>' * 400) +
                            (1..14).map { |i| "<tr><td>#{i} Jun 2026</td><td>1.0</td></tr>" }.join +
                            ('<p>tail</p>' * 5_000),
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
    old_fred = ENV['FRED_API_KEY']
    ENV['FRED_API_KEY'] = 'testkey123'
    record do |dir, results|
      assert results.all? { |_, s, _| s == :ok }, results.inspect
      assert_equal BTC::Fixtures::FIXTURES.size,
                   Dir.glob(File.join(dir, '*.{json,html}')).size
    end
  ensure
    old_fred.nil? ? ENV.delete('FRED_API_KEY') : ENV['FRED_API_KEY'] = old_fred
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
      assert_equal 10, book.size # 4 calls + 4 puts + 2 zero-OI

      cboe = JSON.parse(File.read(File.join(dir, 'cboe_options.json')))['data']
      assert_equal 9, cboe['options'].size
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
      rows = html.gsub(/<[^>]+>/, ' ').scan(/\d{1,2}\s+[A-Z][a-z]{2}\s+\d{4}/).size
      assert_operator rows, :>=, 12
      assert_operator html.size, :<, CANNED['farside'].size # actually trimmed

      filing = File.read(File.join(dir, 'edgar_filing.html'))
      assert_equal 60_000, filing.size
      assert filing.start_with?('FILING BODY')
    end
  end

  def test_readme_provenance_written
    record do |dir, _|
      readme = File.read(File.join(dir, 'README.md'))
      assert_includes readme, 'deribit_book_summary.json'
      assert_includes readme, 'rake fixtures:record'
    end
  end
end
