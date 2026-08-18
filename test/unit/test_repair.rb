# frozen_string_literal: true
#
# test_repair.rb -- unit tests for Ops::Repair (M8-9).
#
# The decision layer (plan + predicates) is pure -- tested on synthetic
# tail lines / snapshot states with no IO. The runner is integration-tested
# against a sandboxed BTC_DATA_DIR with seeded artifacts and INJECTED suite
# and snapshot runners (no real subprocess, no network): a blind scenario
# tail + a stale lppl tail + an errored GEX snapshot, all dated today, are
# healed and logged; a healthy scan is silent; a re-run that stays broken
# rewrites nothing.

require_relative '../test_helper'
require_relative '../../ops/repair'
require 'tmpdir'
require 'json'
require 'stringio'

class TestRepair < Minitest::Test
  TODAY = '2026-07-13'
  NOW   = Time.utc(2026, 7, 13, 12, 0, 0).freeze

  def scen_line(ts:, blind: nil, unavailable: nil, composite: 0.2, regime: 'BASE')
    h = { 'ts' => ts, 'composite' => composite, 'regime' => regime,
          'scores' => { 'etf_flows' => 1, 'macro' => 0 } }
    h['blind'] = true if blind
    h['unavailable'] = unavailable if unavailable
    h
  end

  def ledger_line(ts:, stale: nil)
    h = { 'ts' => ts, 'composite' => -0.1, 'verdict' => 'INDETERMINATE' }
    h['stale_input'] = true if stale
    h
  end

  # ---- decision layer (pure) ------------------------------------------

  def test_plan_scenario_blind_today_triggers_scenario
    actions = Ops::Repair.plan(
      today: TODAY,
      scenario_tail: scen_line(ts: "#{TODAY}T04:45:00Z", blind: true),
      lppl_tail: ledger_line(ts: "#{TODAY}T04:50:00Z"),
      gex_state: :clean, vol_state: :clean
    )
    assert_equal [:scenario], actions
  end

  def test_plan_scenario_blind_yesterday_no_action
    actions = Ops::Repair.plan(
      today: TODAY,
      scenario_tail: scen_line(ts: '2026-07-12T04:45:00Z', blind: true),
      lppl_tail: nil, gex_state: :clean, vol_state: :clean
    )
    assert_empty actions
  end

  # Owner ruling 2026-08-18 (the 7-of-8-down morning the weight-0
  # positioning module kept from being marked blind): ANY degraded row
  # dated today is a repair trigger; the heal itself only ever rewrites
  # when the fresh run is strictly better, so partial days converge and
  # never flap.
  def test_plan_partial_unavailable_today_triggers_scenario
    actions = Ops::Repair.plan(
      today: TODAY,
      scenario_tail: scen_line(ts: "#{TODAY}T04:45:00Z", unavailable: %w[macro]),
      lppl_tail: nil, gex_state: :clean, vol_state: :clean
    )
    assert_equal [:scenario], actions,
                 'a degraded (partially unavailable) today-row is a repair trigger'
  end

  def test_plan_partial_unavailable_yesterday_no_action
    actions = Ops::Repair.plan(
      today: TODAY,
      scenario_tail: scen_line(ts: '2026-07-12T04:45:00Z', unavailable: %w[macro]),
      lppl_tail: nil, gex_state: :clean, vol_state: :clean
    )
    assert_empty actions, "yesterday's damage is a permanent, marked gap"
  end

  # ---- weighted blind marker (owner ruling 2026-08-18) -----------------
  # blind == every WEIGHTED module down. A live weight-0 module (M10-3
  # positioning, display-only) cannot rescue a composite computed from
  # zero live inputs -- that is exactly the row this ruling came from.

  def test_scenario_line_blind_when_all_weighted_modules_down
    j = JSON.parse(scenario_json_mods(
                     [['etf_flows', 3, true], ['macro', 2, true], ['positioning', 0, false]]
                   ))
    row = Ops::Repair.scenario_line(j)
    assert_equal true, row['blind'], 'weight-0 survivor must not defeat the blind marker'
    refute row.key?('unavailable'), 'blind and unavailable are mutually exclusive (M8-8 shape)'
  end

  def test_scenario_line_partial_weighted_down_records_unavailable
    j = JSON.parse(scenario_json_mods(
                     [['etf_flows', 3, true], ['macro', 2, false], ['positioning', 0, false]]
                   ))
    row = Ops::Repair.scenario_line(j)
    refute row.key?('blind')
    assert_equal %w[etf_flows], row['unavailable']
  end

  def test_scenario_line_all_modules_down_is_still_blind
    j = JSON.parse(scenario_json_mods(
                     [['etf_flows', 3, true], ['macro', 2, true], ['positioning', 0, true]]
                   ))
    assert_equal true, Ops::Repair.scenario_line(j)['blind']
  end

  def test_plan_lppl_stale_today_triggers_lppl
    actions = Ops::Repair.plan(
      today: TODAY, scenario_tail: nil,
      lppl_tail: ledger_line(ts: "#{TODAY}T04:50:00Z", stale: true),
      gex_state: :clean, vol_state: :clean
    )
    assert_equal [:lppl], actions
  end

  def test_plan_snapshot_states
    assert_equal [:gex, :vol], Ops::Repair.plan(
      today: TODAY, scenario_tail: nil, lppl_tail: nil,
      gex_state: :missing, vol_state: :errored
    )
    assert_empty Ops::Repair.plan(
      today: TODAY, scenario_tail: nil, lppl_tail: nil,
      gex_state: :clean, vol_state: :clean
    )
  end

  def test_plan_healthy_everything_is_empty
    assert_empty Ops::Repair.plan(
      today: TODAY,
      scenario_tail: scen_line(ts: "#{TODAY}T04:45:00Z"),
      lppl_tail: ledger_line(ts: "#{TODAY}T04:50:00Z"),
      gex_state: :clean, vol_state: :clean
    )
  end

  def test_snapshot_repairable_predicate
    assert Ops::Repair.snapshot_repairable?(:missing)
    assert Ops::Repair.snapshot_repairable?(:errored)
    refute Ops::Repair.snapshot_repairable?(:clean)
  end

  # ---- heal rule: only ever rewrite to a strictly better row -----------

  def test_run_heals_degraded_row_when_fresh_run_is_strictly_better
    with_sandbox do |root|
      scen = seed(root, 'scenario', 'history.jsonl',
                  [scen_line(ts: "#{TODAY}T04:45:00Z", unavailable: %w[etf_flows macro])])
      seed_clean_snapshots(root)
      out = StringIO.new
      Ops::Repair.run(
        now: NOW, out: out,
        suite_runner: suite_runner(
          scenario: scenario_json_mods([['etf_flows', 3, false], ['macro', 2, false]]),
          lppl: lppl_json(stale: false)
        ),
        snapshot_runner: snapshot_runner
      )
      tail = JSON.parse(File.readlines(scen).last)
      assert_equal "#{TODAY}T12:00:00Z", tail['ts'], 'today-row rewritten from the fresh run'
      refute tail.key?('unavailable')
      assert_includes out.string, 'REPAIRED scenario:history'
    end
  end

  def test_run_leaves_degraded_row_when_fresh_run_is_no_better
    with_sandbox do |root|
      scen = seed(root, 'scenario', 'history.jsonl',
                  [scen_line(ts: "#{TODAY}T04:45:00Z", unavailable: %w[etf_flows macro])])
      seed_clean_snapshots(root)
      out = StringIO.new
      Ops::Repair.run(
        now: NOW, out: out,
        suite_runner: suite_runner(
          scenario: scenario_json_mods([['etf_flows', 3, true], ['macro', 2, true]]),
          lppl: lppl_json(stale: false)
        ),
        snapshot_runner: snapshot_runner
      )
      tail = JSON.parse(File.readlines(scen).last)
      assert_equal "#{TODAY}T04:45:00Z", tail['ts'], 'an equally-degraded fresh run rewrites nothing'
      refute_includes out.string, 'REPAIRED scenario:history'
    end
  end

  def seed_clean_snapshots(root)
    seed(root, 'gex_history', "#{TODAY}.json",
         [JSON.generate('date' => TODAY, 'captured_at' => "#{TODAY}T06:15:00Z", 'errors' => {})])
    seed(root, 'vol_history', "#{TODAY}.json", [JSON.generate('date' => TODAY, 'errors' => {})])
  end

  # ---- fake --json payloads -------------------------------------------

  # modules spec: [[name, weight, down], ...] -> scenario --json string.
  def scenario_json_mods(mods, ts: "#{TODAY}T12:00:00Z")
    list = mods.map do |name, w, down|
      { 'mod' => name, 'w' => w, 'score' => down ? 0 : 1, 'headline' => 'x',
        'unavailable' => down }
    end
    JSON.generate('ts' => ts, 'composite' => 0.1, 'regime' => 'NEUTRAL',
                  'modules' => list)
  end

  def scenario_json(unavailable_all:)
    mods = %w[etf_flows macro].map do |m|
      { 'mod' => m, 'w' => 2, 'score' => unavailable_all ? 0 : 1,
        'headline' => 'x', 'unavailable' => unavailable_all }
    end
    JSON.generate('ts' => "#{TODAY}T12:00:00Z",
                  'composite' => unavailable_all ? 0.0 : 0.4,
                  'regime' => unavailable_all ? 'NEUTRAL' : 'RECOVERY',
                  'modules' => mods)
  end

  def lppl_json(stale:)
    detail = {
      'trend' => { 'bf' => 1.2 }, 'envelope' => { 'ratio' => 0.8, 'days_below_strong' => 3 },
      'fit' => { 'trough_date' => '2026-03-01', 'trough_px' => 41_000, 'omega' => 6.5 },
      'logperiodic' => { 'p_value' => 0.3 },
      'percentile' => { 'z' => -1.1, 'pct_emp' => 12.0, 'record' => false, 'days_le_p01' => 2 }
    }
    tests = %w[trend envelope fit logperiodic percentile].map do |n|
      { 'name' => n, 'w' => 2, 'score' => 0, 'headline' => 'x', 'detail' => detail[n] }
    end
    h = { 'ts' => "#{TODAY}T12:00:00Z", 'composite' => -0.1,
          'verdict' => 'INDETERMINATE', 'status_line' => 'LPPL ...', 'tests' => tests }
    h['stale_input'] = true if stale
    JSON.generate(h)
  end

  # suite_runner that answers scenario/lppl argv with the given json strings.
  def suite_runner(scenario:, lppl:)
    lambda do |argv, _to|
      if argv == Ops::Repair::SCENARIO_ARGV then scenario
      elsif argv == Ops::Repair::LPPL_ARGV then lppl
      else raise "unexpected argv #{argv.inspect}"
      end
    end
  end

  BTC_JSON = JSON.generate('venues' => [{ 'name' => 'DERI' }]).freeze
  US_JSON  = JSON.generate([{ 'ticker' => 'IBIT' }]).freeze

  # snapshot_runner: returns btc/us (GEX, 2 calls) or vol (1 call) good json.
  def snapshot_runner
    lambda do |argv, _to|
      if argv.include?('scripts/vol.rb')
        JSON.generate('spot' => 1)
      elsif argv.include?('scripts/gex_btc_combined.rb')
        BTC_JSON
      else
        US_JSON
      end
    end
  end

  def with_sandbox
    Dir.mktmpdir('mimir-repair') do |root|
      old = ENV['BTC_DATA_DIR']
      ENV['BTC_DATA_DIR'] = root
      begin
        yield root
      ensure
        old ? ENV['BTC_DATA_DIR'] = old : ENV.delete('BTC_DATA_DIR')
      end
    end
  end

  def seed(root, sub, file, lines)
    dir = File.join(root, sub)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, file)
    File.write(path, lines.map { |l| l.is_a?(String) ? l : JSON.generate(l) }.join("\n") + "\n")
    path
  end

  # ---- runner integration ---------------------------------------------

  # Blind scenario + stale lppl + errored GEX, all today -> all healed,
  # each logged once, and unrelated (older) history lines preserved.
  def test_run_heals_all_todays_gaps
    with_sandbox do |root|
      keep = scen_line(ts: '2026-07-12T04:45:00Z')
      scen = seed(root, 'scenario', 'history.jsonl',
                  [keep, scen_line(ts: "#{TODAY}T04:45:00Z", blind: true)])
      ledger = seed(root, 'lppl', 'ledger.jsonl',
                    [ledger_line(ts: "#{TODAY}T04:50:00Z", stale: true)])
      gex = seed(root, 'gex_history', "#{TODAY}.json",
                 [JSON.generate('date' => TODAY, 'captured_at' => "#{TODAY}T06:15:00Z",
                                'btc_combined' => nil, 'us' => nil,
                                'errors' => { 'btc_combined' => 'outage', 'us' => 'outage' })])
      seed(root, 'vol_history', "#{TODAY}.json", [JSON.generate('date' => TODAY, 'errors' => {})])

      out = StringIO.new
      healed = Ops::Repair.run(
        now: NOW, out: out,
        suite_runner: suite_runner(scenario: scenario_json(unavailable_all: false),
                                   lppl: lppl_json(stale: false)),
        snapshot_runner: snapshot_runner
      )

      assert_equal %w[scenario:history lppl:ledger gex:snapshot].sort, healed.sort

      scen_lines = File.readlines(scen)
      assert_equal 2, scen_lines.size, 'other history lines must be preserved'
      assert_equal keep, JSON.parse(scen_lines[0]), 'the older line is untouched'
      fresh = JSON.parse(scen_lines[1])
      refute fresh.key?('blind'), 'the blind tail must be healed'
      assert_equal "#{TODAY}T12:00:00Z", fresh['ts'], 'the rewritten line carries the fresh ts'

      refute JSON.parse(File.readlines(ledger).last).key?('stale_input')
      assert_equal({}, JSON.parse(File.read(gex))['errors'], 'gex snapshot re-captured clean')

      log = out.string
      assert_match(/REPAIRED scenario:history 2026-07-13T04:45:00Z -> 2026-07-13T12:00:00Z/, log)
      assert_match(/REPAIRED lppl:ledger 2026-07-13T04:50:00Z -> 2026-07-13T12:00:00Z/, log)
      assert_match(/REPAIRED gex:snapshot 2026-07-13T06:15:00Z -> /, log)
    end
  end

  # Healthy scan: nothing to do -> no rewrite, NO output (quiet).
  def test_run_healthy_is_silent
    with_sandbox do |root|
      seed(root, 'scenario', 'history.jsonl', [scen_line(ts: "#{TODAY}T04:45:00Z")])
      seed(root, 'lppl', 'ledger.jsonl', [ledger_line(ts: "#{TODAY}T04:50:00Z")])
      seed(root, 'gex_history', "#{TODAY}.json",
           [JSON.generate('date' => TODAY, 'errors' => {})])
      seed(root, 'vol_history', "#{TODAY}.json",
           [JSON.generate('date' => TODAY, 'errors' => {})])

      out = StringIO.new
      healed = Ops::Repair.run(now: NOW, out: out,
                               suite_runner: suite_runner(scenario: '{}', lppl: '{}'),
                               snapshot_runner: ->(_a, _t) { raise 'must not capture' })
      assert_empty healed
      assert_equal '', out.string, 'a clean scan logs nothing'
    end
  end

  # A re-run that is STILL blind heals nothing and stays quiet (retry later).
  def test_run_still_blind_rewrites_nothing
    with_sandbox do |root|
      scen = seed(root, 'scenario', 'history.jsonl',
                  [scen_line(ts: "#{TODAY}T04:45:00Z", blind: true)])
      out = StringIO.new
      healed = Ops::Repair.run(
        now: NOW, out: out,
        suite_runner: suite_runner(scenario: scenario_json(unavailable_all: true), lppl: '{}'),
        snapshot_runner: ->(_a, _t) { raise 'no snapshot expected' }
      )
      assert_empty healed
      assert_equal '', out.string
      assert_equal true, JSON.parse(File.readlines(scen).last)['blind'],
                   'a still-blind re-run leaves the marked line in place'
    end
  end

  # Missing snapshot on a fresh day is repairable any time today.
  def test_run_captures_missing_snapshot
    with_sandbox do |root|
      out = StringIO.new
      healed = Ops::Repair.run(now: NOW, out: out,
                               suite_runner: suite_runner(scenario: '{}', lppl: '{}'),
                               snapshot_runner: snapshot_runner)
      assert_includes healed, 'gex:snapshot'
      assert_includes healed, 'vol:snapshot'
      assert_match(/REPAIRED gex:snapshot missing -> /, out.string)
    end
  end

  # A repair-step exception is contained: other actions still run.
  def test_run_is_fail_soft_per_action
    with_sandbox do |root|
      seed(root, 'scenario', 'history.jsonl',
           [scen_line(ts: "#{TODAY}T04:45:00Z", blind: true)])
      seed(root, 'gex_history', "#{TODAY}.json", [JSON.generate('date' => TODAY, 'errors' => {})])
      seed(root, 'vol_history', "#{TODAY}.json", [JSON.generate('date' => TODAY, 'errors' => {})])

      out = StringIO.new
      runner = lambda do |argv, _to|
        raise 'scenario subprocess boom' if argv == Ops::Repair::SCENARIO_ARGV

        '{}'
      end
      # Must not raise despite the scenario re-run blowing up.
      healed = Ops::Repair.run(now: NOW, out: out, suite_runner: runner,
                               snapshot_runner: ->(_a, _t) { raise 'unused' })
      assert_empty healed
    end
  end
end
