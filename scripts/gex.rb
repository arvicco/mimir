#!/usr/bin/env ruby
# frozen_string_literal: true
#
# gex.rb -- Deribit strike-level GEX profile, gamma flip estimate, walls.
#
#   ruby gex.rb                  # BTC, all expiries, human output
#   ruby gex.rb ETH              # ETH board
#   ruby gex.rb --max-days 45    # near-dated board only
#   ruby gex.rb --json           # machine-readable dump (full profile)
#   ruby gex.rb --tmux           # one line -> /tmp/gex_<ccy>.status
#
# stdlib only (net/http, json). One API call for the whole board; gamma is
# computed locally via Black-Scholes from mark_iv (r = 0, options are priced
# off futures), so no per-instrument ticker calls.
#
# Sign convention: naive dealer model -- dealers long calls / short puts,
# i.e. call gamma +, put gamma -. Same convention as SqueezeMetrics and
# cryptogamma.io. On Deribit treat the SIGN with suspicion (flows are
# two-sided); the LEVELS (walls, flip, magnitude) are robust to it.
# Covers BTC/ETH inverse options only, not the USDC-quoted board.
#
# Failure mode: aborts with a message on stderr, exit != 0 (no fail-soft
# JSON) -- downstream consumers must treat nonzero exit as keep-last-good.

require 'json'
require 'time'
require_relative '../lib/btc/options'
require_relative '../lib/btc/util'
require_relative '../lib/btc/http'

HOST = 'https://www.deribit.com/api/v2/public'

def get_json(path)
  JSON.parse(BTC::Http.get("#{HOST}/#{path}")).fetch('result')
rescue StandardError => e
  abort "deribit: #{e.class}: #{e.message}"
end

# ---- fetch + parse board ---------------------------------------------------
ccy      = ARGV.find { |a| %w[BTC ETH].include?(a.upcase) }&.upcase || 'BTC'
max_days = BTC::Util.arg('--max-days')&.to_f
now      = Time.now.utc

spot = get_json("get_index_price?index_name=#{ccy.downcase}_usd")['index_price'].to_f
rows = get_json("get_book_summary_by_currency?currency=#{ccy}&kind=option")

book = rows.map do |r|
  oi = r['open_interest'].to_f
  next if oi <= 0

  _, exp, strike, cp = r['instrument_name'].split('-')
  ex = BTC::Options.deribit_expiry(exp) or next
  t  = (ex - now) / BTC::Options::YEAR_S
  next if t <= 0 || (max_days && t * 365.25 > max_days)

  iv = r['mark_iv'].to_f / 100.0
  next if iv <= 0

  { k: strike.to_f, cp: cp, t: t, iv: iv, oi: oi,
    u: (r['underlying_price'] || spot).to_f }
end.compact
abort 'no live instruments parsed' if book.empty?

# ---- dollar gamma per 1% move at hypothetical index level x ----------------
# Each instrument's forward is scaled proportionally with the index.
def net_gex(book, spot, x)
  book.sum do |o|
    s   = o[:u] * x / spot
    sgn = o[:cp] == 'C' ? 1.0 : -1.0
    sgn * BTC::Options.bs_gamma(s, o[:k], o[:t], o[:iv]) * o[:oi] * x * x * 0.01
  end
end

# ---- strike profile at current spot ----------------------------------------
profile = Hash.new(0.0)
book.each do |o|
  sgn = o[:cp] == 'C' ? 1.0 : -1.0
  profile[o[:k]] += sgn * BTC::Options.bs_gamma(o[:u], o[:k], o[:t], o[:iv]) *
                    o[:oi] * spot * spot * 0.01
end

near, call_wall, put_wall = BTC::Options.walls(profile, spot)
total = profile.values.sum

# ---- flip scan: first zero crossing of net GEX over +/-30% -----------------
flip = BTC::Options.gamma_flip(spot) { |x| net_gex(book, spot, x) }
flip = flip && flip.round

put_oi  = book.sum { |o| o[:cp] == 'P' ? o[:oi] : 0.0 }
call_oi = book.sum { |o| o[:cp] == 'C' ? o[:oi] : 0.0 }
pc      = call_oi.zero? ? 0.0 : put_oi / call_oi

fmt_m = ->(v) { format('%+.1fM', v / 1e6) }
fmt_k = ->(v) { v ? "#{(v / 1000.0).round(1)}k" : '--' }

# ---- output -----------------------------------------------------------------
if ARGV.include?('--json')
  puts JSON.pretty_generate(
    ccy: ccy, spot: spot.round(1), ts: now.iso8601,
    net_gex_usd_per_1pct: total.round,
    regime: total.negative? ? 'short_gamma' : 'long_gamma',
    gamma_flip: flip,
    call_wall: call_wall && { strike: call_wall[0].round, gex: call_wall[1].round },
    put_wall:  put_wall  && { strike: put_wall[0].round,  gex: put_wall[1].round },
    put_call_oi: pc.round(3),
    instruments: book.size,
    profile: Hash[profile.sort.map { |k, v| [k.round, v.round] }]
  )
  exit
end

line = format('GEX %s %s flip %s PW %s CW %s P/C %.2f',
              ccy, fmt_m.(total), fmt_k.(flip),
              fmt_k.(put_wall&.first), fmt_k.(call_wall&.first), pc)

if ARGV.include?('--tmux')
  File.write("/tmp/gex_#{ccy.downcase}.status", line + "\n")
  exit
end

puts format('%s  spot %.0f  %s  (%d instruments)',
            ccy, spot, now.strftime('%H:%M UTC'), book.size)
puts format('net GEX %s per 1%%  ->  %s', fmt_m.(total),
            total.negative? ? 'SHORT GAMMA (amplifying)' : 'LONG GAMMA (pinning)')
puts format('gamma flip ~ %s   put/call OI %.2f', flip || 'none in +/-30%', pc)
if call_wall && put_wall
  puts format('call wall %d (%s)   put wall %d (%s)',
              call_wall[0], fmt_m.(call_wall[1]),
              put_wall[0],  fmt_m.(put_wall[1]))
end

puts
max_abs = near.values.map(&:abs).max || 1.0
profile.select { |k, _| (k - spot).abs / spot <= 0.15 }.sort.each do |k, v|
  bar = '#' * [(v.abs / max_abs * 40).round, 40].min
  puts format('%-9d %12s  %s%s', k, fmt_m.(v), v.negative? ? '-' : '+', bar)
end
