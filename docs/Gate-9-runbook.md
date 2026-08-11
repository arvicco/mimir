# Gate 9 runbook — merge phase-9 (LPPL statistics revision) + tag v1.1

Phase 9 is the SBI-review LPPL statistics revision. Every wave-1/2 change
was SHADOW-first: each new statistic ships ADDITIVE and report-only, next
to its frozen original, so no verdict/score/threshold/weight moved (Golden
Rule 4). M9-11 makes those shadow numbers VISIBLE — a compact "shadow"
scoreboard on the LPPL card — so the D9-* rulings can be made with the
frozen-vs-shadow comparison in front of you during the soak.

Five steps, in order. Each says exactly what to run/open and what you
should see (EXPECT). If an EXPECT fails, stop and tell the loop — don't
improvise past a failed step. Background is at the end; you don't need it
to run the gate.

## 1. Preview eyeball — the shadow scoreboard

```
cd ~/Dev/mimir/.worktrees/phase-9
rsync -a ~/Dev/mimir/scripts/lppl/data/ scripts/lppl/data/        # cached inputs (gitignored)
rsync -a ~/Dev/mimir/scripts/scenario/data/ scripts/scenario/data/
PUBLISH_DRY_RUN=1 ruby publish/publish.rb                          # EXPECT: 26 written, 0 skipped
PORT=8011 rake preview      # 8000 may be squatted by the main-repo server; use a fresh port
```

Open http://localhost:8011/web/preview.html and look at the **LPPL card**.

EXPECT (design-skill surface review, LPPL card only):
- A compact right-side block titled **shadow**, top-right, six rows, each
  frozen value then its shadow value:
  ```
  shadow
  mean/eval  -1.26          (density-honest trend; ≈ the frozen BF panel,
                             per-eval instead of a density-inflated sum)
  365/730    -0.11/+0.16    (report-only long horizons; +0.16 = the power
                             law winning at 24mo)
  damping    0.41 (<1)      (fit anti-bubble condition, unmet)
  impr       29.2→27.9%     (frozen vs symmetric-null RMSE improvement)
  p(osc)     .38→.24        (AR(1) vs GARCH bootstrap p; both > .05)
  freeze     .439→.358      (live envelope bound vs pre-trough candidate)
  ```
- Row names right-aligned, values left-aligned in the column; the `→`
  arrows and the leading-zero-stripped numbers (`.38`, `.439`) render.
- No clipping at the card's right edge, no collision with the ratio pin
  (`0.472`) or the three panels; the three evidence panels keep their
  height. Console clean.
- Hover the card's ⓘ: the help bubble now ends with one sentence per row
  naming its decision item (mean/eval → D9-b, 365/730 → D9-c, damping +
  impr → D9-e, p(osc) → D9-f, freeze → D9-g).

Note: the preview shows the LIVE-cache numbers above; the committed golden
pins the FIXTURE numbers (frozen impr 43.5→27.9, p .19→.24, mean/eval
-1.17), which differ deliberately — the fixture predates the real values.

## 2. Bless the golden

Only `chart_lppl_regime.json` should move (M9-11 touched no other chart).

```
rake golden:approve                 # deterministic; regenerates all 12 from fixtures
git status --short test/golden/     # EXPECT: only M test/golden/chart_lppl_regime.json
rake                                # EXPECT: compat OK, health OK, test 0 failures
```

EXPECT: exactly one golden shows as modified. If any OTHER golden diffs,
STOP — a chart changed that shouldn't have.

(The loop already blessed this golden PROVISIONAL in the M9-11 feat
commit; this step is your formal re-bless after looking at step 1.)

## 3. Merge and deploy (your actions; loop verifies CI first)

After the merge lands, remove the phase worktree in the same sitting
(owner ruling 2026-08-11: a stale worktree after its phase ends is an
anti-pattern; `rake health` fails until it is gone):
```
cd ~/Dev/mimir && git worktree remove .worktrees/phase-9
```


Open the PR:
https://github.com/arvicco/mimir/compare/main...phase-9
(or `gh pr create --base main --head phase-9 --title "Phase 9: LPPL statistics revision"`).

EXPECT before merging: CI green on the phase-9 head —
```
gh run list --repo arvicco/mimir --branch phase-9 --limit 1   # EXPECT: success
```

After the merge, on main:
```
cd ~/Dev/mimir && git checkout main && git pull
gh run list --repo arvicco/mimir --branch main --limit 1      # EXPECT: success
rake deploy        # interactive; includes one real publish
git tag v1.1 && git push origin v1.1
```

