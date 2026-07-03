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
