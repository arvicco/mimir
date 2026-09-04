# frozen_string_literal: true
#
# density.rb -- option-implied density engine (M13-3/M13-4, skuld S-B).
# From a book of option rows (the gex.rb shape) to smooth per-expiry
# smiles and, in part 2, Breeden-Litzenberger densities, digitals and
# quantiles. Pure functions: no IO, no ENV, no clock.
#
# INPUT (shared with lib/btc/vol.rb): rows shaped as gex.rb builds them
#   { k: strike, cp: 'C'|'P', t: years (Julian basis), iv: fraction,
#     oi: open interest, u: the row's own underlying/forward }
#
# PART 1 -- SLICES (this section)
#   Density.slices(book) groups rows by expiry and fits each liquid
#   slice with SVI in total variance (Gatheral):
#     w(k) = a + b * (rho*(k - m) + sqrt((k - m)^2 + s^2))
#   k = ln(K/F), F = the slice's mean row u. Fit: least squares over
#   ALL rows (both sides, unweighted -- v1 simplification, documented)
#   via BTC::Stats.nelder_mead with a deterministic two-stage start,
#   infeasible parameters (b<0, |rho|>=1, s<=0, negative minimum total
#   variance) priced at +Inf (box penalty, the garch_negloglik pattern).
#
#   No-arbitrage checks (REPORTED, never silently "fixed"):
#   * butterfly: Durrleman's g(k) >= 0 on a grid spanning the observed
#     strikes,
#       g = (1 - k*w'/(2w))^2 - (w'^2/4)*(1/w + 1/4) + w''/2
#     with w', w'' analytic from the SVI form.
#   * calendar: total variance non-decreasing in t on a shared k grid
#     across slices (Density.calendar_violations).
#
#   FALLBACK: a slice with < MIN_SIDE strikes per side is not fit; it
#   reports method 'nearest' + degraded: true and total_variance uses
#   the nearest observed strike's own iv (the vol.rb nearest-strike
#   philosophy) -- coarse but honest, and it keeps thin expiries alive.
#
# CAVEATS: SVI parameters are NOT unique (near-degenerate ridges); the
# contract is the fitted total-variance CURVE, not the parameter
# vector. Tests pin w(k) values, never params.

require_relative 'stats'

