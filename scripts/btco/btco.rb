#!/usr/bin/env ruby
# frozen_string_literal: true
#
# btco.rb -- Bitcoin treasury company (BTCo) universe analyser.
#
#   ruby btco.rb                  # metrics table + aggregate stress score
#   ruby btco.rb --json           # machine dump
#   ruby btco.rb --tmux           # one line -> /tmp/btco.status
#   ruby btco.rb --check-filings  # list SEC filings newer than each
#                                 # company's btc_as_of (EDGAR, keyless)
#   ruby btco.rb --universe path  # alternate universe file
#
# Data flow: static fundamentals (BTC held, share counts, senior claims,
# convert tranches) live in universe.json with per-field as-of dates and
# are HUMAN-MAINTAINED; live inputs are US share prices (CBOE delayed
# quotes, keyless), FX (Frankfurter/ECB, keyless), and BTC spot (Deribit
# index). Non-US listings (Metaplanet) price via manual_px only.
# (Stooq served quotes+FX until its API died upstream 2026-07 --
# TOOL-REVIEW.md F-17; universe.json's 'stooq' field is vestigial.)
# --check-filings closes the loop: it queries EDGAR's submissions API
# for filings newer than your recorded as-of date and prints URLs (plus
# a best-effort hint), so the config is updated deliberately, never
# scraped blindly.
#
# Metrics per company:
#   sats/sh (dil)   BTC * 1e8 / assumed diluted shares
#   CEBE sats/sh    Common-Equity BTC Entitlement: net sats per diluted
#                   common after senior claims. In-the-money converts are
#                   treated as equity (face excluded from debt, shares
#                   added at conv price); OTM converts + straight debt +
#                   preferred liquidation are netted against the stack.
#   mNAV            market cap / BTC NAV
#   netNAV          market cap / (BTC NAV - senior claims)
#   EV/BTC          (mcap + senior) / BTC  -- price paid per coin
#   lev             senior claims / BTC NAV
#   Market cap is px * shares_BASIC (the market observable) by design;
#   per-share entitlement metrics (sats/sh, CEBE) use diluted counts.
#
# Verdict (per company, on netNAV with peer-median context):
#   DEEP-DISC < 0.90 | UNDER < 1.10 | FAIR < 1.45 | RICH < 1.90 | OVER >=
#
# Aggregate BTCo stress score (0-100, BTC-weighted):
#   45% share of universe (by BTC held) trading at mNAV < 1  (flywheel off)
#   35% median mNAV shortfall below 1.40                     (issuance dead)
#   20% aggregate leverage (senior / BTC NAV)                (fragility)
#   bands: <25 CALM, <50 ELEVATED, <75 STRESSED, >=75 CRITICAL
#   suite score: +1 if stress <= 30, -1 if >= 60, else 0
#
# Fail-soft: a dead input (universe, Deribit index, no priced companies)
# degrades to a score-0 report with exit 0, matching the scenario/lppl
# module contract; it never crashes an aggregate.
# Last-good cache (M7-8): spot (shared 'deribit_index'), each CBOE quote
# and the FX read through BTC::SourceCache, so a provider outage still
# prices off cached copies (within a 48h cap) rather than blanking rows.
# --json gains 'sources' ({name,as_of,stale}); 'spot_stale' and per-row
# 'px_stale' flag cache-sourced inputs. Fail-soft only when spot has no
# cache (spot is the NAV axis -- nothing to value coins against).
#
# Ruby >= 2.5, stdlib only.

require 'json'
require 'time'
require_relative 'metrics'
require_relative '../../lib/btc/report'
require_relative '../../lib/btc/util'
require_relative '../../lib/btc/http'
require_relative '../../lib/btc/deribit'
require_relative '../../lib/btc/source_cache'

UNIVERSE = BTC::Util.arg('--universe') ||
           File.join(File.expand_path(__dir__), 'universe.json')

def get(url, headers = {})
  ua = ENV['EDGAR_UA'] || 'btco.rb (set EDGAR_UA=name email)'
  BTC::Http.get(url, { 'User-Agent' => ua }.merge(headers), read_timeout: 30)
end

def get_json(url, headers = {})
  JSON.parse(get(url, headers))
end

# Suite convention (scenario/lppl): a dead data source degrades to a
# score-0 report and exit 0, never a crash.
def fail_soft(reason)
  BTC::Report.fail_soft('btco', reason, name_w: 6)
end

begin
  uni = JSON.parse(File.read(UNIVERSE))
rescue StandardError => e
  fail_soft("universe: #{e.class}: #{e.message}")
end
cos = uni['companies'] || []
fail_soft('empty universe') if cos.empty?

