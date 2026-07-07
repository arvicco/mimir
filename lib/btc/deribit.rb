# frozen_string_literal: true
#
# deribit.rb -- Deribit public-API venue helper over the http seam.
# Owns the base URL and the {"result": ...} envelope unwrap that five
# scripts previously spelled out on their own (TOOL-REVIEW.md R-1/R-8).

require 'json'
require_relative 'http'
require_relative 'source_cache'

module BTC
  module Deribit
    BASE = 'https://www.deribit.com/api/v2/public'

    module_function

    # GET <BASE>/<path>, unwrap the result envelope (KeyError if absent).
    def result(path, headers = {})
      JSON.parse(Http.get("#{BASE}/#{path}", headers)).fetch('result')
    end

    # Index price as a Float, e.g. index_price('btc_usd'). UNCACHED: kept
    # for callers whose contract is a plain fail-on-outage (gex.rb, the
    # scenario funding module -- score-0-vs-stale-reuse is a Phase 9
    # research decision, so those stay off the last-good cache).
    def index_price(index_name)
      result("get_index_price?index_name=#{index_name}")
        .fetch('index_price').to_f
    end

    # Index price WITH last-good caching, shared across every adopting
    # caller via one 'deribit_index' cache entry (M7-8). Returns
    # { price:, as_of:, stale: }: stale true when the live call failed and
    # the value came from cache; the fetch re-raises (caller fail-softs)
    # only when there is no cache within the hard age cap. Spot is the
    # axis, so a stale spot still lets the ETF/Deribit books normalize.
    def index(index_name, now: Time.now.utc)
      r = SourceCache.fetch_json(
        'deribit_index', "#{BASE}/get_index_price?index_name=#{index_name}", now: now
      )
      { price: r['data'].fetch('result').fetch('index_price').to_f,
        as_of: r['as_of'], stale: r['stale'] }
    end

    # Whole-board summary rows, e.g. book_summary('BTC', 'option').
    def book_summary(currency, kind)
      result("get_book_summary_by_currency?currency=#{currency}&kind=#{kind}")
    end
  end
end
