# frozen_string_literal: true
#
# M7-12: BTC::SecShares -- structured cover-page share counts from the SEC
# XBRL companyconcept API (dei:EntityCommonStockSharesOutstanding). Same
# offline harness as the other ref tests: temp BTC_DATA_DIR + injected
# transport serving the trimmed DJT fixture. Covers: latest-fact
# selection with date/form provenance, the multi-class 404 -> nil path
# (the MSTR/ASST limitation, docs/BTCO-DATA-SOURCES.md), bad cik -> nil,
# and the cache fallback.

require_relative '../test_helper'
require 'tmpdir'
require 'fileutils'
require 'time'
require_relative '../../lib/btc/sec_shares'

class TestBtcSecShares < Minitest::Test
  FakeRes = Struct.new(:code, :body)
  NOW     = Time.utc(2026, 7, 8, 4, 0, 0)
  FIXTURE = File.expand_path('../fixtures/sec_dei_shares.json', __dir__)
  BODY    = File.read(FIXTURE)
  CIK     = 1_849_635 # DJT, the recorded fixture's filer

  def setup
    @dir = Dir.mktmpdir('mimir-sec-shares')
    @old = ENV['BTC_DATA_DIR']
    ENV['BTC_DATA_DIR'] = @dir
  end

  def teardown
    @old.nil? ? ENV.delete('BTC_DATA_DIR') : ENV['BTC_DATA_DIR'] = @old
    BTC::Http.transport = nil
    FileUtils.remove_entry(@dir)
  end

  def transport(body: BODY, fail_with: nil)
    requested = []
    BTC::Http.transport = lambda do |uri, _req, _opts|
      requested << uri.to_s
      raise fail_with if fail_with

      FakeRes.new('200', body)
    end
    requested
  end

  # ---- latest fact ------------------------------------------------------

  def test_latest_cover_count_with_date_and_form
    transport
    r = BTC::SecShares.outstanding_for(CIK, now: NOW)
    assert_equal 276_953_828, r['shares']
    assert_equal '2026-05-06', r['as_of'], 'newest end date wins'
    assert_equal '10-Q', r['form']
    assert_equal 'sec-xbrl dei', r['source']
    assert_equal false, r['stale']
  end

  def test_url_is_zero_padded_dei_companyconcept
    reqs = transport
    BTC::SecShares.outstanding_for(CIK, now: NOW)
    assert_equal ['https://data.sec.gov/api/xbrl/companyconcept/CIK0001849635' \
                  '/dei/EntityCommonStockSharesOutstanding.json'], reqs
  end

  # ---- the multi-class limitation ----------------------------------------

  def test_multi_class_404_returns_nil
    # MSTR/ASST tag cover counts dimensionally -> the aggregation API 404s;
    # nil means "not available structured", never zero.
    transport(fail_with: BTC::Http::StatusError.new(404, 'NoSuchKey'))
    assert_nil BTC::SecShares.outstanding_for(1_050_446, now: NOW)
  end

  # ---- bad input ----------------------------------------------------------

  def test_nil_or_zero_cik_returns_nil_without_fetching
    reqs = transport
    assert_nil BTC::SecShares.outstanding_for(nil, now: NOW)
    assert_nil BTC::SecShares.outstanding_for(0, now: NOW)
    assert_empty reqs, 'no fetch for an unusable cik'
  end

  def test_reshaped_document_returns_nil
    transport(body: '{"units": {}}')
    assert_nil BTC::SecShares.outstanding_for(CIK, now: NOW)
  end

  # ---- source down: cache fallback ----------------------------------------

  def test_source_down_within_cap_serves_stale_cache
    transport
    BTC::SecShares.outstanding_for(CIK, now: NOW) # seed per-cik cache

    transport(fail_with: RuntimeError.new('dns'))
    r = BTC::SecShares.outstanding_for(CIK, now: NOW + 3600)
    assert_equal 276_953_828, r['shares']
    assert_equal true, r['stale']
  end

  def test_source_down_with_no_cache_returns_nil
    transport(fail_with: RuntimeError.new('dns'))
    assert_nil BTC::SecShares.outstanding_for(CIK, now: NOW)
  end
end
