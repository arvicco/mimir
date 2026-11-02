# frozen_string_literal: true
#
# M12-5: Publish::Alerts -- transition dispatch from a real
# publish summary. Fake ntfy recorder; pins the four kinds' states and
# messages, fail-soft/absent payload skips, the clean-vs-marked health
# state, and the never-raises guard.

require_relative '../test_helper'
require_relative '../../publish/alerts'
require 'tmpdir'

class TestPublishAlerts < Minitest::Test
  class FakeNtfy
    attr_reader :calls

    def initialize = @calls = []
    def notify_transition(kind, state, message, **) = @calls << [kind, state, message]
  end

  def summary(env: {}, old: [], blind: [])
    { envelopes: env, old_keys: old, blind_tails: blind }
  end

  def env_with(key, payload)
    { key => { 'payload' => payload } }
  end

  def test_all_four_kinds_dispatch_with_states
    env = {
      'scenario:latest' => { 'payload' => { 'regime' => 'BASE', 'composite' => 0.33 } },
      'lppl:latest'     => { 'payload' => { 'verdict' => 'STRESSED', 'composite' => 0.0 } },
      'gex:combined'    => { 'payload' => { 'btc_spot' => 78_000.0,
                                            'combined' => { 'gamma_flip' => 65_000.0 } } }
    }
    n = FakeNtfy.new
    assert Publish::Alerts.dispatch(summary(env: env), ntfy: n)
    kinds = n.calls.to_h { |k, s, _| [k, s] }
    assert_equal 'BASE', kinds['regime']
    assert_equal 'STRESSED', kinds['lppl']
    assert_equal 'above', kinds['gamma_flip']
    assert_equal 'clean', kinds['publish_health']
    msg = n.calls.find { |k, _, _| k == 'gamma_flip' }[2]
    assert_match(/spot 78000, flip 65000/, msg)
  end

  def test_below_flip_state
    env = env_with('gex:combined', { 'btc_spot' => 60_000.0,
                                     'combined' => { 'gamma_flip' => 65_000.0 } })
    n = FakeNtfy.new
    Publish::Alerts.dispatch(summary(env: env), ntfy: n)
    assert_equal 'below', n.calls.to_h { |k, s, _| [k, s] }['gamma_flip']
  end

  def test_fail_soft_and_absent_payloads_skip_their_kind
    env = {
      'scenario:latest' => { 'payload' => { 'regime' => 'BASE', 'unavailable' => true } },
      'gex:combined'    => { 'payload' => { 'btc_spot' => 0.0, 'combined' => {} } }
    }
    n = FakeNtfy.new
    Publish::Alerts.dispatch(summary(env: env), ntfy: n)
    kinds = n.calls.map(&:first)
    refute_includes kinds, 'regime', 'fail-soft payload must not alert'
    refute_includes kinds, 'lppl', 'absent envelope must not alert'
    refute_includes kinds, 'gamma_flip', 'zero spot/flip must not alert'
    assert_includes kinds, 'publish_health' # always evaluated
  end

  def test_health_markers_compose_the_state
    n = FakeNtfy.new
    Publish::Alerts.dispatch(summary(old: ['lppl:ledger'], blind: ['scenario']), ntfy: n)
    _, state, msg = n.calls.find { |k, _, _| k == 'publish_health' }
    assert_equal 'OLD:lppl:ledger BLIND:scenario', state
    assert_match(/publish health OLD:lppl:ledger BLIND:scenario/, msg)
  end

  def test_never_raises_even_when_ntfy_explodes
    boom = Object.new
    def boom.notify_transition(*) = raise('ntfy down')
    out = nil
    _, err = capture_io do
      out = Publish::Alerts.dispatch(summary(old: []), ntfy: boom)
    end
    assert_equal false, out
    assert_match(/alerts: skipped/, err)
  end

  # ---- M14-4: the 'deg' kind --------------------------------------
  # Real BTC::Ntfy state machine behind a forwarder that injects the
  # clock and a recording http (no network).

  NOW = Time.utc(2026, 10, 12, 12, 0, 0)

  class RealNtfy
    attr_accessor :now
    attr_reader :pushes

    def initialize(now)
      @now = now
      @pushes = []
    end

    def notify_transition(kind, state, message)
      BTC::Ntfy.notify_transition(kind, state, message, now: @now,
                                                        http: ->(_t, m) { @pushes << m })
    end
  end

  def with_ntfy(topic: 't0pic')
    Dir.mktmpdir do |d|
      old_t = ENV['NTFY_TOPIC']
      old_d = ENV['BTC_DATA_DIR']
      topic.nil? ? ENV.delete('NTFY_TOPIC') : ENV['NTFY_TOPIC'] = topic
      ENV['BTC_DATA_DIR'] = d
      yield RealNtfy.new(NOW)
    ensure
      old_t.nil? ? ENV.delete('NTFY_TOPIC') : ENV['NTFY_TOPIC'] = old_t
      old_d.nil? ? ENV.delete('BTC_DATA_DIR') : ENV['BTC_DATA_DIR'] = old_d
    end
  end

  def deg_run(ntfy, keys)
    Publish::Alerts.dispatch({ envelopes: {}, old_keys: [], blind_tails: [], deg_keys: keys },
                             ntfy: ntfy)
    ntfy.pushes.reject { |m| m.include?('publish health') }
  end

  def test_deg_state_is_sorted_key_list
    n = FakeNtfy.new
    Publish::Alerts.dispatch(summary.merge(deg_keys: ['vol:spread', 'gex:combined']), ntfy: n)
    assert_equal 'gex:combined,vol:spread', n.calls.to_h { |k, s, _| [k, s] }['deg']
  end

  def test_deg_empty_state_is_clean
    n = FakeNtfy.new
    Publish::Alerts.dispatch(summary.merge(deg_keys: []), ntfy: n)
    assert_equal 'clean', n.calls.to_h { |k, s, _| [k, s] }['deg']
  end

  def test_deg_absent_from_summary_skips_the_kind
    n = FakeNtfy.new
    Publish::Alerts.dispatch(summary, ntfy: n)
    refute_includes n.calls.map(&:first), 'deg'
  end

  def test_deg_empty_to_nonempty_pushes_once_with_key_names
    with_ntfy do |n|
      deg_run(n, []) # arm
      pushes = deg_run(n, ['vol:spread'])
      assert_equal ['mimir: degraded inside fresh keys: vol:spread -- a data source ' \
                    "in them has been dead across #{Publish::DegDetector::STREAK_RUNS} " \
                    'consecutive publishes (about half a day)'], pushes
    end
  end

  def test_deg_set_change_pushes
    with_ntfy do |n|
      deg_run(n, [])
      deg_run(n, ['vol:spread'])
      n.now = NOW + 3600
      pushes = deg_run(n, ['vol:spread', 'gex:combined'])
      assert_equal 2, pushes.size
      assert_includes pushes.last, 'gex:combined, vol:spread'
    end
  end

  def test_deg_nonempty_to_empty_pushes_healed
    with_ntfy do |n|
      deg_run(n, [])
      deg_run(n, ['vol:spread'])
      n.now = NOW + 3600 # inside the cooldown: the first heal still pushes
      pushes = deg_run(n, [])
      assert_equal 'mimir: degraded keys healed -- every data source is back', pushes.last
    end
  end

  def test_deg_refire_and_repeat_heal_within_window_are_silent
    with_ntfy do |n|
      deg_run(n, [])
      deg_run(n, ['vol:spread']) # degraded push
      n.now = NOW + 3600
      deg_run(n, [])             # heal pushes
      n.now = NOW + 7200
      deg_run(n, ['vol:spread']) # refire: cooled
      n.now = NOW + 10_800
      pushes = deg_run(n, [])    # repeat heal: cooled
      assert_equal 2, pushes.size
      assert_match(/healed/, pushes.last)
    end
  end

  def test_deg_unchanged_set_is_silent
    with_ntfy do |n|
      deg_run(n, [])
      deg_run(n, ['vol:spread'])
      pushes = deg_run(n, ['vol:spread'])
      assert_equal 1, pushes.size
    end
  end

  def test_deg_daily_cap_still_applies
    with_ntfy do |n|
      deg_run(n, []) # arm
      (1..BTC::Ntfy::DAILY_CAP + 2).each { |i| deg_run(n, ["k#{i}"]) }
      pushes = n.pushes
      assert_equal BTC::Ntfy::DAILY_CAP + 1, pushes.size
      assert_match(/muted/, pushes.last)
    end
  end

  def test_deg_dormant_without_topic
    with_ntfy(topic: nil) do |n|
      deg_run(n, [])
      deg_run(n, ['vol:spread'])
      assert_empty n.pushes
      refute File.exist?(BTC::Ntfy.state_file), 'dormant mode writes nothing'
    end
  end
end
