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
#   published AS-IS: "unavailable" is a real, honest state -- but NO
#   CHART is built from it (junk-chart guard, 2026-07-07 incident), and
#   keep-last-good extends to INDEX MEMBERSHIP: every expected-but-
#   skipped key keeps its previous index row (old generated_at from the
#   prior index -- KV in live mode, out_dir in dry), so a transient
#   upstream outage AGES keys on the dashboard instead of vanishing them.
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
#   expected = producers + tails + charts + 1 (the index) = n/33
#   (15 producers + 2 tails + 15 charts + index). Pinned in the tests.
#   ADDITIVE (M7-5, 2026-07-07 frozen-evidence incident): when a PUBLISHED
#   tail's newest entry is older than STALE_EVIDENCE_H (30h), the line gains
#   a trailing ` OLD:<key>[,<key>...]` marker (TAILS order), e.g.
#   `PUB LIVE 13/13 keys 09:34 UTC OLD:lppl:ledger`. The marker is present
#   ONLY when stale; a SKIPPED tail (no file) gets no marker -- the n/m
#   shortfall already flags it. ops/publish_health.rb reads the marker.
#   ADDITIVE (M8-10): when a published tail's FRESHEST entry still carries
#   its M8-8 data-integrity marker (scenario:history -> blind, lppl:ledger ->
#   stale_input) -- i.e. ops/repair.rb, run just before this publish, could
#   not heal it -- the line gains a trailing ` BLIND:<suite>[,...]` marker
#   (BLIND_MARKERS order), after any ` OLD:` suffix, e.g.
#   `PUB LIVE 13/13 keys 09:34 UTC BLIND:scenario`. publish_health surfaces it.
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
      ['gex:combined',    ['ruby', 'scripts/gex_btc_combined.rb', '--json'],           60,  3_600],
      ['gex:mstr',        ['ruby', 'scripts/gex_us.rb', 'MSTR', '--json'],             60,  3_600],
      ['scenario:latest', ['ruby', 'scripts/scenario/scenario.rb', '--json'],          120, 3_600],
      ['lppl:latest',     ['ruby', 'scripts/lppl/lppl.rb', '--json', '--skip-update'], 300, 3_600],
      ['btco:latest',     ['ruby', 'scripts/btco/btco.rb', '--json'],                  60,  3_600],
      # M8-6: the GEX/volatility family (Phase 8A stage 2). All fail-soft
      # (valid JSON, never 'unavailable') so they publish honestly even when
      # an upstream leg is down; their charts read from these keys.
      ['vol:latest',      ['ruby', 'scripts/vol.rb', '--json'],                        60,  3_600],
      ['vol:mstr',        ['ruby', 'scripts/vol_mstr.rb', '--json'],                   90,  3_600],
      ['vol:spread',      ['ruby', 'scripts/vol_spread.rb', '--json'],                 90,  3_600],
      ['basis:latest',    ['ruby', 'scripts/basis.rb', '--json'],                      60,  3_600],
      ['gex:trend',       ['ruby', 'scripts/gex_trend.rb', '--json'],                  30,  3_600],
      ['gex:check',       ['ruby', 'scripts/gex_check.rb', '--json'],                  120, 3_600],
      # M10-7 (P-19): our own signals' forward-return track record, scored
      # offline from the local ledgers by scripts/scorecard.rb (no network).
      # Descriptive only -- report-only, changes no analytics semantics.
      ['scorecard:latest', ['ruby', 'scripts/scorecard.rb', '--json'],                 60,  3_600],
      # M10-4 (P-6): the crowd-positioning module -- daily crowd/OI/liquidation
      # stance. Runs at WEIGHT 0 during the soak (display only); its --json
      # carries the card series. Daily cadence (24h source-cache ttl).
      ['positioning:latest', ['ruby', 'scripts/scenario/positioning.rb', '--json'],    60,  3_600],
      # M11-7 (P-8, R-11/D11-a): the exchange-reserve module -- weight 0,
      # daily cadence (24h source-cache ttl); its --json carries the
      # reserves series the positioning card draws on its right axis.
      ['reserves:latest',  ['ruby', 'scripts/scenario/reserves.rb', '--json'],         60,  3_600],
      # M12-4 (Q-12): the independent bubble-index cross-reference --
      # ADVISORY payload for the SHADOW tab's x-ref row, never a score
      # input. Daily cadence (24h source-cache ttl).
      ['bubble:ref',       ['ruby', 'scripts/bubble_ref.rb', '--json'],                60,  3_600],
      # M13-5..9 (skuld S-A/S-B, plan-13): the market-implied distribution.
      # SLOW module by ruling (2026-09-04): one fresh compute per UTC day,
      # same-day re-runs re-emit from cache -- so the bi-hourly publisher
      # costs one Deribit book fetch per day. dist:edge extracts the edge
      # ratio from the SAME day build (never disagrees with dist:latest).
      ['dist:latest',      ['ruby', 'scripts/dist/dist.rb', '--json'],                 120, 3_600],
      ['dist:edge',        ['ruby', 'scripts/dist/dist.rb', '--json', '--edge'],       120, 3_600]
    ].freeze

    # key, suite, in-tree default dir, filename, window_days, ttl_hint_s.
    # The data dir is resolved at RUN time so BTC_DATA_DIR is honored.
    TAILS = [
      ['scenario:history', 'scenario', 'scripts/scenario/data', 'history.jsonl', 90,  3_600],
      ['lppl:ledger',      'lppl',     'scripts/lppl/data',     'ledger.jsonl',  365, 3_600],
      # M13-9: the dist publication ledger (one row per day; 90d window
      # keeps the key size bounded -- the full ledger stays on disk).
      ['dist:ledger',      'dist',     'scripts/dist/data',     'ledger.jsonl',  90,  3_600]
    ].freeze

    DAY = 86_400

    # Content-recency guard (2026-07-07 frozen-evidence incident). A tail
    # whose NEWEST published entry is older than this many hours has stopped
    # moving -- the daily evidence agent (ops/suite_history.rb) either did
    # not run or its --history append failed, and the bi-hourly publisher is
    # re-stamping frozen content. 30h = the daily cadence plus slack (a
    # missed run + a late catch-up must not trip it). A code constant on
    # purpose: this is a research/ops invariant, NOT ENV-configurable.
    STALE_EVIDENCE_H = 30

    # M8-10: tail key -> [status-line suite label, the M8-8 marker whose
    # presence on the FRESHEST published entry means today's artifact is
    # still corrupted after repair ran. Additive ` BLIND:<suite>` suffix.
    BLIND_MARKERS = {
      'scenario:history' => ['scenario', 'blind'],
      'lppl:ledger'      => ['lppl',     'stale_input']
    }.freeze

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
      unless envelopes.empty?
        all_keys = PRODUCERS.map(&:first) + TAILS.map(&:first) +
                   Publish::Charts::CHARTS.keys.map { |n| 'chart:' + n }
        carry = index_carry(all_keys - envelopes.keys, dry_run, out_dir, env)
        records << ['index', Publish.build_index(envelopes.values, now: now,
                                                 source: source, carry: carry)]
      end

      published = dry_run ? write_preview(records, out_dir) : write_kv(records, env)

      expected = PRODUCERS.size + TAILS.size + Publish::Charts::CHARTS.size + 1
      old = stale_tails(envelopes, now)
      old_suffix = old.empty? ? '' : format(' OLD:%s', old.join(','))
      # M8-10: a still-marked freshest tail (repair, run just before this
      # publish, could not heal it) rides an additive ` BLIND:<suite>` suffix.
      blind = blind_tails(envelopes)
      blind_suffix = blind.empty? ? '' : format(' BLIND:%s', blind.join(','))
      BTC::Report.status('publish',
                         format('PUB %s %d/%d keys %s%s%s', dry_run ? 'DRY' : 'LIVE',
                                published, expected, now.utc.strftime('%H:%M UTC'),
                                old_suffix, blind_suffix),
                         dir: status_dir)

      { keys: records.map(&:first), skipped: skipped,
        mode: dry_run ? 'DRY' : 'LIVE', out_dir: dry_run ? out_dir : nil,
        # M12-5 (additive): the run's envelopes + health markers, so the
        # publish bin can dispatch transition alerts (real mode only)
        # without re-fetching anything.
        envelopes: envelopes, old_keys: old, blind_tails: blind }
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

    # Content-recency guard: of the PUBLISHED tails (skipped tails are not
    # in +envelopes+, and the n/m shortfall already flags them), the TAILS
    # keys whose newest entry is older than STALE_EVIDENCE_H. Returned in
    # TAILS order so the ` OLD:<key>[,<key>]` suffix is deterministic.
    def stale_tails(envelopes, now)
      cutoff = now - STALE_EVIDENCE_H * 3600
      TAILS.map(&:first).select do |key|
        env = envelopes[key]
        next false unless env

        newest = newest_entry_ts(env['payload'])
        newest && newest < cutoff
      end
    end

    # Newest parseable 'ts' among a tail payload's entries, or nil when the
    # payload has no dated entry (never raises -- a bad ts is skipped).
    def newest_entry_ts(payload)
      return nil unless payload.is_a?(Hash)

      entries = payload['entries']
      return nil unless entries.is_a?(Array)

      entries.map do |e|
        Time.parse(e['ts'].to_s)
      rescue ArgumentError, TypeError
        nil
      end.compact.max
    end

    # The entry with the newest parseable 'ts' in a tail payload (nil when
    # none). Never raises -- an unparseable ts sorts to the epoch.
    def newest_entry(payload)
      return nil unless payload.is_a?(Hash)

      entries = payload['entries']
      return nil unless entries.is_a?(Array) && !entries.empty?

      entries.max_by do |e|
        Time.parse(e['ts'].to_s)
      rescue ArgumentError, TypeError
        Time.at(0)
      end
    end

    # M8-10: of the PUBLISHED tails, the suites whose FRESHEST entry still
    # carries its M8-8 data-integrity marker (scenario:history -> 'blind',
    # lppl:ledger -> 'stale_input') at publish time -- repair (run just
    # before this publish) could not heal it. Returned in BLIND_MARKERS order
    # so the ` BLIND:<suite>[,...]` suffix is deterministic. A skipped tail is
    # absent from +envelopes+ and already shows in the n/m shortfall.
    def blind_tails(envelopes)
      BLIND_MARKERS.filter_map do |tail_key, (suite, marker)|
        env = envelopes[tail_key]
        next unless env

        newest = newest_entry(env['payload'])
        suite if newest.is_a?(Hash) && newest[marker]
      end
    end

    # Build one registered chart from THIS run's collected payloads and
    # insert it as 'chart:<name>' (ttl = MIN of its REQUIRED inputs'
    # ttls). Returns the wrapped envelope on success, nil (with a redacted
    # warn) if any required input is absent or the builder raises -- the
    # caller then counts the skip. Never propagates a builder error.
    #
    # M11-7: a spec may also declare :optional inputs -- enrichment
    # payloads passed AFTER the required ones, or nil when absent or
    # fail-soft. An optional input can therefore never skip the chart
    # (the reserves curve must not couple the positioning card to the
    # reserves module's uptime); the builder degrades on nil.
    def chart(name, spec, envelopes, now, source)
      key = 'chart:' + name
      inputs = spec[:inputs].map { |f| chart_input_key(f) }
      unless inputs.all? { |k| envelopes.key?(k) }
        return skip_chart(key, 'inputs not published')
      end
      # A fail-soft payload ('unavailable': true, F-12) is an honest suite
      # status, not chartable data -- building from one published a NaN
      # gauge / empty table (2026-07-07 incident). Skip instead;
      # keep-last-good + the index carry keep the previous chart visible.
      bad = inputs.find { |k| envelopes[k]['payload'].is_a?(Hash) && envelopes[k]['payload']['unavailable'] }
      return skip_chart(key, "input #{bad} unavailable") if bad

      optional = (spec[:optional] || []).map do |f|
        env = envelopes[chart_input_key(f)]
        p   = env && env['payload']
        p.is_a?(Hash) && p['unavailable'] ? nil : p
      end

      option = Publish::Charts.public_send(spec[:fn],
                                           *inputs.map { |k| envelopes[k]['payload'] },
                                           *optional)
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

    # Keep-last-good extends to INDEX MEMBERSHIP (2026-07-07 incident:
    # a Deribit outage skipped gex:combined and the key VANISHED from the
    # index-driven dashboard even though KV kept its value). For every
    # expected-but-skipped key, carry the row from the PREVIOUS index --
    # old generated_at, so the dashboard shows an honestly aging key.
    # Keys removed from the expected set stop being carried naturally.
    # Any failure here degrades to no carry, never a crashed publish.
    def index_carry(missing, dry_run, out_dir, env)
      return [] if missing.empty?

      keep = previous_index_rows(dry_run, out_dir, env)
             .select { |r| missing.include?(r['key']) }
      keep.each { |r| warn "publish: index carries last-good #{r['key']}@#{r['generated_at']}" }
      keep
    rescue StandardError => e
      warn BTC::Env.redact("publish: no index carry (#{e.class}: #{e.message.to_s[0, 80]})")
      []
    end

    def previous_index_rows(dry_run, out_dir, env)
      raw = if dry_run
              path = File.join(out_dir, 'index.json')
              return [] unless File.file?(path)

              File.read(path)
            else
              Publish::KV.get('v1:index', env: env)
            end
      JSON.parse(raw).dig('payload', 'keys') || []
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
