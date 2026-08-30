# frozen_string_literal: true
#
# M12-3 (Q-20): Backtest -- band mapping (mirrors the aggregator's
# regime derivation EXACTLY), organic-wins row merging, --bands
# validation, and an end-to-end CURRENT-vs-PROPOSED run over synthetic
# histories + prices. No network, no real data dirs.

require_relative '../test_helper'
require_relative '../../scripts/backtest'
require 'tmpdir'
require 'stringio'
require 'json'

class TestBacktest < Minitest::Test
  def test_regime_for_matches_the_aggregator_boundaries
    b = Backtest::CURRENT_BANDS
    assert_equal 'FLUSH',      Backtest.regime_for(-0.40, b) # inclusive
    assert_equal 'LEAN-FLUSH', Backtest.regime_for(-0.10, b) # inclusive
    assert_equal 'NEUTRAL',    Backtest.regime_for(-0.099, b)
    assert_equal 'NEUTRAL',    Backtest.regime_for(0.099, b)
    assert_equal 'BASE',       Backtest.regime_for(0.10, b)  # < 0.10 is NEUTRAL
    assert_equal 'RECOVERY',   Backtest.regime_for(0.40, b)  # >= 0.40
  end

  def test_merged_rows_organic_wins_and_counts
    live   = [{ 'ts' => '2026-04-02T04:47:00Z', 'composite' => 0.5 }]
    staged = [{ 'ts' => '2026-04-01T00:00:00Z', 'composite' => -0.5 },
              { 'ts' => '2026-04-02T00:00:00Z', 'composite' => -0.5 }]
    rows, counts = Backtest.merged_rows(live, staged)
    assert_equal 2, rows.size
    assert_equal({ organic: 1, replayed: 1 }, counts)
    shared = rows.find { |r| r['date'] == '2026-04-02' }
    assert_equal 0.5, shared['composite'], 'organic row wins the shared date'
    refute shared['replayed']
  end

  def test_parse_bands_validates
    assert_equal [-0.5, -0.2, 0.2, 0.5], Backtest.parse_bands(['--bands', '-0.5,-0.2,0.2,0.5'])
    assert_equal Backtest::CURRENT_BANDS, Backtest.parse_bands([])
  end

  def test_end_to_end_current_vs_proposed
    Dir.mktmpdir do |dir|
      lppl = File.join(dir, 'lppl'); scen = File.join(dir, 'scen')
      FileUtils.mkdir_p(lppl); FileUtils.mkdir_p(scen)
      d0 = Date.new(2026, 1, 1)
      # prices: steady 0.2%/day rise over 200 days (positive forward returns)
      File.write(File.join(lppl, 'prices.csv'),
                 "date,close\n" + (0..200).map { |i| "#{(d0 + i).iso8601},#{50_000 * (1.002**i)}" }.join("\n"))
      # 60 daily organic rows alternating composite 0.05 / 0.2
      File.write(File.join(scen, 'history.jsonl'),
                 (0...60).map { |i|
                   JSON.generate('ts' => "#{(d0 + i).iso8601}T04:47:00Z",
                                 'composite' => i.even? ? 0.05 : 0.2, 'regime' => 'x')
                 }.join("\n"))
      staged = File.join(dir, 'staged.jsonl')
      File.write(staged, '') # empty staging is fine

      io = StringIO.new
      Backtest.run(bands: [-0.4, -0.1, 0.0, 0.4], # 0.05 flips NEUTRAL -> BASE
                   lppl_dir: lppl, scenario_dir: scen, staged_path: staged, io: io)
      out = io.string
      assert_match(/60 days \(60 organic \+ 0 replayed/, out)
      assert_match(/CURRENT -0.4\/-0.1\/0.1\/0.4 \| PROPOSED -0.4\/-0.1\/0.0\/0.4/, out)
      assert_match(/7d forward log-return/, out)
      assert_match(/NEUTRAL/, out) # current banding has NEUTRAL days
      assert_match(/BASE/, out)
      # JSON mode carries both scored structures
      jio = StringIO.new
      Backtest.run(bands: [-0.4, -0.1, 0.0, 0.4],
                   lppl_dir: lppl, scenario_dir: scen, staged_path: staged,
                   io: jio, json: true)
      j = JSON.parse(jio.string)
      cur7 = j['current']['7']
      pro7 = j['proposed']['7']
      assert cur7['eligible']
      assert cur7['bands'].key?('NEUTRAL'), 'current bands the 0.05 days NEUTRAL'
      refute pro7['bands'].key?('NEUTRAL'), 'proposed re-bands them BASE'
      assert_operator pro7['bands']['BASE']['n'], :>, cur7['bands']['BASE']['n']
    end
  end
end
