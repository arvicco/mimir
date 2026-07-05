# frozen_string_literal: true

# M2-1: Publish::KV against a fake transport -- auth header, bounded
# retry/backoff on 429/5xx and transport errors, immediate failure on
# other 4xx, and (security-critical) token/payload redaction in every
# error path. No network can be reached from here.

require_relative '../test_helper'
require_relative '../../publish/kv_client'

class TestPublishKv < Minitest::Test
  FakeRes = Struct.new(:code, :body)

  TOKEN = 'cf-secret-token-12345'
  ENV_OK = { 'CLOUDFLARE_ACCOUNT_ID' => 'acct1', 'CLOUDFLARE_KV_NAMESPACE_ID' => 'ns1',
             'CLOUDFLARE_API_TOKEN' => TOKEN }.freeze

  def teardown
    BTC::Http.transport = nil
  end

  def inject(&blk)
    calls = []
    BTC::Http.transport = lambda do |uri, req, opts|
      calls << { uri: uri.to_s, req: req, opts: opts }
      blk.call(calls.size, uri, req)
    end
    calls
  end

  def sleeps
    @sleeps ||= []
  end

  def sleeper
    ->(s) { sleeps << s }
  end

  def test_put_sends_bearer_and_body_to_the_namespaced_key_url
    calls = inject { FakeRes.new('200', '{"success":true}') }
    assert Publish::KV.put('v1:index', '{"v":1}', env: ENV_OK, sleeper: sleeper)
    c = calls.first
    assert_kind_of Net::HTTP::Put, c[:req]
    assert_equal "Bearer #{TOKEN}", c[:req]['Authorization']
    assert_equal '{"v":1}', c[:req].body
    assert_includes c[:uri],
                    'api.cloudflare.com/client/v4/accounts/acct1/storage/kv/namespaces/ns1/values/'
    assert_includes c[:uri], 'v1%3Aindex' # key URL-encoded
  end

  def test_get_returns_raw_body
    inject { FakeRes.new('200', 'stored-value') }
    assert_equal 'stored-value', Publish::KV.get('v1:index', env: ENV_OK, sleeper: sleeper)
  end

  def test_retries_with_backoff_on_429_then_succeeds
    calls = inject { |n, _, _| n < 3 ? FakeRes.new('429', 'slow') : FakeRes.new('200', 'ok') }
    assert Publish::KV.put('k', 'v', env: ENV_OK, sleeper: sleeper)
    assert_equal 3, calls.size
    assert_equal [1, 2], sleeps # doubling backoff, one sleep per retry
  end

  def test_retries_on_5xx_and_transport_errors_up_to_cap
    inject do |n, _, _|
      raise Timeout::Error, 'to' if n == 2

      FakeRes.new('500', 'boom')
    end
    e = assert_raises(Publish::KV::Error) { Publish::KV.put('k', 'v', env: ENV_OK, sleeper: sleeper) }
    assert_match(/after 4 tries/, e.message)
    assert_equal [1, 2, 4], sleeps # capped: tries - 1 sleeps
  end

  def test_non_retryable_4xx_fails_immediately
    calls = inject { FakeRes.new('403', 'denied for token cf-secret-token-12345') }
    e = assert_raises(Publish::KV::Error) { Publish::KV.put('k', 'v', env: ENV_OK, sleeper: sleeper) }
    assert_equal 1, calls.size
    assert_empty sleeps
    assert_match(/HTTP 403/, e.message)
  end

  def test_errors_never_carry_token_or_bodies
    inject { FakeRes.new('500', "upstream said #{TOKEN} and leaked the payload") }
    e = assert_raises(Publish::KV::Error) do
      Publish::KV.put('k', 'secret-payload-body', env: ENV_OK, sleeper: sleeper)
    end
    refute_includes e.message, TOKEN
    refute_includes e.message, 'secret-payload-body'
    refute_includes e.message, 'upstream said' # response bodies never quoted
  end

  def test_missing_env_raises_named_variable_without_values
    e = assert_raises(Publish::KV::Error) do
      Publish::KV.put('k', 'v', env: { 'CLOUDFLARE_ACCOUNT_ID' => 'a' }, sleeper: sleeper)
    end
    assert_match(/CLOUDFLARE_KV_NAMESPACE_ID/, e.message)
    refute_match(/\ba\b/, e.message) # names only, never values
  end
end
