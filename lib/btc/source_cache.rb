# frozen_string_literal: true
#
# source_cache.rb -- read-through last-good cache over the HTTP seam
# (M7-8, owner priority ruling 2026-07-07: one dead provider must never
# blank a card). A suite fetches each upstream through fetch_json; a live
# fetch rewrites the cache and returns fresh; a FAILED fetch falls back to
# the last-good copy on disk (marked stale) when it is within the hard age
# cap, otherwise the original error re-raises and the caller fail-softs as
# before. This lets a suite COMBINE cached-stale data from a dead source
# with fresh data from live ones, degrading only when a source has no
# cache at all (or its cache is older than the cap).
#
# Usage:
#   r = BTC::SourceCache.fetch_json('deribit_index', url)
#   r['data']  -> parsed JSON (the upstream body)
#   r['as_of'] -> iso8601 of when THAT data was fetched (cache time if stale)
#   r['stale'] -> false on a live fetch, true when served from cache
#   # a fetch failure with no usable cache re-raises the ORIGINAL error
#   r = BTC::SourceCache.fetch_json('cg_x', url, ttl: 86_400)
#   # ttl: skips the network entirely while the cache is younger than ttl
#   # (fresh-by-policy, stale=false) -- for data slower than the loop
#
# Cache layout: one file per sanitized source name under the cache dir
# ($BTC_DATA_DIR/source_cache when set, else <repo>/data/source_cache),
# holding {fetched_at, url, data}. Writes are atomic (tmp + rename), so a
# crashed/concurrent write can never leave a half-written cache; errors are
# NEVER cached. now: and the network (via BTC::Http.transport) are
# injectable, so tests run offline against a temp BTC_DATA_DIR and a fake
# transport -- the real data/source_cache/ is never touched under test.
#
# Caveat: the cap is deliberately short (a week-old option chain is worse
# than an honest gap); past it we prefer a visible fail-soft to silent
# staleness. Freshness IS carried to the payload -- callers surface it.

require 'json'
require 'time'
require 'fileutils'
require_relative 'http'
require_relative 'env'

module BTC
  module SourceCache
    # Owner-approved hard cap (M7-8): a source may back a card from cache
    # for at most 48h. Past that the cache is treated as absent -- a
    # stale week-old chain is worse than an honest gap, so we re-raise.
    MAX_STALE_S = 48 * 3600

    module_function

    # Cache directory; honours the BTC_DATA_DIR seam like every other suite.
    def dir
      BTC::Env.data_dir('source_cache',
                        File.expand_path('../../data/source_cache', __dir__))
    end

    # Sanitize a source name into a safe single-file basename (no path
    # traversal, no odd characters): anything outside [A-Za-z0-9_-] folds
    # to '_'. Names are chosen per source ('deribit_index', 'cboe_ibit').
    def sanitize(name)
      name.to_s.gsub(/[^A-Za-z0-9_-]+/, '_')
    end

    def path(name)
      File.join(dir, "#{sanitize(name)}.json")
    end

    # Read-through fetch. On success: parse, rewrite the cache atomically,
    # return the fresh data. On ANY fetch/parse error: serve the last-good
    # cache when present and within max_stale_s (stale=true), else re-raise
    # the ORIGINAL error unchanged. Never caches an error.
    #
    # ttl: (seconds, default nil) is a fresh-by-policy short-circuit for
    # data whose upstream cadence is slower than the caller's loop -- when
    # given and the cache is younger than ttl, the cached entry is returned
    # WITHOUT any network call, stale=false (it is fresh by policy, not a
    # failure fallback). Older-than-ttl / absent / ttl nil all fall through
    # to the live-fetch-with-last-good-fallback path unchanged, so the
    # default (nil) is byte-identical to the pre-M10-1 behavior.
    def fetch_json(name, url, headers = {}, max_stale_s: MAX_STALE_S,
                   read_timeout: 20, now: Time.now.utc, ttl: nil)
      if ttl
        cached = read(name)
        if cached && (now - cached[:fetched_at]) < ttl
          return { 'data' => cached[:data], 'as_of' => cached[:fetched_at].iso8601,
                   'stale' => false }
        end
      end

      data = BTC::Http.get_json(url, headers, read_timeout: read_timeout)
      write(name, url, data, now)
      { 'data' => data, 'as_of' => now.iso8601, 'stale' => false }
    rescue StandardError => e
      cached = read(name)
      raise e unless cached && (now - cached[:fetched_at]) <= max_stale_s

      { 'data' => cached[:data], 'as_of' => cached[:fetched_at].iso8601,
        'stale' => true }
    end

    # Atomic write: serialize to a per-pid temp file then rename into place
    # (rename is atomic on the same filesystem), so a reader never sees a
    # partial file and a crashed write leaves the prior cache intact.
    def write(name, url, data, now)
      FileUtils.mkdir_p(dir)
      tmp = "#{path(name)}.tmp.#{Process.pid}"
      File.write(tmp, JSON.generate('fetched_at' => now.iso8601,
                                    'url' => url, 'data' => data))
      File.rename(tmp, path(name))
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end

    # Parsed cache -> { data:, fetched_at: Time(utc) }, or nil when the
    # cache is absent, unreadable, or corrupt (treated as no cache).
    def read(name)
      h = JSON.parse(File.read(path(name)))
      { data: h.fetch('data'), fetched_at: Time.parse(h.fetch('fetched_at')).utc }
    rescue StandardError
      nil
    end
  end
end
