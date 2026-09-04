# frozen_string_literal: true
#
# stats.rb -- shared statistical machinery (M13-1). Home of the pure
# numeric workhorses that started life inside the LPPL suite and are
# now needed by more than one family (the skuld distribution scoring
# uses the Newey-West SE; its SVI smile fits use Nelder-Mead).
#
# EXTRACTION CONTRACT: both functions moved VERBATIM from
# scripts/lppl/common.rb (M11-3 / M9-7); Lppl.newey_west_se and
# Lppl.nelder_mead delegate here, so every LPPL call site and every
# published LPPL number is byte-identical before and after the move.
# Behavior changes to either function are analytics-semantics changes
# (Golden Rule 4) -- do not touch without a ruling.
#
# Pure functions only: no IO, no ENV, no clock, deterministic.

module BTC
  module Stats
    module_function

    # Newey-West (Bartlett-kernel) standard error of the MEAN of +xs+ under
    # serial dependence up to +lag+ (M11-3, owner ruling 2026-08-29 R-3 --
    # the error bar on the trend test's per-eval-mean headline; overlapping
    # forecast horizons make the daily differentials strongly autocorrelated,
    # so a plain sd/sqrt(n) would be far too tight). lag truncates to n-1.
    #   var(mean) = (g0 + 2 * sum_{l=1..L} (1 - l/(L+1)) * g_l) / n
    # with g_l the lag-l autocovariance in the 1/n convention. Bartlett
    # weights keep the estimate PSD; a tiny negative from fp dust clamps to
    # 0. Returns nil below 2 points.
    def newey_west_se(xs, lag:)
      n = xs.size
      return nil if n < 2

      mu = xs.sum / n.to_f
      l_max = [lag, n - 1].min
      gamma = ->(l) { (l...n).sum { |i| (xs[i] - mu) * (xs[i - l] - mu) } / n.to_f }
      v = gamma.call(0)
      (1..l_max).each { |l| v += 2.0 * (1.0 - l.to_f / (l_max + 1)) * gamma.call(l) }
      v = 0.0 if v.negative?
      Math.sqrt(v / n)
    end

    # Downhill-simplex (Nelder-Mead) minimizer, pure Ruby. Deterministic: the
    # start simplex is x0 plus one per-dimension step, so the same inputs always
    # trace the same path. Reflection 1, expansion 2, contraction/shrink 0.5.
    # Returns [x_best, f_best].
    def nelder_mead(x0, steps, max_iter: 400, tol: 1e-10)
      n  = x0.size
      sx = [x0.dup]
      n.times { |i| pt = x0.dup; pt[i] += steps[i]; sx << pt }
      fx = sx.map { |pt| yield(pt) }
      max_iter.times do
        ord = (0..n).sort_by { |i| fx[i] }
        sx  = ord.map { |i| sx[i] }
        fx  = ord.map { |i| fx[i] }
        break if (fx[n] - fx[0]).abs <= tol * (fx[0].abs + tol)

        cen = Array.new(n, 0.0)
        (0...n).each { |i| (0...n).each { |d| cen[d] += sx[i][d] } }
        cen.map! { |v| v / n }
        worst = sx[n]
        xr = Array.new(n) { |d| cen[d] + (cen[d] - worst[d]) }
        fr = yield(xr)
        if fr < fx[0]
          xe = Array.new(n) { |d| cen[d] + 2.0 * (xr[d] - cen[d]) }
          fe = yield(xe)
          if fe < fr then sx[n] = xe; fx[n] = fe else sx[n] = xr; fx[n] = fr end
        elsif fr < fx[n - 1]
          sx[n] = xr; fx[n] = fr
        else
          xc = Array.new(n) { |d| cen[d] + 0.5 * (worst[d] - cen[d]) }
          fc = yield(xc)
          if fc < fx[n]
            sx[n] = xc; fx[n] = fc
          else
            best = sx[0]
            (1..n).each do |i|
              sx[i] = Array.new(n) { |d| best[d] + 0.5 * (sx[i][d] - best[d]) }
              fx[i] = yield(sx[i])
            end
          end
        end
      end
      bi = (0..n).min_by { |i| fx[i] }
      [sx[bi], fx[bi]]
    end

    # Standard normal CDF / inverse CDF (M13-5 -- the dist benchmarks'
    # analytic lognormal quantiles). The inverse is a deterministic
    # 80-step bisection on the erfc-based CDF: ~1e-16 accurate over
    # p in (1e-9, 1-1e-9), no rational-approximation magic constants.
    def norm_cdf(x)
      0.5 * Math.erfc(-x / Math.sqrt(2))
    end

    def norm_ppf(p)
      raise ArgumentError, "p out of (0,1): #{p}" if p <= 0 || p >= 1

      lo = -8.0
      hi = 8.0
      80.times do
        mid = 0.5 * (lo + hi)
        norm_cdf(mid) < p ? lo = mid : hi = mid
      end
      0.5 * (lo + hi)
    end
  end
end
