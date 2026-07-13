# frozen_string_literal: true
#
# repair.rb -- same-day data-integrity repair loop (M8-9, Phase 8).
#
# PURPOSE
#   The M8-8 markers make a corrupted daily artifact VISIBLE (scenario
#   blind row, lppl stale_input row, an errored/missing GEX-or-vol
#   snapshot). This script tries to HEAL today's artifacts when the data
#   sources answer again. It is wired into ops/run_publish.sh immediately
#   before the publish invocation, so a heal lands in the very next
#   bi-hourly publish tick -- no new launchd agent, up to 12 chances/day.
#
#   Repair NEVER touches an artifact older than today's UTC date: yesterday's
#   damage is a permanent, marked gap (owner ruling 2026-07-13). It re-runs a
#   producer in same-day REPLACE mode (rewrite today's tail line / re-capture
#   today's file), never appending a duplicate.
#
# USAGE
#   ruby ops/repair.rb        # normally invoked by run_publish.sh (env sourced)
#   (env -- BTC_DATA_DIR, FRED_API_KEY, COINGLASS_API_KEY -- comes from the
#   wrapper's sourced env file, exactly as the publisher gets it.)
#
# DECISION TABLE (pure, unit-tested -- see Ops::Repair.plan)
#   artifact          condition (all "today" = UTC)              action
#   -----------------------------------------------------------------------
#   scenario:history  tail line is blind:true AND dated today    re-run + rewrite
#   lppl:ledger       tail line is stale_input:true AND today    re-run + rewrite
#   gex:snapshot      today's file missing OR errors non-empty   re-capture
#   vol:snapshot      today's file missing OR errors non-empty   re-capture
#   (a blind/stale tail dated YESTERDAY -> no action; a clean/absent-today
#    tail -> no action.)
#
# REPLACE SEMANTICS
#   scenario: re-run `scenario.rb --json` (NO --history append); derive blind
#     from the per-module `unavailable` markers. If the fresh result is NOT
#     blind, rewrite today's tail line of history.jsonl (all other lines
#     preserved; atomic tmp+rename; the new line carries the fresh ts). This
#     keeps scenario.rb's own --history semantics untouched.
#   lppl: re-run `lppl.rb --json` WITHOUT --skip-update so the price cache
#     refreshes; read the fresh `stale_input` marker. If the fresh row is NOT
#     stale, rewrite today's ledger tail line the same way. Each rewritten
#     line is the EXACT projection of the suite's --json that its own
#     --history block writes (fields copied here; the suites stay untouched).
#   gex/vol: Ops::GexSnapshot.capture / capture_vol -- the M8-8 retry-on-error
#     guard re-captures a missing OR errored today-file and atomically
#     replaces it.
#
# LOGGING
#   Every SUCCESSFUL repair prints one line to stdout:
#     REPAIRED <artifact> <old-ts> -> <new-ts>
#   A scan with nothing to heal (or a re-run that could not heal) prints
#   NOTHING. Every action is fail-soft: an exception in one is redacted,
#   warned, and never blocks the others or the publish that follows.
#
# Ruby >= 2.5, stdlib only.

require 'json'
require 'time'
require 'timeout'
require 'fileutils'
require_relative '../lib/btc/env'
require_relative './gex_snapshot'

