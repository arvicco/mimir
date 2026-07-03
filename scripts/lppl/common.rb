# frozen_string_literal: true
#
# common.rb -- shared machinery for the LPPL evidence suite.
# Ruby >= 2.5, stdlib only.

require 'net/http'
require 'json'
require 'time'
require 'fileutils'

module Common
  GENESIS = Time.utc(2009, 1, 3)
  DATA    = File.join(File.expand_path(__dir__), 'data')
  PRICES  = File.join(DATA, 'prices.csv')

  module_function

  # ---- IO / reporting --------------------------------------------------------

  def get_json(url, headers = {})
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                    open_timeout: 5, read_timeout: 60) do |http|
      req = Net::HTTP::Get.new(uri.request_uri,
                               { 'User-Agent' => 'lppl.rb' }.merge(headers))
      res = http.request(req)
      raise "HTTP #{res.code}" unless res.code.to_i == 200

      JSON.parse(res.body)
    end
  end

  # Uniform module contract. score in -1/0/+1: +1 supports LPPL-as-regime,
  # -1 is evidence against, 0 neutral/insufficient. detail keys are consumed
  # by the aggregator (lppl.rb).
  def report(name, score, headline, detail = {})
    detail = detail.reject { |_, v| v.nil? }
    if ARGV.include?('--json')
      puts JSON.generate({ name: name, score: score, headline: headline,
                           ts: Time.now.utc.iso8601 }.merge(detail))
    else
      puts format('%-12s [%+d]  %s', name, score, headline)
      detail.each { |k, v| puts format('  %-16s %s', k, v) }
    end
  end

  def fail_soft(name, err)
    report(name, 0, "unavailable (#{err})")
    exit 0
  end

  # ---- price cache -----------------------------------------------------------

  # Returns { dates: [Time], days: [Float, days since genesis],
  #           lnp: [Float], px: [Float] }, ascending, zero/dust rows dropped.
  def load_prices
    raise 'price cache missing -- run prices.rb first' unless File.exist?(PRICES)

    dates = []
    px    = []
    File.foreach(PRICES) do |ln|
      d, c = ln.strip.split(',')
      next if d.nil? || d == 'date'

      v = c.to_f
      next if v < 0.05

      dates << Time.utc(*d.split('-').map { |s| s.to_i })
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
