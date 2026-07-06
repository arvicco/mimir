#!/usr/bin/env ruby
# frozen_string_literal: true
#
# fit.rb -- Test 2: anti-bubble LPPLS fit on the decline since the cycle peak.
#
#   ln P(t) = A + B*tau^m + tau^m * [C1 cos(w ln tau) + C2 sin(w ln tau)],
#   tau = t - tc, tc near the peak (anti-bubble: pattern develops after tc).
#
# Filimonov-Sornette linearization: grid over the nonlinear (tc, m, w),
# 4x4 linear solve for (A, B, C1, C2) from accumulated moments, then one
# refinement pass around the coarse optimum.
#
# Evidence is NOT the fit itself but three diagnostics:
#   (a) Sornette qualifying filters: m in [0.1,0.9] interior, w in [6,13],
#       >= 2.5 oscillations in window, |C|/|B| <= 1
#   (b) parameter stability day-over-day (data/fit_history.jsonl, appended
#       only on --history runs so ad-hoc runs cannot pollute the signal;
#       lppl.rb --history passes the flag through): a real regime shows
#       converging trough estimates; overfit noise wanders
#   (c) RMSE improvement vs the pure power-decay null
#
#   score: +1 all four filters pass; -1 if <= 2 pass; else 0.
#          Downgraded by 1 if >= 5 history entries and the projected trough
#          date std over the last 10 runs exceeds 21 days.
#
# Forward output: projected trough date/level from extrapolating the fitted
# curve up to +400d (reported 'none<=+400d' if the minimum sits on the
# boundary -- itself a strike against the anti-bubble reading).

require_relative 'common'

NAME = 'fit'
HIST = File.join(Lppl::DATA, 'fit_history.jsonl')

begin
  p = Lppl.load_prices
rescue StandardError => e
  Lppl.fail_soft(NAME, e.message)
end

i_peak = Lppl.detect_peak(p)
Lppl.fail_soft(NAME, 'no post-peak window') if i_peak.nil? ||
                                                 p[:dates].size - i_peak < 90

peak_day = p[:days][i_peak]

# ---- grid + linear solve -----------------------------------------------------
# Returns [sse, coef] for given (tc, m, w) using accumulated moments.
def solve_combo(days, lnp, i0, tc, m, w)
  xtx = Array.new(4) { Array.new(4, 0.0) }
  xty = Array.new(4, 0.0)
  syy = 0.0
  cnt = 0
  (i0...days.size).each do |i|
    tau = days[i] - tc
    next if tau <= 2.0

    tm = tau**m
    lt = Math.log(tau)
    row = [1.0, tm, tm * Math.cos(w * lt), tm * Math.sin(w * lt)]
    y   = lnp[i]
    (0...4).each do |a|
      xty[a] += row[a] * y
      (a...4).each { |b| xtx[a][b] += row[a] * row[b] }
    end
    syy += y * y
    cnt += 1
  end
  return nil if cnt < 60

  (0...4).each { |a| (0...a).each { |b| xtx[a][b] = xtx[b][a] } }
  coef = Lppl.gauss_solve(xtx, xty)
  return nil unless coef

  # SSE = y'y - 2 b'X'y + b'X'Xb
  bxy = 0.0
  bxb = 0.0
  (0...4).each do |a|
    bxy += coef[a] * xty[a]
    (0...4).each { |b| bxb += coef[a] * xtx[a][b] * coef[b] }
  end
  [syy - 2 * bxy + bxb, coef, cnt]
end

best = nil
scan = lambda do |tcs, ms, ws|
  tcs.each do |tc|
    ms.each do |m|
      ws.each do |w|
        r = solve_combo(p[:days], p[:lnp], i_peak, tc, m, w)
        next unless r
        next unless best.nil? || r[0] < best[:sse]

        best = { sse: r[0], coef: r[1], n: r[2], tc: tc, m: m, w: w }
      end
    end
  end
end

# coarse pass
scan.((-30..10).step(2).map { |d| peak_day + d },
      (0.10..0.90).step(0.10).to_a,
      (4.0..16.0).step(0.5).to_a)
Lppl.fail_soft(NAME, 'no valid fit') if best.nil?

