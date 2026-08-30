# frozen_string_literal: true
#
# M12-1 (Q-20): scenario-module replay contracts -- each module under
# `--as-of DATE` computes from its dated-history source truncated to
# COMPLETE DAYS strictly before DATE, with the clock frozen to DATE
# (ts = the replay day) and nothing written. Runs the real scripts
# offline via the fake transport against the recorded fixtures; the
# no-flag byte-identity is covered by the existing per-module contracts
# (this file only exercises the flag).
#
# Modules whose replay needs a NOT-YET-RECORDED history fixture
# (funding/cb_premium/macro/stables -- M12-1b) are pinned in this file
# too but skip until `rake fixtures:record SOURCES=replay` lands them.

require_relative 'contract_helper'

class TestScenarioReplayContract < Minitest::Test
  COINGLASS_ENV = { 'COINGLASS_API_KEY' => 'contract-test-key' }.freeze

  def replay_json(mod, date, env: {})
    out, err, st = run_script("scripts/scenario/#{mod}.rb", '--json', '--as-of', date, env: env)
    assert st.success?, "#{mod} --as-of exit #{st.exitstatus}: #{err}"
    assert_equal 1, out.lines.size, "#{mod}: stdout discipline under replay"
    JSON.parse(out)
  end

  def test_bad_as_of_dates_abort
    %w[2026-2-30 2026-02-30 not-a-date].each do |bad|
      _, _, st = run_script('scripts/scenario/reserves.rb', '--json', '--as-of', bad,
                            env: COINGLASS_ENV)
      refute st.success?, "#{bad.inspect} must abort, never roll over"
    end
  end

  def test_replay_ts_is_the_replay_day
    j = replay_json('reserves', '2026-08-25', env: COINGLASS_ENV)
    assert_equal '2026-08-25T00:00:00Z', j['ts'], 'clock frozen to the replay day'
  end

  # reserves: the 130-day recorded chart ends 2026-08-29; a replay on
  # 08-25 must see complete days through 08-24 only.
  def test_reserves_replay_truncates_to_complete_days
    live   = run_json('scripts/scenario/reserves.rb', '--json', env: COINGLASS_ENV)
    replay = replay_json('reserves', '2026-08-25', env: COINGLASS_ENV)
    assert_equal '2026-08-24', replay['series']['total_mbtc'].last.first
    assert_operator replay['series']['total_mbtc'].size, :<,
                    live['series']['total_mbtc'].size
    assert_includes [-1, 0, 1], replay['score']
  end

  # positioning: the recorded fixtures span 03..12 Aug; a replay on
  # 08-10 sees 7 complete days -- WARMUP (bands need 91), series end 08-09.
  def test_positioning_replay_truncates_all_five_series
    j = replay_json('positioning', '2026-08-10', env: COINGLASS_ENV)
    assert_equal 'WARMUP', j['crowding']
    assert_equal 0, j['score']
    j['series'].each do |name, pts|
      next if pts.empty? # a series may lose all rows under a tight window

      assert_operator pts.last.first, :<=, '2026-08-09', "#{name} leaks past the cut"
    end
  end

  # etf_flows: replay rides the Coinglass leg EXCLUSIVELY (HTML has no
  # dated past) -- source says so, and the window ends the day before.
  def test_etf_flows_replay_uses_coinglass_only
    j = replay_json('etf_flows', '2026-07-01', env: COINGLASS_ENV)
    assert_equal 'coinglass', j['source']
    assert_equal '2026-06-30', j['as_of']
  end

  def test_etf_flows_replay_fails_soft_without_key
    j = replay_json('etf_flows', '2026-07-01', env: { 'COINGLASS_API_KEY' => nil })
    assert_equal true, j['unavailable'], 'no keyless replay source exists'
  end

  # onchain: the recorded window is 06-29..07-03; a replay on 07-02
  # reads MVRV from 07-01 (complete days only).
  def test_onchain_replay_ends_the_day_before
    j = replay_json('onchain_value', '2026-07-02')
    assert_match(/2026-07-01/, j['headline'])
    assert_includes [-1, 0, 1], j['score']
  end

  # hash_ribbons: the replay path needs the FULL-history fixture
  # (mempool_hashrate_all.json) -- records with SOURCES=replay.
  def test_hash_ribbons_replay
    unless File.exist?(File.join(ROOT, 'test/fixtures/mempool_hashrate_all.json'))
      skip 'mempool_hashrate_all.json not yet recorded (M12-1) -- owner: rake fixtures:record SOURCES=replay'
    end
    j = replay_json('hash_ribbons', '2026-07-01')
    assert_includes [-1, 0, 1], j['score']
    assert_match(/n\/a\z/, j['headline'], 'difficulty context skipped under replay')
  end

  # replay never appends history (staging is the backfill's job)
  def test_replay_never_writes_history
    Dir.mktmpdir('mimir-replay-nowrite') do |dir|
      run_script('scripts/scenario/reserves.rb', '--json', '--as-of', '2026-08-25',
                 '--history', env: COINGLASS_ENV.merge('BTC_DATA_DIR' => dir))
      refute File.exist?(File.join(dir, 'reserves', 'history.jsonl')),
             'replay + --history must not touch the live history'
    end
  end
end
