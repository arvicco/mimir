# frozen_string_literal: true
#
# M12-4 (Q-12): BubbleRef pure math -- own-history percentile (linear
# rank), the 80/20 HIGH/MID/LOW labels, and the compute() payload shape.
# Synthetic rows; no network.

require_relative '../test_helper'
require_relative '../../scripts/bubble_ref'

class TestBubbleRef < Minitest::Test
  def rows(values)
    values.each_with_index.map do |v, i|
      { 'bubble_index' => v, 'date_string' => format('2026-01-%02d', i + 1),
        'price' => 1.0 }
    end
  end

  def test_percentile_linear_rank_exact
    assert_in_delta 0.0,  BubbleRef.percentile(1.0, [1.0, 2.0, 3.0, 4.0]), 1e-9
    assert_in_delta 75.0, BubbleRef.percentile(4.0, [1.0, 2.0, 3.0, 4.0]), 1e-9
    assert_in_delta 50.0, BubbleRef.percentile(2.5, [1.0, 2.0, 3.0, 4.0]), 1e-9
    assert_nil BubbleRef.percentile(1.0, [])
  end

  def test_band_cutoffs_inclusive_to_extremes
    assert_equal 'HIGH', BubbleRef.band(80.0)
    assert_equal 'MID',  BubbleRef.band(79.9)
    assert_equal 'LOW',  BubbleRef.band(20.0)
    assert_equal 'MID',  BubbleRef.band(20.1)
  end

  def test_compute_payload_shape_and_values
    # latest (10.0) sits above 9 of 10 values -> pct 90 -> HIGH
    p = BubbleRef.compute(rows([1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map(&:to_f)))
    assert_equal 10.0, p['value']
    assert_equal '2026-01-10', p['date']
    assert_in_delta 90.0, p['pct'], 1e-9
    assert_equal 'HIGH', p['band']
    assert_equal 10, p['n_days']
  end

  def test_compute_raises_on_empty
    assert_raises(RuntimeError) { BubbleRef.compute([]) }
  end
end
