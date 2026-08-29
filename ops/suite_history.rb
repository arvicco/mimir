# frozen_string_literal: true
#
# suite_history.rb -- daily evidence-trail advance driver (M7-5, Phase 7).
#
# PURPOSE
#   The dashboard's evidence trails (the lppl ledger + fit_history, the
#   scenario history, and the local price cache) only move forward when a
#   suite is run with --history. The owner's old daily cron did exactly
#   that (~04:54Z: `lppl.rb --history` WITHOUT --skip-update fetched Coin
#   Metrics + appended the ledger/fit_history; `scenario.rb --history`
#   appended its history). That cron was retired at the Gate 5 launchd
#   install and NO agent took the duty -- so the bi-hourly publisher
#   (which deliberately runs lppl --skip-update / no --history) kept
#   re-stamping FROZEN content and the site served ~29h-stale evidence
#   under all-green machinery (2026-07-07 INCIDENT, .docs/WORKLOG.md).
#   This agent is that retired duty's successor: it runs the two --history
#   suites once a day so the evidence trail advances.
#
# USAGE
#   ruby ops/suite_history.rb            # normally invoked by launchd
#   (env -- BTC_DATA_DIR, FRED_API_KEY -- comes from the wrapper's sourced
#   env file; scenario's rates module needs FRED, lppl fetches Coin Metrics.)
#
# WHAT IT RUNS (sequentially, in order)
#   1. ruby scripts/lppl/lppl.rb --history      (NO --skip-update: THIS run
#      owns the daily price-cache update + the ledger/fit_history append)
#   2. ruby scripts/scenario/scenario.rb --history   (the scenario history
#      append)
#   3. ruby scripts/scenario/positioning.rb --history   (the positioning
#      module's daily sub-signal row -- M11-1; this duty was unmapped from
#      the module's ship in Phase 10 until the 2026-08-29 owner ruling)
#   4. ruby scripts/scenario/reserves.rb --history   (the exchange-reserve
#      module's daily row -- M11-7, wired the same day the module shipped)
#   It NEVER passes --tmux (the suites' own /tmp/*.status tokens are not
#   this agent's business) and NEVER --apply anything.
#
# OUTPUT / LOG SUMMARY
#   One summary line per suite, then a final aggregate line:
#     suite-history: lppl updated -- <verdict/status tail>
#     suite-history: scenario updated -- <verdict/status tail>
#     suite-history: positioning updated -- <verdict/status tail>
#     suite-history: reserves updated -- <verdict/status tail>
#     suite-history OK: 4/4 suites updated (lppl, scenario, positioning, reserves)
#   On a suite failure its line is `suite-history: <name> ABORT -- <stderr
#   tail>` and the final line is `suite-history FAILED: n/4 updated,
#   failed: <names>`. All tails pass BTC::Env.redact (defense in depth).
#   Failures are ISOLATED: every suite always runs regardless of the
#   others' outcomes (sequential, each independently reported).
#
# EXIT / ALARM SEMANTICS
#   Exits 1 if EITHER suite failed (launchd surfaces it in `last exit`);
#   0 otherwise. Both duties matter to freshness, so -- unlike
#   gex_snapshot's partial-is-fine both-fail rule -- either failure alarms.
#   The `ABORT` token in a failed suite's line matches lib/btc/ops.rb's
#   shared FAILURE_RE so `rake ops:install`'s kickstart poll shows FAIL.

require 'timeout'
require 'open3'
require_relative '../lib/btc/env'

module Ops
  module SuiteHistory
    # name, argv (from repo root), timeout_s. Order matters: lppl first
    # (it owns the price-cache update + ledger/fit_history append), then
    # scenario, then positioning. lppl --history fetches Coin Metrics and
    # refits, so it gets the wider timeout. positioning --history (M11-1,
    # owner ruling 2026-08-29 on register item R-10) appends the module's
    # daily sub-signal row -- the evidence the D10-b 120-day graduation
    # review referees; on a dead-source day the module fail-softs (exit 0,
    # no row -- an honest gap), so ABORT here means a hard crash only.
    SUITES = [
      ['lppl',        ['ruby', 'scripts/lppl/lppl.rb', '--history'],             600],
      ['scenario',    ['ruby', 'scripts/scenario/scenario.rb', '--history'],     180],
      ['positioning', ['ruby', 'scripts/scenario/positioning.rb', '--history'],  120],
      # M11-7 (R-11/D11-a): the exchange-reserve module's daily row --
      # wired the same day the module ships, so the R-10 gap class
      # (a module whose history duty nothing runs) cannot recur.
      ['reserves',    ['ruby', 'scripts/scenario/reserves.rb', '--history'],     120]
    ].freeze

    # Default subprocess runner: run argv under Timeout, capturing stdout
    # and stderr separately. Returns [ok, stdout, stderr]; ok is false on a
    # nonzero exit, a timeout, or a spawn error. Never raises.
    DEFAULT_RUNNER = lambda do |argv, timeout_s|
      out = +''
      err = +''
      status = nil
      Timeout.timeout(timeout_s) do
        out, err, status = Open3.capture3(*argv)
      end
      [status.success?, out, err]
    rescue Timeout::Error
      [false, out, format('timeout after %ds', timeout_s)]
    rescue StandardError => e
      [false, out, e.message.to_s]
    end

    module_function

    # Run each suite sequentially, in order. Returns a result hash:
    #   { ok: Bool, lines: [summary_line, ...], failed: [name, ...] }
    # ok is true only when EVERY suite succeeded (the evidence trail is
    # current only if BOTH the lppl price/ledger update AND the scenario
    # history append landed).
    #
    # runner: lambda(argv, timeout_s) -> [ok, stdout, stderr]; never raises.
    def run(runner: DEFAULT_RUNNER)
      lines  = []
      failed = []
      SUITES.each do |name, argv, timeout_s|
        ok, out, err = runner.call(argv, timeout_s)
        if ok
          lines << format('suite-history: %s updated -- %s', name, tail_line(out))
        else
          failed << name
          lines << format('suite-history: %s ABORT -- %s', name, tail_line(err))
        end
      end
      lines << final_line(failed)
      { ok: failed.empty?, lines: lines, failed: failed }
    end

    # The aggregate line: the success form is what lib/btc/ops.rb's
    # success_re matches (so the kickstart poll PASSes only on a full run).
    def final_line(failed)
      n = SUITES.size
      if failed.empty?
        format('suite-history OK: %d/%d suites updated (%s)', n, n, SUITES.map(&:first).join(', '))
      else
        format('suite-history FAILED: %d/%d updated, failed: %s', n - failed.size, n, failed.join(', '))
      end
    end

    # Last non-empty, redacted line of +text+ (a suite's verdict/status
    # tail on success, or its stderr tail on failure). '' when there is none.
    def tail_line(text)
      last = text.to_s.lines.map(&:strip).reject(&:empty?).last
      last ? BTC::Env.redact(last) : ''
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  result = Ops::SuiteHistory.run
  result[:lines].each { |l| puts l }
  exit(result[:ok] ? 0 : 1)
end
