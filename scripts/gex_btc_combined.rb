#!/usr/bin/env ruby
# frozen_string_literal: true
#
# gex_btc_combined.rb -- combined Bitcoin GEX across Deribit BTC options and
# all US-listed spot-BTC ETF option chains (CBOE delayed quotes), normalized
# to BTC price levels.
#
#   ruby gex_btc_combined.rb                 # full picture
#   ruby gex_btc_combined.rb --max-days 45   # near-dated boards only
#   ruby gex_btc_combined.rb --bin 500       # strike bucket width, BTC-USD
#   ruby gex_btc_combined.rb --json          # machine-readable dump
#   ruby gex_btc_combined.rb --tmux          # -> /tmp/gex_btc_combined.status
#
# Method: every instrument's strike is mapped to its BTC-equivalent level via
# the live ratio (ETF spot / Deribit BTC index) and bucketed on the BTC price
# axis (Deribit strikes map 1:1). Dollar gamma per 1% BTC move is computed
# per instrument via Black-Scholes from its own IV; the flip scan reprices
# ALL books at hypothetical BTC levels, scaling each underlying
# proportionally. Units are USD delta-notional dealers re-hedge per 1% BTC
# move -- identical to gex.rb / gex_us.rb, so per-venue numbers reconcile.
#
# Coverage: Deribit BTC board + every ETF in ETFS below that has a listed
# chain (missing/optionless tickers are skipped with a warning to stderr).
# Not covered: CME BTC options (no free chain source) and MSTR (not a BTC
# tracker; its gamma lives on MSTR's own price axis). ETF OI is prior-day
# (OPRA convention); Deribit OI is live. Combined P/C is computed on
# BTC-equivalent open interest so venues weigh comparably.
# Sign convention: dealers long calls / short puts.
#
# Failure mode: individual venues fail soft (skipped with a stderr
# warning), but the Deribit index call or all venues failing aborts with
# exit != 0 -- downstream consumers must treat that as keep-last-good.
# Last-good cache (M7-8): the Deribit spot/book and each CBOE chain read
# through BTC::SourceCache, so a source outage still computes off its
# cached copy (within a 48h cap) rather than dropping the venue. --json
# gains a top-level 'sources' list ({name,as_of,stale}) and marks any
# venue whose book came from cache with 'stale' => true; the combined
# profile/walls/flip mix cached and fresh books exactly as if all fresh.
#
# Ruby >= 2.5, stdlib only.

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
# BRRR dropped 2026-07-06 (owner ruling): the Valkyrie fund rebranded
# under CoinShares and CBOE 403s the old ticker on every sweep.
ETFS    = %w[IBIT FBTC BITB ARKB GBTC HODL BTCO EZBC].freeze
MULT    = 100.0 # shares per US option contract

# USD gamma per 1% BTC move for one instrument, with BTC at hypothetical
# level x (its underlying scaled proportionally from spot).
def gex_at(o, btc_spot, x)
  BTC::Options.inst_gex(o, o[:u] * x / btc_spot, o[:cm])
end

# Open interest in BTC-equivalent units (for cross-venue P/C).
def oi_btc(o, btc_spot)
  o[:oi] * o[:cm] * o[:u] / btc_spot
end

# Deribit BTC option board via the shared last-good cache ('deribit_book',
# M7-8). Returns [book, as_of, stale] -- a 503 still computes off the cached
# board (marked stale); no cache within cap re-raises (caller skips Deribit).
def load_deribit(max_days, now, btc_spot)
  r = BTC::SourceCache.fetch_json(
    'deribit_book',
    "#{BTC::Deribit::BASE}/get_book_summary_by_currency?currency=BTC&kind=option", now: now
  )
  book = r['data'].fetch('result').map do |row|
    oi = row['open_interest'].to_f
    next if oi <= 0

    _, exp, strike, cp = row['instrument_name'].split('-')
    ex = BTC::Options.deribit_expiry(exp) or next
    t  = (ex - now) / BTC::Options::YEAR_S
    next if t <= 0 || (max_days && t * 365.25 > max_days)

    iv = row['mark_iv'].to_f / 100.0
    next if iv <= 0

    k = strike.to_f
    { k: k, k_btc: k, cp: cp, t: t, iv: iv, oi: oi,
      u: (row['underlying_price'] || btc_spot).to_f, cm: 1.0, gp: 0.0 }
  end.compact
  [book, r['as_of'], r['stale']]
