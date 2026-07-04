# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/btc/env'

class TestBtcEnv < Minitest::Test
  def with_env(val)
    old = ENV['BTC_DATA_DIR']
    ENV['BTC_DATA_DIR'] = val
    yield
  ensure
    old.nil? ? ENV.delete('BTC_DATA_DIR') : ENV['BTC_DATA_DIR'] = old
  end

  def test_default_when_unset
    with_env(nil) do
      assert_equal '/x/data', BTC::Env.data_dir('lppl', '/x/data')
    end
  end

  def test_default_when_empty
    with_env('') do
      assert_equal '/x/data', BTC::Env.data_dir('lppl', '/x/data')
    end
  end

  def test_override_appends_suite
    with_env('/var/btc') do
      assert_equal '/var/btc/lppl', BTC::Env.data_dir('lppl', '/x/data')
    end
  end
end

class TestBtcEnvRedact < Minitest::Test
  def test_redacts_credential_query_params
    assert_equal 'x?api_key=[REDACTED]&limit=6',
                 BTC::Env.redact('x?api_key=abc123&limit=6')
    assert_equal 'bad token=[REDACTED] here',
                 BTC::Env.redact('bad token=tok_99 here')
  end

  def test_redacts_literal_secret_env_values
    old = ENV['FRED_API_KEY']
    ENV['FRED_API_KEY'] = 'deadbeef42'
    assert_equal 'GET /obs?k=[FRED_API_KEY] failed',
                 BTC::Env.redact('GET /obs?k=deadbeef42 failed')
  ensure
    old.nil? ? ENV.delete('FRED_API_KEY') : ENV['FRED_API_KEY'] = old
  end

  def test_passes_clean_strings_through
    msg = 'HTTP 404 -- and Z -2.31 at 0.85/(Age+2.0)'
    assert_equal msg, BTC::Env.redact(msg)
  end
end