module Ops
  module Repair
    SCENARIO_ARGV = ['ruby', 'scripts/scenario/scenario.rb', '--json'].freeze
    LPPL_ARGV     = ['ruby', 'scripts/lppl/lppl.rb', '--json'].freeze # NO --skip-update
    SCENARIO_TO   = 180
    LPPL_TO       = 600

    # Default suite runner: run argv under Timeout, return the child's full
    # stdout (the aggregators pretty-print ONE JSON doc). Raise on nonzero
    # exit / timeout so the caller records the failure and stays quiet.
    DEFAULT_RUNNER = lambda do |argv, timeout_s|
      out = +''
      Timeout.timeout(timeout_s) { IO.popen(argv) { |io| out = io.read.to_s } }
      raise format('nonzero exit %d', $?.exitstatus) unless $?.success?

      out
    end

    module_function

    # ---- decision layer (PURE -- no IO) ---------------------------------

    # UTC date (YYYY-MM-DD) of a jsonl line's 'ts', or nil when unparseable.
    def line_utc_date(line)
      return nil unless line.is_a?(Hash) && line['ts']

      Time.parse(line['ts'].to_s).utc.strftime('%Y-%m-%d')
    rescue ArgumentError, TypeError
      nil
    end

    # A scenario history tail that is a blind zero recorded TODAY.
    def scenario_blind_today?(tail, today)
      tail.is_a?(Hash) && tail['blind'] == true && line_utc_date(tail) == today
    end

    # An lppl ledger tail that is stale_input recorded TODAY.
    def lppl_stale_today?(tail, today)
      tail.is_a?(Hash) && tail['stale_input'] == true && line_utc_date(tail) == today
    end

    # A snapshot file state (:missing / :errored / :clean) worth re-capturing.
    def snapshot_repairable?(state)
      state == :missing || state == :errored
    end

    # The full plan: the ordered list of repair actions for the given state.
    def plan(today:, scenario_tail:, lppl_tail:, gex_state:, vol_state:)
      actions = []
      actions << :scenario if scenario_blind_today?(scenario_tail, today)
      actions << :lppl     if lppl_stale_today?(lppl_tail, today)
      actions << :gex      if snapshot_repairable?(gex_state)
      actions << :vol      if snapshot_repairable?(vol_state)
      actions
    end

    # ---- projections (copied EXACTLY from the suites' --history blocks) --

    # scenario history line built from scenario.rb --json. blind == every
    # scored module unavailable; unavailable == some (mirrors scenario.rb).
    def scenario_line(j)
      mods = j['modules']
      down = mods.select { |m| m['unavailable'] }.map { |m| m['mod'] }
      row  = { 'ts' => j['ts'], 'composite' => j['composite'],
               'regime' => j['regime'],
               'scores' => mods.to_h { |m| [m['mod'], m['score']] } }
      if !down.empty? && down.size == mods.size
        row['blind'] = true
      elsif !down.empty?
        row['unavailable'] = down
      end
      row
    end

    def scenario_blind_json?(j)
      mods = j['modules']
      mods.is_a?(Array) && !mods.empty? && mods.all? { |m| m['unavailable'] }
    end

    # lppl ledger line built from lppl.rb --json (fields mirror lppl.rb).
    def lppl_line(j)
      d = j['tests'].to_h { |t| [t['name'], t['detail']] }
      row = {
        'ts' => j['ts'], 'composite' => j['composite'], 'verdict' => j['verdict'],
        'bf' => d['trend']['bf'], 'ratio' => d['envelope']['ratio'],
        'days_below_strong' => d['envelope']['days_below_strong'],
        'trough_date' => d['fit']['trough_date'], 'trough_px' => d['fit']['trough_px'],
        'omega' => d['fit']['omega'], 'p_lp' => d['logperiodic']['p_value'],
        'z' => d['percentile']['z'], 'pct_emp' => d['percentile']['pct_emp'],
        'z_record' => d['percentile']['record'],
        'days_le_p01' => d['percentile']['days_le_p01'],
        'scores' => j['tests'].to_h { |t| [t['name'], t['score']] }
      }
      row['stale_input'] = true if j['stale_input']
      row
    end

    # ---- IO helpers -----------------------------------------------------

    # Last non-empty jsonl line of +path+, parsed; nil on absence/parse error.
    def read_tail(path)
      return nil unless File.file?(path)

      last = nil
      File.foreach(path) { |ln| last = ln unless ln.strip.empty? }
      last && JSON.parse(last)
    rescue StandardError
      nil
    end

    # Replace the last non-empty line of +path+ with +new_line+ (Hash),
    # preserving every other line. Atomic tmp+rename.
    def rewrite_tail(path, new_line)
      lines = File.readlines(path)
      idx = lines.rindex { |l| !l.strip.empty? }
      return false if idx.nil?

      lines[idx] = JSON.generate(new_line) + "\n"
      tmp = "#{path}.tmp"
      File.write(tmp, lines.join)
      File.rename(tmp, path)
      true
    end

    # :missing / :errored / :clean for today's snapshot file.
    def snapshot_state(path)
      return :missing unless File.file?(path)

      errs = JSON.parse(File.read(path))['errors']
      errs.is_a?(Hash) && !errs.empty? ? :errored : :clean
    rescue StandardError
      :clean # unreadable/unparseable: leave it (never clobber unconfirmed)
    end

    # captured_at of an existing snapshot file, or 'missing'.
    def snapshot_ts(path)
      return 'missing' unless File.file?(path)

      JSON.parse(File.read(path))['captured_at'].to_s
    rescue StandardError
      'missing'
    end

    # ---- runner ---------------------------------------------------------

    # Scan today's artifacts and heal what the sources now allow. All paths
    # honor BTC_DATA_DIR (sandboxable in tests). +suite_runner+ runs a suite
    # --json subprocess (injected in tests); +snapshot_runner+ is forwarded
    # to Ops::GexSnapshot. Fail-soft throughout; returns the list of healed
    # artifact keys (for tests / callers).
    def run(now: Time.now, out: $stdout,
            suite_runner: DEFAULT_RUNNER,
            snapshot_runner: Ops::GexSnapshot::DEFAULT_RUNNER)
      today   = now.utc.strftime('%Y-%m-%d')
      scen    = File.join(BTC::Env.data_dir('scenario', 'scripts/scenario/data'), 'history.jsonl')
      ledger  = File.join(BTC::Env.data_dir('lppl', 'scripts/lppl/data'), 'ledger.jsonl')
      gex_dir = BTC::Env.data_dir('gex_history', 'data/gex_history')
      vol_dir = BTC::Env.data_dir('vol_history', 'data/vol_history')
      gex_f   = File.join(gex_dir, "#{today}.json")
      vol_f   = File.join(vol_dir, "#{today}.json")

      actions = plan(today: today,
                     scenario_tail: read_tail(scen), lppl_tail: read_tail(ledger),
                     gex_state: snapshot_state(gex_f), vol_state: snapshot_state(vol_f))

      healed = []
      actions.each do |a|
        case a
        when :scenario
          healed << 'scenario:history' if repair_scenario(scen, suite_runner, out)
        when :lppl
          healed << 'lppl:ledger' if repair_lppl(ledger, suite_runner, out)
        when :gex
          healed << 'gex:snapshot' if repair_snapshot('gex:snapshot', gex_dir, gex_f, now, snapshot_runner, out, :capture)
        when :vol
          healed << 'vol:snapshot' if repair_snapshot('vol:snapshot', vol_dir, vol_f, now, snapshot_runner, out, :capture_vol)
        end
      rescue StandardError => e
        warn BTC::Env.redact("repair: #{a} FAILED (contained): #{e.message}")
      end
      healed
    end

    # Re-run scenario --json; if the fresh result is not blind, rewrite today's
    # blind tail line. Returns true on a successful heal.
    def repair_scenario(path, suite_runner, out)
      old_ts = read_tail(path)&.dig('ts')
      j = JSON.parse(suite_runner.call(SCENARIO_ARGV, SCENARIO_TO))
      return false if scenario_blind_json?(j) # still blind: stay quiet, retry later

      rewrite_tail(path, scenario_line(j))
      out.puts format('REPAIRED scenario:history %s -> %s', old_ts, j['ts'])
      true
    end

    # Re-run lppl --json (cache refreshes); if the fresh row is not stale,
    # rewrite today's stale ledger tail line.
    def repair_lppl(path, suite_runner, out)
      old_ts = read_tail(path)&.dig('ts')
      j = JSON.parse(suite_runner.call(LPPL_ARGV, LPPL_TO))
      return false if j['stale_input'] # cache still behind: stay quiet, retry later

      rewrite_tail(path, lppl_line(j))
      out.puts format('REPAIRED lppl:ledger %s -> %s', old_ts, j['ts'])
      true
    end

    # Re-capture a missing/errored snapshot via GexSnapshot; log on a real write.
    def repair_snapshot(name, dir, path, now, snapshot_runner, out, method)
      old_ts = snapshot_ts(path)
      res = Ops::GexSnapshot.public_send(method, dir: dir, now: now, runner: snapshot_runner)
      return false unless %i[written partial].include?(res[:status])

      out.puts format('REPAIRED %s %s -> %s', name, old_ts, snapshot_ts(path))
      true
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    Ops::Repair.run
  rescue StandardError => e
    warn BTC::Env.redact("repair: fatal (contained): #{e.message}")
  end
  exit 0
end
