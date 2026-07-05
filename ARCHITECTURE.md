# ARCHITECTURE.md -- mimir

Mimir is Norse god-keeper of the well of wisdom, apt for a system that extracts wisdom from costly, accumulated evidenc. This is a framework and visual analytics platform for the BTC price toolkits (GEX, scenario signals, LPPL evidence suite). Compute stays Ruby on the local mesh; Cloudflare is a dumb, fast, always-up presentation layer.

## 1. Principles

1. **Ruby computes, Cloudflare serves.** No Ruby on Workers, no analytics in JS. The browser renders pre-built chart specs; it makes no decisions.
2. **Ruby 3.3+ / stdlib-only for everything under `scripts/`, `lib/`,
   `publish/`.** Target machines are Apple Silicon Macs (arm64-darwin)
   with a modern Ruby; CI runs 3.3. Stay within the 3.3 feature set so
   CI and every target Mac agree. stdlib-only is the hard rule: no gems,
   no Gemfile for runtime.
3. **Stale, never down.** Publishers stamp `generated_at`; the Worker adds
   `X-Data-Age-Seconds`; every chart shows a staleness badge. The dashboard
   must remain correct-and-honest when the Macs sleep.
4. **Existing scripts are production.** They keep working unchanged from
   cron/tmux throughout. Refactors are behavior-preserving with
   characterization tests written first; `--json` and `--tmux` outputs are
   frozen public contracts.
5. **Analytics decisions are research decisions.** Scoring thresholds,
   model weights, filter bands, and probability mappings are never changed
   as a side effect of engineering work.

## 2. System overview

```
novo (launchd/cron, Ruby 3.3+, arm64)
  scripts/gex_btc_combined.rb --json     15-30 min   ─┐
  scripts/scenario/scenario.rb --json    30 min       ├─> publish/publish.rb
  scripts/lppl/lppl.rb --json --history  daily 00:15  │
  scripts/btco/btco.rb --json            hourly      ─┘        │
  scripts/btco/ingest.rb                 daily, human-reviewed │ HTTPS PUT
Cloudflare                                                     ▼ (stdlib Net::HTTP)
  KV namespace   MIMIR   small JSON values, key-per-artifact
  Worker         GET /api/:key -> KV; cache + staleness headers; auth;
                 serves web/ as static assets on the same host (amended
                 at Gate 4, 2026-07-05: replaces the separate Pages step)
  Access (opt)   Zero Trust gate (email OTP / service token; no Google dep)
```

Charts are **ECharts option objects generated in Ruby**
(`publish/chart_specs.rb`) and stored in KV as JSON. The frontend is a
~30-line generic loop: `fetch('/api/'+key)` -> `echarts.setOption(spec)`.
All visualization logic (series, bands, markLines, colors, thresholds)
lives in Ruby next to the analytics. ECharts loads from a pinned CDN
script tag; there is **no npm build step**.

## 3. Repository layout

```
mimir/
  README.md                  user-facing capabilities + commands, updated
                             at every gate (honest about what works today)
  ARCHITECTURE.md            this file
  CLAUDE.md                  Claude Code project instructions
  docs/DEV-LOOP.md           how the implementation loop runs (stages,
                             model tiering, gates)
  Rakefile                   test / lint / compat / fixture tasks
  .gitignore                 data dirs, secrets, *.status
  .env.example               required environment variables
  scripts/                   EXISTING TOOLS, imported as-is
    gex.rb  gex_us.rb  gex_btc_combined.rb
    scenario/   (common.rb, 7 modules, scenario.rb, README.md)
    lppl/       (common.rb, prices.rb, 5 tests, lppl.rb, README.md)
    btco/       (btco.rb, ingest.rb, universe.json, capstruct/)
  lib/                       shared code (seams + extracted duplicates)
    btc/http.rb              single HTTP seam (injectable for tests)
    btc/env.rb               ENV access, data-dir resolution
    btc/options.rb           options math + instrument parsing (gex family)
    btc/report.rb            suite module report/fail_soft contract
    btc/util.rb              tiny CLI helpers
  publish/
    kv_client.rb             Cloudflare KV REST client (PUT/GET, retries)
    chart_specs.rb           ECharts option builders (pure functions)
    publish.rb               orchestrator: run/read suites -> envelope -> KV
  web/
    wrangler.toml            Worker + KV binding config
    worker.js                ~40 lines: route, KV read, headers, auth
    public/index.html        dashboard shell
    public/app.js            generic spec loader + staleness badges
    preview.html             offline harness: renders specs from local files
  test/
    test_helper.rb           minitest bootstrap (stdlib), fixture helpers
    unit/                    pure-function tests (math, parsing, specs)
    contract/                --json field-set contracts per module
    golden/                  approved chart-spec JSON (rake golden:approve)
    fixtures/                recorded API responses (rake fixtures:record)
  data/                      runtime artifacts (gitignored)
```

