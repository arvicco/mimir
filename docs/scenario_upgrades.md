# scenario_upgrades.md -- Mimir scenario suite v2

> STATUS 2026-08-11: DEFERRED, UNSCHEDULED. Phase 9 became the LPPL
> statistics revision, not this scenario-v2 work -- these modules did
> NOT ship and remain an unscheduled candidate (docs/DEV-PROPOSALS.md).
> The earlier reconciliation note and build order below are historical:
> U1 -> U4 (start early) -> U3/U6 monitors -> U7, with U2 cohort and U5
> squeeze blocked on Coinglass tier (their LTH/STH and liquidation-
> topology data is not served on our plan).

Upgrades and new tests derived from the 2026-07-05 reassessment. Each of
the four novel theories from that analysis becomes a **pre-registered,
scored hypothesis** with explicit kill criteria -- same falsification
discipline as the LPPL suite, now applied to our own market theories.
All modules: Ruby >= 2.5, stdlib only, standard contract (--json /
--tmux, fail-soft, -1/0/+1 where scored). New modules enter scenario.rb
at **weight 0** and are promoted only on ledger evidence (CLAUDE.md
Golden Rule 4 applies to every threshold below).

Relationship to improvements.md: this document *consumes* its
groundwork (Coinglass client + cache + tier probe) and extends items
A2/B1/B2 with specific hypothesis tests. Build order assumes that
groundwork exists.

---

## U1. flow_decay.rb -- cohort-exhaustion test (Theory: frozen-bid asymmetry)

**Claim under test:** the active seller pool is one finite, heterogeneous
cohort (ETF holders); heterogeneous cohorts exhaust with a decaying
hazard (weak hands first), so outflows should follow rough exponential
decay from the May 7 peak -- the GBTC-2024 pattern. The treasury complex
is frozen (cannot buy below mNAV 1, will not sell pre-2027), so no
second seller wave exists absent a credit event.

**Data:** Coinglass ETF Flows History (per-ticker, daily). Deribit index
for context.

**Mechanics:** fit ln(weekly outflow) ~ a - t/tau on trailing outflow
weeks; report half-life tau, fit quality, projected exhaustion date
(flow < 10% of peak week), and the **per-fund divergence ledger**:
which funds have flipped to net inflow (FBTC, ARKB first per 2026-07-02)
and which have not (IBIT = the last domino; its first positive day is
the cleanest single B-confirmation available).

**Score:** +1 decay fit holding AND >= half the funds (AUM-weighted)
flipped; -1 outflows re-accelerate above the decay envelope for 2+
weeks (theory failing -- second seller wave exists).

**Kill criterion (pre-registered):** a fresh outflow week exceeding the
May-June peak week, or treasury-company coin sales appearing on-chain,
falsifies the frozen-bid asymmetry outright.

## U2. cohort.rb -- amplitude-reset test (Theory: cohort injection)

**Claim under test:** the damping-envelope violation (~0.44x trend vs
>= 0.50 expected) is a *composition artifact*: financialization injected
an immature 2024-25 cohort whose panic coexists with an intact
old-cohort floor. If true, LTH supply should sit at/near record through
the drawdown while realized losses concentrate almost entirely in
sub-1y coins.

**Data:** Coinglass LTH/STH Supply, LTH/STH-SOPR, LTH/STH Realized
Price (extends improvements.md A2 with a hypothesis mode).

**Mechanics + score:** +1 if LTH supply flat-to-rising over trailing
90d AND STH-SOPR in deep-capitulation territory while LTH-SOPR stays
near 1 (old hands not selling at a loss); -1 if LTH supply is falling
materially (old cohort distributing -- the damping break is real, not
compositional). Detail: price vs LTH realized price (terminal-floor
proximity), STH realized price (the reclaim level that confirms
B->C).

**Cross-suite note:** a -1 here is *corroborating evidence for* the
lppl envelope test's break reading; a +1 argues the envelope should be
re-specified per-cohort (research decision, not code).

## U3. expiry_low.rb -- options-defined-bottom monitor (Theory 3)

**Claim under test:** BTC's first institutional-put-complex bear can
print an equity-style expiry-defined low: terminal low within ~1 week
of a quarterly expiry at/near the max-put-OI strike. Supporting prior:
the 2026 YTD low ($58.2k) printed days after the June 26 quarterly.

**Data:** own gex tooling (Deribit chain via gex.rb machinery) for
max-put-OI strike and put-wall levels; Coinglass Option Max Pain /
Exchange OI as cross-check; expiry calendar computed (last Friday of
Mar/Jun/Sep/Dec, 08:00 UTC Deribit).

**Mechanics:** weight-0 monitor + event ledger. Daily: days to next
quarterly, current max-put strike, distance of spot to it, and whether
we are inside an "expiry window" (T-7..T+7). Post-hoc: log whether each
window contained a 30d local low. Status line contributes e.g.
`XPRY 25Sep-82d maxput 50k (-14%)`.

**Kill criterion:** if the cycle's terminal low ultimately prints
mid-quarter far from any put concentration, the mechanism gets archived
as an equity import that did not travel.

