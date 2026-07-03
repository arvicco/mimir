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

## M0-2 · Tool inventory & review memo  [tier: fable] [status: ready] [deps: --]
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

## M0-3 · README.md v1  [tier: fable] [status: ready] [deps: M0-2]
Goal: user-facing README at repo root: what each tool does today, exact
      commands (incl. --json/--tmux/--skip-update flags), required ENV
      per tool, per-tool maturity honestly stated (from the M0-2 memo),
      and an explicit "not yet implemented" list (publish pipeline,
      charts, dashboard). A newcomer reading only the README knows
      exactly what the tools can do today.
Acceptance: owner accepts; every documented command actually runs;
      nothing implemented is missing, nothing missing is claimed.

## M0-4 · Characterization: bs_gamma  [tier: fable] [status: ready] [deps: --]
Goal: pin Black-Scholes gamma as implemented in the gex tools: exact
      known values (precomputed reference points), put/call gamma
      symmetry, edge behavior (deep ITM/OTM, near-zero time). Pattern:
      test/unit/test_lppl_common.rb.
Acceptance: rake test green; values pinned to current behavior (no
      "fixes" -- deviations become decision items); no network.

## M0-5 · Characterization: OSI/Deribit instrument parsing  [tier: fable] [status: ready] [deps: --]
Goal: pin instrument-name parsing in gex.rb (Deribit: BTC-27MAR26-100000-C
      shapes) and gex_us.rb (OSI: IBIT260327C00100000 shapes): expiry,
      strike, type extraction; malformed-input behavior as-is.
Acceptance: rake test green; both parsers covered incl. month map and
      decimal-strike handling; no network.

## M0-6 · Characterization: percentile envelope fit + Lomb-Scargle  [tier: fable] [status: ready] [deps: --]
Goal: pin lppl/envelope.rb percentile-envelope fitting and the
      Lomb-Scargle periodogram (logperiodic.rb) on synthetic inputs:
      envelope on a constructed series with known percentile bands;
      Lomb-Scargle peak frequency/power on a synthetic sinusoid (exact
      tolerance policy set here -- this packet defines the numerical
      tolerance conventions for the whole suite).
Acceptance: rake test green; synthetic generators seeded
      (Random.new(42)); tolerances documented in-test; no network.

## M0-7 · Characterization: btco metrics math  [tier: fable] [status: ready] [deps: --]
Goal: pin CEBE / mNAV / convert ITM-OTM treatment from btco.rb on a
      small synthetic universe (hand-built company entries exercising
      each branch: converts ITM, OTM, at boundary; missing fields).
Acceptance: rake test green; synthetic universe as inline fixture (no
      real universe.json dependency); every metric branch hit; no network.

## M0-8 · Characterization: ingest pure parts  [tier: fable] [status: ready] [deps: --]
Goal: pin ingest.rb's pure functions: `excerpt` windowing (boundaries,
      overlaps, short docs) and `diff_against` (added/changed/removed
      detection on synthetic before/after models).
Acceptance: rake test green; no ANTHROPIC_API_KEY needed, no network;
      extraction prompt/schema untouched (contract, Golden Rule 5).

## Gate 0 (human)
Byte-identical `--json` runs vs owner-provided pre-import captures
(loop prints the exact capture commands); M0-2 memo reviewed; M0-3
README accepted; PR `phase-0 -> main` merged by owner.

---

## Phase 1 -- seams, contracts + reviewed refactoring
Elaborated at Gate 0. Sketch (DEV-LOOP.md section 8): M1-1 http seam ·
M1-2..5 per-suite migration · M1-6 fixtures:record · M1-7..11 contract
tests · M1-12 BTC_DATA_DIR · M1-13..n refactors from the approved
M0-2 memo findings. All [tier: fable] (Stage 0).