`scripts/` keeps its internal `data/` dirs by default (behavior-preserving);
the `BTC_DATA_DIR` override (implemented Phase 0) routes all runtime
artifacts to `$BTC_DATA_DIR/<suite>/` so a checkout stays clean. Status
lines stay in /tmp (tmux-facing); btco's `capstruct/` is a committed
audit trail, not runtime data.

## 4. Data contracts

### 4.1 KV keys (versioned, flat)

| key                      | producer                    | cadence  | ~size |
|--------------------------|-----------------------------|----------|-------|
| v1:index                 | publish.rb                  | each run | <1 KB |
| v1:gex:combined          | gex_btc_combined.rb --json  | 15-30 m  | 4 KB  |
| v1:scenario:latest       | scenario.rb --json          | 30 m     | 2 KB  |
| v1:scenario:history      | tail(90d) of history jsonl  | 30 m     | 20 KB |
| v1:lppl:latest           | lppl.rb --json              | daily    | 3 KB  |
| v1:lppl:ledger           | tail(365d) of ledger.jsonl  | daily    | 40 KB |
| v1:btco:latest           | btco.rb --json              | hourly   | 4 KB  |
| v1:chart:gex_profile     | chart_specs.rb              | w/ gex   | 8 KB  |
| v1:chart:scenario_strip  | chart_specs.rb              | w/ scn   | 6 KB  |
| v1:chart:lppl_regime     | chart_specs.rb              | daily    | 15 KB |
| v1:chart:btco_table      | chart_specs.rb              | w/ btco  | 6 KB  |

Full ledgers/history stay local (backtest data); only trailing windows are
published.

### 4.2 Envelope (every KV value)

```json
{ "v": 1, "key": "gex:combined", "generated_at": "2026-07-02T12:04:11Z",
  "ttl_hint_s": 1800, "source": "novo", "payload": { } }
```

`ttl_hint_s` drives the staleness badge: age <= ttl -> green,
<= 3x -> amber, else red. `v1:index` lists all keys with their
`generated_at` so the dashboard renders health at a glance.

### 4.3 Worker API

```
GET /api/v1/:key      -> envelope JSON
    200: Cache-Control: public, max-age=60
         X-Generated-At, X-Data-Age-Seconds
    404: unknown key   401: bad/missing bearer (when AUTH_TOKEN set)
GET /healthz          -> { ok: true, worker_ts: ... }
```

Auth: optional static bearer (`AUTH_TOKEN` Worker secret) and/or
Cloudflare Access in front of Pages+Worker. No cookies, no Google.

### 4.4 Script contracts (frozen)

Every analytics module keeps: `--json` single-object output with a stable
field set (documented per module in `test/contract/`), `--tmux` one-line
status write, exit 0 with score 0 on data-source failure (fail-soft).
Contract tests assert field presence/types, not values.

### 4.5 BTCo capital-structure store (scripts/btco/)

