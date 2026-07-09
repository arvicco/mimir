#!/usr/bin/env ruby
# frozen_string_literal: true
#
# validate.rb -- per-ticker objective sanity check of the BTCo universe
# against external researchers (M7-15, owner-ruled 2026-07-09: "NONE of
# the ratios currently on file are even close to what other researchers
# report... we need some kind of objective source of truth").
#
#   ruby scripts/btco/validate.rb                  # every company
#   ruby scripts/btco/validate.rb --ticker MSTR    # one company
#   ruby scripts/btco/validate.rb --payload F      # offline payload file
#                                                  #   (default: live KV v1:btco:latest)
#
# Per company it prints:
#   OURS      the row the dashboard actually serves (px, btc, mNAV, dates)
#   EXTERNAL  StrategyTracker's published mNAV + inputs (px, shares w/ date,
#             btc, btc spot), plus independent BTC counts (bitcointreasuries,
#             coingecko) and the SEC dei cover count where it exists
#   RECONCILE our mNAV vs the tracker's, decomposed into the four input
#             factors (px / shares / btc / btc spot); the dominant factor
#             NAMES the input that drives the divergence; a residual far
#             from 1 flags a definition mismatch instead
#   NEEDS     plain-words to-do lines, each with the exact next action
#
# Read-only everywhere: never writes universe.json, ledgers, or state.
# Sources: StrategyTracker feed (registered in lib/btc/health.rb via
# ingest.rb's entry -- same source, second consumer), BTC::TreasuryRef,
# BTC::CoingeckoRef, BTC::SecShares (all registered + cached), and our
# own published payload via Publish::KV (CLOUDFLARE_* env) or --payload.
# A dead external degrades to a printed 'unavailable', never an abort.
#
# Env: CLOUDFLARE_API_TOKEN/_ACCOUNT_ID/_KV_NAMESPACE_ID (live payload
# read; names only, never printed), EDGAR_UA (SEC courtesy).
# Ruby >= 3.3, stdlib only.

require 'json'
require 'time'
require_relative '../../lib/btc/util'
require_relative '../../lib/btc/http'
require_relative '../../lib/btc/treasury_ref'
require_relative '../../lib/btc/coingecko_ref'
require_relative '../../lib/btc/sec_shares'
require_relative '../../publish/kv_client'
require_relative 'validate_core'

DIR = File.expand_path(__dir__)
UA  = { 'User-Agent' => ENV['EDGAR_UA'] || 'btco-validate (set EDGAR_UA=name email)' }.freeze

universe = JSON.parse(File.read(File.join(DIR, 'universe.json')))
only     = BTC::Util.arg('--ticker')

# ---- our published payload (what the owner's dashboard serves) -----------------
payload =
  if (f = BTC::Util.arg('--payload'))
    JSON.parse(File.read(f))['payload']
  else
    begin
      JSON.parse(Publish::KV.get('v1:btco:latest', env: ENV))['payload']
    rescue StandardError => e
      abort "cannot read the live payload (#{e.class}) -- pass --payload FILE " \
            'or set the CLOUDFLARE_* env (names in the header)'
    end
  end

# ---- StrategyTracker feed (one fetch for the whole run; fail-soft) --------------
tracker_companies =
  begin
    ptr  = JSON.parse(BTC::Http.get('https://data.strategytracker.com/latest.json', {},
                                    read_timeout: 30))
    full = ptr.dig('files', 'full')
    JSON.parse(BTC::Http.get("https://data.strategytracker.com/#{full}", {},
                             read_timeout: 120), max_nesting: false)['companies']
  rescue StandardError => e
    warn "strategytracker unavailable (#{e.class}) -- reconciliation limited"
    nil
  end

puts format('btco validate -- payload %s · btc_spot %s · tracker %s',
            payload['ts'], Btco::Validate.commafy(payload['btc_spot']),
            tracker_companies ? 'live' : 'UNAVAILABLE')

universe['companies'].each do |co|
  t = co['ticker']
  next if only && t != only

  ours    = Btco::Validate.our_view(payload, co)
  tracker = Btco::Validate.tracker_view(tracker_companies, t)
  refs    = {}
  [BTC::TreasuryRef, BTC::CoingeckoRef].each do |mod|
    r = begin
      mod.btc_for(t)
    rescue StandardError
      nil
    end
    refs[r['source']] = r['btc'] if r
  end
  sec = co['cik'].to_i.positive? ? BTC::SecShares.outstanding_for(co['cik'], headers: UA) : nil

  puts format("\n%s (%s)", t, co['name'])
  if ours
    puts format('  OURS      px %s · btc %s (as-of %s) · shares %s · mNAV %s%s%s',
                ours['px'], Btco::Validate.commafy(ours['btc']), ours['btc_as_of'],
                ours['shares'] ? Btco::Validate.commafy(ours['shares']) : '--',
                ours['mnav'] || '--',
                ours['stale'] ? ' · STALE' : '', ours['placeholder'] ? ' · placeholder' : '')
  else
    puts '  OURS      -- no row on the dashboard --'
  end
  if tracker
    puts format('  EXTERNAL  strategytracker(%s): mNAV %s basic / %s diluted · px %s · ' \
                'shares %s @%s · btc %s',
                tracker['key'],
                tracker['mnav_basic'] ? format('%.3f', tracker['mnav_basic']) : '--',
                tracker['mnav_diluted'] ? format('%.3f', tracker['mnav_diluted']) : '--',
                tracker['px'],
                tracker['shares'] ? Btco::Validate.commafy(tracker['shares']) : '--',
                tracker['shares_as_of'],
                tracker['btc'] ? Btco::Validate.commafy(tracker['btc']) : '--')
  end
  refs.each { |src, n| puts format('  EXTERNAL  %s: btc %s', src, Btco::Validate.commafy(n)) }
  if sec
    puts format('  EXTERNAL  %s: shares %s (as-of %s, %s)',
                sec['source'], Btco::Validate.commafy(sec['shares']), sec['as_of'], sec['form'])
  end

  if (rec = Btco::Validate.reconcile(ours, tracker))
    fac = rec['factors'].map { |k, v| v ? "#{k} #{Btco::Validate.pct(v)}" : "#{k} n/a" }
                        .join(' · ')
    verdict =
      if (rec['actual_ratio'] - 1.0).abs <= Btco::Validate::TOL
        'MATCHES the external mNAV'
      elsif rec['residual'] && (rec['residual'] - 1.0).abs <= Btco::Validate::TOL
        "diverges #{Btco::Validate.pct(rec['actual_ratio'])} -- fully explained " \
        "by inputs; dominant: #{rec['dominant']}"
      else
        "diverges #{Btco::Validate.pct(rec['actual_ratio'])} -- inputs explain " \
        "#{Btco::Validate.pct(rec['explained_ratio'])}; residual " \
        "#{Btco::Validate.pct(rec['residual'])} suggests a DEFINITION mismatch"
      end
    puts "  RECONCILE #{verdict}"
    puts "            #{fac}"
  end

  needs = Btco::Validate.needs(co, ours, refs, tracker)
  if needs.empty?
    puts '  NEEDS     nothing -- inputs agree with external refs'
  else
    needs.each { |n| puts "  NEEDS     #{n}" }
  end
end
