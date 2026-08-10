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
end
