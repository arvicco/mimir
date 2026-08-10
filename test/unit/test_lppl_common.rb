# frozen_string_literal: true

# Seed characterization test for Phase 0: pins the numerical behavior of
# Lppl::RangeReg and Lppl.gauss_solve from scripts/lppl/common.rb.
# Pattern to replicate for bs_gamma, instrument parsing, envelope fits,
# and Lomb-Scargle (synthetic sinusoid).

require_relative '../test_helper'
require_relative '../../scripts/lppl/common'
require 'tmpdir'

class TestRangeReg < Minitest::Test
  def test_recovers_exact_line
    xs = (1..50).map { |i| Math.log(i.to_f) }
    ys = xs.map { |x| 2.5 + 1.7 * x }
    f  = Lppl::RangeReg.new(xs, ys).fit(0, xs.size - 1)

    assert_close 1.7, f[:slope], 1e-9
    assert_close 2.5, f[:icept], 1e-9
    assert_close 0.0, f[:sse],   1e-9
  end

  def test_sse_matches_direct_computation
    rng = Random.new(7)
    xs  = (1..200).map { |i| Math.log(i + 1.0) }
    ys  = xs.map { |x| 1.0 + 0.5 * x + (rng.rand - 0.5) * 0.2 }
    a   = 40
    b   = 160
    f   = Lppl::RangeReg.new(xs, ys).fit(a, b)

    direct = (a..b).inject(0.0) do |s, i|
      s + (ys[i] - f[:icept] - f[:slope] * xs[i])**2
    end
    assert_close direct, f[:sse], 1e-8
  end

  def test_range_subset_differs_from_full
    xs = (1..100).map { |i| Math.log(i.to_f) }
    ys = xs.each_with_index.map { |x, i| x * (i < 50 ? 1.0 : 2.0) }
    r  = Lppl::RangeReg.new(xs, ys)
    refute_equal r.fit(0, 49)[:slope].round(6), r.fit(50, 99)[:slope].round(6)
  end

  def test_degenerate_range_returns_nil
    xs = [1.0, 2.0]
    assert_nil Lppl::RangeReg.new(xs, xs).fit(0, 1)
  end
end

class TestGaussSolve < Minitest::Test
  def test_solves_known_4x4_system
    a = [[2.0, 1.0, 0.0, 0.0],
         [1.0, 3.0, 1.0, 0.0],
         [0.0, 1.0, 4.0, 1.0],
         [0.0, 0.0, 1.0, 5.0]]
    x_true = [1.0, -2.0, 3.0, -4.0]
    b = a.map { |row| row.each_with_index.inject(0.0) { |s, (v, j)| s + v * x_true[j] } }

    x = Lppl.gauss_solve(a, b)
    x.each_with_index { |v, i| assert_close x_true[i], v, 1e-9 }
  end

  def test_singular_returns_nil
    a = [[1.0, 2.0], [2.0, 4.0]]
    assert_nil Lppl.gauss_solve(a, [1.0, 2.0])
  end
end

# M0-6 tolerance policy: detected frequencies are pinned to the scan
# grid (step 0.1 -> exact grid-point equality for on-grid tones);
# powers/parameters pinned to 1e-9 of precomputed references.
class TestLomb < Minitest::Test
  GRID = (2.0..20.0).step(0.1).to_a # logperiodic.rb's grid

  def test_pure_tone_peak_lands_on_true_frequency
    u = Array.new(300) { |i| Math.log(3.0 + i * 1.3) }
    r = u.map { |x| Math.cos(7.5 * x) }
    _, power, w_peak = Lppl.lomb(u, r, GRID)
    assert_close 7.5, w_peak, 1e-12
    assert_close 146.81424555, power, 1e-6
  end

  def test_seeded_white_noise_peak_stays_insignificant
    rng = Random.new(42)
    u = Array.new(200) { |i| Math.log(3.0 + i * 1.7) }
    r = Array.new(200) { rng.rand - 0.5 }
    _, power, = Lppl.lomb(u, r, GRID)
    assert_close 2.95047054749, power, 1e-6
    assert_operator power, :<, 10.0 # far below any tone; guards the pval logic
  end

  def test_zero_variance_returns_empty
    u = Array.new(10) { |i| Math.log(2.0 + i) }
    assert_equal [[], 0.0, 0.0], Lppl.lomb(u, Array.new(10, 1.0), GRID)
  end
end