EXPECT from the deploy's publish: **`PUB LIVE 26/26 keys`** — the key
count is UNCHANGED (Phase 9 added only report-only --json fields and one
card's right-hand column; no new KV key). If you see anything other than
26/26, stop.

Then put the working tree back on main so the launchd agents run the
released code.

## 4. Live dashboard verification (the outcome check)

Open: https://mimir-cd12ef34.neromontanero.workers.dev
(Hard-reload — Cmd+Shift+R — a tab left open shows old data.)

EXPECT:
- The **LPPL card** now renders the `shadow` scoreboard with REAL,
  live-cache values (roughly the step-1 numbers, drifting daily), beside
  the unchanged three-panel evidence plot. The verdict, composite and
  panels are byte-for-byte what they were pre-deploy — only the right
  column is new.
- Cross-check one row against the payload, not against the render:
  ```
  curl -s https://mimir-cd12ef34.neromontanero.workers.dev/api/v1/lppl:latest \
    | ruby -rjson -e 'd=JSON.parse(STDIN.read)["payload"]; f=d["tests"].find{|t|t["name"]=="fit"}["detail"]; puts "impr #{f["rmse_impr_pct"]} -> #{f["improvement_v2"]}"'
  ```
  EXPECT: the two numbers match the card's `impr` row.
- Every card badge is a bare dot; hover the LPPL badge for age/ttl.
- Header dot cluster all green after the next bi-hourly tick; 26 keys.

Soak note (what to watch over the following days): the shadow fields are
appended once a day by the **04:45 suite-history run** (the same append
that grows the ledger/scenario history). So the scoreboard's numbers
should show a NEWER reading each day than the day before — that day-over-
day movement of frozen-vs-shadow is exactly the evidence the D9 rulings
need. If a row's numbers are identical for several days, the daily append
is not landing; check `~/Library/Logs/mimir/publish.log`.

## 5. The D9 decisions — where each one's evidence now lives

Rule each of these with the data in front of you. Five of the seven are
on the LPPL card's `shadow` scoreboard (row → field); two (D9-a, D9-d)
are not on the card — their evidence is in `lppl:latest` --json / a
research script, noted below. All fields are additive and report-only:
nothing is gating until you rule it so.

- **D9-a — composite refusal + dead-module weight.** NOT on the
  scoreboard (it changes verdict behavior on OUTAGE days, not a shadow
  statistic). Evidence: the blind-day mechanics (M8-8/9/10) — a fully
  unavailable day forces the composite to 0 and the scenario strip greys
  that point; `lppl.rb`'s composite still divides by the full weight
  denominator. Decide: refuse a composite when a weight-3 module fails?
  drop dead modules from the denominator?
- **D9-b — trend normalization (per-eval mean as headline).** Row
  `mean/eval` = sum of `trend.detail.per_horizon.{30,90,180}.mean_per_eval`
  (packet M9-1, aa2d1a7). This equals the density-honest headline
  (-1.26) vs the frozen density-inflated BF sum the BF panel draws.
- **D9-c — do 365/730d horizons enter the scoring band?** Row `365/730`
  = `trend.detail.per_horizon_long.{365,730}.mean_per_eval` (packet M9-8,
  d2a03da). The differential flips POSITIVE at 730d.
- **D9-d — PL+LP1 rival adoption.** NOT on the scoreboard (it changes
  what "trend vs the power law" MEANS, not a single comparison). Evidence:
  `trend.detail.pl_lp1{per_horizon,omega,clock}` (packet M9-9, d085814) —
  the coupled log-periodic mode ~ties pure PL out-of-sample (34% in-sample
  variance, ~zero predictive gain, slightly worse at long horizons). Rule
  from the --json / the M9-9 worklog line.
- **D9-e — flip B<0 / damping / symmetric-null from report-only to
  gating.** Rows `damping` (= `fit.detail.damping` vs
  `damping_ref_threshold`, packet M9-5, bd8a898; `<1` = condition unmet)
  and `impr` (= `fit.detail.rmse_impr_pct` vs `improvement_v2`, packet
  M9-6, ccae0c7; the null-tc grid-edge artifact clears under v2). The
  `b_negative` flag rides the same --json (M9-5) but is not drawn.
- **D9-f — which bootstrap p-value becomes headline.** Row `p(osc)` =
  `logperiodic.detail.p_value` (AR(1)) vs `p_value_v2` (AR(1)+GARCH),
  packet M9-7, e2dc9dd. Both non-significant (.38 vs .24).
- **D9-g — envelope freeze rule.** Row `freeze` =
  `envelope.detail.bound` (live, drifting) vs `freeze_candidate` (the
  2022 bound frozen before the subsequent trough), packet M9-4, 2dc4fa1.

Any flip you rule here (D9-e/f/g especially) is a SEPARATE reviewed
packet that moves a report-only field into a verdict — not part of this
gate. This gate only makes the evidence visible and soakable.

## Background (not needed to run the gate)

Phase 9 = the SBI review's LPPL statistics revision, delivered shadow-
first across two waves (M9-1..10) plus this surfacing packet (M9-11).
Golden Rule 4 was held end-to-end: post-wave trend/fit/logperiodic frozen
--json fields are byte-identical to the pre-wave recording; the shadow
numbers sit BESIDE them, never replacing them.

M9-11 (this gate's packet): the LPPL card gained a right-side `shadow`
scoreboard (side-panels-right ruling). The six rows come additively
through the `lppl:latest` payload the publish already carries into
`chart:lppl_regime`; the builder reads them DEFENSIVELY — a missing
shadow field drops that row, and a payload with no shadow fields at all
degrades the card to its pre-M9-11 three-panel form. No verdict, panel or
score content changed. Fixture `payload_lppl_latest.json` was extended
additively with realistic synthetic shadow values (noted in
`test/fixtures/payloads/README.md`); the golden is PROVISIONAL until your
step-2 re-bless.

Preview gotcha (bit us here and at M8-6/M8-17): a stale `rake preview`
server left running from ANOTHER worktree (e.g. ~/Dev/mimir) silently
keeps answering port 8000 and serves ITS old artifacts — a screenshot
then shows the pre-change card. Use a fresh `PORT=`, or check
`lsof -nP -iTCP:8000 -sTCP:LISTEN` before trusting a shot.

KV quota (Gate 5 carry-over, still comfortable): 26 keys × 12 runs/day
≈ 312 writes/day, ~30% of the free tier. Unchanged by Phase 9.

This file supersedes the GATE 9 sketch in docs/BACKLOG.md (owner ruling
2026-07-11: gate instructions always live in a dedicated
Gate-N-runbook.md, fully specific).
