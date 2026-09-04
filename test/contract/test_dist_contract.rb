# frozen_string_literal: true
#
# M13-5: --json / --tmux contracts for the dist producer (skuld S-A/B).
# Field sets are frozen from birth (Golden Rule 5); values change with
# every fixture re-record and are never pinned here. The trimmed
# deribit_book_summary fixture exercises the degraded/fallback path --
# surface-fit QUALITY pins live in test/unit/test_dist.rb against the
# full-book fixture (skipped until the owner records it).

require_relative 'contract_helper'

class TestDistContract < Minitest::Test
  DIST_KEYS = %w[name ts headline date as_of scoring divergence spot
                 n_slices n_degraded calendar_violations horizons].freeze
  HORIZON_KEYS = %w[d forward median p05 p95 sigma_atm sigma_rw
                    extrapolated degraded].freeze
  UNAVAILABLE_KEYS = %w[name ts headline unavailable].freeze

  def test_dist_json_contract
    j = run_json('scripts/dist/dist.rb', '--json')
    assert_contract_keys DIST_KEYS, j, 'dist.rb'
    assert_equal 'dist', j['name']
    assert_nil j['as_of']
    assert_equal [7, 30, 90], j['horizons'].map { |h| h['d'] }
    # live run, nothing matured on a fresh ledger: summary present, empty
    assert_equal 0, j.dig('scoring', 'n_resolved')
    j['horizons'].each { |h| assert_contract_keys HORIZON_KEYS, h, 'dist horizon' }
  end

  def test_dist_tmux_contract
    _, err, st = run_script('scripts/dist/dist.rb', '--tmux')
    assert st.success?, err
    line = File.read('/tmp/dist.status')
    assert_match(/\Adist \d{4}-\d{2}-\d{2} med30 \S+ \[\S+\.\.\S+\] \| \d+ slices/, line)
  end

  def test_dist_unavailable_when_deribit_down
    j = run_json('scripts/dist/dist.rb', '--json',
                 env: { 'FAKE_HTTP_DENY' => 'deribit.com' })
    assert_contract_keys UNAVAILABLE_KEYS, j, 'dist.rb unavailable'
    assert_equal true, j['unavailable']
  end

  def test_dist_as_of_without_snapshot_is_unavailable
    j = run_json('scripts/dist/dist.rb', '--json', '--as-of', '2020-01-01')
    assert_equal true, j['unavailable']
    assert_match(/no snapshot/, j['headline'])
  end

  # Same-day re-run re-emits (one ledger row, identical horizons) and a
  # replay from the day's own snapshot reproduces the organic run
  # EXACTLY -- the M12 replay-fidelity standard applied to dist.
  def test_dist_same_day_rerun_and_replay_reproduce_the_organic_run
    Dir.mktmpdir('mimir-dist-data') do |data|
      env = { 'BTC_DATA_DIR' => data }
      first = run_json('scripts/dist/dist.rb', '--json', env: env)
      again = run_json('scripts/dist/dist.rb', '--json', env: env)
      assert_equal first['horizons'], again['horizons']
      assert_equal 1, File.readlines(File.join(data, 'dist', 'ledger.jsonl')).size

      replay = run_json('scripts/dist/dist.rb', '--json',
                        '--as-of', first['date'], env: env)
      assert_equal first['date'], replay['as_of']
      assert_equal first['horizons'], replay['horizons']
      assert_equal first['spot'], replay['spot']
    end
  end
end
