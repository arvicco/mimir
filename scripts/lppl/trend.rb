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
# Headline (M11-3, owner ruling 2026-08-29 / register R-3): the trailing-1y
# per-evaluation MEAN log predictive-score differential (log10/eval) of
# pl_full vs the best rival -- the density-invariant number (SBI 3.1: the old
# SUM headline scaled with cache density; it stays as the 'bf' reference
# field and in the human line as 'cum'). The headline carries a Newey-West
# (Bartlett, lag 179) standard error -- overlapping forecast horizons make
# the daily differentials strongly autocorrelated -- and band_per_eval, the
# frozen band re-expressed in headline units. This component can genuinely
# FALSIFY: a decisively negative differential means the trend claim is dying
# regardless of how pretty the oscillation fit looks.
#
# The SCORE is byte-identical to pre-M11-3 -- still the cumulative
# differential against +-1.0 (at equal horizon counts the mean-vs-band and
# sum-vs-1.0 comparisons are the same inequality):
#
#   score +1  trailing cumulative differential >= +1.0 (>=10:1)
#   score -1  trailing cumulative differential <= -1.0
#   score  0  in between
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
#
# PL+LP1 RIVAL (M9-9, REPORT-ONLY): a fourth model, pl_lp1 = power law + one
# rigid log-periodic mode in ln(age) at LP1_OMEGA (stage-1 lp1_check.rb peak),
# fitted like pl_full on [0, j]. Scores go to a SEPARATE cache
# (data/trend_scores_lp1.csv) and surface as the additive --json section
# pl_lp1{per_horizon:{...}, omega, clock}. The pl_full-vs-pl_lp1 differential is
# paired on matched eval dates. pl_lp1 NEVER enters the best-rival max or bf_yr;
# adoption into the verdict is decision item D9-d.

require_relative 'common'

NAME    = 'trend'
CACHE   = File.join(Lppl::DATA, 'trend_scores.csv')
# Long horizons 365/730 (M9-8) are REPORT-ONLY: a SEPARATE cache and
# aggregation, never folded into HORIZ, the +-1 scoring band, or the score.
CACHE_LONG = File.join(Lppl::DATA, 'trend_scores_long.csv')
# PL+LP1 rival (M9-9): power law + ONE rigid log-periodic mode in ln(age), a
# SEPARATE report-only cache that NEVER enters the frozen best-rival max.
CACHE_LP1  = File.join(Lppl::DATA, 'trend_scores_lp1.csv')
HORIZ   = [30, 90, 180].freeze
HORIZ_LONG = [365, 730].freeze
# Rigid, refit-free omega -- the full-history ln(age) Lomb-Scargle peak from
# stage-1 lp1_check.rb (8.70; SBI 8.75). The hypothesis is ONE fundamental
# mode, so omega is fixed, not searched per eval; a per-eval omega search would
# be a different, slower test (future work). NOTE: ln(age) clock -- NOT the
# post-peak ln(tau) omega fit.rb/logperiodic.rb report (different clocks).
LP1_OMEGA = 8.70
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

# ---- PL+LP1 rival SHADOW (M9-9, report-only) ---------------------------------
# power law + ONE rigid log-periodic mode in ln(age), fitted like pl_full on the
# full [0, j] training window (omega fixed at LP1_OMEGA). Scores go to a SEPARATE
# cache and are compared to pl_full on MATCHED eval dates only (never entering
# the frozen best-rival max or bf_yr). Same discipline (C8 completeness,
# read-only under as-of, weekly-stride bootstrap) as the frozen path.
lp1reg = Lppl::PlLp1Reg.new(xs, p[:lnp], LP1_OMEGA)

have_lp1 = {}
if File.exist?(CACHE_LP1)
  File.foreach(CACHE_LP1) do |ln|
    d, h, m, s = ln.strip.split(',')
    next if d.nil? || d == 'date'
    next if asof_key && d >= asof_key

    have_lp1["#{d}|#{h}|#{m}"] = s.to_f
  end
end
bootstrap_lp1 = have_lp1.empty?
stride_lp1    = bootstrap_lp1 ? 7 : 1

new_rows_lp1 = []
(0...n).each do |i|
  next if p[:dates][i] < EVAL0
  next if bootstrap_lp1 && (i % stride_lp1 != 0)

  dkey = p[:dates][i].strftime('%Y-%m-%d')
  HORIZ.each do |h|
    j = i - h
    next if j < MINFIT
    next if have_lp1.key?("#{dkey}|#{h}|pl_lp1")

    g = lp1reg.fit(j)
    next unless g

    xi = lp1reg.row(i)
    mu = g[:coef].each_index.inject(0.0) { |s, a| s + g[:coef][a] * xi[a] }
    new_rows_lp1 << [dkey, h, 'pl_lp1', logscore(p[:lnp][i], mu, g[:sigma2])]
  end
end

if !Lppl.as_of && !new_rows_lp1.empty?
  File.open(CACHE_LP1, 'a') do |f|
    f.puts 'date,h,model,logscore' unless File.exist?(CACHE_LP1) && File.size(CACHE_LP1) > 0
    f.write(new_rows_lp1.map { |r| "#{r.join(',')}\n" }.join)
  end
  new_rows_lp1.each { |d, h, m, s| have_lp1["#{d}|#{h}|#{m}"] = s }
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

