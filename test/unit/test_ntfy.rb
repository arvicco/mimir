# frozen_string_literal: true
#
# M12-5: BTC::Ntfy -- dormant-by-default transition alerts.
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
  # ---- M14-4: flap cooldown (every kind) ---------------------------
  # A delivered push stamps only the ENTERED state; a change into a state
  # stamped within COOLDOWN_H is :cooled.

  H = 3600

  def test_cooldown_first_return_within_window_still_pushes
    Dir.mktmpdir do |d|
      with_env(topic: 't0pic', dir: d) do
        calls, http = recorder
        BTC::Ntfy.notify_transition('k', 'A', 'x', now: NOW, http: http) # arm
        assert_equal :pushed, BTC::Ntfy.notify_transition('k', 'B', 'to B', now: NOW, http: http)
        assert_equal :pushed,
                     BTC::Ntfy.notify_transition('k', 'A', 'to A', now: NOW + H, http: http)
        assert_equal ['to B', 'to A'], calls.map(&:last)
      end
    end
  end

  def test_cooldown_refire_within_window_is_cooled
    Dir.mktmpdir do |d|
      with_env(topic: 't0pic', dir: d) do
        calls, http = recorder
        BTC::Ntfy.notify_transition('k', 'A', 'x', now: NOW, http: http)
        BTC::Ntfy.notify_transition('k', 'B', 'to B', now: NOW, http: http)
        BTC::Ntfy.notify_transition('k', 'A', 'to A', now: NOW + H, http: http)
        assert_equal :cooled,
                     BTC::Ntfy.notify_transition('k', 'B', 'to B', now: NOW + (2 * H), http: http)
        assert_equal ['to B', 'to A'], calls.map(&:last)
      end
    end
  end

  def test_cooldown_repeat_return_within_window_is_cooled
    Dir.mktmpdir do |d|
      with_env(topic: 't0pic', dir: d) do
        calls, http = recorder
        BTC::Ntfy.notify_transition('k', 'A', 'x', now: NOW, http: http)
        BTC::Ntfy.notify_transition('k', 'B', 'to B', now: NOW, http: http)
        BTC::Ntfy.notify_transition('k', 'A', 'to A', now: NOW + H, http: http)
        BTC::Ntfy.notify_transition('k', 'B', 'to B', now: NOW + (2 * H), http: http)
        assert_equal :cooled,
                     BTC::Ntfy.notify_transition('k', 'A', 'to A', now: NOW + (3 * H), http: http)
        assert_equal 2, calls.size
      end
    end
  end

  def test_cooldown_after_quiet_window_pushes_again
    Dir.mktmpdir do |d|
      with_env(topic: 't0pic', dir: d) do
        calls, http = recorder
        BTC::Ntfy.notify_transition('k', 'A', 'x', now: NOW, http: http)
        BTC::Ntfy.notify_transition('k', 'B', 'to B', now: NOW, http: http)
        BTC::Ntfy.notify_transition('k', 'A', 'to A', now: NOW + H, http: http)
        later = NOW + H + (BTC::Ntfy::COOLDOWN_H * H) + 1
        assert_equal :pushed, BTC::Ntfy.notify_transition('k', 'B', 'to B', now: later, http: http)
        assert_equal :pushed,
                     BTC::Ntfy.notify_transition('k', 'A', 'to A', now: later + 60, http: http)
        assert_equal 4, calls.size
      end
    end
  end

  def test_cooled_change_is_recorded_with_a_note
    Dir.mktmpdir do |d|
      with_env(topic: 't0pic', dir: d) do
        _, http = recorder
        BTC::Ntfy.notify_transition('k', 'A', 'x', now: NOW, http: http)
        BTC::Ntfy.notify_transition('k', 'B', 'x', now: NOW, http: http)
        BTC::Ntfy.notify_transition('k', 'A', 'x', now: NOW + H, http: http)
        BTC::Ntfy.notify_transition('k', 'B', 'x', now: NOW + (2 * H), http: http)
        st = BTC::Ntfy.load_state
        assert_equal 'B', st['kinds']['k']
        assert_equal 1, st['notes'].size
        assert_match(/k -> B: cooled/, st['notes'].first)
      end
    end
  end

  def test_cooldown_applies_to_regime_kind
    Dir.mktmpdir do |d|
      with_env(topic: 't0pic', dir: d) do
        calls, http = recorder
        BTC::Ntfy.notify_transition('regime', 'BASE', 'x', now: NOW, http: http)
        BTC::Ntfy.notify_transition('regime', 'FLUSH', 'to FLUSH', now: NOW, http: http)
        BTC::Ntfy.notify_transition('regime', 'BASE', 'to BASE', now: NOW + H, http: http)
        assert_equal :cooled,
                     BTC::Ntfy.notify_transition('regime', 'FLUSH', 'to FLUSH',
                                                 now: NOW + (2 * H), http: http)
        assert_equal ['to FLUSH', 'to BASE'], calls.map(&:last)
      end
    end
  end

  def test_cooled_change_does_not_count_toward_cap
    Dir.mktmpdir do |d|
      with_env(topic: 't0pic', dir: d) do
        _, http = recorder
        BTC::Ntfy.notify_transition('k', 'A', 'x', now: NOW, http: http)
        BTC::Ntfy.notify_transition('k', 'B', 'x', now: NOW, http: http)
        BTC::Ntfy.notify_transition('k', 'A', 'x', now: NOW + 60, http: http)
        BTC::Ntfy.notify_transition('k', 'B', 'x', now: NOW + 120, http: http) # cooled
        assert_equal 2, BTC::Ntfy.load_state['cap']['n']
      end
    end
  end

  def test_old_format_state_file_loads_and_works
    Dir.mktmpdir do |d|
      with_env(topic: 't0pic', dir: d) do
        FileUtils.mkdir_p(BTC::Ntfy.state_dir)
        File.write(BTC::Ntfy.state_file,
                   JSON.generate({ 'kinds' => { 'regime' => 'BASE' },
                                   'cap' => { 'day' => '2026-08-30', 'n' => 2 } }))
        calls, http = recorder
        assert_equal :unchanged,
                     BTC::Ntfy.notify_transition('regime', 'BASE', 'x', now: NOW, http: http)
        assert_equal :pushed,
                     BTC::Ntfy.notify_transition('regime', 'FLUSH', 'to FLUSH', now: NOW, http: http)
        assert_equal ['to FLUSH'], calls.map(&:last)
        assert_equal 3, BTC::Ntfy.load_state['cap']['n']
      end
    end
  end

  # ---- M14-3: the BTC::Http seam + failure paths --------------------
  # With no http: kwarg, push goes through BTC::Http.post, so a fake
  # BTC::Http.transport catches it. Every failure path is checked
  # end-to-end for the topic: the return value, stdout and stderr.

  FakeRes = Struct.new(:code, :body)
  SECRET  = 'sekret-topic-9f2'

  def teardown
    BTC::Http.transport = nil # restore the real transport
  end

  def seam(&blk)
    calls = []
    BTC::Http.transport = lambda do |uri, req, opts|
      calls << { uri: uri, req: req, opts: opts }
      blk.call(uri, req, opts)
    end
    calls
  end

  # Runs push with the secret topic set; returns [result, out + err].
  def push_leak_check(msg = "boom for #{SECRET}", **kw)
    result = nil
    text = nil
    Dir.mktmpdir do |d|
      with_env(topic: SECRET, dir: d) do
        out, err = capture_io { result = BTC::Ntfy.push(msg, **kw) }
        text = out + err
      end
    end
    [result, text]
  end

  def assert_no_leak(result, text)
    refute_includes result.inspect, SECRET, 'return value must not carry the topic'
    refute_includes text, SECRET, 'output must not carry the topic'
  end

  def test_seam_2xx_returns_true
    seam { FakeRes.new('200', '{"id":"x"}') }
    result, = push_leak_check('hello')
    assert_equal true, result
  end

  def test_seam_other_2xx_returns_true
    seam { FakeRes.new('202', '') }
    result, = push_leak_check('hello')
    assert_equal true, result
  end

  def test_seam_targets_topic_url_with_post_body
    calls = seam { FakeRes.new('200', 'ok') }
    push_leak_check('hello')
    c = calls.first
    assert_equal "https://ntfy.sh/#{SECRET}", c[:uri].to_s
    assert_kind_of Net::HTTP::Post, c[:req]
    assert_equal 'hello', c[:req].body
  end

  def test_seam_default_title_is_mimir
    calls = seam { FakeRes.new('200', 'ok') }
    push_leak_check('hello')
    assert_equal 'mimir', calls.first[:req]['Title']
  end

  def test_seam_title_kwarg_sets_title_header
    calls = seam { FakeRes.new('200', 'ok') }
    push_leak_check('hello', title: 'mimir: regime')
    assert_equal 'mimir: regime', calls.first[:req]['Title']
  end

  def test_seam_priority_kwarg_sets_priority_header
    calls = seam { FakeRes.new('200', 'ok') }
    push_leak_check('hello', priority: 4)
    assert_equal '4', calls.first[:req]['Priority']
  end

  def test_seam_no_priority_header_by_default
    calls = seam { FakeRes.new('200', 'ok') }
    push_leak_check('hello')
    assert_nil calls.first[:req]['Priority']
  end

  def test_seam_keeps_historical_timeouts
    calls = seam { FakeRes.new('200', 'ok') }
    push_leak_check('hello')
    assert_equal({ open_timeout: 5, read_timeout: 10 }, calls.first[:opts])
  end

  def test_injected_http_wins_over_the_seam
    calls = seam { FakeRes.new('200', 'ok') }
    hits = []
    result, = push_leak_check('hello', http: ->(t, m) { hits << [t, m] })
    assert_equal true, result
    assert_equal 1, hits.size
    assert_empty calls, 'an injected http: must bypass BTC::Http'
  end

  def test_non_2xx_returns_false
    seam { FakeRes.new('429', 'slow down') }
    result, = push_leak_check
    assert_equal false, result
  end

  def test_non_2xx_does_not_leak_topic
    seam { FakeRes.new('500', "error for topic #{SECRET}") }
    assert_no_leak(*push_leak_check)
  end

  def test_transport_raise_returns_false
    seam { raise SocketError, 'getaddrinfo failed' }
    result, = push_leak_check
    assert_equal false, result
  end

  def test_transport_raise_does_not_leak_topic
    seam { |uri, _r, _o| raise SocketError, "cannot reach #{uri}" }
    assert_no_leak(*push_leak_check)
  end

  def test_timeout_returns_false
    seam { raise Net::ReadTimeout }
    result, = push_leak_check
    assert_equal false, result
  end

  def test_timeout_does_not_leak_topic
    seam { |uri, _r, _o| raise Net::OpenTimeout, "execution expired for #{uri}" }
    assert_no_leak(*push_leak_check)
  end

  def test_injected_http_raise_does_not_leak_topic
    result, text = push_leak_check(http: ->(t, _m) { raise "dead #{t}" })
    assert_equal false, result
    assert_no_leak(result, text)
  end

  def test_dormant_push_makes_zero_transport_calls
    calls = seam { FakeRes.new('200', 'ok') }
    Dir.mktmpdir do |d|
      with_env(topic: nil, dir: d) do
        assert_equal false, BTC::Ntfy.push('hello')
        ENV['NTFY_TOPIC'] = ''
        assert_equal false, BTC::Ntfy.push('hello')
      end
    end
    assert_empty calls
  end

  def test_outbound_body_is_redacted
    calls = seam { FakeRes.new('200', 'ok') }
    push_leak_check("subscribe at ntfy.sh/#{SECRET}")
    refute_includes calls.first[:req].body, SECRET
    assert_includes calls.first[:req].body, '[NTFY_TOPIC]'
  end

  def test_outbound_title_is_redacted
    calls = seam { FakeRes.new('200', 'ok') }
    push_leak_check('hello', title: "t #{SECRET}")
    refute_includes calls.first[:req]['Title'], SECRET
  end

  def test_env_redact_scrubs_the_topic
    Dir.mktmpdir do |d|
      with_env(topic: SECRET, dir: d) do
        assert_equal 'x [NTFY_TOPIC] y', BTC::Env.redact("x #{SECRET} y")
      end
    end
  end
end