# ---- filings check mode ------------------------------------------------------
if ARGV.include?('--check-filings')
  cos.each do |c|
    cik = c['cik']
    if cik.nil? || cik.to_s.empty?
      puts format('%-6s no CIK (non-US or unset) -- check manually', c['ticker'])
      next
    end
    begin
      sub = get_json(format('https://data.sec.gov/submissions/CIK%010d.json', cik.to_i))
      r   = sub['filings']['recent']
      hits = []
      r['form'].each_index do |i|
        next unless %w[8-K 10-Q 10-K].include?(r['form'][i])
        next unless r['filingDate'][i] > c['btc_as_of'].to_s

        acc = r['accessionNumber'][i].delete('-')
        hits << format('  %s %-5s https://www.sec.gov/Archives/edgar/data/%d/%s/%s',
                       r['filingDate'][i], r['form'][i], cik.to_i, acc,
                       r['primaryDocument'][i])
        break if hits.size >= 5
      end
      puts format('%-6s %s since %s', c['ticker'],
                  hits.empty? ? 'no new filings' : "#{hits.size}+ filings",
                  c['btc_as_of'])
      puts hits.join("\n") unless hits.empty?
    rescue StandardError => e
      puts format('%-6s EDGAR failed (%s)', c['ticker'], e.message)
    end
    sleep 0.25
  end
  exit
end

# ---- live inputs -------------------------------------------------------------
now = Time.now.utc

# sources: every live upstream that returned data this run (fresh or stale),
# each { name:, as_of:, stale: } -- surfaced additively in --json so the card
# marks stale sources. Spot is the axis: fail-soft only when it has NO cache.
sources = []
UA = ENV['EDGAR_UA'] || 'btco.rb (set EDGAR_UA=name email)'

begin
  di = BTC::Deribit.index('btc_usd', now: now)
rescue StandardError => e
  fail_soft("deribit index: #{e.message}")
end
btc_px     = di[:price]
spot_stale = di[:stale]
sources << { name: 'deribit_index', as_of: di[:as_of], stale: di[:stale] }

CBOE = 'https://cdn.cboe.com/api/global/delayed_quotes/options'

quotes   = {} # ticker -> price in listing ccy (US listings only)
px_stale = {} # ticker -> true when the quote came from cache
cos.each do |c|
  next unless (c['ccy'] || 'USD').upcase == 'USD'

  begin
    r = BTC::SourceCache.fetch_json("cboe_quote_#{c['ticker']}",
                                    "#{CBOE}/#{c['ticker']}.json",
                                    { 'User-Agent' => UA }, read_timeout: 30, now: now)
    d = r['data']['data']
    next unless d

    px = (d['current_price'] || d['close']).to_f
    px = d['close'].to_f if px <= 0
    next unless px > 0

    quotes[c['ticker']]   = px
    px_stale[c['ticker']] = r['stale']
    sources << { name: "cboe_quote_#{c['ticker']}", as_of: r['as_of'], stale: r['stale'] }
  rescue StandardError => e
    warn "#{c['ticker']}: quote failed (#{e.message})"
  end
end

ccys = cos.map { |c| (c['ccy'] || 'USD').upcase }.uniq - ['USD']
fx = Hash.new(1.0) # ccy -> units per USD
unless ccys.empty?
  begin
    r = BTC::SourceCache.fetch_json(
      'frankfurter',
      "https://api.frankfurter.dev/v1/latest?base=USD&symbols=#{ccys.join(',')}",
      { 'User-Agent' => UA }, read_timeout: 30, now: now
    )
    rates = r['data']['rates'] || {}
    ccys.each { |x| fx[x] = rates[x].to_f }
    sources << { name: 'frankfurter', as_of: r['as_of'], stale: r['stale'] }
  rescue StandardError => e
    warn "fx: #{e.message}"
    ccys.each { |x| fx[x] = 0.0 }
  end
end

# ---- per-company metrics -----------------------------------------------------
rows = []
cos.each do |c|
  ccy = (c['ccy'] || 'USD').upcase
  px  = quotes[c['ticker']] || c['manual_px']
  next warn("#{c['ticker']}: no price, skipped") unless px

  rate = ccy == 'USD' ? 1.0 : fx[ccy]
  next warn("#{c['ticker']}: no FX #{ccy}, skipped") if rate.zero?

  rows << Btco.company_row(c, px, rate, btc_px, now)
end
fail_soft('no companies priced') if rows.empty?

med = lambda do |a|
  s = a.compact.sort
  s.empty? ? nil : s[s.size / 2]
end
med_netm = med.(rows.map { |r| r[:netm] })

verdict = lambda do |r|
  return 'N/A' unless r[:netm]

  v = r[:netm]
  if    v < 0.90 then 'DEEP-DISC'
  elsif v < 1.10 then 'UNDER'
  elsif v < 1.45 then 'FAIR'
  elsif v < 1.90 then 'RICH'
  else                'OVER'
  end
end

