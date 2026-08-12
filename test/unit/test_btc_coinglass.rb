# frozen_string_literal: true
#
# M8 seam: BTC::Coinglass -- URL building, v4 envelope unwrap, error
# paths. Transport injected per-test (never the wire); fixtures are the
# real recorded 2026-07-10 responses.

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
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

  # Transport returning an arbitrary HTTP code (for tier-gated / error
  # paths). Records the CG-API-KEY header seen on each request.
  def stub_status(code, body = '{}')
    calls = []
    BTC::Http.transport = lambda { |uri, req, _opts|
      calls << { url: uri.to_s, key: req['CG-API-KEY'] }
      Struct.new(:code, :body).new(code.to_s, body)
    }
    calls
  end

  def with_data_dir
    dir = Dir.mktmpdir('mimir-coinglass')
    old = ENV['BTC_DATA_DIR']
    ENV['BTC_DATA_DIR'] = dir
    yield dir
  ensure
    old.nil? ? ENV.delete('BTC_DATA_DIR') : ENV['BTC_DATA_DIR'] = old
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
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

  # ---- tier-gated detection (M10-1) -----------------------------------

  def test_http_401_raises_tier_gated_with_path_only_message
    stub_status(401, 'Unauthorized')
    err = assert_raises(BTC::Coinglass::TierGated) do
      with_key { BTC::Coinglass.get('option/info', { symbol: 'BTC' }) }
    end
    assert_kind_of BTC::Coinglass::Error, err, 'TierGated is a Coinglass::Error'
    assert_includes err.message, 'option/info'
    assert_includes err.message, 'tier-gated'
    refute_includes err.message, 'symbol', 'no params in the message'
    refute_includes err.message, 'test-key', 'no key in the message'
  end

  def test_non_401_status_error_reraises_unchanged
    stub_status(503, 'down')
    err = assert_raises(BTC::Http::StatusError) do
      with_key { BTC::Coinglass.get('option/info', { symbol: 'BTC' }) }
    end
    assert_equal 503, err.code
  end

  # ---- optional caching path (M10-1) ----------------------------------

  def test_cached_path_unwraps_envelope_and_sends_key_header
    body = JSON.generate('code' => '0', 'data' => [{ 'x' => 1 }])
    calls = stub_transport(body)
    rows = with_data_dir do
      with_key { BTC::Coinglass.get('option/info', { symbol: 'BTC' }, cache: 'cg_opt') }
    end
    assert_equal [{ 'x' => 1 }], rows
    assert_equal 'test-key', calls.first[:key], 'CG-API-KEY reaches the transport'
    assert_includes calls.first[:url], 'option/info?symbol=BTC'
  end

  def test_cached_path_still_raises_on_nonzero_envelope_code
    body = JSON.generate('code' => '400', 'msg' => 'secret-ish param')
    stub_transport(body)
    with_data_dir do
      err = assert_raises(BTC::Coinglass::Error) do
        with_key { BTC::Coinglass.get('option/max-pain', { symbol: 'BTC' }, cache: 'cg_mp') }
      end
      assert_includes err.message, 'option/max-pain'
      refute_includes err.message, 'secret-ish'
    end
  end

  def test_cached_path_ttl_fresh_hit_avoids_second_transport_call
    body = JSON.generate('code' => '0', 'data' => [{ 'x' => 1 }])
    with_data_dir do
      stub_transport(body)
      with_key { BTC::Coinglass.get('option/info', { symbol: 'BTC' }, cache: 'cg_ttl', ttl: 86_400) }

      calls = stub_transport(body) # fresh recorder
      rows = with_key { BTC::Coinglass.get('option/info', { symbol: 'BTC' }, cache: 'cg_ttl', ttl: 86_400) }
      assert_empty calls, 'ttl-fresh cache hit must not re-hit the API'
      assert_equal [{ 'x' => 1 }], rows
    end
  end
end
