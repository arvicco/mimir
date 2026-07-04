# frozen_string_literal: true

# BTC::Http seam tests -- all through an injected fake transport; no
# network can be reached from here (Golden Rule 6).

require_relative '../test_helper'
require_relative '../../lib/btc/http'

class TestBtcHttp < Minitest::Test
  FakeRes = Struct.new(:code, :body)

  def teardown
    BTC::Http.transport = nil # restore the real transport
  end

  def inject(&blk)
    calls = []
    BTC::Http.transport = lambda do |uri, req, opts|
      calls << { uri: uri, req: req, opts: opts }
      blk.call(uri, req, opts)
    end
    calls
  end

  def test_get_returns_body_on_200
    inject { FakeRes.new('200', 'hello') }
    assert_equal 'hello', BTC::Http.get('https://example.com/x')
  end

  def test_get_raises_status_error_with_historical_message
    inject { FakeRes.new('404', 'not here') }
    e = assert_raises(BTC::Http::StatusError) { BTC::Http.get('https://example.com/x') }
    assert_equal 'HTTP 404', e.message # frozen fail-soft headline text
    assert_equal 404, e.code
    assert_equal 'not here', e.body
  end

  def test_get_json_parses
    inject { FakeRes.new('200', '{"a":1}') }
    assert_equal({ 'a' => 1 }, BTC::Http.get_json('https://example.com/x'))
  end

  def test_headers_and_timeouts_reach_the_transport
    calls = inject { FakeRes.new('200', 'ok') }
    BTC::Http.get('https://example.com/x?q=1', { 'User-Agent' => 'lppl.rb' },
                  read_timeout: 60)
    c = calls.first
    assert_equal 'lppl.rb', c[:req]['User-Agent']
    assert_equal 60, c[:opts][:read_timeout]
    assert_equal 5, c[:opts][:open_timeout]
    assert_equal '/x?q=1', c[:req].path
  end

  def test_post_sends_body
    calls = inject { FakeRes.new('200', 'ok') }
    BTC::Http.post('https://api.example.com/v1', '{"m":1}',
                   { 'content-type' => 'application/json' })
    c = calls.first
    assert_kind_of Net::HTTP::Post, c[:req]
    assert_equal '{"m":1}', c[:req].body
    assert_equal 120, c[:opts][:read_timeout]
  end

  # For 3xx responses get_follow reads the Location header via #[].
  class RedirectRes < FakeRes
    def initialize(code, body, location = nil)
      super(code, body)
      @location = location
    end

    def [](key)
      @location if key.to_s.casecmp('location').zero?
    end
  end

  def test_get_follow_follows_absolute_and_relative_redirects
    calls = inject do |uri, _req, _opts|
      case uri.to_s
      when %r{example\.com/start} then RedirectRes.new('302', '', 'https://example.com/hop')
      when %r{/hop\z}             then RedirectRes.new('301', '', '/final')
      when %r{/final\z}           then FakeRes.new('200', 'landed')
      end
    end
    assert_equal 'landed', BTC::Http.get_follow('https://example.com/start')
    assert_equal 3, calls.size
  end

  def test_get_follow_raises_on_redirect_loop
    inject { RedirectRes.new('302', '', 'https://example.com/again') }
    e = assert_raises(BTC::Http::StatusError) { BTC::Http.get_follow('https://example.com/again') }
    assert_equal 508, e.code
  end

  def test_get_follow_passes_plain_errors_through
    inject { FakeRes.new('403', 'blocked') }
    e = assert_raises(BTC::Http::StatusError) { BTC::Http.get_follow('https://example.com/x') }
    assert_equal 'HTTP 403', e.message
  end

  def test_get_follow_raises_on_redirect_without_location
    inject { RedirectRes.new('302', 'no loc', nil) }
    e = assert_raises(BTC::Http::StatusError) { BTC::Http.get_follow('https://example.com/x') }
    assert_equal 302, e.code
  end
end