module BTC
  module Density
    MIN_SIDE  = 5     # strikes per side needed for an SVI fit
    RHO_CAP   = 0.999
    S_FLOOR   = 1e-4
    NM_ITER   = 800

    module_function

    # SVI total variance at log-moneyness k for params {a:, b:, rho:, m:, s:}.
    def svi_w(p, k)
      d = k - p[:m]
      p[:a] + p[:b] * (p[:rho] * d + Math.sqrt(d * d + p[:s] * p[:s]))
    end

    # Analytic first/second derivatives of the SVI total variance.
    def svi_w1(p, k)
      d = k - p[:m]
      p[:b] * (p[:rho] + d / Math.sqrt(d * d + p[:s] * p[:s]))
    end

    def svi_w2(p, k)
      d = k - p[:m]
      p[:b] * p[:s] * p[:s] / (d * d + p[:s] * p[:s])**1.5
    end

    # Durrleman butterfly function; g(k) >= 0 <=> no butterfly arbitrage
    # (and a nonnegative implied density) at k.
    def durrleman_g(p, k)
      w = svi_w(p, k)
      return -Float::INFINITY if w <= 0

      w1 = svi_w1(p, k)
      w2 = svi_w2(p, k)
      (1.0 - k * w1 / (2.0 * w))**2 - (w1 * w1 / 4.0) * (1.0 / w + 0.25) + w2 / 2.0
    end

    # book -> ascending-t array of slice hashes:
    #   { t:, days:, forward:, method: 'svi'|'nearest', degraded:,
    #     params:, rmse_w:, n_calls:, n_puts:, butterfly_ok:, reason:,
    #     k_lo:, k_hi:, rows: }
    # rows are kept on the slice (the fallback and part 2 need them).
    def slices(book)
      book.group_by { |r| r[:t] }.map { |t, rows| slice(t, rows) }
          .sort_by { |sl| sl[:t] }
    end

    def slice(t, rows)
      forward = rows.sum { |r| r[:u] } / rows.size
      calls   = rows.count { |r| r[:cp] == 'C' }
      puts_   = rows.count { |r| r[:cp] == 'P' }
      ks      = rows.map { |r| Math.log(r[:k] / forward) }
      base = { t: t, days: (t * 365.25).round(1), forward: forward,
               n_calls: calls, n_puts: puts_, rows: rows,
               k_lo: ks.min, k_hi: ks.max }

      if calls < MIN_SIDE || puts_ < MIN_SIDE
        reason = format('thin slice: %d calls, %d puts (need %d each) -- nearest-strike fallback',
                        calls, puts_, MIN_SIDE)
        return base.merge(method: 'nearest', degraded: true, params: nil,
                          rmse_w: nil, butterfly_ok: nil, reason: reason)
      end

      obs = rows.map { |r| [Math.log(r[:k] / forward), r[:iv] * r[:iv] * t] }
      params, rmse = fit_svi(obs)
      ok = butterfly_ok?(params, ks.min, ks.max)
      base.merge(method: 'svi', degraded: false, params: params,
                 rmse_w: rmse, butterfly_ok: ok, reason: nil)
    end

    # Least-squares SVI fit on [[k, w], ...]. Deterministic two-stage
    # Nelder-Mead (the second stage restarts from the first's best with
    # tighter steps). Returns [params_hash, rmse_in_w].
    def fit_svi(obs)
      w_atm = obs.min_by { |k, _| k.abs }[1]
      objective = lambda do |x|
        a, b, rho, m, s = x
        return Float::INFINITY if b.negative? || rho.abs >= RHO_CAP || s < S_FLOOR
        return Float::INFINITY if a + b * s * Math.sqrt(1.0 - rho * rho) < 0

        p = { a: a, b: b, rho: rho, m: m, s: s }
        obs.sum { |k, w| (svi_w(p, k) - w)**2 }
      end
      x0    = [0.8 * w_atm, 0.1 * [w_atm, 1e-3].max, 0.0, 0.0, 0.2]
      steps = [0.5 * [w_atm, 1e-3].max, 0.05, 0.3, 0.2, 0.1]
      x1, = BTC::Stats.nelder_mead(x0, steps, max_iter: NM_ITER, &objective)
      x2, f2 = BTC::Stats.nelder_mead(x1, steps.map { |v| v * 0.1 },
                                      max_iter: NM_ITER, &objective)
      a, b, rho, m, s = x2
      [{ a: a, b: b, rho: rho, m: m, s: s }, Math.sqrt(f2 / obs.size)]
    end

    # Durrleman check on a grid spanning the observed strikes (+ margin).
    def butterfly_ok?(params, k_lo, k_hi, n: 81, tol: -1e-8)
      pad  = 0.1 * [k_hi - k_lo, 0.1].max
      lo   = k_lo - pad
      step = (k_hi + pad - lo) / (n - 1)
      (0...n).all? { |i| durrleman_g(params, lo + i * step) >= tol }
    end

    # Total variance for a slice at log-moneyness k, honoring the
    # slice's method (SVI curve or nearest-strike fallback).
    def total_variance(sl, k)
      return svi_w(sl[:params], k) if sl[:method] == 'svi'

      row = sl[:rows].min_by { |r| (Math.log(r[:k] / sl[:forward]) - k).abs }
      row[:iv] * row[:iv] * sl[:t]
    end

    # Calendar-arbitrage scan: for each adjacent slice pair, total
    # variance must be non-decreasing in t on a shared k grid. Returns
    # [{ t0:, t1:, k:, w0:, w1: }, ...] -- empty = clean.
    def calendar_violations(slices, n: 21, tol: 1e-10)
      out = []
      slices.each_cons(2) do |s0, s1|
        lo = [s0[:k_lo], s1[:k_lo]].max
        hi = [s0[:k_hi], s1[:k_hi]].min
        next if hi <= lo

        step = (hi - lo) / (n - 1)
        (0...n).each do |i|
          k  = lo + i * step
          w0 = total_variance(s0, k)
          w1 = total_variance(s1, k)
          out << { t0: s0[:t], t1: s1[:t], k: k, w0: w0, w1: w1 } if w1 < w0 - tol
        end
      end
      out
    end
  end
end