# pl_lp1 (M9-9, additive, REPORT-ONLY): the pl_full-vs-pl_lp1 differential over
# the trailing-1y window, paired on eval dates present in BOTH caches so the
# comparison is density-matched (SBI 3.1). Same {sum, mean_per_eval, n_evals}
# shape, pl_full-centric like per_horizon: sum > 0 means the rigid mode HURTS
# out-of-sample (pl_full wins), sum < 0 means it HELPS. Never enters bf_yr or
# the best-rival max (that flip is decision item D9-d).
pl_lp1_ph = {}
HORIZ.each do |h|
  diff = 0.0
  ne   = 0
  have_lp1.each do |k, s_lp1|
    d, hh, m = k.split('|')
    next unless hh == h.to_s && m == 'pl_lp1'
    next if d < cut

    pf = have["#{d}|#{h}|pl_full"]
    next unless pf

    diff += (pf - s_lp1)
    ne   += 1
  end
  dd10 = diff / Math.log(10)
  pl_lp1_ph[h.to_s] = { 'sum' => dd10.round(2),
                        'mean_per_eval' => (ne.positive? ? (dd10 / ne).round(4) : nil),
                        'n_evals' => ne,
                        'report_only' => true }
end
pl_lp1_field = { 'per_horizon' => pl_lp1_ph, 'omega' => LP1_OMEGA,
                 'clock' => 'ln(age) -- not the post-peak ln(tau) omega' }

score = if bf_yr >= 1.0
          1
        elsif bf_yr <= -1.0
          -1
        else
          0
        end

# ---- headline_mean (M11-3, owner ruling 2026-08-29 / register R-3) -----------
# The HEADLINE becomes the density-honest per-evaluation MEAN: the sum across
# horizons of each horizon's mean_per_eval (log10/eval; at equal horizon
# counts this is exactly bf_yr / n_evals, so the frozen +-1.0 cumulative band
# re-expresses as +-band_per_eval = 1.0 / n_evals in headline units -- the
# same inequality, different units). The SCORE above still compares the
# cumulative bf_yr to +-1.0, byte-identical to pre-M11-3 -- the ruling moved
# the number we stand behind, not the test.
#
# Uncertainty: Newey-West (Bartlett) SE of the daily combined differential
# series over the trailing year, lag = the longest horizon (180d overlap
# makes the differentials strongly autocorrelated; plain sd/sqrt(n) would be
# far too tight). The daily series uses each horizon's WINNING rival (by
# trailing-year sum -- the same rival the aggregate compares against), so the
# series total reproduces the aggregate differential on complete dates.
nw_lag = HORIZ.max - 1
riv_name = {}
HORIZ.each do |h|
  riv_name[h] = sums["yr|#{h}|pl_recent"] >= sums["yr|#{h}|rw"] ? 'pl_recent' : 'rw'
end
daily = Hash.new(0.0)
daily_n = Hash.new(0)
have.each do |k, s|
  d, h, m = k.split('|')
  next if d < cut
  next unless m == 'pl_full'

  r = have["#{d}|#{h}|#{riv_name[h.to_i]}"]
  next unless r

  daily[d]   += (s - r) / Math.log(10)
  daily_n[d] += 1
end
series = daily.keys.sort.filter_map { |d| daily[d] if daily_n[d] == HORIZ.size }
se_nw  = Lppl.newey_west_se(series, lag: nw_lag)

means = HORIZ.filter_map { |h| per_horizon[h.to_s]['mean_per_eval'] }
ne_yr = count["yr|90|pl_full"]
headline_mean = {
  'value'         => (means.empty? ? nil : means.sum.round(4)),
  'se_nw'         => se_nw&.round(4),
  'lag'           => nw_lag,
  'n_dates'       => series.size,
  'band_per_eval' => (ne_yr.positive? ? (1.0 / ne_yr).round(4) : nil)
}

Lppl.report(NAME, score,
              format('trailing-1y MEAN log predictive-score differential/eval (log10) pl_full vs best rival %s ±%s NW · band ±%s · cum %+.2f  [30d %+.4f / 90d %+.4f / 180d %+.4f /eval]',
                     headline_mean['value'] ? format('%+.4f', headline_mean['value']) : '?',
                     se_nw ? format('%.4f', se_nw) : '?',
                     headline_mean['band_per_eval'] ? format('%.4f', headline_mean['band_per_eval']) : '?',
                     bf_yr,
                     per_horizon['30']['mean_per_eval'] || 0.0,
                     per_horizon['90']['mean_per_eval'] || 0.0,
                     per_horizon['180']['mean_per_eval'] || 0.0),
              'bf' => bf_yr, # deprecated name; the value is the cumulative differential
              'bf_by_horizon' => per_h.inspect, # deprecated name; see per_horizon
              'per_horizon' => per_horizon,
              'per_horizon_long' => per_horizon_long,
              'headline_mean' => headline_mean,
              'pl_lp1' => pl_lp1_field,
              'delta_ln_age' => delta_ln_age,
              'eval_points_1y' => count["yr|90|pl_full"],
              'bootstrap' => (bootstrap ? 'first run: weekly stride history built' : nil))
