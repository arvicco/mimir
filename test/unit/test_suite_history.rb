# frozen_string_literal: true

# test_suite_history.rb -- unit tests for Ops::SuiteHistory (M7-5).
#
# Uses a fake runner (records argv calls, returns canned [ok, out, err]
# triples) so nothing forks a subprocess, hits the network, or touches the
# real ledger/history files. Pins: the exact suite argv (--history, NO
# --skip-update, NO --tmux, NO --apply); the success summary lines + the
# aggregate line that lib/btc/ops.rb's success_re matches; the failure path
# (ABORT token, stderr tail, exit-nonzero via ok:false); and secret
# redaction of the tails.

require_relative '../test_helper'
require_relative '../../ops/suite_history'
require_relative '../../lib/btc/ops'

class TestSuiteHistory < Minitest::Test
  # Build a fake runner: responses is a Hash script-basename => [ok, out, err].
  def fake_runner(responses)
    calls  = []
    runner = lambda do |argv, _timeout_s|
      calls << argv.dup
      key = argv.find { |a| a.end_with?('.rb') }
      responses.fetch(key)
    end
    [runner, calls]
  end

  LPPL = 'scripts/lppl/lppl.rb'
  SCN  = 'scripts/scenario/scenario.rb'

  # 1. Both suites succeed -> two `updated` lines + the OK aggregate, ok true.
  def test_both_succeed_ok_and_summary_lines
    runner, calls = fake_runner(
      LPPL => [true, "test  wt ...\nCOMPOSITE +0.55\nLPPL SUPPORTED +0.55 BF+1.2\n", ''],
      SCN  => [true, "module ...\nCOMPOSITE +0.20  ->  RISK-ON   (2026-07-07 12:00 UTC)\n", '']
    )
    r = Ops::SuiteHistory.run(runner: runner)

    assert r[:ok]
    assert_empty r[:failed]
    assert_includes r[:lines], 'suite-history: lppl updated -- LPPL SUPPORTED +0.55 BF+1.2'
    assert_includes r[:lines],
                    'suite-history: scenario updated -- COMPOSITE +0.20  ->  RISK-ON   (2026-07-07 12:00 UTC)'
    assert_equal 'suite-history OK: 2/2 suites updated (lppl, scenario)', r[:lines].last
    # runs lppl FIRST, then scenario -- in order.
    assert_equal [LPPL, SCN], calls.map { |c| c.find { |a| a.end_with?('.rb') } }
  end

  # 2. The exact argv: --history, and NONE of --skip-update / --tmux / --apply.
  def test_suite_argv_is_history_only
    Ops::SuiteHistory::SUITES.each do |_name, argv, _t|
      assert_includes argv, '--history'
      refute_includes argv, '--skip-update', 'lppl --history OWNS the daily price update'
      refute_includes argv, '--tmux', 'the suites\' status tokens are not this agent\'s business'
      refute_includes argv, '--apply'
    end
  end

  # 3. The OK aggregate line is what ops.rb's success_re matches.
  def test_ok_aggregate_matches_ops_success_re
    runner, = fake_runner(LPPL => [true, "LPPL X\n", ''], SCN => [true, "SCN Y\n", ''])
    r = Ops::SuiteHistory.run(runner: runner)
    re = %r{suite-history OK: \d+/\d+ suites updated}
    assert_match re, r[:lines].last
  end

  # 4. A suite failure -> ABORT token + stderr tail, ok false, named failed.
  def test_failure_aborts_with_stderr_tail
    runner, = fake_runner(
      LPPL => [true, "LPPL SUPPORTED +0.55\n", ''],
      SCN  => [false, '', "some noise\nTraceback: rates module 503\n"]
    )
    r = Ops::SuiteHistory.run(runner: runner)

    refute r[:ok]
    assert_equal %w[scenario], r[:failed]
    assert_includes r[:lines], 'suite-history: scenario ABORT -- Traceback: rates module 503'
    assert_match(/suite-history FAILED: 1\/2 updated, failed: scenario/, r[:lines].last)
    # the ABORT token matches ops.rb's shared FAILURE_RE (kickstart shows FAIL).
    assert(r[:lines].any? { |l| l.match?(BTC::Ops::FAILURE_RE) })
  end

  # 5. Tails are redacted (a secret in a suite's stderr never reaches the log).
  def test_tails_are_redacted
    runner, = fake_runner(
      LPPL => [true, "LPPL ok\n", ''],
      SCN  => [false, '', "FRED_API_KEY=deadbeefcafe1234 rejected\n"]
    )
    r = Ops::SuiteHistory.run(runner: runner)
    text = r[:lines].join("\n")
    refute_includes text, 'deadbeefcafe1234'
  end

  # 6. Empty stdout tail collapses to '' (no crash).
  def test_empty_output_tail_is_blank
    runner, = fake_runner(LPPL => [true, '', ''], SCN => [true, "SCN\n", ''])
    r = Ops::SuiteHistory.run(runner: runner)
    assert_includes r[:lines], 'suite-history: lppl updated -- '
  end
end
