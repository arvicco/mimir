#!/usr/bin/env ruby
# frozen_string_literal: true
#
# percentile.rb -- Test 5 (weight 0, monitor): Perrenod-style age-adjusted
# valuation percentile, with two fixes over the published method:
#   * empirical-rank percentile alongside the Gaussian-table number (the
#     residuals are not normal; at Z ~ -2.3 the tail shape dominates the answer)
#   * a record tracker: is today's Z merely rare, or the deepest
#     age-adjusted reading in Bitcoin's history?
#
# Method (after "How to Replace the Bitcoin Floor with Probability"):
#   1. power-law trend fit, log10 P vs log10 Age(years)
#   2. residuals r = log10 P - trend
#   3. reciprocal-decay envelope fitted per side:
#      E[|r| | side] = a / (Age + b)   (grid over b, linear solve for a)
#   4. sigma(Age) = mean * sqrt(pi/2)  (half-normal factor)
#   5. Z = r / sigma_side(Age)
#
# An extreme percentile is AMBIGUOUS -- strongest value signal ever vs
# first out-of-sample failure -- so the score encodes persistence, not level:
#   score -1  >= 60 consecutive days at/below the 1st empirical percentile
#             (mean reversion failing: evidence against the distribution)
#   score +1  an extreme (<= 5th pctile) printed within the trailing 90d
#             AND Z has since reverted above -1.0 (model behaving as claimed)
#   score  0  otherwise (monitor)

require_relative 'common'

NAME = 'percentile'
L10  = Math.log(10)
HN   = Math.sqrt(Math::PI / 2)

begin
  p = Common.load_prices
rescue StandardError => e
  Common.fail_soft(NAME, e.message)
end

n_rows = p[:px].size
age = p[:days].map { |d| d / 365.25 }
x   = age.map { |a| Math.log(a) / L10 }
y   = p[:lnp].map { |v| v / L10 }

reg = Common::RangeReg.new(x, y)
f   = reg.fit(0, n_rows - 1)
Common.fail_soft(NAME, 'trend fit failed') unless f

resid = (0...n_rows).map { |i| y[i] - (f[:icept] + f[:slope] * x[i]) }

# reciprocal-decay envelope per side: |r| ~ a / (Age + b)
fit_side = lambda do |idx|
  best = nil
  (0.0..25.0).step(0.5) do |b|
    sw2 = 0.0
    srw = 0.0
    idx.each do |i|
      w = 1.0 / (age[i] + b)
      sw2 += w * w
      srw += resid[i].abs * w
    end
    next if sw2 <= 0

    a   = srw / sw2
    sse = idx.inject(0.0) { |s, i| s + (resid[i].abs - a / (age[i] + b))**2 }
    best = { a: a, b: b, sse: sse } if best.nil? || sse < best[:sse]
  end
  best
end

pos_ix = (0...n_rows).select { |i| resid[i] >= 0 }
neg_ix = (0...n_rows).select { |i| resid[i] < 0 }
if pos_ix.size < 100 || neg_ix.size < 100
  Common.fail_soft(NAME, 'insufficient residual history')
end

ep = fit_side.(pos_ix)
en = fit_side.(neg_ix)

z = (0...n_rows).map do |i|
  e   = resid[i] >= 0 ? ep : en
  sig = (e[:a] / (age[i] + e[:b])) * HN
  resid[i] / sig
end

z_now  = z[-1]
sorted = z.sort
pct_e  = sorted.count { |v| v <= z_now }.to_f / n_rows
pct_g  = 0.5 * (1 + Math.erf(z_now / Math.sqrt(2)))

z01 = sorted[(0.01 * n_rows).floor]
z05 = sorted[(0.05 * n_rows).floor]

run01 = 0
(n_rows - 1).downto(0) do |i|
  break if z[i] > z01

  run01 += 1
end
run05 = 0
(n_rows - 1).downto(0) do |i|
  break if z[i] > z05

  run05 += 1
end

# record tracking: deepest Z before the current episode (trailing 90d excluded)
cut    = [n_rows - 90, 1].max
prior  = z[0...cut]
pmin   = prior.min
pmin_d = p[:dates][prior.index(pmin)].strftime('%Y-%m-%d')
record = z_now < pmin

recent_min = z[[n_rows - 90, 0].max..-1].min
score = 0
score = -1 if run01 >= 60
score = 1 if score.zero? && recent_min <= z05 && z_now >= -1.0

trend_px = 10**(f[:icept] + f[:slope] * x[-1])

Common.report(NAME, score,
              format('Z %.2f -> emp pctile %.2f%% (gauss %.2f%%); %dd at <=1st pct, %dd at <=5th; %s',
                     z_now, pct_e * 100, pct_g * 100, run01, run05,
                     record ? format('NEW RECORD low (prior %.2f on %s)', pmin, pmin_d) \
                            : format('record %.2f on %s', pmin, pmin_d)),
              'z' => z_now.round(2),
              'pct_emp' => (pct_e * 100).round(2),
              'pct_gauss' => (pct_g * 100).round(2),
              'trend_px' => trend_px.round(-2),
              'exponent' => f[:slope].round(3),
              'ratio_to_trend' => (p[:px][-1] / trend_px).round(3),
              'record' => record,
              'prior_min_z' => pmin.round(2), 'prior_min_date' => pmin_d,
              'days_le_p01' => run01, 'days_le_p05' => run05,
              'envelope_pos' => format('%.2f/(Age+%.1f)', ep[:a], ep[:b]),
              'envelope_neg' => format('-%.2f/(Age+%.1f)', en[:a], en[:b]))
