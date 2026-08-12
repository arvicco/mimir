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
#   BTC::Coinglass.get('option/info', { symbol: 'BTC' },
#                      cache: 'cg_option_info', ttl: 86_400) # cached, 24h
#
# DATA-SOURCE NOTES
#   Key: ENV['COINGLASS_API_KEY'] (CG-API-KEY header; same key etf_flows
#   uses). NEVER printed; error paths carry only the endpoint path. The
#   v4 envelope is {code:'0', msg:, data:} -- code != '0' is an API-level
#   error even under HTTP 200, raised here as Coinglass::Error so callers'
#   fail-soft paths treat it exactly like transport failure.
#
#   TIER GATING: our tier has no runtime tier-probe endpoint (the probe
#   path 404s), so tier detection is necessarily per-call -- an endpoint
#   above our tier answers HTTP 401. get() re-raises that as TierGated
#   (a Coinglass::Error subclass, message = path only) so callers rescue
#   it and fail soft with an explicit "tier-gated" reason instead of a
#   generic transport error. Any other HTTP status re-raises unchanged.
#
#   CACHING: get(..., cache: <name>, ttl: <seconds>) routes the fetch
#   through SourceCache (last-good fallback + ttl fresh-by-policy short-
#   circuit) -- for daily-cadence endpoints on a bi-hourly publish loop,
#   so we do not re-hit the API every run. Default (cache: nil) is the
#   direct Http path, unchanged. The v4 envelope code check applies to
#   cached bodies too.
#
# CAVEATS
#   Our tier was probed 2026-07-08..10 (.docs/DEV-PROPOSALS.md): these
#   three endpoints are confirmed served. max-pain REQUIRES the exchange
#   param ('Required String parameter' 400 otherwise).

require 'json'
require_relative 'http'
require_relative 'source_cache'

module BTC
  module Coinglass
    BASE = 'https://open-api-v4.coinglass.com/api'

    class Error < StandardError; end

    # An endpoint above our API tier (HTTP 401). A per-call signal because
    # there is no runtime tier-probe endpoint; callers rescue it to fail
    # soft with an explicit "tier-gated" reason. Subclass of Error so
    # existing rescue Error paths still catch it.
    class TierGated < Error; end

    module_function

    def key
      k = ENV['COINGLASS_API_KEY'].to_s
      raise Error, 'COINGLASS_API_KEY not set' if k.empty?

      k
    end

    # GET an endpoint path (+ query params), unwrap the v4 envelope,
    # return the 'data' payload. Raises Coinglass::Error on a non-'0'
    # code (message redacted to code+path -- upstream msg may echo params),
    # TierGated on HTTP 401 (path only). When cache: is a source-cache
    # name the fetch routes through SourceCache (ttl: fresh-by-policy
    # short-circuit); default cache: nil takes the direct Http path.
    def get(path, params = {}, cache: nil, ttl: nil)
      qs  = params.map { |k, v| "#{k}=#{v}" }.join('&')
      url = qs.empty? ? "#{BASE}/#{path}" : "#{BASE}/#{path}?#{qs}"
      j   = fetch(url, cache, ttl)
      raise Error, "coinglass #{path}: code #{j['code']}" unless j['code'].to_s == '0'

      j['data']
    rescue BTC::Http::StatusError => e
      raise TierGated, "coinglass #{path}: tier-gated (401)" if e.code == 401

      raise
    end

    # Fetch the v4 envelope for `url`, either directly or (when cache is
    # a source-cache name) through SourceCache's last-good + ttl seam.
    # SourceCache wraps the upstream body as its own 'data'; that body IS
    # the v4 envelope, so we unwrap one layer here.
    def fetch(url, cache, ttl)
      hdr = { 'CG-API-KEY' => key }
      return Http.get_json(url, hdr) unless cache

      SourceCache.fetch_json(cache, url, hdr, ttl: ttl)['data']
    end

    # Per-exchange option open interest / volume snapshot (M8-3).
    # Params braced explicitly so they land in get's `params` and not its
    # cache:/ttl: keywords (M10-1); default = uncached, as before.
    def option_info(symbol: 'BTC')
      get('option/info', { symbol: symbol })
    end

    # Per-expiry max-pain rows for one exchange (M8-3). Rows carry
    # date, max_pain_price, call/put open interest + notionals.
    def max_pain(symbol: 'BTC', exchange: 'Deribit')
      get('option/max-pain', { symbol: symbol, exchange: exchange })
    end

    # OI-weighted funding-rate OHLC history (M8-4). Rows carry
    # time (ms), open/high/low/close (rate fractions per interval).
    def funding_oi_history(symbol: 'BTC', interval: '8h')
      get('futures/funding-rate/oi-weight-history', { symbol: symbol, interval: interval })
    end
  end
end