# ---- aggregate stress --------------------------------------------------------
tot_btc  = rows.inject(0.0) { |s, r| s + r[:btc] }
below_w  = rows.inject(0.0) { |s, r| s + (r[:mnav] && r[:mnav] < 1.0 ? r[:btc] : 0.0) } / tot_btc
mm       = med.(rows.map { |r| r[:mnav] }) || 0.0
shortfall = [[(1.40 - mm) / 0.80, 0.0].max, 1.0].min
agg_lev  = rows.inject(0.0) { |s, r| s + r[:lev] * r[:nav] } /
           [rows.inject(0.0) { |s, r| s + r[:nav] }, 1e-9].max
lev_c    = [[agg_lev / 0.50, 0.0].max, 1.0].min

stress = (100 * (0.45 * below_w + 0.35 * shortfall + 0.20 * lev_c)).round
band   = if    stress < 25 then 'CALM'
         elsif stress < 50 then 'ELEVATED'
         elsif stress < 75 then 'STRESSED'
         else                   'CRITICAL'
         end
score  = if stress >= 60 then -1
         elsif stress <= 30 then 1
         else 0
         end
n_stale = rows.count { |r| r[:stale] }

# ---- output ------------------------------------------------------------------
if ARGV.include?('--json')
  # additive (M7-8): 'sources' (always present) lists every live upstream
  # consulted; 'spot_stale' and per-company 'px_stale' are present ONLY
  # when true (absent = fresh), keeping the all-fresh contract fixtures
  # field-set valid. The mNAV/stress math mixes cached-stale and fresh
  # inputs exactly as if all fresh.
  out = {
    name: 'btco', score: score, ts: now.iso8601, btc_spot: btc_px.round,
    stress: stress, band: band,
    headline: format('stress %d (%s): %.0f%% of BTC-weighted universe below mNAV 1, median mNAV %.2f, lev %.0f%%',
                     stress, band, below_w * 100, mm, agg_lev * 100),
    below_1_btc_weighted: (below_w * 100).round(1),
    median_mnav: mm.round(3), median_net_mnav: med_netm && med_netm.round(3),
    aggregate_leverage: agg_lev.round(3), stale_entries: n_stale,
    sources: sources.map { |s| { name: s[:name], as_of: s[:as_of], stale: s[:stale] } },
    companies: rows.map do |r|
      h = { ticker: r[:t], px: r[:px], ccy: r[:ccy], btc: r[:btc].round,
            sats_sh_diluted: r[:sats_d].round, cebe_sats_sh: r[:cebe].round,
            mnav: r[:mnav] && r[:mnav].round(3), net_mnav: r[:netm] && r[:netm].round(3),
            ev_per_btc: r[:ev] && r[:ev].round, leverage: r[:lev].round(3),
            verdict: verdict.(r), btc_as_of: r[:as_of],
            stale: r[:stale] || false, placeholder: r[:ph] || false }
      h[:px_stale] = true if px_stale[r[:t]]
      h
    end
  }
  out[:spot_stale] = true if spot_stale
  puts JSON.pretty_generate(out)
  exit
end

line = format('BTCO %d %s <1:%d%% med %.2f lev %.0f%%%s',
              stress, band, (below_w * 100).round, mm, agg_lev * 100,
              n_stale > 0 ? " stale:#{n_stale}" : '')
if ARGV.include?('--tmux')
  BTC::Report.status('btco', line)
  exit
end

puts format('BTC treasury universe   BTC %.0f   %s', btc_px, now.strftime('%H:%M UTC'))
puts format('%-6s %9s %9s %10s %10s %6s %6s %9s %5s  %-9s %s',
            'tick', 'px', 'BTC', 'sats/shD', 'CEBE s/sh', 'mNAV', 'netNAV',
            'EV/BTC', 'lev', 'verdict', 'as-of')
rows.sort_by { |r| -r[:btc] }.each do |r|
  puts format('%-6s %9.2f %9d %10d %10d %6s %6s %9s %4.0f%%  %-9s %s%s%s',
              r[:t], r[:px], r[:btc], r[:sats_d], r[:cebe],
              r[:mnav] ? format('%.2f', r[:mnav]) : '--',
              r[:netm] ? format('%.2f', r[:netm]) : 'neg',
              r[:ev] ? format('%d', r[:ev]) : '--',
              r[:lev] * 100, verdict.(r), r[:as_of],
              r[:stale] ? ' STALE' : '', r[:ph] ? ' *' : '')
end
puts '-' * 100
puts format('STRESS %d -> %s   (below-1: %.0f%% BTC-wt, median mNAV %.2f, agg lev %.0f%%)%s',
            stress, band, below_w * 100, mm, agg_lev * 100,
            n_stale > 0 ? "  [#{n_stale} stale entries -- run --check-filings]" : '')
puts '* placeholder seed data -- update universe.json' if rows.any? { |r| r[:ph] }
