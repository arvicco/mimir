# frozen_string_literal: true
#
# health.rb -- scripts health-check framework (Phase-0 tool review onward).
#
#   rake health          offline: conventions/interface scan + registry
#                        integrity + public-repo hygiene (private board
#                        ids, unregistered hosts) -- part of the
#                        pre-commit gate
#   rake health:sources  NETWORK: probe every registered upstream data
#                        source and validate its response shape, so
#                        upstream degradation (key-gating, dead or moved
#                        endpoints -- the dead-price-source class) is caught
#                        deliberately, not mid-analysis
#
# Registry discipline: every entry names the file that owns the source
# (src) and a marker string that must literally appear there --
# `rake health` fails if the registry drifts from the code.

require 'json'
require 'uri'
require 'rexml/document'
require_relative 'http'
require_relative 'flows'
require_relative 'treasury_ref'

module BTC
  module Health
    # Raw ENV access allowed outside lib/btc/env.rb, per file.
    ALLOWED_ENV = {
      'scripts/btco/btco.rb'          => %w[EDGAR_UA],
      'scripts/btco/ingest.rb'        => %w[EDGAR_UA ANTHROPIC_API_KEY BTCO_MODEL],
      'scripts/btco/validate.rb'      => %w[EDGAR_UA],
      'scripts/scenario/macro.rb'     => %w[FRED_API_KEY],
      'scripts/scenario/etf_flows.rb' => %w[COINGLASS_API_KEY],
      'lib/btc/coinglass.rb'          => %w[COINGLASS_API_KEY],
      'scripts/scenario/scenario.rb'  => %w[HOME],
      'publish/publish.rb'            => %w[PUBLISH_DRY_RUN],
      # M12-2: the staged-backfill window override (a date, not a secret)
      'scripts/scenario/backfill.rb'  => %w[SCENARIO_BACKFILL_FROM],
      # M12-5: the alert topic -- treated as a credential (ENV-only, never
      # logged); the dormant-until-set switch.
      'lib/btc/ntfy.rb'               => %w[NTFY_TOPIC]
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
      # M14-6: cb_premium's spot leg -- hard-coded but never registered
      # (found by the unregistered-host sweep).
      { name: 'binance spot', src: 'scripts/scenario/cb_premium.rb',
        marker: 'api.binance.com/api/v3/ticker/price',
        url: 'https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT',
        check: ->(b) { JSON.parse(b)['price'].to_f > 0 } },
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
      # (seen 2026-07); the module falls back, so degradation here WARNs
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
      # soft: M8-3/M8-4 display inputs via the BTC::Coinglass seam -- a
      # dead endpoint degrades a strip/cross-check line (fail-soft), never
      # a score, so degradation WARNs rather than failing the probe run.
      { name: 'coinglass option info', src: 'lib/btc/coinglass.rb',
        marker: 'option/info', env: 'COINGLASS_API_KEY', soft: true,
        url: 'https://open-api-v4.coinglass.com/api/option/info?symbol=BTC',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        check: ->(b) { j = JSON.parse(b); j['code'].to_s == '0' && !j['data'].to_a.empty? } },
      { name: 'coinglass max pain', src: 'lib/btc/coinglass.rb',
        marker: 'option/max-pain', env: 'COINGLASS_API_KEY', soft: true,
        url: 'https://open-api-v4.coinglass.com/api/option/max-pain?symbol=BTC&exchange=Deribit',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        check: ->(b) { j = JSON.parse(b); j['code'].to_s == '0' && !j['data'].to_a.empty? } },
      { name: 'coinglass funding (oi-weighted)', src: 'lib/btc/coinglass.rb',
        marker: 'oi-weight-history', env: 'COINGLASS_API_KEY', soft: true,
        url: 'https://open-api-v4.coinglass.com/api/futures/funding-rate/oi-weight-history?symbol=BTC&interval=8h',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        check: ->(b) { j = JSON.parse(b); j['code'].to_s == '0' && !j['data'].to_a.empty? } },
      # soft: M10-2 crowd-positioning inputs via the BTC::Coinglass
      # seam -- a dead endpoint degrades a positioning strip (fail-soft),
      # never a score, so degradation WARNs. Daily cadence (tier-safe);
      # the ratio/liquidation endpoints carry their REQUIRED probe params.
      { name: 'coinglass oi aggregated', src: 'lib/btc/coinglass.rb',
        marker: 'open-interest/aggregated-history', env: 'COINGLASS_API_KEY', soft: true,
        url: 'https://open-api-v4.coinglass.com/api/futures/open-interest/aggregated-history?symbol=BTC&interval=1d',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        check: ->(b) { j = JSON.parse(b); j['code'].to_s == '0' && !j['data'].to_a.empty? } },
      { name: 'coinglass global l/s ratio', src: 'lib/btc/coinglass.rb',
        marker: 'global-long-short-account-ratio/history', env: 'COINGLASS_API_KEY', soft: true,
        url: 'https://open-api-v4.coinglass.com/api/futures/global-long-short-account-ratio/history?exchange=Binance&symbol=BTCUSDT&interval=1d',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        check: ->(b) { j = JSON.parse(b); j['code'].to_s == '0' && !j['data'].to_a.empty? } },
      { name: 'coinglass top position ratio', src: 'lib/btc/coinglass.rb',
        marker: 'top-long-short-position-ratio/history', env: 'COINGLASS_API_KEY', soft: true,
        url: 'https://open-api-v4.coinglass.com/api/futures/top-long-short-position-ratio/history?exchange=Binance&symbol=BTCUSDT&interval=1d',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        check: ->(b) { j = JSON.parse(b); j['code'].to_s == '0' && !j['data'].to_a.empty? } },
      { name: 'coinglass taker buy/sell', src: 'lib/btc/coinglass.rb',
        marker: 'taker-buy-sell-volume/history', env: 'COINGLASS_API_KEY', soft: true,
        url: 'https://open-api-v4.coinglass.com/api/futures/taker-buy-sell-volume/history?exchange=Binance&symbol=BTCUSDT&interval=1d',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        check: ->(b) { j = JSON.parse(b); j['code'].to_s == '0' && !j['data'].to_a.empty? } },
      { name: 'coinglass liquidations', src: 'lib/btc/coinglass.rb',
        marker: 'liquidation/aggregated-history', env: 'COINGLASS_API_KEY', soft: true,
        url: 'https://open-api-v4.coinglass.com/api/futures/liquidation/aggregated-history?symbol=BTC&interval=1d&exchange_list=Binance,OKX,Bybit',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        check: ->(b) { j = JSON.parse(b); j['code'].to_s == '0' && !j['data'].to_a.empty? } },
      # M12-4: the independent bubble-index cross-reference.
      { name: 'coinglass bubble index', src: 'lib/btc/coinglass.rb',
        marker: 'index/bitcoin/bubble-index', env: 'COINGLASS_API_KEY', soft: true,
        url: 'https://open-api-v4.coinglass.com/api/index/bitcoin/bubble-index',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        check: ->(b) { j = JSON.parse(b); j['code'].to_s == '0' && !j['data'].to_a.empty? } },
      # M11-7: exchange BTC reserves -- snapshot list + daily history.
      { name: 'coinglass exchange balance list', src: 'lib/btc/coinglass.rb',
        marker: 'exchange/balance/list', env: 'COINGLASS_API_KEY', soft: true,
        url: 'https://open-api-v4.coinglass.com/api/exchange/balance/list?symbol=BTC',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        check: ->(b) { j = JSON.parse(b); j['code'].to_s == '0' && !j['data'].to_a.empty? } },
      { name: 'coinglass exchange balance chart', src: 'lib/btc/coinglass.rb',
        marker: 'exchange/balance/chart', env: 'COINGLASS_API_KEY', soft: true,
        url: 'https://open-api-v4.coinglass.com/api/exchange/balance/chart?symbol=BTC',
        headers: -> { { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] } },
        check: ->(b) { j = JSON.parse(b); j['code'].to_s == '0' && !(j.dig('data', 'time_list') || []).empty? } },
      # soft: an advisory ingest sanity reference (M7-9) -- if the
      # aggregator is down or reshapes, --review just omits the ref line,
      # so degradation WARNs rather than failing the probe run.
      { name: 'bitcointreasuries ref', src: 'lib/btc/treasury_ref.rb',
        marker: 'bitcointreasuries.net', soft: true,
        url: 'https://bitcointreasuries.net/',
        check: ->(b) { TreasuryRef.parse_table(b).size >= 10 } },
      # soft: the M7-11/M7-12 advisory review refs + the M7-14 tracker
      # proposal source (docs/BTCO-DATA-SOURCES.md) -- --review omits the
      # line / --tracker aborts with a message, so degradation WARNs.
      { name: 'coingecko treasury ref', src: 'lib/btc/coingecko_ref.rb',
        marker: 'api.coingecko.com/api/v3/companies/public_treasury', soft: true,
        url: 'https://api.coingecko.com/api/v3/companies/public_treasury/bitcoin',
        check: ->(b) { JSON.parse(b).fetch('companies').size >= 50 } },
      { name: 'sec xbrl dei shares', src: 'lib/btc/sec_shares.rb',
        marker: 'data.sec.gov/api/xbrl/companyconcept', soft: true,
        url: 'https://data.sec.gov/api/xbrl/companyconcept/CIK0001849635/dei/EntityCommonStockSharesOutstanding.json',
        headers: -> { { 'User-Agent' => ENV['EDGAR_UA'] || 'mimir health (set EDGAR_UA=name email)' } },
        check: ->(b) { !JSON.parse(b).fetch('units').fetch('shares').to_a.empty? } },
      { name: 'strategytracker feed', src: 'scripts/btco/ingest.rb',
        marker: 'data.strategytracker.com', soft: true,
        url: 'https://data.strategytracker.com/latest.json',
        check: ->(b) { JSON.parse(b).fetch('files').key?('full') } },
      # soft: non-US quote source (owner ruling 2026-07-10) -- a dead quote drops the row
      # (fail-soft by design), never blanks the card.
      { name: 'yahoo quote (non-US)', src: 'scripts/btco/btco.rb',
        marker: 'query1.finance.yahoo.com/v8/finance/chart', soft: true,
        url: 'https://query1.finance.yahoo.com/v8/finance/chart/3350.T?interval=1d&range=1d',
        check: ->(b) { JSON.parse(b).dig('chart', 'result', 0, 'meta', 'regularMarketPrice').to_f.positive? } },
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
      # list-keys limit must be >= 10 (the API 400s below that)
      { name: 'cloudflare kv', src: 'publish/kv_client.rb',
        marker: 'api.cloudflare.com/client/v4', env: 'CLOUDFLARE_API_TOKEN',
        url: -> { "https://api.cloudflare.com/client/v4/accounts/#{ENV['CLOUDFLARE_ACCOUNT_ID']}/storage/kv/namespaces/#{ENV['CLOUDFLARE_KV_NAMESPACE_ID']}/keys?limit=10" },
        headers: -> { { 'Authorization' => "Bearer #{ENV['CLOUDFLARE_API_TOKEN']}" } },
        check: ->(b) { JSON.parse(b)['success'] == true } },
      # M14-3: the push-alert channel. Reachability of the BARE host only
      # -- never a topic URL (the topic is a credential, and a probe must
      # never post or subscribe). soft: alerts are advisory; a dead
      # ntfy.sh never touches an analytic, so it WARNs.
      { name: 'ntfy.sh push', src: 'lib/btc/ntfy.rb',
        marker: "HOST      = 'https://ntfy.sh'", soft: true,
        url: 'https://ntfy.sh/',
        check: ->(b) { b.to_s.downcase.include?('ntfy') } }
    ].freeze

    # Expected ECharts CDN artifact.  Update only intentionally (bump both
    # HTML pages together; recompute with the recipe in the HTML comment).
    ECHARTS_PIN = {
      version: '5.6.0',
      sha384:  'pPi0zxBAoDu6+JXW/C68UZLvBUUtU+7zonhif43rqj7pxsGyqyqzcian2Rj37Rss'
    }.freeze

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
          bad << "#{loc}: brace-less trailing hash at a keyword-taking call (it binds to the headers param)" if
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

    # ---- offline: public-repo hygiene (M14-6) -------------------------
    #
    # PRIVATE-ID GUARD. Owner declaration 2026-10-12: this is a PUBLIC
    # repo whose work boards live in the gitignored .docs/. Ids that
    # resolve ONLY in those boards are PRIVATE and may not appear in any
    # tracked file (code, comments, docs, runtime strings, fixtures):
    # register/incident ids (with or without the numero sign), queue
    # ids Q-<n> and the older P-<n>, review findings F-<n>, and phase
    # decision ids D<digits>-<letter> (incl. slash/dot ranges). PUBLIC
    # and fine: M<digits>-<digits> packet ids, phase numbers, PR numbers.
    # Replace an id with its content (a date, "owner ruling <date>", a
    # plain clause) -- never delete the information, only the pointer.
    # The two lines tagged with the marker below are the guard's own
    # pattern definition: the single allowed exception (declared 2026-10-12).
    # Boundary calls (owner review 2026-10-12): skuld slice ids S-A..S-H
    # are PUBLIC sub-phase cross-references, like M-n packet ids (not in
    # the pattern); naming .docs/ FILE PATHS in tracked files is allowed --
    # the ban is on register ids, not on naming the boards.
    HYGIENE_SELF   = 'lib/btc/health.rb'
    HYGIENE_MARKER = '# hygiene: pattern-definition (owner declaration 2026-10-12)'
    PRIVATE_ID_RE  = /(?<![\w-])(?:№?[RIQFP]-\d+(?!\d)|D\d+-[a-z](?![A-Za-z0-9]))/ # hygiene: pattern-definition (owner declaration 2026-10-12)

    # git's own heuristic: a NUL byte in the first 8000 bytes = binary.
    def binary?(bytes)
      bytes.b[0, 8000].include?("\0")
    end

    # -> [[line_no, id], ...] for one text blob.
    def private_id_hits(text)
      text = text.dup.force_encoding('UTF-8').scrub
      text.each_line.with_index(1).flat_map do |line, i|
        line.scan(PRIVATE_ID_RE).map { |id| [i, id] }
      end
    end

    # files: { relative_path => raw bytes }. Binaries are skipped by
    # content sniff (never by path); the guard file's tagged
    # pattern-definition lines are the only exception.
    def scan_private_ids(files)
      files.flat_map do |path, bytes|
        next [] if binary?(bytes)

        lines = bytes.dup.force_encoding('UTF-8').scrub.lines
        private_id_hits(bytes).filter_map do |i, id|
          next if path == HYGIENE_SELF && lines[i - 1].include?(HYGIENE_MARKER)

          "#{path}:#{i}: private board id #{id} in a tracked file " \
            '(public repo, owner declaration 2026-10-12 -- replace it with its content)'
        end
      end
    end

    # UNREGISTERED-HOST SWEEP. Every http(s) host literal in tracked
    # runtime files must be a SOURCES-registered host or an entry here --
    # a hard-coded host nobody registered is never probed by
    # `rake health:sources` (the registry drift check cannot see it).
    # Infrastructure endpoints only; each entry carries its reason.
    HOST_ALLOWLIST = {
      'localhost'           => 'the local preview server (lib/btc/preview_server.rb, web/ dev hints) -- not a network source',
      'cdn.jsdelivr.net'    => 'the pinned ECharts CDN tag in web/ -- version + SRI hash enforced by scan_sri',
      'github.com'          => 'the public repo link in the web/ page footers -- a static link, never fetched',
      'api.anthropic.com'   => 'the BTCo ingest LLM call (owner-interactive, paid, key-gated) -- not a data source to probe',
      'www.sec.gov'         => 'EDGAR filing-document links/fetches; data.sec.gov (registered) is the probed EDGAR liveness proxy'
    }.freeze

    # Files the host sweep covers: runtime Ruby + everything under web/.
    def host_scope?(path)
      path.match?(%r{\A(?:scripts|lib|publish|ops)/.+\.rb\z}) || path.start_with?('web/')
    end

    def hosts_in(text)
      text.dup.force_encoding('UTF-8').scrub
          .scan(%r{https?://([A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9])}).flatten
          .map(&:downcase).uniq
    end

    # Hosts of every SOURCES url (lambda urls are built, never fetched).
    # -> [hosts, problems]. A lambda url can carry an ENV secret (FRED's
    # key rides a query param) and URI errors embed the full URI in their
    # message, so ANY failure reports the entry NAME only -- never the
    # url, never the exception text.
    def registered_hosts_report(sources = SOURCES)
      hosts = []
      bad = []
      sources.each do |s|
        url = s[:url].respond_to?(:call) ? s[:url].call : s[:url]
        host = URI.parse(url.to_s).host
        raise ArgumentError if host.nil? || host.empty?

        hosts << host.downcase
      rescue StandardError
        bad << "health hosts: SOURCES entry '#{s[:name]}' -- url unreadable " \
               '(details withheld: urls may carry secrets)'
      end
      [hosts.uniq, bad]
    end

    def registered_hosts(sources = SOURCES)
      registered_hosts_report(sources).first
    end

    # Every allowlist entry must carry a non-empty one-line reason.
    def check_host_allowlist(list = HOST_ALLOWLIST)
      list.filter_map do |host, why|
        next if why.is_a?(String) && !why.strip.empty? && !why.include?("\n")

        "health hosts: allowlist entry #{host} needs a one-line reason"
      end
    end

    # files: { relative_path => content }. -> problem strings.
    def scan_hosts(files, sources = SOURCES, allow = HOST_ALLOWLIST)
      reg, bad = registered_hosts_report(sources)
      known = reg + allow.keys
      bad += check_host_allowlist(allow)
      files.each do |path, content|
        next unless host_scope?(path)
        next if binary?(content)

        content.dup.force_encoding('UTF-8').scrub.each_line.with_index(1) do |line, i|
          hosts_in(line).each do |h|
            next if known.include?(h)

            bad << "#{path}:#{i}: host #{h} is not in Health::SOURCES or HOST_ALLOWLIST " \
                   '(register it so rake health:sources probes it, or allowlist it with a reason)'
          end
        end
      end
      bad
    end

    # { path => raw bytes } of every git-tracked file under root.
    def tracked_files(root = Dir.pwd)
      list = IO.popen(['git', '-C', root, 'ls-files', '-z'], &:read)
      return nil unless $?.success?

      list.split("\0").each_with_object({}) do |rel, h|
        full = File.join(root, rel)
        h[rel] = File.binread(full) if File.file?(full)
      end
    end

    # The rake-health entry point for both hygiene checks.
    def scan_hygiene(root = Dir.pwd)
      files = tracked_files(root)
      return ['hygiene: git ls-files failed -- cannot enumerate tracked files'] unless files

      scan_private_ids(files) + scan_hosts(files)
    end

    # SRI drift check for the pinned ECharts CDN tag.
    # pages: { path => html_content }
    # Returns an array of problem strings (empty = all clear).
    def scan_sri(pages)
      bad = []
      pin = ECHARTS_PIN
      expected_ver  = pin[:version]
      expected_hash = pin[:sha384]
      # Regex matches the echarts script tag across one or two lines --
      # capture the src version, the integrity hash, and crossorigin presence.
      tag_re = %r{
        <script[^>]*
        cdn\.jsdelivr\.net/npm/echarts@([0-9.]+)/dist/echarts\.min\.js[^>]*
        >
      }mx

      pages.each do |path, html|
        m = tag_re.match(html)
        unless m
          bad << "#{path}: echarts script tag not found"
          next
        end
        tag = m[0]
        ver = m[1]
        bad << "#{path}: echarts version #{ver} != pinned #{expected_ver}" if ver != expected_ver

        integrity_m = tag.match(/integrity="sha384-([^"]+)"/)
        if integrity_m
          bad << "#{path}: integrity hash mismatch (got #{integrity_m[1]})" if integrity_m[1] != expected_hash
        else
          bad << "#{path}: echarts script tag missing integrity attribute"
        end

        bad << "#{path}: echarts script tag missing crossorigin attribute" unless tag.include?('crossorigin=')
      end

      # Cross-page consistency: all pages must agree on version + hash.
      versions = pages.filter_map do |path, html|
        m = tag_re.match(html)
        m ? [path, m[1]] : nil
      end.to_h
      hashes = pages.filter_map do |path, html|
        m = html.match(/integrity="sha384-([^"]+)"/)
        m ? [path, m[1]] : nil
      end.to_h

      if versions.values.uniq.size > 1
        bad << "pages disagree on echarts version: #{versions.map { |p, v| "#{p}=#{v}" }.join(', ')}"
      end
      if hashes.values.uniq.size > 1
        bad << "pages disagree on echarts SRI hash: #{hashes.map { |p, h| "#{p}=#{h[0, 12]}..." }.join(', ')}"
      end

      bad
    end

    # ---- offline: ops/ launchd wrappers scan (M5-1) --------------------

    # Offline audit of the prepared launchd artifacts under `ops_dir`
    # (default 'ops'). Every check is local -- `bash -n` for shell syntax
    # and rexml for the plists (plutil is macOS-only, absent on the ubuntu
    # CI). A missing or empty ops/ is a FAIL: the M5-1 wrapper + plist must
    # exist. Returns an array of problem strings (empty = all clear).
    def scan_ops(ops_dir = 'ops')
      unless File.directory?(ops_dir)
        return ["ops: directory #{ops_dir}/ is missing (M5-1: run_publish.sh + com.mimir.publish.plist must exist)"]
      end

      shells = Dir.glob(File.join(ops_dir, '*.sh')).sort
      plists = Dir.glob(File.join(ops_dir, '*.plist')).sort
      if shells.empty? && plists.empty?
        return ["ops: #{ops_dir}/ is empty (expected run_publish.sh + com.mimir.publish.plist)"]
      end

      bad = []
      shells.each { |f| bad.concat(scan_ops_shell(f)) }
      plists.each { |f| bad.concat(scan_ops_plist(f)) }
      bad
    end

    # Worktree discipline (owner rulings 2026-08-11): worktrees are the
    # loop's INTERNAL, EPHEMERAL tooling -- they live in agent scratch
    # space (/tmp), are removed the moment their need ends, and must
    # NEVER appear on the owner's filesystem or in owner-facing docs.
    # Flagged: (a) any extra worktree under a home directory (persistent
    # pollution -- the ~/Dev/mimir-phaseX folders, or anything like
    # them), and (b) any extra worktree whose branch is already merged
    # into main (stale -- the need ended; phase-8's rotted a month).
    # check_worktrees is pure (offline-testable); scan_worktrees gathers
    # the git state and returns [] where git is absent (CI checkout).
    def check_worktrees(porcelain, merged_branches, home = Dir.home)
      bad = []
      entries = porcelain.split(/\n\n+/).map(&:strip).reject(&:empty?)
      # git lists the MAIN checkout first; it is the one sanctioned tree
      main = File.expand_path(entries.first[/^worktree (.+)$/, 1].to_s)
      return [] if main.empty?

      home = File.expand_path(home)
      entries.each do |entry|
        path   = entry[/^worktree (.+)$/, 1]
        branch = entry[/^branch refs\/heads\/(.+)$/, 1]
        next unless path

        path = File.expand_path(path)
        next if path == main # the main checkout itself

        if path == home || path.start_with?(home + File::SEPARATOR)
          bad << "worktree: #{path} sits on the owner's filesystem " \
                 '(anti-pattern, owner ruling 2026-08-11) -- worktrees are ' \
                 'loop-internal and live in agent scratch space (/tmp) only'
        end
        if branch && merged_branches.include?(branch)
          bad << "worktree: #{path} (branch #{branch}) is STALE -- the branch " \
                 'is merged into main; the need ended, git worktree remove it'
        end
      end
      bad
    end

    def scan_worktrees
      porcelain = IO.popen(%w[git worktree list --porcelain], &:read)
      return [] unless $?.success?

      merged = IO.popen(%w[git branch --merged main --format %(refname:short)],
                        &:read)
      merged = '' unless $?.success?
      check_worktrees(porcelain, merged.split("\n").map(&:strip) - ['main'])
    end

    # One shell wrapper: `bash -n` syntax, the PUBLISH_DRY_RUN=0 guarantee
    # for the publish wrapper, and the repo-wide --apply ban (universe.json
    # protection -- no ops job may mutate the universe).
    def scan_ops_shell(path)
      bad = []
      unless system('bash', '-n', path, out: File::NULL, err: File::NULL)
        bad << "#{path}: bash -n syntax error"
      end
      content = File.read(path)
      if File.basename(path) == 'run_publish.sh' && !content.include?('PUBLISH_DRY_RUN=0')
        bad << "#{path}: missing PUBLISH_DRY_RUN=0 (the publish wrapper must force a LIVE run)"
      end
      if content.include?('--apply')
        bad << "#{path}: contains --apply (universe.json protection: ops jobs never apply)"
      end
      bad
    end

    # One launchd plist: well-formed XML (rexml) with a non-empty Label and
    # ProgramArguments, RunAtLoad present and false, no `KeepAlive true`
    # (no-overlap: launchd must not respawn the publisher), and the same
    # --apply ban as the wrappers (a plist could schedule it directly).
    def scan_ops_plist(path)
      content = File.read(path)
      bad = []
      if content.include?('--apply')
        bad << "#{path}: contains --apply (universe.json protection: ops jobs never apply)"
      end
      doc = begin
        REXML::Document.new(content)
      rescue REXML::ParseException => e
        return bad + ["#{path}: not well-formed XML (#{e.message.to_s.lines.first.to_s.strip})"]
      end

      root = doc.root
      return bad + ["#{path}: missing <plist> root element"] unless root && root.name == 'plist'

      dict = root.elements['dict']
      return bad + ["#{path}: missing top-level <dict>"] unless dict

      pairs = plist_pairs(dict)

      label = pairs['Label']
      unless label && label.name == 'string' && !label.text.to_s.strip.empty?
        bad << "#{path}: Label missing or empty"
      end

      args = pairs['ProgramArguments']
      ok_args = args && args.name == 'array' &&
                args.elements.to_a.any? { |c| c.name == 'string' && !c.text.to_s.strip.empty? }
      bad << "#{path}: ProgramArguments missing or empty" unless ok_args

      ral = pairs['RunAtLoad']
      if ral.nil?
        bad << "#{path}: RunAtLoad key missing (must be present and false)"
      elsif ral.name != 'false'
        bad << "#{path}: RunAtLoad must be <false/> (got <#{ral.name}/>)"
      end

      ka = pairs['KeepAlive']
      bad << "#{path}: KeepAlive true is forbidden (no-overlap: launchd must not respawn)" if ka && ka.name == 'true'

      bad
    end

    # Map a plist <dict>'s <key> nodes to their following value elements.
    def plist_pairs(dict)
      pairs = {}
      key = nil
      dict.elements.each do |el|
        if el.name == 'key'
          key = el.text
        elsif key
          pairs[key] = el
          key = nil
        end
      end
      pairs
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
