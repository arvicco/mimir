# mimir -- BTC analytics toolkits

Local Ruby analytics for Bitcoin: options positioning (GEX), a
multi-signal regime composite, an LPPL falsification suite, and a
treasury-company analyser. Everything runs from cron/tmux on a Mac and
prints to the terminal. On top of that sits a **Cloudflare presentation
layer** (Worker API + KV + a static dashboard, see
[ARCHITECTURE.md](ARCHITECTURE.md)): Ruby computes and publishes
pre-built chart specs, the browser just renders them. The whole layer
is **live in production** (Gate 4, 2026-07-06): the Worker serves the
API and the dashboard from one workers.dev host. Deploys stay human
(`rake deploy`, owner-run -- it ships code AND a fresh data publish;
the loop and CI are locked out).

Requirements: **Ruby 3.3+ (Apple Silicon), zero gems** -- stdlib only,
no bundle install. Run everything from the repo root.

**New here?** [docs/METHODOLOGY.md](docs/METHODOLOGY.md) explains what
each tool measures, every displayed field, how to decode the status
lines, and the caveats -- read it before acting on any output.

## What works today

| tool | what it tells you | maturity |
|---|---|---|
| `scripts/gex.rb` | Deribit BTC/ETH strike-level GEX, gamma flip, walls | mature |
| `scripts/gex_us.rb` | same for US-listed chains (IBIT, MSTR, ...) via CBOE | mature |
| `scripts/gex_btc_combined.rb` | cross-venue BTC GEX on one BTC axis | newer, math verified |
| `scripts/scenario/scenario.rb` | -1/0/+1 regime composite from 7 scored signals (+ 2 weight-0 modules) | mature |
| `scripts/scenario/positioning.rb` | crowd positioning: L/S ratios, OI trend, taker flow, liquidations | new; bands WARMUP until 91 days of history |
| `scripts/scenario/reserves.rb` | exchange BTC reserves: 30d delta vs its own trailing distribution | new (M11-7); ~676d of source history, bands live day one |
| `scripts/scorecard.rb` | track record: our published signals vs realized forward BTC returns | new, report-only |
| `scripts/lppl/lppl.rb` | LPPL regime verdict from 5 falsification tests | new but rigorous; builds caches on first run |
| `scripts/btco/btco.rb` | treasury-company metrics + stress score | **seed data is placeholder**; US quotes via CBOE + Frankfurter FX, non-US via `manual_px` |
| `scripts/btco/ingest.rb` | EDGAR filing -> reviewed universe updates | newest, lightly exercised |

Shared conventions: `--json` (machine output, frozen contract),
`--tmux` (one-line status to `/tmp/<name>.status`), fail-soft (a dead
data source reports score 0 and exits 0; in JSON it carries
`"unavailable": true`). Runtime data lives in `scripts/<suite>/data/`,
or `$BTC_DATA_DIR/<suite>/` if set.

## GEX tools

```
ruby scripts/gex.rb                        # Deribit BTC board
ruby scripts/gex.rb ETH --max-days 45      # ETH, near-dated only
ruby scripts/gex_us.rb IBIT MSTR           # US chains (15-min delayed)
ruby scripts/gex_btc_combined.rb           # Deribit + 9 spot-ETF chains
ruby scripts/gex_btc_combined.rb --bin 500 # finer BTC-axis buckets
```

All three: `--json`, `--tmux`, `--max-days N`. No keys needed.
`gex_us.rb --json` returns an object for one ticker, an array for
several. Failure mode: these abort with exit != 0 (no fail-soft) --
treat that as keep-last-good.

## Volatility & positioning tools (Phase 8A)

```
ruby scripts/vol.rb          # BTC vol surface: ATM IV, 25d RR, 25d fly (7/14/21/30/45/90d)
ruby scripts/vol_spread.rb   # MSTR-vs-BTC ATM IV spread per tenor
ruby scripts/basis.rb        # Deribit futures basis curve + OI-weighted funding
ruby scripts/gex_trend.rb    # time series over the daily GEX snapshots (local)
ruby scripts/gex_check.rb    # our walls/flip vs Coinglass Deribit max pain
```

