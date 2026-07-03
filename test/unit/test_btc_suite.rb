# frozen_string_literal: true

# BTC::Suite.run_module against tiny throwaway module scripts -- no
# network, subprocesses only.

require_relative '../test_helper'
require_relative '../../lib/btc/suite'
require 'tmpdir'
require 'fileutils'

class TestBtcSuite < Minitest::Test
  def write_module(dir, name, body)
    File.write(File.join(dir, "#{name}.rb"), body)
  end

  def test_parses_last_stdout_line_as_json
    Dir.mktmpdir do |dir|
      write_module(dir, 'noisy', <<~RB)
        puts 'warning: something incidental'
        puts '{"name":"noisy","score":1,"headline":"ok"}'
      RB
      r = BTC::Suite.run_module(dir, 'noisy', 10)
      assert_equal 1, r['score']
      assert_equal 'ok', r['headline']
    end
  end

  def test_passes_extra_argv_through
    Dir.mktmpdir do |dir|
      write_module(dir, 'echoer', <<~RB)
        require 'json'
        puts JSON.generate('argv' => ARGV)
      RB
      r = BTC::Suite.run_module(dir, 'echoer', 10, ['--history'])
      assert_equal %w[--json --history], r['argv']
    end
  end

  def test_timeout_raises
    Dir.mktmpdir do |dir|
      write_module(dir, 'hang', 'sleep 30')
      assert_raises(Timeout::Error) { BTC::Suite.run_module(dir, 'hang', 0.3) }
    end
  end

  def test_garbage_stdout_raises_parse_error
    Dir.mktmpdir do |dir|
      write_module(dir, 'garbage', "puts 'not json'")
      assert_raises(JSON::ParserError) { BTC::Suite.run_module(dir, 'garbage', 10) }
    end
  end
end
