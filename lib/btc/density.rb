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
#
# PART 2 -- DENSITIES (M13-4)
#   Density.density_from_w builds the implied density from ANY total-
#   variance curve w(k) (an SVI slice, a nearest fallback, or a term-
#   interpolated horizon):
#   * inner region (between the 10-delta strikes): Black calls (r = 0,
#     forward measure) on a uniform price grid, Breeden-Litzenberger by
#     central second differences, negatives clamped to 0 (clamped mass
#     reported, never hidden).
#   * wings (beyond 10-delta): a LOGNORMAL matched to the boundary
#     density in level and slope -- the 1-D solve for sigma is a
#     guaranteed bisection (the level equation is strictly decreasing
#     in sigma); a degenerate boundary (density <= 0) falls back to a
#     level-only match at the local implied vol, flagged wing_matched
#     false. Wing mass is ALWAYS reported; tail numbers beyond the last
#     liquid strike are only as good as the wing model (per-concept
#     flag, never silent).
#   * the assembled grid is renormalized to integrate to 1
#     (integral_raw reports how far off the raw assembly was).
#   Quantiles at TAUS, digitals P(S_T > K) read off the assembled CDF,
#   one-touch as the driftless-lognormal 2x-digital approximation.
#
#   Term structure: Density.horizon interpolates total variance
#   LINEARLY IN TIME at fixed log-moneyness between bracketing slices
#   (forward log-interpolated); horizons before the first / beyond the
#   last liquid expiry scale that slice's curve by t/t_slice and are
#   flagged (extrapolated -- flat forward vol assumption).

