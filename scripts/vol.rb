#!/usr/bin/env ruby
# frozen_string_literal: true
#
# vol.rb -- Deribit implied-vol surface & skew (ATM IV, 25-delta risk
# reversal + butterfly) per tenor bucket.
#
#   ruby vol.rb          # BTC board, human table
#   ruby vol.rb --json   # machine-readable dump
#
# stdlib only (net/http, json). One API call for the whole board; IVs are
# read straight from Deribit's mark_iv -- the same book gex.rb fetches for
# gamma, whose per-instrument iv it discards. The book-row mapping here is
# a deliberate local copy of gex.rb's parse/filter (oi > 0, live expiry,
# iv > 0) -- not a refactor of gex.rb (minimal-diff rule).
#
# SEMANTICS
#   Per target tenor (7/14/21/30/45/90d -- BTC::Vol::DEFAULT_TARGETS, the shared
#   vol paradigm, owner ruling 2026-08-18) pick the expiry whose days are
#   closest to the target, then report:
#     atm_iv  -- IV at the strike nearest that expiry's underlying
#     rr25    -- iv(25-delta call) - iv(25-delta put)  (skew)
#     fly25   -- mean(25d call, 25d put) IV - atm_iv    (smile curvature)
#   25-delta legs are chosen by nearest bs_delta (each row's own iv), no
#   interpolation (v1). Full rules + fail-soft: lib/btc/vol.rb.
#
# DATA SOURCE
#   Deribit public get_book_summary_by_currency + get_index_price, via the
#   BTC::Deribit seam (already health-registered). No new source, no ENV.
#
# CAVEATS
#   Thin tenors (< 3 calls or < 3 puts) report atm_iv but null rr25/fly25
#   with a 'reason'. A stale/sparse board yields indicative, not tradeable,
#   skew. Inverse (coin-margined) BTC board only, matching gex.rb.
#
# FAILURE MODE
#   Aborts with a message on stderr, exit != 0 (no fail-soft JSON) if the
#   Deribit fetch fails -- downstream consumers treat nonzero as keep-last.

require 'json'
require 'time'
require_relative '../lib/btc/options'
require_relative '../lib/btc/deribit'
require_relative '../lib/btc/vol'

# ---- fetch + parse board (local copy of gex.rb's mapping) ------------------
now = Time.now.utc

begin
  spot = BTC::Deribit.index_price('btc_usd')
  rows = BTC::Deribit.book_summary('BTC', 'option')
rescue StandardError => e
  abort "deribit: #{e.class}: #{e.message}"
end

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
    u: (r['underlying_price'] || spot).to_f }
end.compact
abort 'no live instruments parsed' if book.empty?

surface = BTC::Vol.surface(book)

# ---- output ----------------------------------------------------------------
if ARGV.include?('--json')
  puts JSON.pretty_generate(
    ts: now.iso8601,
    btc_spot: spot.round(1),
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

puts format('BTC vol surface  spot %.0f  %s  (%d instruments)',
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