end

# One CBOE ETF chain via the shared last-good cache ('cboe_<ticker>', M7-8).
# Returns [book, as_of, stale], or nil when the chain has no usable data.
def load_cboe(ticker, max_days, now, btc_spot)
  r = BTC::SourceCache.fetch_json("cboe_#{ticker.downcase}", "#{CBOE}/#{ticker}.json",
                                  { 'User-Agent' => 'gex_btc_combined.rb' }, now: now)
  data = r['data']['data']
  return nil unless data

  spot = (data['current_price'] || data['close']).to_f
  return nil if spot <= 0

  ratio = spot / btc_spot
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

    { k: k, k_btc: k / ratio, cp: cp, t: t, iv: iv, oi: oi,
      u: spot, cm: MULT, gp: gp }
  end.compact
  book.empty? ? nil : [book, r['as_of'], r['stale']]
end

# ---- main -------------------------------------------------------------------
max_days = BTC::Util.arg('--max-days')&.to_f
bin      = (BTC::Util.arg('--bin') || 1000).to_f
now      = Time.now.utc

# sources: every upstream that returned data this run (fresh or stale),
# each { name:, as_of:, stale: } -- surfaced additively in --json so the
# card can mark stale sources. venue_stale: name -> true when that venue's
# book came from cache (its profile still mixes into the combined picture).
sources     = []
venue_stale = {}

begin
  di = BTC::Deribit.index('btc_usd', now: now)
rescue StandardError => e
  abort "deribit index: #{e.class}: #{e.message}"
end
btc_spot = di[:price]
sources << { name: 'deribit_index', as_of: di[:as_of], stale: di[:stale] }

venues = {}
begin
  book, as_of, stale = load_deribit(max_days, now, btc_spot)
  venues['Deribit']       = book
  venue_stale['Deribit']  = stale
  sources << { name: 'deribit_book', as_of: as_of, stale: stale }
rescue StandardError => e
  warn "Deribit: skipped (#{e.class}: #{e.message})"
end
ETFS.each do |tk|
  begin
    res = load_cboe(tk, max_days, now, btc_spot) or next
    book, as_of, stale = res
    venues[tk]      = book
    venue_stale[tk] = stale
    sources << { name: "cboe_#{tk.downcase}", as_of: as_of, stale: stale }
  rescue StandardError => e
    warn "#{tk}: skipped (#{e.class}: #{e.message})"
  end
end
abort 'no option books loaded' if venues.empty?

all_book = venues.values.flatten

per_venue = venues.map do |name, book|
  tot = book.inject(0.0) { |a, o| a + gex_at(o, btc_spot, btc_spot) }
  { name: name, net: tot, n: book.size,
    pc: BTC::Options.put_call_ratio(book) { |o| oi_btc(o, btc_spot) } }
end

total  = per_venue.inject(0.0) { |a, v| a + v[:net] }
pc_all = BTC::Options.put_call_ratio(all_book) { |o| oi_btc(o, btc_spot) }

# Bucketed profile on the BTC price axis; per-venue put/call split kept
# alongside (additive --json field for the gex_btc chart, 2026-07-05;
# call+put per level sums to the net profile by construction).
profile  = Hash.new(0.0)
profiles = Hash.new { |h, k| h[k] = Hash.new { |g, l| g[l] = { 'call' => 0.0, 'put' => 0.0 } } }
venues.each do |name, book|
  book.each do |o|
    b = (o[:k_btc] / bin).round * bin
    g = gex_at(o, btc_spot, btc_spot)
    profile[b] += g
    profiles[name][b][o[:cp] == 'C' ? 'call' : 'put'] += g
  end
