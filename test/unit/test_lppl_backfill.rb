# frozen_string_literal: true
#
# M6-2: the staged backfill driver (scripts/lppl/backfill.rb). Pure
# orchestration logic under test with a fake runner + tmpdir staging --
# the real subprocess replay path is M6-1's territory (test_lppl_asof.rb).
# The invariant these tests pin: the driver only ever WRITES under the
# staging root; the real suite data dir is read-only input (prices +
# trend scores copied in, never back).

require_relative '../test_helper'
require_relative '../../scripts/lppl/backfill'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'json'

class TestLpplBackfill < Minitest::Test
  def entry(date, over = {})
    { 'ts' => "#{date}T00:00:00Z", 'composite' => 0.0, 'verdict' => 'STRESSED',
      'bf' => -400.0, 'ratio' => 0.45, 'omega' => 8.6 }.merge(over)
  end

  def write_ledger(path, entries)
    File.write(path, entries.map { |e| JSON.generate(e) }.join("\n") + "\n")
  end

  # ---- date enumeration ------------------------------------------------------

  def test_dates_inclusive_ascending
    d = Lppl::Backfill.dates(from: '2025-10-04', upto: '2025-10-07')
    assert_equal %w[2025-10-04 2025-10-05 2025-10-06 2025-10-07], d
  end

  def test_dates_single_day
    assert_equal %w[2025-10-04], Lppl::Backfill.dates(from: '2025-10-04', upto: '2025-10-04')
  end

  # ---- resume: done dates from the staged ledger -----------------------------

  def test_done_dates_reads_ts_prefixes_and_collapses_dups
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'ledger.jsonl')
      write_ledger(path, [entry('2025-10-04'), entry('2025-10-05'),
                          entry('2025-10-05')])
      assert_equal %w[2025-10-04 2025-10-05].to_set, Lppl::Backfill.done_dates(path)
    end
  end

  def test_done_dates_empty_when_no_ledger
    assert_equal Set.new, Lppl::Backfill.done_dates('/nonexistent/ledger.jsonl')
  end

  # ---- staging setup ---------------------------------------------------------

  def test_setup_copies_inputs_once_and_never_writes_source
    Dir.mktmpdir do |dir|
      src = File.join(dir, 'src')
      FileUtils.mkdir_p(src)
      File.write(File.join(src, 'prices.csv'), "date,close\n2025-10-01,100.0\n")
      File.write(File.join(src, 'trend_scores.csv'), "date,h,model,logscore\n")
      before = Dir[File.join(src, '*')].sort

      stage = File.join(dir, 'stage')
      Lppl::Backfill.setup(stage, data_dir: src, io: StringIO.new)
      %w[prices.csv trend_scores.csv].each do |f|
        assert File.exist?(File.join(stage, 'lppl', f)), "#{f} not staged"
      end

      # idempotent: a staged ledger survives a second setup
      ledger = File.join(stage, 'lppl', 'ledger.jsonl')
      write_ledger(ledger, [entry('2025-10-04')])
      File.write(File.join(stage, 'lppl', 'prices.csv'), "date,close\nCHANGED\n")
      Lppl::Backfill.setup(stage, data_dir: src, io: StringIO.new)
      assert_match(/2025-10-04/, File.read(ledger))
      assert_match(/CHANGED/, File.read(File.join(stage, 'lppl', 'prices.csv')),
                   'setup must not overwrite existing staged inputs (resume safety)')

      assert_equal before, Dir[File.join(src, '*')].sort, 'source dir mutated'
    end
  end

  # ---- the run loop ----------------------------------------------------------

  def fake_runner(log, fail_on: nil, stage: nil)
    lambda do |date, env|
      log << date
      raise "runner saw wrong staging root: #{env['BTC_DATA_DIR']}" if stage && env['BTC_DATA_DIR'] != stage

      if fail_on == date
        [false, 'boom']
      else
        # a real run appends the day's ledger line; emulate for resume
        ledger = File.join(env['BTC_DATA_DIR'], 'lppl', 'ledger.jsonl')
        File.open(ledger, 'a') { |f| f.puts JSON.generate(entry(date)) }
        [true, "LPPL STRESSED +0.00 @#{date}"]
      end
    end
  end

  def with_stage
    Dir.mktmpdir do |dir|
      src = File.join(dir, 'src')
      FileUtils.mkdir_p(src)
      File.write(File.join(src, 'prices.csv'), "date,close\n2025-10-01,100.0\n")
      File.write(File.join(src, 'trend_scores.csv'), "date,h,model,logscore\n")
      yield File.join(dir, 'stage'), src
    end
  end

  def test_run_sequential_ascending_with_progress
    with_stage do |stage, src|
      log = []
      io  = StringIO.new
      ok = Lppl::Backfill.run(stage_root: stage, data_dir: src,
                              from: '2025-10-04', upto: '2025-10-06',
                              io: io, runner: fake_runner(log, stage: stage))
      assert ok
      assert_equal %w[2025-10-04 2025-10-05 2025-10-06], log
      assert_match %r{\[1/3\] 2025-10-04}, io.string
      assert_match %r{\[3/3\] 2025-10-06}, io.string
    end
  end

  def test_run_skips_already_staged_days
    with_stage do |stage, src|
      FileUtils.mkdir_p(File.join(stage, 'lppl'))
      write_ledger(File.join(stage, 'lppl', 'ledger.jsonl'),
                   [entry('2025-10-04'), entry('2025-10-05')])
      log = []
      ok = Lppl::Backfill.run(stage_root: stage, data_dir: src,
                              from: '2025-10-04', upto: '2025-10-06',
                              io: StringIO.new, runner: fake_runner(log))
      assert ok
      assert_equal %w[2025-10-06], log, 'resume must skip staged days'
    end
  end

  def test_run_aborts_on_first_failure
    with_stage do |stage, src|
      log = []
      io  = StringIO.new
      ok = Lppl::Backfill.run(stage_root: stage, data_dir: src,
                              from: '2025-10-04', upto: '2025-10-06',
                              io: io, runner: fake_runner(log, fail_on: '2025-10-05'))
      refute ok
      assert_equal %w[2025-10-04 2025-10-05], log, 'must stop at the failure'
      assert_match(/FAILED 2025-10-05/, io.string)
      assert_match(/boom/, io.string)
    end
  end

  # ---- the overlap diff + promotion print ------------------------------------

  def test_diff_reports_mismatches_and_promotion_commands
    Dir.mktmpdir do |dir|
      staged = File.join(dir, 'staged.jsonl')
      live   = File.join(dir, 'live.jsonl')
      write_ledger(staged, [entry('2026-07-03'), entry('2026-07-04'),
                            entry('2026-07-05', 'bf' => -426.35)])
      # live starts 07-04 (so 07-03 is backfill-only), has a dup on 07-05,
      # and disagrees with staged on 07-04's bf.
      write_ledger(live, [entry('2026-07-04', 'ts' => '2026-07-04T19:48:34Z', 'bf' => -425.52),
                          entry('2026-07-05', 'ts' => '2026-07-05T12:38:12Z', 'bf' => -426.35),
                          entry('2026-07-05', 'ts' => '2026-07-05T12:42:41Z', 'bf' => -426.35)])
      io = StringIO.new
      mismatches = Lppl::Backfill.diff(staged, live, io: io)

      assert_equal 1, mismatches.size
      assert_equal ['2026-07-04', 'bf', -400.0, -425.52], mismatches.first
      out = io.string
      assert_match(/2026-07-04 +bf +-400\.0 +-425\.52/, out)
      assert_match(/2026-07-05: match/, out)
      assert_match(/duplicate live entries on 2026-07-05: 2/, out)
      # ts is the documented, excluded difference
      refute_match(/ts/, out.lines.grep(/mismatch/).join)
      # promotion block: backup first, then staged-before-first-live + live
      assert_match(/cp .*live\.jsonl.*\.bak-/, out)
      assert_match(/2026-07-04/, out[/first live day.*/])
    end
  end
end
