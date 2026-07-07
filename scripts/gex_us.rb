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
#   ruby gex_us.rb IBIT --json        # single ticker -> ONE OBJECT;
#   ruby gex_us.rb IBIT MSTR --json   #   multiple -> ARRAY (frozen contract)
#   ruby gex_us.rb IBIT MSTR --tmux   # one line each -> /tmp/gex_<ticker>.status
#
# For spot-BTC ETFs (IBIT, FBTC, ...) every price output is annotated with
# its approximate BTC equivalent, e.g. "34.8 (61.4K)", via the Deribit index.
#
# Ruby >= 2.5, stdlib only. Sign convention as in gex.rb: dealers long
# calls / short puts (call gamma +, put gamma -); on OPRA customer flow
# this assumption is more defensible than on Deribit. Quotes are ~15 min
# delayed; open interest is previous-day (OPRA updates OI overnight).
# US expiry approximated at 21:00 UTC year-round (4pm ET ignoring DST);
# worst case 1h of T error, negligible at daily horizons.
#
# Failure mode: aborts with a message on stderr, exit != 0 (no fail-soft
# JSON) -- downstream consumers must treat nonzero exit as keep-last-good.
# Last-good cache (M7-8): the CBOE chain and Deribit index read through
# BTC::SourceCache, so a source outage computes off its cached copy
# (within a 48h cap) instead of aborting; only a dead source with NO cache
# aborts. --json gains a top-level 'sources' list ({name,as_of,stale}) per
# ticker and a top-level 'stale' => true when the chain came from cache.

require 'json'
require 'time'
require_relative '../lib/btc/options'
require_relative '../lib/btc/util'
require_relative '../lib/btc/http'
require_relative '../lib/btc/deribit'
require_relative '../lib/btc/source_cache'
require_relative '../lib/btc/report'
require_relative '../lib/btc/format'

CBOE = 'https://cdn.cboe.com/api/global/delayed_quotes/options'
MULT = 100.0 # shares per contract
BTC_ETFS = %w[IBIT FBTC BITB ARKB GBTC BTC HODL BTCO BRRR EZBC].freeze

# The CBOE chain via the shared last-good cache ('cboe_<ticker>', M7-8):
# a chain outage still computes off the cached board (marked stale);
# no cache within the cap re-raises and we abort (the documented hard
# failure). Returns [spot, book, source={name,as_of,stale}].
def parse_chain(ticker, max_days, now)
  url = "#{CBOE}/#{ticker}.json"
  begin
    r = BTC::SourceCache.fetch_json("cboe_#{ticker.downcase}", url,
                                    { 'User-Agent' => 'gex_us.rb' }, now: now)
  rescue StandardError => e
    abort "fetch #{url}: #{e.class}: #{e.message}"
  end
  data = r['data']['data']
  abort "#{ticker}: no data in CBOE response" unless data

  spot = (data['current_price'] || data['close']).to_f
  abort "#{ticker}: no spot price" if spot <= 0

  book = (data['options'] || []).map do |o|
    oi = o['open_interest'].to_f
    next if oi <= 0

    expiry, cp, k = BTC::Options.parse_osi(o['option'])
    next unless expiry

    t = (expiry - now) / BTC::Options::YEAR_S
    next if t <= 0 || (max_days && t * 365.25 > max_days)

    iv = o['iv'].to_f
    gp = o['gamma'].to_f
    next if iv <= 0 && gp <= 0

    { k: k, cp: cp, t: t, iv: iv, oi: oi, gp: gp }
  end.compact
  abort "#{ticker}: no live instruments parsed" if book.empty?

  [spot, book, { name: "cboe_#{ticker.downcase}", as_of: r['as_of'], stale: r['stale'] }]
end

# Dollar gamma per 1% move at hypothetical spot x (x IS each
# instrument's underlying here -- single-name chains).
def net_gex(book, x)
  book.sum { |o| BTC::Options.inst_gex(o, x, MULT) }
end

# ---- main -------------------------------------------------------------------
tickers  = ARGV.select { |a| a =~ /\A[A-Za-z.]{1,6}\z/ }.map(&:upcase)
abort 'usage: gex_us.rb TICKER [TICKER ...] [--max-days N] [--json|--tmux]' if tickers.empty?

max_days = BTC::Util.arg('--max-days')&.to_f
now      = Time.now.utc

btc_spot   = nil
deribit_src = nil # {name,as_of,stale} shared by every BTC-ETF ticker below
if (tickers & BTC_ETFS).any?
  begin
    di = BTC::Deribit.index('btc_usd', now: now)
  rescue StandardError => e
    abort "fetch deribit index: #{e.class}: #{e.message}"
  end
  btc_spot    = di[:price]
  deribit_src = { name: 'deribit_index', as_of: di[:as_of], stale: di[:stale] }
end

fmt_m  = BTC::Format.method(:musd)
fmt_px = ->(v) { v >= 1000 ? format('%.1fk', v / 1000.0) : format('%g', v.round(2)) }

json_acc = []

tickers.each do |ticker|
  spot, book, cboe_src = parse_chain(ticker, max_days, now)

  # sources consulted for THIS ticker: the deribit index (BTC ETFs only,
  # for the BTC-equivalent annotations) plus its own CBOE chain (M7-8).
  sources = []
  sources << deribit_src if deribit_src && BTC_ETFS.include?(ticker)
  sources << cboe_src

  profile = Hash.new(0.0)
  book.each { |o| profile[o[:k]] += BTC::Options.inst_gex(o, spot, MULT) }

  near, call_wall, put_wall = BTC::Options.walls(profile, spot)
  total = profile.values.sum

  flip = BTC::Options.gamma_flip(spot) { |x| net_gex(book, x) }
  flip = flip && flip.round(2)

  pc = BTC::Options.put_call_ratio(book) { |o| o[:oi] }

  ratio  = btc_spot && BTC_ETFS.include?(ticker) ? spot / btc_spot : nil
  to_btc = ->(v) { v && ratio ? v / ratio : nil }
  pxb    = ->(v) { ratio ? format('%s (%.1fK)', fmt_px.(v), v / ratio / 1000.0) : fmt_px.(v) }

  if ARGV.include?('--json')
    obj = {
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
      # additive (M7-8): sources consulted this run; top-level 'stale' is
      # present ONLY when the CBOE chain came from cache (absent = fresh),
      # so the all-fresh contract fixtures stay field-set valid.
      sources: sources.map { |s| { name: s[:name], as_of: s[:as_of], stale: s[:stale] } },
      profile: Hash[profile.sort.map { |k, v| [k, v.round] }]
    }
    obj[:stale] = true if cboe_src[:stale]
    json_acc << obj
    next
  end

  line = format('GEX %s %s flip %s PW %s CW %s P/C %.2f',
                ticker, fmt_m.(total),
                flip ? pxb.(flip) : '--',
                put_wall ? pxb.(put_wall[0]) : '--',
                call_wall ? pxb.(call_wall[0]) : '--', pc)

  if ARGV.include?('--tmux')
    BTC::Report.status("gex_#{ticker.downcase}", line)
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
  BTC::Format.profile_bars(profile, near, spot, 16, pxb)
  puts
end

puts JSON.pretty_generate(json_acc.size == 1 ? json_acc.first : json_acc) if ARGV.include?('--json')