All five: `--json` (frozen contracts). No keys needed except the
Coinglass legs (`basis.rb` funding, `gex_check.rb`) which read
`COINGLASS_API_KEY` and fail soft to a reasoned null section without
it. Everything here is DESCRIPTIVE -- no thresholds, no scores; the
25-delta points are nearest-strike (no interpolation) from BS delta
computed off Deribit's own mark IV; funding is percent per 8h
(verified against Binance). `gex_trend.rb` reads
`data/gex_history/`; the vol surface snapshots daily into
`data/vol_history/` via the same 08:15 agent. On the dashboard these
render as two cards -- a "Volatility" card (the surface tabbed
[BTC][MSTR] with the futures/funding basis stacked below) and a
separate MSTR-vs-BTC IV-spread card (the current spread with its trend
stacked beneath) -- plus [BTC TREND] and [MSTR TREND] tabs on the GEX
card. All live since the Phase 8 deploy.

## Scenario composite

```
ruby scripts/scenario/scenario.rb            # table + composite + regime
ruby scripts/scenario/scenario.rb --history  # also append data/history.jsonl
ruby scripts/scenario/etf_flows.rb           # any module runs standalone
```

Seven weighted signals (ETF flows, funding/basis, Coinbase premium,
macro liquidity, hash ribbons, MVRV, stablecoin supply) -> composite in
[-1, +1] -> FLUSH / LEAN-FLUSH / NEUTRAL / BASE / RECOVERY. The composite
is an evidence index (a bounded weighted vote read by band), not a
probability.

Two further modules ride the table at **weight 0** -- displayed,
never able to move the composite, each with pre-registered kill
criteria in its file header, both needing `COINGLASS_API_KEY` (fail
soft without it):

- `positioning.rb` (Phase 10): five crowd-positioning reads from
  Coinglass (daily, cached 24h): long/short account ratio, top-trader
  ratio, 7-day open-interest change, taker buy share, liquidation
  skew. Each band is the value's percentile in its own trailing 90
  days (80/20 cutoffs), so a sub-signal honestly reports WARMUP until
  91 daily values exist. Score -1 only on the full flush lineup
  (crowd LONG + OI RISING + longs liquidated), +1 on the exact
  mirror, else 0.
- `reserves.rb` (Phase 11, owner ruling R-11 2026-08-29): aggregate
  BTC sitting on the exchanges Coinglass tracks. Scores the 30-day
  percent change against its own trailing-90d distribution (80/20):
  +1 when coins drain to self-custody unusually fast, -1 when
  sellable supply builds unusually fast. The delta is
  window-consistent across exchange delistings (a dead venue can
  never fake a drain), and the source serves ~676 days of history, so
  the bands are real from day one. Its reserves curve draws on the
  positioning card's OI panel (right axis).
`macro.rb` needs a free `FRED_API_KEY` (degrades to score 0 without).
`etf_flows.rb` scrapes farside.co.uk, falling back to the Internet
Archive snapshot and then CoinGlass (`COINGLASS_API_KEY`, free) -- see
the source-chain note in the script header. Its history entries before
2026-07-04 are unreliable: the old parser reported day-of-month numbers
as daily totals (internal review finding F-22).
Everything else is keyless public APIs; `etf_flows` is the one HTML
scrape (degrades gracefully on layout drift).

## LPPL suite

```
ruby scripts/lppl/lppl.rb                  # update prices, run 5 tests, verdict
ruby scripts/lppl/lppl.rb --skip-update    # offline, cached prices
ruby scripts/lppl/lppl.rb --history        # also append ledger + fit history
ruby scripts/lppl/lppl.rb --as-of 2026-05-01  # replay: verdict as of that day
ruby scripts/lppl/trend.rb                 # any test standalone
ruby scripts/lppl/logperiodic.rb --sims 500  # more bootstrap sims
rake lppl:backfill                         # staged ledger rebuild from the cycle peak
rake lppl:backfill_diff                    # staged-vs-live verification report
rake lppl:promote                          # OWNER, interactive: promote staged history
```

