# Gate 7 runbook — v1 tag (run on/after the July 13 soak review)

Six steps, in order. Each step says exactly what to run/open and what
you should see (EXPECT). If an EXPECT fails, stop and tell the loop —
don't improvise past a failed step. Background context is at the end;
you don't need it to run the gate.

## 1. Universe validation

```
cd ~/Dev/mimir
(source ~/.config/mimir/env; ruby scripts/btco/validate.rb)
```

(The subshell gives it CLOUDFLARE_* for the live-payload read and
EDGAR_UA for SEC; nothing is printed from that file.)

EXPECT: a block per US ticker ending in "nothing -- inputs agree with
external refs". Two advisories are known-good and fine to see:
- MSTR share count vs tracker (~350.4M Apr cover vs ~371.6M) — ATMs
  outrun quarterly covers; closes at the next 10-Q.
- ABTC external refs disagreeing with each other (8,195 vs 7,500 BTC);
  ours (8,000 @2026-07-06) is the dated one.
3350 (Metaplanet) has no tracker mNAV decomposition — its row check is
step 2's table eyeball instead.

## 2. Dashboard eyeball

Open: https://mimir-cd12ef34.neromontanero.workers.dev
(Hard-reload — Cmd+Shift+R — a tab left open shows old data.)

EXPECT, card by card (DEV-LOOP.md section 6b, the short version):
- Header dot cluster: all green; "pub" slot shows today's latest
  bi-hourly tick (ticks run every 2h at ~:45).
- GEX card: BTC/MSTR tabs both filled, spot in the title ≈ current
  BTC price, no NaN/blank axes.
- Scenario + LPPL cards: newest data point dated TODAY or yesterday
  (daily cadence, appended by the 06:45 agent).
- BTCo table: 8 rows (MSTR, XXI, 3350, DJT, NAKA, ASST, BLSH, ABTC),
  no placeholder asterisks, no STALE flags, prices dated within a
  trading day.
- Day-over-day: the data is newer than what you saw yesterday.

## 3. Soak verdict

```
grep OLD ~/Library/Logs/mimir/publish.log | tail -20
grep "publish LIVE" ~/Library/Logs/mimir/publish.log | tail -5
```

EXPECT: first grep EMPTY (no OLD flags since the 2026-07-08 install);
second shows a clean streak of "13 written, 0 skipped". If any OLD
appears, read docs/WORKLOG.md for that date before proceeding.

## 4. Decide or explicitly carry (say your ruling out loud to the loop)

- **D8-e — divergence alert wiring**: should validate.rb's
  our-vs-tracker check run inside the daily 07:45 btco-alert job (its
  ING token would then also count divergences)? Costs an ING contract
  change. Decide: wire it / carry past v1.
- **Refetch bundle**: the dashboard never re-fetches by itself — a tab
  left open keeps showing the data from when it loaded (this is the
  thing that confused us twice). Fixing it means the page re-pulls
  keys on a timer, which touches the pinned per-chart ttl values.
  Decide: build it / carry past v1.

## 5. Merge and tag (your actions; loop verifies CI first)

Open the PR: https://github.com/arvicco/mimir/compare/main...phase-7
(or `gh pr create --base main --head phase-7 --title "Phase 7: BTCo real data + soak"`).

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

## 6. Phase 8 scope

Phase 8A (GEX/volatility family, M8-1..M8-6) is ALREADY BUILT on
branch phase-8 (built during the soak, owner-approved 2026-07-10; not
live anywhere). Its own gate needs from you, after Gate 7:
- Preview eyeball: `cd ~/Dev/mimir-phase8 && PUBLISH_DRY_RUN=1 ruby
  publish/publish.rb && rake preview`, open
  http://localhost:8000/web/preview.html — EXPECT a fifth "Volatility"
  card ([SURFACE][SPREAD][BASIS] tabs) + a [TREND] tab on the GEX card.
- Bless the four new goldens if they look right: `rake golden:approve`.
- Pick the next packets from docs/DEV-PROPOSALS.md (waves 2-3: COT,
  exchange reserves, Kalshi ladder, scorecard...).

## Background (not needed to run the gate)

v1 = real BTCo data end-to-end per the standing ruling; the soak week
folds in here. Gate 5 carry-overs remain owner-scheduled: Novo
promotion and the KV quota check (arithmetic as of 2026-07-11: 22 keys
post-phase-8 x 12 runs/day ≈ 264 writes/day, ~26% of the free tier —
comfortable). D8-f (3350 pricing) was RESOLVED 2026-07-10 via the
Yahoo chart API; the row is live. This file supersedes the checklist
that lived in docs/BACKLOG.md (owner ruling 2026-07-11: gate
instructions always live in a dedicated Gate-N-runbook.md, fully
specific).
