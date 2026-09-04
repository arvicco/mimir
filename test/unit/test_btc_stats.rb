# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../lib/btc/stats'

# M13-1: the shared-stats extraction. BTC::Stats is the new home of
# newey_west_se + nelder_mead (moved verbatim from scripts/lppl/common.rb);
# the exact values below match the pre-move pins in test_lppl_common.rb /
# test_lppl_garch_bootstrap.rb, so old home and new home are provably the
# same math. The Lppl.* delegations stay covered by the original tests.
class TestBtcStats < Minitest::Test
  def test_newey_west_lag_zero_is_plain_variance_of_mean
    # [1,2,3,4]: gamma0 = 1.25 -> var(mean) = 1.25/4 -> se = 0.559017
    assert_in_delta 0.5590169943749475,
                    BTC::Stats.newey_west_se([1.0, 2.0, 3.0, 4.0], lag: 0), 1e-12
  end

  def test_newey_west_lag_one_bartlett_weight
    # gamma1 = 0.3125, weight (1 - 1/2) -> var(mean) = (1.25 + 0.3125)/4
    assert_in_delta 0.625,
                    BTC::Stats.newey_west_se([1.0, 2.0, 3.0, 4.0], lag: 1), 1e-12
  end

  def test_newey_west_lag_truncates_to_n_minus_one
    assert_in_delta BTC::Stats.newey_west_se([1.0, 2.0, 3.0, 4.0], lag: 3),
                    BTC::Stats.newey_west_se([1.0, 2.0, 3.0, 4.0], lag: 99), 1e-12
  end

  def test_newey_west_constant_series_is_zero_and_short_series_nil
    assert_in_delta 0.0, BTC::Stats.newey_west_se([2.0] * 10, lag: 3), 1e-12
    assert_nil BTC::Stats.newey_west_se([], lag: 1)
    assert_nil BTC::Stats.newey_west_se([1.0], lag: 1)
  end

  def test_nelder_mead_minimizes_quadratic
    xb, fb = BTC::Stats.nelder_mead([0.0, 0.0], [1.0, 1.0]) do |x|
      (x[0] - 3.0)**2 + (x[1] + 1.0)**2
    end
    assert_in_delta 3.0, xb[0], 1e-4
    assert_in_delta(-1.0, xb[1], 1e-4)
    assert_operator fb, :<, 1e-7
  end

  def test_nelder_mead_is_deterministic
    run = lambda do
      BTC::Stats.nelder_mead([0.5, 0.5], [0.1, 0.1]) do |x|
        (x[0] - 1.0)**2 + 100.0 * (x[1] - x[0]**2)**2
      end
    end
    assert_equal run.call, run.call
  end

  def test_lppl_delegations_match_the_new_home
    require_relative '../../scripts/lppl/common'
    assert_equal BTC::Stats.newey_west_se([1.0, 2.0, 3.0, 4.0], lag: 1),
                 Lppl.newey_west_se([1.0, 2.0, 3.0, 4.0], lag: 1)
    f = ->(x) { (x[0] - 2.0)**2 }
    assert_equal BTC::Stats.nelder_mead([0.0], [1.0], &f),
                 Lppl.nelder_mead([0.0], [1.0], &f)
  end
end
