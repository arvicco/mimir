# test/fixtures -- recorded API responses

Real responses trimmed to the minimum the parsers need
(the trim IS part of the frozen fixture shape). Regenerate
with `rake fixtures:record` (network, owner-run), then
review the diff before committing.

Recorded 2026-07-04 18:27 UTC:

- `deribit_index.json` -- OK (https://www.deribit.com/api/v2/public/get_index_price?index_name=btc_usd)
- `deribit_book_summary.json` -- OK (https://www.deribit.com/api/v2/public/get_book_summary_by_currency?currency=BTC&kind=option)
- `deribit_futures.json` -- OK (https://www.deribit.com/api/v2/public/get_book_summary_by_currency?currency=BTC&kind=future)
- `cboe_options.json` -- OK (https://cdn.cboe.com/api/global/delayed_quotes/options/IBIT.json)
- `coinmetrics_prices.json` -- OK (https://community-api.coinmetrics.io/v4/timeseries/asset-metrics?assets=btc&metrics=PriceUSD&frequency=1d&page_size=5&paging_from=start&start_time=2026-06-28)
- `coinmetrics_onchain.json` -- OK (https://community-api.coinmetrics.io/v4/timeseries/asset-metrics?assets=btc&metrics=CapMVRVCur,PriceUSD&frequency=1d&page_size=5&start_time=2026-06-28)
- `binance_funding.json` -- OK (https://fapi.binance.com/fapi/v1/fundingRate?symbol=BTCUSDT&limit=21)
- `binance_premium.json` -- OK (https://fapi.binance.com/fapi/v1/premiumIndex?symbol=BTCUSDT)
- `binance_spot.json` -- OK (https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT)
- `coinbase_ticker.json` -- OK (https://api.exchange.coinbase.com/products/BTC-USD/ticker)
- `mempool_hashrate.json` -- OK (https://mempool.space/api/v1/mining/hashrate/6m)
- `defillama_stables.json` -- OK (https://stablecoins.llama.fi/stablecoins?includePrices=false)
- `farside_flows.html` -- OK (https://farside.co.uk/btc/)
- `coinglass_flows.json` -- OK (https://open-api-v4.coinglass.com/api/etf/bitcoin/flow-history)
- `frankfurter_fx.json` -- OK (https://api.frankfurter.dev/v1/latest?base=USD&symbols=JPY)
- `fred_walcl.json` -- OK (https://api.stlouisfed.org/fred/series/observations?series_id=WALCL&api_key=[REDACTED]&file_type=json&sort_order=desc&limit=6)
- `fred_wtregen.json` -- OK (https://api.stlouisfed.org/fred/series/observations?series_id=WTREGEN&api_key=[REDACTED]&file_type=json&sort_order=desc&limit=6)
- `fred_rrpontsyd.json` -- OK (https://api.stlouisfed.org/fred/series/observations?series_id=RRPONTSYD&api_key=[REDACTED]&file_type=json&sort_order=desc&limit=25)
- `fred_dfii10.json` -- OK (https://api.stlouisfed.org/fred/series/observations?series_id=DFII10&api_key=[REDACTED]&file_type=json&sort_order=desc&limit=25)
- `edgar_submissions.json` -- OK (https://data.sec.gov/submissions/CIK0001050446.json)
- `edgar_filing.html` -- OK (https://www.sec.gov/Archives/edgar/data/1050446/000119312526286871/mstr-20260629.htm)
