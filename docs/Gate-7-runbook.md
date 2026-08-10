# Gate 7 runbook — merge phase-7 + tag v1 (re-scoped 2026-08-10: BTCo frozen)

RE-SCOPED by owner ruling 2026-08-10: BTCo (treasury-company)
development is STOPPED pending a rethink. This gate no longer
validates BTCo data. It merges the finished, soaked phase-7 code and
tags v1. The old BTCo validation step is gone; two new BTCo shutdown
decisions are in step 3.

Five steps, in order. Each step says exactly what to run/open and what
you should see (EXPECT). If an EXPECT fails, stop and tell the loop —
don't improvise past a failed step. Background context is at the end;
you don't need it to run the gate.

## 1. Dashboard eyeball (non-BTCo cards)

Open: https://mimir-cd12ef34.neromontanero.workers.dev
(Hard-reload — Cmd+Shift+R — a tab left open shows old data.)

EXPECT, card by card (DEV-LOOP.md section 6b, the short version):
- Header dot cluster: all green; "pub" slot shows today's latest
  bi-hourly tick (ticks run every 2h at ~:45).
- GEX card: BTC/MSTR tabs both filled, spot in the title ≈ current
  BTC price, no NaN/blank axes.
- Scenario + LPPL cards: newest data point dated TODAY or yesterday
  (daily cadence, appended by the 06:45 agent).
- Day-over-day: the data is newer than what you saw yesterday.
- BTCo table: only sanity — it renders without errors. STALE flags on
  XXI/DJT and an old MSTR share count are EXPECTED (data upkeep
  stopped with the freeze); they are not gate blockers.

## 2. Soak verdict

```
grep OLD ~/Library/Logs/mimir/publish.log | tail -20
grep "publish LIVE" ~/Library/Logs/mimir/publish.log | tail -5
```

EXPECT: first grep EMPTY (no OLD flags since the 2026-07-08 install);
second shows a clean streak of "13 written, 0 skipped". If any OLD
appears, read docs/WORKLOG.md for that date before proceeding.

## 3. Decide or explicitly carry (say your ruling out loud to the loop)

- **BTCo card on the dashboard**: keep it visible (with honest STALE
  flags that will only grow), or hide the card until the rethink?
  Hiding touches publish keys + web render — the loop prepares it, you
  deploy. Decide: keep / hide.
- **BTCo daily agents**: the 07:45 btco-alert job still runs and its
  data goes stale. Keep it running, or unload it (a launchd change —
  your action; the loop prints the exact command)? If retired, the
  loop first writes the decommissioning inventory (per the standing
  verification rules). Decide: keep / stop.
- **Refetch bundle**: the dashboard never re-fetches by itself — a tab
  left open keeps showing the data from when it loaded (this is the
  thing that confused us twice). Fixing it means the page re-pulls
  keys on a timer, which touches the pinned per-chart ttl values.
  Decide: build it / carry past v1.

(D8-e and D8-h were BTCo decisions — FROZEN with the ruling, nothing
to decide here. Full texts stay in docs/BACKLOG.md.)

## 4. Merge and tag (your actions; loop verifies CI first)

Open the PR: https://github.com/arvicco/mimir/compare/main...phase-7
(or `gh pr create --base main --head phase-7 --title "Phase 7"`).

EXPECT before merging: CI green on the phase-7 head —
```
gh run list --repo arvicco/mimir --branch phase-7 --limit 1
```

After the merge, on main:
```
cd ~/Dev/mimir && git checkout main && git pull
gh run list --repo arvicco/mimir --branch main --limit 1   # EXPECT: success
git tag v1 && git push origin v1
```

Then redeploy + switch the working tree back so the agents keep
running the released code (ask the loop to prepare the exact deploy
command if you want it staged).

## 5. Next scope (post-freeze focus)

- **Gate 8 — vol/GEX family** (M8-1..M8-10, ALREADY BUILT on branch
  phase-8 during the soak; not live anywhere). Its gate needs from
  you, after Gate 7:
  - Preview eyeball: `cd ~/Dev/mimir-phase8 && PUBLISH_DRY_RUN=1 ruby
    publish/publish.rb && rake preview`, open
    http://localhost:8000/web/preview.html — EXPECT a fifth
    "Volatility" card ([SURFACE][SPREAD][BASIS] tabs) + a [TREND] tab
    on the GEX card.
  - Bless the four new goldens if they look right: `rake golden:approve`.
- **Phase 9 — LPPL statistics revision** (the SBI review, R1–R10):
  the loop drafts the phase plan; every change that alters what a
  verdict means gets your explicit approval first.
- Non-BTCo picks from docs/DEV-PROPOSALS.md remain available (COT,
  exchange reserves, Kalshi ladder...); family D (BTCo) is frozen.

## Background (not needed to run the gate)

BTCo freeze (owner ruling 2026-08-10): "Treasury dashboard is
completely broken/unrepairable, we stop its development now, pending
serious re-thinking." All BTCo packets and decision items are frozen
(see the ruling block in docs/BACKLOG.md). Code, ledgers and tests
stay in the tree; one MSTR proposal from the aborted 2026-08-10
refresh sits in capstruct/pending — dismiss with
`ruby scripts/btco/ingest.rb --dismiss-all --ticker MSTR` or leave it.

Ingest-data provenance note (M7-17, 2026-08-09): the SBI review's C1
bug (keyword regex blind to "preferred stock" / "notes due" /
share-count phrases) affected every ai-mode ingest before its fix. The
ledger scan confirmed all such applies (2026-07-07..09) were superseded
by the externally-reconciled M7-16 baseline sweep, so the frozen
universe does not rest on blind excerpts.

v1 originally meant "real BTCo data end-to-end" (standing ruling,
2026-07-06); the 2026-08-10 freeze supersedes that: v1 now tags the
soaked suite (GEX, scenario, LPPL, publish pipeline, ops agents) with
BTCo present but frozen. Gate 5 carry-overs remain owner-scheduled:
Novo promotion and the KV quota check (arithmetic as of 2026-07-11: 22
keys post-phase-8 x 12 runs/day ≈ 264 writes/day, ~26% of the free
tier — comfortable). D8-f (3350 pricing) was RESOLVED 2026-07-10 via
the Yahoo chart API. This file supersedes the checklist that lived in
docs/BACKLOG.md (owner ruling 2026-07-11: gate instructions always
live in a dedicated Gate-N-runbook.md, fully specific).
