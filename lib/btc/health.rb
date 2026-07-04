# frozen_string_literal: true
#
# health.rb -- scripts health-check framework (TOOL-REVIEW.md F-18+).
#
#   rake health          offline: conventions/interface scan + registry
#                        integrity (part of the pre-commit gate)
#   rake health:sources  NETWORK: probe every registered upstream data
#                        source and validate its response shape, so
#                        upstream degradation (key-gating, dead or moved
#                        endpoints -- the F-16/F-17 class) is caught
#                        deliberately, not mid-analysis
#
# Registry discipline: every entry names the file that owns the source
# (src) and a marker string that must literally appear there --
# `rake health` fails if the registry drifts from the code.

require 'json'
require_relative 'http'
require_relative 'flows'

module BTC
  module Health
    # Raw ENV access allowed outside lib/btc/env.rb, per file.
    ALLOWED_ENV = {
      'scripts/btco/btco.rb'          => %w[EDGAR_UA],
      'scripts/btco/ingest.rb'        => %w[EDGAR_UA ANTHROPIC_API_KEY BTCO_MODEL],
      'scripts/scenario/macro.rb'     => %w[FRED_API_KEY],
      'scripts/scenario/etf_flows.rb' => %w[COINGLASS_API_KEY],
      'scripts/scenario/scenario.rb'  => %w[HOME]
    }.freeze

    CM = 'https://community-api.coinmetrics.io/v4/timeseries/asset-metrics'

    SOURCES = [
      { name: 'deribit index', src: 'lib/btc/deribit.rb',
        marker: 'www.deribit.com/api/v2/public',
        url: 'https://www.deribit.com/api/v2/public/get_index_price?index_name=btc_usd',
        check: ->(b) { JSON.parse(b).fetch('result').fetch('index_price').to_f > 0 } },
      { name: 'deribit books', src: 'lib/btc/deribit.rb',
        marker: 'get_book_summary_by_currency',
        url: 'https://www.deribit.com/api/v2/public/get_book_summary_by_currency?currency=BTC&kind=option',
        check: ->(b) { r = JSON.parse(b).fetch('result'); r.is_a?(Array) && r.first.key?('instrument_name') } },
      { name: 'cboe options', src: 'scripts/gex_us.rb',
        marker: 'cdn.cboe.com/api/global/delayed_quotes/options',
        url: 'https://cdn.cboe.com/api/global/delayed_quotes/options/IBIT.json',
        check: ->(b) { d = JSON.parse(b).fetch('data'); (d['current_price'] || d['close']).to_f > 0 && d['options'].is_a?(Array) && !d['options'].empty? } },
      { name: 'coinmetrics prices', src: 'scripts/lppl/prices.rb',
        marker: 'metrics=PriceUSD',
        url: -> { CM + '?assets=btc&metrics=PriceUSD&frequency=1d&page_size=5&start_time=' + (Time.now.utc - 10 * 86_400).strftime('%Y-%m-%d') },
        check: ->(b) { d = JSON.parse(b).fetch('data'); !d.empty? && d.last['PriceUSD'].to_f > 0 } },
      { name: 'coinmetrics onchain', src: 'scripts/scenario/onchain_value.rb',
        marker: 'CapMVRVCur',
        url: -> { CM + '?assets=btc&metrics=CapMVRVCur,PriceUSD&frequency=1d&page_size=5&start_time=' + (Time.now.utc - 10 * 86_400).strftime('%Y-%m-%d') },
        check: ->(b) { d = JSON.parse(b).fetch('data'); !d.empty? && d.last['CapMVRVCur'].to_f > 0 } },
      { name: 'binance funding', src: 'scripts/scenario/funding_basis.rb',
        marker: 'fapi.binance.com/fapi/v1/fundingRate',
        url: 'https://fapi.binance.com/fapi/v1/fundingRate?symbol=BTCUSDT&limit=3',
        check: ->(b) { r = JSON.parse(b); r.is_a?(Array) && r.first.key?('fundingRate') } },
      { name: 'binance premium', src: 'scripts/scenario/funding_basis.rb',
        marker: 'fapi/v1/premiumIndex',
        url: 'https://fapi.binance.com/fapi/v1/premiumIndex?symbol=BTCUSDT',
        check: ->(b) { JSON.parse(b).key?('lastFundingRate') } },
      { name: 'coinbase ticker', src: 'scripts/scenario/cb_premium.rb',
        marker: 'api.exchange.coinbase.com/products/BTC-USD/ticker',
        url: 'https://api.exchange.coinbase.com/products/BTC-USD/ticker',
        check: ->(b) { JSON.parse(b)['price'].to_f > 0 } },
      { name: 'mempool hashrate', src: 'scripts/scenario/hash_ribbons.rb',
        marker: 'mempool.space/api/v1/mining/hashrate',
        url: 'https://mempool.space/api/v1/mining/hashrate/6m',
        check: ->(b) { JSON.parse(b)['hashrates'].to_a.size >= 75 } },
      { name: 'defillama stables', src: 'scripts/scenario/stables.rb',
        marker: 'stablecoins.llama.fi/stablecoins',
        url: 'https://stablecoins.llama.fi/stablecoins?includePrices=false',
        check: ->(b) { JSON.parse(b)['peggedAssets'].to_a.any? { |a| a['symbol'] == 'USDT' } } },
      # soft: farside direct is intermittently Cloudflare-challenged
      # (F-23); the module falls back, so degradation here WARNs
      # instead of failing the probe run.
      { name: 'farside etf flows', src: 'scripts/scenario/etf_flows.rb',
        marker: 'farside.co.uk/btc', soft: true,
        url: 'https://farside.co.uk/btc/',
        check: ->(b) { Flows.parse_flows(b).size >= 10 } },
      { name: 'farside archive', src: 'scripts/scenario/etf_flows.rb',
        marker: 'web.archive.org/web/2id_', follow: true,
        url: 'https://web.archive.org/web/2id_/https://farside.co.uk/btc/',
        check: ->(b) { Flows.parse_flows(b).size >= 10 } },
      { name: 'coinglass etf flows', src: 'scripts/scenario/etf_flows.rb',
        marker: 'open-api-v4.coinglass.com', env: 'COINGLASS_API_KEY',
        url: 'https://open-api-v4.coinglass.com/api/etf/bitcoin/flow-history',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        check: ->(b) { j = JSON.parse(b); j['code'].to_s == '0' && !j['data'].to_a.empty? } },
      { name: 'frankfurter fx', src: 'scripts/btco/btco.rb',
        marker: 'api.frankfurter.dev/v1/latest',
        url: 'https://api.frankfurter.dev/v1/latest?base=USD&symbols=JPY',
        check: ->(b) { JSON.parse(b).fetch('rates').fetch('JPY').to_f > 0 } },
      { name: 'fred series', src: 'scripts/scenario/macro.rb',
        marker: 'api.stlouisfed.org/fred/series/observations', env: 'FRED_API_KEY',
        url: -> { "https://api.stlouisfed.org/fred/series/observations?series_id=WALCL&api_key=#{ENV['FRED_API_KEY']}&file_type=json&sort_order=desc&limit=2" },
        check: ->(b) { !JSON.parse(b)['observations'].to_a.empty? } },
      { name: 'edgar submissions', src: 'scripts/btco/ingest.rb',
        marker: 'data.sec.gov/submissions/CIK',
        url: 'https://data.sec.gov/submissions/CIK0001050446.json',
        headers: -> { { 'User-Agent' => ENV['EDGAR_UA'] || 'mimir health (set EDGAR_UA=name email)' } },
        check: ->(b) { JSON.parse(b).fetch('filings').fetch('recent').fetch('form').is_a?(Array) } },
      { name: 'cloudflare kv', src: 'publish/kv_client.rb',
        marker: 'api.cloudflare.com/client/v4', env: 'CF_API_TOKEN',
        url: -> { "https://api.cloudflare.com/client/v4/accounts/#{ENV['CF_ACCOUNT_ID']}/storage/kv/namespaces/#{ENV['CF_KV_NAMESPACE_ID']}/keys?limit=5" },
        headers: -> { { 'Authorization' => "Bearer #{ENV['CF_API_TOKEN']}" } },
        check: ->(b) { JSON.parse(b)['success'] == true } }
    ].freeze

    module_function

    # ---- offline: conventions scan -------------------------------------

    # files: { relative_path => content }. All five checks (scripts/).
    def scan_conventions(files)
      bad = scan_frozen(files)
      files.each do |path, content|
        content.lines.each_with_index do |line, i|
          next if line.strip.start_with?('#')

          loc = "#{path}:#{i + 1}"
          bad << "#{loc}: HTTP outside the seam (use BTC::Http)" if
            line =~ /\bNet::HTTP\b|\bURI\(/
          bad << "#{loc}: brace-less trailing hash at a keyword-taking call (F-18)" if
            line =~ /\bHttp\.(?:get|post|get_json)\([^){}\n]*=>/
          bad << "#{loc}: raw /tmp write (use BTC::Report.status)" if
            line =~ %r{File\.write\(['"]/tmp}
          line.scan(/ENV\[['"]([A-Za-z_]+)['"]\]/).flatten.each do |var|
            bad << "#{loc}: ENV['#{var}'] not in Health::ALLOWED_ENV" unless
              (ALLOWED_ENV[path] || []).include?(var)
          end
        end
      end
      bad
    end

    # frozen_string_literal pragma within the first three lines.
    def scan_frozen(files)
      files.reject { |_, c| c.lines.first(3).any? { |l| l.include?('frozen_string_literal: true') } }
           .map { |path, _| "#{path}: missing frozen_string_literal" }
    end

    # Every registry entry's marker must appear in its src file.
    def registry_integrity(root)
      SOURCES.map do |s|
        path = File.join(root, s[:src])
        next "health registry: #{s[:name]} -- src missing (#{s[:src]})" unless File.exist?(path)
        next "health registry: #{s[:name]} -- marker not found in #{s[:src]}" unless
          File.read(path).include?(s[:marker])
      end.compact
    end

    # ---- live: source probes (NETWORK) ---------------------------------

    # -> [:ok] | [:skip, reason] | [:fail, message] | [:warn, message]
    # (:warn = a soft-registered source degraded -- a fallback covers it)
    def probe(entry)
      return [:skip, "#{entry[:env]} not set"] if entry[:env] && ENV[entry[:env]].to_s.empty?

      url     = entry[:url].respond_to?(:call) ? entry[:url].call : entry[:url]
      headers = entry[:headers] ? entry[:headers].call : {}
      body    = if entry[:follow]
                  Http.get_follow(url, headers, read_timeout: 30)
                else
                  Http.get(url, headers, read_timeout: 30)
                end
      entry[:check].call(body) ? [:ok] : [entry[:soft] ? :warn : :fail, 'response shape check failed']
    rescue StandardError => e
      [entry[:soft] ? :warn : :fail, "#{e.class}: #{e.message[0, 120]}"]
    end
  end
end
