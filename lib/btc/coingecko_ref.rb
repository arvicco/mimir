# frozen_string_literal: true
#
# coingecko_ref.rb -- second independent BTC-holdings reference for ingest
# proposals (M7-11). Same advisory contract as BTC::TreasuryRef (M7-9):
# --review cross-checks a proposal's BTC figure against an aggregator
# mimir does not control; a miss, a dead source, or ANY error degrades to
# nil, never to an exception the caller sees. Two refs that disagree with
# each other are themselves a signal the owner wants to see.
#
# Source (data-source research, docs/BTCO-DATA-SOURCES.md, 2026-07-08):
# CoinGecko's keyless public-treasury snapshot -- plain JSON, ~175
# companies, covers the whole universe, verified live to match owner
# -confirmed counts (MSTR, DJT exact). It carries NO per-company as-of
# dates, so the ref's as_of is the FETCH time (same convention as
# TreasuryRef): it answers "what does the outside world say the count is
# right now", not "as of which filing".
#
# Caching: read-through via BTC::SourceCache (name 'coingecko_treasury',
# shared 48h cap) so a momentary outage serves the last-good snapshot.
#
# Matching: CoinGecko symbols are exchange-qualified ("MSTR.US",
# "3350.T"); we match the bare prefix before the dot, then fall back to a
# normalized-name-prefix alias map (SpaceX-style rows have empty
# symbols). Unknown company -> nil, never a guess.
#
# stdlib only; no ENV, no secrets. Network only via BTC::Http (through
# SourceCache), so tests inject a fake transport and run fully offline.

require 'time'
require_relative 'http'
require_relative 'source_cache'

module BTC
  module CoingeckoRef
    URL    = 'https://api.coingecko.com/api/v3/companies/public_treasury/bitcoin'
    SOURCE = 'coingecko'
    CACHE  = 'coingecko_treasury'

    # Universe ticker -> CoinGecko entity name, matched by normalized-name
    # prefix when the symbol lookup misses (kept in sync with
    # TreasuryRef::ALIAS -- same companies, same reasoning).
    ALIAS = {
      'MSTR' => 'Strategy', '3350' => 'Metaplanet', 'XXI' => 'XXI',
      'ASST' => 'Strive', 'BLSH' => 'Bullish', 'ABTC' => 'American Bitcoin',
      'DJT' => 'Trump Media', 'NAKA' => 'Nakamoto'
    }.freeze

    module_function

    # Public entry point. ticker_or_name -> { 'btc'=>Integer, 'source'=>str,
    # 'as_of'=>iso8601 } for a matched company, else nil (unknown company,
    # or source down with no usable cache). Never raises for a data miss.
    def btc_for(query, now: Time.now.utc)
      q = query.to_s.strip
      return nil if q.empty?

      fetched = fetch_snapshot(now: now)
      return nil unless fetched

      row = lookup(fetched['companies'], q)
      return nil unless row && row['total_holdings'].to_f.positive?

      { 'btc' => row['total_holdings'].to_f.round, 'source' => SOURCE,
        'as_of' => fetched['as_of'] }
    end

    # Resolve a query to one company row: bare-symbol match first
    # ("MSTR.US" answers "MSTR"), then the alias map / raw query by
    # normalized name prefix. No fuzzy fallback -> unknown returns nil.
    def lookup(companies, query)
      up = query.upcase
      sym_hit = companies.find { |c| c['symbol'].to_s.split('.').first.to_s.upcase == up }
      return sym_hit if sym_hit

      key = norm(ALIAS[up] || query)
      return nil if key.empty?

      companies.find { |c| norm(c['name']).start_with?(key) }
    end

    # Fold to a comparable form: lowercase alphanumerics, single-spaced.
    def norm(str)
      str.to_s.downcase.gsub(/[^a-z0-9]+/, ' ').strip
    end

    # Read-through snapshot fetch: SourceCache handles live-vs-last-good;
    # an empty/unrecognizable document is a failure (never cached as good
    # by us -- SourceCache only caches what parsed). Returns
    # { 'companies'=>[...], 'as_of'=>iso8601, 'stale'=>bool } or nil.
    def fetch_snapshot(now: Time.now.utc)
      fetched = BTC::SourceCache.fetch_json(CACHE, URL, {}, now: now)
      companies = fetched['data']['companies']
      return nil unless companies.is_a?(Array) && !companies.empty?

      { 'companies' => companies, 'as_of' => fetched['as_of'],
        'stale' => fetched['stale'] }
    rescue StandardError
      nil
    end
  end
end
