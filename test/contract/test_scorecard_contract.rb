# frozen_string_literal: true
#
# M10-6: --json field-set contract for scripts/scorecard.rb. Runs the REAL
# script offline against a throwaway BTC_DATA_DIR seeded from committed
# synthetic ledgers (test/fixtures/scorecard/*, never the real data home).
# The envelope, per-signal, ledger, and horizon-cell field sets are frozen
# from birth: additive changes must update these pins in the same commit
# (Golden Rule 5). Also pins the fail-soft contract: absent ledgers list
# every static signal with rows:0 and exit 0.

require_relative 'contract_helper'
require 'tmpdir'
require 'fileutils'

class TestScorecardContract < Minitest::Test
  FIX = File.join(ContractHelpers::ROOT, 'test', 'fixtures', 'scorecard')

  ENVELOPE_KEYS = %w[generated_at horizons signals].freeze
  SIGNAL_KEYS   = %w[ledger horizons].freeze
  LEDGER_KEYS   = %w[rows from to].freeze
  ELIGIBLE_KEYS   = %w[n n_eff eligible all bands].freeze
  INELIGIBLE_KEYS = %w[n eligible reason].freeze
  STAT_KEYS       = %w[n mean_pct pos_pct].freeze

  # Static signals present regardless of what the ledgers contain.
  STATIC_SIGNALS = %w[lppl_verdict lppl_trend lppl_envelope lppl_fit
                      scenario_regime gex_gamma_sign].freeze

  # Seed a sandbox data home in the BTC_DATA_DIR layout; yields the base.
  # `with:` selects which fixtures to copy (default all).
  def with_data(with: %i[lppl scenario gex])
    Dir.mktmpdir('mimir-scorecard') do |base|
      %w[lppl scenario gex_history].each { |d| FileUtils.mkdir_p(File.join(base, d)) }
      if with.include?(:lppl)
        FileUtils.cp(File.join(FIX, 'prices.csv'), File.join(base, 'lppl', 'prices.csv'))
        FileUtils.cp(File.join(FIX, 'lppl_ledger.jsonl'), File.join(base, 'lppl', 'ledger.jsonl'))
      end
      if with.include?(:scenario)
        FileUtils.cp(File.join(FIX, 'scenario_history.jsonl'),
                     File.join(base, 'scenario', 'history.jsonl'))
      end
      if with.include?(:gex)
        Dir.glob(File.join(FIX, 'gex_history', '*.json')).each do |p|
          FileUtils.cp(p, File.join(base, 'gex_history', File.basename(p)))
        end
      end
      yield base
    end
  end

  def test_json_field_set_contract
    with_data do |base|
      j = run_json('scripts/scorecard.rb', '--json', env: { 'BTC_DATA_DIR' => base })
      assert_contract_keys ENVELOPE_KEYS, j, 'scorecard.rb'
      assert_kind_of String, j['generated_at']
      assert Time.iso8601(j['generated_at'])
      assert_equal [7, 30, 90], j['horizons']

      sigs = j['signals']
      assert_kind_of Hash, sigs
      STATIC_SIGNALS.each { |name| assert sigs.key?(name), "missing signal #{name}" }
      # scenario module signals are derived from the scores keys present
      assert sigs.key?('scenario_macro'), 'scenario module signal not derived'

      sigs.each do |name, entry|
        assert_contract_keys SIGNAL_KEYS, entry, name
        assert_contract_keys LEDGER_KEYS, entry['ledger'], "#{name}.ledger"
        assert_equal %w[7 30 90], entry['horizons'].keys, "#{name}.horizons"
      end
    end
  end

  def test_horizon_cell_shapes_eligible_and_ineligible
    with_data do |base|
      j = run_json('scripts/scorecard.rb', '--json', env: { 'BTC_DATA_DIR' => base })
      h = j['signals']['lppl_trend']['horizons']

      # 70 daily rows spanning 69d -> h7/h30 eligible, h90 span-ineligible.
      assert h['7']['eligible']
      assert_contract_keys ELIGIBLE_KEYS, h['7'], 'eligible cell'
      assert_contract_keys STAT_KEYS, h['7']['all'], 'all stats'
      assert h['7']['bands'].any?, 'eligible cell has bands'
      h['7']['bands'].each_value { |s| assert_contract_keys STAT_KEYS, s, 'band stats' }

      refute h['90']['eligible']
      assert_contract_keys INELIGIBLE_KEYS, h['90'], 'ineligible cell'
      assert_equal 'n too small', h['90']['reason']
    end
  end

  def test_dedup_keeps_one_row_per_utc_day
    with_data do |base|
      j = run_json('scripts/scorecard.rb', '--json', env: { 'BTC_DATA_DIR' => base })
      # ledger has 71 lines (one duplicate UTC day) -> 70 deduped rows.
      led = j['signals']['lppl_trend']['ledger']
      assert_equal 70, led['rows']
      assert_equal '2026-05-01', led['from']
      assert_equal '2026-07-09', led['to']
    end
  end

  def test_absent_ledgers_list_static_signals_with_zero_rows_and_exit_zero
    with_data(with: []) do |base|
      out, err, st = run_script('scripts/scorecard.rb', '--json', env: { 'BTC_DATA_DIR' => base })
      assert st.success?, "absent ledgers must exit 0 (fail-soft): #{err}"
      j = JSON.parse(out)
      STATIC_SIGNALS.each do |name|
        assert j['signals'].key?(name), "missing static signal #{name}"
        assert_equal 0, j['signals'][name]['ledger']['rows']
        refute j['signals'][name]['horizons']['7']['eligible']
      end
    end
  end

  def test_terminal_table_renders_and_exits_zero
    with_data do |base|
      out, err, st = run_script('scripts/scorecard.rb', env: { 'BTC_DATA_DIR' => base })
      assert st.success?, err
      assert_match(/SIGNAL\s+BAND/, out)
      assert_match(/lppl_trend/, out)
      assert_match(/^sources: lppl \d+ rows/, out)
    end
  end
end
