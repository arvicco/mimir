# frozen_string_literal: true
#
# M12-5 (Q-17): Publish::Alerts -- transition dispatch from a real
# publish summary. Fake ntfy recorder; pins the four kinds' states and
# messages, fail-soft/absent payload skips, the clean-vs-marked health
# state, and the never-raises guard.

require_relative '../test_helper'
require_relative '../../publish/alerts'

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
end
