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
# are HUMAN-MAINTAINED; live inputs are share prices (Stooq CSV, keyless,
# covers US+JP), FX (Stooq), and BTC spot (Deribit index). --check-filings
# closes the loop: it queries EDGAR's submissions API for filings newer
# than your recorded as-of date and prints URLs (plus a best-effort hint),
# so the config is updated deliberately, never scraped blindly.
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
# Ruby >= 2.5, stdlib only.

require 'net/http'
require 'json'
require 'time'
require_relative 'metrics'

def arg(flag)
  i = ARGV.index(flag)
  i && ARGV[i + 1]
end

UNIVERSE = arg('--universe') || File.join(File.expand_path(__dir__), 'universe.json')
STALE_D  = 120

def get(url, headers = {})
  uri = URI(url)
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                  open_timeout: 5, read_timeout: 30) do |http|
    req = Net::HTTP::Get.new(uri.request_uri,
                             { 'User-Agent' => ENV['EDGAR_UA'] || 'btco.rb (set EDGAR_UA=name email)' }
                               .merge(headers))
    res = http.request(req)
    raise "HTTP #{res.code}" unless res.code.to_i == 200

    res.body
  end
end

def get_json(url, headers = {})
  JSON.parse(get(url, headers))
end

begin
  uni = JSON.parse(File.read(UNIVERSE))
rescue StandardError => e
  abort "universe: #{e.class}: #{e.message}"
end
cos = uni['companies'] || []
abort 'empty universe' if cos.empty?

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
begin
  btc_px = get_json('https://www.deribit.com/api/v2/public/get_index_price?index_name=btc_usd')
           .fetch('result').fetch('index_price').to_f
rescue StandardError => e
  abort "deribit index: #{e.message}"
end

syms = cos.map { |c| c['stooq'] }.compact
ccys = cos.map { |c| (c['ccy'] || 'USD').upcase }.uniq - ['USD']
syms += ccys.map { |x| "usd#{x.downcase}" }

quotes = {}
begin
  csv = get("https://stooq.com/q/l/?s=#{syms.join('+')}&f=sd2t2ohlcv&h&e=csv")
  csv.lines.drop(1).each do |ln|
    f = ln.strip.split(',')
    next if f.size < 7 || f[6] == 'N/D'

    quotes[f[0].downcase] = f[6].to_f
  end
rescue StandardError => e
  warn "stooq: #{e.message} (manual_px fallbacks only)"
end

fx = Hash.new(1.0) # ccy -> units per USD
ccys.each { |x| fx[x] = quotes["usd#{x.downcase}"] || 0.0 }

# ---- per-company metrics -----------------------------------------------------
now  = Time.now.utc
rows = []
cos.each do |c|
  ccy = (c['ccy'] || 'USD').upcase
  px  = quotes[c['stooq'].to_s.downcase] || c['manual_px']
  next warn("#{c['ticker']}: no price, skipped") unless px

  rate   = ccy == 'USD' ? 1.0 : fx[ccy]
  next warn("#{c['ticker']}: no FX #{ccy}, skipped") if rate.zero?

  px_usd = px / rate
  btc    = c['btc'].to_f
  shs_b  = c['shares_basic'].to_f
  shs_d  = [c['shares_diluted'].to_f, shs_b].max

  itm_sh, otm_fc = BtcoMetrics.convert_split(c['converts'], px, rate)
  senior = otm_fc + c['debt_face'].to_f + c['pref_liq'].to_f
  shs_a  = shs_d + itm_sh

  nav      = btc * btc_px
  mcap     = px_usd * shs_b
  net_nav  = nav - senior
  sats_d   = btc * 1e8 / shs_d
  cebe     = [net_nav, 0.0].max / btc_px * 1e8 / shs_a
  mnav     = nav.zero? ? nil : mcap / nav
  netm     = net_nav > 0 ? mcap / net_nav : nil
  ev_btc   = btc.zero? ? nil : (mcap + senior) / btc
  lev      = nav.zero? ? 0.0 : senior / nav
  stale    = c['btc_as_of'] && (now - Time.parse(c['btc_as_of'] + ' 00:00:00 UTC')) / 86_400 > STALE_D

  rows << { t: c['ticker'], px: px, ccy: ccy, btc: btc, sats_d: sats_d,
            cebe: cebe, mnav: mnav, netm: netm, ev: ev_btc, lev: lev,
            mcap: mcap, nav: nav, stale: stale, as_of: c['btc_as_of'],
            ph: c['placeholder'] }
end
abort 'no companies priced' if rows.empty?

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
  puts JSON.pretty_generate(
    name: 'btco', score: score, ts: now.iso8601, btc_spot: btc_px.round,
    stress: stress, band: band,
    headline: format('stress %d (%s): %.0f%% of BTC-weighted universe below mNAV 1, median mNAV %.2f, lev %.0f%%',
                     stress, band, below_w * 100, mm, agg_lev * 100),
    below_1_btc_weighted: (below_w * 100).round(1),
    median_mnav: mm.round(3), median_net_mnav: med_netm && med_netm.round(3),
    aggregate_leverage: agg_lev.round(3), stale_entries: n_stale,
    companies: rows.map do |r|
      { ticker: r[:t], px: r[:px], ccy: r[:ccy], btc: r[:btc].round,
        sats_sh_diluted: r[:sats_d].round, cebe_sats_sh: r[:cebe].round,
        mnav: r[:mnav] && r[:mnav].round(3), net_mnav: r[:netm] && r[:netm].round(3),
        ev_per_btc: r[:ev] && r[:ev].round, leverage: r[:lev].round(3),
        verdict: verdict.(r), btc_as_of: r[:as_of],
        stale: r[:stale] || false, placeholder: r[:ph] || false }
    end
  )
  exit
end

line = format('BTCO %d %s <1:%d%% med %.2f lev %.0f%%%s',
              stress, band, (below_w * 100).round, mm, agg_lev * 100,
              n_stale > 0 ? " stale:#{n_stale}" : '')
if ARGV.include?('--tmux')
  File.write('/tmp/btco.status', line + "\n")
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
