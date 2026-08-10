# frozen_string_literal: true
#
# M6-1: --as-of replay behavior of the real module scripts, driven as
# subprocesses against a throwaway BTC_DATA_DIR (no network -- these
# modules read the price cache only). Covers the two date-evolving caches
# whose read-filter/append rules the seam tests in test_lppl_common.rb
# cannot reach: trend_scores.csv (read-filter + append suppression) and
# fit_history.jsonl (stability read-filter), plus the frozen wall clock
# threaded through the aggregator into --json and the ledger, and the
# malformed-flag abort.

require_relative '../test_helper'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'time'

class TestLpplAsOf < Minitest::Test
  ROOT    = File.expand_path('../..', __dir__)
  GENESIS = Time.utc(2009, 1, 3)

  # A smooth increasing daily series -- enough rows that horizons mature past
  # trend's MINFIT (1460) so real new scores would be produced (and thus
  # append-suppression is observable), but cheap to load.
  def write_prices(dir, from, to)
    FileUtils.mkdir_p(dir)
    lines = +"date,close\n"
    t = from
    while t <= to
      days = (t - GENESIS) / 86_400.0
      lines << "#{t.strftime('%Y-%m-%d')},#{format('%.2f', Math.exp(-10 + 3.0 * Math.log(days)))}\n"
      t += 86_400
    end
    File.write(File.join(dir, 'prices.csv'), lines)
  end

  # The contract synthetic (Random.new(42)): a global power law + 4y
  # oscillation, a rise into a 2026-03-01 peak, then a power-decay anti-bubble
  # tail so fit.rb finds a qualified post-peak window and an interior trough.
  def write_lppl_series(dir, last)
    FileUtils.mkdir_p(dir)
    start = Time.utc(2014, 1, 1)
    bump0 = Time.utc(2025, 1, 1)
    peak  = Time.utc(2026, 3, 1)
    rng = Random.new(42)
    peak_ln = nil
    lines = +"date,close\n"
    t = start
    while t <= last
      days = (t - GENESIS) / 86_400.0
      yrs  = (t - start) / (365.25 * 86_400)
      ln = -36.0 + 5.4 * Math.log(days) + 0.15 * Math.sin(2 * Math::PI * yrs / 4.0)
      ln += 0.5 * ((t - bump0) / (peak - bump0).to_f)**2 if t >= bump0 && t <= peak
      if t > peak
        tau = (t - peak) / 86_400.0
        ln = peak_ln - 0.06 * (tau**0.4) +
             0.015 * (tau**0.4) * Math.cos(8.0 * Math.log([tau, 2.5].max))
      end
      ln += (rng.rand - 0.5) * 0.04
      peak_ln = ln if t == peak
      lines << "#{t.strftime('%Y-%m-%d')},#{format('%.2f', Math.exp(ln))}\n"
      t += 86_400
    end
    File.write(File.join(dir, 'prices.csv'), lines)
  end

  def run_module(root, mod, *argv)
    Open3.capture3({ 'BTC_DATA_DIR' => root }, RbConfig.ruby,
                   File.join(ROOT, "scripts/lppl/#{mod}.rb"), '--json', *argv,
                   chdir: ROOT)
  end

  def last_json(out)
    JSON.parse(out.lines.last)
  end

  # ---- trend: read-filter + append suppression -------------------------------

  def seed_trend_cache(path)
    # h=90 pl_full rows straddling the as-of boundary (2024-06-15). The two
    # before it sit inside the trailing-year window; the 2024-06-20 row is
    # after it and must be read-filtered out of the aggregation.
    rows = []
    %w[2024-06-01 2024-06-05 2024-06-20].each do |d|
      rows << [d, 90, 'pl_full', -1.0]
      rows << [d, 90, 'pl_recent', -2.0]
      rows << [d, 90, 'rw', -2.0]
    end
    File.open(path, 'w') do |f|
      f.puts 'date,h,model,logscore'
      rows.each { |r| f.puts r.join(',') }
    end
  end

  def test_trend_as_of_read_filters_and_suppresses_append
    Dir.mktmpdir do |base|
      root  = File.join(base, 'data')
      dir   = File.join(root, 'lppl')
      write_prices(dir, Time.utc(2019, 1, 1), Time.utc(2024, 6, 30))
      cache = File.join(dir, 'trend_scores.csv')
      seed_trend_cache(cache)
      before = File.read(cache)

      out, err, st = run_module(root, 'trend', '--as-of', '2024-06-15')
      assert st.success?, "trend --as-of failed: #{err}"
      j = last_json(out)

      # 2024-06-20 is on/after AS_OF -> dropped; only the two earlier h=90
      # pl_full rows remain in the trailing-year aggregation.
      assert_equal 2, j['eval_points_1y'],
                   'rows on/after AS_OF must not reach the aggregation'
      # ts frozen to the replay midnight.
      assert_equal '2024-06-15T00:00:00Z', Time.iso8601(j['ts']).iso8601
      # append suppressed: the cache is byte-identical after a replay run.
      assert_equal before, File.read(cache), 'replay must not write trend_scores.csv'
    end
  end

  def test_trend_heals_a_torn_append_without_duplicates
    # C8 (SBI review): the dedup key was pl_full-only, so a crash between the
    # pl_full line and its group's rw line left the cache permanently
    # unbalanced -- pl_full present, rw missing, never recomputed. A rerun
    # must restore the missing rows and must NOT duplicate the survivors.
    Dir.mktmpdir do |base|
      root = File.join(base, 'data')
      dir  = File.join(root, 'lppl')
      write_prices(dir, Time.utc(2019, 1, 1), Time.utc(2024, 6, 30))
      cache = File.join(dir, 'trend_scores.csv')

      _, err, st = run_module(root, 'trend')
      assert st.success?, err

      lines = File.readlines(cache)
      torn = lines.reverse.find { |l| l.split(',')[2] == 'pl_full' }
      dkey, h, = torn.split(',')
      group = ->(l) { p = l.split(','); p[0] == dkey && p[1] == h }
      File.write(cache, lines.reject { |l| group.call(l) && !l.include?('pl_full') }.join)

      _, err2, st2 = run_module(root, 'trend')
      assert st2.success?, err2
      after = File.readlines(cache).select { |l| group.call(l) }
      counts = after.group_by { |l| l.split(',')[2] }.transform_values(&:size)
      assert_equal 1, counts['pl_full'], "pl_full duplicated: #{after.inspect}"
      assert_equal 1, counts['rw'], "rw not restored exactly once: #{after.inspect}"
    end
  end

  def test_history_as_of_refuses_without_data_dir_override
    # C6 (SBI review): --history --as-of against the LIVE data dir would
    # write backdated ledger entries despite the header's read-only claim.
    # Without BTC_DATA_DIR the combination must abort before any module runs.
    out, err, st = Open3.capture3(
      { 'BTC_DATA_DIR' => nil }, RbConfig.ruby,
      File.join(ROOT, 'scripts/lppl/lppl.rb'),
      '--as-of', '2024-06-15', '--history', '--skip-update'
    )
    refute st.success?, "must refuse: out=#{out} err=#{err}"
    assert_match(/BTC_DATA_DIR/, err + out)
  end

  def test_trend_live_run_does_append_the_cache
    # Control: without --as-of the same setup DOES grow the cache, proving the
    # suppression above is load-bearing and not a no-op.
    Dir.mktmpdir do |base|
      root = File.join(base, 'data')
      dir  = File.join(root, 'lppl')
      write_prices(dir, Time.utc(2019, 1, 1), Time.utc(2024, 6, 30))
      cache = File.join(dir, 'trend_scores.csv')
      seed_trend_cache(cache)
      before = File.read(cache)

      _, err, st = run_module(root, 'trend')
      assert st.success?, err
      refute_equal before, File.read(cache), 'a live run appends matured scores'
    end
  end

  # ---- fit: stability history read-filter ------------------------------------

  def seed_fit_history(path, entries)
    File.open(path, 'w') do |f|
      entries.each do |ts, td|
        f.puts JSON.generate(ts: ts, tc: 6090.0, m: 0.5, w: 8.6, rmse: 0.05,
                             trough_day: td, trough_px: 28_000, filters_passed: 4)
      end
    end
  end

  def test_fit_as_of_filters_history_below_as_of
    Dir.mktmpdir do |base|
      root = File.join(base, 'data')
      dir  = File.join(root, 'lppl')
      write_lppl_series(dir, Time.utc(2026, 7, 4))
      hist = File.join(dir, 'fit_history.jsonl')
      # three entries before 2026-07-04, five after it.
      entries = [['2026-07-01T10:00:00Z', 6790.0],
                 ['2026-07-02T10:00:00Z', 6795.0],
                 ['2026-07-03T10:00:00Z', 6800.0],
                 ['2026-07-04T10:00:00Z', 6805.0],
                 ['2026-07-05T10:00:00Z', 6810.0],
                 ['2026-07-06T10:00:00Z', 6815.0],
                 ['2026-07-07T10:00:00Z', 6820.0],
                 ['2026-07-08T10:00:00Z', 6825.0]]
      seed_fit_history(hist, entries)
      before = File.read(hist)

      live, err_l, st_l = run_module(root, 'fit')
      assert st_l.success?, err_l
      # all 8 entries feed the stability window -> a trough-std is reported.
      assert_kind_of Float, last_json(live)['trough_std_days']

      asof, err_a, st_a = run_module(root, 'fit', '--as-of', '2026-07-04')
      assert st_a.success?, err_a
      ja = last_json(asof)
      # only the 3 entries stamped before 2026-07-04 survive (< 4) -> no std.
      refute ja.key?('trough_std_days'),
             'entries at/after AS_OF must not enter the stability window'
      assert_equal '2026-07-04T00:00:00Z', Time.iso8601(ja['ts']).iso8601
      # history file untouched by the read-only replay.
      assert_equal before, File.read(hist)
    end
  end

  # ---- aggregator: frozen ts in --json and the ledger ------------------------

  def test_aggregator_as_of_freezes_ts_and_ledger
    Dir.mktmpdir do |base|
      root = File.join(base, 'data')
      dir  = File.join(root, 'lppl')
      write_lppl_series(dir, Time.utc(2026, 7, 4))

      out, err, st = Open3.capture3(
        { 'BTC_DATA_DIR' => root }, RbConfig.ruby,
        File.join(ROOT, 'scripts/lppl/lppl.rb'),
        '--json', '--history', '--as-of', '2026-07-02', chdir: ROOT
      )
      assert st.success?, "aggregator --as-of failed: #{err}"
      j = JSON.parse(out)
      assert_equal '2026-07-02', j['as_of']
      assert_equal '2026-07-02T00:00:00Z', Time.iso8601(j['ts']).iso8601
      j['tests'].each do |t|
        assert_equal '2026-07-02T00:00:00Z', Time.iso8601(t['detail']['ts']).iso8601,
                     "#{t['name']} module ts not frozen to AS_OF"
      end

      ledger = File.join(dir, 'ledger.jsonl')
      assert File.exist?(ledger), 'ledger not written under --history'
      line = JSON.parse(File.readlines(ledger).last)
      assert_equal '2026-07-02T00:00:00Z', Time.iso8601(line['ts']).iso8601
    end
  end

  # ---- malformed flag aborts -------------------------------------------------

  def test_malformed_as_of_aborts_with_usage
    Dir.mktmpdir do |base|
      root = File.join(base, 'data')
      write_lppl_series(File.join(root, 'lppl'), Time.utc(2026, 7, 4))
      _, err, st = Open3.capture3(
        { 'BTC_DATA_DIR' => root }, RbConfig.ruby,
        File.join(ROOT, 'scripts/lppl/lppl.rb'), '--json', '--as-of', '07/05/2026',
        chdir: ROOT
      )
      assert_equal 2, st.exitstatus, 'malformed --as-of must exit 2'
      assert_match(/usage: --as-of YYYY-MM-DD/, err)
    end
  end

  def test_impossible_calendar_date_aborts
    Dir.mktmpdir do |base|
      root = File.join(base, 'data')
      write_lppl_series(File.join(root, 'lppl'), Time.utc(2026, 7, 4))
      _, _, st = Open3.capture3(
        { 'BTC_DATA_DIR' => root }, RbConfig.ruby,
        File.join(ROOT, 'scripts/lppl/lppl.rb'), '--json', '--as-of', '2026-02-30',
        chdir: ROOT
      )
      assert_equal 2, st.exitstatus, 'well-formed but impossible date must exit 2'
    end
  end
end
