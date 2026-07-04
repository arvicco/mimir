# DEV-LOOP.md -- driving mimir's implementation with Claude models

*How mimir gets built with maximum unattended automation,
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

1. **Brownfield production code, built without TDD.** `scripts/` runs
   in cron today; some tools are new and barely used or tested by the
   owner. Legacy-without-TDD is always tricky: behavior must be pinned
   (characterization tests) before it is touched, weak spots must be
   found by review rather than assumed absent, and Gate 0's
   byte-identical `--json` check needs pre-import captures only the
   owner can produce. This is why Stage 0 exists (section 5) and why it
   runs interactively with Fable-only code access.
2. **Untouchable semantics.** Scoring thresholds, weights, model
   parameters, probability mappings are research decisions. The loop
   treats any packet that seems to require touching them as
   `blocked: decision-item` immediately -- zero attempts.
3. **Human-only deploys.** wrangler/KV/token/first-publish actions are
   never executed by any model at any tier (Golden Rule 3).
4. **Visual gates.** Golden chart specs are approved only by a human
   looking at preview.html (`rake golden:approve`).

Runtime target is Ruby 3.3+ on Apple Silicon Macs (arm64-darwin); local
dev rubies and CI (section 9) are all modern, so green-locally is
meaningful -- no cross-version gymnastics needed.

The loop's job is dispatch-and-verify, not judge -- which is what lets
cheaper models do most of the work in later stages.

## 2. Model tiering policy

**Principle (revised at Gate 1, owner-ruled 2026-07-04): Fable
orchestrates, designs, and reviews; cheaper models write most of the
code; the test suite + frozen contracts + CI gatekeep regardless of
who wrote it.** Fable-writes-everything was a Stage 0 rule for
hardening untested legacy analytics; it ended with Stage 0. Phase 1
retrospective: harness design and bug hunts (F-18/F-20/F-22) needed
Fable; fixture entries, canned bodies, and pattern-copied contract
pins did not.

| Tier | Used for | Rationale |
|---|---|---|
| **Fable** | Phase/architecture design and packet elaboration; FIRST-of-family patterns (the first chart spec, `publish/kv_client.rb` with its secret redaction/retry semantics); anything touching analytics semantics, frozen contracts, or the extraction prompt (proposal-only -- final say stays with the owner); review of every delegated diff before commit; auth/header logic in `web/`; phase-gate reviews; adjudicating `blocked` packets; upstream-breakage forensics (the F-16..F-23 class) | Mistakes here are cross-cutting, expensive, or subtle; everything downstream copies these patterns. Review is ~10x cheaper than writing -- Fable reads every delegated diff, it just stops typing the boilerplate |
| **Opus** | Standard implementation against a written spec: second-and-later chart specs, `publish/publish.rb` orchestration glue, `worker.js` / `app.js` / `preview.html` (fully specified in ARCHITECTURE.md), API-call plumbing behind the `BTC::Http` seam, retry/dry-run test batteries, RUNBOOK.md drafting, prepared (not installed) cron/launchd entries | Pattern-following work with a reference implementation and an oracle to grade it |
| **Sonnet** | Pattern-following with a deterministic oracle: new tests copying an established pattern, fixture/registry/shim entries, mechanical refactors the suite fully pins, doc syncs, worklog/backlog housekeeping | The gate catches failures cheaply; a wrong attempt costs one red run, not a bad foundation |

**Tagging rules:**
- Every packet gets its tier assigned at elaboration. `fable` is NOT
  the default: a `[tier: fable]` tag on a coding packet carries a
  one-line justification (first-of-kind / cross-cutting /
  secret-adjacent / semantics-adjacent).
- When in doubt between two tiers, tag the cheaper one and rely on the
  escalation rule (section 4): a wrongly-tagged packet fails
  verification and gets bumped one tier, costing one retry, not a bad
  foundation.
- The dispatching Fable session reviews every delegated diff against
  the packet's acceptance criteria and the self-review checklist
  before committing -- delegation moves the typing, not the
  accountability.

