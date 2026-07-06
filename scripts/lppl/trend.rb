#!/usr/bin/env ruby
# frozen_string_literal: true
#
# trend.rb -- Test 1: trend integrity via prequential out-of-sample scoring.
#
# The LPPL regime's load-bearing claim is that log-price is stationary
# around a global power law in log-time. Each evaluation date t, three
# rival models are fitted on data up to t-h and score today's realized
# log-price with a Gaussian log-score, at horizons h = 30/90/180d:
#
#   pl_full    power law fitted on ALL history       (the LPPL trend claim)
#   pl_recent  power law fitted on trailing 3 years  ("the trend has bent")
#   rw         random walk, sigma scaled sqrt(h)     (no trend information)
#
# Headline: cumulative log10 Bayes factor of pl_full vs the best rival over
# the trailing 365 evaluation days. This component can genuinely FALSIFY:
# a decisively negative BF means the trend claim is dying regardless of how
# pretty the oscillation fit looks.
#
#   score +1  trailing BF >= +1.0 (>=10:1 for the global power law)
#   score -1  trailing BF <= -1.0
#   score  0  in between
#
# Scores are cached in data/trend_scores.csv. First run bootstraps history
# from 2017 with weekly stride (a minute or so); daily runs append only
# newly matured evaluation dates. Under --as-of the cache is read-filtered to
# dates before the replay day and never written (read-only replay).

require_relative 'common'

NAME    = 'trend'
CACHE   = File.join(Lppl::DATA, 'trend_scores.csv')
HORIZ   = [30, 90, 180].freeze
EVAL0   = Time.utc(2017, 1, 1)
WIN_REC = 1095 # rows in the "recent" power-law window
MINFIT  = 1460 # min rows of history before a fit is scored

begin
  p = Lppl.load_prices
rescue StandardError => e
  Lppl.fail_soft(NAME, e.message)
end

n     = p[:dates].size
xs    = p[:days].map { |d| Math.log(d) }
reg   = Lppl::RangeReg.new(xs, p[:lnp])

# prefix sums of daily log-diffs for the RW sigma
dd  = Array.new(n, 0.0)
dd2 = Array.new(n, 0.0)
(1...n).each do |i|
  d      = p[:lnp][i] - p[:lnp][i - 1]
  dd[i]  = dd[i - 1] + d
  dd2[i] = dd2[i - 1] + d * d
end

def logscore(y, mu, var)
  var = 1e-6 if var < 1e-6
  -0.5 * Math.log(2 * Math::PI * var) - (y - mu)**2 / (2 * var)
end

# ---- load score cache --------------------------------------------------------
# In as-of mode the cache is read-filtered to eval dates strictly before AS_OF
# (the whole-cache aggregation below is load-bearing, so later scores must not
# leak in) and never written back -- replay is read-only on trend_scores.csv.
have    = {}
asof_key = Lppl.as_of&.strftime('%Y-%m-%d')
if File.exist?(CACHE)
  File.foreach(CACHE) do |ln|
    d, h, m, s = ln.strip.split(',')
    next if d.nil? || d == 'date'
    next if asof_key && d >= asof_key

    have["#{d}|#{h}|#{m}"] = s.to_f
  end
end
bootstrap = have.empty?
stride    = bootstrap ? 7 : 1

# ---- compute missing scores --------------------------------------------------
new_rows = []
(0...n).each do |i|
  next if p[:dates][i] < EVAL0
  next if bootstrap && (i % stride != 0)

  dkey = p[:dates][i].strftime('%Y-%m-%d')
  HORIZ.each do |h|
    j = i - h
    next if j < MINFIT
    next if have.key?("#{dkey}|#{h}|pl_full")

    x_star = xs[i]
    y      = p[:lnp][i]

    # pl_full
    f = reg.fit(0, j)
    next unless f

    ls = logscore(y, f[:icept] + f[:slope] * x_star, f[:sigma2])
    new_rows << [dkey, h, 'pl_full', ls]

    # pl_recent
    a = j - WIN_REC + 1
    if a >= 0 && (f2 = reg.fit(a, j))
      ls2 = logscore(y, f2[:icept] + f2[:slope] * x_star, f2[:sigma2])
      new_rows << [dkey, h, 'pl_recent', ls2]
    end

    # rw: mu = lnp[j], var = daily var over trailing 365d * h
    a2 = [j - 364, 1].max
    nn = (j - a2 + 1).to_f
    sd = dd[j] - dd[a2 - 1]
    s2 = dd2[j] - dd2[a2 - 1]
    dvar = (s2 - sd * sd / nn) / [nn - 1, 1].max
    ls3  = logscore(y, p[:lnp][j], dvar * h)
    new_rows << [dkey, h, 'rw', ls3]
  end
end

# Append suppressed entirely in as-of mode: replay neither writes the cache
# nor folds fresh scores into the aggregation, keeping eval-point density
# identical to what the live run on AS_OF actually saw (the trend-BF magnitude
# depends on cache density -- see docs/METHODOLOGY.md caveat).
if !Lppl.as_of && !new_rows.empty?
  File.open(CACHE, 'a') do |f|
    f.puts 'date,h,model,logscore' unless File.exist?(CACHE) && File.size(CACHE) > 0
    new_rows.each { |r| f.puts r.join(',') }
  end
  new_rows.each { |d, h, m, s| have["#{d}|#{h}|#{m}"] = s }
end

# ---- aggregate ---------------------------------------------------------------
cut = (Lppl.now_utc - 365 * 86_400).strftime('%Y-%m-%d')
sums  = Hash.new(0.0) # "window|h|model" => sum
count = Hash.new(0)
have.each do |k, s|
  d, h, m = k.split('|')
  sums["all|#{h}|#{m}"] += s
  count["all|#{h}|#{m}"] += 1
  next if d < cut

  sums["yr|#{h}|#{m}"] += s
  count["yr|#{h}|#{m}"] += 1
end

bf_yr = 0.0
per_h = {}
HORIZ.each do |h|
  pl  = sums["yr|#{h}|pl_full"]
  riv = [sums["yr|#{h}|pl_recent"], sums["yr|#{h}|rw"]].max
  d   = (pl - riv) / Math.log(10)
  per_h[h] = d.round(2)
  bf_yr += d
end
bf_yr = bf_yr.round(2)

score = if bf_yr >= 1.0
          1
        elsif bf_yr <= -1.0
          -1
        else
          0
        end

Lppl.report(NAME, score,
              format('trailing-1y log10 BF (pl_full vs best rival) %+.2f  [30d %+.2f / 90d %+.2f / 180d %+.2f]',
                     bf_yr, per_h[30], per_h[90], per_h[180]),
              'bf' => bf_yr,
              'bf_by_horizon' => per_h.inspect,
              'eval_points_1y' => count["yr|90|pl_full"],
              'bootstrap' => (bootstrap ? 'first run: weekly stride history built' : nil))