end

near, call_wall, put_wall = BTC::Options.walls(profile, btc_spot)

# Flip scan: net GEX repriced at hypothetical BTC levels over +/-30%.
flip = BTC::Options.gamma_flip(btc_spot) do |x|
  all_book.inject(0.0) { |a, o| a + gex_at(o, btc_spot, x) }
end
flip = flip && flip.round

fmt_m = BTC::Format.method(:musd)
fmt_k = ->(v) { v ? format('%gk', (v / 1000.0).round(2)) : '--' }

if ARGV.include?('--json')
  puts JSON.pretty_generate(
    ts: now.iso8601, btc_spot: btc_spot.round(1), bin: bin.round,
    # additive (M7-8): every source consulted this run; a venue entry
    # carries 'stale' => true ONLY when its book came from cache (absent =
    # fresh), so the all-fresh contract fixtures stay field-set valid.
    sources: sources.map { |s| { name: s[:name], as_of: s[:as_of], stale: s[:stale] } },
    venues: per_venue.map { |v|
      h = { name: v[:name], net_gex_usd_per_1pct: v[:net].round,
            instruments: v[:n], put_call_oi_btc: v[:pc].round(3) }
      h[:stale] = true if venue_stale[v[:name]]
      h
    },
    combined: {
      net_gex_usd_per_1pct: total.round,
      regime: total.negative? ? 'short_gamma' : 'long_gamma',
      gamma_flip: flip,
      call_wall: call_wall && { level: call_wall[0].round, gex: call_wall[1].round },
      put_wall:  put_wall  && { level: put_wall[0].round,  gex: put_wall[1].round },
      put_call_oi_btc: pc_all.round(3),
      instruments: all_book.size
    },
    profile: Hash[profile.sort.map { |k, v| [k.round, v.round] }],
    profiles: Hash[profiles.map { |name, per|
      [name, Hash[per.sort.map { |k, v|
        [k.round, { call: v['call'].round, put: v['put'].round }]
      }]]
    }]
  )
  exit
end

line = format('GEXsum %s flip %s PW %s CW %s P/C %.2f',
              fmt_m.(total), fmt_k.(flip),
              fmt_k.(put_wall && put_wall[0]),
              fmt_k.(call_wall && call_wall[0]), pc_all)

if ARGV.include?('--tmux')
  BTC::Report.status('gex_btc_combined', line)
  exit
end

puts format('BTC combined GEX   index %.0f   %s   bin %.0f',
            btc_spot, now.strftime('%H:%M UTC'), bin)
puts format('%-9s %14s %8s %8s', 'venue', 'net $GEX/1%', 'instr', 'P/C')
per_venue.sort_by { |v| v[:net] }.each do |v|
  puts format('%-9s %14s %8d %8.2f', v[:name], fmt_m.(v[:net]), v[:n], v[:pc])
end
puts '-' * 42
puts format('%-9s %14s %8d %8.2f  -> %s', 'COMBINED', fmt_m.(total),
            all_book.size, pc_all,
            total.negative? ? 'SHORT GAMMA (amplifying)' : 'LONG GAMMA (pinning)')
puts format('gamma flip ~ %s   call wall %s (%s)   put wall %s (%s)',
            fmt_k.(flip),
            fmt_k.(call_wall && call_wall[0]), call_wall ? fmt_m.(call_wall[1]) : '--',
            fmt_k.(put_wall && put_wall[0]),   put_wall  ? fmt_m.(put_wall[1])  : '--')

puts
BTC::Format.profile_bars(profile, near, btc_spot, 8, fmt_k)
