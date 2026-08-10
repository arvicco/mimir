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

  def test_timeout_raises_and_kills_the_child
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, 'pid.txt')
      write_module(dir, 'hang', <<~RB)
        File.write(#{pidfile.inspect}, Process.pid.to_s)
        sleep 30
      RB
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(Timeout::Error) { BTC::Suite.run_module(dir, 'hang', 0.3) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      # the pre-fix behavior held the Timeout::Error for the child's full
      # 30 s sleep inside IO.popen's implicit close-wait
      assert_operator elapsed, :<, 5, 'timeout must interrupt, not wait out the child'
      pid = File.read(pidfile).to_i
      # C8 (SBI review): the timed-out child must not linger. Poll briefly --
      # the TERM/KILL escalation is allowed a moment to land.
      dead = 20.times.any? do
        begin
          Process.kill(0, pid)
          sleep 0.1
          false
        rescue Errno::ESRCH
          true
        end
      end
      assert dead, "child #{pid} still alive after timeout"
    end
  end

  def test_garbage_stdout_raises_parse_error
    Dir.mktmpdir do |dir|
      write_module(dir, 'garbage', "puts 'not json'")
      assert_raises(JSON::ParserError) { BTC::Suite.run_module(dir, 'garbage', 10) }
    end
  end
end
