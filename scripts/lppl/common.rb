# frozen_string_literal: true
#
# common.rb -- shared machinery for the LPPL evidence suite.
# Ruby >= 2.5, stdlib only.
#
# Replay: an optional `--as-of YYYY-MM-DD` flag (parsed once via Lppl.as_of)
# makes the suite compute exactly as a live run on wall-clock day DATE would
# have, from the price cache alone. load_prices then truncates the series in
# memory to rows strictly before AS_OF (a live run on D excludes the
# incomplete current day, so it sees prices through D-1); Lppl.now_utc freezes
# every wall-clock anchor to AS_OF. Absent the flag, behavior is unchanged.

require 'json'
require 'time'
require 'fileutils'
require_relative '../../lib/btc/report'
require_relative '../../lib/btc/env'
require_relative '../../lib/btc/http'

module Lppl
  GENESIS = Time.utc(2009, 1, 3)
  DATA    = BTC::Env.data_dir('lppl', File.join(File.expand_path(__dir__), 'data'))
  PRICES  = File.join(DATA, 'prices.csv')

  AS_OF_RE = /\A\d{4}-\d{2}-\d{2}\z/

  module_function

  # ---- replay clock ----------------------------------------------------------

  # Parse --as-of from ARGV once. Returns the Time.utc midnight it names, or
  # nil when the flag is absent. A malformed value aborts (exit 2) with usage
  # -- replay must never silently run against the wrong day.
  def as_of
    return @as_of if defined?(@as_of)

    i = ARGV.index('--as-of')
    return @as_of = nil if i.nil?

    v = ARGV[i + 1]
    abort_as_of(v) unless v && v =~ AS_OF_RE
    y, m, d = v.split('-').map(&:to_i)
    t = begin
      Time.utc(y, m, d)
    rescue ArgumentError
      abort_as_of(v)
    end
    # Time.utc silently rolls impossible days over (2026-02-30 -> 2026-03-02);
    # a replay must never run against a day the caller did not name.
    abort_as_of(v) unless t.strftime('%Y-%m-%d') == v
    @as_of = t
  end

  def abort_as_of(v)
    warn "as-of: invalid date #{v.inspect} -- expected YYYY-MM-DD"
    warn 'usage: --as-of YYYY-MM-DD'
    exit 2
  end

  # Wall clock for the run: AS_OF when replaying, else the real now.
  def now_utc
    as_of || Time.now.utc
  end

  # ---- IO / reporting --------------------------------------------------------

  # Crash-safe file replace (C5): write a same-directory temp file, rename
  # over the target. A crash mid-write leaves the original untouched; the
  # temp is removed on any failure. Rename is atomic on the same filesystem.
  def atomic_write(path)
    tmp = "#{path}.tmp-#{Process.pid}"
    File.open(tmp, 'w') { |f| yield f }
    File.rename(tmp, path)
  ensure
    File.unlink(tmp) if File.exist?(tmp)
  end

  def get_json(url, headers = {})
    BTC::Http.get_json(url, { 'User-Agent' => 'lppl.rb' }.merge(headers),
                       read_timeout: 60)
  end

  # Uniform module contract. score in -1/0/+1: +1 supports LPPL-as-regime,
  # -1 is evidence against, 0 neutral/insufficient. detail keys are consumed
  # by the aggregator (lppl.rb).
  def report(name, score, headline, detail = {})
    BTC::Report.report(name, score, headline, detail, name_w: 12, key_w: 16,
                       now: now_utc)
  end

  def fail_soft(name, err)
    BTC::Report.fail_soft(name, err, name_w: 12)
  end

  # ---- price cache -----------------------------------------------------------

  # Returns { dates: [Time], days: [Float, days since genesis],
  #           lnp: [Float], px: [Float] }, ascending, zero/dust rows dropped.
  # In as-of mode the series is truncated in memory to rows strictly before
  # AS_OF (the cache file is never rewritten).
  def load_prices
    raise 'price cache missing -- run prices.rb first' unless File.exist?(PRICES)

    cutoff = as_of
    dates = []
    px    = []
    File.foreach(PRICES) do |ln|
      d, c = ln.strip.split(',')
      next if d.nil? || d == 'date'

      t = Time.utc(*d.split('-').map { |s| s.to_i })
      next if cutoff && t >= cutoff

      v = c.to_f
      next if v < 0.05

      dates << t
      px << v
    end
    raise 'price cache empty' if px.empty?

    { dates: dates,
      days: dates.map { |t| (t - GENESIS) / 86_400.0 },
      lnp: px.map { |v| Math.log(v) },
      px: px }
  end

  # ---- regression machinery ---------------------------------------------------

  # O(1) linear regression over any index range [a, b] of fixed (xs, ys),
  # via prefix sums. Used for power-law trend fits (x = ln day, y = ln price).
  class RangeReg
    def initialize(xs, ys)
      n = xs.size
      @cx  = Array.new(n + 1, 0.0)
      @cy  = Array.new(n + 1, 0.0)
      @cxx = Array.new(n + 1, 0.0)
      @cxy = Array.new(n + 1, 0.0)
      @cyy = Array.new(n + 1, 0.0)
      (0...n).each do |i|
        @cx[i + 1]  = @cx[i] + xs[i]
        @cy[i + 1]  = @cy[i] + ys[i]
        @cxx[i + 1] = @cxx[i] + xs[i] * xs[i]
        @cxy[i + 1] = @cxy[i] + xs[i] * ys[i]
        @cyy[i + 1] = @cyy[i] + ys[i] * ys[i]
      end
    end

    # y = icept + slope * x fitted on rows a..b inclusive.
    def fit(a, b)
      n = (b - a + 1).to_f
      return nil if n < 3

      sx  = @cx[b + 1] - @cx[a]
      sy  = @cy[b + 1] - @cy[a]
      sxx = @cxx[b + 1] - @cxx[a]
      sxy = @cxy[b + 1] - @cxy[a]
      syy = @cyy[b + 1] - @cyy[a]
      den = n * sxx - sx * sx
      return nil if den.abs < 1e-12

      slope = (n * sxy - sx * sy) / den
      icept = (sy - slope * sx) / n
      sse   = syy + n * icept * icept + slope * slope * sxx -
              2 * icept * sy - 2 * slope * sxy + 2 * icept * slope * sx
      sse = 0.0 if sse < 0
      { n: n, slope: slope, icept: icept, sse: sse,
        sigma2: sse / [n - 2, 1].max }
    end
  end

  # O(1)-per-fit least squares for the FIXED 4-column PL+LP1 design
  # [1, ln(age), cos(w*ln age), sin(w*ln age)] with omega fixed -- the rigid
  # single-mode rival (M9-9). The mirror of RangeReg: prefix sums of X'X, X'y,
  # y'y let any [0, b] prefix fit be assembled in O(1). Report-only; it feeds a
  # SEPARATE trend cache and never the frozen rival set.
  class PlLp1Reg
    def initialize(u, y, omega)
      n     = u.size
      @u    = u
      @cw   = u.map { |x| Math.cos(omega * x) }
      @sw   = u.map { |x| Math.sin(omega * x) }
      cols  = [Array.new(n, 1.0), u, @cw, @sw]
      @sxx  = Array.new(4) { Array.new(4) { Array.new(n + 1, 0.0) } }
      @sxy  = Array.new(4) { Array.new(n + 1, 0.0) }
      @syy  = Array.new(n + 1, 0.0)
      (0...n).each do |i|
        @syy[i + 1] = @syy[i] + y[i] * y[i]
        (0...4).each do |a|
          @sxy[a][i + 1] = @sxy[a][i] + cols[a][i] * y[i]
          (a...4).each { |b| @sxx[a][b][i + 1] = @sxx[a][b][i] + cols[a][i] * cols[b][i] }
        end
      end
    end

    # Fit on rows 0..b inclusive. Returns { coef: [4], sigma2: } or nil.
    def fit(b)
      m = b + 1
      return nil if m < 6

      xtx = Array.new(4) { Array.new(4, 0.0) }
      xty = Array.new(4, 0.0)
      (0...4).each do |a|
        xty[a] = @sxy[a][b + 1]
        (a...4).each { |c| xtx[a][c] = @sxx[a][c][b + 1]; xtx[c][a] = xtx[a][c] }
      end
      coef = Lppl.gauss_solve(xtx, xty)
      return nil unless coef

      bxy = (0...4).inject(0.0) { |s, a| s + coef[a] * xty[a] }
      bxb = 0.0
      (0...4).each { |a| (0...4).each { |c| bxb += coef[a] * xtx[a][c] * coef[c] } }
      sse = @syy[b + 1] - 2 * bxy + bxb
      sse = 0.0 if sse < 0
      { coef: coef, sigma2: sse / [m - 4, 1].max }
    end

    # Design row at index i, for forecasting at the eval point.
    def row(i)
      [1.0, @u[i], @cw[i], @sw[i]]
    end
  end

  # Gaussian elimination with partial pivoting; a is NxN (array of rows),
  # b is length-N. Returns solution array or nil if singular.
  def gauss_solve(a, b)
    n = b.size
    m = a.map { |row| row.dup }
    v = b.dup
    (0...n).each do |col|
      piv = (col...n).max_by { |r| m[r][col].abs }
      return nil if m[piv][col].abs < 1e-12

      m[col], m[piv] = m[piv], m[col]
      v[col], v[piv] = v[piv], v[col]
      ((col + 1)...n).each do |r|
        f = m[r][col] / m[col][col]
        next if f.zero?

        ((col)...n).each { |c| m[r][c] -= f * m[col][c] }
        v[r] -= f * v[col]
      end
    end
    x = Array.new(n, 0.0)
    (n - 1).downto(0) do |r|
      s = v[r]
      ((r + 1)...n).each { |c| s -= m[r][c] * x[c] }
      x[r] = s / m[r][r]
    end
    x
  end

  # Lomb-Scargle normalized periodogram over an angular-frequency grid,
  # on the (uneven) sample points u. Returns [powers, peak_power,
  # peak_frequency]; [[], 0.0, 0.0] for zero-variance input.
  # (Extracted verbatim from logperiodic.rb for characterization, M0-6.)
  def lomb(u, r, grid)
    n    = r.size
    mu   = r.inject(:+) / n
    rc   = r.map { |v| v - mu }
    var  = rc.inject(0.0) { |s, v| s + v * v } / n
    return [[], 0.0, 0.0] if var <= 0

    pw = grid.map do |w|
      s2 = 0.0
      c2 = 0.0
      (0...n).each do |i|
        s2 += Math.sin(2 * w * u[i])
        c2 += Math.cos(2 * w * u[i])
      end
      tau = Math.atan2(s2, c2) / (2 * w)
      sc = 0.0; ss = 0.0; cc = 0.0; s_s = 0.0
      (0...n).each do |i|
        cv = Math.cos(w * (u[i] - tau))
        sv = Math.sin(w * (u[i] - tau))
        sc += rc[i] * cv
        s_s += rc[i] * sv
        cc += cv * cv
        ss += sv * sv
      end
      ((sc * sc / cc) + (s_s * s_s / ss)) / (2 * var)
    end
    pk = pw.each_index.max_by { |i| pw[i] }
    [pw, pw[pk], grid[pk]]
  end

  # Reciprocal-decay envelope fit E[|r| | side] = a / (Age + b): grid
  # over b (0..25 step 0.5), weighted linear solve for a, min-SSE
  # winner. Returns { a:, b:, sse: } or nil. (Extracted verbatim from
  # percentile.rb's per-side lambda for characterization, M0-6.)
  def reciprocal_envelope(abs_r, ages)
    best = nil
    (0.0..25.0).step(0.5) do |b|
      sw2 = 0.0
      srw = 0.0
      abs_r.each_index do |j|
        w = 1.0 / (ages[j] + b)
        sw2 += w * w
        srw += abs_r[j] * w
      end
      next if sw2 <= 0

      a   = srw / sw2
      sse = abs_r.each_index.inject(0.0) { |s, j| s + (abs_r[j] - a / (ages[j] + b))**2 }
      best = { a: a, b: b, sse: sse } if best.nil? || sse < best[:sse]
    end
    best
  end

  # ---- report-only fit diagnostics (M9-5, D9-e) -------------------------------

  # The Sornette-school damping condition threshold: a genuine anti-bubble
  # decline satisfies D = m|B| / (omega|C|) >= 1. Reference-only -- the fit
  # does NOT impose it (nor the B<0 sign restriction) today; the flip from
  # report-only to gating is decision item D9-e. Named a reference constant so
  # no caller mistakes it for an active threshold.
  DAMPING_REF_THRESHOLD = 1.0

  # Report-only flags for a fitted LPPLS combo, additive next to the frozen
  # four-filter verdict (never wired into pass/fail or the score):
  #   b_negative -- fitted B < 0, the standard LPPLS sign restriction the fit
  #                 currently does not impose
  #   damping    -- D = m|B| / (omega|C|), 4dp; nil when C is zero/absent (no
  #                 oscillation amplitude to damp against).
  def fit_report_flags(m, b, omega, cmag)
    damping = if cmag.abs < 1e-12 || omega.abs < 1e-12
                nil
              else
                (m * b.abs / (omega * cmag.abs)).round(4)
              end
    { b_negative: b.negative?, damping: damping }
  end

  # ---- ARMA-GARCH bootstrap machinery (M9-7, shadow null) --------------------
  # Pure-Ruby, stdlib-only building blocks for logperiodic.rb's second null:
  # an AR(1)+GARCH(1,1) parametric bootstrap. Report-only -- the frozen AR(1)
  # bootstrap in logperiodic.rb is untouched.

  # Standard normal deviate (Box-Muller) from a seeded Random.
  def gauss(rng)
    Math.sqrt(-2 * Math.log(1 - rng.rand)) * Math.cos(2 * Math::PI * rng.rand)
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

  # OLS AR(1) with intercept on a series: x_t = c + phi*x_{t-1} + e_t.
  # Returns { phi:, c:, innov: [e_t] } (innovations feed the GARCH fit).
  def ar1_fit(x)
    m   = x.size - 1
    x0  = x[0...-1]
    x1  = x[1..]
    sx  = x0.inject(:+); sy = x1.inject(:+)
    sxx = x0.inject(0.0) { |s, v| s + v * v }
    sxy = (0...m).inject(0.0) { |s, i| s + x0[i] * x1[i] }
    den = m * sxx - sx * sx
    phi = den.abs < 1e-12 ? 0.0 : (m * sxy - sx * sy) / den
    c   = (sy - phi * sx) / m
    { phi: phi, c: c, innov: Array.new(m) { |i| x1[i] - c - phi * x0[i] } }
  end

  # GARCH(1,1) conditional Gaussian negative log-likelihood on innovations e:
  #   sigma2_t = omega + alpha*e_{t-1}^2 + beta*sigma2_{t-1}
  # sigma2_1 and e_0^2 seeded with the sample variance. Infeasible parameters
  # (omega<=0, alpha/beta<0, alpha+beta>=0.999) return +Inf -- the box penalty.
  def garch_negloglik(e, omega, alpha, beta)
    return Float::INFINITY if omega <= 0 || alpha < 0 || beta < 0 ||
                              alpha + beta >= 0.999

    n    = e.size
    var0 = e.inject(0.0) { |s, v| s + v * v } / n
    s2   = var0
    nll  = 0.0
    (0...n).each do |t|
      eprev2 = t.positive? ? e[t - 1] * e[t - 1] : var0
      s2     = omega + alpha * eprev2 + beta * s2
      return Float::INFINITY if s2 <= 0

      nll += 0.5 * (Math.log(2 * Math::PI) + Math.log(s2) + e[t] * e[t] / s2)
    end
    nll
  end

  # Estimate GARCH(1,1) by conditional MLE (Nelder-Mead on the negloglik).
  # Deterministic start (alpha 0.1, beta 0.8, omega var*0.1). On non-convergence
  # -- infeasible or non-finite optimum -- falls back to alpha 0.1, beta 0.8,
  # omega var*(1-0.9) and flags fitted:false. Returns
  # { omega:, alpha:, beta:, fitted: }.
  def estimate_garch(e)
    var = e.inject(0.0) { |s, v| s + v * v } / e.size
    best, fbest = nelder_mead([var * 0.1, 0.1, 0.8], [var * 0.05, 0.05, 0.05]) do |x|
      garch_negloglik(e, x[0], x[1], x[2])
    end
    om, al, be = best
    ok = fbest.finite? && om.positive? && al >= 0 && be >= 0 && al + be < 0.999
    return { omega: om, alpha: al, beta: be, fitted: true } if ok

    { omega: var * (1 - 0.1 - 0.8), alpha: 0.1, beta: 0.8, fitted: false }
  end

  # Simulate an AR(1)+GARCH(1,1) path of length n (after `burn` discarded
  # steps) from a seeded Random. sigma2 and e^2 seeded at the stationary
  # variance omega/(1-alpha-beta). Returns the length-n series.
  def simulate_ar1_garch(n, phi, c, omega, alpha, beta, rng, burn: 500)
    s2v    = omega / [1 - alpha - beta, 1e-6].max
    s2     = s2v
    eprev2 = s2v
    x      = 0.0
    out    = []
    (burn + n).times do |t|
      s2 = omega + alpha * eprev2 + beta * s2
      ev = Math.sqrt(s2) * gauss(rng)
      x  = c + phi * x + ev
      eprev2 = ev * ev
      out << x if t >= burn
    end
    out
  end

  # Full AR(1)+GARCH(1,1) parametric-bootstrap p-value for the Lomb-Scargle
  # peak of the power-decay null's residuals (M9-7 shadow). Unlike the frozen
  # AR(1) bootstrap in logperiodic.rb, each simulated path is pushed through
  # the SAME pipeline the real residuals were: a synthetic price window (the
  # null's fitted curve + simulated AR-GARCH noise) is re-fit with
  # power_decay_fit, and that refit's residuals are Lomb-Scargled. Symmetric
  # with the observed side (obs_max also came from power_decay_fit + lomb), so
  # p = fraction of sim maxima >= obs_max is a like-for-like tail probability.
  # `rng` is a seeded Random for determinism. Returns
  #   { p_value:, sims:, hits:, garch: {ar1, omega, alpha, beta, fitted} }.
  def arma_garch_pvalue(p, i_peak, null, obs_max, grid, sims, rng)
    r  = null[:resid]
    ar = ar1_fit(r)
    g  = estimate_garch(ar[:innov])
    fitted_curve = null[:idx].each_index.map { |k| null[:a] + null[:b] * null[:tau][k]**null[:m] }
    days_win = null[:idx].map { |i| p[:days][i] }
    genesis_dates = days_win.map { |d| GENESIS + d * 86_400 }

    hits = 0
    used = 0
    sims.times do
      noise = simulate_ar1_garch(r.size, ar[:phi], ar[:c], g[:omega], g[:alpha], g[:beta], rng)
      syn_lnp = fitted_curve.each_index.map { |k| fitted_curve[k] + noise[k] }
      syn = { days: days_win, lnp: syn_lnp, dates: genesis_dates,
              px: syn_lnp.map { |v| Math.exp(v) } }
      sn = power_decay_fit(syn, 0)
      next unless sn

      used += 1
      _, smax, = lomb(sn[:u], sn[:resid], grid)
      hits += 1 if smax >= obs_max
    end

    { p_value: (hits + 1).to_f / (used + 1), sims: used, hits: hits,
      garch: { ar1: ar[:phi], omega: g[:omega], alpha: g[:alpha],
               beta: g[:beta], fitted: g[:fitted] } }
  end

  # ---- anti-bubble window helpers ---------------------------------------------

  # Index of the cycle peak (max close on/after from_date).
  def detect_peak(p, from_date = Time.utc(2025, 1, 1))
    best = nil
    p[:dates].each_index do |i|
      next if p[:dates][i] < from_date

      best = i if best.nil? || p[:px][i] > p[:px][best]
    end
    best
  end

  # Best pure power-decay fit ln P = A + B * tau^m on the post-peak window,
  # grid over (tc, m), tc in days-since-genesis. The no-oscillation null
  # shared by fit.rb and logperiodic.rb.
  # Returns { tc:, m:, a:, b:, sse:, rmse:, idx: [row indices], u: [ln tau],
  #           resid: [...] } or nil.
  def power_decay_fit(p, i_peak)
    peak_day = p[:days][i_peak]
    idx_all  = (i_peak...p[:days].size).to_a
    return nil if idx_all.size < 60

    best = nil
    (-30..10).step(2) do |dt|
      tc  = peak_day + dt
      idx = idx_all.select { |i| p[:days][i] - tc > 2.0 }
      next if idx.size < 60

      tau = idx.map { |i| p[:days][i] - tc }
      y   = idx.map { |i| p[:lnp][i] }
      (0.1..0.9).step(0.1) do |mm|
        x = tau.map { |t| t**mm }
        n = x.size.to_f
        sx = 0.0; sy = 0.0; sxx = 0.0; sxy = 0.0; syy = 0.0
        (0...x.size).each do |k|
          sx += x[k]; sy += y[k]
          sxx += x[k] * x[k]; sxy += x[k] * y[k]; syy += y[k] * y[k]
        end
        den = n * sxx - sx * sx
        next if den.abs < 1e-12

        bb  = (n * sxy - sx * sy) / den
        aa  = (sy - bb * sx) / n
        sse = syy + n * aa * aa + bb * bb * sxx -
              2 * aa * sy - 2 * bb * sxy + 2 * aa * bb * sx
        next unless best.nil? || sse < best[:sse]

        best = { tc: tc, m: mm, a: aa, b: bb, sse: sse, idx: idx, tau: tau }
      end
    end
    return nil if best.nil?

    resid = []
    best[:idx].each_with_index do |i, k|
      resid << p[:lnp][i] - (best[:a] + best[:b] * best[:tau][k]**best[:m])
    end
    best[:u]     = best[:tau].map { |t| Math.log(t) }
    best[:resid] = resid
    best[:rmse]  = Math.sqrt(best[:sse] / resid.size)
    best
  end

  # Symmetric-null SHADOW (M9-6, feeds D9-e/D9-f). power_decay_fit above
  # selects tc on raw SSE across tc-dependent row counts -- rows with tau > 2d
  # shrink as tc moves late, so a later tc wins mechanically (fewer squared
  # residuals to sum). SBI observed the null tc pinned at the +10d coarse-grid
  # edge as a result. This variant removes both biases:
  #   (a) selects tc/m on RMSE = sqrt(SSE / rows) so row count cannot tilt the
  #       choice, and
  #   (b) adds the same coarse+refined two-pass search the LPPLS fit gets.
  # REPORT-ONLY: it feeds fit.rb's improvement_v2 and never the frozen null
  # fields or the frozen improvement figure. The original power_decay_fit is
  # left byte-identical (logperiodic.rb still consumes its u/resid).
  # at_grid_edge flags whether the chosen tc still sits at the late (+10d) or
  # early (-30d) coarse boundary -- the artifact SBI saw; a cleared artifact
  # reads false. Returns { tc:, m:, a:, b:, sse:, rmse:, at_grid_edge: } or nil.
  def power_decay_fit_v2(p, i_peak)
    peak_day = p[:days][i_peak]
    idx_all  = (i_peak...p[:days].size).to_a
    return nil if idx_all.size < 60

    eval_fit = lambda do |tc, mm|
      idx = idx_all.select { |i| p[:days][i] - tc > 2.0 }
      next nil if idx.size < 60

      y = idx.map { |i| p[:lnp][i] }
      x = idx.map { |i| (p[:days][i] - tc)**mm }
      n = x.size.to_f
      sx = 0.0; sy = 0.0; sxx = 0.0; sxy = 0.0; syy = 0.0
      (0...x.size).each do |k|
        sx += x[k]; sy += y[k]
        sxx += x[k] * x[k]; sxy += x[k] * y[k]; syy += y[k] * y[k]
      end
      den = n * sxx - sx * sx
      next nil if den.abs < 1e-12

      bb  = (n * sxy - sx * sy) / den
      aa  = (sy - bb * sx) / n
      sse = syy + n * aa * aa + bb * bb * sxx -
            2 * aa * sy - 2 * bb * sxy + 2 * aa * bb * sx
      sse = 0.0 if sse < 0
      { tc: tc, m: mm, a: aa, b: bb, sse: sse, rmse: Math.sqrt(sse / n) }
    end

    best = nil
    pick = lambda do |tcs, ms|
      tcs.each do |tc|
        ms.each do |mm|
          r = eval_fit.(tc, mm)
          next unless r
          next unless best.nil? || r[:rmse] < best[:rmse]

          best = r
        end
      end
    end

    # coarse pass -- same tc/m ranges as the original null's coarse grid
    pick.((-30..10).step(2).map { |dt| peak_day + dt }, (0.1..0.9).step(0.1).to_a)
    return nil if best.nil?

    # refinement pass around the coarse optimum, mirroring the LPPLS fit's
    b0 = best
    pick.(((b0[:tc] - 2)..(b0[:tc] + 2)).step(1).to_a,
          ([b0[:m] - 0.08, 0.05].max..(b0[:m] + 0.08)).step(0.02).to_a)

    dt_sel = best[:tc] - peak_day
    best[:at_grid_edge] = dt_sel >= 10.0 || dt_sel <= -30.0
    best
  end
end