require_relative 'stats'
require_relative 'options'

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

    # ---- part 2: densities, quantiles, digitals ------------------------------

    # Published quantile levels: 1% tails + a 5% ladder. Every stored
    # density is this grid; DistScoring scores it directly.
    TAUS = ([0.01] + (1..19).map { |i| (i * 0.05).round(2) } + [0.99]).freeze

    WING_DELTA = 0.10 # wings take over beyond the 10-delta strikes
    INNER_N    = 241  # inner price-grid points
    WING_N     = 60   # points per wing
    WING_SPAN  = 6.0  # wing grid reaches mu +/- WING_SPAN*sigma

    # Undiscounted Black call on the forward measure (r = 0), from total
    # variance w at that strike.
    def black_call(f, strike, w)
      return [f - strike, 0.0].max if w <= 0

      sq = Math.sqrt(w)
      d1 = (Math.log(f / strike) + 0.5 * w) / sq
      f * Options.norm_cdf(d1) - strike * Options.norm_cdf(d1 - sq)
    end

    # Density of lognormal(mu, sigma) at price x.
    def lognormal_pdf(x, mu, sigma)
      z = (Math.log(x) - mu) / sigma
      Math.exp(-0.5 * z * z) / (x * sigma * Math.sqrt(2 * Math::PI))
    end

    # Solve the wing lognormal matched to density level q_b and log-slope
    # r = q'(x_b)/q(x_b) at boundary x_b. With c = r*x_b + 1 the level
    # equation  q_b = exp(-sigma^2 c^2 / 2) / (x_b sigma sqrt(2pi))  is
    # strictly decreasing in sigma -> unique root, plain bisection.
    # Returns [mu, sigma] or nil when q_b is degenerate.
    def solve_wing(x_b, q_b, r)
      return nil if q_b <= 0 || !q_b.finite? || !r.finite?

      c = r * x_b + 1.0
      level = ->(sig) { Math.exp(-0.5 * sig * sig * c * c) / (x_b * sig * Math.sqrt(2 * Math::PI)) }
      lo = 1e-4
      hi = 10.0
      return nil if level.call(lo) < q_b || level.call(hi) > q_b

      60.times do
        mid = 0.5 * (lo + hi)
        level.call(mid) > q_b ? lo = mid : hi = mid
      end
      sigma = 0.5 * (lo + hi)
      [Math.log(x_b) + sigma * sigma * c, sigma]
    end

    # Log-moneyness of the WING_DELTA call/put boundaries under w(k),
    # clamped to [k_lo, k_hi]. Scans a fine grid (w is arbitrary here,
    # no closed form).
    def wing_bounds(w_fn, k_lo, k_hi, n: 201)
      step = (k_hi - k_lo) / (n - 1)
      grid = (0...n).map { |i| k_lo + i * step }
      deltas = grid.map do |k|
        w = w_fn.call(k)
        w <= 0 ? (k.negative? ? 1.0 : 0.0) : Options.norm_cdf((-k + 0.5 * w) / Math.sqrt(w))
      end
      k_put  = grid.zip(deltas).find { |_, d| d < 1.0 - WING_DELTA }&.first || k_lo
      k_call = grid.zip(deltas).reverse.find { |_, d| d > WING_DELTA }&.first || k_hi
      k_call = [k_call, k_put + 4 * step].max # never collapse the inner grid
      [k_put, k_call]
    end

    # The full pipeline from a total-variance curve to a density record:
    #   { xs:, pdf:, cdf:, quantiles: [[tau, price], ...],
    #     integral_raw:, clamped:, wing_mass: {left:, right:},
    #     wing_matched: {left:, right:}, forward: }
    def density_from_w(forward, w_fn, k_lo, k_hi)
      kp, kc = wing_bounds(w_fn, k_lo, k_hi)
      x_lo = forward * Math.exp(kp)
      x_hi = forward * Math.exp(kc)
      dx = (x_hi - x_lo) / (INNER_N - 1)
      # one extra strike each side so central differences cover the edges
      xs_in = (-1..INNER_N).map { |i| x_lo + i * dx }
      calls = xs_in.map { |x| black_call(forward, x, w_fn.call(Math.log(x / forward))) }
      clamped = 0.0
      pdf_in = (1...(xs_in.size - 1)).map do |i|
        q = (calls[i + 1] - 2 * calls[i] + calls[i - 1]) / (dx * dx)
        clamped += q.abs * dx if q.negative?
        [q, 0.0].max
      end
      xs_in = xs_in[1...-1]

      left  = wing(xs_in.first, pdf_in[0], (pdf_in[1] - pdf_in[0]) / dx,
                   w_fn, forward, :left)
      right = wing(xs_in.last, pdf_in[-1], (pdf_in[-1] - pdf_in[-2]) / dx,
                   w_fn, forward, :right)

      xs  = left[:xs] + xs_in + right[:xs]
      pdf = left[:pdf] + pdf_in + right[:pdf]

      raw = trapezoid(xs, pdf)
      pdf = pdf.map { |v| v / raw } if raw.positive?
      cdf = cumulative(xs, pdf)
      { xs: xs, pdf: pdf, cdf: cdf, quantiles: quantiles(xs, cdf),
        integral_raw: raw, clamped: clamped,
        wing_mass: { left: cdf_at(xs, cdf, xs_in.first),
                     right: 1.0 - cdf_at(xs, cdf, xs_in.last) },
        wing_matched: { left: left[:matched], right: right[:matched] },
        forward: forward }
    end

    # One wing: lognormal matched in level+slope at the boundary, or a
    # level-only local-vol lognormal when the boundary is degenerate.
    def wing(x_b, q_b, slope, w_fn, forward, side)
      mu, sigma = solve_wing(x_b, q_b, slope / (q_b.positive? ? q_b : 1.0))
      matched = !mu.nil?
      unless matched
        w = [w_fn.call(Math.log(x_b / forward)), 1e-6].max
        sigma = Math.sqrt(w)
        mu = Math.log(forward) - 0.5 * w
      end
      lo, hi = side == :left ? [mu - WING_SPAN * sigma, Math.log(x_b)] : [Math.log(x_b), mu + WING_SPAN * sigma]
      return { xs: [], pdf: [], matched: matched } if hi <= lo

      step = (hi - lo) / WING_N
      pts = (0...WING_N).map { |i| Math.exp(lo + i * step) }
      pts = pts.select { |x| side == :left ? x < x_b : x > x_b }.sort
      { xs: pts, pdf: pts.map { |x| lognormal_pdf(x, mu, sigma) }, matched: matched }
    end

    def trapezoid(xs, ys)
      (1...xs.size).sum { |i| 0.5 * (ys[i] + ys[i - 1]) * (xs[i] - xs[i - 1]) }
    end

    def cumulative(xs, ys)
      acc = 0.0
      out = [0.0]
      (1...xs.size).each do |i|
        acc += 0.5 * (ys[i] + ys[i - 1]) * (xs[i] - xs[i - 1])
        out << acc
      end
      # guard fp dust so the CDF is a proper, monotone [0,1] map
      out.map { |v| v.clamp(0.0, 1.0) }
    end

    def cdf_at(xs, cdf, x)
      return 0.0 if x <= xs.first
      return 1.0 if x >= xs.last

      i = xs.bsearch_index { |v| v >= x }
      x0 = xs[i - 1]
      x1 = xs[i]
      f0 = cdf[i - 1]
      f1 = cdf[i]
      x1 == x0 ? f1 : f0 + (f1 - f0) * (x - x0) / (x1 - x0)
    end

    def quantiles(xs, cdf, taus: TAUS)
      taus.map do |tau|
        i = cdf.bsearch_index { |v| v >= tau }
        q = if i.nil? then xs.last
            elsif i.zero? then xs.first
            else
              f0 = cdf[i - 1]
              f1 = cdf[i]
              f1 == f0 ? xs[i] : xs[i - 1] + (xs[i] - xs[i - 1]) * (tau - f0) / (f1 - f0)
            end
        [tau, q]
      end
    end

    # P(S_T > strike) off the assembled CDF.
    def digital(den, strike)
      1.0 - cdf_at(den[:xs], den[:cdf], strike)
    end

    # pdf interpolated at x (0 outside the grid).
    def pdf_at(den, x)
      xs = den[:xs]
      return 0.0 if x <= xs.first || x >= xs.last

      i = xs.bsearch_index { |v| v >= x }
      x0 = xs[i - 1]
      x1 = xs[i]
      y0 = den[:pdf][i - 1]
      y1 = den[:pdf][i]
      x1 == x0 ? y1 : y0 + (y1 - y0) * (x - x0) / (x1 - x0)
    end

    # KL(P || Q) between two density records (M13-7 -- cross-venue
    # divergence). Evaluated on the overlap of the two supports, both
    # renormalized over that window first (so support truncation is not
    # misread as divergence); q floored at 1e-12. nil when the supports
    # do not overlap or either mass vanishes.
    def kl(p, q, n: 201)
      lo = [p[:xs].first, q[:xs].first].max
      hi = [p[:xs].last, q[:xs].last].min
      return nil if hi <= lo

      step = (hi - lo) / (n - 1)
      xs = (0...n).map { |i| lo + i * step }
      ps = xs.map { |x| pdf_at(p, x) }
      qs = xs.map { |x| pdf_at(q, x) }
      zp = trapezoid(xs, ps)
      zq = trapezoid(xs, qs)
      return nil if zp <= 0 || zq <= 0

      vals = (0...n).map do |i|
        pi = ps[i] / zp
        qi = [qs[i] / zq, 1e-12].max
        pi <= 0 ? 0.0 : pi * Math.log(pi / qi)
      end
      trapezoid(xs, vals)
    end

    # Driftless one-touch approximation: ~2x the terminal probability of
    # ending beyond the barrier (paths that touch and come back are the
    # other half). Capped at 1; anything better needs simulated paths
    # (a later skuld slice).
    def touch(den, strike)
      p = digital(den, strike)
      strike >= den[:forward] ? [2.0 * p, 1.0].min : [2.0 * (1.0 - p), 1.0].min
    end

    # ---- term structure ------------------------------------------------------

    # Interpolated total-variance curve at t_target years:
    #   { t:, forward:, w_fn:, k_lo:, k_hi:, extrapolated:, degraded: }
    # Linear in time at fixed log-moneyness between bracketing slices;
    # before the first / beyond the last slice the nearest curve is
    # scaled by t/t_slice (flat forward vol) and flagged extrapolated.
    def horizon(slices, t_target)
      raise ArgumentError, 'no slices' if slices.empty?

      first = slices.first
      last  = slices.last
      if t_target <= first[:t] || slices.size == 1 || t_target >= last[:t]
        sl = t_target <= first[:t] ? first : last
        scale = t_target / sl[:t]
        return { t: t_target, forward: sl[:forward],
                 w_fn: ->(k) { total_variance(sl, k) * scale },
                 k_lo: sl[:k_lo], k_hi: sl[:k_hi],
                 extrapolated: !(t_target >= first[:t] && t_target <= last[:t]),
                 degraded: sl[:degraded] }
      end

      s0 = slices.take_while { |sl| sl[:t] <= t_target }.last
      s1 = slices.find { |sl| sl[:t] >= t_target }
      return horizon([s0], t_target).merge(extrapolated: false) if s0.equal?(s1)

      alpha = (t_target - s0[:t]) / (s1[:t] - s0[:t])
      fwd = Math.exp((1 - alpha) * Math.log(s0[:forward]) + alpha * Math.log(s1[:forward]))
      { t: t_target, forward: fwd,
        w_fn: lambda { |k|
          (1 - alpha) * total_variance(s0, k) + alpha * total_variance(s1, k)
        },
        k_lo: [s0[:k_lo], s1[:k_lo]].max, k_hi: [s0[:k_hi], s1[:k_hi]].min,
        extrapolated: false, degraded: s0[:degraded] || s1[:degraded] }
    end

    # Density at an arbitrary horizon (years).
    def horizon_density(slices, t_target)
      h = horizon(slices, t_target)
      density_from_w(h[:forward], h[:w_fn], h[:k_lo], h[:k_hi])
        .merge(t: h[:t], extrapolated: h[:extrapolated], degraded: h[:degraded])
    end

    # Density for one fitted slice.
    def expiry_density(sl)
      density_from_w(sl[:forward], ->(k) { total_variance(sl, k) }, sl[:k_lo], sl[:k_hi])
        .merge(t: sl[:t], extrapolated: false, degraded: sl[:degraded])
    end
  end
end
