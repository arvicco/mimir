# mimir -- BTC analytics toolkits

Local Ruby analytics for Bitcoin: options positioning (GEX), a
multi-signal regime composite, an LPPL falsification suite, and a
treasury-company analyser. Everything runs from cron/tmux on a Mac and
prints to the terminal; the planned Cloudflare dashboard (see
[ARCHITECTURE.md](ARCHITECTURE.md)) is **not built yet** -- today these
are command-line tools, nothing more.

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
| `scripts/btco/btco.rb` | treasury-company metrics + stress score | **seed data is placeholder**; live quote source (Stooq) died upstream 2026-07 -- currently needs `manual_px` (replacement pending, TOOL-REVIEW F-17) |
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
Everything else is keyless public APIs; `etf_flows` is the one HTML
scrape (degrades gracefully on layout drift).

## LPPL suite

```
ruby scripts/lppl/lppl.rb                  # update prices, run 5 tests, verdict
ruby scripts/lppl/lppl.rb --skip-update    # offline, cached prices
ruby scripts/lppl/lppl.rb --history        # also append ledger + fit history
ruby scripts/lppl/trend.rb                 # any test standalone
ruby scripts/lppl/logperiodic.rb --sims 500  # more bootstrap sims
```

Five tests (out-of-sample trend Bayes factor, damping envelope, LPPLS
anti-bubble fit, Lomb-Scargle oscillation significance, valuation
percentile monitor) -> REGIME-INTACT ... FALSIFIED verdict. First run
downloads full BTC price history and bootstraps a score cache (takes a
minute or two); daily runs are incremental. Keyless.

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

## Not implemented yet (roadmap in ARCHITECTURE.md)

- Publishing to Cloudflare KV (`publish/`), chart specs, the Worker API
  and the dashboard (Phases 2-4). `PUBLISH_DRY_RUN` does nothing today.
- Cron/launchd install, runbook (Phase 5).

## Development

```
rake                 # compat + health (offline) + tests -- the pre-commit gate
rake test:unit       # just the unit tests
rake test:contract   # --json/--tmux field-set contracts (offline, vs fixtures)
rake fixtures:record # re-record live API fixtures (NETWORK -- review the diff)
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
`docs/BACKLOG.md` (work state). ENV reference: `.env.example`.
