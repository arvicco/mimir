# frozen_string_literal: true
#
# M12-2 (Q-20): ScenarioBackfill -- dates/resume/row-building/diff on
# fakes (no subprocess, no network; STAGE_ROOT redirected to a tmpdir).

require_relative '../test_helper'
require_relative '../../scripts/scenario/backfill'
require 'tmpdir'
require 'stringio'

class TestScenarioBackfill < Minitest::Test
  def with_stage(dir)
    old = ScenarioBackfill::STAGE_ROOT
    ScenarioBackfill.send(:remove_const, :STAGE_ROOT)
    ScenarioBackfill.const_set(:STAGE_ROOT, dir)
    yield
  ensure
    ScenarioBackfill.send(:remove_const, :STAGE_ROOT)
    ScenarioBackfill.const_set(:STAGE_ROOT, old)
  end

  def agg_json(date, scores: { 'etf_flows' => 1 }, unavailable: [])
    { 'ts' => "#{date}T00:00:00Z", 'composite' => 0.25, 'regime' => 'BASE',
      'modules' => scores.map do |m, sc|
        { 'mod' => m, 'w' => m == 'positioning' ? 0 : 3, 'score' => sc,
          'unavailable' => unavailable.include?(m) }
      end }
  end

  def test_dates_inclusive_ascending
    assert_equal %w[2026-04-01 2026-04-02 2026-04-03],
                 ScenarioBackfill.dates(from: '2026-04-01', upto: '2026-04-03')
  end

  def test_row_from_json_shape_and_markers
    row = ScenarioBackfill.row_from_json(agg_json('2026-04-01'))
    assert_equal true, row['replayed']
    assert_equal 'BASE', row['regime']
    assert_equal({ 'etf_flows' => 1 }, row['scores'])
    refute row.key?('unavailable')

    part = ScenarioBackfill.row_from_json(
      agg_json('2026-04-01', scores: { 'etf_flows' => 1, 'macro' => 0 },
               unavailable: %w[macro]))
    assert_equal %w[macro], part['unavailable']
    refute part.key?('blind')

    blind = ScenarioBackfill.row_from_json(
      agg_json('2026-04-01', scores: { 'etf_flows' => 0, 'positioning' => 0 },
               unavailable: %w[etf_flows]))
    assert_equal true, blind['blind'], 'all weighted down -> blind (weight-0 cannot rescue)'
  end

  def test_run_is_resumable_and_appends_staged_rows
    Dir.mktmpdir do |dir|
      with_stage(dir) do
        calls = []
        runner = ->(d) { calls << d; agg_json(d) }
        io = StringIO.new
        assert ScenarioBackfill.run(from: '2026-04-01', upto: '2026-04-03',
                                    runner: runner, io: io)
        assert_equal %w[2026-04-01 2026-04-02 2026-04-03], calls
        assert_equal 3, File.readlines(ScenarioBackfill.staged_history).size

        calls.clear
        assert ScenarioBackfill.run(from: '2026-04-01', upto: '2026-04-04',
                                    runner: runner, io: StringIO.new)
        assert_equal %w[2026-04-04], calls, 'staged days are skipped (resume)'
      end
    end
  end

  def test_run_abort_is_resumable
    Dir.mktmpdir do |dir|
      with_stage(dir) do
        runner = ->(d) { d == '2026-04-02' ? raise('boom') : agg_json(d) }
        io = StringIO.new
        refute ScenarioBackfill.run(from: '2026-04-01', upto: '2026-04-03',
                                    runner: runner, io: io)
        assert_match(/ABORT/, io.string)
        assert_equal 1, File.readlines(ScenarioBackfill.staged_history).size,
                     'the day before the crash is staged; rerun continues'
      end
    end
  end

  def test_diff_reports_divergent_shared_dates_only
    Dir.mktmpdir do |dir|
      staged = File.join(dir, 'staged.jsonl')
      live   = File.join(dir, 'live.jsonl')
      File.write(staged, [
        { ts: '2026-04-01T00:00:00Z', composite: 0.25, regime: 'BASE', scores: { a: 1 } },
        { ts: '2026-04-02T00:00:00Z', composite: 0.25, regime: 'BASE', scores: { a: 1 } }
      ].map { |r| JSON.generate(r) }.join("\n"))
      File.write(live, [
        { ts: '2026-04-02T04:47:00Z', composite: -0.1, regime: 'NEUTRAL', scores: { a: 0 } },
        { ts: '2026-04-03T04:47:00Z', composite: 0.0, regime: 'NEUTRAL', scores: { a: 0 } }
      ].map { |r| JSON.generate(r) }.join("\n"))
      io = StringIO.new
      n = ScenarioBackfill.diff(staged, live, io: io)
      assert_equal 1, n # only 04-02 is shared, and it diverges
      assert_match(/2026-04-02.*composite.*regime NEUTRAL|2026-04-02/, io.string)
      assert_match(%r{1/1 shared dates diverge}, io.string)
    end
  end
end
