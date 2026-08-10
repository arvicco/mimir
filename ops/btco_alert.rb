# frozen_string_literal: true
#
# btco_alert.rb -- daily BTCo new-filing DISCOVERY ALERT (M7-2, Phase 7).
#
# Runs the ingest discovery primitive `ruby scripts/btco/ingest.rb --dry
# --json` -- a provably read-only listing: NO document fetch, NO AI, NO
# state mutation, NO API spend (decision D6-a) -- and writes a one-glance
# status token to /tmp/ingest.status for the tmux bar to `cat`.
#
# Usage (normally invoked by ops/run_btco_alert.sh under launchd):
#   ruby ops/btco_alert.rb            # write /tmp/ingest.status
#   ruby ops/btco_alert.rb /some/dir  # ARGV[0] overrides the status dir
#
# Output contract (--tmux, via BTC::Report.status('ingest', ...)):
#
#   Condition                               /tmp/ingest.status token
#   -----------------------------------------------------------------
#   n new filings discovered (n > 0)        ING n!
#   nothing new (n == 0)                    (empty file -- D8-a: the tmux
#                                            #() collapses to nothing, so a
#                                            packed bar stays quiet on quiet days)
#   discovery failed / unparseable output   ING ?
#
#   `!` = attention: n filings await an owner review session. `ING ?`
#   makes a BROKEN alert visible rather than silent (mirrors
#   publish_health.rb's `PUB! ?` philosophy). This job ALWAYS exits 0 --
#   the token, not the exit code, is the signal; launchd never alarms on it.
#
# The alert is decoupled from ingest.rb: a nonzero exit or a non-JSON line
# collapses to the safe `ING ?` fallback rather than crashing.

require 'json'
require 'open3'
require 'rbconfig'
require_relative '../lib/btc/report'

module Ops
  module BtcoAlert
    DEFAULT_STATUS_DIR = '/tmp'
    STATUS_NAME        = 'ingest'
    INGEST             = File.expand_path('../scripts/btco/ingest.rb', __dir__)
    # The ONLY discovery invocation: list + count. No document fetch, no AI,
    # no state write, no --apply (universe.json protection).
    DISCOVERY_ARGV     = %w[--dry --json].freeze
    ERROR_TOKEN        = 'ING ?'

    # runner: lambda(argv) -> [ok, stdout]. Default spawns the SAME ruby on
    # ingest.rb with DISCOVERY_ARGV; injectable so tests never fork the wire.
    DEFAULT_RUNNER = lambda do |argv|
      out, status = Open3.capture2(RbConfig.ruby, INGEST, *argv)
      [status.success?, out]
    rescue StandardError
      [false, '']
    end

    module_function

    # Run discovery, write the status token, return a one-line log summary.
    # ALWAYS writes the status file and ALWAYS returns cleanly: a broken
    # discovery becomes `ING ?`, never a crash and never silence.
    def run(status_dir: DEFAULT_STATUS_DIR, runner: DEFAULT_RUNNER)
      ok, out = begin
        runner.call(DISCOVERY_ARGV)
      rescue StandardError
        [false, '']
      end
      n          = ok ? parse_new(out) : nil
      line, note = render(n)
      BTC::Report.status(STATUS_NAME, line, dir: status_dir)
      note
    end

    # n new filings -> "ING n!"; zero -> "" (empty file so the tmux #()
    # collapses to nothing); nil (failure/unparseable) -> "ING ?".
    def token(n)
      return ERROR_TOKEN if n.nil?

      n.positive? ? format('ING %d!', n) : ''
    end

    # -> [status_line, log_note].
    def render(n)
      note = if n.nil?
               'alert: discovery failed -> ING ?'
             elsif n.positive?
               format('alert: %d new filing(s) -> ING %d!', n, n)
             else
               'alert: no new filings -> quiet'
             end
      [token(n), note]
    end

    # Parse the single ingest --dry --json line {"new":n,"filings":[...]}.
    # Returns the integer count, or nil on any parse/shape mismatch.
    def parse_new(out)
      line = out.to_s.strip
      return nil if line.empty?

      obj = JSON.parse(line)
      new = obj['new']
      return nil unless new.is_a?(Integer) && new >= 0 &&
                        obj['filings'].is_a?(Array) && obj['filings'].size == new

      new
    rescue JSON::ParserError
      nil
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  status_dir = ARGV[0] || Ops::BtcoAlert::DEFAULT_STATUS_DIR
  puts Ops::BtcoAlert.run(status_dir: status_dir)
  exit 0
end
