# frozen_string_literal: true

# BTC::Flows -- the per-<tr>/<td> flows parser that replaced the F-22
# regex (which halved rows and reported day-of-month numbers as daily
# totals). Exact values pinned against the recorded real page; ground
# truth was established cell-by-cell during the F-22 analysis.

require_relative '../test_helper'
require_relative '../../lib/btc/flows'

class TestBtcFlows < Minitest::Test
  def test_parses_recorded_page_to_exact_ground_truth
    rows = BTC::Flows.parse_flows(fixture('farside_flows.html'))
    assert_equal 13, rows.size
    assert_equal '2026-06-15', rows.first[0].strftime('%Y-%m-%d')

    by_date = rows.to_h { |d, v| [d.strftime('%Y-%m-%d'), v] }
    assert_close(-222.6, by_date['2026-06-30']) # the F-22 regex yielded "01" here
    assert_close(-296.0, by_date['2026-07-01'])
    assert_close(223.5,  by_date['2026-07-02'])
  end

  def test_rows_ascend_and_none_is_a_bare_day_number
    rows = BTC::Flows.parse_flows(fixture('farside_flows.html'))
    assert_equal rows.map(&:first), rows.map(&:first).sort
    # the F-22 corruption signature: an integer 1..31 exactly matching
    # the following row's day-of-month
    rows.each_cons(2) do |(_, v), (d2, _)|
      refute_equal d2.day.to_f, v, 'total equals next row day number (F-22 regression)'
    end
  end

  def test_paren_negatives_commas_and_summary_rows
    html = <<~HTML
      <table>
        <tr><th>Date</th><th>IBIT</th><th>Total</th></tr>
        <tr><td>1 Jul 2026</td><td>10.0</td><td>(1,234.5)</td></tr>
        <tr><td>2 Jul 2026</td><td>(5.0)</td><td>42</td></tr>
        <tr><td>Total</td><td>5.0</td><td>(1,192.5)</td></tr>
        <tr><td>Average</td><td>2.5</td><td>596.2</td></tr>
      </table>
    HTML
    rows = BTC::Flows.parse_flows(html)
    assert_equal 2, rows.size # summary rows have no date cell
    assert_close(-1234.5, rows[0][1])
    assert_close(42.0, rows[1][1])
  end

  def test_adjacent_rows_do_not_swallow_each_other
    # the exact shape that broke the old regex: rows back-to-back after
    # tag-strip, each ending in a numeric total
    html = (1..12).map { |i| "<tr><td>#{i} Jun 2026</td><td>(#{i}00.0)</td></tr>" }.join
    rows = BTC::Flows.parse_flows(html)
    assert_equal 12, rows.size
    assert_close(-100.0, rows[0][1])
    assert_close(-1200.0, rows[11][1])
  end

  def test_empty_or_tableless_input
    assert_equal [], BTC::Flows.parse_flows('')
    assert_equal [], BTC::Flows.parse_flows('<p>Just a moment...</p>')
  end

  def test_from_coinglass_converts_ms_and_raw_usd
    rows = BTC::Flows.from_coinglass(
      [{ 'timestamp' => 1_704_931_200_000, 'flow_usd' => 655_300_000, 'price_usd' => 46_663 },
       { 'timestamp' => 1_704_844_800_000, 'flow_usd' => -95_100_000 },
       { 'timestamp' => 0, 'flow_usd' => 1 }]
    )
    assert_equal 2, rows.size # zero timestamp dropped
    assert_equal '2024-01-10', rows.first[0].strftime('%Y-%m-%d') # sorted ascending
    assert_close(-95.1, rows.first[1])
    assert_close(655.3, rows.last[1]) # raw USD -> $m
  end
end
