# frozen_string_literal: true
#
# gex_snapshot.rb -- daily local GEX snapshot writer (M5-5, Phase 5).
#
# PURPOSE
#   Deribit / CBOE options data is now-data -- unbackfillable. This script
#   captures a dated snapshot of both GEX outputs once per day, accumulating
#   a local archive for later analysis. Phase 9 module U3 (expiry_low) will
#   consume the max-put-strike track from this archive.
#
# USAGE
#   ruby ops/gex_snapshot.rb                     # normally invoked by launchd
#   BTC_DATA_DIR=/path ruby ops/gex_snapshot.rb  # override the archive root
#
# FILE SCHEMA
#   One file per calendar day: <dir>/YYYY-MM-DD.json
#   {
#     "date":         "YYYY-MM-DD",
#     "captured_at":  "<ISO8601 UTC>",
#     "btc_combined": <verbatim parsed --json from gex_btc_combined.rb>,
#     "us":           <verbatim parsed --json from gex_us.rb IBIT MSTR>,
#     "errors":       { "<key>": "<redacted message>", ... }
#   }
#   Both data keys are always present; a failed capture's key is null.
#   The errors key is always present; it is an empty hash when all captures
#   succeeded. The --json output shapes are frozen contracts -- they are
#   stored verbatim and never filtered or wrapped.
#
# DATE-GUARD
#   If today's dated file already exists, the script exits 0 without
#   touching it. Re-runs are idempotent; a partial earlier capture is
#   never overwritten.
#
# BOTH-FAIL SEMANTICS
#   If BOTH captures fail, no file is written (nothing worth archiving)
#   and the script exits 1 so launchd / cron alarms. A partial capture
#   (one success, one failure) writes the file and exits 0.
#
# LOCAL-ONLY
#   Snapshots land under BTC::Env.data_dir('gex_history','data/gex_history').
#   The data/ tree is gitignored; snapshots are never published to KV and
#   never committed to git.

require 'json'
require 'time'
require 'timeout'
require 'fileutils'
require_relative '../lib/btc/env'

module Ops
  module GexSnapshot
    # key, argv, timeout_s.  Order matters: btc_combined is captured first.
    CAPTURES = [
      ['btc_combined', ['ruby', 'scripts/gex_btc_combined.rb', '--json'],        60],
      ['us',           ['ruby', 'scripts/gex_us.rb', 'IBIT', 'MSTR', '--json'],  60]
    ].freeze

    # Default subprocess runner: execute argv under Timeout, return the
    # child's full stdout as a String; raise on nonzero exit or timeout so
    # the caller can record the failure and continue with the next capture.
    # Cribbed from publish/pipeline.rb DEFAULT_RUNNER.
    DEFAULT_RUNNER = lambda do |argv, timeout_s|
      out = +''
      Timeout.timeout(timeout_s) do
        IO.popen(argv) { |io| out = io.read.to_s }
      end
      raise format('nonzero exit %d', $?.exitstatus) unless $?.success?
      out
    end

    module_function

    # Capture both GEX outputs and write a dated snapshot under +dir+.
    #
    # Returns a result hash:
    #   { status: :written,  path: }          -- both captures succeeded
    #   { status: :partial,  path: }          -- one succeeded, one failed
    #   { status: :skipped,  path: }          -- date-guard: file already exists
    #   { status: :failed,   path:, errors: } -- both captures failed, no file
    #
    # runner: lambda(argv, timeout_s) -> stdout_string; raise on failure.
    def capture(dir:, now:, runner: DEFAULT_RUNNER)
      date_str = now.utc.strftime('%Y-%m-%d')
      target   = File.join(dir, "#{date_str}.json")

      # Date-guard: today's file is already present -- idempotent, exit clean.
      return { status: :skipped, path: target } if File.exist?(target)

      FileUtils.mkdir_p(dir)

      data = {
        'date'         => date_str,
        'captured_at'  => now.utc.iso8601,
        'btc_combined' => nil,
        'us'           => nil,
        'errors'       => {}
      }
      failed_count = 0

      CAPTURES.each do |key, argv, timeout_s|
        begin
          stdout    = runner.call(argv, timeout_s)
          data[key] = JSON.parse(stdout)
        rescue StandardError => e
          data['errors'][key] = BTC::Env.redact(e.message.to_s)
          failed_count += 1
        end
      end

      # Both captures failed: nothing worth archiving -- do NOT write the file.
      if failed_count == CAPTURES.size
        return { status: :failed, path: target, errors: data['errors'] }
      end

      # Write atomically via tmp-file-then-rename so a crash never leaves a
      # half-written dated file (rename within the same filesystem is atomic).
      tmp = "#{target}.tmp"
      File.write(tmp, JSON.generate(data))
      File.rename(tmp, target)

      { status: failed_count > 0 ? :partial : :written, path: target }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  dir    = BTC::Env.data_dir('gex_history', 'data/gex_history')
  now    = Time.now
  result = Ops::GexSnapshot.capture(dir: dir, now: now)

  case result[:status]
  when :skipped
    puts format('skipped (today\'s file exists): %s', result[:path])
  when :written
    puts format('written: %s', result[:path])
  when :partial
    puts format('partial (one capture failed): %s', result[:path])
  when :failed
    $stderr.puts format('failed (both captures failed): %s', result[:path])
    exit 1
  end
end
