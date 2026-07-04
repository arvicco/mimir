#!/usr/bin/env ruby
# frozen_string_literal: true
#
# logperiodic.rb -- Test 4: is the oscillation real?
#
# Kills the most common LPPL self-deception: seeing omega in autocorrelated
# noise. Residuals of the post-peak pure power-decay fit are tested for
# periodicity in ln(tau) time via Lomb-Scargle; significance of the peak
# power is assessed against an AR(1) bootstrap null with matched lag-1
# autocorrelation and variance, evaluated on the same uneven u-grid.
#
#   score +1  p <= 0.05 and omega_peak in [6, 13]
#   score -1  p >  0.50 (clearly noise)
#   score  0  in between
#
#   ruby logperiodic.rb [--sims N]   # default 100 bootstrap sims

require_relative 'common'
require_relative '../../lib/btc/util'

NAME = 'logperiodic'

SIMS = (BTC::Util.arg('--sims') || 100).to_i

begin
  p = Lppl.load_prices
rescue StandardError => e
  Lppl.fail_soft(NAME, e.message)
end

i_peak = Lppl.detect_peak(p)
Lppl.fail_soft(NAME, 'no post-peak window') if i_peak.nil? ||
                                                 p[:dates].size - i_peak < 90

null = Lppl.power_decay_fit(p, i_peak)
Lppl.fail_soft(NAME, 'power-decay null failed') unless null

u = null[:u]
r = null[:resid]
n = r.size

# ---- Lomb-Scargle over angular frequency grid (Lppl.lomb) ---------------------
GRID = (2.0..20.0).step(0.1).to_a

_, obs_max, w_peak = Lppl.lomb(u, r, GRID)

# ---- AR(1) bootstrap null ----------------------------------------------------
mu  = r.inject(:+) / n
rc  = r.map { |v| v - mu }
v0  = rc.inject(0.0) { |s, v| s + v * v } / n
v1  = (1...n).inject(0.0) { |s, i| s + rc[i] * rc[i - 1] } / (n - 1)
rho = v0 > 0 ? [[v1 / v0, 0.99].min, -0.99].max : 0.0
se  = Math.sqrt([v0 * (1 - rho * rho), 1e-12].max)

def gauss(rng)
  Math.sqrt(-2 * Math.log(1 - rng.rand)) * Math.cos(2 * Math::PI * rng.rand)
end

rng  = Random.new(42)
hits = 0
SIMS.times do
  x   = 0.0
  sim = Array.new(n) { x = rho * x + se * gauss(rng) }
  _, smax, = Lppl.lomb(u, sim, GRID)
  hits += 1 if smax >= obs_max
end
pval = (hits + 1).to_f / (SIMS + 1)

score = if pval <= 0.05 && w_peak >= 6.0 && w_peak <= 13.0
          1
        elsif pval > 0.50
          -1
        else
          0
        end

Lppl.report(NAME, score,
              format('LS peak omega %.1f, power %.1f, p = %.3f (AR(1) rho %.2f, %d sims)',
                     w_peak, obs_max, pval, rho, SIMS),
              'omega_peak' => w_peak.round(2), 'p_value' => pval.round(3),
              'ar1_rho' => rho.round(3), 'n_resid' => n)
