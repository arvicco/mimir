# frozen_string_literal: true
#
# M7-11: BTC::CoingeckoRef -- second independent BTC-holdings reference
# for --review (beside M7-9's bitcointreasuries). Same harness as
# test_btc_treasury_ref.rb: temp BTC_DATA_DIR + injected transport
# serving the trimmed CoinGecko fixture. Covers: bare-symbol hit on an
# exchange-qualified symbol, fractional-holdings rounding, name/alias
# hit, unknown -> nil, source-down cache fallback, dead-source nil.

require_relative '../test_helper'
require 'tmpdir'
require 'fileutils'
require 'time'
require_relative '../../lib/btc/coingecko_ref'

class TestBtcCoingeckoRef < Minitest::Test
  FakeRes = Struct.new(:code, :body)
  NOW     = Time.utc(2026, 7, 8, 4, 0, 0)
  FIXTURE = File.expand_path('../fixtures/coingecko_treasury.json', __dir__)
  BODY    = File.read(FIXTURE)

  def setup
    @dir = Dir.mktmpdir('mimir-coingecko-ref')
    @old = ENV['BTC_DATA_DIR']
    ENV['BTC_DATA_DIR'] = @dir
  end

  def teardown
    @old.nil? ? ENV.delete('BTC_DATA_DIR') : ENV['BTC_DATA_DIR'] = @old
    BTC::Http.transport = nil
    FileUtils.remove_entry(@dir)
  end

  def transport(body: BODY, fail_with: nil)
    BTC::Http.transport = lambda do |_uri, _req, _opts|
      raise fail_with if fail_with

      FakeRes.new('200', body)
    end
  end

  # ---- symbol matching --------------------------------------------------

  def test_bare_ticker_matches_exchange_qualified_symbol
    transport
    r = BTC::CoingeckoRef.btc_for('MSTR', now: NOW) # fixture symbol MSTR.US
    assert_equal 843_775, r['btc']
    assert_equal 'coingecko', r['source']
    assert_equal NOW.iso8601, r['as_of']
  end

  def test_numeric_ticker_matches_tokyo_symbol
    transport
    assert_equal 43_000, BTC::CoingeckoRef.btc_for('3350', now: NOW)['btc'] # 3350.T
  end

  def test_fractional_holdings_round_to_integer
    transport
    r = BTC::CoingeckoRef.btc_for('DJT', now: NOW) # fixture 9542.16
    assert_equal 9_542, r['btc']
    assert_kind_of Integer, r['btc']
  end

  def test_name_lookup_resolves_when_symbol_misses
    transport
    assert_equal 43_000, BTC::CoingeckoRef.btc_for('Metaplanet', now: NOW)['btc']
  end

  # ---- miss ---------------------------------------------------------------

  def test_unknown_company_returns_nil
    transport
    assert_nil BTC::CoingeckoRef.btc_for('ZZZZ', now: NOW)
  end

  def test_blank_query_returns_nil
    transport
    assert_nil BTC::CoingeckoRef.btc_for('', now: NOW)
    assert_nil BTC::CoingeckoRef.btc_for(nil, now: NOW)
  end

  # ---- source down: cache fallback ----------------------------------------

  def test_source_down_within_cap_serves_stale_cache
    transport
    BTC::CoingeckoRef.btc_for('MSTR', now: NOW) # seed cache

    transport(fail_with: BTC::Http::StatusError.new(503, 'down'))
    r = BTC::CoingeckoRef.btc_for('MSTR', now: NOW + 3600)
    assert_equal 843_775, r['btc'], 'served from last-good cache'
    assert_equal NOW.iso8601, r['as_of'], 'as_of reflects when cache was fetched'
  end

  def test_source_down_beyond_cap_returns_nil
    transport
    BTC::CoingeckoRef.btc_for('MSTR', now: NOW)
    transport(fail_with: RuntimeError.new('dns'))
    assert_nil BTC::CoingeckoRef.btc_for('MSTR', now: NOW + BTC::SourceCache::MAX_STALE_S + 1)
  end

  def test_source_down_with_no_cache_returns_nil
    transport(fail_with: RuntimeError.new('dns'))
    assert_nil BTC::CoingeckoRef.btc_for('MSTR', now: NOW)
  end

  # ---- reshaped upstream ---------------------------------------------------

  def test_document_without_companies_returns_nil
    transport(body: '{"reshaped": true}')
    assert_nil BTC::CoingeckoRef.btc_for('MSTR', now: NOW)
  end
end
