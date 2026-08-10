# CLAUDE.md -- mimir

Ruby analytics (GEX / scenario signals / LPPL evidence) published as
pre-built chart specs to Cloudflare KV, rendered by a dumb static
frontend. Read ARCHITECTURE.md before any non-trivial task; it defines
the phases, data contracts, and review gates that govern this repo.

## Golden rules (non-negotiable)

1. **Target Ruby is 3.3+** on Apple Silicon (arm64-darwin) for
   everything under `scripts/`, `lib/`, `publish/`. Write idiomatic
   modern Ruby, but stay within the 3.3 feature set (no 3.4+/4.x-only
   constructs) so CI and every target Mac agree. Existing code written
   for older rubies is modernized only as part of a reviewed refactor
   task, never as a drive-by.
2. **stdlib only** in runtime code (`net/http`, `json`, `time`,
   `fileutils`, `timeout`, `matrix`). No gems, no Gemfile for runtime.
   Tests use bundled minitest. Never add a dependency without asking.
3. **Never run deploys or network-mutating commands.** `wrangler deploy`,
   Pages publish, KV namespace/token creation, and the first real
   (non-dry-run) publish are HUMAN actions. You may prepare configs and
   print the exact commands.
4. **Never change analytics semantics silently.** Scoring thresholds,
   weights, filter bands, probability mappings, model parameters are
   research decisions. If a task seems to require touching them, stop and
   flag it as a decision item.
5. **`--json` and `--tmux` outputs of every script are frozen contracts.**
   Additive fields only, and only with a contract-test update in the same
   commit.
6. **No network in tests.** All HTTP goes through `lib/btc/http.rb`
   (Phase 1+); tests inject a fake transport and use `test/fixtures/`.
   The only network task is `rake fixtures:record`, run manually.
7. **Minimal diffs.** These scripts run in production cron. Prefer the
   smallest behavior-preserving change; do not reformat, rename, or
   "clean up" beyond the task's scope.
8. Secrets (`CLOUDFLARE_API_TOKEN`, `FRED_API_KEY`) come from ENV only. Never
   read, print, or commit them; error paths must redact.

## Commands

```
rake test                 # full minitest suite (must pass before any commit)
rake test:unit            # math/parsing only
rake test:contract        # --json field-set contracts (fixtures)
rake compat               # ruby -c syntax check of every Ruby file
rake health               # offline conventions/interface + source-registry scan
rake health:sources       # probe upstream data sources -- NETWORK, read-only
rake fixtures:record      # refresh API fixtures -- NETWORK, ask first
rake golden:approve       # bless regenerated chart specs after visual review
ruby scripts/lppl/lppl.rb --skip-update   # run suites offline against cache
PUBLISH_DRY_RUN=1 ruby publish/publish.rb # publish pipeline, no network
```

`rake compat`, `rake health` and `rake test` are the pre-commit gate
(= `rake`); all green or the commit does not happen. New hard-coded
data sources MUST be registered in lib/btc/health.rb's SOURCES in the
same commit (`rake health` fails on registry drift).

## Workflow (every task)

1. **PLAN.** Restate the task, list files to touch, tests to add, contracts
   affected, and which phase/gate (ARCHITECTURE.md section 6) it belongs
   to. Wait for approval on anything touching >3 files, any contract, any
   analytics semantics, or anything in `web/`.
2. **TESTS FIRST.** Red-green-refactor. For changes to existing untested
   code, write characterization tests pinning current behavior BEFORE
   modifying it. New pure functions get exact-value tests; parsers get
   fixture tests; chart specs get golden files.
3. **IMPLEMENT** to green with the minimal diff.
4. **SELF-REVIEW** against the checklist below, then produce a short
   summary: what changed, why, test evidence (`rake test` + `rake compat`
   output), contract impact (none/additive), open questions.
5. **README before every gate.** Each phase gate includes an updated
   `README.md` -- the user-facing document describing the capabilities
   and commands implemented up to this point, honest about what does
   not work yet. A newcomer reading only the README should know exactly
   what the tools can do today.
6. **STOP at gates.** Phase boundaries and anything listed in Golden Rule
   3 end your turn with a handoff summary, not an action.
7. **Gate instructions live in `docs/Gate-N-runbook.md`** (owner ruling
   2026-07-11), one file per gate, written for a human runner: numbered
   steps with full copy-pasteable commands, real URLs/links, and an
   EXPECT line per step; background quarantined at the end. Never bury
   a gate checklist in BACKLOG.md or a chat summary; keep the runbook
   current as gate scope evolves.

### Self-review checklist
- [ ] Ruby 3.3-compatible (`rake compat` clean; no 3.4+/4.x-only constructs)
- [ ] stdlib only; no new deps
- [ ] tests added/updated and green; no network in tests
- [ ] `--json` / `--tmux` contracts unchanged or additive + tested
- [ ] no analytics threshold/weight changed (or explicitly flagged)
- [ ] no secrets in code, logs, fixtures, or error messages
- [ ] diff is minimal; unrelated code untouched
- [ ] file header comment updated if behavior/usage changed
- [ ] success claims cite an outcome-level check (what would a user
      see?), not only signals the system emits about itself