class TestReciprocalEnvelope < Minitest::Test
  def test_recovers_exact_on_grid_decay
    ages  = (1..60).map { |i| i * 0.25 }
    abs_r = ages.map { |a| 2.0 / (a + 3.0) }
    f = Lppl.reciprocal_envelope(abs_r, ages)
    assert_close 3.0, f[:b]
    assert_close 2.0, f[:a], 1e-9
    assert_close 0.0, f[:sse], 1e-12
  end

  def test_off_grid_b_picks_nearest_grid_point
    ages  = (1..60).map { |i| i * 0.25 }
    abs_r = ages.map { |a| 2.0 / (a + 3.2) }
    f = Lppl.reciprocal_envelope(abs_r, ages)
    assert_close 3.0, f[:b] # nearest 0.5-grid point below 3.2
    assert_close 1.92816511287, f[:a], 1e-9
    assert_operator f[:sse], :>, 0.0
  end

  def test_empty_input_returns_nil
    assert_nil Lppl.reciprocal_envelope([], [])
  end
end

# M6-1: the --as-of replay seams in common.rb, exercised directly. as_of
# memoizes off ARGV, so each case swaps ARGV and clears the memo; load_prices
# is pointed at a throwaway cache (never the real data dir) via the PRICES
# constant. Characterization first (unfiltered), then the truncation.
class TestAsOfSeam < Minitest::Test
  CACHE = <<~CSV
    date,close
    2020-01-01,7000.0
    2020-01-02,0.01
    2020-01-03,7200.5
    2020-06-01,9000.0
    2020-06-02,9100.0
  CSV

  def reset_memo
    Lppl.remove_instance_variable(:@as_of) if Lppl.instance_variable_defined?(:@as_of)
  end

  def with_argv(argv)
    old = ARGV.dup
    ARGV.replace(argv)
    reset_memo
    yield
  ensure
    ARGV.replace(old)
    reset_memo
  end

  def with_prices(csv)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'prices.csv')
      File.write(path, csv)
      old = Lppl::PRICES
      silence { Lppl.const_set(:PRICES, path) }
      begin
        yield
      ensure
        silence { Lppl.const_set(:PRICES, old) }
      end
    end
  end

  def silence
    v = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = v
  end

  # ---- parse -----------------------------------------------------------------
  def test_absent_flag_is_nil
    with_argv(['--json']) do
      assert_nil Lppl.as_of
      assert_operator (Time.now.utc - Lppl.now_utc).abs, :<, 5 # now_utc falls back
    end
  end

  def test_valid_date_parses_to_utc_midnight
    with_argv(['--json', '--as-of', '2026-07-05']) do
      assert_equal Time.utc(2026, 7, 5), Lppl.as_of
      assert_equal Time.utc(2026, 7, 5), Lppl.now_utc # frozen clock
    end
  end

  # ---- load_prices: characterization then truncation -------------------------
  def test_load_prices_unfiltered_drops_dust_orders_ascending
    with_argv([]) do
      with_prices(CACHE) do
        p = Lppl.load_prices
        assert_equal %w[2020-01-01 2020-01-03 2020-06-01 2020-06-02],
                     p[:dates].map { |t| t.strftime('%Y-%m-%d') }
        assert_equal 4, p[:px].size # the 0.01 dust row is gone
      end
    end
  end

  def test_load_prices_truncates_strictly_before_as_of
    with_argv(['--as-of', '2020-06-01']) do
      with_prices(CACHE) do
        p = Lppl.load_prices
        # strict <: the row dated ON the as-of day and the one after it drop.
        assert_equal %w[2020-01-01 2020-01-03],
                     p[:dates].map { |t| t.strftime('%Y-%m-%d') }
      end
    end
  end
end

class TestAtomicWrite < Minitest::Test
  # C5 (SBI review): prices.csv was rewritten in place in production cron; a
  # crash mid-write corrupts the suite's single source of truth. The helper
  # writes a same-directory temp file and renames it over the target.
  def test_success_replaces_content_and_leaves_no_temp
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'prices.csv')
      File.write(path, "old\n")
      Lppl.atomic_write(path) { |f| f.puts 'new' }
      assert_equal "new\n", File.read(path)
      assert_equal ['prices.csv'], Dir.children(dir)
    end
  end

  def test_crash_inside_block_leaves_original_intact
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'prices.csv')
      File.write(path, "old\n")
      assert_raises(RuntimeError) do
        Lppl.atomic_write(path) do |f|
          f.puts 'half-written'
          raise 'crash mid-write'
        end
      end
      assert_equal "old\n", File.read(path)
      assert_equal ['prices.csv'], Dir.children(dir), 'temp file must be cleaned up'
    end
  end
end
