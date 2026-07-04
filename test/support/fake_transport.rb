# frozen_string_literal: true
#
# fake_transport.rb -- preload shim for CONTRACT tests. The real scripts
# run as subprocesses with BTC::Http's transport replaced by a
# fixture-backed fake:
#
#   ruby -I test/support -r fake_transport scripts/gex.rb --json
#
# (contract tests set this via RUBYOPT so it also reaches the
# aggregators' own child processes). Environment knobs:
#
#   FAKE_HTTP_DIR   fixture directory (default test/fixtures)
#   FAKE_HTTP_DENY  comma-separated URL fragments answered with HTTP 500
#   FAKE_NOW        ISO8601 -- freezes Time.now; fixtures carry real
#                   expiries/dates, so tests pin "now" to recording day
#
# Unknown URLs answer 404: a contract test can never reach the wire.

require_relative '../../lib/btc/http'

module FakeTransport
  DIR = ENV['FAKE_HTTP_DIR'] || File.expand_path('../fixtures', __dir__)

  # URL fragment -> fixture file, mirroring lib/btc/fixtures.rb FIXTURES
  # (FRED is matched dynamically on series_id below).
  MAP = [
    ['get_index_price',             'deribit_index.json'],
    ['kind=option',                 'deribit_book_summary.json'],
    ['kind=future',                 'deribit_futures.json'],
    ['delayed_quotes/options/IBIT', 'cboe_options.json'],
    ['metrics=CapMVRVCur',          'coinmetrics_onchain.json'],
    ['metrics=PriceUSD',            'coinmetrics_prices.json'],
    ['fundingRate',                 'binance_funding.json'],
    ['premiumIndex',                'binance_premium.json'],
    ['ticker/price',                'binance_spot.json'],
    ['BTC-USD/ticker',              'coinbase_ticker.json'],
    ['hashrate',                    'mempool_hashrate.json'],
    ['stablecoins',                 'defillama_stables.json'],
    ['farside',                     'farside_flows.html'], # also matches the archive-proxy URL
    ['flow-history',                'coinglass_flows.json'],
    ['frankfurter',                 'frankfurter_fx.json'],
    ['submissions/CIK',             'edgar_submissions.json'],
    ['Archives/edgar',              'edgar_filing.html']
  ].freeze

  Res = Struct.new(:code, :body)

  def self.respond(url)
    deny = ENV['FAKE_HTTP_DENY'].to_s.split(',').reject(&:empty?)
    return Res.new('500', 'denied by test') if deny.any? { |f| url.include?(f) }

    file = if (m = url.match(/series_id=(\w+)/))
             "fred_#{m[1].downcase}.json"
           else
             MAP.find { |frag, _| url.include?(frag) }&.last
           end
    path = file && File.join(DIR, file)
    return Res.new('404', "no fixture for #{url}") unless path && File.exist?(path)

    Res.new('200', File.read(path))
  end

  if ENV['FAKE_NOW']
    require 'time'
    FROZEN = Time.parse(ENV['FAKE_NOW']).utc

    class << Time
      def now
        FakeTransport::FROZEN
      end
    end
  end
end

BTC::Http.transport = ->(uri, _req, _opts) { FakeTransport.respond(uri.to_s) }
