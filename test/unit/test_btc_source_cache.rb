# frozen_string_literal: true

# M7-8: BTC::SourceCache -- read-through last-good cache over BTC::Http.
# The seam that lets one dead provider degrade to STALE (combined with
# fresh siblings) instead of blanking a card, with a hard age cap past
# which it re-raises so the caller fail-softs. All offline: a temp
# BTC_DATA_DIR + an injected transport; the real data/source_cache is
# never touched.

require_relative '../test_helper'
require 'tmpdir'
require 'fileutils'
require 'time'
require_relative '../../lib/btc/source_cache'

class TestBtcSourceCache < Minitest::Test
  FakeRes = Struct.new(:code, :body)
  NOW  = Time.utc(2026, 7, 7, 12, 0, 0)
  BODY = '{"result":{"index_price":62158.27}}'

  def setup
    @dir = Dir.mktmpdir('mimir-source-cache')
    @old = ENV['BTC_DATA_DIR']
    ENV['BTC_DATA_DIR'] = @dir
  end

  def teardown
    @old.nil? ? ENV.delete('BTC_DATA_DIR') : ENV['BTC_DATA_DIR'] = @old
    BTC::Http.transport = nil
    FileUtils.remove_entry(@dir)
  end

  # transport that serves `body` for the first `ok` calls then fails.
  def transport(body: BODY, fail_with: nil)
    calls = []
    BTC::Http.transport = lambda do |uri, req, opts|
      calls << { uri: uri, opts: opts }
      raise fail_with if fail_with

      FakeRes.new('200', body)
    end
    calls
  end

  def cache_file(name)
    File.join(@dir, 'source_cache', "#{name}.json")
  end

  # ---- fresh path -----------------------------------------------------

  def test_fresh_fetch_returns_data_not_stale_and_writes_cache
    transport
    r = BTC::SourceCache.fetch_json('deribit_index', 'https://x/y', now: NOW)
    assert_equal 62_158.27, r['data']['result']['index_price']
    assert_equal false, r['stale']
    assert_equal NOW.iso8601, r['as_of']

    assert File.exist?(cache_file('deribit_index')), 'cache written'
    disk = JSON.parse(File.read(cache_file('deribit_index')))
    assert_equal NOW.iso8601, disk['fetched_at']
    assert_equal 'https://x/y', disk['url']
    assert_equal JSON.parse(BODY), disk['data']
  end

  def test_passes_headers_and_read_timeout_to_transport
    calls = transport
    BTC::SourceCache.fetch_json('n', 'https://x/y', { 'User-Agent' => 'ua' },
                                read_timeout: 30, now: NOW)
    assert_equal 30, calls.first[:opts][:read_timeout]
  end

  # ---- failure serves cache (within cap) ------------------------------

  def test_failure_serves_cache_with_stale_true_and_original_as_of
    transport
    BTC::SourceCache.fetch_json('deribit_index', 'https://x/y', now: NOW) # seed

    transport(fail_with: BTC::Http::StatusError.new(503, 'down'))
    later = NOW + 3600
    r = BTC::SourceCache.fetch_json('deribit_index', 'https://x/y', now: later)
    assert_equal true, r['stale']
    assert_equal 62_158.27, r['data']['result']['index_price']
    assert_equal NOW.iso8601, r['as_of'], 'as_of is when the cached data was fetched'
  end

  def test_failure_within_cap_at_the_boundary_serves_cache
    transport
    BTC::SourceCache.fetch_json('n', 'https://x/y', now: NOW)
    transport(fail_with: RuntimeError.new('boom'))
    edge = NOW + BTC::SourceCache::MAX_STALE_S # exactly at the cap
    r = BTC::SourceCache.fetch_json('n', 'https://x/y', now: edge)
    assert_equal true, r['stale']
  end

  # ---- failure beyond cap / no cache re-raises ------------------------

  def test_failure_beyond_cap_reraises_original_error
    transport
    BTC::SourceCache.fetch_json('n', 'https://x/y', now: NOW)
    transport(fail_with: (boom = BTC::Http::StatusError.new(503, 'down')))
    beyond = NOW + BTC::SourceCache::MAX_STALE_S + 1
    err = assert_raises(BTC::Http::StatusError) do
      BTC::SourceCache.fetch_json('n', 'https://x/y', now: beyond)
    end
    assert_same boom, err
    assert_equal 503, err.code
  end

  def test_failure_with_no_cache_reraises_original_error
    transport(fail_with: (boom = RuntimeError.new('dns')))
    err = assert_raises(RuntimeError) do
      BTC::SourceCache.fetch_json('never_seen', 'https://x/y', now: NOW)
    end
    assert_same boom, err
  end

  # ---- corrupt cache treated as absent --------------------------------

  def test_corrupt_cache_file_treated_as_absent
    FileUtils.mkdir_p(File.dirname(cache_file('n')))
    File.write(cache_file('n'), '{not json')
    transport(fail_with: (boom = RuntimeError.new('boom')))
    assert_raises(RuntimeError) do
      BTC::SourceCache.fetch_json('n', 'https://x/y', now: NOW)
    end
  end

  def test_cache_missing_fetched_at_treated_as_absent
    FileUtils.mkdir_p(File.dirname(cache_file('n')))
    File.write(cache_file('n'), JSON.generate('url' => 'u', 'data' => { 'a' => 1 }))
    transport(fail_with: RuntimeError.new('boom'))
    assert_raises(RuntimeError) { BTC::SourceCache.fetch_json('n', 'https://x/y', now: NOW) }
  end

  # ---- atomicity + naming ---------------------------------------------

  def test_atomic_write_leaves_no_tmp_files
    transport
    BTC::SourceCache.fetch_json('n', 'https://x/y', now: NOW)
    turds = Dir.glob(File.join(@dir, 'source_cache', '*.tmp*'))
    assert_empty turds, 'atomic write must not leave temp files'
  end

  def test_written_cache_is_always_complete_and_parseable
    # atomicity: a rename-published file is never half-written -- a fresh
    # write over an existing cache yields a fully valid document, and the
    # rewrite is visible in full (no partial/truncated intermediate).
    transport(body: '{"result":{"index_price":1.0}}')
    BTC::SourceCache.fetch_json('n', 'https://x/y', now: NOW)
    transport(body: BODY)
    BTC::SourceCache.fetch_json('n', 'https://x/y', now: NOW + 1)
    disk = JSON.parse(File.read(cache_file('n'))) # raises if truncated
    assert_equal 62_158.27, disk['data']['result']['index_price']
  end

  def test_sanitizes_name_into_a_safe_basename
    transport
    BTC::SourceCache.fetch_json('cboe/../evil name', 'https://x/y', now: NOW)
    # slashes/spaces fold to _ -> a single file in the cache dir, no escape
    files = Dir.glob(File.join(@dir, 'source_cache', '*.json')).map { |f| File.basename(f) }
    assert_equal ['cboe_evil_name.json'], files
  end

  def test_dir_honours_btc_data_dir_seam
    assert_equal File.join(@dir, 'source_cache'), BTC::SourceCache.dir
  end
end