# refinement pass around coarse optimum
b0 = best
scan.(((b0[:tc] - 2)..(b0[:tc] + 2)).step(1).to_a,
      ([b0[:m] - 0.08, 0.05].max..(b0[:m] + 0.08)).step(0.02).to_a,
      ((b0[:w] - 0.5)..(b0[:w] + 0.5)).step(0.1).to_a)

rmse = Math.sqrt(best[:sse] / best[:n])
a, b, c1, c2 = best[:coef]
cmag = Math.sqrt(c1 * c1 + c2 * c2)

# null: pure power decay
null = Lppl.power_decay_fit(p, i_peak)
impr = null ? (1.0 - rmse / null[:rmse]) * 100 : nil

# ---- filters -----------------------------------------------------------------
tau_min = 3.0
tau_max = p[:days][-1] - best[:tc]
n_osc   = best[:w] / (2 * Math::PI) * Math.log(tau_max / tau_min)
filters = {
  'm_interior'  => best[:m] > 0.10 && best[:m] < 0.90,
  'omega_band'  => best[:w] >= 6.0 && best[:w] <= 13.0,
  'oscillations' => n_osc >= 2.5,
  'amp_bounded' => b.abs > 1e-9 && (cmag / b.abs) <= 1.0
}
passed = filters.values.count(true)

# ---- trough extrapolation ----------------------------------------------------
trough_day = nil
trough_ln  = nil
d0 = p[:days][-1]
(0..400).each do |k|
  tau = d0 + k - best[:tc]
  next if tau <= 2.0

  v = a + b * tau**best[:m] +
      tau**best[:m] * (c1 * Math.cos(best[:w] * Math.log(tau)) +
                       c2 * Math.sin(best[:w] * Math.log(tau)))
  next unless trough_ln.nil? || v < trough_ln

  trough_ln  = v
  trough_day = d0 + k
end
interior    = trough_day && trough_day < d0 + 398
trough_date = trough_day && (Lppl::GENESIS + trough_day * 86_400).strftime('%d%b%y')
trough_px   = trough_ln && Math.exp(trough_ln).round(-2)

# ---- stability ---------------------------------------------------------------
# In as-of mode only history entries stamped before AS_OF count (a live run on
# that day had not yet written the later ones); the ledger is never truncated.
entries = []
if File.exist?(HIST)
  entries = File.readlines(HIST).map { |l| JSON.parse(l) rescue nil }.compact
  if (cutts = Lppl.as_of&.iso8601)
    entries = entries.select { |e| e['ts'].to_s < cutts }
  end
end
tstd = nil
if entries.size >= 4 && trough_day
  recent = (entries.last(9).map { |e| e['trough_day'].to_f } + [trough_day]).reject(&:zero?)
  if recent.size >= 5
    mu   = recent.inject(:+) / recent.size
    tstd = Math.sqrt(recent.inject(0.0) { |s, v| s + (v - mu)**2 } / recent.size).round(1)
  end
end

score = if passed == 4
          1
        elsif passed <= 2
          -1
        else
          0
        end
score = [score - 1, -1].max if tstd && tstd > 21
score = [score - 1, -1].max unless interior

if ARGV.include?('--history')
  File.open(HIST, 'a') do |f|
    f.puts JSON.generate(ts: Lppl.now_utc.iso8601, tc: best[:tc].round(1),
                         m: best[:m].round(3), w: best[:w].round(2),
                         rmse: rmse.round(4), trough_day: trough_day,
                         trough_px: trough_px, filters_passed: passed)
  end
end

Lppl.report(NAME, score,
              format('m %.2f, omega %.1f, %d/4 filters; trough %s @ ~%s; rmse %.3f (%s vs null)%s',
                     best[:m], best[:w], passed,
                     interior ? trough_date : 'none<=+400d',
                     trough_px ? trough_px.to_s : '--', rmse,
                     impr ? format('%+.0f%%', impr) : 'n/a',
                     tstd ? format('; trough std %.0fd', tstd) : ''),
              'omega' => best[:w].round(2), 'm' => best[:m].round(3),
              'tc_date' => (Lppl::GENESIS + best[:tc] * 86_400).strftime('%Y-%m-%d'),
              'trough_date' => (interior ? trough_date : nil),
              'trough_px' => (interior ? trough_px : nil),
              'filters' => filters.inspect,
              'rmse_impr_pct' => impr && impr.round(1),
              'trough_std_days' => tstd)
