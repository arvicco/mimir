# frozen_string_literal: true
#
# M12-5 (Q-17): BTC::Ntfy -- dormant-by-default transition alerts.
# Pins: dormant no-op without NTFY_TOPIC; first observation ARMS
# (records, no push); a transition pushes exactly once; repeats are
# unchanged; the daily cap mutes with a single overflow notice; push
# failures are swallowed and redacted. No network: http injected.

require_relative '../test_helper'
require_relative '../../lib/btc/ntfy'
require 'tmpdir'

class TestNtfy < Minitest::Test
  def with_env(topic:, dir:)
    old_t = ENV['NTFY_TOPIC']
    old_d = ENV['BTC_DATA_DIR']
    topic.nil? ? ENV.delete('NTFY_TOPIC') : ENV['NTFY_TOPIC'] = topic
    ENV['BTC_DATA_DIR'] = dir
    yield
  ensure
    old_t.nil? ? ENV.delete('NTFY_TOPIC') : ENV['NTFY_TOPIC'] = old_t
    old_d.nil? ? ENV.delete('BTC_DATA_DIR') : ENV['BTC_DATA_DIR'] = old_d
  end

  def recorder
    calls = []
    [calls, ->(topic, msg) { calls << [topic, msg] }]
  end

  NOW = Time.utc(2026, 8, 30, 12, 0, 0)

  def test_dormant_without_topic
    Dir.mktmpdir do |d|
      with_env(topic: nil, dir: d) do
        calls, http = recorder
        assert_equal :dormant,
                     BTC::Ntfy.notify_transition('regime', 'BASE', 'x', now: NOW, http: http)
        assert_empty calls
        refute File.exist?(BTC::Ntfy.state_file), 'dormant mode writes nothing'
      end
    end
  end

  def test_first_observation_arms_without_pushing
    Dir.mktmpdir do |d|
      with_env(topic: 't0pic', dir: d) do
        calls, http = recorder
        assert_equal :armed,
                     BTC::Ntfy.notify_transition('regime', 'BASE', 'x', now: NOW, http: http)
        assert_empty calls, 'arming must not fire a fake transition'
      end
    end
  end

  def test_transition_pushes_once_then_unchanged
    Dir.mktmpdir do |d|
      with_env(topic: 't0pic', dir: d) do
        calls, http = recorder
        BTC::Ntfy.notify_transition('regime', 'BASE', 'x', now: NOW, http: http) # arm
        assert_equal :pushed,
                     BTC::Ntfy.notify_transition('regime', 'RECOVERY',
                                                 'regime BASE -> RECOVERY', now: NOW, http: http)
        assert_equal [%w[t0pic] + ['regime BASE -> RECOVERY']].map(&:flatten), calls.map(&:flatten)
        assert_equal :unchanged,
                     BTC::Ntfy.notify_transition('regime', 'RECOVERY', 'again', now: NOW, http: http)
        assert_equal 1, calls.size, 'a repeated state never re-pushes'
      end
    end
  end

  def test_kinds_are_independent
    Dir.mktmpdir do |d|
      with_env(topic: 't0pic', dir: d) do
        calls, http = recorder
        BTC::Ntfy.notify_transition('regime', 'BASE', 'x', now: NOW, http: http)
        BTC::Ntfy.notify_transition('lppl', 'STRESSED', 'x', now: NOW, http: http)
        assert_empty calls # both armed
        BTC::Ntfy.notify_transition('lppl', 'FALSIFIED', 'lppl!', now: NOW, http: http)
        assert_equal 1, calls.size
        assert_equal 'lppl!', calls.first[1]
      end
    end
  end

  def test_daily_cap_mutes_with_single_notice
    Dir.mktmpdir do |d|
      with_env(topic: 't0pic', dir: d) do
        calls, http = recorder
        BTC::Ntfy.notify_transition('k', 's0', 'x', now: NOW, http: http) # arm
        (1..BTC::Ntfy::DAILY_CAP + 3).each do |i|
          BTC::Ntfy.notify_transition('k', "s#{i}", "m#{i}", now: NOW, http: http)
        end
        # CAP real pushes + exactly ONE muted notice, the extra two silent
        assert_equal BTC::Ntfy::DAILY_CAP + 1, calls.size
        assert_match(/muted/, calls.last[1])
        # a new UTC day resets the counter
        tomorrow = NOW + 86_400
        assert_equal :pushed,
                     BTC::Ntfy.notify_transition('k', 'fresh', 'new day', now: tomorrow, http: http)
      end
    end
  end

  def test_push_failure_is_swallowed_and_redacted
    Dir.mktmpdir do |d|
      with_env(topic: 'sekret-topic', dir: d) do
        boom = ->(_t, _m) { raise 'connect timeout to sekret-topic' }
        BTC::Ntfy.notify_transition('k', 'a', 'x', now: NOW, http: boom) # arm
        err = capture_io do
          assert_equal :pushed, # transition recorded even though the wire failed
                       BTC::Ntfy.notify_transition('k', 'b', 'x', now: NOW, http: boom)
        end[1]
        refute_includes err, 'sekret-topic', 'error path must not leak the topic'
        assert_includes err, 'ntfy: push failed'
      end
    end
  end
end