`universe.json` is the canonical current model per company; it changes
ONLY via `ingest.rb`'s propose -> human review -> apply pipeline (or a
deliberate manual edit). Discovery dedupes against `capstruct/state.json`
(seen accessions + fixed per-ticker floor) AND the applied ledger
`capstruct/<TICKER>.jsonl`, so state is disposable and applied history is
authoritative. AI extraction (Claude API, strict-JSON schema) proposes;
it never applies. Git policy: commit `universe.json` and the ledgers
(audit trail); ignore `capstruct/pending/`, `capstruct/state.json`, and
`universe.json.bak-*` (runtime). Changes to the extraction prompt/schema
are contract changes (Golden Rule 5 in CLAUDE.md applies).

## 5. Environment

```
CLOUDFLARE_ACCOUNT_ID        Cloudflare account
CLOUDFLARE_KV_NAMESPACE_ID   KV namespace for MIMIR
CLOUDFLARE_API_TOKEN         ONE token, both jobs (owner ruling, Gate 4):
                             Workers KV write + Workers Scripts edit;
                             shared by publisher and wrangler
FRED_API_KEY         (existing, scenario/macro.rb)
EDGAR_UA             'name email' -- SEC-required identifying UA (btco)
ANTHROPIC_API_KEY    Claude API for ingest.rb extraction (optional;
                     heuristic fallback without it)
BTCO_MODEL           extraction model override (default claude-sonnet-4-6)
BTC_DATA_DIR         optional data-dir override ($BTC_DATA_DIR/<suite>/)
PUBLISH_DRY_RUN=1    write artifacts to data/publish_preview/, no network
```

Secrets live in `~/.config/mimir/env` sourced by cron, never in
the repo. `.env.example` documents names only.

## 6. Implementation phases

Each phase ends at a **review gate**: work stops, a summary of diffs +
test evidence is produced, `README.md` is brought up to date (what the
tools can do today, honestly), and a human approves before the next
phase. Deploy-touching steps are always executed by the human, never by
tooling.

Phases 0-1 are **Stage 0: legacy hardening** (see docs/DEV-LOOP.md).
The existing tools grew without TDD and some are new and barely used;
they are inventoried, documented, fully tested, reviewed, and refactored
BEFORE any new feature work. Stage 0 runs interactively with the owner.

### Phase 0 -- inventory, documentation + safety net
- Import `scripts/` as-is; add Rakefile, .gitignore, .env.example,
  test harness. (done)
- **Tool inventory & review memo**: per tool -- what it does, data
  sources, output contracts, maturity assessment (battle-tested vs new
  and barely used), suspected weak spots, refactor candidates. Reviewed
  with the owner; the agreed findings seed Phase 1's refactor list.
- **README.md v1**: user-facing capabilities + commands as they exist
  today, honest about maturity per tool.
- Full offline test suite for pure logic: `RangeReg` (incl. SSE
  identity), `gauss_solve`, `bs_gamma` (known values, put/call
  symmetry), OSI/Deribit instrument parsing, percentile envelope fit,
  Lomb-Scargle on a synthetic sinusoid; btco metrics math (CEBE / mNAV /
  convert ITM-OTM treatment on a synthetic universe) and ingest pure
  parts (`excerpt` windowing, `diff_against`).
- `rake compat` (`ruby -c` per file) and `rake test` green.
- **Gate 0:** all scripts still run byte-identically (`--json` diff against
  pre-import captures); review memo accepted; README v1 accepted.

### Phase 1 -- seams, contracts + reviewed refactoring
- `lib/btc/http.rb` seam + all call-site migration: delivered early in
  Phase 0 (F-13). Remaining here: fixtures recorded via
  `rake fixtures:record` (network task, run manually).
- Contract tests in `test/contract/` for every module's `--json`,
  including btco.rb, plus the ingest proposal schema (extraction JSON
  shape + diff computation on fixture excerpts; no live API calls).
- **Refactor pass** from the Phase 0 review memo: owner-approved list
  only; behavior-preserving, characterization tests first; duplication
  across the disparate tools consolidated into `lib/`. Bugs found are
  decision items (a fix changes published behavior), never silent.
