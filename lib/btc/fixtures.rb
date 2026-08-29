# frozen_string_literal: true
#
# fixtures.rb -- recorder behind `rake fixtures:record` (M1-6) and the
# offline verifier behind `rake fixtures:verify` (M1-16).
# Fetches one real response per registered shape through BTC::Http,
# trims it to the minimum the parsers need, and writes
# test/fixtures/<name> plus a regenerated provenance README (URLs
# redacted). RECORDING IS NETWORK and owner-run; this module is
# unit-tested against an injected fake transport, so `rake test`
# never touches the wire.
#
# Trimming is part of the frozen fixture shape: contract tests pin
# against these exact structures. Changing a trim is a contract change.
#
# Option-board rows are selected PARSER-live (unexpired at record time,
# nonzero greeks), far-dated first so fixtures age slowly -- CBOE lists
# expired weeklies first, and a board of parser-dead rows is useless to
# the contract tests (F-20).
#
# verify(dir) (M1-16) replaces eyeballing fixture diffs: every entry
# carries a `stat:` lambda that digests the raw file to a human note
# with the load-bearing numbers (raising on the wrong shape), and
# verify layers on generic safety checks -- README<->disk drift and a
# leak scan for credential material. It is pure-offline (no BTC::Http),
# reuses BTC::Flows / BTC::Options rather than reparsing, and fails on
# any :fail row. Board entries also carry an `aging:` lambda returning
# the nearest parser-live expiry Time so verify can WARN (never fail)
# when a board is about to age out.

require 'json'
require 'fileutils'
require_relative 'http'
require_relative 'env'
require_relative 'options'
require_relative 'flows'

