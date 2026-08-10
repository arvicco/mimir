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
# Ratios are computed against today's full-history power-law fit, so the
# bound updates consistently as the trend re-estimates.
#
# freeze_candidate (M9-4, additive, report-only): the strong bound drifts
# every day because it is the 2022 trough ratio recomputed against TODAY's
# re-estimated trend. This field is that same bound FROZEN -- the 2022 trough
# ratio measured against the trend as it stood through the 2022 trough itself
# (a fit on data up to that date), the value a "freeze each cycle's bound
# before the subsequent trough" rule (D9-g) would lock. Report-only; the live
# bound/floor/score are unchanged (Golden Rule 4).

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

bound = hist.last          # strong form: damping means new trough > 2022 ratio
floor = hist.min           # weak form
r_now = ratio_at.(p[:days].size - 1)

# freeze_candidate (report-only): the 2022 bound measured against the trend
# frozen at the 2022 trough, i.e. a fit on data only up to that trough date --
# what a pre-subsequent-trough freeze rule (D9-g) would lock, independent of
# today's re-estimated trend.
last_trough_ix   = date_ix[TROUGHS.last]
freeze_candidate = if last_trough_ix && (ff = reg.fit(0, last_trough_ix))
                     Math.exp(p[:lnp][last_trough_ix] -
                              (ff[:icept] + ff[:slope] * xs[last_trough_ix])).round(3)
                   end

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
              format('price/trend %.3f vs bound %.3f (floor %.3f) -- %s; %dd below strong, %dd below floor',
                     r_now, bound, floor, state, d_strong, d_weak),
              'ratio' => r_now.round(3), 'bound' => bound.round(3),
              'floor' => floor.round(3), 'freeze_candidate' => freeze_candidate,
              'trough_ratios' => hist.map { |v| v.round(3) }.join(' -> '),
              'trend_today' => Math.exp(trend_ln.(p[:days].size - 1)).round(-2),
              'days_below_strong' => d_strong, 'days_below_floor' => d_weak)
