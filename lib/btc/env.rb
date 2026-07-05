# frozen_string_literal: true
#
# env.rb -- ENV access and data-dir resolution (ARCHITECTURE.md section 3).
# One rule for every suite: runtime artifacts live in
# $BTC_DATA_DIR/<suite>/ when BTC_DATA_DIR is set, else in the suite's
# in-tree data/ dir (the historical default). Status lines stay in /tmp
# (ephemeral, tmux-facing) and btco's capstruct/ is a committed audit
# trail, not runtime data -- both deliberate exceptions.

module BTC
  module Env
    # ENV names whose values must never appear in output or error text.
    # CLOUDFLARE_API_TOKEN is the canonical name (one-token ruling, Gate
    # 4); the legacy CF_API_TOKEN stays listed purely so a stale env
    # file's value is still redacted.
    SECRET_ENV = %w[FRED_API_KEY CLOUDFLARE_API_TOKEN CF_API_TOKEN
                    ANTHROPIC_API_KEY COINGLASS_API_KEY].freeze

    module_function

    def data_dir(suite, default)
      base = ENV['BTC_DATA_DIR']
      base && !base.empty? ? File.join(base, suite) : default
    end

    # Scrub secrets from a string bound for output: credential-looking
    # query params by pattern, plus the literal values of SECRET_ENV
    # (some APIs, e.g. FRED, only accept keys as query params, so URLs
    # in exception messages are a leak vector -- TOOL-REVIEW.md F-6).
    def redact(str)
      s = str.to_s.gsub(/((?:api_?key|token|secret|password)=)[^&\s"']+/i,
                        '\1[REDACTED]')
      SECRET_ENV.each do |k|
        v = ENV[k]
        s = s.gsub(v, "[#{k}]") if v && !v.empty?
      end
      s
    end
  end
end
