# Gate 8 runbook — Phase 8A (GEX/volatility family) goes live

Run AFTER Gate 7 is closed (phase-7 merged to main, v1 tagged — see
docs/Gate-7-runbook.md). Five steps. Each step says exactly what to
run/open and what you should see (EXPECT). If an EXPECT fails, stop
and tell the loop.

## 1. Rebase phase-8 onto the merged main (ask the loop, or run)

```
cd ~/Dev/mimir-phase8
git fetch origin && git rebase origin/main
rake            # full gate: compat + health + test
git push --force-with-lease origin phase-8
```

EXPECT: rebase applies cleanly (phase-8 was cut from phase-7's head,
so after the Gate-7 merge the only new base commits are the merge
itself); `rake` ends green (~619 runs, 0 failures); CI green on the
pushed head:
```
gh run list --repo arvicco/mimir --branch phase-8 --limit 1
```
This is the one step the loop can do for you — force-with-lease after
a rebase is the sanctioned exception to the no-force rule, say the
word.

## 2. Preview eyeball (offline, nothing published)

```
cd ~/Dev/mimir-phase8
# one-time: the worktree has none of the gitignored runtime data, so
# the LPPL/scenario history producers SKIP and their cards vanish
# (bit us 2026-08-10 -- 18/22 keys, 3 cards). Copy it from the main
# tree first:
rsync -a ~/Dev/mimir/scripts/lppl/data/ scripts/lppl/data/
rsync -a ~/Dev/mimir/scripts/scenario/data/ scripts/scenario/data/
rsync -a ~/Dev/mimir/data/gex_history/ data/gex_history/
rsync -a ~/Dev/mimir/data/vol_history/ data/vol_history/ 2>/dev/null || true
PUBLISH_DRY_RUN=1 ruby publish/publish.rb   # EXPECT: no SKIP lines, 25 keys (incl. index)
rake preview
```

Open: http://localhost:8000/web/preview.html
(If the page shows only 4 cards, an old preview server may still be
answering :8000 — `lsof -ti :8000 | xargs kill`, then `rake preview`
again. That exact trap cost the loop a review cycle.)

EXPECT:
- The Volatility card is STACKED: a SURFACE section on top, a BASIS
  section below. The SURFACE section carries a `[BTC][MSTR]` tab pair
  (M8-17), BTC active by default; the BTC tab title is like `Vol
  surface · ATM 30d 43.9%`, the MSTR tab like `MSTR vol surface · ATM
  30d 86.2%`. Clicking MSTR swaps that section's chart/title/badge; the
  BASIS section is unaffected.
- The GEX card now shows [BTC][MSTR][TREND]; the TREND tab plots
  spot/flip/CW/PW daily lines and its title carries the max-pain
  delta (`· MP Δ+0.59%`).
- Offline fixture data is FLAT/degenerate on the vol tabs (one
  recorded expiry backs all tenors) — that is the fixture, not a bug;
  judge layout/labels/colors, not the line shapes.

## 3. Bless the goldens

If step 2 looked right:

```
cd ~/Dev/mimir-phase8 && rake golden:approve
```

EXPECT: it lists exactly four new specs (chart_vol_surface,
chart_vol_spread, chart_vol_basis, chart_gex_trend), you confirm, and
`rake test` stays green. Commit lands via the loop.

## 4. Merge and deploy (your actions)

Open the PR: https://github.com/arvicco/mimir/compare/main...phase-8
(or `gh pr create --base main --head phase-8 --title "Phase 8A: GEX/volatility family"`).

EXPECT before merging: CI green on the phase-8 head (step 1 command).

After the merge:
```
cd ~/Dev/mimir && git checkout main && git pull
gh run list --repo arvicco/mimir --branch main --limit 1   # EXPECT: success
rake deploy        # interactive; includes one real publish
```

EXPECT from the deploy's publish: `PUB LIVE 25/25 keys` (was 13/13 —
the monitor/notes expectation changes with this deploy; tell the loop
so its tick-watch copy updates). Then put the working tree back on
main so the launchd agents run the released code — the loop will
confirm agent health at the next tick.

## 5. Live dashboard verification (the outcome check)

Open: https://mimir-cd12ef34.neromontanero.workers.dev (hard reload).

EXPECT:
- Header dot cluster grows to the new key count, all green after the
  next bi-hourly tick.
- The Volatility card renders REAL curves now: upward ATM term
  structure (roughly 30→37% at the time of writing), negative RR25
  (downside skew), MSTR−BTC spread around +50 vol points, contango
  basis curve.
- GEX TREND tab shows the accumulated daily history (starts
  2026-07-06) and keeps growing a point per day; `data/vol_history/`
  starts accumulating from the first post-deploy 08:15 snapshot (IV
  rank/percentiles become buildable after a few weeks).
- The title ⓘ (next to "mimir") opens its orientation bubble on
  hover/focus, and its "How to read this dashboard →" link loads
  guide.html on the live host (opens `/guide.html`, the full reading
  guide; "Methodology →" goes to the repo).
- Auto-refresh (M8-13): leave the tab OPEN across one bi-hourly tick
  (ticks at ~:45 odd hours) — the header pub time and card badges
  advance by themselves, NO reload. This closes the stale-open-tab
  trap that confused us twice.
- Security headers (M8-12): `curl -sI https://mimir-cd12ef34.neromontanero.workers.dev/api/v1/index | grep -i vary`
  shows `Vary: Authorization`; `curl -sI https://mimir-cd12ef34.neromontanero.workers.dev/ | grep -i content-security`
  shows the CSP line.
- Data-integrity honesty (M8-8/9/10): on a healthy day the publish
  status line carries NO `BLIND` marker --
  `grep -o 'BLIND:[^ ]*' /tmp/publish.status` prints nothing (equiv:
  the tmux `PUB` token shows no `BLIND`). A `BLIND:scenario` /
  `BLIND:lppl` only appears when today's freshest scenario/lppl row is
  still marked after ops/repair.rb ran, and the scenario strip greys
  that day's point (hollow marker; hover help names the convention).

## Decide or explicitly carry at this gate

- Which Phase 8 packets come next: docs/DEV-PROPOSALS.md waves 2–3
  (derivatives positioning, CFTC COT, exchange reserves, Kalshi
  ladder, bubble-index cross-ref; then scorecard/backtest road) plus
  M7-13 (deterministic iXBRL parser) and M7-15b (cash model — makes
  DJT/BLSH mNAV honest).
- KV quota check (Gate 5 carry-over): 25 keys × 12 runs/day ≈ 300
  writes/day, ~30% of the free tier by arithmetic — confirm in the CF
  dashboard if you want the observed number.
- gex_check divergence threshold: stays report-only until weeks of
  data suggest a band (deliberate, Golden Rule 4).

## Background (not needed to run the gate)

Phase 8A was built 2026-07-10/11 during the Phase-7 soak under the
"keep going" ruling: M8-1 vol surface (+ bs_delta seam), M8-2 GEX
history analytics, M8-3 max-pain cross-check (report-only), M8-4
basis+funding (funding verified percent-per-8h against Binance), M8-5
MSTR−BTC IV spread, M8-6 publish wiring + Volatility card + TREND tab.
All display-first: no scenario-score membership changed. Producers are
individually runnable (README "Volatility & positioning tools").
Goldens were generated deterministically from recorded fixtures and
are PROVISIONAL until step 3. Production ran pure phase-7 throughout
the build (main tree pinned to phase-7; work in worktrees).
