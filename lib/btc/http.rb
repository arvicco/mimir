# frozen_string_literal: true
#
# http.rb -- the single HTTP seam (ARCHITECTURE.md section 3). All
# runtime HTTP under scripts/ goes through BTC::Http; tests inject a
# fake transport (BTC::Http.transport=), so nothing under test/ can
# reach the network. Extracted from six per-script variants
# (TOOL-REVIEW.md F-13); per-caller User-Agents and timeouts are passed
# in by the callers, preserving their historical behavior.
#
# Non-200 raises StatusError whose message is exactly "HTTP <code>"
# (the historical text of the suite helpers, so fail-soft headlines are
# unchanged); the response code and body are carried as attributes for
# callers that want detail (ingest.rb). Other exceptions (timeouts, DNS,
# TLS) pass through untouched -- output redaction lives in BTC::Report.

require 'net/http'
require 'json'

module BTC
  module Http
    class StatusError < StandardError
      attr_reader :code, :body

      def initialize(code, body)
        @code = code
        @body = body
        super("HTTP #{code}")
      end
    end

    @transport = nil

    class << self
      # Injectable transport: a callable (uri, request, opts) -> response
      # responding to #code and #body. nil restores the real one.
      attr_writer :transport

      def transport
        @transport || method(:real_transport)
      end
    end

    module_function

    def real_transport(uri, req, opts)
      Net::HTTP.start(uri.host, uri.port,
                      use_ssl: uri.scheme == 'https',
                      open_timeout: opts[:open_timeout],
                      read_timeout: opts[:read_timeout]) { |h| h.request(req) }
    end

    def get(url, headers = {}, open_timeout: 5, read_timeout: 20)
      uri = URI(url)
      req = Net::HTTP::Get.new(uri.request_uri, headers)
      run(uri, req, open_timeout: open_timeout, read_timeout: read_timeout)
    end

    def get_json(url, headers = {}, open_timeout: 5, read_timeout: 20)
      JSON.parse(get(url, headers,
                     open_timeout: open_timeout, read_timeout: read_timeout))
    end

    def post(url, body, headers = {}, open_timeout: 5, read_timeout: 120)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri.request_uri, headers)
      req.body = body
      run(uri, req, open_timeout: open_timeout, read_timeout: read_timeout)
    end

    def run(uri, req, opts)
      res = Http.transport.call(uri, req, opts)
      raise StatusError.new(res.code.to_i, res.body) unless res.code.to_i == 200

      res.body
    end
  end
end
