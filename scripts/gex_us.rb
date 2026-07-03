#!/usr/bin/env ruby
# frozen_string_literal: true
#
# gex_us.rb -- strike-level GEX for US-listed options (IBIT, MSTR, ...)
# via CBOE's free delayed-quotes JSON (no auth). Companion to gex.rb
# (Deribit): both report dollar gamma per 1% move, so the numbers are
# directly summable across venues (Deribit board + IBIT = combined BTC GEX).
#
#   ruby gex_us.rb IBIT               # human output
#   ruby gex_us.rb IBIT MSTR          # multiple tickers
#   ruby gex_us.rb IBIT --max-days 45 # near-dated board only
#   ruby gex_us.rb IBIT --json
#   ruby gex_us.rb IBIT MSTR --tmux   # one line each -> /tmp/gex_<ticker>.status
#
# For spot-BTC ETFs (IBIT, FBTC, ...) every price output is annotated with
# its approximate BTC equivalent, e.g. "34.8 (61.4K)", via the Deribit index.
#
# Ruby >= 2.5, stdlib only. Sign convention as in gex.rb: dealers long
# calls / short puts (call gamma +, put gamma -); on OPRA customer flow
# this assumption is more defensible than on Deribit. Quotes are ~15 min
# delayed; open interest is previous-day (OPRA updates OI overnight).

require 'net/http'
require 'json'
require 'time'

CBOE = 'https://cdn.cboe.com/api/global/delayed_quotes/options'
MULT = 100.0 # shares per contract
BTC_ETFS = %w[IBIT FBTC BITB ARKB GBTC BTC HODL BTCO BRRR EZBC].freeze

def get_json(url)
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                  open_timeout: 5, read_timeout: 20) do |http|
    req = Net::HTTP::Get.new(uri.request_uri, 'User-Agent' => 'gex_us.rb')
    JSON.parse(http.request(req).body)
  end
rescue StandardError => e
  abort "fetch #{url}: #{e.class}: #{e.message}"
end

def norm_pdf(x)
  Math.exp(-0.5 * x * x) / Math.sqrt(2 * Math::PI)
end

def bs_gamma(s, k, t, v)
  return 0.0 if t <= 0 || v <= 0 || s <= 0 || k <= 0

  sq = v * Math.sqrt(t)
  d1 = (Math.log(s / k) + 0.5 * v * v * t) / sq
  norm_pdf(d1) / (s * sq)
end

# Gamma at hypothetical spot s. Recompute via BS when IV is present;
# fall back to the CBOE-provided (static) gamma otherwise.
def gamma_at(o, s)
  o[:iv] > 0 ? bs_gamma(s, o[:k], o[:t], o[:iv]) : o[:gp]
end

OSI = /\A[A-Z]+(\d{6})([CP])(\d{8})\z/

def parse_chain(ticker, max_days, now)
  data = get_json("#{CBOE}/#{ticker}.json")['data']
  abort "#{ticker}: no data in CBOE response" unless data

  spot = (data['current_price'] || data['close']).to_f
  abort "#{ticker}: no spot price" if spot <= 0

  book = (data['options'] || []).map do |o|
    oi = o['open_interest'].to_f
    next if oi <= 0

    m = OSI.match(o['option'].to_s.delete(' ')) or next
    d = m[1]
    expiry = Time.utc(2000 + d[0, 2].to_i, d[2, 2].to_i, d[4, 2].to_i, 21)
    t = (expiry - now) / (365.25 * 86_400)
    next if t <= 0 || (max_days && t * 365.25 > max_days)

    iv = o['iv'].to_f
    gp = o['gamma'].to_f
    next if iv <= 0 && gp <= 0

    { k: m[3].to_f / 1000.0, cp: m[2], t: t, iv: iv, oi: oi, gp: gp }
  end.compact
  abort "#{ticker}: no live instruments parsed" if book.empty?

  [spot, book]
end

# Dollar gamma per 1% move at hypothetical spot x.
def net_gex(book, x)
  book.sum do |o|
    sgn = o[:cp] == 'C' ? 1.0 : -1.0
    sgn * gamma_at(o, x) * o[:oi] * MULT * x * x * 0.01
  end
end

def arg(flag)
  i = ARGV.index(flag)
  i && ARGV[i + 1]
end

# ---- main -------------------------------------------------------------------
tickers  = ARGV.select { |a| a =~ /\A[A-Za-z.]{1,6}\z/ }.map(&:upcase)
abort 'usage: gex_us.rb TICKER [TICKER ...] [--max-days N] [--json|--tmux]' if tickers.empty?

max_days = arg('--max-days') && arg('--max-days').to_f
now      = Time.now.utc

