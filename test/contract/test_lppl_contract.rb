# frozen_string_literal: true
#
# M1-9: --json contracts for the five LPPL evidence tests, the
# aggregator, the ledger line and the status line -- the real scripts
# run offline against a SYNTHETIC price cache in a temp BTC_DATA_DIR
# (--skip-update; the shim 404s any accidental network). The synthetic
# series is deterministic (Random.new(42)): a global power law with a
# 4y oscillation from 2014 (covering envelope.rb's three historical
# trough dates), a rise into a 2026-03-01 cycle peak, then a power
# decay with a log-periodic wiggle so fit/logperiodic get a real
# post-peak window. Values are irrelevant -- these pins are field sets
# and formats, not scores.

require_relative 'contract_helper'
require 'tmpdir'
require 'fileutils'

class TestLpplContract < Minitest::Test
  BASE_KEYS      = %w[headline name score ts].freeze
  FAIL_SOFT_KEYS = %w[headline name score ts unavailable].freeze
  VERDICTS       = %w[REGIME-INTACT SUPPORTED INDETERMINATE STRESSED FALSIFIED].freeze

  GENESIS = Time.utc(2009, 1, 3)
  START   = Time.utc(2014, 1, 1)
  BUMP0   = Time.utc(2025, 1, 1)
  PEAK    = Time.utc(2026, 3, 1)
  LAST    = Time.utc(2026, 7, 4)

  DATA_ROOT = File.join(Dir.tmpdir, "mimir-lppl-contract-#{Process.pid}")
  EMPTY_ROOT = File.join(Dir.tmpdir, "mimir-lppl-empty-#{Process.pid}")
  Minitest.after_run { FileUtils.rm_rf([DATA_ROOT, EMPTY_ROOT]) }

  def self.build_prices
    dir = File.join(DATA_ROOT, 'lppl')
    path = File.join(dir, 'prices.csv')
    return if File.exist?(path)

    FileUtils.mkdir_p(dir)
    FileUtils.mkdir_p(File.join(EMPTY_ROOT, 'lppl'))
    rng = Random.new(42)
    peak_ln = nil
    lines = +"date,close\n"
    t = START
    while t <= LAST
      days = (t - GENESIS) / 86_400.0
      yrs  = (t - START) / (365.25 * 86_400)
      ln = -36.0 + 5.4 * Math.log(days) +
           0.15 * Math.sin(2 * Math::PI * yrs / 4.0)
      if t >= BUMP0 && t <= PEAK # rise into the cycle peak
        prog = (t - BUMP0) / (PEAK - BUMP0).to_f
        ln += 0.5 * prog * prog
      end
      if t > PEAK # anti-bubble tail: power decay + log-periodic wiggle
        tau = (t - PEAK) / 86_400.0
        ln = peak_ln - 0.06 * (tau**0.4) +
             0.015 * (tau**0.4) * Math.cos(8.0 * Math.log([tau, 2.5].max))
      end
      ln += (rng.rand - 0.5) * 0.04
      peak_ln = ln if t == PEAK
      lines << "#{t.strftime('%Y-%m-%d')},#{format('%.2f', Math.exp(ln))}\n"
      t += 86_400
    end
    File.write(path, lines)
  end

  def setup
    self.class.build_prices
  end

  def lppl_env(root = DATA_ROOT)
    { 'BTC_DATA_DIR' => root }
  end

  # F-9: exactly one stdout line in --json mode, parsing as one object.
  def module_json(mod, *argv, root: DATA_ROOT)
    out, err, st = run_script("scripts/lppl/#{mod}.rb", '--json', *argv,
                              env: lppl_env(root))
    assert st.success?, "#{mod} exit #{st.exitstatus}: #{err}"
    assert_equal 1, out.lines.size, "#{mod}: stdout discipline (F-9) -- got: #{out.inspect}"
    JSON.parse(out)
  end

  # test file -> [required detail keys, optional detail keys (nil-dropped
  # or run-dependent), extra argv]
  TESTS = {
    'trend'       => [%w[bf bf_by_horizon per_horizon delta_ln_age eval_points_1y],
                      %w[bootstrap], []],
    'envelope'    => [%w[ratio bound floor freeze_candidate trough_ratios
                         trend_today days_below_strong days_below_floor], [], []],
    'fit'         => [%w[omega m tc_date filters b_negative damping_ref_threshold],
                      %w[trough_date trough_px rmse_impr_pct trough_std_days
                         damping null_v2 improvement_v2], []],
    'logperiodic' => [%w[omega_peak p_value ar1_rho n_resid], [], %w[--sims 5]],
    'percentile'  => [%w[z pct_emp pct_gauss trend_px exponent ratio_to_trend
                         record prior_min_z prior_min_date days_le_p01
                         days_le_p05 envelope_pos envelope_neg], [], []]
  }.freeze

  TESTS.each do |mod, (required, optional, argv)|
    define_method("test_#{mod}_success_shape") do
      j = module_json(mod, *argv)
      assert_equal mod, j['name']
      assert_includes [-1, 0, 1], j['score']
      assert_equal RECORDED_NOW, Time.iso8601(j['ts']).iso8601
      missing = (BASE_KEYS + required) - j.keys
      assert_empty missing, "#{mod}: required --json fields absent #{missing}"
      surplus = j.keys - BASE_KEYS - required - optional
      assert_empty surplus, "#{mod}: unpinned --json fields #{surplus} (frozen contract)"
      refute j.key?('unavailable'), "#{mod}: healthy run must not carry the F-12 marker"
    end

    define_method("test_#{mod}_fail_soft_without_cache") do
      j = module_json(mod, *argv, root: EMPTY_ROOT)
      assert_contract_keys FAIL_SOFT_KEYS, j, "#{mod} fail-soft"
      assert_equal 0, j['score']
      assert_equal true, j['unavailable'] # F-12
      assert_match(/price cache/, j['headline'])
    end
  end

  # M9-1: per_horizon is an additive density-invariant view -- one entry per
  # horizon, each carrying {sum, mean_per_eval, n_evals}. The legacy bf /
  # bf_by_horizon keys ride alongside unchanged.
  def test_trend_per_horizon_shape
    j = module_json('trend')
    ph = j['per_horizon']
    assert_kind_of Hash, ph
    assert_equal %w[180 30 90], ph.keys.sort
    ph.each_value do |h|
      assert_equal %w[mean_per_eval n_evals sum], h.keys.sort
      assert_kind_of Numeric, h['sum']
      assert_kind_of Integer, h['n_evals']
    end
  end

  # M9-5: report-only fit diagnostics ride additively next to the frozen
  # four-filter verdict -- b_negative (bool, always present) and
  # damping_ref_threshold (the reference-only constant 1.0). damping itself is
  # nil-droppable (absent when C is zero). None of them touch the score.
  def test_fit_report_only_flags_shape
    j = module_json('fit')
    assert_includes [true, false], j['b_negative']
    assert_equal 1.0, j['damping_ref_threshold']
    assert_kind_of Numeric, j['damping'] if j.key?('damping')
  end

  # M9-6: the symmetric-null SHADOW rides additively -- null_v2 {tc, rmse,
  # at_grid_edge} and improvement_v2 -- next to the frozen rmse_impr_pct, which
  # must remain present and untouched. Both v2 fields are nil-droppable.
  def test_fit_symmetric_null_v2_shape
    j = module_json('fit')
    if j.key?('null_v2')
      nv = j['null_v2']
      assert_equal %w[at_grid_edge rmse tc], nv.keys.sort
      assert_kind_of Numeric, nv['rmse']
      assert_includes [true, false], nv['at_grid_edge']
      assert_match(/\A\d{4}-\d{2}-\d{2}\z/, nv['tc'])
      assert_kind_of Numeric, j['improvement_v2']
    end
  end

  # ---- aggregator ------------------------------------------------------

  STATUS_RE = %r{\ALPPL (REGIME-INTACT|SUPPORTED|INDETERMINATE|STRESSED|FALSIFIED) [+-]\d+\.\d\d BF\S+ r\S+ trough \S+ w\S+ p\S+ Z\S+@\S+\z}

  def test_aggregator_json_contract
    j = run_json('scripts/lppl/lppl.rb', '--json', '--skip-update', env: lppl_env)
    assert_contract_keys %w[composite omega_xcheck status_line tests
                            trough_stability ts verdict], j, 'lppl.rb'
    assert_kind_of Float, j['composite']
    assert_includes VERDICTS, j['verdict']
    assert_match STATUS_RE, j['status_line']
    # M9-3: omega cross-check rides along additively -- two independent omega
    # estimates and their gap; trough_stability is a first-class field.
    assert_contract_keys %w[delta fit_omega ls_omega], j['omega_xcheck'], 'omega_xcheck'
    assert j.key?('trough_stability'), 'trough_stability first-class field absent'

    assert_equal TESTS.keys.sort, j['tests'].map { |t| t['name'] }.sort
    j['tests'].each do |t|
      assert_contract_keys %w[detail headline name score w], t, 'tests[]'
      assert_includes [-1, 0, 1], t['score']
      assert_kind_of Integer, t['w']
      assert_kind_of Hash, t['detail'] # full module --json object rides along
    end
    # M8-8: stale_input is additive on --json too -- fresh cache omits it.
    refute j.key?('stale_input'), 'a fresh cache must not carry the --json marker'
  end

  # M8-8/M8-9: --json exposes stale_input:true (only) when the cache is stale,
  # so repair can read the fresh re-run's marker without touching the cache.
  def test_aggregator_json_stale_input_additive
    root = File.join(Dir.tmpdir, "mimir-lppl-json-stale-#{Process.pid}")
    FileUtils.mkdir_p(File.join(root, 'lppl'))
    FileUtils.cp(File.join(DATA_ROOT, 'lppl', 'prices.csv'),
                 File.join(root, 'lppl', 'prices.csv'))
    j = run_json('scripts/lppl/lppl.rb', '--json', '--skip-update',
                 env: lppl_env(root).merge('FAKE_NOW' => '2026-07-20T00:00:00Z'))
    assert_equal true, j['stale_input']
    assert_contract_keys %w[composite omega_xcheck stale_input status_line tests
                            trough_stability ts verdict], j,
                         'lppl.rb --json (stale)'
  ensure
    FileUtils.rm_rf(root) if root
  end

  # M6-1: --as-of is an additive replay field -- present (only) with the flag,
  # and it freezes the aggregator's ts to the replay midnight.
  def test_aggregator_as_of_json_additive
    live = run_json('scripts/lppl/lppl.rb', '--json', '--skip-update', env: lppl_env)
    refute live.key?('as_of'), 'as_of must be absent without the flag'

    j = run_json('scripts/lppl/lppl.rb', '--json', '--skip-update',
                 '--as-of', '2026-07-03', env: lppl_env)
    assert_contract_keys %w[as_of composite omega_xcheck status_line tests
                            trough_stability ts verdict], j,
                         'lppl.rb --as-of'
    assert_equal '2026-07-03', j['as_of']
    assert_equal '2026-07-03T00:00:00Z', Time.iso8601(j['ts']).iso8601
  end

  def test_aggregator_as_of_refuses_tmux
    _, err, st = run_script('scripts/lppl/lppl.rb', '--tmux', '--as-of',
                            '2026-07-03', env: lppl_env)
    refute st.success?, 'as-of + --tmux must abort (would clobber the live token)'
    assert_equal 2, st.exitstatus
    assert_match(/tmux/, err)
  end

  def test_aggregator_tmux_contract
    _, err, st = run_script('scripts/lppl/lppl.rb', '--tmux', '--skip-update',
                            env: lppl_env)
    assert st.success?, err
    assert_match STATUS_RE, File.read('/tmp/lppl.status').chomp
  end

  LEDGER_KEYS = %w[bf composite days_below_strong days_le_p01 omega p_lp
                   pct_emp ratio scores trough_date trough_px ts verdict
                   z z_record].freeze

  def test_history_ledger_line_contract
    _, err, st = run_script('scripts/lppl/lppl.rb', '--json', '--skip-update',
                            '--history', env: lppl_env)
    assert st.success?, err
    ledger = File.join(DATA_ROOT, 'lppl', 'ledger.jsonl')
    assert File.exist?(ledger), 'ledger.jsonl not written on --history'
    line = JSON.parse(File.readlines(ledger).last)
    # RECORDED_NOW (2026-07-04) vs synthetic cache last (2026-07-04): the cache
    # holds >= D-1, so this healthy line carries NO stale_input key.
    assert_contract_keys LEDGER_KEYS, line, 'ledger line'
    assert_equal TESTS.keys.sort, line['scores'].keys.sort
    refute line.key?('stale_input'), 'a fresh cache must not carry the marker'
  end

  # M8-8: stale_input is additive -- present (and true) ONLY when the cache's
  # newest row predates the run day's D-1. Isolated data dir (its own ledger)
  # + a clock far ahead of the synthetic cache's last date forces staleness.
  def test_history_ledger_line_stale_input_additive
    root = File.join(Dir.tmpdir, "mimir-lppl-stale-#{Process.pid}")
    FileUtils.mkdir_p(File.join(root, 'lppl'))
    FileUtils.cp(File.join(DATA_ROOT, 'lppl', 'prices.csv'),
                 File.join(root, 'lppl', 'prices.csv'))
    _, err, st = run_script('scripts/lppl/lppl.rb', '--json', '--skip-update',
                            '--history',
                            env: lppl_env(root).merge('FAKE_NOW' => '2026-07-20T00:00:00Z'))
    assert st.success?, err
    line = JSON.parse(File.readlines(File.join(root, 'lppl', 'ledger.jsonl')).last)
    assert_equal true, line['stale_input']
    # additive: every frozen ledger key is still present alongside the marker.
    assert_equal (LEDGER_KEYS + %w[stale_input]).sort, line.keys.sort,
                 'stale_input must be purely additive to the ledger line'
  ensure
    FileUtils.rm_rf(root) if root
  end
end
