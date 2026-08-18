#!/usr/bin/env ruby
# frozen_string_literal: true
#
# vol_mstr.rb -- MSTR implied-vol surface & skew (ATM IV, 25-delta risk
# reversal + butterfly) per tenor bucket. The single-name sibling of
# scripts/vol.rb: same set-up, same three numbers, but on MicroStrategy's
# own USD-settled option chain instead of Deribit's coin-margined BTC book.
#
#   ruby vol_mstr.rb          # MSTR board, human table
#   ruby vol_mstr.rb --json   # machine-readable dump
#
# stdlib only (net/http, json). The book-row mapping is a deliberate local
# copy of scripts/vol_spread.rb's MSTR leg (parse the CBOE delayed-quote
# chain, iv already a fraction, u = current_price) -- NOT a refactor of
# vol_spread.rb (minimal-diff rule). BTC::Vol is reused unchanged.
#
# SEMANTICS
#   Per target tenor (7/14/21/45/90d -- BTC::Vol::DEFAULT_TARGETS, the same
#   set-up as vol.rb) pick the expiry whose days are closest to the target,
#   then report:
#     atm_iv  -- IV at the strike nearest that expiry's underlying
#     rr25    -- iv(25-delta call) - iv(25-delta put)  (skew)
#     fly25   -- mean(25d call, 25d put) IV - atm_iv    (smile curvature)
#   25-delta legs are chosen by nearest bs_delta (each row's own iv), no
#   interpolation (v1). Full rules + fail-soft: lib/btc/vol.rb.
#
# DATA SOURCE
#   CBOE cdn.cboe.com/api/global/delayed_quotes/options/MSTR.json via
#   BTC::SourceCache (health-registered as the CBOE options endpoint --
#   same URL gex_us.rb/vol_spread.rb already use; no new source, no ENV).
#   CBOE per-option iv is already a fraction (0.773 == 77.3%); no /100
#   normalization. MSTR u = chain current_price (spot per share).
#
# CAVEATS
#   Thin tenors (< 3 calls or < 3 puts) report atm_iv but null rr25/fly25
#   with a 'reason'. A stale/sparse board yields indicative, not tradeable,
#   skew. MSTR options are USD cash-settled linear single-name (contrast
#   vol.rb's inverse BTC board); the 90d tenor can drop honestly when the
#   listed chain is short. CBOE quotes are ~15-min delayed; OI is previous
#   day (OPRA overnight).
#
# FAILURE MODE
#   Aborts with a message on stderr, exit != 0 (no fail-soft JSON) if the
#   CBOE fetch fails or yields no live instruments -- mirrors vol.rb's
#   Deribit-down behavior; downstream consumers treat nonzero as keep-last.

require 'json'
require 'time'
require_relative '../lib/btc/options'
require_relative '../lib/btc/source_cache'
require_relative '../lib/btc/vol'

CBOE_BASE = 'https://cdn.cboe.com/api/global/delayed_quotes/options'

# ---- fetch + parse board (local copy of vol_spread.rb's MSTR leg) -----------
now = Time.now.utc

begin
  url  = "#{CBOE_BASE}/MSTR.json"
  r    = BTC::SourceCache.fetch_json('cboe_mstr', url,
                                     { 'User-Agent' => 'vol_mstr.rb' }, now: now)
  data = r['data']['data']
  raise 'no data in CBOE response for MSTR' unless data

  spot = (data['current_price'] || data['close']).to_f
  raise 'no spot price for MSTR' if spot <= 0

  book = (data['options'] || []).map do |o|
    oi = o['open_interest'].to_f
    next if oi <= 0

    expiry, cp, k = BTC::Options.parse_osi(o['option'])
    next unless expiry

    t = (expiry - now) / BTC::Options::YEAR_S
    next if t <= 0

    # CBOE per-option iv is already a fraction (e.g. 0.773 == 77.3% IV).
    iv = o['iv'].to_f
    next if iv <= 0

    { k: k, cp: cp, t: t, iv: iv, oi: oi, u: spot }
  end.compact
rescue StandardError => e
  abort "cboe_mstr: #{e.class}: #{e.message}"
end
abort 'no live MSTR instruments parsed' if book.empty?

surface = BTC::Vol.surface(book)

# ---- output ----------------------------------------------------------------
if ARGV.include?('--json')
  puts JSON.pretty_generate(
    ts: now.iso8601,
    mstr_spot: spot.round(2),
    tenors: surface.map do |s|
      { tenor_d:  s[:tenor_d],
        expiry_d: s[:expiry_d],
        atm_iv:   s[:atm_iv] && s[:atm_iv].round(4),
        rr25:     s[:rr25] && s[:rr25].round(4),
        fly25:    s[:fly25] && s[:fly25].round(4),
        n_calls:  s[:n_calls],
        n_puts:   s[:n_puts],
        reason:   s[:reason] }
    end
  )
  exit
end

pct = ->(v) { v ? format('%6.1f%%', v * 100) : format('%7s', '--') }
pp1 = ->(v) { v ? format('%+6.1f', v * 100) : format('%6s', '--') }

puts format('MSTR vol surface  spot %.2f  %s  (%d instruments)',
            spot, now.strftime('%H:%M UTC'), book.size)
puts format('%5s  %8s  %7s  %6s  %6s  %3s %3s',
            'tenor', 'expiry', 'atm_iv', 'rr25', 'fly25', 'nC', 'nP')
surface.each do |s|
  puts format('%4dd  %7.1fd  %s  %s  %s  %3d %3d',
              s[:tenor_d], s[:expiry_d] || 0.0,
              pct.(s[:atm_iv]), pp1.(s[:rr25]), pp1.(s[:fly25]),
              s[:n_calls], s[:n_puts])
  puts format('%14s(%s)', '', s[:reason]) if s[:reason]
end
