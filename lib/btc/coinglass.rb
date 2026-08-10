# frozen_string_literal: true
#
# coinglass.rb -- thin keyed client for the Coinglass v4 API (M8-3/M8-4
# seam; the Phase-8 groundwork the 2026-07-06 plan sketched). One request
# helper plus a named wrapper per endpoint the packets consume, so callers
# never hand-build URLs and the health registry has one marker per
# endpoint family.
#
#   BTC::Coinglass.option_info                       # per-exchange option OI
#   BTC::Coinglass.max_pain(exchange: 'Deribit')     # per-expiry max pain
#   BTC::Coinglass.funding_oi_history(interval: '8h')# OI-weighted funding OHLC
#
# DATA-SOURCE NOTES
#   Key: ENV['COINGLASS_API_KEY'] (CG-API-KEY header; same key etf_flows
#   uses). NEVER printed; error paths carry only the endpoint path. The
#   v4 envelope is {code:'0', msg:, data:} -- code != '0' is an API-level
#   error even under HTTP 200, raised here as Coinglass::Error so callers'
#   fail-soft paths treat it exactly like transport failure.
#
# CAVEATS
#   Our tier was probed 2026-07-08..10 (docs/DEV-PROPOSALS.md): these
#   three endpoints are confirmed served. max-pain REQUIRES the exchange
#   param ('Required String parameter' 400 otherwise).

require 'json'
require_relative 'http'

module BTC
  module Coinglass
    BASE = 'https://open-api-v4.coinglass.com/api'

    class Error < StandardError; end

    module_function

    def key
      k = ENV['COINGLASS_API_KEY'].to_s
      raise Error, 'COINGLASS_API_KEY not set' if k.empty?

      k
    end

    # GET an endpoint path (+ query params), unwrap the v4 envelope,
    # return the 'data' payload. Raises Coinglass::Error on a non-'0'
    # code (message redacted to code+path -- upstream msg may echo params).
    def get(path, params = {})
      qs  = params.map { |k, v| "#{k}=#{v}" }.join('&')
      url = qs.empty? ? "#{BASE}/#{path}" : "#{BASE}/#{path}?#{qs}"
      j   = Http.get_json(url, { 'CG-API-KEY' => key })
      raise Error, "coinglass #{path}: code #{j['code']}" unless j['code'].to_s == '0'

      j['data']
    end

    # Per-exchange option open interest / volume snapshot (M8-3).
    def option_info(symbol: 'BTC')
      get('option/info', symbol: symbol)
    end

    # Per-expiry max-pain rows for one exchange (M8-3). Rows carry
    # date, max_pain_price, call/put open interest + notionals.
    def max_pain(symbol: 'BTC', exchange: 'Deribit')
      get('option/max-pain', symbol: symbol, exchange: exchange)
    end

    # OI-weighted funding-rate OHLC history (M8-4). Rows carry
    # time (ms), open/high/low/close (rate fractions per interval).
    def funding_oi_history(symbol: 'BTC', interval: '8h')
      get('futures/funding-rate/oi-weight-history', symbol: symbol, interval: interval)
    end
  end
end
