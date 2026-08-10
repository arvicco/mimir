#!/usr/bin/env ruby
# frozen_string_literal: true
#
# vol_spread.rb -- MSTR-vs-BTC implied-vol spread (ATM IV, nearest-expiry
# pairing per tenor). This is the market's live price of treasury-company
# leverage; nobody publishes it. Companion to scripts/vol.rb (M8-1).
#
# USAGE
#   ruby vol_spread.rb          # aligned terminal table
#   ruby vol_spread.rb --json   # machine-readable JSON (frozen contract)
#
# SEMANTICS (owner-approved 2026-07-10, nearest-expiry pairing)
#   BTC leg:  Deribit BTC option book -> BTC::Vol.surface (7/14/21/45/90d
#             targets -- finer than the surface chart, owner ruling 2026-08-10).
#   MSTR leg: CBOE delayed-quote MSTR chain -> BTC::Vol.surface (same targets).
#   For each target tenor: spread_atm = MSTR atm_iv - BTC atm_iv (both
#   fractions from BTC::Vol; displayed x100 as vol-points in human output).
#   Pairing is nearest-expiry for each leg independently, so a thin MSTR board
#   may pair a 7d expiry against 25JUN27; expiry_d is always carried so
#   degenerate cross-expiry pairings stay visible.
#
# DATA SOURCES
#   Deribit: public get_book_summary_by_currency + get_index_price via the
#     BTC::Deribit seam (health-registered). Book-row mapping is a local copy
#     of scripts/vol.rb's (minimal-diff rule -- vol.rb must not be modified).
#   CBOE:    cdn.cboe.com/api/global/delayed_quotes/options/MSTR.json via
#     BTC::SourceCache (health-registered as 'cboe options' in gex_us.rb).
#   CBOE per-option iv is already a fraction (e.g. 0.773 = 77.3%); no /100
#   normalization is applied. MSTR u = chain current_price (spot per share).
#
# FAIL-SOFT
#   If the CBOE fetch fails (or yields no live MSTR instruments), the MSTR
#   leg nulls with a reason and the process exits 0 -- BTC data is still
#   reported. Symmetric for a Deribit failure. If BOTH legs fail, the process
#   writes a message to stderr and exits != 0 (no JSON; downstream keeps last).
#
# CAVEATS
#   Deribit board is coin-margined (inverse) BTC/ETH. MSTR options are USD
#   cash-settled linear. Both legs use the same BTC::Vol::MIN_SIDE gate (3
#   per side per expiry). Cross-expiry pairing (a 7d MSTR vs a 355d BTC) is
#   indicative, not tradeable; expiry_d makes the degeneracy explicit.
#   CBOE quotes are ~15-min delayed; OI is previous-day (OPRA overnight).

require 'json'
require 'time'
require_relative '../lib/btc/options'
require_relative '../lib/btc/deribit'
require_relative '../lib/btc/source_cache'
require_relative '../lib/btc/vol'

CBOE_BASE = 'https://cdn.cboe.com/api/global/delayed_quotes/options'

# Finer tenor ladder than the surface chart's 7/30/90 (owner ruling
# 2026-08-10): the MSTR-vs-BTC spread's term structure is the point of
# this chart, and three points hid its shape. Additive rows only -- the
# per-tenor field set is unchanged.
TARGETS = [7, 14, 21, 45, 90].freeze

now = Time.now.utc

# ---- BTC leg: Deribit book -> BTC::Vol.surface ------------------------------
# Local copy of scripts/vol.rb's mapping (minimal-diff rule: vol.rb is not
# modified; BTC::Deribit and BTC::Vol are reused unchanged).
btc_spot    = nil
btc_surface = nil
btc_reason  = nil

begin
  btc_spot = BTC::Deribit.index_price('btc_usd')
  rows     = BTC::Deribit.book_summary('BTC', 'option')

  book = rows.map do |r|
    oi = r['open_interest'].to_f
    next if oi <= 0

    _, exp, strike, cp = r['instrument_name'].split('-')
    ex = BTC::Options.deribit_expiry(exp) or next
    t  = (ex - now) / BTC::Options::YEAR_S
    next if t <= 0

    iv = r['mark_iv'].to_f / 100.0
    next if iv <= 0

    { k: strike.to_f, cp: cp, t: t, iv: iv, oi: oi,
      u: (r['underlying_price'] || btc_spot).to_f }
  end.compact

  if book.empty?
    btc_reason = 'no live BTC instruments parsed'
  else
    btc_surface = BTC::Vol.surface(book, targets: TARGETS)
  end
rescue StandardError => e
  btc_reason = "deribit: #{e.class}: #{e.message}"
end

