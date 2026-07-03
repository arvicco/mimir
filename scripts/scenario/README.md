# scenario -- BTC regime signal suite

Modular signal scripts + aggregator for early discrimination between BTC
price scenarios (flush / base / recovery). Ruby >= 2.5, stdlib only, all
data sources free/public.

## Modules

| module           | source                          | freq   | wt | measures                        |
|------------------|---------------------------------|--------|----|---------------------------------|
| etf_flows.rb     | farside.co.uk (HTML scrape)     | daily  | 3  | spot-ETF net flows, 5d trend    |
| funding_basis.rb | Binance fapi + Deribit          | live   | 2  | perp funding (contrarian), basis|
| cb_premium.rb    | Coinbase + Binance tickers      | live   | 2  | US institutional bid            |
| macro.rb         | FRED (needs free FRED_API_KEY)  | weekly | 2  | net liquidity, 10y real yield   |
| hash_ribbons.rb  | mempool.space                   | daily  | 1  | miner capitulation / recovery   |
| onchain_value.rb | Coin Metrics community API      | daily  | 1  | MVRV, realized price floor      |
| stables.rb       | DefiLlama                       | daily  | 1  | USDT+USDC supply growth         |

Every module: runs standalone (`ruby etf_flows.rb`), scores -1/0/+1
(+1 = base/recovery-supportive, -1 = flush-supportive), supports `--json`.
Dead data sources degrade to score 0, never crash the composite.

## Aggregator

    ruby scenario.rb              # table + composite
    ruby scenario.rb --tmux       # 'SCN LEAN-FLUSH -0.25 etf-1 fnd+1 ...'
                                  #   -> /tmp/scenario.status
    ruby scenario.rb --json
    ruby scenario.rb --history    # append ~/.scenario_history.jsonl

Composite bands: <=-0.40 FLUSH, -0.10 LEAN-FLUSH, +0.10 NEUTRAL,
+0.40 BASE, above RECOVERY.

## Cron (novo)

    */30 12-23 * * 1-5  cd $HOME/Dev/bitcoin/scenario && /usr/bin/ruby scenario.rb --tmux --history

Signals lead at different horizons -- funding/premium (days),
flows (days-weeks), hash/MVRV/stables (weeks), macro (months) -- so the
composite drifting from FLUSH through NEUTRAL to BASE over successive
history entries is itself the A'->B' transition signature.

## Notes

- etf_flows is the only scrape; if Farside changes layout it reports
  score 0 with a parse error. Everything else is JSON APIs.
- macro.rb needs `export FRED_API_KEY=...` (free, fred.stlouisfed.org).
- Weights in scenario.rb MODULES are meant to be tuned against
  ~/.scenario_history.jsonl once a few weeks accumulate.
