# Gate 9 runbook — merge phase-9 (LPPL statistics revision) + tag v1.1

Phase 9 is the SBI-review LPPL statistics revision. Every wave-1/2 change
was SHADOW-first: each new statistic ships ADDITIVE and report-only, next
to its frozen original, so no verdict/score/threshold/weight moved (Golden
Rule 4). M9-11 made those shadow numbers VISIBLE; M9-13 (owner ruling
2026-08-11, at this preview) moved them off the LPPL panels' right margin
onto a **SHADOW tab** of the same card — the three LPPL panels get their
full width back, and every shadow number gets a plain-language hover
explanation — so the D9-* rulings can be made with the frozen-vs-shadow
comparison, and its meaning, in front of you during the soak.

Five steps, in order. Each says exactly what to run/open and what you
should see (EXPECT). If an EXPECT fails, stop and tell the loop — don't
improvise past a failed step. Background is at the end; you don't need it
to run the gate.

## 1. Preview eyeball — the SHADOW tab

Ask the loop: **"serve the gate preview"** (all branch-side prep is the loop's
job; owner ruling 2026-08-11: you never touch paths outside ~/Dev/mimir).

Open http://localhost:8000/web/preview.html and look at the **LPPL card**.
Its head now carries a **[LPPL][SHADOW]** tab pair.

EXPECT (design-skill surface review, LPPL card only):
- Default tab **LPPL**: the three evidence panels (ratio / log10 BF / Z)
  at FULL card width — the pre-M9-11 form, no right-hand column, no
  clipping, the ratio pin (`0.472`) intact.
- Click **SHADOW**: title `Shadow diagnostics · 6 checks`, subtitle
  `frozen → shadow · hover a row for what it means`, then six readable
  rows — stat name (bold), frozen value, an amber `→`, the shadow value,
  and a one-phrase verdict — all visible WITHOUT hover:
  ```
  mean/eval  -461.34 →  -1.26   rivals win
  365/730     -0.11  → +0.15     wins at 2y
  damping      >=1   →  0.42     not met
  impr        28.9%  → 27.6%     still wins
  p(osc)       .40   →  .25      still noise
  freeze       .439  →  .358     drift flatters
  ```
- Hover any SHADOW row: a block opens with the bold stat name, the
  `frozen … → shadow …  <verdict>` line, then a plain-language paragraph
  explaining the number and naming its decision item. It must stay fully
  inside the viewport (hover the bottom `freeze` row — the tooltip flips
  ABOVE the pointer). Console clean.
- The default tab is LPPL (SHADOW is never the landing tab).
- **M9-15 glossary hovers** (other cards): on the GEX card's **BTC TREND**
  tab hover the **CW** legend entry, on the Volatility card hover **RR25**,
  on the Scenario card hover the **macro** module name — each explains
  itself in a sentence or two (the same styled block), staying inside the
  viewport; the GEX card's venue toggles (DERI/IBIT/…) do the same on hover.

Note: the preview shows the LIVE-cache numbers above; the committed golden
pins the FIXTURE numbers (frozen impr 43.5→27.9, p .19→.24, mean/eval
-427.34→-1.17), which differ deliberately — the fixture predates the real
values. The hover paragraphs quote representative live numbers verbatim
(owner-approved), independent of the row's own frozen/shadow values.

## 2. Bless the goldens

Exactly TWO goldens should move: `chart_lppl_regime.json` reverts to its
pre-M9-11 three-panel content, and the NEW `chart_lppl_shadow.json`
appears. No other chart changed.

```
rake golden:approve                 # deterministic; regenerates all 13 from fixtures
git status --short test/golden/     # EXPECT: M chart_lppl_regime.json + ?? chart_lppl_shadow.json
rake                                # EXPECT: compat OK, health OK, test 0 failures
```

EXPECT: only those two goldens differ. If any OTHER golden diffs, STOP —
a chart changed that shouldn't have.

