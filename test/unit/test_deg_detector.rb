# frozen_string_literal: true

# test_deg_detector.rb -- Publish::DegDetector (M14-2): the incident replay
# (venues vanish from gex:combined + an all-null MSTR vol:spread leg), the
# 14-day norm window, optional-key skipping, dry runs, census raises, and
# the state file round-trip / corrupt-file reset. Frozen clock, tmpdirs,
# real payload fixtures; no network.

require_relative '../test_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../../publish/deg_detector'

class TestDegDetector < Minitest::Test
  NOW  = Time.utc(2026, 10, 12, 10, 0, 0)
  RUN  = 2 * 3600 # bi-hourly cadence
  DAY  = 86_400
  DD   = Publish::DegDetector
  PAYLOADS = File.expand_path('../fixtures/payloads', __dir__)

  def setup
    @dir  = Dir.mktmpdir('mimir-deg')
    @path = File.join(@dir, 'ops', 'deg_state.json')
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def load_payload(key)
    JSON.parse(File.read(File.join(PAYLOADS, "payload_#{key.tr(':', '_')}.json")))
  end

  def envelopes(payloads) = payloads.transform_values { |p| { 'payload' => p } }

  def healthy
    { 'gex:combined' => load_payload('gex:combined'), 'vol:spread' => load_payload('vol:spread') }
  end

  # The incident shape: IBIT + FBTC vanish from venues[]; every MSTR leg null.
  def incident
    gex = load_payload('gex:combined')
    gex['venues'].reject! { |v| %w[IBIT FBTC].include?(v['name']) }
    spread = load_payload('vol:spread')
    spread['tenors'].each { |t| t['mstr'] = { 'expiry_d' => nil, 'atm_iv' => nil, 'reason' => 'no chain' } }
    { 'gex:combined' => gex, 'vol:spread' => spread }
  end

  def live(payloads, now)
    DD.run(envelopes(payloads), now: now, dry_run: false, path: @path)
  end

  def streak(key) = JSON.parse(File.read(@path))['keys'][key]['streak']

  # ---- incident replay ----------------------------------------------------

  def test_incident_replay_streaks_advance_one_through_six
    live(healthy, NOW) # seeds the seen-leg norm
    (1..6).each do |i|
      live(incident, NOW + i * RUN)
      assert_equal i, streak('gex:combined'), "gex streak at run #{i}"
      assert_equal i, streak('vol:spread'), "spread streak at run #{i}"
    end
  end

  def test_incident_replay_marker_appears_at_run_six_not_five
    live(healthy, NOW)
    marks = (1..6).map { |i| live(incident, NOW + i * RUN) }
    assert_equal [], marks[4], 'run 5: still under the threshold'
    assert_equal %w[gex:combined vol:spread], marks[5], 'run 6: both keys marked'
  end

  def test_incident_replay_healed_run_clears_marker_and_streak
    live(healthy, NOW)
    (1..6).each { |i| live(incident, NOW + i * RUN) }
    assert_equal [], live(healthy, NOW + 7 * RUN)
    assert_equal 0, streak('gex:combined')
    assert_equal 0, streak('vol:spread')
  end

  def test_dead_leg_is_degraded_without_a_seeded_norm
    st, marked = DD.evaluate({}, { 'vol:spread' => incident['vol:spread'] }, now: NOW)
    assert_empty marked
    assert_equal 1, st['keys']['vol:spread']['streak']
  end

  def test_healthy_first_run_is_clean
    st, marked = DD.evaluate({}, healthy, now: NOW)
    assert_empty marked
    assert_equal 0, st['keys']['gex:combined']['streak']
    assert_equal '2026-10-12', st['keys']['gex:combined']['legs']['IBIT']
  end

  # ---- 14-day norm window -------------------------------------------------

  def seeded_with_extra_leg(days_ago)
    legs = healthy['gex:combined']['venues'].to_h { |v| [v['name'], '2026-10-12'] }
    legs['GONE'] = (NOW.to_date - days_ago).iso8601
    { 'v' => 1, 'keys' => { 'gex:combined' => { 'legs' => legs, 'streak' => 0 } } }
  end

  def test_leg_last_seen_15_days_ago_falls_out_of_the_norm
    st, = DD.evaluate(seeded_with_extra_leg(15), { 'gex:combined' => healthy['gex:combined'] }, now: NOW)
    assert_equal 0, st['keys']['gex:combined']['streak']
    refute st['keys']['gex:combined']['legs'].key?('GONE'), 'pruned from the state'
  end

  def test_leg_last_seen_13_days_ago_still_counts_as_missing
    st, = DD.evaluate(seeded_with_extra_leg(13), { 'gex:combined' => healthy['gex:combined'] }, now: NOW)
    assert_equal 1, st['keys']['gex:combined']['streak']
  end

  # ---- skipping -----------------------------------------------------------

  def test_optional_reserves_absent_is_skipped_with_no_streak
    st, marked = DD.evaluate({}, healthy, now: NOW)
    refute st['keys'].key?('reserves:latest')
    assert_empty marked
  end

  def test_absent_key_keeps_its_streak_untouched
    prior = { 'v' => 1, 'keys' => { 'reserves:latest' => { 'legs' => {}, 'streak' => 4 } } }
    st, = DD.evaluate(prior, healthy, now: NOW)
    assert_equal 4, st['keys']['reserves:latest']['streak']
  end

  # ---- dry runs -----------------------------------------------------------

  def test_dry_run_writes_no_state_and_advances_nothing
    live(healthy, NOW)
    before = File.read(@path)
    assert_equal [], DD.run(envelopes(incident), now: NOW + RUN, dry_run: true, path: @path)
    assert_equal before, File.read(@path)
  end

  def test_dry_run_creates_no_state_file
    DD.run(envelopes(incident), now: NOW, dry_run: true, path: @path)
    refute File.exist?(@path)
  end

  def test_dry_run_reports_an_already_tripped_streak_read_only
    # review fix 2026-10-12: dry runs mirror OLD/BLIND -- saved tripped
    # streaks stay visible, but nothing advances and nothing is written.
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, JSON.generate(
                        'v' => 1,
                        'keys' => { 'gex:combined' => { 'legs' => {}, 'streak' => 6 } }
                      ))
    before = File.read(@path)
    assert_equal ['gex:combined'],
                 DD.run(envelopes(healthy), now: NOW, dry_run: true, path: @path)
    assert_equal before, File.read(@path)
  end

  def test_dry_run_does_not_report_a_sub_threshold_streak
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, JSON.generate(
                        'v' => 1,
                        'keys' => { 'gex:combined' => { 'legs' => {}, 'streak' => 5 } }
                      ))
    assert_equal [], DD.run(envelopes(incident), now: NOW, dry_run: true, path: @path)
  end

  # ---- unexpected shape ---------------------------------------------------

  def test_census_raise_counts_as_degraded_not_a_crash
    st, = DD.evaluate({}, { 'gex:combined' => { 'venues' => 'not-a-list' } }, now: NOW)
    assert_equal 1, st['keys']['gex:combined']['streak']
  end

  # ---- state file ---------------------------------------------------------

  def test_state_file_round_trip
    live(incident, NOW)
    st = JSON.parse(File.read(@path))
    assert_equal 1, st['v']
    assert_equal DD.load_state(@path), st
    assert_equal '2026-10-12', st['keys']['gex:combined']['legs']['Deribit']
    refute File.exist?(@path + '.tmp')
  end

  def test_corrupt_state_file_resets_with_a_warning
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, '{{{ not json')
    out, err = capture_io { live(healthy, NOW) }
    assert_empty out
    assert_includes err, 'deg state reset (JSON::ParserError)'
    assert_equal 0, streak('gex:combined')
  end

  def test_wrong_shaped_state_file_resets_with_a_warning
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, '[1,2,3]')
    _, err = capture_io { live(healthy, NOW) }
    assert_includes err, 'deg state reset (TypeError)'
  end

  def test_default_state_path_follows_the_data_dir
    prev = ENV['BTC_DATA_DIR']
    ENV['BTC_DATA_DIR'] = @dir
    assert_equal File.join(@dir, 'ops', 'deg_state.json'), DD.state_path
  ensure
    ENV['BTC_DATA_DIR'] = prev
  end

  def test_blessed_constants
    assert_equal 14, DD::WINDOW_DAYS
    assert_equal 6, DD::STREAK_RUNS
  end
end
