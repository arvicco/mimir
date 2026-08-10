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
# Headline: the trailing-365-day cumulative log predictive-score differential
# (log10) of pl_full vs the best rival (formerly called the "Bayes factor").
# This component can genuinely FALSIFY: a decisively negative differential
# means the trend claim is dying regardless of how pretty the oscillation
# fit looks.
#
#   score +1  trailing differential >= +1.0 (>=10:1 for the global power law)
#   score -1  trailing differential <= -1.0
#   score  0  in between
#
# CACHE-DENSITY CAVEAT (SBI 3.1): the headline is a SUM over evaluation days,
# so its magnitude scales roughly linearly with how many days the cache
# holds -- a full daily cache and a weekly-stride cache of the same period
# differ ~7x in magnitude while agreeing on sign and on the per-evaluation
# MEAN. The additive per_horizon.mean_per_eval field is the density-invariant
# reading; the raw sum is not comparable across cache densities (feeds D9-b).
#
# Scores are cached in data/trend_scores.csv. First run bootstraps history
# from 2017 with weekly stride (a minute or so); daily runs append only
# newly matured evaluation dates. Under --as-of the cache is read-filtered to
# dates before the replay day and never written (read-only replay).
#
# LONG HORIZONS 365/730d (M9-8, REPORT-ONLY): evaluated in shadow into a
# SEPARATE cache (data/trend_scores_long.csv) with the same discipline, and
# surfaced as the additive --json field per_horizon_long (same {sum,
# mean_per_eval, n_evals} shape as per_horizon, each marked report_only:true).
# They are EXCLUDED from the +-1 band and the score until decision item D9-c.
# Published evidence says the power law wins at 12-24mo; the soak shows whether
# our own data agrees before any scoring ruling.

require_relative 'common'

NAME    = 'trend'
CACHE   = File.join(Lppl::DATA, 'trend_scores.csv')
# Long horizons 365/730 (M9-8) are REPORT-ONLY: a SEPARATE cache and
# aggregation, never folded into HORIZ, the +-1 scoring band, or the score.
CACHE_LONG = File.join(Lppl::DATA, 'trend_scores_long.csv')
HORIZ   = [30, 90, 180].freeze
HORIZ_LONG = [365, 730].freeze
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
    # A group is complete only when pl_full AND rw are both present (rw is
    # unconditional whenever pl_full lands; pl_recent legitimately drops
    # out on early dates). pl_full-only meant a torn append -- a crash
    # between the two lines -- left the group half-written forever (C8).
    next if have.key?("#{dkey}|#{h}|pl_full") && have.key?("#{dkey}|#{h}|rw")

    x_star = xs[i]
    y      = p[:lnp][i]

    # pl_full
    f = reg.fit(0, j)
    next unless f

    ls = logscore(y, f[:icept] + f[:slope] * x_star, f[:sigma2])
    new_rows << [dkey, h, 'pl_full', ls] unless have.key?("#{dkey}|#{h}|pl_full")

    # pl_recent
    a = j - WIN_REC + 1
    if a >= 0 && (f2 = reg.fit(a, j)) && !have.key?("#{dkey}|#{h}|pl_recent")
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
    # single write: one syscall for the whole batch narrows the torn-append
    # window the group-completeness check above exists to heal
    f.write(new_rows.map { |r| "#{r.join(',')}\n" }.join)
  end
  new_rows.each { |d, h, m, s| have["#{d}|#{h}|#{m}"] = s }
end

# ---- long horizons 365/730 SHADOW (M9-8, report-only) ------------------------
# A SEPARATE cache (trend_scores_long.csv) and aggregation that never touch the
# frozen HORIZ path above: not the +-1 band, not the score. Same
# group-completeness/dedup discipline (C8) and the same read-only-under-as-of
# rule. On the first live run trend_scores_long.csv does not exist yet while
# trend_scores.csv already does, so the long cache bootstraps (weekly stride)
# and backfills independently -- a one-time cost, then daily appends.
have_long = {}
if File.exist?(CACHE_LONG)
  File.foreach(CACHE_LONG) do |ln|
    d, h, m, s = ln.strip.split(',')
    next if d.nil? || d == 'date'
    next if asof_key && d >= asof_key

    have_long["#{d}|#{h}|#{m}"] = s.to_f
  end
end
bootstrap_long = have_long.empty?
stride_long    = bootstrap_long ? 7 : 1

