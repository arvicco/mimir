# DEV-LOOP.md -- driving mimir's implementation with Claude models

*How mimir (btc-analytics) gets built with maximum unattended automation,
minimum Fable-tier spend, and the human gates ARCHITECTURE.md already
mandates. Modeled on the proven loop in `../nabu/docs/dev-loop.md`
(Phases 0-1 of nabu were executed by that loop). This document is the
proposal; nothing under "Next steps" (section 10) runs until the owner
approves it.*

## 1. Why this project fits an unattended loop -- and where it doesn't

CLAUDE.md already specifies most of an autonomous loop:

- **Machine-checkable done:** `rake compat` + `rake test` green is the
  pre-commit gate. No network in tests; fully deterministic verification.
- **Frozen contracts as oracles:** `--json` field-set contract tests and
  golden chart specs grade the work, not judgment.
- **Minimal-diff / TDD rules** make packets naturally PR-sized.
- **Phases with review gates** (ARCHITECTURE.md section 6) are the
  standing human approval points -- the loop never invents its own.

Where mimir is *harder* than a greenfield project (nabu) and the loop
must be more conservative:

1. **Brownfield production code.** `scripts/` runs in cron today.
   Characterization tests come BEFORE any modification, and Gate 0's
   byte-identical `--json` check needs pre-import captures only the
   owner can produce (on novo, against live data).
2. **Ruby 2.5.5 floor.** Local dev rubies are newer (this machine runs
   4.x), so green tests locally do NOT prove 2.5.5 compatibility.
   `rake compat` is the automated floor; the authoritative check is a
   periodic human run of the suite on novo (part of each gate).
3. **Untouchable semantics.** Scoring thresholds, weights, model
   parameters, probability mappings are research decisions. The loop
   treats any packet that seems to require touching them as
   `blocked: decision-item` immediately -- zero attempts.
4. **Human-only deploys.** wrangler/KV/token/first-publish actions are
   never executed by any model at any tier (Golden Rule 3).
5. **Visual gates.** Golden chart specs are approved only by a human
   looking at preview.html (`rake golden:approve`).

The loop's job is dispatch-and-verify, not judge -- which is what lets
cheaper models do most of the work.

## 2. Model tiering policy

**Principle: Fable writes seams, patterns, and judgments; Opus writes
code that has a pattern and an oracle; the test suite gatekeeps
regardless of who wrote the code.**

| Tier | Used for | Rationale |
|---|---|---|
| **Fable** | `lib/btc/http.rb` seam design (touches every suite); characterization-test design for numerically subtle code (Lomb-Scargle, percentile envelope fit, LPPL fit internals); `kv_client.rb` (secret redaction, retry semantics -- security-sensitive); the FIRST chart spec (`gex_profile`, sets the family pattern); the first contract test (sets the pattern); phase-gate reviews of the whole phase diff; adjudicating `blocked` packets | Mistakes here are cross-cutting or expensive; everything downstream copies these patterns |
| **Opus** | Characterization tests following the pinned pattern (seed test `test_lppl_common.rb` exists); every second-and-later contract test and chart spec; `publish.rb` orchestrator against the Fable-approved kv_client; per-suite `Common.get_json` migration onto the http seam; `worker.js` / `app.js` / `preview.html` (small, fully specified in ARCHITECTURE.md); `BTC_DATA_DIR` plumbing; RUNBOOK.md drafting; prepared (not installed) cron/launchd entries | Pattern-following work with a reference implementation and an oracle to grade it |
| **Sonnet** | Non-coding chores only: fixture READMEs, worklog/backlog housekeeping, summarizing dry-run artifacts | Cheap and adequate for prose; **never writes code** |

**Only Fable and Opus write code.** Heuristic for tagging a coding
packet: **first-of-kind or cross-cutting or secret-adjacent -> Fable;
everything else -> Opus.** When in doubt, tag Opus and rely on the
escalation rule (section 4) -- a wrongly-tagged packet fails
verification and gets bumped up, costing one retry, not a bad
foundation.

Mimir-specific hard rule regardless of tier: **no model changes
analytics semantics, frozen contract fields, or `universe.json`.**
Those become `blocked: decision-item` for the owner.

## 3. Work packets and the backlog

The backlog lives at `docs/BACKLOG.md` -- flat, human-editable packets
(same format that ran nabu):

```markdown
## M1-04 · Contract test: scenario.rb --json field set  [tier: opus] [status: ready] [deps: M1-01]
Goal: test/contract/test_scenario_contract.rb asserts field presence/types
      (not values) of scenario.rb --json against a recorded fixture.
Acceptance: contract test red against a mutated fixture, green against the
      real one; rake test + rake compat green; no network.
```

Statuses: `ready` -> `in-progress` -> `done` | `blocked: <reason>`.
The executing session updates its own packet's status and appends one
line to `docs/WORKLOG.md` (date, packet, commit SHA, notes). The
backlog is the loop's entire coordination state -- no external tracker,
survives any session dying.