- [ ] CI green on the pushed head before calling a packet done -- the
      local ruby is NEWER than the 3.3 target, so the local gate cannot
      catch 3.3-runtime differences (e.g. Hash#inspect spacing); CI is
      the 3.3 authority

### Verification discipline (owner-ruled 2026-07-07, after the
### frozen-evidence incident -- docs/WORKLOG.md that date)
1. **Outcome-first.** No "done / green / proven live" claim without at
   least one check at the outermost user-visible surface, asserting the
   outcome against a reference INDEPENDENT of the system under test.
   For publish/ops work: fetch the LIVE dashboard's data and compare
   the newest data point INSIDE the payloads (ledger ts, history ts,
   price date) against the wall clock -- never against `generated_at`,
   which the pipeline itself mints.
2. **Decommissioning inventory.** Before any process is retired or
   replaced, enumerate every duty it performed (full command lines,
   every file it wrote, every side effect) and map each duty to a
   successor. Unmapped duties become decision items, never silent
   drops. (The incident: the retired cron ran `--history`; the new
   agents didn't; nobody diffed the two.)
3. **Contradiction protocol.** When the owner's observation contradicts
   telemetry, the default assumption is a telemetry blind spot.
   Reproduce what they see at THEIR surface first, then work inward.
   Hard rule: never re-assert health from an instrument already
   contradicted once -- find an independent one.
4. **Content-progress invariants.** Every scheduled producer carries a
   machine-checked invariant on its OUTPUT's progress, not its
   execution ("if a duty matters enough to schedule, its outcome
   matters enough to monitor"). See ops/publish_health.rb's OLD flag
   and the daily evidence agent.
5. **Surface review = the full checklist** in docs/DEV-LOOP.md section
   6b (elements present and filled, order/placement, per-chart data
   recency vs cadence, no NaN/null/empty renders, cross-element
   consistency, designed failure states shown honestly, interactions
   respond, clean console, real geometry + mobile, keyboard floor) --
   liveness markers alone are NEVER sufficient. Gate soaks include
   "the surface shows newer data each day than the day before."

## Code style

- `# frozen_string_literal: true` in every file.
- Every script keeps the established header contract: purpose, usage
  examples, scoring/semantics, data-source notes, caveats -- in the file,
  not in external docs.
- Module functions over classes unless state demands otherwise; small
  lambdas for local helpers are idiomatic here.
- `format` with explicit widths for aligned terminal output (existing
  convention); no string interpolation in status lines.
- Fail-soft pattern for data sources: report score 0 with a reason,
  exit 0. A dead API must never break an aggregate.
- Names: snake_case files, one purpose per file, aggregators named after
  the suite (`scenario.rb`, `lppl.rb`, `publish.rb`).

## Testing conventions

- minitest, `test/unit/test_*.rb`, one behavior per test method.
- Fixtures are real recorded responses, trimmed to minimum size, named
  `<source>_<shape>.json` (e.g. `deribit_book_summary.json`).
- Golden chart specs live in `test/golden/`; a failing golden diff is
  presented for review, never auto-approved (that is what
  `rake golden:approve` is for, after the human looks at preview.html).
- Deterministic seeds for anything stochastic (bootstrap sims use
  `Random.new(42)` -- keep it that way in tests).

## Git conventions

- Work happens on phase branches (`phase-0`, `phase-1`, ...) pushed to
  origin; `main` is owner-merged at gates (see docs/DEV-LOOP.md).
- Conventional commits: `feat:`, `fix:`, `test:`, `refactor:`, `docs:`,
  `chore:`; imperative subject <= 72 chars; body explains WHY.
- One logical change per commit; tests in the same commit as the code
  they cover. Never commit `data/`, `*.status`, fixtures containing
  secrets, or `.env`.
- Do not rewrite published history; do not tag -- tags are gate actions.

## Repo map (details in ARCHITECTURE.md section 3)

- `scripts/` production analytics -- highest caution, characterize first;
  `scripts/btco/universe.json` changes ONLY via ingest.rb's reviewed
  proposals (or a deliberate human edit) -- never write to it directly
- `lib/` shared seams (Phase 1+)
- `publish/` KV client, chart specs, orchestrator (Phases 2-3)
- `web/` Worker + static frontend; minimal dumb JS; no npm, ECharts via
  pinned CDN tag (Phase 4)
- `test/` unit / contract / golden / fixtures

## Current phase

Phase 9 (LPPL statistics revision, branch phase-9 in
~/Dev/mimir-phase9; Gate 8 closed 2026-08-10 -- PR #9 + hotfix #10,
deployed + live-verified, 26 keys). Spec = the SBI consolidated
review; packets M9-1..10 + decision items D9-a..g in docs/BACKLOG.md.
SHADOW-FIRST: verdict-affecting changes ship as additive report-only
fields and flip only on owner rulings (Golden Rule 4). BTCo stays
FROZEN (2026-08-10 ruling). Stage A tiering; visual work follows
.claude/skills/mimir-design; deploys and launchd changes are HUMAN
actions. Update this line at each gate.
v1 tagged at 03cac84, deployed and live-verified). **BTCo
development is FROZEN (owner ruling 2026-08-10, pending a rethink)**:
no BTCo packets, no ingest work, no universe edits; code and tests
stay. Owner rulings 2026-08-10: BTCo table stays VISIBLE (as a
rethink reminder), the daily btco-alert agent STOPS, dashboard
auto-refresh gets BUILT (pre-Gate-8 packet). Gate 8 = vol/GEX family
(M8-1..M8-10 built) + pre-gate hardening; runbook
docs/Gate-8-runbook.md. After Gate 8: Phase 9 (LPPL statistics
revision from the SBI review; every verdict-affecting change is a
Golden-Rule-4 decision item). Stage A tiering (DEV-LOOP.md section
2): Fable orchestrates/reviews, Opus/Sonnet write most code in
isolated worktrees. Visual work follows .claude/skills/mimir-design;
deploys and launchd changes are HUMAN actions (Golden Rule 3).
Update this line at each gate.
