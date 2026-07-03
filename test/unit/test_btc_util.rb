# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/btc/util'

class TestBtcUtil < Minitest::Test
  def test_arg_returns_value_after_flag
    assert_equal '45', BTC::Util.arg('--max-days', ['--max-days', '45'])
  end

  def test_arg_nil_when_flag_absent_or_valueless
    assert_nil BTC::Util.arg('--max-days', ['--json'])
    assert_nil BTC::Util.arg('--max-days', ['--json', '--max-days'])
  end
end
