# frozen_string_literal: true
#
# pipeline.rb -- the publish orchestrator (M2-3, ARCHITECTURE.md 4.1/4.2,
# section 6 Phase 2). Collects the four signal suites' --json outputs plus
# two trailing history windows, wraps each in the frozen KV envelope
# (publish/envelope.rb), builds v1:index, and writes the artifact set --
# to data/publish_preview/ in DRY RUN (the default) or to Cloudflare KV in
# REAL mode.
#
# Usage (the executable is publish/publish.rb):
#   PUBLISH_DRY_RUN=1 ruby publish/publish.rb   # default: files, no network
#   PUBLISH_DRY_RUN=0 ruby publish/publish.rb   # real: KV PUTs (needs CF_*)
#
# CONTRACTS / SEMANTICS
# - PRODUCERS run as subprocesses; the FULL stdout is parsed as ONE JSON
#   document (the producers print pretty multi-line JSON, so the suite's
#   lines.last discipline does NOT apply here). A producer that raises,
#   exits nonzero, or emits unparseable JSON is SKIPPED (warn to stderr,
#   key absent) -- a nonzero gex/btco means keep-last-good, never publish
#   garbage. A fail-soft producer (valid JSON carrying 'unavailable') is
#   published AS-IS: "unavailable" is a real, honest state.
# - TAILS read a jsonl history file and publish only the trailing window
#   (90d scenario, 365d lppl) of lines whose 'ts' is >= now - window.
#   Absent/unreadable file or zero surviving lines -> key SKIPPED.
# - CHARTS (M3-5): after the sources are collected, each entry in
#   Publish::Charts::CHARTS is built from THIS run's payloads -- every
#   input fixture filename maps 1:1 onto an artifact key
#   (payload_gex_combined.json -> gex:combined). A chart is wrapped as
#   'chart:<name>' (ttl = MIN of its inputs' ttls) only if ALL its inputs
#   were published; a missing input or a builder that raises SKIPs just
#   that chart (redacted warn) -- never the source keys or the run.
# - REAL mode: a single KV PUT failure aborts the run (raises
#   Publish::KV::Error) so cron alarms on the exit code; nothing further
#   is attempted. Error text stays redacted (kv_client's pattern).
# - STATUS (frozen --tmux contract): /tmp/publish.status carries
#   `PUB DRY|LIVE <published>/<expected> keys HH:MM UTC` where
#   expected = producers + tails + charts + 1 (the index) = n/13
#   (5 producers + 2 tails + 5 charts + index). Pinned in the tests.
#
# DATA SOURCES: the four scripts/ suites (subprocess), plus the scenario
# history + lppl ledger jsonl under BTC::Env.data_dir(<suite>). No direct
# network here -- KV goes through Publish::KV -> BTC::Http (injectable).
#
# CAVEATS: on a timeout the child subprocess is not force-reaped (matches
# BTC::Suite.run_module); if EVERY producer and tail is skipped no index
# is built and the run publishes nothing (published 0/expected).

require 'json'
require 'time'
require 'timeout'
require 'fileutils'
require_relative 'envelope'
require_relative 'chart_specs'
require_relative 'kv_client'
require_relative '../lib/btc/env'
require_relative '../lib/btc/report'

