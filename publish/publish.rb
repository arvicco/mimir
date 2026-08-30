#!/usr/bin/env ruby
# frozen_string_literal: true
#
# publish.rb -- publish orchestrator entry point (M2-3, ARCHITECTURE.md
# section 6 Phase 2). Runs the four signal suites + two history tails,
# wraps the frozen KV envelope, and writes the v1:* artifact set + the
# v1:index. All logic lives in publish/pipeline.rb (injectable for tests);
# this file only resolves mode/source and prints the run summary.
#
# Usage:
#   PUBLISH_DRY_RUN=1 ruby publish/publish.rb   # DEFAULT: files, no network
#   ruby publish/publish.rb                     # same -- dry run is the default
#   PUBLISH_DRY_RUN=0 ruby publish/publish.rb   # REAL: KV PUTs (needs CF_* env)
#
# DRY RUN IS THE DEFAULT: real mode is entered ONLY with an explicit
# PUBLISH_DRY_RUN=0 (any other value, or unset, means dry) AND the CF_*
# credentials in ENV -- a missing CF_* var aborts the real run nonzero via
# Publish::KV. Dry-run artifacts land in data/publish_preview/; the status
# line lands in /tmp/publish.status. Exit 0 on a dry run; nonzero if a real
# publish fails (so cron alarms on the exit code).

require 'socket'
require_relative 'pipeline'

dry_run = ENV['PUBLISH_DRY_RUN'] != '0'
source  = Socket.gethostname.split('.').first

begin
  summary = Publish::Pipeline.run(now: Time.now.utc, source: source, dry_run: dry_run)
rescue Publish::KV::Error => e
  warn "publish: ABORT #{BTC::Env.redact(e.message)}"
  exit 1
end

summary[:keys].each    { |k| puts format('  %-18s %s', k, 'written') }
summary[:skipped].each { |k| puts format('  %-18s %s', k, 'SKIPPED') }
dest = summary[:out_dir] || 'KV'
puts format('publish %s: %d written, %d skipped -> %s',
            summary[:mode], summary[:keys].size, summary[:skipped].size, dest)

# M12-5 (Q-17): transition alerts from THIS run's payloads -- REAL mode
# only (previews/replays never alert), dormant until the owner sets
# NTFY_TOPIC, and Alerts.dispatch never raises or changes the exit code.
unless dry_run
  require_relative 'alerts'
  Publish::Alerts.dispatch(summary)
end

exit 0
