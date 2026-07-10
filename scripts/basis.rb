#!/usr/bin/env ruby
# frozen_string_literal: true
#
# basis.rb -- futures basis & funding composite (M8-4, DISPLAY-ONLY).
# Two independent legs, each fail-soft:
#
#   ruby basis.rb          # human table (basis per tenor + funding)
#   ruby basis.rb --json   # machine-readable dump (frozen contract)
#
# stdlib only. No chart spec, no web work, no scenario-score membership --
# this producer only DESCRIBES the term structure and funding history.
#
# BASIS LEG (Deribit, coin-margined futures book)
#   BTC::Deribit.book_summary('BTC', 'future') + BTC::Deribit.index_price.
#   Spot = the Deribit index. For each DATED future (BTC-DDMMMYY):
#     days          = (expiry 08:00 UTC - now) / 86400
#     basis_ann_pct = (mark / spot - 1) * (365.25 / days) * 100
#   i.e. the annualized rich/cheap of the future over spot, in percent.
#   The PERPETUAL row (no expiry) reports a simple, NON-annualized percent
#   premium (mark / spot - 1) * 100. Tenors are sorted by expiry (soonest
#   first). Contango steepness is leverage appetite and a basis collapse /
#   backwardation is stress -- but those are INTERPRETATION for a hover
#   card, NOT computed here (Golden Rule 4: no thresholds, no verdicts).
#
# FUNDING LEG (Coinglass, OI-weighted funding OHLC via the keyed seam)
#   BTC::Coinglass.funding_oi_history(interval: '8h') -> OHLC rows whose
#   'close' is the OI-weighted funding rate for that 8h period. We take the
#   last 30 rows and report, all in PERCENT per 8h:
#     latest_pct  -- the most recent close
#     d1_pct      -- mean of the last 3 closes   (3  x 8h =  1 day)
#     d7_pct      -- mean of the last 21 closes  (21 x 8h =  7 days)
#     d30_pct     -- mean of the last 90 closes  (90 x 8h = 30 days)
#   (fewer values if the returned history is shorter). These are simple
#   descriptive averages over the returned closes -- no weighting, no
#   annualization.
#
#   UNITS: the API returns funding as a FRACTION per 8h; we multiply by 100
#   for percent display. NOTE (2026-07-10 fixture): the recorded closes sit
#   at ~0.001..0.010, i.e. ~0.1%..1.0% per 8h once scaled -- an order of
#   magnitude above the canonical ~0.01% per 8h BTC funding. Displayed as
#   documented (fraction x 100); the magnitude is flagged for owner review.
#
# FAIL-SOFT (per leg, independent)
#   The Deribit basis leg and the Coinglass funding leg are separate. Either
#   one down (Deribit unreachable; Coinglass unreachable; or no
#   COINGLASS_API_KEY) nulls ONLY its own section with a reason string and
#   the script still exits 0 with the other leg populated. The key is read
#   only through BTC::Coinglass (never ENV here). reasons are null on success.

require 'json'
require 'time'
require_relative '../lib/btc/options'
require_relative '../lib/btc/deribit'
require_relative '../lib/btc/coinglass'
require_relative '../lib/btc/basis'

now = Time.now.utc

# ---- BASIS leg (Deribit) ---------------------------------------------------
# One leg: index + futures book are both Deribit; either failing nulls it.
spot   = nil
tenors = []
perp_premium_pct = nil
basis_reason = nil
begin
  spot = BTC::Deribit.index_price('btc_usd')
  rows = BTC::Deribit.book_summary('BTC', 'future')

  dated = []
  rows.each do |r|
    name = r['instrument_name'].to_s
    mark = r['mark_price'].to_f
    next if mark <= 0

    if name.end_with?('PERPETUAL')
      perp_premium_pct = BTC::Basis.perp_premium_pct(mark, spot)
      next
    end

    _, exp = name.split('-')
    ex = BTC::Options.deribit_expiry(exp) or next
    days = (ex - now) / 86_400.0
    next if days <= 0

    dated << { instrument: name, days: days, mark: mark,
               basis_ann_pct: BTC::Basis.annualized_basis_pct(mark, spot, days) }
  end
  tenors = dated.sort_by { |t| t[:days] }