## 4. Loop mechanics

Each iteration, regardless of execution vehicle (section 5):

1. **Pick** the first `ready` packet whose deps are `done`.
2. **Dispatch** at the packet's tier (session model or Agent-tool model
   override).
3. **Implement TDD** per CLAUDE.md: characterization/failing test first,
   then minimal diff to green. Forbidden-construct list applies; when
   unsure about a 2.5.5 API, verify against 2.5 docs, don't guess.
4. **Verify**: `rake compat` + `rake test` green, then a `/code-review`
   (medium) pass; fix findings. For anything touching a `--json`/`--tmux`
   path, additionally diff the output field set against the contract.
5. **Commit** on the current phase branch (`phase-N`), conventional
   message referencing the packet ID. Update backlog + worklog.
6. **Escalate on failure**: two failed attempts -> mark
   `blocked: <diagnosis>`, move on. Never thrash. `blocked` packets are
   adjudicated by Fable at the next gate (or sooner if everything is
   blocked -> stop and notify the owner). Packets touching semantics or
   contracts skip attempts entirely and go straight to
   `blocked: decision-item`.
7. **Phase gate** (all phase packets done/blocked): Fable reviews the
   *entire phase diff* against ARCHITECTURE.md, verifies the doc is
   still truthful, resolves blocked packets, updates the "Current
   phase" line in CLAUDE.md, and produces the gate handoff summary.
   **The owner executes the gate's human actions (section 7) and
   merges -- this is the standing approval gate.** The next phase's
   packets are elaborated in detail only after the gate closes.

## 5. Execution vehicles -- two stages

**Stage A (Phases 0-2): Fable-led sessions, semi-attended.**
A Claude Code session on Fable does the design-heavy packets itself and
delegates `tier: opus` packets to Opus subagents via the Agent tool.
This is where the seam, the contract-test pattern, and the kv client
get built -- Fable spend is genuinely justified, and trust in the loop
is established while the owner is around intermittently.

**Stage B (Phases 3-4): assembly line, mostly unattended.**
The patterns exist; Phase 3 is three more chart specs after the first,
Phase 4 is ~80 lines of specified JS. Run the loop as an **Opus main
session** (`/loop`, or headless `claude -p --model opus` per packet)
that spawns **Fable subagents only** for gate reviews and blocked-packet
adjudication. Fresh context per packet prevents drift; the backlog file
carries all state.

Phase 5 is ops integration -- inherently human-paced (installing cron
entries, one-week soak); the loop only drafts artifacts (RUNBOOK.md,
launchd plists, tmux status line) as Opus packets.

Cloud scheduled agents are not proposed: the runtime target is a local
Mac mesh and every deploy-adjacent action is human anyway.

## 6. Guardrails

Principle (inherited from nabu, proven there): **inside the sandbox,
full freedom -- the boundary itself is hard.**

**Freely allowed, no prompts** (via `.claude/settings.json`, section 10):
- All file operations inside the repo + session scratchpad.
- `rake` (test/compat/golden tasks), `ruby -c`, `ruby scripts/... --skip-update`,
  `PUBLISH_DRY_RUN=1 ruby publish/publish.rb`.
- `git add/commit/branch/checkout/diff/log` on non-`main` branches.
- Web search / doc fetches (e.g. Ruby 2.5 API docs, ECharts option docs,
  Cloudflare KV REST docs).

**Hard boundary (deny-listed or owner-only, every time):**
- `wrangler` anything; KV namespace/token creation; any non-dry-run
  publish; `rake fixtures:record` (network -- owner-triggered only).
- Secrets: never read `~/.config/btc-analytics/env`, `.env`, `*.token`;
  ENV names only; error paths redact (already Golden Rule 8).
- Pushes to `main`; force pushes; history rewrites; tags (tags are gate
  actions).
- Anything outside the repo; installing software (brew/gem); any new
  dependency (stdlib-only rule -- ask first, always).
- Writing `scripts/btco/universe.json` directly.

**Loop discipline:**
- Two-strike rule bounds spend on any packet.
- The loop never marks its own phase done -- a phase ends at
  owner-executed gate actions, full stop.
- No opportunistic refactors, no reformatting, no assertion weakening.

## 7. Human-action inventory (what only the owner does)

This project has more human touchpoints than a greenfield one; the loop
schedules around them so they never block mid-phase:

