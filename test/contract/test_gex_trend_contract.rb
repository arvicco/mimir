# frozen_string_literal: true
#
# M8-2: --json field-set contract for scripts/gex_trend.rb. Runs the real
# script offline against a throwaway BTC_DATA_DIR seeded with a few
# synthetic daily snapshots (never the real data/). The envelope, per-row,
# and stats field sets are frozen contracts from birth: additive changes
# must update these pins in the same commit (Golden Rule 5). Also pins the
# fail-soft contract: a corrupt daily file is skipped, empty history exits 0.

require_relative 'contract_helper'
require 'tmpdir'
require 'fileutils'

class TestGexTrendContract < Minitest::Test
  # M8-18: 'mstr' is an additive top-level block { series, stats } with the
  # same per-row/stats field sets as the BTC series (Golden Rule 5).
  ENVELOPE_KEYS = %w[ts days series stats mstr].freeze
  SERIES_KEYS   = %w[date spot flip flip_dist_pct cw pw net_gex regime].freeze
  STATS_KEYS    = %w[days regime regime_days transitions cw_moves pw_moves
                     flip_dist_pct_min flip_dist_pct_max flip_dist_pct_last].freeze
  MSTR_KEYS     = %w[series stats].freeze

  def snap(date, spot:, flip:, cw:, pw:, regime:, net_gex: 100_000_000)
    { 'date' => date, 'captured_at' => "#{date}T06:15:05Z",
      'btc_combined' => {
        'ts' => "#{date}T06:15:06Z", 'btc_spot' => spot,
        'combined' => {
          'net_gex_usd_per_1pct' => net_gex, 'regime' => regime,
          'gamma_flip' => flip,
          'call_wall' => { 'level' => cw, 'gex' => 1 },
          'put_wall' => { 'level' => pw, 'gex' => -1 },
          'put_call_oi_btc' => 0.6, 'instruments' => 4000
        }
      },
      # a verbatim gex_us.rb capture per underlying; the MSTR entry (walls
      # under 'strike') drives the additive 'mstr' block.
      'us' => [
        { 'ticker' => 'IBIT', 'spot' => 40.0 },
        { 'ticker' => 'MSTR', 'spot' => 100.0, 'gamma_flip' => 90.0,
          'net_gex_usd_per_1pct' => 12_000_000, 'regime' => regime,
          'call_wall' => { 'strike' => 99.0, 'gex' => 1 },
          'put_wall' => { 'strike' => 88.0, 'gex' => -1 } }
      ], 'errors' => {} }
  end

  # A sandbox data root; yields the BTC_DATA_DIR base and its gex_history dir.
  def with_history
    Dir.mktmpdir('mimir-gex-trend') do |base|
      dir = File.join(base, 'gex_history')
      FileUtils.mkdir_p(dir)
      yield base, dir
    end
  end

  def write_snap(dir, date, **kw)
    File.write(File.join(dir, "#{date}.json"), JSON.generate(snap(date, **kw)))
  end

  def test_json_field_set_contract
    with_history do |base, dir|
      write_snap(dir, '2026-07-06', spot: 62_000, flip: 61_000, cw: 64_000, pw: 60_000, regime: 'long_gamma')
      write_snap(dir, '2026-07-07', spot: 63_000, flip: 61_200, cw: 64_000, pw: 60_000, regime: 'long_gamma')
      write_snap(dir, '2026-07-08', spot: 60_000, flip: 61_500, cw: 63_000, pw: 59_000, regime: 'short_gamma')

      j = run_json('scripts/gex_trend.rb', '--json', env: { 'BTC_DATA_DIR' => base })
      assert_contract_keys ENVELOPE_KEYS, j, 'gex_trend.rb'
      assert_kind_of String, j['ts']
      assert Time.iso8601(j['ts'])
      assert_equal 3, j['days']

      assert_kind_of Array, j['series']
      assert_equal 3, j['series'].length
      j['series'].each { |r| assert_contract_keys SERIES_KEYS, r, 'series[]' }

      assert_contract_keys STATS_KEYS, j['stats'], 'stats{}'
      assert_equal 3, j['stats']['days']
      assert_equal j['days'], j['stats']['days']

      # M8-18 additive 'mstr' block: same series/stats field sets, over the
      # MSTR `us` captures (3 days present in these snapshots).
      assert_contract_keys MSTR_KEYS, j['mstr'], 'mstr{}'
      assert_kind_of Array, j['mstr']['series']
      assert_equal 3, j['mstr']['series'].length
      j['mstr']['series'].each { |r| assert_contract_keys SERIES_KEYS, r, 'mstr.series[]' }
      assert_contract_keys STATS_KEYS, j['mstr']['stats'], 'mstr.stats{}'
      assert_equal 3, j['mstr']['stats']['days']
      # walls read from call_wall/put_wall.strike (single-name chain)
      assert_equal 99.0, j['mstr']['series'].first['cw']
      assert_equal 88.0, j['mstr']['series'].first['pw']
    end
  end

  def test_days_window_keeps_last_n_files
    with_history do |base, dir|
      %w[2026-07-06 2026-07-07 2026-07-08].each do |d|
        write_snap(dir, d, spot: 62_000, flip: 61_000, cw: 64_000, pw: 60_000, regime: 'long_gamma')
      end
      j = run_json('scripts/gex_trend.rb', '--days', '2', '--json', env: { 'BTC_DATA_DIR' => base })
      assert_equal 2, j['days']
      assert_equal %w[2026-07-07 2026-07-08], j['series'].map { |r| r['date'] }
    end
  end

  def test_corrupt_daily_file_is_skipped_not_fatal
    with_history do |base, dir|
      write_snap(dir, '2026-07-06', spot: 62_000, flip: 61_000, cw: 64_000, pw: 60_000, regime: 'long_gamma')
      File.write(File.join(dir, '2026-07-07.json'), '{ this is not json')

      out, err, st = run_script('scripts/gex_trend.rb', '--json', env: { 'BTC_DATA_DIR' => base })
      assert st.success?, err
      j = JSON.parse(out)
      assert_equal 1, j['days']
    end
  end

  def test_empty_history_reports_and_exits_zero
    with_history do |base, _dir|
      out, err, st = run_script('scripts/gex_trend.rb', env: { 'BTC_DATA_DIR' => base })
      assert st.success?, 'zero usable days must still exit 0 (fail-soft)'
      assert_match(/no usable GEX snapshots/i, "#{out}#{err}")
    end
  end
end
