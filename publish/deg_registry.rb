# frozen_string_literal: true
#
# deg_registry.rb -- the reviewed REGISTRY of payloads whose legs (venues,
# sub-sources) a degradation detector can enumerate, and what "alive"
# means for each leg. DATA ONLY: no IO, no ENV, no network, no detector
# logic. The detector (a later packet) iterates DEG_REGISTRY generically;
# adding a payload here is a reviewed change pinned by
# test/unit/test_deg_registry.rb against the real fixture samples.
#
# WHY IT EXISTS: a venue can die INSIDE a still-fresh payload. In the
# incident that prompted this, gex:combined silently became Deribit-only
# and vol:spread published all-null MSTR legs; the envelope timestamp
# was fresh, every producer exited 0, and nothing noticed for two weeks.
# Freshness of the whole payload says nothing about its parts.
#
# ENTRY SHAPE (DEG_REGISTRY[payload_key]):
#   why:      one line, why this payload is covered
#   legs:     ->(payload) { [leg_name, ...] }   legs the payload carries NOW
#   leg_data: ->(payload, leg_name) { data }    that leg's slice of payload
#   alive:    ->(data) { true/false }           is the leg carrying real data
#   optional: true (only reserves:latest) -- the payload may be ABSENT by
#             design; absence is NOT degradation, the detector must skip a
#             missing key and apply the entry only when it is published.
#
# SEMANTICS: "degraded" for a leg = not alive (dead/empty/all-null). The
# detector compares legs(payload) against the legs seen in earlier runs
# to catch a DISAPPEARED leg (gex:combined losing a venue shrinks the
# list; nothing inside the payload says so), and runs alive on each leg
# present to catch a PRESENT-but-dead leg (vol:spread's all-null MSTR).
# The registry only supplies the enumerator and the alive test; it does
# not decide thresholds or alert policy.
#
# Alive tests are deliberately minimal ("has any real number"), never
# value-range judgements -- no analytics threshold lives here. A venue
# flagged stale (served from the 48h cache) still counts alive: its data
# is present; staleness is reported by the payload itself.
#
# CAVEATS: leg_data/alive raise nothing on well-formed payloads; the
# detector should treat an unexpected payload shape (NoMethodError) as a
# degraded payload, not a crash. Leg names are the stable identifiers the
# detector persists, so renaming one is a contract change.
#
# EXCLUDED payloads (swept from Publish::Pipeline::PRODUCERS/TAILS and
# the chart inputs) and why:
#   scenario:latest  modules each carry a score/headline ("unavailable
#                    ..." text marks a dead one) and the composite already
#                    self-flags the all-weighted-modules-down "blind" day
#                    in its history. Registering it would double-cover
#                    the total-blind case; the partial case (one module
#                    down, e.g. macro without a FRED key) is the designed
#                    fail-soft state and is visible per module. Not
#                    registered; revisit only on an owner ruling that
#                    partial module loss should alert.
#   dist:latest      no venue/source list; one Deribit-derived build per
#                    day. Its own n_degraded/n_slices fields and the
#                    ledger recency guard already describe quality.
#   dist:edge        derived from the same build as dist:latest.
#   vol:latest       single source (Deribit tenors); a dead source is an
#                    all-null payload, not a lost leg.
#   vol:mstr         single source (Cboe MSTR tenors), same reasoning.
#   gex:mstr         single-ticker, single-source book.
#   gex:trend        derived from stored history, not live legs.
#   lppl:latest      one suite verdict; its own composite/status_line
#                    carries test health.
#   scorecard:latest offline, scored from local ledgers; no live legs.
#   bubble:ref       single independent source, advisory only.
#   btco:latest      BTCo development is FROZEN (owner ruling 2026-08-10).
#   scenario:history, lppl:ledger, dist:ledger
#                    tail ledgers; the pipeline's content-recency guard
#                    (OLD/BLIND markers) already covers them.
#   chart:*          presentation specs built from the payloads above;
#                    covering the inputs covers the charts.