Five tests (out-of-sample trend predictive-score differential, damping
envelope, LPPLS anti-bubble fit, Lomb-Scargle oscillation significance,
valuation percentile monitor) -> REGIME-INTACT ... FALSIFIED verdict.
The verdict rides a composite that is an evidence index (a bounded
weighted vote read by band), not a probability. First run downloads full
BTC price history and bootstraps a score cache (takes a minute or two);
daily runs are incremental. Keyless.

`--as-of YYYY-MM-DD` computes the verdict exactly as a live run on
that day would have, from the price cache alone: prices truncated to
the day before, wall clock frozen, score/fit caches read-filtered,
nothing written unless `--history` is also given (and `--tmux` is
refused so a replay can never clobber the live status token).
`rake lppl:backfill` chains replays day-by-day from the Oct-2025
cycle peak into `data/lppl_backfill_staging/` (resumable, ~3 s/day,
never touches live data); `rake lppl:backfill_diff` verifies the
staged history against the organically recorded days field-by-field.
`rake lppl:promote` performs the one-shot write into the live ledger
and fit history (diff, one prompt, timestamped backups) -- it is
interactive-only (refuses CI and non-TTY), a deliberate human step.

The Phase-9 shadow soak concluded with the 2026-08-29 owner rulings:
four shadow statistics ARE now the headlines -- the trend test reads
the density-invariant per-evaluation MEAN differential (with a
Newey-West error bar) instead of the cache-density-dependent sum; the
fit's improvement figure is the fair symmetric-null measurement; the
oscillation p-value (headline AND score) comes from the realistic
AR(1)+GARCH bootstrap; and the envelope's bound/floor are FROZEN
per-trough measurements the daily re-fit can no longer drag around.
Every demoted number stays as a reference field. The dashboard's
**SHADOW** tab now reads reference -> operative per row (hover for
the story); two checks remain deliberately report-only -- the
1y/2y horizons (await a backtest) and the damping condition (awaits a
longer soak).

## BTCo treasury analyser — FROZEN

**Development stopped 2026-08-10 (owner ruling), pending a rethink.**
The tools below still run and the dashboard table still renders, but
the data is no longer maintained: rows go STALE as their as-of dates
age, and no new filings are ingested. Do not trust the numbers for
anything current.

```
export EDGAR_UA='name email'          # SEC-required identifying UA
ruby scripts/btco/btco.rb             # metrics table + stress score
ruby scripts/btco/btco.rb --check-filings  # what changed since my as-of dates?
ruby scripts/btco/ingest.rb           # discover + analyse new filings
ruby scripts/btco/ingest.rb --review  # inspect proposals, then --apply <acc>
```

```
ruby scripts/btco/ingest.rb --baseline XXI  # AI+web ground truth -> proposal
ruby scripts/btco/validate.rb               # reconcile vs external researchers
```

Fundamentals live in `scripts/btco/universe.json`. **As of 2026-07-10
all 8 entries are real, baselined data** (the placeholder-seed era is
over) maintained under a two-regime process (owner-ruled, M7-16):

- **Baseline** (`--baseline T`): an AI research session with web
  search establishes the company's CURRENT ground truth -- every field
  with its own value, as-of date, and source -- as ONE reviewed
  proposal whose apply REPLACES the entry. This is how state is
  ESTABLISHED (needs `ANTHROPIC_API_KEY`).
- **Increment** (`ingest.rb` discovery / `--file` / `--tracker`):
  filings and feeds propose changes that must BEAT the model's
  per-field as-of dates (the freshness gate) and pass a
  duplicate-instrument guard -- fresh info lands, stale data bounces.
  Claude extraction when `ANTHROPIC_API_KEY` is set (model override
  `BTCO_MODEL`), regex heuristics at low confidence otherwise.

Nothing touches `universe.json` except an explicit `--apply`; every
applied change is ledgered in `capstruct/<TICKER>.jsonl`. `--review`
cross-checks each proposal against independent references
(bitcointreasuries + CoinGecko BTC counts, SEC XBRL cover-page share
counts) and prints paste-ready apply/dismiss commands.
`validate.rb` is the standing objective audit: it reconciles the
PUBLISHED dashboard row against StrategyTracker's mNAV (decomposed
into the four inputs so the divergent one is NAMED), flags count
divergence vs every ref, and prints plain-words to-dos per ticker.