Hard rule regardless of tier and stage: **no model changes analytics
semantics, frozen contract fields, or `universe.json`.** Those become
`blocked: decision-item` for the owner.

## 3. Work packets and the backlog

The backlog lives at `docs/BACKLOG.md` -- flat, human-editable packets
(same format that ran nabu):

```markdown
## M1-04 · Contract test: scenario.rb --json field set  [tier: fable] [status: ready] [deps: M1-01]
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
   override; in Stage 0, always Fable for code).
3. **Implement TDD** per CLAUDE.md: characterization/failing test first,
   then minimal diff to green.
4. **Verify**: `rake compat` + `rake test` green, then a `/code-review`
   (medium) pass; fix findings. For anything touching a `--json`/`--tmux`
   path, additionally diff the output field set against the contract.
5. **Commit** on the current phase branch (`phase-N`), conventional
   message referencing the packet ID. Update backlog + worklog.
6. **Escalate on failure**: two failed attempts at the packet's tier ->
   bump one tier (sonnet -> opus -> fable) and retry once; two failed
   attempts AT Fable tier -> mark `blocked: <diagnosis>`, move on.
   Never thrash. `blocked` packets are adjudicated by Fable at the next
   gate (or sooner if everything is blocked -> stop and notify the
   owner). Packets touching semantics or contracts skip attempts
   entirely and go straight to `blocked: decision-item`.
7. **Pre-gate: update `README.md`** -- the user-facing document
   describing the capabilities and commands implemented up to this
   point, honest about what does not work yet. A newcomer reading only
   the README should know exactly what the tools can do today. A phase
   is not gate-ready with a stale README.
8. **Phase gate** (all phase packets done/blocked, README current):
   Fable reviews the *entire phase diff* against ARCHITECTURE.md,
   verifies the doc is still truthful, resolves blocked packets, updates
   the "Current phase" line in CLAUDE.md, and produces the gate handoff
   summary. **The owner executes the gate's human actions (section 7)
   and merges -- this is the standing approval gate.** The next phase's
   packets are elaborated in detail only after the gate closes.
9. **Ring for the owner** whenever the loop stops on something only the
   owner can do -- a phase gate handoff, an all-blocked stop, a
   `decision-item` that halts progress. As the LAST tool call of that
   turn, arm the machine's sticky attention alarm:

   ```
   nohup "$HOME/.claude/hooks/attention-alarm.sh" sticky >/dev/null 2>&1 &
   ```

   Sticky mode (Glass chime, once a minute, max 20 rings) survives
   turn end and stops only when the owner reacts (types anything,
   presses the mic key, runs `hush`, or clicks the Hush Dock icon).
   Do NOT arm it earlier in the turn (any later tool call kills it via
   hook) and do NOT ring for informational or progress-report turns --
   the alarm is scoped to input-required moments only. (Normal mode,
   no argument, is auto-started by the Notification hook on permission
   prompts; the loop never invokes it directly.) On a machine without
   the hook the command is a harmless no-op, so sessions elsewhere can
   follow this step unconditionally.

## 5. Execution stages

**Stage 0 (Phases 0-1): legacy hardening -- interactive, Fable-only code.**
The existing disparate CLI tools were developed without TDD; some are
new and barely used. Before ANY new feature work, Stage 0 puts the
legacy in good shape, deliberately staged:

- *Phase 0 -- inventory, documentation + safety net.* A per-tool review
  memo (purpose, data sources, output contracts, maturity assessment,
  suspected weak spots, refactor candidates), `README.md` v1, and the
  full offline test suite pinning all pure logic. The memo is reviewed
  WITH the owner -- its agreed findings seed Phase 1.
- *Phase 1 -- seams, contracts + reviewed refactoring.* The
  `lib/btc/http.rb` seam, fixtures, contract tests for every module,
  then the owner-approved refactor list executed behavior-preservingly
  (characterization first). Bugs found in the barely-used tools are
  decision items, never silent fixes.

Stage 0 is **more interactive than later stages**: the owner is present
for the memo review, refactor-list approval, and both gates; sessions
work packet-by-packet with the owner able to steer between packets, not
in a fire-and-forget loop. **Every code-touching packet is Fable.**

**Stage A (Phases 2-3): new features -- Fable-orchestrated, semi-attended.**
Legacy is now trustworthy; new-feature work begins. A Fable session
elaborates packets, writes only the `[tier: fable]` ones itself
(first-of-family, secret-adjacent, semantics-adjacent -- each with its
one-line justification), and dispatches everything else to Opus/Sonnet
subagents via the Agent tool at the packet's tier, reviewing each diff
against acceptance criteria before committing. Most implementation
code in Stage A is written by Opus, most pattern-copied tests and
registry plumbing by Sonnet (section 2 table). Owner is around
intermittently.

**Stage B (Phases 4-5): assembly line -- Opus-led, mostly unattended.**
The patterns exist; Phase 4 is ~80 lines of specified JS, Phase 5 is
drafting ops artifacts. Run the loop as an **Opus main session**
(`/loop`, or headless `claude -p --model opus` per packet) that
dispatches `tier: sonnet` packets downward and spawns **Fable
subagents only** for gate reviews and blocked-packet adjudication.
Fresh context per packet prevents drift; the backlog file carries all
state. Phase 5's installations and the one-week soak are inherently
human-paced; the loop only drafts artifacts.

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
- Web search / doc fetches (e.g. Ruby stdlib docs, ECharts option docs,
  Cloudflare KV REST docs).

**Hard boundary (deny-listed or owner-only, every time):**
- `wrangler` anything; KV namespace/token creation; any non-dry-run
  publish; `rake fixtures:record` (network -- owner-triggered only).
- Secrets: never read `~/.config/mimir/env`, `.env`, `*.token`;
  ENV names only; error paths redact (already Golden Rule 8).
- Pushes to `main`; force pushes; history rewrites; tags (tags are gate
  actions).
- Anything outside the repo; installing software (brew/gem); any new
  dependency (stdlib-only rule -- ask first, always).
- Writing `scripts/btco/universe.json` directly.

**Loop discipline:**
- Owner-facing verification requests are always SPECIFIC: exact
  command lines to run and files to check, plus what good/bad looks
  like -- never a bare "take a look".
- Two-strike rule bounds spend on any packet.
- The loop never marks its own phase done -- a phase ends at
  owner-executed gate actions, full stop.
- No opportunistic refactors, no reformatting, no assertion weakening.
  (In Stage 0, refactoring happens ONLY from the owner-approved list.)

## 7. Human-action inventory (what only the owner does)

| When | Action |
|---|---|
| Phase 0 | Review the tool inventory memo; agree the refactor/priority list; accept README v1; provide pre-import `--json` captures for Gate 0 |
| Phase 1 | Run `rake fixtures:record` once (live API calls), review the recorded fixtures diff; approve the refactor list before execution; adjudicate any bug found (fix vs pin as-is) |
| Gate 2 | Review dry-run artifact set; create KV namespace + scoped token; run first real publish by hand |
| Gate 3 | Visual review in preview.html; `rake golden:approve` |
| Gate 4 | `wrangler deploy` / Pages publish; smoke checklist |
| Phase 5 / Gate 5 | Install launchd/cron entries; one-week soak; tag v1 |
| Any time | Adjudicate `blocked: decision-item` packets (semantics/contract questions) |

## 8. Phase & packet breakdown

Packet lists are the plan; each phase's packets get full
Goal/Acceptance elaboration at the previous phase's gate. IDs `M<phase>-<n>`.

**Phase 0 -- inventory, documentation + safety net** *(Stage 0: all code
Fable; in progress -- skeleton, import, and seed test done)*
- M0-1 `phase-0` branch, `.claude/settings.json` permission profile,
  `docs/BACKLOG.md` + `docs/WORKLOG.md` bootstrap [fable]
- M0-2 tool inventory & review memo (`docs/TOOL-REVIEW.md`): all of
  `scripts/` -- purpose, sources, contracts, maturity, weak spots,
  refactor candidates [fable; owner reviews]
- M0-3 `README.md` v1: capabilities + commands as they exist today,
  per-tool maturity honestly stated [fable draft; owner accepts]
- M0-4 characterization: `bs_gamma` (known values, put/call symmetry) [fable]
- M0-5 characterization: OSI/Deribit instrument parsing [fable]
- M0-6 characterization: percentile envelope fit + Lomb-Scargle on
  synthetic sinusoid [fable]
- M0-7 characterization: btco CEBE/mNAV/convert ITM-OTM on synthetic
  universe [fable]
- M0-8 characterization: ingest pure parts (`excerpt`, `diff_against`) [fable]
- Gate 0: byte-identical `--json` vs owner-provided captures; memo +
  README accepted [human]

**Phase 1 -- seams, contracts + reviewed refactoring** *(Stage 0: all
code Fable)*
- M1-1 `lib/btc/http.rb` + injectable transport [fable]
- M1-2..5 migrate each suite's `Common.get_json` onto the seam, one
  suite per packet [fable]
- M1-6 implement `rake fixtures:record` [fable; execution is human]
- M1-7..11 contract tests: one per module + ingest proposal schema [fable]
- M1-12 `BTC_DATA_DIR` override [fable]
- M1-13..n refactor packets from the owner-approved Phase 0 list, one
  finding per packet, behavior-preserving [fable]
- Gate 1: field-set diffs empty; refactor list resolved; README updated
  [human]

**Phase 2 -- publish pipeline** *(Stage A begins)*
- M2-1 `publish/kv_client.rb` [fable -- retries, auth, redaction]
- M2-2 `publish/publish.rb` orchestrator + envelopes + dry-run [opus]
- M2-3 redaction/retry/dry-run test battery [opus, fable review]

**Phase 3 -- chart specs**
- M3-1 `gex_profile` spec [fable -- family pattern-setter]
- M3-2..4 `scenario_strip`, `lppl_regime`, `btco_table` [opus]
- M3-5 `web/preview.html` offline harness [opus]

**Phase 4 -- Cloudflare layer** *(Stage B begins)*
- M4-1 `worker.js` + `wrangler.toml` [opus, fable review of auth/headers]
- M4-2 `public/index.html` + `app.js` loader + staleness badges [opus]

**Phase 5 -- ops artifacts** *(drafts only; installation is human)*
- M5-1 launchd/cron entry files + tmux health line [opus]
- M5-2 `docs/RUNBOOK.md` [opus draft, sonnet polish]

## 9. CI (proposed)

GitHub Actions on every push/PR: `rake compat && rake test` on Ruby 3.3
(`ruby/setup-ruby`, ubuntu-latest) as the always-on oracle, plus a
`macos-latest` (Apple Silicon) job running the same suite so the target
architecture is exercised on every change. No gems to install (stdlib +
bundled minitest), so both jobs are fast and dependency-free. Becomes a
Phase 0 packet (M0-1 scope) if approved.

## 10. Decisions (approved by owner, 2026-07-03)

1. **Plan approved** with amendments incorporated (Ruby 3.3+/Apple
   Silicon retarget; Stage 0 legacy hardening, interactive, Fable-only
   code; README updated before every gate).
2. **Git hosting:** private `arvicco/mimir`. **Push policy:** the loop
   pushes `phase-N` branches and opens PRs; `main` stays owner-merged
   (nabu policy -- makes the CI oracle bite on every PR).
3. **In effect:** `docs/BACKLOG.md` carries the elaborated packets,
   `.claude/settings.json` carries the permission profile,
   `.github/workflows/ci.yml` runs compat+test on ubuntu and
   macos-arm64, work proceeds on `phase-N` branches (M0-1 done).
4. **Outstanding owner input:** pre-import `--json` captures for
   Gate 0 -- run each tool once, save output (the loop prints the
   exact commands when Gate 0 approaches).
