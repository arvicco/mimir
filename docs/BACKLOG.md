# Backlog

Work packets for the dev loop (see `docs/DEV-LOOP.md`). Statuses:
`ready` -> `in-progress` -> `done` | `blocked: <reason>`. The executing
session updates its packet's status and appends one line to
`docs/WORKLOG.md`. Phase N+1 packets are elaborated only at Gate N.

Stage 0 rule: every code-touching packet below is `[tier: fable]` --
no exceptions until Stage A (Phase 2).

---

## Phase 0 -- inventory, documentation + safety net (branch: phase-0)

## M0-1 · Loop bootstrap: branch, permissions, CI, backlog  [tier: fable] [status: done] [deps: --]
Goal: `phase-0` branch; `.claude/settings.json` permission profile
      (sandbox-freedom inside the repo, hard deny on wrangler /
      fixtures:record / main pushes / secrets paths); GitHub Actions CI
      (`rake compat` + `rake test` on ubuntu + macos-arm64, Ruby 3.3);
      this backlog + `docs/WORKLOG.md`.
Acceptance: branch pushed; first CI run green on both OSes; backlog
      carries all Phase 0 packets with goals/acceptance.

## M0-2 · Tool inventory & review memo  [tier: fable] [status: done -- all findings owner-ruled and executed; open at Gate 0: optional R-3/6/7, flagged R-11/12/13 (R-12 needs an analytics ruling)] [deps: --]
Goal: `docs/TOOL-REVIEW.md` covering every tool under `scripts/`
      (gex.rb, gex_us.rb, gex_btc_combined.rb, scenario/* incl. all 7
      modules, lppl/* incl. all 5 evidence tests, btco.rb, ingest.rb):
      purpose, data sources, output contracts (--json/--tmux shapes),
      maturity assessment (battle-tested vs new/barely-used), suspected
      weak spots, duplication across tools, refactor candidates.
      Read-only packet: no code changes.
Acceptance: memo covers 100% of scripts/; each tool has an explicit
      maturity verdict and a (possibly empty) refactor-candidate list;
      owner has reviewed and the agreed findings are marked -- these
      seed Phase 1's M1-13..n refactor packets.

## M0-3 · README.md v1  [tier: fable] [status: done -- owner accepted 2026-07-04] [deps: M0-2]
Goal: user-facing README at repo root: what each tool does today, exact
      commands (incl. --json/--tmux/--skip-update flags), required ENV
      per tool, per-tool maturity honestly stated (from the M0-2 memo),
      and an explicit "not yet implemented" list (publish pipeline,
      charts, dashboard). A newcomer reading only the README knows
      exactly what the tools can do today.
Acceptance: owner accepts; every documented command actually runs;
      nothing implemented is missing, nothing missing is claimed.

## M0-4 · Characterization: bs_gamma  [tier: fable] [status: done] [deps: --]
Goal: pin Black-Scholes gamma as implemented in the gex tools: exact
      known values (precomputed reference points), put/call gamma
      symmetry, edge behavior (deep ITM/OTM, near-zero time). Pattern:
      test/unit/test_lppl_common.rb.
Acceptance: rake test green; values pinned to current behavior (no
      "fixes" -- deviations become decision items); no network.

## M0-5 · Characterization: OSI/Deribit instrument parsing  [tier: fable] [status: done] [deps: --]
Goal: pin instrument-name parsing in gex.rb (Deribit: BTC-27MAR26-100000-C
      shapes) and gex_us.rb (OSI: IBIT260327C00100000 shapes): expiry,
      strike, type extraction; malformed-input behavior as-is.
Acceptance: rake test green; both parsers covered incl. month map and
      decimal-strike handling; no network.

## M0-6 · Characterization: percentile envelope fit + Lomb-Scargle  [tier: fable] [status: done] [deps: --]
Goal: pin lppl/envelope.rb percentile-envelope fitting and the
      Lomb-Scargle periodogram (logperiodic.rb) on synthetic inputs:
      envelope on a constructed series with known percentile bands;
      Lomb-Scargle peak frequency/power on a synthetic sinusoid (exact
      tolerance policy set here -- this packet defines the numerical
      tolerance conventions for the whole suite).
Acceptance: rake test green; synthetic generators seeded
      (Random.new(42)); tolerances documented in-test; no network.

## M0-7 · Characterization: btco metrics math  [tier: fable] [status: done] [deps: --]
Goal: pin CEBE / mNAV / convert ITM-OTM treatment from btco.rb on a
      small synthetic universe (hand-built company entries exercising
      each branch: converts ITM, OTM, at boundary; missing fields).
Acceptance: rake test green; synthetic universe as inline fixture (no
      real universe.json dependency); every metric branch hit; no network.

## M0-8 · Characterization: ingest pure parts  [tier: fable] [status: done] [deps: --]
Goal: pin ingest.rb's pure functions: `excerpt` windowing (boundaries,
      overlaps, short docs) and `diff_against` (added/changed/removed
      detection on synthetic before/after models).
Acceptance: rake test green; no ANTHROPIC_API_KEY needed, no network;
      extraction prompt/schema untouched (contract, Golden Rule 5).

## M0-9 · Methodology documentation  [tier: fable] [status: done] [deps: M0-2]
Goal: docs/METHODOLOGY.md for new users (owner request 2026-07-04):
      per-tool rationale, model assumptions, every displayed field and
      its interpretation, token-by-token status-line decodes, worked
      readings of real output, honest caveats (GEX sign trust, trend-BF
      magnitude/cache-density, empirical-vs-gaussian percentile).
Acceptance: a newcomer can decode any tool's terminal output unaided;
      linked from README; owner review at Gate 0.

## Gate 0 (human)
~~Byte-identical vs pre-import captures~~ amended (no pre-import copies
survived): characterization suite + loop-run capture review
(TOOL-REVIEW.md section 6, done 2026-07-04). Memo + README accepted.
Remaining owner actions: sign off F-16 (Coin Metrics price source),
rule F-17 (btco quote-source replacement), eyeball the first LPPL
readings, merge PR `phase-0 -> main`.

---

## Phase 1 -- fixtures + contract tests (branch: phase-1)
Gate 0 closed 2026-07-04 (PR #1). M1-1..5 (seam + migration) and M1-12
(BTC_DATA_DIR) were delivered in Phase 0, as were the memo refactors.
All [tier: fable] (Stage 0).

## M1-6 · Implement rake fixtures:record  [tier: fable] [status: done -- implementation; recording itself is the owner-run Gate 1 step] [deps: --]
Goal: replace the Rakefile stub: for each registered upstream response
      shape, fetch once through BTC::Http, trim to minimum size (drop
      rows beyond what parsers need), redact anything sensitive, write
      test/fixtures/<source>_<shape>.json + per-file provenance note
      (url, retrieved date). Reuses lib/btc/health.rb's SOURCES where
      shapes align; adds fixture-only shapes (full option book slice,
      farside HTML sample, EDGAR filing excerpt, stooq gone -- cboe
      quote). RUNNING it stays owner-only (network; deny-listed).
Acceptance: task implemented + unit-tested against a fake transport
      (writes correct layout without network); rake gates green.

## M1-7 · Contract tests: gex family --json  [tier: fable] [status: done -- gex_us pins self-enable once the owner re-records cboe_options.json (F-20)] [deps: M1-6]
Goal: test/contract/ pins field presence/types (not values) for
      gex.rb, gex_us.rb (BOTH shapes: single-ticker object, multi
      array -- F-10), gex_btc_combined.rb (venues[], combined{},
      profile{}), via fixtures + injected transport.
Acceptance: red against a mutated fixture, green against real; no network.

## M1-8 · Contract tests: scenario modules + aggregator  [tier: fable] [status: done -- etf_flows/cb_premium success pins self-enable on the owner re-record (F-21/F-22)] [deps: M1-6]
Goal: per-module --json contract (name/score/headline/ts; the
      funding/onchain name quirks pinned -- F-11), fail-soft shape with
      'unavailable': true (F-12), one-JSON-line stdout discipline
      (F-9), aggregator composite/regime fields.
Acceptance: every module covered; no network.

## M1-9 · Contract tests: lppl tests + aggregator  [tier: fable] [status: done] [deps: M1-6]
Goal: per-test --json contracts on a synthetic price cache written to
      a temp BTC_DATA_DIR (tests run the real scripts offline); ledger
      line field set; status_line format.
Acceptance: all five tests + aggregator covered; no network.

## M1-10 · Contract tests: btco --json  [tier: fable] [status: done] [deps: M1-6]
Goal: success shape (companies[], stress fields) on a synthetic
      universe + fixture quotes; fail-soft shape; --tmux line format.
Acceptance: covered incl. STALE/placeholder flags; no network.

## M1-11 · Contract test: ingest proposal schema  [tier: fable] [status: done] [deps: --]
Goal: proposal JSON shape (ticker/accession/form/diff/extraction keys)
      + diff computation on fixture excerpts; extraction prompt/schema
      text pinned verbatim (Golden Rule 5 tripwire).
Acceptance: no ANTHROPIC_API_KEY, no network.

## Gate 1 (human)
First recording done 2026-07-04 (committed 38f991a), but it predated
the F-20/21/22 recorder fixes: owner re-runs `rake fixtures:record`
once more and reviews the diff (expect: far-dated live option boards,
new binance_spot.json, a longer farside page). That flips the 5
self-gated contract skips to live pins -- `rake test:contract` must
then show 0 skips. Field-set contracts green for all modules; README
updated; PR phase-1 -> main merged. (F-4's code half remains a Phase 2
design input.)
