# frozen_string_literal: true
#
# fixtures.rb -- recorder behind `rake fixtures:record` (M1-6).
# Fetches one real response per registered shape through BTC::Http,
# trims it to the minimum the parsers need, and writes
# test/fixtures/<name> plus a regenerated provenance README (URLs
# redacted). RECORDING IS NETWORK and owner-run; this module is
# unit-tested against an injected fake transport, so `rake test`
# never touches the wire.
#
# Trimming is part of the frozen fixture shape: contract tests pin
# against these exact structures. Changing a trim is a contract change.

require 'json'
require 'fileutils'
require_relative 'http'
require_relative 'env'

module BTC
  module Fixtures
    CM  = 'https://community-api.coinmetrics.io/v4/timeseries/asset-metrics'
    UA  = -> { { 'User-Agent' => ENV['EDGAR_UA'] || 'mimir fixtures (set EDGAR_UA=name email)' } }

    # slim a CBOE option row to the fields the parsers read
    CBOE_FIELDS = %w[option iv gamma open_interest].freeze

    # shortest HTML prefix whose tag-stripped text has >= 12 daily rows
    FARSIDE_TRIM = lambda do |body|
      (5_000..body.size).step(5_000) do |i|
        txt = body[0, i].gsub(/<[^>]+>/, ' ')
        return body[0, i] if txt.scan(/\d{1,2}\s+[A-Z][a-z]{2}\s+\d{4}/).size >= 12
      end
      body
    end

    fred = lambda do |series, limit, keep|
      { file: "fred_#{series.downcase}.json", env: 'FRED_API_KEY',
        url: -> { "https://api.stlouisfed.org/fred/series/observations?series_id=#{series}&api_key=#{ENV['FRED_API_KEY']}&file_type=json&sort_order=desc&limit=#{limit}" },
        trim: ->(b) { j = JSON.parse(b); JSON.generate('observations' => j['observations'].to_a.first(keep)) } }
    end

    FIXTURES = [
      { file: 'deribit_index.json',
        url: 'https://www.deribit.com/api/v2/public/get_index_price?index_name=btc_usd',
        trim: ->(b) { JSON.generate('result' => JSON.parse(b)['result']) } },
      { file: 'deribit_book_summary.json',
        url: 'https://www.deribit.com/api/v2/public/get_book_summary_by_currency?currency=BTC&kind=option',
        trim: lambda { |b|
          rows = JSON.parse(b)['result']
          live = rows.select { |r| r['open_interest'].to_f > 0 }
          keep = live.select { |r| r['instrument_name'].end_with?('-C') }.first(4) +
                 live.select { |r| r['instrument_name'].end_with?('-P') }.first(4) +
                 rows.select { |r| r['open_interest'].to_f <= 0 }.first(2)
          JSON.generate('result' => keep)
        } },
      { file: 'deribit_futures.json',
        url: 'https://www.deribit.com/api/v2/public/get_book_summary_by_currency?currency=BTC&kind=future',
        trim: ->(b) { JSON.generate('result' => JSON.parse(b)['result'].first(4)) } },
      { file: 'cboe_options.json',
        url: 'https://cdn.cboe.com/api/global/delayed_quotes/options/IBIT.json',
        trim: lambda { |b|
          d = JSON.parse(b)['data']
          opts = d['options'].to_a
          live = opts.select { |o| o['open_interest'].to_f > 0 }
          keep = (live.select { |o| o['option'].to_s =~ /C\d{8}\z/ }.first(4) +
                  live.select { |o| o['option'].to_s =~ /P\d{8}\z/ }.first(4) +
                  opts.select { |o| o['open_interest'].to_f <= 0 }.first(2))
                 .map { |o| o.select { |k, _| CBOE_FIELDS.include?(k) } }
          JSON.generate('data' => { 'current_price' => d['current_price'],
                                    'close' => d['close'], 'options' => keep })
        } },
      { file: 'coinmetrics_prices.json',
        url: -> { CM + '?assets=btc&metrics=PriceUSD&frequency=1d&page_size=5&paging_from=start&start_time=' + (Time.now.utc - 6 * 86_400).strftime('%Y-%m-%d') },
        trim: ->(b) { JSON.generate('data' => JSON.parse(b)['data']) } },
      { file: 'coinmetrics_onchain.json',
        url: -> { CM + '?assets=btc&metrics=CapMVRVCur,PriceUSD&frequency=1d&page_size=5&start_time=' + (Time.now.utc - 6 * 86_400).strftime('%Y-%m-%d') },
        trim: ->(b) { JSON.generate('data' => JSON.parse(b)['data']) } },
      { file: 'binance_funding.json',
        url: 'https://fapi.binance.com/fapi/v1/fundingRate?symbol=BTCUSDT&limit=21' },
      { file: 'binance_premium.json',
        url: 'https://fapi.binance.com/fapi/v1/premiumIndex?symbol=BTCUSDT' },
      { file: 'coinbase_ticker.json',
        url: 'https://api.exchange.coinbase.com/products/BTC-USD/ticker' },
      { file: 'mempool_hashrate.json',
        url: 'https://mempool.space/api/v1/mining/hashrate/6m',
        trim: lambda { |b|
          j = JSON.parse(b)
          JSON.generate('hashrates' => j['hashrates'].to_a.last(80),
                        'difficulty' => j['difficulty'].to_a.last(3))
        } },
      { file: 'defillama_stables.json',
        url: 'https://stablecoins.llama.fi/stablecoins?includePrices=false',
        trim: lambda { |b|
          keep = JSON.parse(b)['peggedAssets'].to_a
                     .select { |a| %w[USDT USDC].include?(a['symbol']) }
                     .map { |a| a.select { |k, _| %w[symbol circulating circulatingPrevWeek circulatingPrevMonth].include?(k) } }
          JSON.generate('peggedAssets' => keep)
        } },
      { file: 'farside_flows.html',
        url: 'https://farside.co.uk/btc/', trim: FARSIDE_TRIM },
      { file: 'frankfurter_fx.json',
        url: 'https://api.frankfurter.dev/v1/latest?base=USD&symbols=JPY' },
      fred.call('WALCL', 6, 6),
      fred.call('WTREGEN', 6, 6),
      fred.call('RRPONTSYD', 25, 25),
      fred.call('DFII10', 25, 25),
      { file: 'edgar_submissions.json',
        url: 'https://data.sec.gov/submissions/CIK0001050446.json', headers: UA,
        trim: lambda { |b|
          j = JSON.parse(b)
          r = j['filings']['recent']
          slim = Hash[r.map { |k, v| [k, v.is_a?(Array) ? v.first(15) : v] }]
          JSON.generate('cik' => j['cik'], 'name' => j['name'],
                        'filings' => { 'recent' => slim })
        } },
      { file: 'edgar_filing.html', headers: UA,
        # dependent fetch: newest 8-K primary doc from the submissions index
        fetch: lambda {
          sub = JSON.parse(Http.get('https://data.sec.gov/submissions/CIK0001050446.json', UA.call, read_timeout: 30))
          r = sub['filings']['recent']
          i = r['form'].index('8-K') or raise 'no 8-K in recent filings'
          acc = r['accessionNumber'][i].delete('-')
          url = "https://www.sec.gov/Archives/edgar/data/#{sub['cik'].to_i}/#{acc}/#{r['primaryDocument'][i]}"
          [Http.get(url, UA.call, read_timeout: 30), url]
        },
        trim: ->(b) { b[0, 60_000] } }
    ].freeze

    module_function

    # Record every fixture into dir. Returns [[file, :ok|:skip|:fail, note]].
    # All HTTP goes through BTC::Http, so tests inject a fake transport.
    def record_all(dir)
      FileUtils.mkdir_p(dir)
      results = FIXTURES.map do |f|
        if f[:env] && ENV[f[:env]].to_s.empty?
          [f[:file], :skip, "#{f[:env]} not set"]
        else
          begin
            body, url = fetch(f)
            body = f[:trim].call(body) if f[:trim]
            File.write(File.join(dir, f[:file]), body)
            [f[:file], :ok, BTC::Env.redact(url)]
          rescue StandardError => e
            [f[:file], :fail, BTC::Env.redact("#{e.class}: #{e.message[0, 120]}")]
          end
        end
      end
      write_readme(dir, results)
      results
    end

    def fetch(f)
      return f[:fetch].call if f[:fetch]

      url     = f[:url].respond_to?(:call) ? f[:url].call : f[:url]
      headers = f[:headers] ? f[:headers].call : {}
      [Http.get(url, headers, read_timeout: 30), url]
    end

    def write_readme(dir, results)
      lines = ["# test/fixtures -- recorded API responses\n",
               "Real responses trimmed to the minimum the parsers need",
               "(the trim IS part of the frozen fixture shape). Regenerate",
               "with `rake fixtures:record` (network, owner-run), then",
               "review the diff before committing.\n",
               "Recorded #{Time.now.utc.strftime('%Y-%m-%d %H:%M UTC')}:\n"]
      results.each do |file, status, note|
        lines << format('- `%s` -- %s%s', file, status.to_s.upcase,
                        note.to_s.empty? ? '' : " (#{note})")
      end
      File.write(File.join(dir, 'README.md'), lines.join("\n") + "\n")
    end
  end
end
