# frozen_string_literal: true
#
# M7-9: BTC::TreasuryRef -- independent third-party BTC-holdings reference
# used to sanity-check ingest proposals at --review time. All offline: a
# temp BTC_DATA_DIR (so SourceCache never touches the real data/) + an
# injected BTC::Http transport serving the trimmed bitcointreasuries.net
# fixture. Covers: exact-ticker hit, alias-by-name hit, unknown -> nil,
# source-down-with-cache -> stale hit, source-down-no-cache -> nil.

require_relative '../test_helper'
require 'tmpdir'
require 'fileutils'
require 'time'
require_relative '../../lib/btc/treasury_ref'

class TestBtcTreasuryRef < Minitest::Test
  FakeRes = Struct.new(:code, :body)
  NOW     = Time.utc(2026, 7, 7, 12, 0, 0)
  FIXTURE = File.expand_path('../fixtures/bitcointreasuries_table.html', __dir__)
  TABLE   = File.read(FIXTURE)

  def setup
    @dir = Dir.mktmpdir('mimir-treasury-ref')
    @old = ENV['BTC_DATA_DIR']
    ENV['BTC_DATA_DIR'] = @dir
  end

  def teardown
    @old.nil? ? ENV.delete('BTC_DATA_DIR') : ENV['BTC_DATA_DIR'] = @old
    BTC::Http.transport = nil
    FileUtils.remove_entry(@dir)
  end

  # transport serving the fixture (200), or failing when fail_with is set.
  def transport(body: TABLE, fail_with: nil)
    BTC::Http.transport = lambda do |_uri, _req, _opts|
      raise fail_with if fail_with

      FakeRes.new('200', body)
    end
  end

  # ---- parse ----------------------------------------------------------

  def test_parse_table_extracts_rows_with_integer_btc
    rows = BTC::TreasuryRef.parse_table(TABLE)
    assert_equal 9, rows.size
    mstr = rows.find { |r| r['ticker'] == 'MSTR' }
    assert_equal 843_775, mstr['btc']
    assert_kind_of Integer, mstr['btc']
    assert_equal 'Strategy', mstr['name']
  end

  def test_parse_table_never_raises_on_junk
    assert_equal [], BTC::TreasuryRef.parse_table('<html>no data here</html>')
    assert_equal [], BTC::TreasuryRef.parse_table(nil)
  end

  # ---- exact-ticker hit -----------------------------------------------

  def test_btc_for_exact_ticker_hit
    transport
    r = BTC::TreasuryRef.btc_for('MSTR', now: NOW)
    assert_equal 843_775, r['btc']
    assert_equal 'bitcointreasuries.net', r['source']
    assert_equal NOW.iso8601, r['as_of']
  end

  def test_btc_for_is_case_insensitive_on_ticker
    transport
    assert_equal 24_300, BTC::TreasuryRef.btc_for('blsh', now: NOW)['btc']
  end

  # ---- alias-by-name hit ----------------------------------------------

  def test_btc_for_alias_maps_universe_ticker_to_aggregator_name
    transport
    # universe 3350 has no ticker symbol '3350' on the aggregator (symbol
    # MPJPY); the alias map resolves it by name "Metaplanet".
    r = BTC::TreasuryRef.btc_for('3350', now: NOW)
    assert_equal 43_000, r['btc']
  end

  def test_btc_for_bare_name_also_resolves
    transport
    assert_equal 4_467, BTC::TreasuryRef.btc_for('Nakamoto', now: NOW)['btc']
  end

  # ---- miss -----------------------------------------------------------

  def test_btc_for_unknown_company_returns_nil
    transport
    assert_nil BTC::TreasuryRef.btc_for('ZZZZ', now: NOW)
  end

  def test_btc_for_blank_query_returns_nil
    transport
    assert_nil BTC::TreasuryRef.btc_for('', now: NOW)
    assert_nil BTC::TreasuryRef.btc_for(nil, now: NOW)
  end

  # ---- source down: cache fallback ------------------------------------

  def test_source_down_within_cap_serves_stale_cache
    transport # seed the cache with a live fetch
    BTC::TreasuryRef.btc_for('MSTR', now: NOW)

    transport(fail_with: BTC::Http::StatusError.new(503, 'down'))
    later = NOW + 3600
    r = BTC::TreasuryRef.btc_for('MSTR', now: later)
    assert_equal 843_775, r['btc'], 'served from last-good cache'
    assert_equal NOW.iso8601, r['as_of'], 'as_of reflects when cache was fetched'
  end

  def test_source_down_beyond_cap_returns_nil
    transport
    BTC::TreasuryRef.btc_for('MSTR', now: NOW)
    transport(fail_with: RuntimeError.new('dns'))
    beyond = NOW + BTC::SourceCache::MAX_STALE_S + 1
    assert_nil BTC::TreasuryRef.btc_for('MSTR', now: beyond)
  end

  def test_source_down_with_no_cache_returns_nil
    transport(fail_with: RuntimeError.new('dns'))
    assert_nil BTC::TreasuryRef.btc_for('MSTR', now: NOW)
  end

  # ---- empty/garbage upstream is not cached ---------------------------

  def test_empty_parse_is_treated_as_failure_not_cached
    transport(body: '<html>reshaped, no entities</html>')
    assert_nil BTC::TreasuryRef.btc_for('MSTR', now: NOW)
    refute File.exist?(File.join(@dir, 'source_cache', 'treasury_ref.json')),
           'an unparseable page must not overwrite/create the cache'
  end
end
