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
| `scripts/scenario/scenario.rb` | -1/0/+1 regime composite from 7 signals | mature |
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

## Scenario composite

```
ruby scripts/scenario/scenario.rb            # table + composite + regime
ruby scripts/scenario/scenario.rb --history  # also append data/history.jsonl
ruby scripts/scenario/etf_flows.rb           # any module runs standalone
```

Seven weighted signals (ETF flows, funding/basis, Coinbase premium,
macro liquidity, hash ribbons, MVRV, stablecoin supply) -> composite in
[-1, +1] -> FLUSH / LEAN-FLUSH / NEUTRAL / BASE / RECOVERY.
`macro.rb` needs a free `FRED_API_KEY` (degrades to score 0 without).
`etf_flows.rb` scrapes farside.co.uk, falling back to the Internet
Archive snapshot and then CoinGlass (`COINGLASS_API_KEY`, free) -- see
the source-chain note in the script header. Its history entries before
2026-07-04 are unreliable: the old parser reported day-of-month numbers
as daily totals (TOOL-REVIEW.md F-22).
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

Five tests (out-of-sample trend Bayes factor, damping envelope, LPPLS
anti-bubble fit, Lomb-Scargle oscillation significance, valuation
percentile monitor) -> REGIME-INTACT ... FALSIFIED verdict. First run
downloads full BTC price history and bootstraps a score cache (takes a
minute or two); daily runs are incremental. Keyless.

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

## BTCo treasury analyser

```
export EDGAR_UA='name email'          # SEC-required identifying UA
ruby scripts/btco/btco.rb             # metrics table + stress score
ruby scripts/btco/btco.rb --check-filings  # what changed since my as-of dates?
ruby scripts/btco/ingest.rb           # discover + analyse new filings
ruby scripts/btco/ingest.rb --review  # inspect proposals, then --apply <acc>
```

Fundamentals live in `scripts/btco/universe.json` (human-maintained,
per-field as-of dates); only prices/FX/BTC spot are fetched live: US
listings via CBOE delayed quotes, FX via Frankfurter/ECB, BTC via the
Deribit index. Non-US listings (Metaplanet) price via `manual_px`
only. (Stooq served quotes+FX until its API died upstream 2026-07 --
TOOL-REVIEW.md F-17.)
**Every shipped universe entry is `placeholder: true` seed data --
update via ingest before the numbers mean anything.** `ingest.rb` with
`ANTHROPIC_API_KEY` set uses Claude extraction (model override:
`BTCO_MODEL`); without it, regex heuristics at low confidence. Nothing
touches `universe.json` except an explicit `--apply`; applied changes
are ledgered in `capstruct/<TICKER>.jsonl`.

## Publish pipeline (dry-run today; real publish is a human action)

```
PUBLISH_DRY_RUN=1 ruby publish/publish.rb   # DEFAULT: artifact set -> data/publish_preview/
PUBLISH_DRY_RUN=0 ruby publish/publish.rb   # KV PUTs; needs CLOUDFLARE_ACCOUNT_ID/CLOUDFLARE_KV_NAMESPACE_ID/CLOUDFLARE_API_TOKEN
```

Runs the five producers (the four suites plus MSTR dealer gamma via
`gex_us.rb`), wraps every payload in the frozen envelope
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

The publish run also builds five pre-rendered chart specs
(`v1:chart:gex_profile / gex_mstr / scenario_strip / lppl_regime /
btco_table`) --
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
  loader over the Worker -- per-key chips, live age tickers (the badge
  ticks up second-by-second and recolours green/amber/red from each
  envelope's `generated_at`/`ttl_hint_s`), a healthz-aware failure banner,
  the chart cards in a 2x2 grid (the two GEX charts share one card as
  [BTC][MSTR] tabs), and the BTCo sortable table.
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

## Ops layer (Phase 5 -- prepared, installation is an owner action)

Everything under `ops/` is ready to run but deliberately NOT installed
by tooling (Golden Rule 3): `run_publish.sh` + `com.mimir.publish.plist`
(bi-hourly live publisher), `gex_snapshot.rb` + wrapper + daily plist
(dated local archive of both GEX `--json` outputs under
`data/gex_history/` -- options data cannot be backfilled), and
`publish_health.rb` (tmux status-right one-liner: green fresh / yellow
amber-or-partial / red stale / `PUB ?` fail-soft). `rake health` audits
all of it offline (shell syntax, plist keys, the --apply ban). The owner
drives it with three interactive tasks (owner-run only -- they refuse
under CI and without a TTY, Golden Rule 3): `rake ops:install` (pre-flight,
render + bootstrap both agents, optional kickstart with a polled PASS/FAIL
table), `rake ops:status` (agent state, log markers, status-file age,
newest snapshot), `rake ops:uninstall` (confirm, bootout, remove plists).
Install/operate/recover procedures: `docs/RUNBOOK.md`.

## Not implemented yet (roadmap in ARCHITECTURE.md)

- BTCo universe is still placeholder seed data; Phase 7 (ingest
  shakedown + owner-applied proposals) replaces it with filing-derived
  values and adds a daily new-filing discovery alert. Until then the
  BTCo card's numbers carry `placeholder` flags and a ~year-old as-of.
- The LIVE LPPL ledger still starts 2026-07-04 until the owner runs
  the Gate 6 promotion (`rake lppl:promote`): the full Oct-2025-peak
  replay history is already staged and verified. Scenario history
  still starts 2026-07-04 (no replay mode; source-dependent seeding is
  Phase 8).
- Coinglass integration (docs/improvements.md), scenario v2 hypothesis
  modules (docs/scenario_upgrades.md), dashboard round 2 -- Phases 8-10.
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
(ground rules), `ARCHITECTURE.md` (design + phases), `docs/DEV-LOOP.md`
(how this gets built), `docs/TOOL-REVIEW.md` (per-tool audit),
`docs/BACKLOG.md` (work state), `docs/RUNBOOK.md` (operate the box:
launchd agents, tmux health line, rotate token / recover from stale).
ENV reference: `.env.example`.
