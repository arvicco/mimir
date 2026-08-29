#!/usr/bin/env ruby
# frozen_string_literal: true
#
# logperiodic.rb -- Test 4: is the oscillation real?
#
# Kills the most common LPPL self-deception: seeing omega in autocorrelated
# noise. Residuals of the post-peak pure power-decay fit are tested for
# periodicity in ln(tau) time via Lomb-Scargle; significance of the peak
# power is assessed against a parametric bootstrap null on the same uneven
# u-grid. HEADLINE + SCORE p (owner ruling 2026-08-29, register R-7 / was
# D9-f): the AR(1)+GARCH(1,1) bootstrap (p_value_v2) -- the more realistic
# null. The plain AR(1) p (field p_value) stays as the in-line reference.
#
#   score +1  p_v2 <= 0.05 and omega_peak in [6, 13]
#   score -1  p_v2 >  0.50 (clearly noise)
#   score  0  in between
#
#   ruby logperiodic.rb [--sims N]   # default 100 AR(1) reference sims
#
# The two nulls (M9-7): the AR(1) path matches only lag-1 autocorrelation +
# variance and Lomb-Scargles the simulated noise directly; the GARCH path
# additionally (a) matches GARCH(1,1) volatility clustering by conditional
# MLE and (b) re-fits the power-decay null on EACH simulated price path (the
# AR(1) path skips the refit), so p_value_v2 carries the
# refit-and-look-elsewhere variance the AR(1) p-value ignores. Fields
# p_value_v2 / sims_v2 / garch{...} / runtime_v2_s; the AR(1) fields keep
# their meaning. Default 1000 sims (~20s on the real cache); --sims-v2 N
# overrides, and LPPL_SIMS_V2 shrinks the default for the test suite.

require_relative 'common'
require_relative '../../lib/btc/util'

NAME = 'logperiodic'

SIMS = (BTC::Util.arg('--sims') || 100).to_i
# SHADOW AR(1)+GARCH bootstrap sim count (M9-7). Default 1000; --sims-v2 N or
# the LPPL_SIMS_V2 env (used by the test suite) override it.
SIMS_V2 = (BTC::Util.arg('--sims-v2') || ENV['LPPL_SIMS_V2'] || 1000).to_i

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

# ---- AR(1)+GARCH(1,1) parametric bootstrap (M9-7; HEADLINE since M11-4) ------
# Owner ruling 2026-08-29 (register R-7): the GARCH bootstrap p -- the more
# realistic null (volatility clustering) -- is the p-value we stand behind:
# it drives the SCORE and leads the headline; the AR(1) p stays as the
# in-line reference (field p_value, unchanged meaning). Both p's sat
# mid-band at the flip (AR(1) 0.376 / GARCH 0.238 -> score 0 either way);
# on a future day they disagree across a threshold, v2 governs -- that is
# the ruling working. Measured runtime rides along so cron cost is visible.
t_v2 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
boot = Lppl.arma_garch_pvalue(p, i_peak, null, obs_max, GRID, SIMS_V2, Random.new(42))
runtime_v2 = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_v2).round(2)
pval_v2 = boot[:p_value]

score = if pval_v2 <= 0.05 && w_peak >= 6.0 && w_peak <= 13.0
          1
        elsif pval_v2 > 0.50
          -1
        else
          0
        end

Lppl.report(NAME, score,
              format('LS peak omega %.1f, power %.1f, p = %.3f (GARCH, %d sims; AR(1) ref p %.3f rho %.2f)',
                     w_peak, obs_max, pval_v2, boot[:sims], pval, rho),
              'omega_peak' => w_peak.round(2), 'p_value' => pval.round(3),
              'ar1_rho' => rho.round(3), 'n_resid' => n,
              'p_value_v2' => boot[:p_value].round(3),
              'sims_v2' => boot[:sims],
              'garch' => { 'ar1' => boot[:garch][:ar1].round(4),
                           'omega' => boot[:garch][:omega].round(6),
                           'alpha' => boot[:garch][:alpha].round(4),
                           'beta' => boot[:garch][:beta].round(4),
                           'fitted' => boot[:garch][:fitted] },
              'runtime_v2_s' => runtime_v2)
