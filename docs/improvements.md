# improvements.md -- Coinglass API integration plan (Mimir)

Mapping of the Coinglass API v4 catalog (base
`https://open-api-v4.coinglass.com`, auth header `CG-API-KEY`, docs:
https://docs.coinglass.com/reference/endpoint-overview) onto the existing
toolset. Organized as: integration groundwork, upgrades to existing
modules, new tools, and a prioritized rollout mapped to the mimir phases.

Headline findings from the catalog review:

1. Coinglass covers the **cohort on-chain metrics** (LTH/STH realized
   price, SOPR, supply, NUPL, Reserve Risk) previously assumed to require
   a separate CryptoQuant/Glassnode subscription -- the biggest
   single analytical upgrade available to us.
2. It **replaces the only scrape in the codebase** (Farside HTML in
   `etf_flows.rb`) with a clean JSON endpoint including per-ticker
   breakdowns.
3. It provides the **liquidation topology** (heatmaps/maps, 3 models,
   aggregated cross-exchange) that pairs with our GEX profiles into a
   complete forced-flow map -- the flagship new tool.
4. It does NOT replace: the Deribit chain (Coinglass options data is
   summary-level -- OI/volume/max-pain, not per-strike greeks; gex.rb and
   the future rnd.rb stay on Deribit), mempool.space (hash ribbons),
   EDGAR/Stooq/CBOE (btco), FRED (macro), DefiLlama (adequate).

## 0. Integration groundwork (do first)

- **Shared client** `lib/btc/coinglass.rb` (or `scenario/common.rb`
  extension pre-Phase-1): GET with `CG-API-KEY` from
  `COINGLASS_API_KEY` env, standard `{code, data}` unwrapping,
  fail-soft on error.
- **File cache with per-endpoint TTL** (`data/cg_cache/<hash>.json`):
  plan tiers are rate-limited per minute and several modules will share
  endpoints; daily-granularity endpoints get 6-12h TTLs, intraday ones
  5-15 min. Cache layer keeps us far from limits and gives offline
  reruns for free.
- **Tier probe**: call Account Level Query
  (`/api/user/account-subscription` -- see docs/reference/
  user-account-subscription) once per run; some endpoints (notably
  liquidation heatmaps, orderbook history) are gated by plan tier.
  Modules must degrade fail-soft with a "requires higher tier" note
  rather than erroring, so the suite works identically across plans.
- **Governance** (per CLAUDE.md Golden Rule 4): source swaps keep
  existing thresholds untouched. Where richer data justifies *new*
  thresholds (funding, premium), the module runs BOTH sources in
  parallel for >= 2 weeks, logging both to history, before any scoring
  change is proposed as an explicit research decision.
- Note for CC-assisted dev: Coinglass publishes an MCP service and an
  agent skill (docs/reference/mcp-service) -- useful during development
  for exploring response shapes; production code still uses our own
  client.

## A. Upgrades to existing modules

### A1. scenario/etf_flows.rb -- source swap (P0)
Replace the Farside HTML scrape with **ETF Flows History**
(docs/reference/etf-flows-history): daily net flows USD + per-ticker
breakdown. Keep the identical 5d-vs-prior-5d scoring. Adds for free:
per-ticker concentration (is IBIT the whole story?) as detail fields.
Farside parser stays as documented fallback for one release, then dies.
Effort: ~1h. Risk: none (parallel-run one week).

### A2. scenario/onchain_value.rb -- cohort upgrade (P0)
Today: Coin Metrics MVRV + realized price ("floor gauge"). Add from
Coinglass index endpoints: **LTH Realized Price**, **STH Realized
Price**, **LTH-SOPR**, **NUPL**, **Reserve Risk**
(docs/reference/bitcoin-long-term-holder-realized-price and siblings).
This converts the module into the *timing* gauge relevant to the
price-done/time-not question:
- STH realized price = the bear-market resistance line (reclaim = B'->C'
  confirmation);
- price vs LTH realized price = terminal-floor proximity (2015/2018/2022
  bottoms converged there);
- LTH-SOPR < 1 sustained = old-hand capitulation in progress (A'
  terminal phase);
- NUPL capitulation zone entry/exit timestamps the cycle phase.
Scoring: keep MVRV score unchanged; add the cohort readings as detail +
a proposed secondary score behind the parallel-run gate. Effort: ~3h.

### A3. scenario/cb_premium.rb -- history upgrade (P1)
**Coinbase Premium Index** endpoint (docs/reference/
coinbase-premium-index) provides the *historical* series our snapshot
approach lacks. Upgrade the signal from level-band to
level-plus-persistence (e.g. 10d mean premium), which is what the module
header already admits it wants. Keep the live two-ticker computation as
cross-check. Scoring change -> research gate. Effort: ~1h.

### A4. scenario/funding_basis.rb -- aggregation upgrade (P1)
Replace Binance-only funding with **OI-Weighted Funding OHLC**
(docs/reference/oi-weight-ohlc-history) -- cross-exchange, manipulation-
resistant -- and the ad-hoc Deribit quarterly calc with **Futures
Basis** history (docs/reference/basis), which gives annualized basis as
a proper series (persistence of negative basis, not just a snapshot).
Thresholds re-validated under parallel run (aggregated funding levels
differ from Binance-only). Effort: ~2h.

### A5. lppl/prices.rb -- source redundancy (P2)
Add Coinglass **Price OHLC History** (docs/reference/price-ohlc-history)
as automatic fallback when CryptoCompare fails/rots. Cache format
unchanged; provenance column added. Effort: ~1h.

### A6. gex suite -- cross-checks only (P2)
**Options Info / Max Pain / Exchange OI History** (docs/reference/info,
option-max-pain, exchange-open-interest-history) as a sanity panel for
gex_btc_combined.rb: our computed Deribit OI totals vs Coinglass's, and
max-pain per expiry as an independent reference line in the chart spec.
No engine changes -- Coinglass has no per-strike chain. Effort: ~1h.

## B. New tools

### B1. liqmap.rb -- liquidation topology + GEX merge (P0, flagship)
Endpoints: **Coin Liquidation Map** (docs/reference/
liquidation-aggregated-map), **Coin Liquidation Heatmap Model 1-3**
(liquidation-aggregate-heatmap*), **Liquidation Max Pain**
(liquidation-max-pain), **Aggregated Liquidation History**
(aggregated-liquidation-history).
Output: cross-exchange liquidation-cluster levels bucketed on the BTC
price axis -- same $1k bins and USD units as gex_btc_combined.rb -- plus
merged output: for each level, dealer-hedging gamma flow AND estimated
liquidation notional. The two together give the complete forced-flow
map (convex + linear leverage), which is what actually resolves
"air pocket vs wall" questions like the $60k break. Contract: standard
--json/--tmux (`LIQ dn:55.2k($1.9B) up:64.8k($1.2B) skew -0.4`); feeds
a fourth chart spec (`v1:chart:liq_topology`) overlaying GEX profile
bars with liquidation density. Effort: ~1 day incl. chart spec.

### B2. positioning.rb -- futures positioning module (P1)
Endpoints: **Top Position Ratio History** (top-longshort-position-ratio),
**Global Account Ratio** (global-longshort-account-ratio), **Net
Long/Short Position v2** (net-position-v2), **Aggregated OI OHLC** +
coin-margin/stablecoin-margin splits (oi-ohlc-aggregated-*).
The linear-positioning complement to funding: top-trader vs crowd
divergence (top traders net long while crowd shorts = squeeze setup),
and coin-margined OI share as a cascade-amplifier metric (coin-margined
positions lose collateral value as price falls). Scenario module #9,
standard -1/0/+1 (crowding extremes are contrarian). Effort: ~3h.

### B3. deriv_risk.rb -- CDRI monitor (P1, weight-0 first)
**CDRI Index** (docs/reference/cdri-index) -- Coinglass's own composite
derivatives risk index. We did not build it and should not trust it
blindly: ingest as a weight-0 monitor (percentile vs its own history),
correlate against our scenario composite in the ledger for a quarter,
then decide promotion. Cheap orthogonal check on our own stress logic.
Effort: ~1h.

### B4. whale.rb -- large-actor monitor (P2)
**Hyperliquid Whale Positions/Alerts** (hyperliquid-whale-*), **Whale
Transfer** >= $10M on-chain (whale-transfer), **Exchange Balance
List/Chart** (exchange-balance-*). Exchange-reserve drawdown is a
supply-tightness signal; whale exchange inflows precede distribution.
Hyperliquid data gives visibility into the venue our Deribit/CME view
misses entirely. Monitor-first (weight 0), promotion by ledger evidence.
Effort: ~3h.

### B5. flow_quality.rb -- CVD / taker-flow module (P3, optional)
**Aggregated CVD** (futures-aggregated-cvd-history, spot-aggregated-cvd-
history), **Taker Buy/Sell ratios** (aggregated-taker-buysell-*),
**Coin NetFlow** futures vs spot. Answers "is this move real (spot-led)
or leverage-led?" -- regime-quality context for scenario transitions.
Defer until B1/B2 have ledger history; overlapping information content.

## C. Rollout plan

| step | items                          | effort | gate                        |
|------|--------------------------------|--------|-----------------------------|
| 1    | groundwork (client+cache+probe)| 0.5d   | tier confirmed, cache hits  |
| 2    | A1 etf_flows swap              | 1h     | 1w parallel vs Farside      |
| 3    | B1 liqmap.rb + chart spec      | 1d     | visual review vs coinglass.com UI |
| 4    | A2 onchain cohort upgrade      | 3h     | detail-only until research OK |
| 5    | A3+A4 premium/funding upgrades | 3h     | 2w parallel, threshold review |
| 6    | B2 positioning.rb              | 3h     | 2w weight-0 in scenario     |
| 7    | B3 deriv_risk.rb               | 1h     | quarter-long correlation    |
| 8    | A5/A6, B4, B5                  | ad hoc | opportunistic               |

Fits the mimir repo as: groundwork lands with Phase 1 (it IS the http
seam for one more source); module upgrades are behavior-preserving
source swaps under existing contract tests plus additive detail fields;
new tools follow suite conventions and enter scenario.rb at weight 0
until ledger evidence justifies promotion. Every scoring/threshold
change goes through the CLAUDE.md research-decision gate with parallel-
run evidence attached.

## D. Open items to verify at implementation time

- Exact endpoint paths/params from each doc page (slugs above are doc
  references, not guaranteed URL paths); response field names against
  live fixtures recorded via `rake fixtures:record`.
- Which of the used endpoints sit above the current plan tier (probe +
  fail-soft covers this at runtime, but the rollout order may reshuffle
  if e.g. heatmaps are gated).
- Rate limits per tier -> final cache TTLs.
- Liquidation heatmap model choice (1/2/3): start with the aggregated
  map + model 2, compare against the site's rendering before trusting.
