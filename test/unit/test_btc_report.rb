# frozen_string_literal: true

# Pins BTC::Report output byte-for-byte against the three historical
# per-suite copies it replaces (F-15): scenario (14/18), lppl (12/16),
# btco fail_soft (6).

require_relative '../test_helper'
require_relative '../../lib/btc/report'

class TestBtcReport < Minitest::Test
  def test_json_line_shape_and_key_order
    out, = capture_io do
      BTC::Report.report('funding', -1, 'headline here',
                         { 'note' => 'x', 'skipme' => nil }, json: true)
    end
    h = JSON.parse(out)
    assert_equal %w[name score headline ts note], h.keys
    assert_equal(-1, h['score'])
    refute h.key?('skipme')
  end

  def test_human_format_scenario_widths
    out, = capture_io do
      BTC::Report.report('cb_premium', 1, 'ok', { 'k' => 'v' },
                         name_w: 14, key_w: 18, json: false)
    end
    assert_equal "cb_premium     [+1]  ok\n  k                  v\n", out
  end

  def test_human_format_lppl_widths
    out, = capture_io do
      BTC::Report.report('trend', 0, 'ok', {}, name_w: 12, key_w: 16, json: false)
    end
    assert_equal "trend        [+0]  ok\n", out
  end

  def test_fail_soft_reports_score_zero_and_exits_zero
    out, = capture_io do
      e = assert_raises(SystemExit) do
        BTC::Report.fail_soft('btco', 'boom', name_w: 6, json: false)
      end
      assert_equal 0, e.status
    end
    assert_equal "btco   [+0]  unavailable (boom)\n", out
  end
end
