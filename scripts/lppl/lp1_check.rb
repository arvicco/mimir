#!/usr/bin/env ruby
# frozen_string_literal: true
#
# lp1_check.rb -- Stage-1 CHARACTERIZATION for the PL+LP1 rival (M9-9).
#
# Reproduces, on our own price cache, the SBI empirical check that motivated
# the PL+LP1 (power law + one rigid log-periodic mode) hypothesis: is there a
# single dominant log-periodic oscillation in the FULL-HISTORY residuals of the
# global power law, measured in the model's natural clock ln(age), age = days
# since genesis?
#
#   1. fit the global power law   ln P = A + B*ln(age)   over all history
#      (Lppl::RangeReg, x = ln(age), y = ln price)
#   2. Lomb-Scargle the residuals in ln(age) time over an omega grid
#      GRID = 2.0..20.0 step 0.05 (fine enough to resolve SBI's ~8.75; the
#      2..20 span brackets the plausible log-periodic band on this clock)
#   3. report peak omega, peak Lomb power, and the explained variance of the
#      SINGLE rigid mode at that omega -- r ~ c0 + c1*cos(w*u) + c2*sin(w*u)
#      by least squares, R^2 = 1 - SSE/TSS against the residual variance.
#
# Output is research-only: this script is NOT registered in publish and feeds
# NO verdict. It exists so decision item D9-d can be ruled with our own numbers
# next to SBI's (omega 8.75, ~35% variance).
#
# CAUTION (SBI, verbatim intent): this is the ln(age) clock -- NOT comparable
# to the post-peak ln(tau) omega that fit.rb / logperiodic.rb report. Two
# different clocks; do not conflate the two omegas.
#
#   ruby scripts/lppl/lp1_check.rb [--json]

require_relative 'common'

NAME = 'lp1_check'
GRID = (2.0..20.0).step(0.05).to_a

p    = Lppl.load_prices
u    = p[:days].map { |d| Math.log(d) } # ln(age) sample points
lnp  = p[:lnp]

# 1. global power law in ln(age)
f = Lppl::RangeReg.new(u, lnp).fit(0, u.size - 1)
resid = u.each_index.map { |i| lnp[i] - (f[:icept] + f[:slope] * u[i]) }

# 2. Lomb-Scargle over the ln(age) omega grid
_, peak_power, peak_omega = Lppl.lomb(u, resid, GRID)

# 3. explained variance of the single rigid mode at peak omega
cosv = u.map { |x| Math.cos(peak_omega * x) }
sinv = u.map { |x| Math.sin(peak_omega * x) }
n    = resid.size
rbar = resid.inject(:+) / n
tss  = resid.inject(0.0) { |s, r| s + (r - rbar)**2 }

# normal equations for r ~ c0 + c1*cos + c2*sin
xcols = [Array.new(n, 1.0), cosv, sinv]
xtx = Array.new(3) { Array.new(3, 0.0) }
xty = Array.new(3, 0.0)
(0...3).each do |a|
  (0...3).each { |b| xtx[a][b] = (0...n).inject(0.0) { |s, i| s + xcols[a][i] * xcols[b][i] } }
  xty[a] = (0...n).inject(0.0) { |s, i| s + xcols[a][i] * resid[i] }
end
coef = Lppl.gauss_solve(xtx, xty)
fitv = (0...n).map { |i| coef[0] + coef[1] * cosv[i] + coef[2] * sinv[i] }
sse  = (0...n).inject(0.0) { |s, i| s + (resid[i] - fitv[i])**2 }
r2   = tss.positive? ? 1.0 - sse / tss : 0.0

if ARGV.include?('--json')
  puts JSON.generate(name: NAME, peak_omega: peak_omega.round(3),
                     peak_power: peak_power.round(2), mode_r2: r2.round(4),
                     n: n, clock: 'ln(age) -- NOT comparable to post-peak ln(tau) omega')
else
  puts "PL+LP1 stage-1 characterization (ln(age) clock)"
  puts format('  global power law:  ln P = %.4f + %.4f * ln(age)   n=%d',
              f[:icept], f[:slope], n)
  puts format('  Lomb-Scargle peak: omega %.3f   power %.2f   (grid %.1f..%.1f step %.2f)',
              peak_omega, peak_power, GRID.first, GRID.last, 0.05)
  puts format('  single rigid mode: explained variance R^2 = %.1f%% of residual variance',
              r2 * 100)
  puts '  NOTE: ln(age) clock -- NOT comparable to the post-peak ln(tau) omega'
  puts '        that fit.rb / logperiodic.rb report (different clocks).'
end
