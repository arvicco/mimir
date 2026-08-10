# frozen_string_literal: true
#
# M8 seam: BTC::Coinglass -- URL building, v4 envelope unwrap, error
# paths. Transport injected per-test (never the wire); fixtures are the
# real recorded 2026-07-10 responses.

require 'minitest/autorun'
require 'json'
require_relative '../../lib/btc/coinglass'

class TestBtcCoinglass < Minitest::Test
  FIX = File.expand_path('../fixtures', __dir__)

  def with_key(value = 'test-key')
    old = ENV['COINGLASS_API_KEY']
    ENV['COINGLASS_API_KEY'] = value
    yield
  ensure
    ENV['COINGLASS_API_KEY'] = old
  end

  # Route requests to a fixture file, capturing url + headers for pins.
  def stub_transport(fixture_body)
    calls = []
    BTC::Http.transport = lambda { |uri, req, _opts|
      calls << { url: uri.to_s, key: req['CG-API-KEY'] }
      Struct.new(:code, :body).new('200', fixture_body)
    }
    calls
  ensure
    # caller runs inside this transport; reset happens in teardown
  end

  def teardown
    BTC::Http.transport = nil
  end

  def test_option_info_unwraps_data
    body  = File.read(File.join(FIX, 'coinglass_option_info.json'))
    calls = stub_transport(body)
    rows  = with_key { BTC::Coinglass.option_info }
    assert_kind_of Array, rows
    assert_equal 6, rows.size
    assert rows.first.key?('exchange_name')
    assert_includes calls.first[:url], 'option/info?symbol=BTC'
    assert_equal 'test-key', calls.first[:key]
  end

  def test_max_pain_requires_and_sends_exchange
    body  = File.read(File.join(FIX, 'coinglass_max_pain.json'))
    calls = stub_transport(body)
    rows  = with_key { BTC::Coinglass.max_pain }
    assert_equal 4, rows.size
    assert rows.first.key?('max_pain_price')
    assert_includes calls.first[:url], 'exchange=Deribit'
  end

  def test_funding_oi_history_params
    body  = File.read(File.join(FIX, 'coinglass_funding_oi.json'))
    calls = stub_transport(body)
    rows  = with_key { BTC::Coinglass.funding_oi_history }
    assert_equal 30, rows.size
    assert rows.first.key?('close')
    assert_includes calls.first[:url], 'futures/funding-rate/oi-weight-history'
    assert_includes calls.first[:url], 'interval=8h'
  end

  def test_nonzero_code_raises_without_echoing_upstream_msg
    stub_transport(JSON.generate('code' => '400',
                                 'msg' => 'Required String parameter secret-ish'))
    err = assert_raises(BTC::Coinglass::Error) { with_key { BTC::Coinglass.max_pain } }
    assert_includes err.message, 'option/max-pain'
    refute_includes err.message, 'secret-ish'
  end

  def test_missing_key_raises_before_any_request
    calls = stub_transport('{}')
    assert_raises(BTC::Coinglass::Error) { with_key(nil) { BTC::Coinglass.option_info } }
    assert_empty calls
  end
end