(The loop already blessed both goldens PROVISIONAL in the M9-13 feat
commit; this step is your formal re-bless after looking at step 1.)

## 3. Merge and deploy (your actions; loop verifies CI first)



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

EXPECT from the deploy — TWO new lines from the M9-12 live-runtime sync:
- `live runtime -> <sha7>` where `<sha7>` is the first 7 chars of the
  `main` commit you just deployed (the deploy REFUSES if that commit is
  not pushed to origin — `git push` first if it stops here).
- `publishing data from live runtime .../mimir/live (BTC_DATA_DIR=.../mimir/data)`
  — the publish runs from the app-managed copy, not your dev folder.

EXPECT from the deploy's publish: **`PUB LIVE 27/27 keys`** — one MORE
than before Phase 9. M9-13 adds exactly one new KV key, `chart:lppl_shadow`
(the SHADOW tab is its own chart sharing the LPPL card); the frozen
analytics --json fields are otherwise unchanged. If you see anything other
than 27/27, stop.

You do NOT need to leave any particular branch checked out afterward:
from M9-12 on, the launchd agents run from the live runtime copy, so
`~/Dev/mimir` is a normal git folder whose branch never affects
production.

## 3a. Switch production to the live runtime (M9-12, one time)

This is the ONE step that moves the launchd agents off your dev folder
and onto the app-managed copy, and migrates their data. It is safe and
atomic: until you run it, the agents keep running exactly as today.

```
cd ~/Dev/mimir
rake ops:install        # interactive; refuses under CI / without a TTY
```

EXPECT, in order:
- a `pre-flight:` table of `[ok ]` rows, INCLUDING a new
  `live runtime` row → `present .../Library/Application Support/mimir/live`
  (if it says `MISSING … run rake deploy first`, you skipped step 3 —
  go back).
- a `migration inventory (dev tree -> data home):` table — one line per
  suite (`lppl`, `scenario`, `gex_history`, `vol_history`, `vol_spread`,
  `source_cache`) showing `N file(s), N to copy / 0 skip` and the
  `source -> destination` mapping. Answer `y` to
  `copy N file(s) into the data home now?`.
  EXPECT: `migrated: N copied, 0 skipped, 0 error(s).`
- a `verification:` table where every row is `[PASS]`, for the THREE
  agents (`com.mimir.publish`, `com.mimir.gex-snapshot`,
  `com.mimir.suite-history`) — each `plist`/`bootstrap` row now shows
  `program = .../Library/Application Support/mimir/live/ops/run_*.sh`
  (the live copy, NOT `~/Dev/mimir`). Answer `y` to each
  `kickstart <label> now?`; EXPECT the publish `run` row →
  `publish LIVE: 27 written …` and its `status file` row → `PUB LIVE 27/27 …`.

NOTE (data continuity): migration copies your EXISTING histories into the
data home before the agents' next tick, so the ledger / scenario history
/ snapshot files keep growing with no gap. One caveat: the step-3 deploy
publish above ran before this migration, so for that single publish the
history-derived charts read empty; the kickstarted publish here (and
every scheduled one after) reads the full migrated tails. If you want to
avoid even that one-publish blip, run step 3 as
`DEPLOY_SKIP_PUBLISH=1 rake deploy` (creates the live copy, no publish),
then this step, then a plain `rake deploy` to publish from the populated
data home.

IMPORTANT: after this step, make sure `~/.config/mimir/env` does NOT pin
`BTC_DATA_DIR` to the old in-tree path — the wrappers default it to the
data home only when it is unset (an explicit value still wins). Comment
out any `BTC_DATA_DIR=...` line there, or set it to
`$HOME/Library/Application Support/mimir/data`.

## 4. Live dashboard verification (the outcome check)

Open: https://mimir-cd12ef34.neromontanero.workers.dev
(Hard-reload — Cmd+Shift+R — a tab left open shows old data.)

