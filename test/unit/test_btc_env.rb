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

# M9-12: runtime-separation path helpers (pure; no IO). live_dir is the
# app-managed clone the agents/deploy run from; data_home is the
# BTC_DATA_DIR for production. Both sit under ~/Library/Application
# Support/mimir and take an injectable home.
class TestBtcEnvRuntimeLayout < Minitest::Test
  HOME = '/Users/tester'
  SUPPORT = '/Users/tester/Library/Application Support/mimir'

  def test_app_support_under_home
    assert_equal SUPPORT, BTC::Env.app_support(HOME)
  end

  def test_live_dir_is_the_clone_under_app_support
    assert_equal "#{SUPPORT}/live", BTC::Env.live_dir(HOME)
  end

  def test_data_home_is_the_data_dir_under_app_support
    assert_equal "#{SUPPORT}/data", BTC::Env.data_home(HOME)
  end

  def test_helpers_default_to_real_home
    assert_equal BTC::Env.app_support(Dir.home), BTC::Env.app_support
    assert_equal BTC::Env.live_dir(Dir.home), BTC::Env.live_dir
    assert_equal BTC::Env.data_home(Dir.home), BTC::Env.data_home
  end

  # data_home is exactly what data_dir('<suite>', ...) lands on once
  # BTC_DATA_DIR points at it -- the layout the migration must match.
  def test_data_home_matches_the_data_dir_seam_layout
    old = ENV['BTC_DATA_DIR']
    ENV['BTC_DATA_DIR'] = BTC::Env.data_home(HOME)
    assert_equal "#{SUPPORT}/data/gex_history",
                 BTC::Env.data_dir('gex_history', 'data/gex_history')
    assert_equal "#{SUPPORT}/data/lppl", BTC::Env.data_dir('lppl', 'scripts/lppl/data')
  ensure
    old.nil? ? ENV.delete('BTC_DATA_DIR') : ENV['BTC_DATA_DIR'] = old
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
