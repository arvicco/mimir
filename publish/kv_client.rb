# frozen_string_literal: true
#
# kv_client.rb -- Cloudflare Workers KV REST client for the publish
# pipeline (M2-1, ARCHITECTURE.md section 6 Phase 2).
#
#   Publish::KV.put('v1:index', json_string)   # -> true
#   Publish::KV.get('v1:index')                # -> raw stored value
#
# Config from ENV (names in .env.example; values live outside the
# repo): CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_KV_NAMESPACE_ID, CLOUDFLARE_API_TOKEN (bearer,
# scoped to the one namespace). All HTTP goes through BTC::Http, so
# tests inject a fake transport.
#
# Retry policy: 429 and 5xx and transport-level errors (timeouts, DNS,
# TLS) retry with doubling backoff (1s, 2s, 4s), 4 tries total; any
# other non-200 fails immediately (a 401/403 will not fix itself).
#
# SECURITY (the pattern downstream publish code copies): error messages
# carry HTTP status + attempt count ONLY -- never the token, never a
# request or response body, and the whole message still passes
# BTC::Env.redact as defense in depth. This module never prints.

require_relative '../lib/btc/http'
require_relative '../lib/btc/env'

module Publish
  module KV
    class Error < StandardError; end

    BASE      = 'https://api.cloudflare.com/client/v4'
    TRIES     = 4
    RETRYABLE = [429, 500, 502, 503, 504].freeze

    module_function

    def put(key, value, env: ENV, sleeper: ->(s) { sleep s })
      request(key, env, sleeper, 'PUT') do |url, headers|
        BTC::Http.put(url, value, headers)
      end
      true
    end

    def get(key, env: ENV, sleeper: ->(s) { sleep s })
      request(key, env, sleeper, 'GET') do |url, headers|
        BTC::Http.get(url, headers, read_timeout: 60)
      end
    end

    # -> { account:, namespace:, token: }; Error naming (only) the
    # missing variable.
    def config(env)
      vars = { account: 'CLOUDFLARE_ACCOUNT_ID', namespace: 'CLOUDFLARE_KV_NAMESPACE_ID',
               token: 'CLOUDFLARE_API_TOKEN' }
      vars.transform_values do |name|
        v = env[name].to_s
        raise Error, "#{name} not set" if v.empty?

        v
      end
    end

    def value_url(cfg, key)
      format('%s/accounts/%s/storage/kv/namespaces/%s/values/%s',
             BASE, cfg[:account], cfg[:namespace],
             URI.encode_www_form_component(key))
    end

    # Shared fetch loop. The block performs one attempt; retryable
    # failures back off and retry, everything else raises immediately.
    # Raised messages carry status/class + attempt count, NEVER bodies.
    def request(key, env, sleeper, verb)
      cfg     = config(env)
      url     = value_url(cfg, key)
      headers = { 'Authorization' => "Bearer #{cfg[:token]}" }
      failure = nil

      TRIES.times do |attempt|
        begin
          return yield(url, headers)
        rescue BTC::Http::StatusError => e
          failure = "HTTP #{e.code}"
          unless RETRYABLE.include?(e.code)
            raise Error, BTC::Env.redact("KV #{verb} #{key}: #{failure}")
          end
        rescue StandardError => e
          failure = e.class.name
        end
        sleeper.call(2**attempt) if attempt < TRIES - 1
      end
      raise Error, BTC::Env.redact("KV #{verb} #{key}: #{failure} after #{TRIES} tries")
    end
  end
end