module Publish
  module DegRegistry
    # True for a real number (not nil, not NaN/Infinity).
    NUM = ->(x) { x.is_a?(Numeric) && (!x.is_a?(Float) || x.finite?) }

    # True for a [date, value] series that has a real latest value.
    SERIES_LIVE = ->(s) { s.is_a?(Array) && !s.empty? && NUM.call(s.last.is_a?(Array) ? s.last[1] : nil) }

    # vol:spread tenor rows -> that side's legs ('mstr' | 'btc').
    SPREAD_SIDE = ->(p, side) { (p['tenors'] || []).map { |t| t[side] } }

    DEG_REGISTRY = {
      'gex:combined' => {
        why: 'one book per venue (Deribit + the spot-BTC ETF option chains); a venue can vanish from venues[] while the payload stays fresh',
        legs: ->(p) { (p['venues'] || []).map { |v| v['name'] } },
        leg_data: ->(p, name) { (p['venues'] || []).find { |v| v['name'] == name } },
        alive: ->(v) { !v.nil? && NUM.call(v['net_gex_usd_per_1pct']) && v['instruments'].to_i.positive? }
      }.freeze,

      'vol:spread' => {
        why: 'the MSTR and BTC legs are separate upstreams per tenor; one side can be all-null (reason set) while the other keeps the payload looking healthy',
        legs: ->(_p) { %w[mstr btc] },
        leg_data: ->(p, name) { SPREAD_SIDE.call(p, name) },
        # alive = at least one tenor carries a real ATM IV on that side
        alive: ->(rows) { rows.is_a?(Array) && rows.any? { |r| r.is_a?(Hash) && NUM.call(r['atm_iv']) } }
      }.freeze,

      'positioning:latest' => {
        why: 'six independent Coinglass-derived daily series; any can go empty or stop producing values while the score and headline still render',
        legs: ->(p) { (p['series'] || {}).keys },
        leg_data: ->(p, name) { (p['series'] || {})[name] },
        alive: SERIES_LIVE
      }.freeze,

      'reserves:latest' => {
        why: 'the exchange-reserve series feeds the positioning card right axis; a dead series is a lost leg',
        # OPTIONAL BY DESIGN: the payload may be absent; skip, never degraded.
        optional: true,
        legs: ->(p) { (p['series'] || {}).keys },
        leg_data: ->(p, name) { (p['series'] || {})[name] },
        alive: SERIES_LIVE
      }.freeze,

      'basis:latest' => {
        why: 'futures basis (Deribit) and perp funding (Binance) come from different upstreams and each fails soft to null with a reason',
        legs: ->(_p) { %w[basis funding] },
        leg_data: ->(p, name) { p[name] },
        alive: lambda { |d|
          next false unless d.is_a?(Hash)
          next false if d.key?('reason') && !d['reason'].nil?

          d['tenors'] ? !d['tenors'].empty? : NUM.call(d['latest_pct'])
        }
      }.freeze,

      'gex:check' => {
        why: 'cross-check of our levels (ours) against an independent max-pain reference (theirs); losing either side makes the comparison meaningless',
        legs: ->(_p) { %w[ours theirs] },
        leg_data: ->(p, name) { p[name] },
        # ours.flip is legitimately null on some days; alive = any real value
        alive: lambda { |d|
          next false unless d.is_a?(Hash)

          d.values.any? { |v| v.is_a?(Hash) ? v.values.any?(&NUM) : NUM.call(v) }
        }
      }.freeze
    }.freeze

    module_function

    # Convenience for the detector: [[leg_name, alive?], ...] for one
    # payload. Pure; raises on a malformed payload (see CAVEATS).
    def census(key, payload)
      e = DEG_REGISTRY.fetch(key)
      e[:legs].call(payload).map { |n| [n, e[:alive].call(e[:leg_data].call(payload, n)) ? true : false] }
    end
  end
end