module BTC
  module Fixtures
    CM  = 'https://community-api.coinmetrics.io/v4/timeseries/asset-metrics'
    UA  = -> { { 'User-Agent' => ENV['EDGAR_UA'] || 'mimir fixtures (set EDGAR_UA=name email)' } }

    # slim a CBOE option row to the fields the parsers read
    CBOE_FIELDS = %w[option iv gamma open_interest].freeze

    # F-20: 4 calls + 4 puts the parsers would actually keep, farthest
    # expiry first, plus 2 parser-dead rows for skip-branch coverage.
    def self.pick_rows(rows, live:, expiry:, call:)
      alive = rows.select { |r| live.call(r) }
                  .sort_by { |r| expiry.call(r) }.reverse
      raise 'no parser-live option rows to record' if alive.empty?

      alive.select { |r| call.call(r) }.first(4) +
        alive.reject { |r| call.call(r) }.first(4) +
        (rows - alive).first(2)
    end

    # shortest HTML prefix that PARSES (BTC::Flows, the F-22 per-row
    # parser) to >= 12 daily rows (the module fail-softs below 10); an
    # insufficient page fails the recording loudly.
    FARSIDE_TRIM = lambda do |body|
      (5_000..body.size).step(5_000) do |i|
        return body[0, i] if Flows.parse_flows(body[0, i]).size >= 12
      end
      raise 'fewer than 12 parseable farside rows on the whole page'
    end

    # M10-2 P-6 crowd-positioning family: one recorded fixture per probed
    # BTC::Coinglass wrapper. Envelope {code, data}; trim keeps code + the
    # last `keep` daily rows verbatim (all fields preserved -- the M10-3
    # caller's field list is not frozen yet, so we do not slim columns).
    # `check` asserts the load-bearing row shape M10-3 will consume.
    cg = lambda do |file, path, params, keep, row_field, label|
      { file: file, env: 'COINGLASS_API_KEY',
        url: "https://open-api-v4.coinglass.com/api/#{path}?#{params}",
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        trim: lambda { |b|
          j = JSON.parse(b)
          JSON.generate('code' => j['code'], 'data' => j['data'].to_a.last(keep))
        },
        stat: lambda { |b|
          data = JSON.parse(b)['data'].to_a
          raise "only #{data.size} rows (need >= 5)" if data.size < 5
          raise "row missing time field" unless data.last.key?('time')
          raise "row missing #{row_field}" unless data.last.key?(row_field)

          span = [data.first['time'].to_i, data.last['time'].to_i].map do |ms|
            Time.at(ms / 1000).utc.strftime('%d %b %Y')
          end
          format('%s: %d rows, %s..%s', label, data.size, span[0], span[1])
        } }
    end

    fred = lambda do |series, limit, keep|
      { file: "fred_#{series.downcase}.json", env: 'FRED_API_KEY',
        url: -> { "https://api.stlouisfed.org/fred/series/observations?series_id=#{series}&api_key=#{ENV['FRED_API_KEY']}&file_type=json&sort_order=desc&limit=#{limit}" },
        trim: ->(b) { j = JSON.parse(b); JSON.generate('observations' => j['observations'].to_a.first(keep)) },
        stat: lambda { |b|
          obs = JSON.parse(b)['observations'].to_a
          raise "only #{obs.size} observations" if obs.size < 5

          format('%d observations', obs.size)
        } }
    end

    FIXTURES = [
      { file: 'deribit_index.json',
        url: 'https://www.deribit.com/api/v2/public/get_index_price?index_name=btc_usd',
        trim: ->(b) { JSON.generate('result' => JSON.parse(b)['result']) },
        stat: lambda { |b|
          spot = JSON.parse(b)['result']['index_price'].to_f
          raise 'index_price not positive' unless spot.positive?

          format('spot %.2f', spot)
        } },
      { file: 'deribit_book_summary.json',
        url: 'https://www.deribit.com/api/v2/public/get_book_summary_by_currency?currency=BTC&kind=option',
        trim: lambda { |b|
          now = Time.now.utc
          exp = ->(r) { Options.deribit_expiry(r['instrument_name'].split('-')[1]) }
          keep = pick_rows(
            JSON.parse(b)['result'],
            live:   ->(r) { r['open_interest'].to_f > 0 && r['mark_iv'].to_f > 0 && (e = exp.call(r)) && e > now },
            expiry: exp,
            call:   ->(r) { r['instrument_name'].end_with?('-C') }
          )
          JSON.generate('result' => keep)
        },
        stat: lambda { |b|
          rows = JSON.parse(b)['result'].to_a
          live = deribit_live_expiries(b)
          raise "only #{live.size} parser-live rows (need >= 8)" if live.size < 8

          format('%d rows, %d live, %s..%s', rows.size, live.size,
                 live.first[1], live.last[1])
        },
        aging: ->(b) { (e = deribit_live_expiries(b).first) && e[0] } },
      { file: 'deribit_futures.json',
        url: 'https://www.deribit.com/api/v2/public/get_book_summary_by_currency?currency=BTC&kind=future',
        trim: ->(b) { JSON.generate('result' => JSON.parse(b)['result'].first(4)) },
        stat: lambda { |b|
          rows = JSON.parse(b)['result'].to_a
          raise 'no futures rows' if rows.empty?

          format('%d futures', rows.size)
        } },
      { file: 'cboe_options.json',
        url: 'https://cdn.cboe.com/api/global/delayed_quotes/options/IBIT.json',
        trim: lambda { |b|
          now = Time.now.utc
          d = JSON.parse(b)['data']
          osi = ->(o) { Options.parse_osi(o['option']) }
          keep = pick_rows(
            d['options'].to_a,
            live:   ->(o) { o['open_interest'].to_f > 0 && (o['iv'].to_f > 0 || o['gamma'].to_f > 0) && (p = osi.call(o)) && p[0] > now },
            expiry: ->(o) { osi.call(o)[0] },
            call:   ->(o) { osi.call(o)[1] == 'C' }
          ).map { |o| o.select { |k, _| CBOE_FIELDS.include?(k) } }
          JSON.generate('data' => { 'current_price' => d['current_price'],
                                    'close' => d['close'], 'options' => keep })
        },
        stat: lambda { |b|
          d = JSON.parse(b)['data']
          rows = d['options'].to_a
          live = cboe_live_expiries(b)
          raise "only #{live.size} parser-live rows (need >= 8)" if live.size < 8
          spot = d['current_price'].to_f

          format('%d rows, %d live, %s..%s, spot %.2f', rows.size, live.size,
                 live.first[1], live.last[1], spot)
        },
        aging: ->(b) { (e = cboe_live_expiries(b).first) && e[0] } },
      { file: 'coinmetrics_prices.json',
        url: -> { CM + '?assets=btc&metrics=PriceUSD&frequency=1d&page_size=5&paging_from=start&start_time=' + (Time.now.utc - 6 * 86_400).strftime('%Y-%m-%d') },
        trim: ->(b) { JSON.generate('data' => JSON.parse(b)['data']) },
        stat: lambda { |b|
          data = JSON.parse(b)['data'].to_a
          price = data.last['PriceUSD'].to_f
          raise 'PriceUSD not positive' unless price.positive?

          format('%d rows, PriceUSD %.2f', data.size, price)
        } },
      { file: 'coinmetrics_onchain.json',
        url: -> { CM + '?assets=btc&metrics=CapMVRVCur,PriceUSD&frequency=1d&page_size=5&start_time=' + (Time.now.utc - 6 * 86_400).strftime('%Y-%m-%d') },
        trim: ->(b) { JSON.generate('data' => JSON.parse(b)['data']) },
        stat: lambda { |b|
          data = JSON.parse(b)['data'].to_a
          price = data.last['PriceUSD'].to_f
          mvrv = data.last['CapMVRVCur'].to_f
          raise 'PriceUSD/MVRV not positive' unless price.positive? && mvrv.positive?

          format('%d rows, PriceUSD %.2f, MVRV %.3f', data.size, price, mvrv)
        } },
      { file: 'binance_funding.json',
        url: 'https://fapi.binance.com/fapi/v1/fundingRate?symbol=BTCUSDT&limit=21',
        stat: lambda { |b|
          rows = JSON.parse(b).to_a
          raise "only #{rows.size} rows (need >= 10)" if rows.size < 10

          format('%d rows', rows.size)
        } },
      { file: 'binance_premium.json',
        url: 'https://fapi.binance.com/fapi/v1/premiumIndex?symbol=BTCUSDT',
        stat: lambda { |b|
          rate = JSON.parse(b)['lastFundingRate']
          raise 'no lastFundingRate' if rate.nil? || rate.to_s.empty?

          format('lastFundingRate %s', rate)
        } },
      { file: 'binance_spot.json', # F-21: cb_premium's spot leg was missing
        url: 'https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT',
        stat: lambda { |b|
          spot = JSON.parse(b)['price'].to_f
          raise 'price not positive' unless spot.positive?

          format('spot %.2f', spot)
        } },
      { file: 'coinbase_ticker.json',
        url: 'https://api.exchange.coinbase.com/products/BTC-USD/ticker',
        stat: lambda { |b|
          price = JSON.parse(b)['price'].to_f
          raise 'price not positive' unless price.positive?

          format('price %.2f', price)
        } },
      { file: 'mempool_hashrate.json',
        url: 'https://mempool.space/api/v1/mining/hashrate/6m',
        trim: lambda { |b|
          j = JSON.parse(b)
          JSON.generate('hashrates' => j['hashrates'].to_a.last(80),
                        'difficulty' => j['difficulty'].to_a.last(3))
        },
        stat: lambda { |b|
          j = JSON.parse(b)
          hr = j['hashrates'].to_a.size
          df = j['difficulty'].to_a.size
          raise "only #{hr} hashrates (need >= 75)" if hr < 75

          format('%d hashrates, %d difficulty', hr, df)
        } },
      { file: 'defillama_stables.json',
        url: 'https://stablecoins.llama.fi/stablecoins?includePrices=false',
        trim: lambda { |b|
          keep = JSON.parse(b)['peggedAssets'].to_a
                     .select { |a| %w[USDT USDC].include?(a['symbol']) }
                     .map { |a| a.select { |k, _| %w[symbol circulating circulatingPrevWeek circulatingPrevMonth].include?(k) } }
          JSON.generate('peggedAssets' => keep)
        },
        stat: lambda { |b|
          syms = JSON.parse(b)['peggedAssets'].to_a.map { |a| a['symbol'] }
          missing = %w[USDT USDC] - syms
          raise "missing symbols: #{missing.join(', ')}" unless missing.empty?

          format('%d assets: %s', syms.size, syms.join(', '))
        } },
      { file: 'farside_flows.html',
        # F-23 chain, mirroring etf_flows.rb: the direct page when it
        # parses (Cloudflare challenge pages don't), else the Internet
        # Archive's latest raw snapshot (redirects followed).
        fetch: lambda {
          direct = 'https://farside.co.uk/btc/'
          body = begin
            Http.get(direct, { 'User-Agent' => 'mimir fixtures' }, read_timeout: 30)
          rescue StandardError
            nil
          end
          return [body, direct] if body && Flows.parse_flows(body).size >= 12

          arch = 'https://web.archive.org/web/2id_/https://farside.co.uk/btc/'
          [Http.get_follow(arch, { 'User-Agent' => 'mimir fixtures' }, read_timeout: 60), arch]
        },
        trim: FARSIDE_TRIM,
        stat: lambda { |b|
          rows = Flows.parse_flows(b)
          raise "only #{rows.size} rows (need >= 10)" if rows.size < 10

          format('%d rows, %s..%s', rows.size,
                 rows.first[0].strftime('%d %b %Y'), rows.last[0].strftime('%d %b %Y'))
        } },
      { file: 'coinglass_flows.json', env: 'COINGLASS_API_KEY',
        url: 'https://open-api-v4.coinglass.com/api/etf/bitcoin/flow-history',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        trim: lambda { |b|
          j = JSON.parse(b)
          keep = j['data'].to_a.last(30)
                  .map { |r| r.select { |k, _| %w[timestamp flow_usd price_usd].include?(k) } }
          JSON.generate('code' => j['code'], 'msg' => j['msg'], 'data' => keep)
        },
        stat: lambda { |b|
          data = JSON.parse(b)['data'].to_a
          raise "only #{data.size} rows (need >= 10)" if data.size < 10

          last = Time.at(data.last['timestamp'].to_i / 1000).utc
          format('%d rows, last %s', data.size, last.strftime('%d %b %Y'))
        } },
      cg.call('coinglass_oi_aggregated.json', 'futures/open-interest/aggregated-history',
              'symbol=BTC&interval=1d', 10, 'close', 'OI'),
      cg.call('coinglass_global_ls_ratio.json', 'futures/global-long-short-account-ratio/history',
              'exchange=Binance&symbol=BTCUSDT&interval=1d', 10, 'global_account_long_short_ratio', 'global L/S'),
      cg.call('coinglass_top_position_ratio.json', 'futures/top-long-short-position-ratio/history',
              'exchange=Binance&symbol=BTCUSDT&interval=1d', 10, 'top_position_long_short_ratio', 'top pos'),
      cg.call('coinglass_taker_volume.json', 'futures/taker-buy-sell-volume/history',
              'exchange=Binance&symbol=BTCUSDT&interval=1d', 10, 'taker_buy_volume_usd', 'taker'),
      cg.call('coinglass_liquidation.json', 'futures/liquidation/aggregated-history',
              'symbol=BTC&interval=1d&exchange_list=Binance,OKX,Bybit', 10,
              'aggregated_long_liquidation_usd', 'liq'),
      # M11-7 (P-8): exchange reserves. The list is a small per-exchange
      # snapshot (kept whole); the chart is {time_list, price_list,
      # data_map} -- trimmed to the trailing 400 days per series (the
      # 365d card window + the 30d delta lead-in; comfortably above the
      # 121-day stat floor).
      { file: 'coinglass_exchange_balance_list.json', env: 'COINGLASS_API_KEY',
        url: 'https://open-api-v4.coinglass.com/api/exchange/balance/list?symbol=BTC',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        stat: lambda { |b|
          data = JSON.parse(b)['data'].to_a
          raise "only #{data.size} exchanges (need >= 5)" if data.size < 5
          raise 'row missing total_balance' unless data.first.key?('total_balance')

          format('reserves: %d exchanges, total %.0f BTC', data.size,
                 data.sum { |r| r['total_balance'].to_f })
        } },
      { file: 'coinglass_exchange_balance_chart.json', env: 'COINGLASS_API_KEY',
        url: 'https://open-api-v4.coinglass.com/api/exchange/balance/chart?symbol=BTC',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        trim: lambda { |b|
          j = JSON.parse(b)
          d = j['data']
          keep = 400 # 365d card window + the 30d delta lead-in (2026-08-29)
          JSON.generate('code' => j['code'],
                        'data' => {
                          'time_list' => d['time_list'].to_a.last(keep),
                          'price_list' => d['price_list'].to_a.last(keep),
                          'data_map' => Hash[d['data_map'].to_h.map { |k, v| [k, v.to_a.last(keep)] }]
                        })
        },
        stat: lambda { |b|
          d = JSON.parse(b)['data']
          n = d['time_list'].to_a.size
          raise "only #{n} days (need >= 121)" if n < 121

          last = Time.at(d['time_list'].last.to_i / 1000).utc
          format('reserve chart: %d days x %d exchanges, last %s', n,
                 d['data_map'].to_h.size, last.strftime('%d %b %Y'))
        } },
      { file: 'frankfurter_fx.json',
        url: 'https://api.frankfurter.dev/v1/latest?base=USD&symbols=JPY',
        stat: lambda { |b|
          rate = JSON.parse(b)['rates']['JPY'].to_f
          raise 'JPY rate not positive' unless rate.positive?

          format('JPY %s', rate)
        } },
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
        },
        stat: lambda { |b|
          form = JSON.parse(b)['filings']['recent']['form'].to_a
          raise "recent form length #{form.size} != 15" unless form.size == 15

          format('%d recent forms', form.size)
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
        trim: ->(b) { b[0, 60_000] },
        stat: lambda { |b|
          raise "only #{b.bytesize} bytes (need >= 10_000)" if b.bytesize < 10_000

          format('%d bytes', b.bytesize)
        } }
    ].freeze

    module_function

    # Record every fixture into dir. Returns [[file, :ok|:skip|:fail, note]].
    # All HTTP goes through BTC::Http, so tests inject a fake transport.
    #
    # `only:` (array of file-name substrings, from `rake fixtures:record
    # SOURCES=...`) records just the matching fixtures -- an additive
    # filter (M10-2) so a new source can be recorded without re-hitting
    # every upstream. A filtered run leaves README.md untouched (the
    # curated provenance is hand-maintained); a full run regenerates it.
    def record_all(dir, only: nil)
      FileUtils.mkdir_p(dir)
      selected = only ? FIXTURES.select { |f| only.any? { |t| f[:file].include?(t) } } : FIXTURES
      results = selected.map do |f|
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
      write_readme(dir, results) if only.nil?
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

    # ---- offline verification (M1-16) --------------------------------

    AGING_DAYS  = 30      # WARN when a board's nearest live expiry is closer
    STALE_DAYS  = 45      # WARN when the README record stamp is older
    AGING_NOTE  = 'nearest live expiry <30d -- re-record soon'

    # Deribit book rows that PARSE live (OI>0, IV>0, unexpired), as
    # [expiry Time, code] ascending by expiry -- shared by the deribit
    # stat/aging lambdas so the live filter is written once.
    def deribit_live_expiries(content)
      now = Time.now.utc
      JSON.parse(content)['result'].to_a.filter_map do |r|
        code = r['instrument_name'].to_s.split('-')[1]
        e = Options.deribit_expiry(code)
        next unless r['open_interest'].to_f > 0 && r['mark_iv'].to_f > 0 && e && e > now

        [e, code]
      end.sort_by(&:first)
    end

    # CBOE option rows that PARSE live (OI>0, IV or gamma>0, unexpired),
    # as [expiry Time, short code] ascending -- the code is the OSI date
    # rendered like a Deribit expiry (e.g. '15DEC28').
    def cboe_live_expiries(content)
      now = Time.now.utc
      JSON.parse(content)['data']['options'].to_a.filter_map do |o|
        p = Options.parse_osi(o['option'])
        next unless o['open_interest'].to_f > 0 &&
                    (o['iv'].to_f > 0 || o['gamma'].to_f > 0) && p && p[0] > now

        [p[0], p[0].strftime('%-d%b%y').upcase]
      end.sort_by(&:first)
    end

    # Digest every registered fixture + generic safety checks, offline.
    # Returns [[file, :ok|:warn|:fail, note], ...]. No network.
    def verify(dir)
      now = Time.now.utc
      rows = FIXTURES.map { |f| verify_one(dir, f, now) }
      rows + [readme_row(dir, now), leak_row(dir)]
    end

    def verify_one(dir, f, now)
      path = File.join(dir, f[:file])
      unless File.exist?(path)
        return [f[:file], :fail, 'missing'] unless f[:env]

        return [f[:file], :warn, "#{f[:env]} fixture not recorded yet"]
      end

      content = File.read(path)
      if f[:file].end_with?('.json')
        begin
          JSON.parse(content)
        rescue JSON::ParserError => e
          return [f[:file], :fail, "invalid JSON: #{e.message[0, 60]}"]
        end
      end

      note = f[:stat].call(content)
      return [f[:file], :fail, 'stat returned nil'] if note.nil?

      if f[:aging] && (t = f[:aging].call(content)) && (t - now) < AGING_DAYS * 86_400
        return [f[:file], :warn, "#{note} (#{AGING_NOTE})"]
      end

      [f[:file], :ok, note]
    rescue StandardError => e
      [f[:file], :fail, BTC::Env.redact(e.message.to_s[0, 100])]
    end

    # README.md must list exactly the fixture files on disk (backtick
    # quoted), and carry a not-too-old record stamp.
    def readme_row(dir, now = Time.now.utc)
      path = File.join(dir, 'README.md')
      return ['README.md', :fail, 'missing'] unless File.exist?(path)

      text = File.read(path)
      disk = Dir.glob(File.join(dir, '*.{json,html}')).map { |p| File.basename(p) }
      mentioned = text.scan(/`([^`]+\.(?:json|html))`/).flatten
      drift = disk.reject { |b| text.include?("`#{b}`") }.map { |b| "#{b} unlisted" } +
              mentioned.reject { |b| disk.include?(b) }.map { |b| "#{b} absent" }
      return ['README.md', :fail, "drift: #{drift.uniq.join(', ')}"] unless drift.empty?

      stamp = text[/Recorded (\d{4}-\d\d-\d\d \d\d:\d\d) UTC/, 1]
      return ['README.md', :warn, 'no record stamp'] unless stamp

      age = (now - Time.parse("#{stamp} UTC")) / 86_400
      ['README.md', age > STALE_DAYS ? :warn : :ok, "Recorded #{stamp} UTC"]
    end

    # No credential material anywhere in the fixture tree or its README.
    def leak_row(dir)
      secrets = BTC::Env::SECRET_ENV.filter_map { |k| ENV[k] unless ENV[k].to_s.empty? }
      files = Dir.glob(File.join(dir, '*.{json,html}')) + [File.join(dir, 'README.md')]
      files.each do |p|
        next unless File.exist?(p)

        body = File.read(p)
        return ['leak-scan', :fail, "#{File.basename(p)} has api_key= material"] if
          body =~ /api_key=[A-Za-z0-9]{8,}/
        return ['leak-scan', :fail, "#{File.basename(p)} contains a secret value"] if
          secrets.any? { |v| body.include?(v) }
      end
      ['leak-scan', :ok, 'no secret material']
    end
  end
end