- Optional `BTC_DATA_DIR` (delivered early in Phase 0, F-8).
- **Gate 1:** field-set diff empty for all modules; cron behavior
  unchanged; refactor list fully resolved (done or explicitly deferred).
  Legacy code is now in good shape -- new feature work may begin.

### Phase 2 -- publish pipeline
- `publish/kv_client.rb`: PUT/GET against the KV REST API, bearer auth,
  bounded retries, never logs token or payload bodies.
- `publish/publish.rb`: runs (or reads freshest outputs of) the four
  suites, wraps envelopes, writes `v1:*` keys + `v1:index`, emits
  `/tmp/publish.status`. `PUBLISH_DRY_RUN=1` is the default until Gate 2.
- Tests: envelope construction, ttl hints, retry/backoff, dry-run file
  layout, secret-redaction in error paths (fixture-driven, zero network).
- **Gate 2:** human reviews a dry-run artifact set, creates the KV
  namespace + token (manual, dashboard or wrangler), runs first real
  publish by hand.

### Phase 3 -- chart specs
- `publish/chart_specs.rb`, pure functions `payload -> ECharts option`:
  1. `gex_profile`: per-strike bars (put/call split), flip + wall
     markLines, per-venue toggle, BTC axis.
  2. `scenario_strip`: composite time series from history tail + current
     module score heat-strip.
  3. `lppl_regime`: log price vs trend + damping envelope bands, trough
     projection marker, BF sparkline, percentile/Z panel.
  4. `btco_table`: universe table (sortable columns via ECharts dataset)
     + stress gauge; STALE/placeholder rows visually flagged.
- Golden-file tests: generated spec JSON diffed against
  `test/golden/*.json`; updates only via explicit `rake golden:approve`.
- `web/preview.html` renders specs from `data/publish_preview/` for
  offline visual review.
- **Gate 3:** visual review in preview harness; goldens approved.

### Phase 4 -- Cloudflare layer
- `web/worker.mjs` + `wrangler.toml` (KV binding + `[assets]` serving
  `web/` on the same host -- amended at Gate 4, 2026-07-05: one deploy,
  same-origin by construction, no Pages project), dashboard loader with
  staleness badges, `/healthz`.
- JS stays dumb and dependency-free; ECharts pinned by version + SRI hash.
- **Gate 4:** human runs `rake deploy` (owner-run wrapper; loop/CI
  refused); smoke checklist (all keys 200, ages sane, 404/401 paths,
  badge behavior with a stale key) -- docs/DEPLOY.md.

### Phase 5 -- ops integration
- launchd/cron entries on novo (publisher after each suite run, btco.rb
  hourly; ingest.rb runs daily in discovery mode with proposals reviewed
  manually -- applying is never scheduled), publish health line in tmux
  bar, runbook in `docs/RUNBOOK.md` (rotate token, re-create namespace,
  purge key, recover from stale-everything).
- **Gate 5:** one-week soak; review KV free-tier usage (writes/day well
  under limits at stated cadences), staleness incidents, then tag v1.

### Phase 6 (optional, deferred decision)
- `cloudflared` Tunnel + Sinatra on nero for interactive drill-downs
  (ledger explorer, per-venue GEX slices). Separate design note when/if
  wanted; nothing in Phases 0-5 depends on it.

## 7. Testing strategy summary

| layer               | technique                          | network |
|---------------------|------------------------------------|---------|
| math/parsing        | minitest unit, exact values        | no      |
| module `--json`     | contract tests on fixtures         | no      |
| chart specs         | golden files + preview harness     | no      |
| kv client           | fake transport, error injection    | no      |
| fixtures refresh    | `rake fixtures:record` (manual)    | yes     |
| deploy smoke        | human checklist at Gate 4/5        | yes     |

minitest ships bundled with Ruby: zero gem installs on the target Macs.

## 8. Explicit non-goals (v1)

Live websockets, intraday tick storage, running analytics in Workers,
npm/toolchain-managed frontend, multi-user auth, mobile app. The
`visualize`-style interactivity budget is: ECharts built-ins (tooltip,
zoom, legend toggle) only.