EXPECT:
- The **LPPL card** now carries the **[LPPL][SHADOW]** tab pair. The LPPL
  tab is the three-panel evidence plot at full width — verdict, composite
  and panels byte-for-byte what they were pre-deploy. The SHADOW tab shows
  the six rows with REAL, live-cache values (roughly the step-1 numbers,
  drifting daily); hover a row for its explanation.
- Cross-check one row against the payload, not against the render:
  ```
  curl -s https://mimir-cd12ef34.neromontanero.workers.dev/api/v1/lppl:latest \
    | ruby -rjson -e 'd=JSON.parse(STDIN.read)["payload"]; f=d["tests"].find{|t|t["name"]=="fit"}["detail"]; puts "impr #{f["rmse_impr_pct"]} -> #{f["improvement_v2"]}"'
  ```
  EXPECT: the two numbers match the SHADOW tab's `impr` row.
- Every card badge is a bare dot; hover the LPPL badge for age/ttl.
- Header dot cluster all green after the next bi-hourly tick; 27 keys.

Soak note (what to watch over the following days): the shadow fields are
appended once a day by the **04:45 suite-history run** (the same append
that grows the ledger/scenario history). So the SHADOW tab's numbers
should show a NEWER reading each day than the day before — that day-over-
day movement of frozen-vs-shadow is exactly the evidence the D9 rulings
need. If a row's numbers are identical for several days, the daily append
is not landing; check `~/Library/Logs/mimir/publish.log`.

## 5. The D9 decisions — where each one's evidence now lives

Rule each of these with the data in front of you. Five of the seven are
on the LPPL card's **SHADOW tab** (row → field); two (D9-a, D9-d)
are not on the card — their evidence is in `lppl:latest` --json / a
research script, noted below. All fields are additive and report-only:
nothing is gating until you rule it so.

- **D9-a — composite refusal + dead-module weight.** NOT on the
  SHADOW tab (it changes verdict behavior on OUTAGE days, not a shadow
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
- **D9-d — PL+LP1 rival adoption.** NOT on the SHADOW tab (it changes
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

M9-11 first surfaced the six shadow checks as a right-side scoreboard on
`chart:lppl_regime`. M9-13 (this gate's final surfacing packet, owner
ruling 2026-08-11) reverts that: `lppl_regime` is once again the pre-M9-11
three-panel card, and the checks move to a new `chart:lppl_shadow` — the
**SHADOW tab** of the same card (`tab_group 'lppl'`, LPPL is tab_pos 0 /
default). The rows read at full width — stat, frozen, `→`, shadow, verdict
— and each carries an owner-approved plain-language hover explanation via
the `lppl_shadow` renderer formatter (numbers alone were an
"incomprehensible mess"). Both charts read the `lppl:latest` payload the
publish already carries; the shadow builder reads DEFENSIVELY — a missing
shadow field drops that row. No verdict, panel or score content changed;
the only KV delta is the new `chart:lppl_shadow` key (26 → 27). Fixture
`payload_lppl_latest.json` carries the synthetic shadow values (noted in
`test/fixtures/payloads/README.md`); both goldens are PROVISIONAL until
your step-2 re-bless.

Preview gotcha (bit us here and at M8-6/M8-17): a stale `rake preview`
server left running from another checkout silently
keeps answering port 8000 and serves ITS old artifacts — a screenshot
then shows the pre-change card. Use a fresh `PORT=`, or check
`lsof -nP -iTCP:8000 -sTCP:LISTEN` before trusting a shot.

KV quota (Gate 5 carry-over, still comfortable): 27 keys × 12 runs/day
≈ 324 writes/day, ~32% of the free tier. Phase 9 adds one key
(`chart:lppl_shadow`).

This file supersedes the GATE 9 sketch in docs/BACKLOG.md (owner ruling
2026-07-11: gate instructions always live in a dedicated
Gate-N-runbook.md, fully specific).
