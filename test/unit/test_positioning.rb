# frozen_string_literal: true
#
# M10-3: crowd-positioning module pure logic -- percentile, band mapping,
# score truth table, WARMUP, string-typed-numeric normalization, history
# append dedup, and the fail-soft paths (TierGated + transport error).
# Requiring positioning.rb does NOT execute the fetch/report (guarded by
# $PROGRAM_NAME == __FILE__), so these run fully offline.

require 'minitest/autorun'
require 'json'
require 'tmpdir'
require 'fileutils'
require_relative '../../scripts/scenario/positioning'

class TestPositioning < Minitest::Test
  P = Positioning

  def teardown
    BTC::Http.transport = nil
  end

  # ---- percentile: exact values, both cutoff boundaries ----------------

  def test_percentile_exact_values
    w = [1.0, 2.0, 3.0, 4.0]
    assert_in_delta 0.0,   P.percentile(1.0, w), 1e-9   # none strictly below
    assert_in_delta 50.0,  P.percentile(2.5, w), 1e-9   # two below
    assert_in_delta 100.0, P.percentile(5.0, w), 1e-9   # all below
    assert_in_delta 25.0,  P.percentile(2.0, w), 1e-9   # strictly-below only
  end

  # A value landing exactly on the 80th (and 20th) cutoff is IN the
  # extreme band. Window 0..89: count strictly below v == v.
  def test_band_boundaries_are_inclusive_to_the_extreme
    window_hi = (0..89).map(&:to_f) + [72.0] # pct == 72/90*100 == 80.0
    assert_equal ['LONG', 80.0, 72.0], P.band_for(window_hi, 'LONG', 'BALANCED', 'SHORT')

    window_lo = (0..89).map(&:to_f) + [18.0] # pct == 18/90*100 == 20.0
    assert_equal ['SHORT', 20.0, 18.0], P.band_for(window_lo, 'LONG', 'BALANCED', 'SHORT')

    window_mid = (0..89).map(&:to_f) + [50.0] # 50 of 90 below -> pct 55.56
    band, pct, = P.band_for(window_mid, 'LONG', 'BALANCED', 'SHORT')
    assert_equal 'BALANCED', band
    assert_in_delta 55.555556, pct, 1e-5
  end

  def test_classify_cutoffs
    assert_equal 'HI',  P.classify(80.0, 'HI', 'MID', 'LO')
    assert_equal 'HI',  P.classify(99.9, 'HI', 'MID', 'LO')
    assert_equal 'LO',  P.classify(20.0, 'HI', 'MID', 'LO')
    assert_equal 'LO',  P.classify(0.0,  'HI', 'MID', 'LO')
    assert_equal 'MID', P.classify(50.0, 'HI', 'MID', 'LO')
    assert_equal 'MID', P.classify(79.99, 'HI', 'MID', 'LO')
    assert_equal 'MID', P.classify(20.01, 'HI', 'MID', 'LO')
  end

  # ---- WARMUP: fewer than 90 trailing values --------------------------

  def test_warmup_below_ninety_trailing
    series90 = (1..90).map(&:to_f)      # 89 trailing -> WARMUP
    assert_equal ['WARMUP', nil, 90.0], P.band_for(series90, 'HI', 'MID', 'LO')

    series91 = (1..91).map(&:to_f)      # exactly 90 trailing -> banded
    band, pct, today = P.band_for(series91, 'HI', 'MID', 'LO')
    refute_equal 'WARMUP', band
    assert_in_delta 100.0, pct, 1e-9    # today (91) above all 90 trailing
    assert_in_delta 91.0, today, 1e-9
  end

  # ---- per-sub-signal band mapping ------------------------------------

  # 90 flat rows then a spike/dip drives the extreme band deterministically.
  def rows_with(field, flat, last, extra = {})
    (1..91).map do |i|
      { 'time' => i * 86_400_000, field => (i == 91 ? last : flat) }.merge(extra)
    end
  end

  def test_crowding_band_long_and_short
    hi = P.crowding_band(rows_with('global_account_long_short_ratio', 1.0, 9.0))
    assert_equal 'LONG', hi[0]
    lo = P.crowding_band(rows_with('global_account_long_short_ratio', 5.0, 0.1))
    assert_equal 'SHORT', lo[0]
  end

  def test_top_traders_band
    hi = P.top_traders_band(rows_with('top_position_long_short_ratio', 1.0, 9.0))
    assert_equal 'LONG', hi[0]
  end

  def oi_rows(closes)
    closes.each_with_index.map { |c, i| { 'time' => i * 86_400_000, 'close' => c } }
  end

  def test_oi7d_series_is_seven_day_percent_change_exact
    # 8 closes -> exactly one 7d change: (110-100)/100*100 == 10.0
    assert_equal [10.0], P.oi7d_series(oi_rows([100, 100, 100, 100, 100, 100, 100, 110]))
    # string-typed closes normalize via to_f
    assert_equal [50.0], P.oi7d_series(oi_rows(%w[200 200 200 200 200 200 200 300]))
  end

  def test_oi7d_band_rising_when_last_day_change_is_extreme
    closes = Array.new(100, 100.0)
    closes[99] = 200.0 # only the final day jumps -> its 7d change is the max
    band, pct, val = P.oi7d_band(oi_rows(closes))
    assert_equal 'RISING', band
    assert_in_delta 100.0, pct, 1e-9
    assert_in_delta 100.0, val, 1e-9
  end

  def test_oi7d_band_warmup_below_ninety
    band, = P.oi7d_band(oi_rows(Array.new(20, 100.0))) # 13 derived -> WARMUP
    assert_equal 'WARMUP', band
  end

  def test_taker_bias_band_buy_from_string_typed_values
    # buy/sell arrive as STRINGS; normalization must to_f them.
    rows = (1..91).map do |i|
      buy, sell = i == 91 ? ['9', '1'] : ['1', '1']
      { 'time' => i * 86_400_000, 'taker_buy_volume_usd' => buy, 'taker_sell_volume_usd' => sell }
    end
    band, _pct, val = P.taker_bias_band(rows)
    assert_equal 'BUY', band          # 0.9 buy share, far above the flat 0.5
    assert_in_delta 0.9, val, 1e-9
  end

  def test_liq_skew_band_longs_and_shorts_hit
    hi = (1..91).map do |i|
      l, s = i == 91 ? [90.0, 10.0] : [1.0, 1.0]
      { 'time' => i * 86_400_000, 'aggregated_long_liquidation_usd' => l,
        'aggregated_short_liquidation_usd' => s }
    end
    assert_equal 'LONGS-HIT', P.liq_skew_band(hi)[0]
  end

  # ---- score truth table ----------------------------------------------

  def test_score_flush_lineup_is_minus_one
    assert_equal(-1, P.score('LONG', 'RISING', 'LONGS-HIT'))
  end

  def test_score_recovery_lineup_is_plus_one
    assert_equal 1, P.score('SHORT', 'FALLING', 'SHORTS-HIT')
  end

  def test_score_near_misses_are_zero
    assert_equal 0, P.score('LONG', 'RISING', 'BALANCED')
    assert_equal 0, P.score('LONG', 'FLAT', 'LONGS-HIT')
    assert_equal 0, P.score('BALANCED', 'RISING', 'LONGS-HIT')
    assert_equal 0, P.score('SHORT', 'FALLING', 'BALANCED')
    assert_equal 0, P.score('SHORT', 'FLAT', 'SHORTS-HIT')
    assert_equal 0, P.score('WARMUP', 'WARMUP', 'WARMUP')
    assert_equal 0, P.score('LONG', 'RISING', 'SHORTS-HIT') # crossed lineup
  end

  # ---- history append dedup -------------------------------------------

  def test_history_appends_once_per_utc_day
    Dir.mktmpdir('mimir-pos-hist') do |dir|
      file = File.join(dir, 'history.jsonl')
      row1 = { 'date' => '2026-08-12', 'score' => 0 }
      row2 = { 'date' => '2026-08-12', 'score' => -1 } # same day, second run
      row3 = { 'date' => '2026-08-13', 'score' => 1 }  # next day

      assert_equal true,  P.append_history(file, row1)
      assert_equal false, P.append_history(file, row2) # dedup: no second write
      assert_equal true,  P.append_history(file, row3)

      lines = File.readlines(file).map { |l| JSON.parse(l) }
      assert_equal 2, lines.size
      assert_equal %w[2026-08-12 2026-08-13], lines.map { |l| l['date'] }
      assert_equal 0, lines.first['score'] # first-writer-wins for the day
    end
  end

  # ---- fail-soft reason mapping ---------------------------------------

  def test_failsoft_reason_maps_tier_gated
    assert_equal 'tier-gated',
                 P.failsoft_reason(BTC::Coinglass::TierGated.new('coinglass x: tier-gated'))
    assert_equal 'boom', P.failsoft_reason(RuntimeError.new('boom'))
  end

  # ---- fail-soft at the run surface (TierGated + transport error) -----

  def with_key
    old = ENV['COINGLASS_API_KEY']
    ENV['COINGLASS_API_KEY'] = 'unit-test-key'
    yield
  ensure
    old.nil? ? ENV.delete('COINGLASS_API_KEY') : ENV['COINGLASS_API_KEY'] = old
  end

  def run_human(argv)
    old = ARGV.dup
    ARGV.replace(argv)
    out, = capture_io { assert_raises(SystemExit) { P.run } }
    out
  ensure
    ARGV.replace(old)
  end

  def test_run_fails_soft_on_tier_gated
    BTC::Http.transport = ->(_u, _r, _o) { Struct.new(:code, :body).new('401', 'Unauthorized') }
    Dir.mktmpdir('mimir-pos-tg') do |dir|
      ENV['BTC_DATA_DIR'] = dir
      out = with_key { run_human([]) }
      assert_match(/positioning/, out)
      assert_match(/unavailable \(tier-gated\)/, out)
    ensure
      ENV.delete('BTC_DATA_DIR')
    end
  end

  def test_run_fails_soft_on_transport_error
    BTC::Http.transport = ->(_u, _r, _o) { Struct.new(:code, :body).new('500', 'boom') }
    Dir.mktmpdir('mimir-pos-500') do |dir|
      ENV['BTC_DATA_DIR'] = dir
      out = with_key { run_human([]) }
      assert_match(/unavailable/, out)
    ensure
      ENV.delete('BTC_DATA_DIR')
    end
  end

  # ---- weight-0 invariance of the scenario composite math -------------
  # Characterizes scenario.rb's composite formula: a weight-0 module
  # cannot move the composite, whatever its score.

  def composite(mods) # mods = [[weight, score], ...]
    wsum = mods.sum { |w, _| w }
    mods.sum { |w, s| w * s }.to_f / wsum
  end

  def test_weight0_module_cannot_move_composite
    base = [[3, 1], [2, -1], [2, 0], [2, 1], [1, -1], [1, 0], [1, 1]]
    [-1, 0, 1].each do |s|
      assert_in_delta composite(base), composite(base + [[0, s]]), 1e-12,
                      "weight-0 module with score #{s} moved the composite"
    end
  end
end