btc_spot = nil
if (tickers & BTC_ETFS).any?
  r = get_json('https://www.deribit.com/api/v2/public/get_index_price?index_name=btc_usd')
  btc_spot = r['result'] && r['result']['index_price'].to_f
end

fmt_m  = ->(v) { format('%+.1fM', v / 1e6) }
fmt_px = ->(v) { v >= 1000 ? format('%.1fk', v / 1000.0) : format('%g', v.round(2)) }

json_acc = []

tickers.each do |ticker|
  spot, book = parse_chain(ticker, max_days, now)

  profile = Hash.new(0.0)
  book.each do |o|
    sgn = o[:cp] == 'C' ? 1.0 : -1.0
    profile[o[:k]] += sgn * gamma_at(o, spot) * o[:oi] * MULT * spot * spot * 0.01
  end

  near      = profile.select { |k, _| (k - spot).abs / spot <= 0.30 }
  call_wall = near.max_by { |_, v| v }
  put_wall  = near.min_by { |_, v| v }
  total     = profile.values.sum

  vals = (0.70..1.30).step(0.005).map do |f|
    x = spot * f
    [x, net_gex(book, x)]
  end
  cross = vals.each_cons(2).find { |(_, a), (_, b)| a.negative? ^ b.negative? }
  flip  = cross && begin
    (x0, y0), (x1, y1) = cross
    (x0 - y0 * (x1 - x0) / (y1 - y0)).round(2)
  end

  put_oi  = book.sum { |o| o[:cp] == 'P' ? o[:oi] : 0.0 }
  call_oi = book.sum { |o| o[:cp] == 'C' ? o[:oi] : 0.0 }
  pc      = call_oi.zero? ? 0.0 : put_oi / call_oi

  ratio  = btc_spot && BTC_ETFS.include?(ticker) ? spot / btc_spot : nil
  to_btc = ->(v) { v && ratio ? v / ratio : nil }
  pxb    = ->(v) { ratio ? format('%s (%.1fK)', fmt_px.(v), v / ratio / 1000.0) : fmt_px.(v) }

  if ARGV.include?('--json')
    json_acc << {
      ticker: ticker, spot: spot.round(2), ts: now.iso8601,
      net_gex_usd_per_1pct: total.round,
      regime: total.negative? ? 'short_gamma' : 'long_gamma',
      gamma_flip: flip,
      gamma_flip_btc: to_btc.(flip) && to_btc.(flip).round,
      call_wall: call_wall && { strike: call_wall[0], gex: call_wall[1].round,
                                btc: to_btc.(call_wall[0]) && to_btc.(call_wall[0]).round },
      put_wall:  put_wall  && { strike: put_wall[0], gex: put_wall[1].round,
                                btc: to_btc.(put_wall[0]) && to_btc.(put_wall[0]).round },
      put_call_oi: pc.round(3),
      instruments: book.size,
      profile: Hash[profile.sort.map { |k, v| [k, v.round] }]
    }
    next
  end

  line = format('GEX %s %s flip %s PW %s CW %s P/C %.2f',
                ticker, fmt_m.(total),
                flip ? pxb.(flip) : '--',
                put_wall ? pxb.(put_wall[0]) : '--',
                call_wall ? pxb.(call_wall[0]) : '--', pc)

  if ARGV.include?('--tmux')
    File.write("/tmp/gex_#{ticker.downcase}.status", line + "\n")
    next
  end

  puts format('%s  spot %s  %s  (%d instruments)',
              ticker, pxb.(spot), now.strftime('%H:%M UTC'), book.size)
  puts format('net GEX %s per 1%%  ->  %s', fmt_m.(total),
              total.negative? ? 'SHORT GAMMA (amplifying)' : 'LONG GAMMA (pinning)')
  puts format('gamma flip ~ %s   put/call OI %.2f',
              flip ? pxb.(flip) : 'none in +/-30%', pc)
  if call_wall && put_wall
    puts format('call wall %s (%s)   put wall %s (%s)',
                pxb.(call_wall[0]), fmt_m.(call_wall[1]),
                pxb.(put_wall[0]),  fmt_m.(put_wall[1]))
  end

  puts
  max_abs = near.values.map(&:abs).max || 1.0
  profile.select { |k, _| (k - spot).abs / spot <= 0.15 }.sort.each do |k, v|
    bar = '#' * [(v.abs / max_abs * 40).round, 40].min
    puts format('%-16s %12s  %s%s', pxb.(k), fmt_m.(v), v.negative? ? '-' : '+', bar)
  end
  puts
end

puts JSON.pretty_generate(json_acc.size == 1 ? json_acc.first : json_acc) if ARGV.include?('--json')
