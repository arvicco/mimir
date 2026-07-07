# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../../lib/btc/deribit'

class TestBtcDeribit < Minitest::Test
  FakeRes = Struct.new(:code, :body)

  def teardown
    BTC::Http.transport = nil
  end

  def inject(body)
    calls = []
    BTC::Http.transport = lambda do |uri, req, opts|
      calls << { uri: uri, req: req, opts: opts }
      FakeRes.new('200', body)
    end
    calls
  end

  def test_index_price_unwraps_envelope_to_float
    calls = inject('{"result":{"index_price":62158.27}}')
    assert_close 62_158.27, BTC::Deribit.index_price('btc_usd')
    assert_equal '/api/v2/public/get_index_price?index_name=btc_usd',
                 calls.first[:req].path
  end

  def test_book_summary_builds_query_and_unwraps
    calls = inject('{"result":[{"instrument_name":"BTC-27MAR26-100000-C"}]}')
    rows = BTC::Deribit.book_summary('BTC', 'option')
    assert_equal 'BTC-27MAR26-100000-C', rows.first['instrument_name']
    assert_equal '/api/v2/public/get_book_summary_by_currency?currency=BTC&kind=option',
                 calls.first[:req].path
  end

  def test_missing_result_envelope_raises_key_error
    inject('{"error":{"code":13}}')
    assert_raises(KeyError) { BTC::Deribit.result('get_index_price?index_name=x') }
  end

  # ---- index (M7-8: shared last-good cache) ----------------------------

  def with_data_dir
    dir = Dir.mktmpdir('mimir-deribit')
    old = ENV['BTC_DATA_DIR']
    ENV['BTC_DATA_DIR'] = dir
    yield dir
  ensure
    old.nil? ? ENV.delete('BTC_DATA_DIR') : ENV['BTC_DATA_DIR'] = old
    FileUtils.remove_entry(dir)
  end

  def test_index_returns_price_as_of_and_fresh_flag
    with_data_dir do
      inject('{"result":{"index_price":62158.27}}')
      r = BTC::Deribit.index('btc_usd')
      assert_close 62_158.27, r[:price]
      assert_equal false, r[:stale]
      refute_nil r[:as_of]
    end
  end

  def test_index_serves_cache_stale_after_outage
    with_data_dir do
      inject('{"result":{"index_price":62158.27}}')
      BTC::Deribit.index('btc_usd', now: Time.utc(2026, 7, 7, 12))
      BTC::Http.transport = ->(_u, _r, _o) { FakeRes.new('503', 'down') }
      r = BTC::Deribit.index('btc_usd', now: Time.utc(2026, 7, 7, 13))
      assert_equal true, r[:stale]
      assert_close 62_158.27, r[:price]
    end
  end
end
