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
#   If today's dated file already exists AND is clean (empty errors map),
#   the script exits 0 without touching it -- idempotent re-runs. But if
#   today's file exists AND carries a non-empty errors map (a prior
#   partial/failed capture, e.g. an overnight outage), the guard treats it
#   as RETRYABLE: it re-captures and atomically REPLACES the file so a
#   later run in the same day can heal it (M8-8; only today's file is ever
#   touched). A both-fail retry leaves the existing errored file in place.
#   An unreadable/unparseable existing file is treated as not-retryable.
#
# BOTH-FAIL SEMANTICS
#   If BOTH captures fail, no file is written (nothing worth archiving)
#   and the script exits 1 so launchd / cron alarms. A partial capture
#   (one success, one failure) writes the file and exits 0.
#
# VOL SNAPSHOT (M8-1)
#   Alongside the GEX file this script also captures scripts/vol.rb --json
#   into a SEPARATE dated file under
#   BTC::Env.data_dir('vol_history','data/vol_history') via capture_vol,
#   which mirrors capture()'s shape:
#     { "date":, "captured_at":, "vol": <verbatim vol.rb --json | null>,
#       "errors": { "vol": "<redacted message>" } }
#   The vol capture is fully independent -- a vol failure records its error
#   in the vol file (or writes no file, exactly like a both-fail GEX run)
#   and NEVER affects the GEX snapshot's status or exit code above it.
#
# LOCAL-ONLY
#   Snapshots land under BTC::Env.data_dir('gex_history','data/gex_history')
#   (GEX) and BTC::Env.data_dir('vol_history','data/vol_history') (vol).
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

    # M8-1: the vol surface is a single capture written to its own dated
    # file under vol_history (see capture_vol). key, argv, timeout_s.
    VOL_CAPTURE = ['vol', ['ruby', 'scripts/vol.rb', '--json'], 60].freeze

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

    # M8-8: today's dated file is RETRYABLE only when it exists AND carries a
    # non-empty errors map (a prior partial/failed capture). A clean file
    # (empty errors) short-circuits to :skipped; a fresh day has no file. Any
    # read/parse problem is treated as not-retryable -- never clobber a file
    # we cannot confirm is broken.
    def retryable?(target)
      return false unless File.exist?(target)

      errs = JSON.parse(File.read(target))['errors']
      errs.is_a?(Hash) && !errs.empty?
    rescue StandardError
      false
    end

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

      # Date-guard: a present, clean file short-circuits; an errored file is
      # re-captured and REPLACED (M8-8), a fresh day falls through to capture.
      return { status: :skipped, path: target } if File.exist?(target) && !retryable?(target)

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

    # M8-1: capture scripts/vol.rb --json into a dated file under +dir+
    # (vol_history), mirroring capture()'s date-guard, atomic write, and
    # redaction. A single capture, so a failure means "nothing worth
    # archiving": no file is written and the status is :failed. This method
    # is invoked independently of capture() so a vol outage cannot touch the
    # GEX snapshot's outcome.
    #
    # Returns:
    #   { status: :written, path: }          -- vol.rb --json captured
    #   { status: :skipped, path: }          -- date-guard: file exists
    #   { status: :failed,  path:, errors: } -- capture failed, no file
    def capture_vol(dir:, now:, runner: DEFAULT_RUNNER)
      date_str = now.utc.strftime('%Y-%m-%d')
      target   = File.join(dir, "#{date_str}.json")

      # M8-8: same retry-on-error guard as capture() -- an errored vol file is
      # re-captured and REPLACED; a clean one is left untouched.
      return { status: :skipped, path: target } if File.exist?(target) && !retryable?(target)

      FileUtils.mkdir_p(dir)

      key, argv, timeout_s = VOL_CAPTURE
      data = {
        'date'        => date_str,
        'captured_at' => now.utc.iso8601,
        'vol'         => nil,
        'errors'      => {}
      }

      begin
        data['vol'] = JSON.parse(runner.call(argv, timeout_s))
      rescue StandardError => e
        data['errors'][key] = BTC::Env.redact(e.message.to_s)
        return { status: :failed, path: target, errors: data['errors'] }
      end

      tmp = "#{target}.tmp"
      File.write(tmp, JSON.generate(data))
      File.rename(tmp, target)

      { status: :written, path: target }
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

  # M8-1: vol snapshot, fully contained -- any failure here is reported but
  # must never affect the GEX snapshot's outcome or this process's exit
  # code (the GEX write above has already completed).
  begin
    vol_dir = BTC::Env.data_dir('vol_history', 'data/vol_history')
    vres    = Ops::GexSnapshot.capture_vol(dir: vol_dir, now: now)
    case vres[:status]
    when :skipped then puts format('vol skipped (today\'s file exists): %s', vres[:path])
    when :written then puts format('vol written: %s', vres[:path])
    when :failed  then $stderr.puts format('vol failed (not archived): %s', vres[:path])
    end
  rescue StandardError => e
    $stderr.puts format('vol snapshot error (contained): %s', BTC::Env.redact(e.message.to_s))
  end
end