## U4. macro.rb v2 -- liquidity-clock upgrade (Theory: refinancing cycle, halving dead)

**Claim under test:** trough timing is endogenous to the real-rate peak,
not to halving arithmetic; the labor-data sequence is the clock. The
2026-07-03 tape (BTC +2.7% on weak jobs, $265M short liquidations)
demonstrated the transmission.

**Data (all FRED, existing key):** PAYEMS (payroll momentum, 3m
annualized change), ICSA (initial claims, 4-week avg vs 26w low),
UNRATE (Sahm-style 3m avg vs 12m low), DGS2 (2y yield as the market's
cut-pricing proxy), keeping the existing WALCL-TGA-RRP net-liquidity
stock and DFII10.

**Score (replaces current macro score, behind a 2-week parallel run):**
+1 labor rolling over (2 of 3 labor gauges deteriorating) AND DGS2
falling >= 25bp/4w (cuts being priced) -- the C-branch accelerant;
-1 labor strong AND DGS2 rising (clock paused/reversing); else 0.
Detail keeps the liquidity stock so nothing is lost.

**Consequence for cycle-template priors:** the "Q4-2026 trough because
Oct-2025 + 13 months" prior is demoted to coincidence-class context in
scenario documentation; timing weight moves onto this module.

## U5. squeeze.rb -- forced-flow skew (extends improvements.md B1/B2)

Derived signal on top of liqmap.rb: ratio of liquidation notional
within +10% of spot (shorts, upside fuel) vs within -10% (longs,
downside kindling), combined with OI-weighted funding sign. Crowded
shorts + dominant upside liquidation notional = squeeze-primed tape
(+1); the mirror image -1. This formalizes what the July 3 bounce
demonstrated ($265M shorts liquidated on a 3% move). Weight-0 for two
weeks alongside funding_basis.rb, then a merge/replace decision.

## U6. cycle_pos.rb -- base-rate context panel (correction from the audit)

Weight-0 panel encoding the 200-week-MA lesson: distance of price to
the 200WMA, consecutive weeks below, and this drawdown's depth/duration
expressed as a percentile of the three prior bears -- with the
historical base rate stated in the output (breaks below 200WMA occurred
in the final third of every prior bear). Purpose: prevent re-importing
the "structural damage" misreading; give the dashboard a
where-are-we-in-the-cycle dial with honest n=3 framing. Price history
from the lppl prices.rb cache (shared, no new source).

## U7. Housekeeping in existing modules

- **hash_ribbons.rb**: add header caveat + detail flag `hpc_era: true`
  -- AI/HPC hosting revenue has decoupled hashrate from BTC price, so
  the recovery-cross will fire late/muted this cycle; PROPOSAL (research
  gate): demote weight 1 -> 0.5 or reinterpret silence as
  non-informative rather than mildly bearish.
- **etf_flows.rb**: after the improvements.md A1 source swap, add the
  per-fund flip-count detail consumed by U1 (single fetch, shared
  cache).
- **percentile deadline surfacing**: scenario.rb gains an optional,
  fail-soft reader of the lppl ledger tail to surface `days_le_p01` and
  the ~60-day reversion deadline (early Sept) in the composite output --
  display only, no score coupling between suites.

---

## Proposed module table (post-rollout target)

| module         | wt now | wt target | status                     |
|----------------|--------|-----------|----------------------------|
| etf_flows      | 3      | 3         | source swap (A1)           |
| flow_decay     | --     | 0 -> 2    | new, U1                    |
| funding_basis  | 2      | 2         | aggregation upgrade (A4)   |
| squeeze        | --     | 0 -> ?    | new, U5; may merge w/ above|
| cb_premium     | 2      | 2         | history upgrade (A3)       |
| macro v2       | 2      | 3         | U4, parallel-run gate      |
| cohort         | --     | 0 -> 2    | new, U2                    |
| hash_ribbons   | 1      | 0.5       | demotion proposal, U7      |
| onchain_value  | 1      | 1         | folded into cohort context |
| stables        | 1      | 1         | unchanged                  |
| btco           | opt    | 1         | E-branch tripwire          |
| expiry_low     | --     | 0         | monitor only, U3           |
| cycle_pos      | --     | 0         | panel only, U6             |

Every weight change is a research decision requiring ledger evidence;
the table is the *proposal*, not an instruction.

## Dashboard panels (chart_specs.rb additions, Phase 3 of Mimir)

`flow_decay_curve` (weekly outflows + fitted decay + per-fund flip
markers), `cohort_panel` (LTH/STH supply + realized-price lines vs
spot), `expiry_timeline` (quarterly windows vs local lows, max-put
strike track), `macro_clock` (labor gauges + DGS2 dial), extending the
liq_topology spec from improvements.md with the U5 skew readout.

## Rollout order

U1 and U2 first (they test the two theories with the nearest-term
resolution and reuse the A1/A2 Coinglass work), then U4 (macro v2 --
highest weight consequence, longest parallel run, start it early), then
U3/U5/U6 as monitors, U7 housekeeping opportunistically. Every new
module ships with its kill criterion in the file header -- if a theory
dies, the module's job is to say so loudly, not to be quietly retuned.