Prices/FX/BTC spot are fetched live: US listings via CBOE delayed
quotes, FX via Frankfurter/ECB, BTC via the Deribit index. Known gap:
Metaplanet (3350) has real data but NO dashboard row until its price
source is decided (D8-f -- stooq died upstream, F-17; `manual_px` or
tracker-priced).

## Signal scorecard

```
ruby scripts/scorecard.rb           # track-record table
ruby scripts/scorecard.rb --json    # machine output (frozen contract)
```

Scores our own published signals against the BTC returns that actually
followed (7/30/90-day horizons) from the recorded ledgers -- LPPL back
to 2025-10, scenario history, daily GEX snapshots. For each signal
band: n, mean forward return, share of positive outcomes, next to the
same-window unconditional row as the benchmark. Deliberately modest:
no significance verdicts, no declared "right" direction per band, and
a cell renders only with n >= 30 over a span >= twice the horizon --
short ledgers show an explicit "n too small". Daily h-day returns
overlap, so `n_eff ~ n/h` in the JSON is the honest evidence count.
Definitions are the D10-a owner ruling; the engine is
`lib/btc/scorecard.rb`.

## Publish pipeline (dry-run today; real publish is a human action)

```
PUBLISH_DRY_RUN=1 ruby publish/publish.rb   # DEFAULT: artifact set -> data/publish_preview/
PUBLISH_DRY_RUN=0 ruby publish/publish.rb   # KV PUTs; needs CLOUDFLARE_ACCOUNT_ID/CLOUDFLARE_KV_NAMESPACE_ID/CLOUDFLARE_API_TOKEN
```

Runs the fourteen producers (the four suites, MSTR dealer gamma, the
five Phase-8A volatility tools, the positioning and reserves modules,
and the scorecard), wraps every payload in the frozen envelope
(`v/key/generated_at/ttl_hint_s/source/payload`), adds trailing
history windows (scenario 90d, lppl 365d) and a `v1:index`, and writes
files (dry) or Cloudflare KV keys (real). A producer that crashes or
prints garbage is skipped -- keep-last-good, never publish junk; a
fail-soft suite publishes its honest `unavailable` state. Status line:
`/tmp/publish.status`. Real mode is live (first publish at Gate 2,
2026-07-04; `rake deploy` also runs one so a deploy never leaves stale
data). Scheduled freshness is the Phase 5 ops layer: a prepared launchd
agent runs the publisher bi-hourly once the owner installs it per
`docs/RUNBOOK.md`; until then, between-deploy freshness is a manual
`PUBLISH_DRY_RUN=0` run. Retries are bounded and error paths never
carry the token or payloads.

## Chart specs + offline preview

The publish run also builds fifteen pre-rendered chart specs under
`v1:chart:` (`gex_btc / gex_mstr / gex_btc_trend / gex_mstr_trend /
scenario_strip / scorecard / positioning / lppl_regime / lppl_shadow /
btco_table / vol_surface / vol_surface_mstr / vol_spread /
vol_spread_trend / vol_basis`) --
each payload is a complete ECharts option the dashboard renders with
one `setOption` call. Review them offline:

```
PUBLISH_DRY_RUN=1 ruby publish/publish.rb   # fresh artifact set
rake preview                                # stdlib server, localhost:8000
open http://localhost:8000/web/preview.html # all chart specs, side by side
open http://localhost:8000/web/index.html   # the production dashboard, same data
```

`rake preview` (localhost-only stdlib server) reviews **both** pages
offline against `data/publish_preview/`: `preview.html` (the raw chart
specs) and `index.html` (the production dashboard -- the server shims
`/api/v1/:key` and `/healthz` so the same-origin loader works with no
Worker). Chart output is pinned by golden files (`test/golden/`)
regenerated deterministically from committed payload fixtures; a red
golden diff is presented for review and re-blessed only via `rake
golden:approve` after looking at the rendered result. ECharts loads from
one pinned CDN tag with an SRI integrity hash (drift caught offline by
`rake health`). Known v1 presentation choices: the LPPL chart plots the
evidence ledger (a published price-vs-trend panel would need a new data
key -- deferred), and the dashboard shows the BTCo view as labeled bars +
stress gauge plus a literal sortable table beneath.