module Publish
  module Pipeline
    # key, argv (relative to repo root), timeout_s, ttl_hint_s
    PRODUCERS = [
      ['gex:combined',    ['ruby', 'scripts/gex_btc_combined.rb', '--json'],           60,  1_800],
      ['gex:mstr',        ['ruby', 'scripts/gex_us.rb', 'MSTR', '--json'],             60,  1_800],
      ['scenario:latest', ['ruby', 'scripts/scenario/scenario.rb', '--json'],          120, 1_800],
      ['lppl:latest',     ['ruby', 'scripts/lppl/lppl.rb', '--json', '--skip-update'], 300, 86_400],
      ['btco:latest',     ['ruby', 'scripts/btco/btco.rb', '--json'],                  60,  3_600]
    ].freeze

    # key, suite, in-tree default dir, filename, window_days, ttl_hint_s.
    # The data dir is resolved at RUN time so BTC_DATA_DIR is honored.
    TAILS = [
      ['scenario:history', 'scenario', 'scripts/scenario/data', 'history.jsonl', 90,  1_800],
      ['lppl:ledger',      'lppl',     'scripts/lppl/data',     'ledger.jsonl',  365, 86_400]
    ].freeze

    DAY = 86_400

    # Default runner: run argv under a timeout, return the child's FULL
    # stdout as a String; raise on timeout or nonzero exit (-> SKIP).
    DEFAULT_RUNNER = lambda do |argv, timeout_s|
      out = +''
      Timeout.timeout(timeout_s) do
        IO.popen(argv) { |io| out = io.read.to_s }
      end
      raise "nonzero exit #{$?.exitstatus}" unless $?.success?

      out
    end

    module_function

    # Collect -> wrap -> write. Returns a summary hash for the caller to
    # print: { keys:, skipped:, mode:, out_dir: }.
    def run(now:, source:, dry_run:, runner: DEFAULT_RUNNER, env: ENV,
            out_dir: 'data/publish_preview', status_dir: '/tmp')
      envelopes = {} # artifact key => wrapped envelope (insertion order)
      skipped   = []

      PRODUCERS.each do |key, argv, timeout_s, ttl|
        payload = produce(runner, key, argv, timeout_s)
        payload ? envelopes[key] = Publish.wrap(key, payload, ttl, now: now, source: source) : skipped << key
      end

      TAILS.each do |key, suite, default, file, days, ttl|
        path = File.join(BTC::Env.data_dir(suite, default), file)
        payload = tail(key, path, days, now)
        payload ? envelopes[key] = Publish.wrap(key, payload, ttl, now: now, source: source) : skipped << key
      end

      Publish::Charts::CHARTS.each do |name, spec|
        chart(name, spec, envelopes, now, source) or skipped << ('chart:' + name)
      end

      records = envelopes.to_a
      records << ['index', Publish.build_index(envelopes.values, now: now, source: source)] unless envelopes.empty?

      published = dry_run ? write_preview(records, out_dir) : write_kv(records, env)

      expected = PRODUCERS.size + TAILS.size + Publish::Charts::CHARTS.size + 1
      BTC::Report.status('publish',
                         format('PUB %s %d/%d keys %s', dry_run ? 'DRY' : 'LIVE',
                                published, expected, now.utc.strftime('%H:%M UTC')),
                         dir: status_dir)

      { keys: records.map(&:first), skipped: skipped,
        mode: dry_run ? 'DRY' : 'LIVE', out_dir: dry_run ? out_dir : nil }
    end

    # Run one producer; parse its full stdout as a single JSON document.
    # nil (with a redacted warn) on any failure so the key is skipped.
    def produce(runner, key, argv, timeout_s)
      payload = JSON.parse(runner.call(argv, timeout_s))
      return payload unless payload.nil?

      warn "publish: SKIP #{key} (null payload)"
      nil
    rescue StandardError => e
      warn BTC::Env.redact("publish: SKIP #{key} (#{e.class}: #{e.message.to_s[0, 120]})")
      nil
    end

    # Trailing-window payload { 'entries' => [line hashes, ascending] } or
    # nil (skip) for an absent/unreadable file or zero surviving lines.
    # Lines that do not parse or lack a usable 'ts' are dropped silently.
    def tail(key, path, days, now)
      return skip_tail(key, "no file #{path}") unless File.file?(path)

      cutoff = now - days * DAY
      entries = []
      File.foreach(path) do |line|
        line = line.strip
        next if line.empty?

        h = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        t = begin
          Time.parse(h['ts'].to_s)
        rescue ArgumentError, TypeError
          next
        end
        entries << h if t >= cutoff
      end
      return skip_tail(key, "0 lines within #{days}d") if entries.empty?

      { 'entries' => entries }
    rescue StandardError => e
      skip_tail(key, e.class.to_s)
    end

    def skip_tail(key, reason)
      warn BTC::Env.redact("publish: SKIP #{key} (#{reason})")
      nil
    end

    # Build one registered chart from THIS run's collected payloads and
    # insert it as 'chart:<name>' (ttl = MIN of its inputs' ttls). Returns
    # the wrapped envelope on success, nil (with a redacted warn) if any
    # input is absent or the builder raises -- the caller then counts the
    # skip. Never propagates a builder error.
    def chart(name, spec, envelopes, now, source)
      key = 'chart:' + name
      inputs = spec[:inputs].map { |f| chart_input_key(f) }
      unless inputs.all? { |k| envelopes.key?(k) }
        return skip_chart(key, 'inputs not published')
      end

      option = Publish::Charts.public_send(spec[:fn], *inputs.map { |k| envelopes[k]['payload'] })
      ttl = inputs.map { |k| envelopes[k]['ttl_hint_s'] }.min
      envelopes[key] = Publish.wrap(key, option, ttl, now: now, source: source,
                                    meta: spec[:meta])
    rescue StandardError => e
      skip_chart(key, "#{e.class}: #{e.message.to_s[0, 120]}")
    end

    # payload_<x>.json -> <x> with '_' -> ':'. The chart registry names
    # its inputs by fixture file; each maps 1:1 onto a runtime artifact
    # key (payload_gex_combined.json -> 'gex:combined').
    def chart_input_key(fixture)
      fixture.delete_prefix('payload_').delete_suffix('.json').tr('_', ':')
    end

    def skip_chart(key, reason)
      warn BTC::Env.redact("publish: SKIP #{key} (#{reason})")
      nil
    end

    # DRY: pretty-JSON each envelope to <key with ':' -> '_'>.json.
    def write_preview(records, out_dir)
      FileUtils.mkdir_p(out_dir)
      records.each do |key, envelope|
        File.write(File.join(out_dir, preview_name(key)), JSON.pretty_generate(envelope) + "\n")
      end
      records.size
    end

    # REAL: PUT each 'v1:'-prefixed key; a failure raises straight out
    # (aborting the run) after having attempted nothing further.
    def write_kv(records, env)
      records.each do |key, envelope|
        Publish::KV.put('v1:' + key, JSON.generate(envelope), env: env)
      end
      records.size
    end

    def preview_name(key)
      key.tr(':', '_') + '.json'
    end
  end
end