# ---- MSTR leg: CBOE chain -> BTC::Vol.surface (gex_us.rb parse pattern) ----
mstr_spot    = nil
mstr_surface = nil
mstr_reason  = nil

begin
  url  = "#{CBOE_BASE}/MSTR.json"
  r    = BTC::SourceCache.fetch_json('cboe_mstr', url,
                                     { 'User-Agent' => 'vol_spread.rb' }, now: now)
  data = r['data']['data']
  raise 'no data in CBOE response for MSTR' unless data

  mstr_spot = (data['current_price'] || data['close']).to_f
  raise 'no spot price for MSTR' if mstr_spot <= 0

  mstr_book = (data['options'] || []).map do |o|
    oi = o['open_interest'].to_f
    next if oi <= 0

    expiry, cp, k = BTC::Options.parse_osi(o['option'])
    next unless expiry

    t = (expiry - now) / BTC::Options::YEAR_S
    next if t <= 0

    # CBOE per-option iv is already a fraction (e.g. 0.773 == 77.3% IV).
    iv = o['iv'].to_f
    next if iv <= 0

    { k: k, cp: cp, t: t, iv: iv, oi: oi, u: mstr_spot }
  end.compact

  if mstr_book.empty?
    mstr_reason = 'no live MSTR instruments parsed'
  else
    mstr_surface = BTC::Vol.surface(mstr_book, targets: TARGETS)
  end
rescue StandardError => e
  mstr_reason = "cboe_mstr: #{e.class}: #{e.message}"
end

# ---- both legs failed: abort ------------------------------------------------
if btc_surface.nil? && mstr_surface.nil?
  $stderr.puts format('vol_spread: both legs failed -- BTC: %s | MSTR: %s',
                      btc_reason, mstr_reason)
  exit 1
end

# ---- build spread rows (nearest-expiry pairing per tenor) -------------------
spread_rows = TARGETS.map do |target_d|
  bt = btc_surface&.find  { |s| s[:tenor_d] == target_d }
  mt = mstr_surface&.find { |s| s[:tenor_d] == target_d }

  spread_atm = (bt && mt && bt[:atm_iv] && mt[:atm_iv]) ?
               (mt[:atm_iv] - bt[:atm_iv]) : nil

  { tenor_d:    target_d,
    mstr:       { expiry_d: mt&.[](:expiry_d),
                  atm_iv:   mt&.[](:atm_iv)&.round(4),
                  reason:   mt ? mt[:reason] : mstr_reason },
    btc:        { expiry_d: bt&.[](:expiry_d),
                  atm_iv:   bt&.[](:atm_iv)&.round(4),
                  reason:   bt ? bt[:reason] : btc_reason },
    spread_atm: spread_atm&.round(4) }
end

# ---- output -----------------------------------------------------------------
if ARGV.include?('--json')
  puts JSON.pretty_generate(
    ts:        now.iso8601,
    mstr_spot: mstr_spot&.round(2),
    btc_spot:  btc_spot&.round(1),
    tenors:    spread_rows.map do |sr|
      { tenor_d:    sr[:tenor_d],
        mstr:       { expiry_d: sr[:mstr][:expiry_d],
                      atm_iv:   sr[:mstr][:atm_iv],
                      reason:   sr[:mstr][:reason] },
        btc:        { expiry_d: sr[:btc][:expiry_d],
                      atm_iv:   sr[:btc][:atm_iv],
                      reason:   sr[:btc][:reason] },
        spread_atm: sr[:spread_atm] }
    end
  )
  exit
end

# Human-readable aligned table
pct = ->(v) { v ? format('%6.1f%%', v * 100) : format('%7s', '--') }
spr = ->(v) { v ? format('%+6.1f', v * 100) : format('%6s', '--') }
xd  = ->(v) { v ? format('%5.1fd', v) : format('%6s', '--') }

puts format('MSTR-vs-BTC vol spread  MSTR %.2f  BTC %.0f  %s',
            mstr_spot || 0.0, btc_spot || 0.0, now.strftime('%H:%M UTC'))
puts format('%-5s  %-18s  %-18s  %s',
            'tenor', 'MSTR atm/expiry', 'BTC  atm/expiry', 'spread')
puts '-' * 65
spread_rows.each do |sr|
  puts format('%4dd  %s (%s)  %s (%s)  %s',
              sr[:tenor_d],
              pct.(sr[:mstr][:atm_iv]), xd.(sr[:mstr][:expiry_d]),
              pct.(sr[:btc][:atm_iv]),  xd.(sr[:btc][:expiry_d]),
              spr.(sr[:spread_atm]))
  puts format('%14s(MSTR: %s)', '', sr[:mstr][:reason]) if sr[:mstr][:reason]
  puts format('%14s(BTC:  %s)', '', sr[:btc][:reason])  if sr[:btc][:reason]
end