rescue StandardError => e
  spot = nil
  tenors = []
  perp_premium_pct = nil
  basis_reason = "deribit: #{e.class}: #{e.message}"
end

# ---- FUNDING leg (Coinglass, keyed via the seam) ---------------------------
funding_latest = nil
funding_d1 = nil
funding_d7 = nil
funding_d30 = nil
funding_points = 0
funding_reason = nil
begin
  raw    = BTC::Coinglass.funding_oi_history(interval: '8h')
  closes = raw.last(30).map { |r| r['close'].to_f } # fractions per 8h
  raise 'no funding closes returned' if closes.empty?

  funding_points = closes.size
  to_pct = ->(v) { v && v * 100.0 } # fraction -> percent per 8h
  funding_latest = to_pct.call(closes.last)
  funding_d1  = to_pct.call(BTC::Basis.trailing_mean(closes, 3))
  funding_d7  = to_pct.call(BTC::Basis.trailing_mean(closes, 21))
  funding_d30 = to_pct.call(BTC::Basis.trailing_mean(closes, 90))
rescue StandardError => e
  funding_latest = funding_d1 = funding_d7 = funding_d30 = nil
  funding_points = 0
  funding_reason = "coinglass: #{e.class}: #{e.message}"
end

# ---- output ----------------------------------------------------------------
if ARGV.include?('--json')
  puts JSON.pretty_generate(
    ts:   now.iso8601,
    spot: spot && spot.round(1),
    basis: {
      tenors: tenors.map do |t|
        { instrument:    t[:instrument],
          days:          t[:days].round(2),
          mark:          t[:mark].round(2),
          basis_ann_pct: t[:basis_ann_pct] && t[:basis_ann_pct].round(3) }
      end,
      perp_premium_pct: perp_premium_pct && perp_premium_pct.round(4),
      reason:           basis_reason
    },
    funding: {
      latest_pct: funding_latest && funding_latest.round(4),
      d1_pct:     funding_d1  && funding_d1.round(4),
      d7_pct:     funding_d7  && funding_d7.round(4),
      d30_pct:    funding_d30 && funding_d30.round(4),
      points:     funding_points,
      reason:     funding_reason
    }
  )
  exit
end

pct  = ->(v, w = 7) { v ? format("%+#{w}.3f%%", v) : format("%#{w + 1}s", '--') }
mk   = ->(v) { v ? format('%9.1f', v) : format('%9s', '--') }

# BASIS section
if spot
  puts format('BTC futures basis  spot %.0f  %s  (%d tenors)',
              spot, now.strftime('%Y-%m-%d %H:%M UTC'), tenors.size)
  puts format('%-14s %8s %10s %10s', 'instrument', 'days', 'mark', 'basis(ann)')
  tenors.each do |t|
    puts format('%-14s %8.1f %s %s',
                t[:instrument], t[:days], mk.call(t[:mark]), pct.call(t[:basis_ann_pct], 9))
  end
  puts format('%-14s %8s %10s %s', 'PERPETUAL', '', '', pct.call(perp_premium_pct, 9))
else
  puts format('BTC futures basis  UNAVAILABLE (%s)', basis_reason)
end

puts

# FUNDING section
if funding_reason
  puts format('BTC funding (OI-weighted, 8h)  UNAVAILABLE (%s)', funding_reason)
else
  puts format('BTC funding (OI-weighted, 8h)  %d points  (%% per 8h)', funding_points)
  puts format('%-10s %s', 'latest',  pct.call(funding_latest))
  puts format('%-10s %s   (last 3)',  '1d avg',  pct.call(funding_d1))
  puts format('%-10s %s   (last 21)', '7d avg',  pct.call(funding_d7))
  puts format('%-10s %s   (last 90)', '30d avg', pct.call(funding_d30))
end

puts
puts format('basis: %s tenors + perp %s   |   funding: %d points %s',
            tenors.size, basis_reason ? '(down)' : 'ok',
            funding_points, funding_reason ? '(down)' : 'ok')
