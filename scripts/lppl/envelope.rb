#!/usr/bin/env ruby
# frozen_string_literal: true
#
# envelope.rb -- Test 3: the damping-envelope claim.
#
# This is a DESCRIPTIVE CYCLE HEURISTIC, not a statistical test: only three
# historical troughs support it, so it describes a pattern rather than
# proving one. LPPL-as-regime asserts trough depth ratios (price/trend at
# cycle lows) DAMP monotonically: ~0.40 (2015) -> ~0.45 (2018) -> ~0.50
# (2022), so this cycle's trough should print ABOVE the 2022 ratio. Two
# thresholds:
#
#   strong form: bound = last cycle's trough ratio. Sustained trade below
#                0.95*bound for >= 45 consecutive days -> strong form broken.
#   weak form:   hard floor = min historical trough ratio. Sustained below
#                0.95*floor for >= 30 days -> the envelope claim is dead
#                in any form (model falsified on this component).
#
#   score +1  ratio above strong bound (damping intact)
#   score  0  below strong bound but persistence not yet met (stressed)
#   score -1  strong form broken (>= 45d) or weak form broken (>= 30d)
#
# FREEZE RULE (M11-5, owner ruling 2026-08-29, register R-8 / was D9-g):
# the operative bound and floor are FROZEN measurements -- each historical
# trough's ratio against the trend AS FITTED ON DATA UP TO THAT TROUGH --
# so today's re-estimated trend cannot drag the reference thresholds
# around (the drift flattered the model: rising price pulled the bound up
# with it, and by 2026-08 had even made the live trough sequence
# non-monotonic, 0.545 -> 0.585 -> 0.441). The bound re-sets only when a
# subsequent trough is confirmed (a deliberate TROUGHS edit -- trough
# confirmation was always a research decision, so no state file is
# needed; everything derives from the price cache). Today's ratio is
# still measured against today's trend -- the freeze applies to the
# REFERENCE thresholds, not the live reading. The drifting measurements
# stay visible as bound_live / floor_live / trough_ratios_live reference
# fields; freeze_candidate (M9-4) keeps its field and now equals the
# operative bound. If a frozen fit is ever unavailable the test falls
# back to the live measurements (fail-soft, headline says so).
# Frozen sequence on adoption: 0.241 -> 0.482 -> 0.358 (note: honest
# measurement says damping ALSO failed 2018 -> 2022 -- recorded, not
# hidden).

require_relative 'common'

NAME    = 'envelope'
TROUGHS = %w[2015-01-14 2018-12-15 2022-11-21].freeze

begin
  p = Lppl.load_prices
rescue StandardError => e
  Lppl.fail_soft(NAME, e.message)
end

xs  = p[:days].map { |d| Math.log(d) }
reg = Lppl::RangeReg.new(xs, p[:lnp])
f   = reg.fit(0, p[:days].size - 1)
Lppl.fail_soft(NAME, 'trend fit failed') unless f

trend_ln = ->(i) { f[:icept] + f[:slope] * xs[i] }
ratio_at = ->(i) { Math.exp(p[:lnp][i] - trend_ln.(i)) }

date_ix = {}
p[:dates].each_index { |i| date_ix[p[:dates][i].strftime('%Y-%m-%d')] = i }

hist = TROUGHS.map { |d| date_ix[d] && ratio_at.(date_ix[d]) }.compact
Lppl.fail_soft(NAME, 'historical troughs not in cache') if hist.size < 3

# Frozen per-trough ratios (M11-5): each trough measured against the trend
# fitted on data up to that trough only. The operative thresholds; the
# drifting +hist+ values above become the *_live references.
hist_frozen = TROUGHS.filter_map do |d|
  i  = date_ix[d]
  ff = i && reg.fit(0, i)
  ff && Math.exp(p[:lnp][i] - (ff[:icept] + ff[:slope] * xs[i]))
end
frozen_ok = hist_frozen.size == TROUGHS.size

bound_live = hist.last
floor_live = hist.min
bound = frozen_ok ? hist_frozen.last : bound_live # strong form threshold
floor = frozen_ok ? hist_frozen.min  : floor_live # weak form threshold
r_now = ratio_at.(p[:days].size - 1)

# freeze_candidate keeps its M9-4 field for ledger/dashboard continuity;
# since the R-8 adoption it IS the operative bound.
freeze_candidate = frozen_ok ? bound.round(3) : nil

# consecutive days below each threshold, walking back from today
below = lambda do |thr|
  c = 0
  (p[:days].size - 1).downto(0) do |i|
    break if ratio_at.(i) >= thr

    c += 1
  end
  c
end
d_strong = below.(bound * 0.95)
d_weak   = below.(floor * 0.95)

broken = d_strong >= 45 || d_weak >= 30
score  = if broken
           -1
         elsif r_now >= bound
           1
         else
           0
         end

state = if broken
          d_weak >= 30 ? 'BROKEN (weak form)' : 'BROKEN (strong form)'
        elsif r_now >= bound
          'intact'
        else
          'stressed'
        end

Lppl.report(NAME, score,
              format('price/trend %.3f vs %s bound %.3f (floor %.3f; live %.3f/%.3f) -- %s; %dd below strong, %dd below floor',
                     r_now, frozen_ok ? 'frozen' : 'LIVE-FALLBACK',
                     bound, floor, bound_live, floor_live,
                     state, d_strong, d_weak),
              'ratio' => r_now.round(3), 'bound' => bound.round(3),
              'floor' => floor.round(3), 'freeze_candidate' => freeze_candidate,
              'trough_ratios' => (frozen_ok ? hist_frozen : hist).map { |v| v.round(3) }.join(' -> '),
              'bound_live' => bound_live.round(3), 'floor_live' => floor_live.round(3),
              'trough_ratios_live' => hist.map { |v| v.round(3) }.join(' -> '),
              'trend_today' => Math.exp(trend_ln.(p[:days].size - 1)).round(-2),
              'days_below_strong' => d_strong, 'days_below_floor' => d_weak)