new_rows_long = []
(0...n).each do |i|
  next if p[:dates][i] < EVAL0
  next if bootstrap_long && (i % stride_long != 0)

  dkey = p[:dates][i].strftime('%Y-%m-%d')
  HORIZ_LONG.each do |h|
    j = i - h
    next if j < MINFIT
    next if have_long.key?("#{dkey}|#{h}|pl_full") && have_long.key?("#{dkey}|#{h}|rw")

    x_star = xs[i]
    y      = p[:lnp][i]

    f = reg.fit(0, j)
    next unless f

    ls = logscore(y, f[:icept] + f[:slope] * x_star, f[:sigma2])
    new_rows_long << [dkey, h, 'pl_full', ls] unless have_long.key?("#{dkey}|#{h}|pl_full")

    a = j - WIN_REC + 1
    if a >= 0 && (f2 = reg.fit(a, j)) && !have_long.key?("#{dkey}|#{h}|pl_recent")
      ls2 = logscore(y, f2[:icept] + f2[:slope] * x_star, f2[:sigma2])
      new_rows_long << [dkey, h, 'pl_recent', ls2]
    end

    a2 = [j - 364, 1].max
    nn = (j - a2 + 1).to_f
    sd = dd[j] - dd[a2 - 1]
    s2 = dd2[j] - dd2[a2 - 1]
    dvar = (s2 - sd * sd / nn) / [nn - 1, 1].max
    ls3  = logscore(y, p[:lnp][j], dvar * h)
    new_rows_long << [dkey, h, 'rw', ls3]
  end
end

if !Lppl.as_of && !new_rows_long.empty?
  File.open(CACHE_LONG, 'a') do |f|
    f.puts 'date,h,model,logscore' unless File.exist?(CACHE_LONG) && File.size(CACHE_LONG) > 0
    f.write(new_rows_long.map { |r| "#{r.join(',')}\n" }.join)
  end
  new_rows_long.each { |d, h, m, s| have_long["#{d}|#{h}|#{m}"] = s }
end

# ---- aggregate ---------------------------------------------------------------
# delta_ln_age (M9-10, additive): how far the model's NATURAL clock -- ln(age),
# age = days since genesis -- advances across the trailing-1y aggregation
# window. At age ~17.5y a full calendar year spans only ~0.057 in ln-age, so
# the "trailing year" is a sliver of log-time (context for the eval-schedule
# discussion; the schedule change itself is out of scope). Report-only.
age_end_days = (Lppl.now_utc - Lppl::GENESIS) / 86_400.0
delta_ln_age = (Math.log(age_end_days) - Math.log(age_end_days - 365)).round(4)

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
# per_horizon (M9-1, additive): the density-invariant view of the same
# numbers -- for each horizon the cumulative differential (sum), the
# per-evaluation-point MEAN (invariant to cache density; feeds D9-b), and
# the eval-point count that scales the sum.
per_horizon = {}
HORIZ.each do |h|
  pl  = sums["yr|#{h}|pl_full"]
  riv = [sums["yr|#{h}|pl_recent"], sums["yr|#{h}|rw"]].max
  d   = (pl - riv) / Math.log(10)
  per_h[h] = d.round(2)
  ne = count["yr|#{h}|pl_full"]
  per_horizon[h.to_s] = { 'sum' => d.round(2),
                          'mean_per_eval' => (ne.positive? ? (d / ne).round(4) : nil),
                          'n_evals' => ne }
  bf_yr += d
end
bf_yr = bf_yr.round(2)

# per_horizon_long (M9-8, additive, REPORT-ONLY): the identical density-invariant
# view for the 365/730d horizons, aggregated over the SAME trailing-1y window
# (cut) from the SEPARATE long cache. A parallel map (not extra keys inside
# per_horizon) keeps the M9-1 contract shape byte-identical. Each entry carries
# report_only:true and NEVER enters bf_yr or the score.
sums_long  = Hash.new(0.0)
count_long = Hash.new(0)
have_long.each do |k, s|
  d, h, m = k.split('|')
  next if d < cut

  sums_long["yr|#{h}|#{m}"] += s
  count_long["yr|#{h}|#{m}"] += 1
end
per_horizon_long = {}
HORIZ_LONG.each do |h|
  pl  = sums_long["yr|#{h}|pl_full"]
  riv = [sums_long["yr|#{h}|pl_recent"], sums_long["yr|#{h}|rw"]].max
  d   = (pl - riv) / Math.log(10)
  ne  = count_long["yr|#{h}|pl_full"]
  per_horizon_long[h.to_s] = { 'sum' => d.round(2),
                               'mean_per_eval' => (ne.positive? ? (d / ne).round(4) : nil),
                               'n_evals' => ne,
                               'report_only' => true }
end

score = if bf_yr >= 1.0
          1
        elsif bf_yr <= -1.0
          -1
        else
          0
        end

Lppl.report(NAME, score,
              format('trailing-1y cum. log predictive-score differential (log10) pl_full vs best rival %+.2f  [30d %+.2f / 90d %+.2f / 180d %+.2f]',
                     bf_yr, per_h[30], per_h[90], per_h[180]),
              'bf' => bf_yr, # deprecated name; the value is the cumulative differential
              'bf_by_horizon' => per_h.inspect, # deprecated name; see per_horizon
              'per_horizon' => per_horizon,
              'per_horizon_long' => per_horizon_long,
              'delta_ln_age' => delta_ln_age,
              'eval_points_1y' => count["yr|90|pl_full"],
              'bootstrap' => (bootstrap ? 'first run: weekly stride history built' : nil))