| When | Action |
|---|---|
| Phase 0, before Gate 0 | Provide pre-import `--json` captures from novo; provide/locate `gex.rb` + `gex_us.rb` (listed in ARCHITECTURE §3, not yet in the repo); run suite once on novo Ruby 2.5.5 |
| Phase 1 | Run `rake fixtures:record` once (live API calls), review the recorded fixtures diff |
| Gate 2 | Review dry-run artifact set; create KV namespace + scoped token; run first real publish by hand |
| Gate 3 | Visual review in preview.html; `rake golden:approve` |
| Gate 4 | `wrangler deploy` / Pages publish; smoke checklist |
| Phase 5 / Gate 5 | Install launchd/cron entries; one-week soak; tag v1 |
| Any time | Adjudicate `blocked: decision-item` packets (semantics/contract questions) |

## 8. Phase & packet breakdown

Packet lists are the plan; each phase's packets get full
Goal/Acceptance elaboration at the previous phase's gate. IDs `M<phase>-<n>`.

**Phase 0 -- safety net** *(in progress; mostly Opus -- the seed
characterization test pins the pattern)*
- M0-1 git init, `phase-0` branch, `.claude/settings.json` permission
  profile, `docs/BACKLOG.md` + `docs/WORKLOG.md` bootstrap [opus]
- M0-2 import `gex.rb`, `gex_us.rb` [human provides, opus verifies compat]
- M0-3 characterization: `bs_gamma` (known values, put/call symmetry) [opus]
- M0-4 characterization: OSI/Deribit instrument parsing [opus]
- M0-5 characterization: percentile envelope fit + Lomb-Scargle on
  synthetic sinusoid [fable -- numerically subtle, defines tolerance policy]
- M0-6 characterization: btco CEBE/mNAV/convert ITM-OTM on synthetic
  universe [fable design, opus implement]
- M0-7 characterization: ingest pure parts (`excerpt`, `diff_against`) [opus]
- Gate 0: byte-identical `--json` vs owner-provided captures [human]

**Phase 1 -- seams** *(Fable-heavy: the seam everything depends on)*
- M1-1 `lib/btc/http.rb` + injectable transport design [fable]
- M1-2..5 migrate each suite's `Common.get_json` onto the seam,
  one suite per packet [opus]
- M1-6 implement `rake fixtures:record` [opus; execution is human]
- M1-7 first contract test (pattern-setter) [fable]; M1-8..11 remaining
  module contracts + ingest proposal schema [opus]
- M1-12 `BTC_DATA_DIR` override [opus]

**Phase 2 -- publish pipeline**
- M2-1 `publish/kv_client.rb` [fable -- retries, auth, redaction]
- M2-2 `publish/publish.rb` orchestrator + envelopes + dry-run [opus]
- M2-3 redaction/retry/dry-run test battery [opus, fable review]

**Phase 3 -- chart specs** *(Stage B begins)*
- M3-1 `gex_profile` spec [fable -- family pattern-setter]
- M3-2..4 `scenario_strip`, `lppl_regime`, `btco_table` [opus]
- M3-5 `web/preview.html` offline harness [opus]

**Phase 4 -- Cloudflare layer**
- M4-1 `worker.js` + `wrangler.toml` [opus, fable review of auth/headers]
- M4-2 `public/index.html` + `app.js` loader + staleness badges [opus]

**Phase 5 -- ops artifacts** *(drafts only; installation is human)*
- M5-1 launchd/cron entry files + tmux health line [opus]
- M5-2 `docs/RUNBOOK.md` [opus draft, sonnet polish]

## 9. CI (proposed, decision item)

Nabu's loop leaned on GitHub Actions as an un-gameable external oracle.
For mimir the equivalent is `rake compat && rake test` on every push --
but hosted runners cannot faithfully provide Ruby 2.5.5 (EOL). Proposal:
CI runs the suite on a modern Ruby plus `rake compat` (the automated
floor); the authoritative 2.5.5 run happens on novo at each gate
(section 7). If no remote/CI is wanted for a local-first repo, the gate
run on novo alone suffices -- the loop treats local `rake compat` +
`rake test` as its oracle either way.

## 10. Next steps (require owner approval -- nothing below has run)

1. **Approve this plan** (amend tiering/guardrails inline as with nabu).
2. ~~Decide git hosting~~ **Decided 2026-07-03:** repo initialized and
   pushed to private `arvicco/mimir` (main). Remaining sub-decision:
   whether the loop pushes `phase-N` branches + opens PRs (nabu policy,
   enables CI per section 9) or phases merge locally. `main` stays
   owner-merged either way.
3. On approval, execute M0-1: `git init`, initial commit of current
   tree, `phase-0` branch, `.claude/settings.json` permission profile
   (nabu's, adapted: deny `wrangler:*`, `curl` write methods, secrets
   paths; allow rake/ruby/git-non-main), elaborate Phase 0 packets into
   `docs/BACKLOG.md`.
4. Owner supplies the two Phase 0 inputs the loop cannot get itself:
   `gex.rb`/`gex_us.rb` origin, and pre-import `--json` captures from
   novo for Gate 0.
5. Stage A begins: Fable-led session works the Phase 0 backlog.
