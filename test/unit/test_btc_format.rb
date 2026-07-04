# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/btc/format'

class TestBtcFormat < Minitest::Test
  def test_musd
    assert_equal '+58.0M', BTC::Format.musd(58_035_157)
    assert_equal '-3.2M',  BTC::Format.musd(-3_240_000)
    assert_equal '+0.0M',  BTC::Format.musd(0)
  end

  def test_profile_bars_pins_gex_rb_rendering
    profile = { 95_000.0 => -10_000_000.0, 100_000.0 => 20_000_000.0,
                150_000.0 => 99_000_000.0 } # outside +-15%, hidden
    near = profile # bar scale anchor
    out, = capture_io do
      BTC::Format.profile_bars(profile, near, 100_000.0, 9,
                               ->(k) { format('%d', k) })
    end
    lines = out.lines
    assert_equal 2, lines.size # 150k outside the +-15% display band
    # 10M/99M * 40 -> 4 bars; 20M/99M * 40 -> 8 bars
    assert_equal "95000           -10.0M  -####\n", lines[0]
    assert_equal "100000          +20.0M  +########\n", lines[1]
  end

  def test_profile_bars_caps_at_forty
    profile = { 100_000.0 => 50.0 }
    out, = capture_io do
      BTC::Format.profile_bars(profile, profile, 100_000.0, 8, ->(k) { k.to_s })
    end
    assert_includes out, '#' * 40
    refute_includes out, '#' * 41
  end
end
