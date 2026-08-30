# frozen_string_literal: true
#
# M12-4 (Q-12): --json field-set contract for scripts/bubble_ref.rb,
# run offline via the fake transport against the recorded
# coinglass_bubble_index.json (skips until the owner records it:
# `rake fixtures:record SOURCES=bubble`). Frozen contract from birth
# (Golden Rule 5): additive changes update these pins in the same
# commit. The fail-soft path needs no fixture (denied transport).

require_relative 'contract_helper'

class TestBubbleContract < Minitest::Test
  KEYS = %w[name ts headline value date pct band n_days].freeze

  def fixture?
    File.exist?(File.join(ROOT, 'test/fixtures/coinglass_bubble_index.json'))
  end

  def test_bubble_ref_json_contract
    skip 'coinglass_bubble_index.json not yet recorded (M12-4) -- owner: rake fixtures:record SOURCES=bubble' unless fixture?
    j = run_json('scripts/bubble_ref.rb', '--json',
                 env: { 'COINGLASS_API_KEY' => 'contract-test-key' })
    assert_equal KEYS.sort, j.keys.sort, 'frozen field set'
    assert_equal 'bubble_ref', j['name']
    assert_equal RECORDED_NOW, Time.iso8601(j['ts']).iso8601
    assert_kind_of Numeric, j['value']
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, j['date'])
    assert_kind_of Numeric, j['pct']
    assert_includes %w[HIGH MID LOW], j['band']
    assert_operator j['n_days'], :>=, 300
    refute j.key?('unavailable')
  end

  def test_bubble_ref_fails_soft_when_denied
    j = run_json('scripts/bubble_ref.rb', '--json',
                 env: { 'COINGLASS_API_KEY' => 'contract-test-key',
                        'FAKE_HTTP_DENY' => 'coinglass' })
    assert_equal true, j['unavailable']
    assert_match(/unavailable/, j['headline'])
    assert_equal 'bubble_ref', j['name']
  end
end
