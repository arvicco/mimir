# frozen_string_literal: true
#
# M9-5: report-only fit diagnostics -- the B<0 sign restriction and the
# Sornette-school damping condition D = m|B|/(omega|C|). Exact-value pins
# with synthetic fit parameters either side of each condition. These flags
# are additive and must NEVER enter the four-filter pass/fail or the score.

require_relative '../test_helper'
require_relative '../../scripts/lppl/common'

class TestLpplFitFlags < Minitest::Test
  def test_b_negative_true_when_b_below_zero
    f = Lppl.fit_report_flags(0.5, -0.3, 8.0, 0.2)
    assert_equal true, f[:b_negative]
  end

  def test_b_negative_false_when_b_at_or_above_zero
    assert_equal false, Lppl.fit_report_flags(0.5, 0.3, 8.0, 0.2)[:b_negative]
    assert_equal false, Lppl.fit_report_flags(0.5, 0.0, 8.0, 0.2)[:b_negative]
  end

  def test_damping_exact_value
    # D = m|B| / (omega|C|) = 0.5 * 2.0 / (8.0 * 0.25) = 1.0 / 2.0 = 0.5
    assert_in_delta 0.5, Lppl.fit_report_flags(0.5, -2.0, 8.0, 0.25)[:damping], 1e-12
  end

  def test_damping_either_side_of_reference_threshold
    # below 1.0: 0.4 * 1.0 / (2.0 * 0.5) = 0.4
    below = Lppl.fit_report_flags(0.4, -1.0, 2.0, 0.5)[:damping]
    assert below < Lppl::DAMPING_REF_THRESHOLD
    assert_in_delta 0.4, below, 1e-12
    # above 1.0: 0.8 * 4.0 / (2.0 * 0.5) = 3.2
    above = Lppl.fit_report_flags(0.8, -4.0, 2.0, 0.5)[:damping]
    assert above > Lppl::DAMPING_REF_THRESHOLD
    assert_in_delta 3.2, above, 1e-12
  end

  def test_damping_uses_absolute_values_of_b_and_c
    # sign of B and C must not matter to the magnitude ratio
    pos = Lppl.fit_report_flags(0.5, 2.0, 8.0, 0.25)[:damping]
    neg = Lppl.fit_report_flags(0.5, -2.0, 8.0, -0.25)[:damping]
    assert_in_delta pos, neg, 1e-12
  end

  def test_damping_nil_when_c_absent
    assert_nil Lppl.fit_report_flags(0.5, -2.0, 8.0, 0.0)[:damping]
    assert_nil Lppl.fit_report_flags(0.5, -2.0, 8.0, 1e-15)[:damping]
  end

  def test_damping_rounds_to_four_dp
    # 0.5 * 1.0 / (3.0 * 1.0) = 0.16666... -> 0.1667
    assert_in_delta 0.1667, Lppl.fit_report_flags(0.5, -1.0, 3.0, 1.0)[:damping], 1e-12
  end

  def test_reference_threshold_is_one
    assert_equal 1.0, Lppl::DAMPING_REF_THRESHOLD
  end
end
