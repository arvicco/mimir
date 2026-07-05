# frozen_string_literal: true

# test_publish_envelope.rb -- pins the FROZEN KV envelope contract
# (ARCHITECTURE.md 4.2) built by Publish.wrap / Publish.build_index.
# Pure functions: no IO, no ENV, no network. The envelope key set is a
# public contract -- additive only, and only with this test updated in
# the same commit.

require_relative '../test_helper'
require_relative '../../publish/envelope'

class TestPublishEnvelope < Minitest::Test
  NOW = Time.utc(2026, 7, 4, 12, 0, 0)

  def test_wrap_builds_exact_envelope
    env = Publish.wrap('gex:combined', { 'flip' => 42 }, 1800,
                       now: NOW, source: 'testhost')
    assert_equal(
      {
        'v' => 1,
        'key' => 'gex:combined',
        'generated_at' => '2026-07-04T12:00:00Z',
        'ttl_hint_s' => 1800,
        'source' => 'testhost',
        'payload' => { 'flip' => 42 }
      },
      env
    )
  end

  def test_wrap_key_set_is_the_frozen_contract
    env = Publish.wrap('gex:combined', { 'a' => 1 }, 1800,
                       now: NOW, source: 'testhost')
    # FROZEN envelope contract: additive only, with a same-commit update
    # to this pin. See ARCHITECTURE.md 4.2.
    assert_equal %w[generated_at key payload source ttl_hint_s v], env.keys.sort
  end

  def test_wrap_key_order_is_stable
    env = Publish.wrap('gex:combined', { 'a' => 1 }, 1800,
                       now: NOW, source: 'testhost')
    assert_equal %w[v key generated_at ttl_hint_s source payload], env.keys
  end

  def test_wrap_round_trips_through_json
    env = Publish.wrap('gex:combined', { 'a' => [1, 2], 'b' => 'x' }, 1800,
                       now: NOW, source: 'testhost')
    assert_equal env, JSON.parse(JSON.generate(env))
  end

  def test_wrap_passes_payload_through_untouched
    payload = { 'nested' => { 'k' => [1, 2, 3] } }
    env = Publish.wrap('scenario:latest', payload, 30, now: NOW, source: 'novo')
    assert_same payload, env['payload']
  end

  def test_wrap_rejects_nil_payload
    assert_raises(ArgumentError) do
      Publish.wrap('gex:combined', nil, 1800, now: NOW, source: 'testhost')
    end
  end

  def test_wrap_rejects_non_positive_ttl
    assert_raises(ArgumentError) do
      Publish.wrap('gex:combined', {}, 0, now: NOW, source: 'testhost')
    end
    assert_raises(ArgumentError) do
      Publish.wrap('gex:combined', {}, -5, now: NOW, source: 'testhost')
    end
  end

  def test_wrap_rejects_empty_key
    assert_raises(ArgumentError) do
      Publish.wrap('', {}, 1800, now: NOW, source: 'testhost')
    end
  end

  def test_build_index_wraps_sorted_keys_with_min_ttl
    later = Time.utc(2026, 7, 4, 12, 5, 0)
    entries = [
      Publish.wrap('scenario:latest', { 's' => 1 }, 1800, now: later, source: 'novo'),
      Publish.wrap('gex:combined', { 'g' => 1 }, 900, now: NOW, source: 'novo')
    ]
    idx = Publish.build_index(entries, now: later, source: 'novo')

    assert_equal 1, idx['v']
    assert_equal 'index', idx['key']
    assert_equal '2026-07-04T12:05:00Z', idx['generated_at']
    assert_equal 900, idx['ttl_hint_s'] # MIN across entries
    assert_equal 'novo', idx['source']
    assert_equal(
      { 'keys' => [
        { 'key' => 'gex:combined', 'generated_at' => '2026-07-04T12:00:00Z' },
        { 'key' => 'scenario:latest', 'generated_at' => '2026-07-04T12:05:00Z' }
      ] },
      idx['payload']
    )
  end

  def test_build_index_round_trips_through_json
    entries = [Publish.wrap('gex:combined', { 'g' => 1 }, 900, now: NOW, source: 'novo')]
    idx = Publish.build_index(entries, now: NOW, source: 'novo')
    assert_equal idx, JSON.parse(JSON.generate(idx))
  end

  def test_build_index_rejects_empty_entries
    assert_raises(ArgumentError) do
      Publish.build_index([], now: NOW, source: 'novo')
    end
  end
end
