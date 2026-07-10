# frozen_string_literal: true

# M8-1: exact-value unit tests for BTC::Vol.surface against small,
# hand-built synthetic books. Delta selection is pinned by constructing
# strikes whose bs_delta straddles +/-0.25 so the choice is unambiguous.

require_relative '../test_helper'
require_relative '../../lib/btc/vol'

class TestVolSurface < Minitest::Test
  # A dense 30-day expiry: spot 100, five strikes each side, so both the
  # >=3-per-side gate passes and a clear 25-delta strike exists.
  # t = 30/365.25 years.
  T30 = 30 / 365.25

  def row(k, cp, iv)
    { k: k.to_f, cp: cp, t: T30, iv: iv, oi: 10.0, u: 100.0 }
  end

  # Build a symmetric smile: same iv on the matching call/put strike, so
  # rr25 == 0 and atm_iv is the 100-strike iv.
  def symmetric_book
    [
      row(100, 'C', 0.50), row(100, 'P', 0.50),
      row(110, 'C', 0.52), row(110, 'P', 0.52),
      row(120, 'C', 0.55), row(120, 'P', 0.55),
      row(90,  'C', 0.52), row(90,  'P', 0.52),
      row(80,  'C', 0.55), row(80,  'P', 0.55)
    ]
  end

  def test_atm_iv_is_mean_of_atm_strike_iv
    s = BTC::Vol.surface(symmetric_book, targets: [30]).first
    assert_equal 30, s[:tenor_d]
    assert_close 30.0, s[:expiry_d], 0.05
    assert_close 0.50, s[:atm_iv], 1e-12
    assert_equal 5, s[:n_calls]
    assert_equal 5, s[:n_puts]
    assert_nil s[:reason]
  end

  def test_symmetric_smile_has_zero_risk_reversal
    s = BTC::Vol.surface(symmetric_book, targets: [30]).first
    # By construction call-25d and put-25d sit on mirror strikes with equal
    # iv, so rr25 is exactly 0 and fly25 = that wing iv - atm_iv.
    assert_close 0.0, s[:rr25], 1e-12
    refute_nil s[:fly25]
    assert_operator s[:fly25], :>, 0.0 # wings above the 0.50 ATM
  end

  # Pin the 25-delta pick explicitly: give calls a monotone smile and check
  # rr25 = iv(chosen call) - iv(chosen put).
  def test_risk_reversal_picks_25_delta_strikes
    book = symmetric_book.map do |r|
      # skew the calls up, puts down, keep atm equal
      if r[:cp] == 'C' && r[:k] > 100 then r.merge(iv: r[:iv] + 0.05)
      elsif r[:cp] == 'P' && r[:k] < 100 then r.merge(iv: r[:iv] - 0.03)
      else r
      end
    end
    s = BTC::Vol.surface(book, targets: [30]).first
    # Identify the exact strikes Vol would choose and recompute by hand.
    calls = book.select { |r| r[:cp] == 'C' }
    puts_ = book.select { |r| r[:cp] == 'P' }
    c = BTC::Vol.nearest_delta(calls, 0.25)
    p = BTC::Vol.nearest_delta(puts_, -0.25)
    assert_close c[:iv] - p[:iv], s[:rr25], 1e-12
    assert_close (c[:iv] + p[:iv]) / 2.0 - s[:atm_iv], s[:fly25], 1e-12
  end

  def test_thin_tenor_reports_atm_but_nil_skew_with_reason
    thin = [
      row(100, 'C', 0.50), row(100, 'P', 0.50),
      row(110, 'C', 0.52) # only 2 calls, 1 put -> below MIN_SIDE
    ]
    s = BTC::Vol.surface(thin, targets: [30]).first
    assert_close 0.50, s[:atm_iv], 1e-12 # atm still computable
    assert_nil s[:rr25]
    assert_nil s[:fly25]
    assert_equal 2, s[:n_calls]
    assert_equal 1, s[:n_puts]
    assert_match(/thin tenor/, s[:reason])
  end

  def test_empty_book_reports_reason_for_every_target
    surf = BTC::Vol.surface([], targets: [7, 30, 90])
    assert_equal 3, surf.size
    surf.each do |s|
      assert_nil s[:atm_iv]
      assert_nil s[:expiry_d]
      assert_equal 0, s[:n_calls]
      assert_equal 0, s[:n_puts]
      assert_match(/no expiries/, s[:reason])
    end
    assert_equal [7, 30, 90], surf.map { |s| s[:tenor_d] }
  end

  # Two expiries; targets 7 and 90 must each snap to the nearest one, and a
  # target with no near expiry still snaps to the closest (degeneracy shown
  # via expiry_d).
  def test_target_snaps_to_nearest_expiry_and_degenerates_visibly
    near = symmetric_book # ~30d
    far  = symmetric_book.map { |r| r.merge(t: 95 / 365.25) } # ~95d
    surf = BTC::Vol.surface(near + far, targets: [7, 30, 90])
    d7, d30, d90 = surf
    # 7 and 30 are both closest to the 30d expiry -> same expiry_d (degenerate)
    assert_close 30.0, d7[:expiry_d], 0.05
    assert_close 30.0, d30[:expiry_d], 0.05
    # 90 is closest to the 95d expiry
    assert_close 95.0, d90[:expiry_d], 0.05
  end

  def test_field_set_is_constant_across_success_and_failure
    keys = %i[tenor_d expiry_d atm_iv rr25 fly25 n_calls n_puts reason].sort
    ok   = BTC::Vol.surface(symmetric_book, targets: [30]).first
    fail = BTC::Vol.surface([], targets: [30]).first
    assert_equal keys, ok.keys.sort
    assert_equal keys, fail.keys.sort
  end
end