## Cloudflare layer (Worker API + dashboard)

The presentation layer is a dumb, always-up Cloudflare front end: Ruby
publishes JSON envelopes to a KV namespace, a Worker serves them, and a
static dashboard renders the pre-built chart specs.

- **Worker API** (`web/worker.mjs`): `GET /api/v1/:key` returns the KV
  envelope verbatim (`Cache-Control: public, max-age=60`,
  `X-Generated-At`, `X-Data-Age-Seconds`); `404` on an unknown/malformed
  key; `GET /healthz` -> `{ok:true,...}`. Public-read at v1 (owner ruling
  D4-c); a dormant `AUTH_TOKEN` bearer branch activates with one
  `wrangler secret put` and no code change. Tested with the node built-in
  runner (`rake web:test`, zero npm).
- **Dashboard** (`web/index.html` + shared `web/render.js`): a same-origin
  loader over the Worker -- per-key dot badges, live age tickers (each
  dot ticks up second-by-second and recolours green/amber/red from each
  envelope's `generated_at`/`ttl_hint_s`), a healthz-aware failure banner,
  the chart cards in a three-row grid (row 1 GEX / Volatility /
  IV-spread, row 2 Scenario / Positioning / LPPL, row 3 BTCo; the
  GEX card is [BTC][MSTR][BTC TREND][MSTR TREND] tabs, the scenario
  card [SCENARIO][SCORES] -- the signal scorecard rides the card it
  audits -- the LPPL card [LPPL][SHADOW], volatility is a
  surface+basis card), and the BTCo sortable table. The staleness badges are dot-only
  (hover a dot for its key and last publish time); legend terms (CW/PW,
  ATM IV, RR25) and the scenario module names carry the same hover
  glossary explanations.
- **Deploy** (`rake deploy`, **owner-run**): pre-flight (wrangler + CF_*
  env + clean tree + green gate), generate the live `wrangler.toml` from
  the committed template with the namespace id from `CLOUDFLARE_KV_NAMESPACE_ID`,
  `wrangler deploy`, then smoke-probe the live host (healthz, index, a 404
  path). Deploys are **human actions** (Golden Rule 3): the task refuses
  under CI and is deny-listed for the automation loop.

```
DEPLOY_DRY_RUN=1 rake deploy   # assemble + print the would-run command, deploy nothing
rake deploy                    # OWNER-RUN: pre-flight -> deploy -> smoke
```

Full instructions -- first-time Cloudflare setup, the Gate 4 smoke
checklist, rollback, and AUTH_TOKEN activation -- are in
[docs/DEPLOY.md](docs/DEPLOY.md). The same deploy ships the dashboard:
`wrangler.toml`'s `[assets]` block serves `web/` on the Worker's own
host, so there is no separate Pages step and the API is same-origin by
construction.

## Ops layer (installed on gold since 2026-07-08; 3 launchd agents)

Three managed agents run unattended: `com.mimir.publish` (bi-hourly
live publisher), `com.mimir.gex-snapshot` (08:15, dated archive of both
GEX outputs -- options data cannot be backfilled), and
`com.mimir.suite-history` (06:45, the daily lppl/scenario `--history`
appends -- content freshness, guarded by the `PUB! ... OLD` flag when
published tails stop moving >30h). (`com.mimir.btco-alert` was retired
2026-08-10 when BTCo froze.) Status surfaces: the tmux one-liner
(`publish_health.rb`: green fresh / yellow amber / red stale / OLD
content-stall / `PUB ?` fail-soft). `rake health` audits everything
offline. Installation on a NEW box stays an owner action (Golden Rule
3) via the interactive tasks: `rake ops:install` / `ops:status` /
`ops:uninstall` (TTY-gated, refuse under CI) + `rake ops:tmux` for the
status-bar token. Procedures: `docs/RUNBOOK.md`.

Runtime separation (M9-12). The agents do NOT run from your dev folder.
`rake deploy` keeps an app-managed copy of the code at
`~/Library/Application Support/mimir/live` -- a plain clone parked on the
deployed commit (refreshed each deploy; refuses if the commit isn't
pushed) -- and all runtime data lives under
`~/Library/Application Support/mimir/data` (the agents' `BTC_DATA_DIR`).
So your `~/Dev/mimir` is an ordinary git checkout: switch branches, run
tests, leave it dirty -- production is untouched. The one-time
`rake ops:install` prints a migration inventory and copies existing
histories from the dev tree into the data home, then renders the launchd
plists to point at the live copy. Until you run that install, the agents
keep running exactly as before -- the switch is atomic at install.

Data-integrity guard (M8-8/9/10, after the 2026-07-13 blind-zero
incident). Corrupted daily artifacts are marked at write time: a
scenario history row with zero live modules gets `blind: true` (a
partial degradation lists the down modules); an lppl ledger row whose
price cache never reached yesterday gets `stale_input: true`; a GEX/vol
snapshot with a non-empty errors map is retryable that same day.
`ops/repair.rb`, run by the publish wrapper just before every bi-hourly
publish, re-runs today's producers when the sources answer again and
rewrites today's marked row / re-captures its snapshot in place (older
damage is a permanent, marked gap -- never touched). If a row is still
marked after repair, the publish status line carries `BLIND:scenario` /
`BLIND:lppl` (surfaced by the tmux monitor beside `OLD`) and the
scenario strip greys that day's point so a data outage never reads as a
real neutral day.

## Not implemented yet (roadmap in ARCHITECTURE.md)

- The model has no `cash` / non-BTC-business fields, so mNAV for
  diversified holders (DJT, BLSH, miners) overstates richness by
  construction -- the M7-15b research question.
- Remaining proposal-pool candidates (owner-approved waves,
  .docs/DEV-PROPOSALS.md; family A -- vol surface, basis, GEX history,
  max-pain cross-check, IV spread -- shipped 2026-07-10/11 as the
  tools above; positioning + the signal scorecard shipped in Phase
  10; exchange reserves shipped in Phase 11): CFTC COT, Kalshi
  implied probabilities, bubble-index cross-ref, ntfy push alerts,
  deterministic filing-iXBRL parser (M7-13). Scenario history
  seeding/replay.
- IV rank / percentiles on the vol card: needs weeks of
  `data/vol_history/` accumulation first (snapshotting has been active
  since Gate 8; the ranks become buildable once enough days accrue).
- Queue-tail hardening: Cloudflare Access (email OTP / service tokens)
  in front of the Worker host -- console work, post-v1.

## Development

```
rake                 # compat + health (offline) + tests -- the pre-commit gate
rake test:unit       # just the unit tests
rake test:contract   # --json/--tmux field-set contracts (offline, vs fixtures)
rake fixtures:record # re-record live API fixtures (NETWORK -- prints verify digest)
rake fixtures:verify # offline digest + safety checks (leaks, drift, aging) -- in the default gate
rake health:sources  # probe all upstream data sources (network, read-only)
```

Every tool's `--json` and `--tmux` output is a frozen contract, pinned
by `test/contract/`: the real scripts run offline as subprocesses
against recorded fixtures (`test/fixtures/`, provenance in its README)
with a fake HTTP transport and the clock frozen to the recording day.
Changing an output field set, a status-line format, or the ingest
extraction prompt fails the suite unless the matching contract test
changes in the same commit. A few pins skip themselves until fixtures
recorded before a recorder fix are refreshed (`rake fixtures:record`,
network, owner-run); the skip messages say exactly which.

Read `docs/METHODOLOGY.md` (how to interpret the outputs), `CLAUDE.md`
(ground rules), `ARCHITECTURE.md` (design + phases), `docs/RUNBOOK.md`
(operate the box: launchd agents, tmux health line, rotate token /
recover from stale). Internal process documents (dev loop, backlog,
worklog, proposals, gate runbooks) live in the gitignored `.docs/` on
the development machine and are not part of the repository.
ENV reference: `.env.example`.
