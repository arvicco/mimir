# METHODOLOGY.md -- what the tools measure and how to read them

Written for a first-time user of the terminal output. Each section
covers: why the tool exists, the model behind it, every displayed
field, a decoded status line, and the caveats that keep you honest.
Commands and flags live in [README.md](../README.md); this document is
about *interpretation*.

## 0. Conventions shared by every tool

- **Scores are -1 / 0 / +1.** Positive supports the constructive
  reading (recovery-supportive, regime-intact, calm); negative supports
  the destructive one; 0 is neutral, insufficient, or "source down".
- **Fail-soft**: a dead data source reports score 0 with an
  `unavailable (...)` headline and exits 0. In `--json` this carries
  `"unavailable": true` -- a *healthy* 0 and a *blind* 0 are different
  things; check which one you have before trusting a composite
  (`rake health:sources` probes every upstream directly).
- **Status lines** (`--tmux`) are one-line summaries written to
  `/tmp/<tool>.status` for a tmux bar; each is decoded in its section.
- Weights, thresholds and bands quoted below are research decisions,
  frozen in code (CLAUDE.md Golden Rule 4); this document describes
  them, it does not justify re-tuning them ad hoc.

## 1. GEX -- dealer gamma positioning (gex.rb, gex_us.rb, gex_btc_combined.rb)

### Why

Options market makers ("dealers") hedge the options they carry. The
aggregate *gamma* of their book determines how that hedging feeds back
into price: **long gamma** dealers sell rallies and buy dips (pinning,
dampened moves); **short gamma** dealers buy rallies and sell dips
(amplification, air pockets). Knowing where the book flips sign and
where its biggest strikes sit gives you a map of mechanical flow.

### Model and assumptions

- Per instrument, dollar gamma per 1% move =
  `sign * BS-gamma * open interest * contract multiplier * S^2 * 1%`,
  with S the instrument's own underlying level, Black-Scholes gamma
  computed from the venue's implied vol (r = 0, options priced off
  forwards).
- **Sign convention (the big assumption):** dealers are long calls,
  short puts -- so call gamma counts +, put gamma −. This "naive dealer
  model" (same as SqueezeMetrics/cryptogamma) is defensible for
  US-listed customer flow, but on Deribit flows are two-sided: **trust
  the LEVELS (flip, walls, magnitude), be skeptical of the SIGN.**
- `gex_btc_combined.rb` maps every ETF strike to a BTC-equivalent level
  via the live ETF/BTC price ratio and buckets on the BTC axis, so
  Deribit and nine US spot-ETF chains sum into one profile.

### Reading the output

| field | meaning | interpretation |
|---|---|---|
| `net GEX ... per 1%` | book-wide dollar gamma per 1% move | magnitude = how much mechanical flow; e.g. +80M means dealers re-hedge ~$80M against every 1% move |
| `LONG GAMMA (pinning)` / `SHORT GAMMA (amplifying)` | sign of the total | pinning: moves fade; amplifying: moves run. Subject to the sign caveat above |
| `gamma flip` | level where net GEX crosses zero (scan +-30%, linear interpolation) | below the flip the market trades "short gamma": expect faster, gappier moves. Distance from spot to flip = cushion |
| `call wall` / `put wall` | largest positive / most negative strike bucket within +-30% | walls attract and then repel price (hedging concentrates there); classic range edges |
| `put/call OI` | put OI / call OI (combined: in BTC-equivalent units so venues weigh comparably) | > 1 = put-heavy positioning; context, not a signal by itself |
| profile bars | per-strike net GEX within +-15% of spot, bar scale anchored to the +-30% max | the shape matters: one dominant wall vs a ragged profile |

Per-venue rows in the combined tool let you see who contributes what;
Deribit and the ETF chains reconcile to the same formula (verified to
ppm in tests).

### Status line

`GEX BTC +80.9M flip 61.3k PW 60.0k CW 65.0k P/C 0.57`
= net GEX +$80.9M per 1% (long gamma), flip at 61.3k, put wall 60k,
call wall 65k, put/call OI 0.57. Combined uses `GEXsum` and BTC-axis
levels.

### Caveats

CBOE quotes are ~15 min delayed and OPRA open interest is
previous-day; Deribit OI is live. CME options are not covered (no free
chain). MSTR is deliberately excluded from the combined BTC axis (its
gamma lives on its own price axis).

## 2. Scenario composite -- regime discrimination (scripts/scenario/)

### Why

Seven cheap, independent signals, each answering "does the tape
support flush, base, or recovery?" at a different horizon. No single
module is trustworthy alone; the weighted composite and especially its
*drift over successive readings* is the signal (funding/premium lead by
days, flows by days-weeks, hash/MVRV/stables by weeks, macro by
months).

### The modules

| module (wt) | measures | +1 when | -1 when |
|---|---|---|---|
| `etf_flows` (3) | US spot-ETF net flows, 5d vs prior 5d (farside -> archive.org snapshot -> CoinGlass, first source with >=10 rows) | net 5d inflow, or outflow shrunk >50% | outflow steady/accelerating (>=90% of prior) |
| `funding_basis` (2) | Binance perp funding, 7d avg (contrarian) | <= -0.010%/8h: crowded shorts = squeeze fuel | >= +0.010%/8h: crowded longs |
| `cb_premium` (2) | Coinbase vs Binance spot premium | >= +10 bps: US institutional bid | <= -10 bps: US distribution |
| `macro` (2) | Fed net liquidity (WALCL - TGA - RRP) and 10y real yield, ~4w deltas (FRED) | liquidity rising AND real yields falling | liquidity falling AND yields rising |
| `hash_ribbons` (1) | miner capitulation, 30d vs 60d hashrate SMA | recovery cross within last 14d (the classic buy signal) | 30d < 60d: capitulation in progress |
| `onchain_value` (1) | MVRV (market cap / realized cap) | <= 0.85: terminal value zone | >= 2.5: froth |
| `stables` (1) | USDT+USDC supply, 1-month change | >= +0.5%: liquidity expanding | <= -0.5%: contracting |

Extras shown but not scored: annualized basis of the nearest Deribit
future (negative basis has historically marked terminal capitulation);
recent difficulty adjustments; realized price vs spot.

### Composite and bands

`composite = sum(weight * score) / 12`, mapped to:
`<= -0.40 FLUSH | <= -0.10 LEAN-FLUSH | < +0.10 NEUTRAL | < +0.40 BASE | >= +0.40 RECOVERY`.
The composite is an **evidence index**, not a probability -- a bounded
weighted vote over the modules, read by band, never as an "N% chance".

A reading of `LEAN-FLUSH -0.17` with only hash and stables negative is
a *mild* tilt -- two slow gauges leaning bearish, fast gauges neutral.
The A'->B' transition signature is the composite drifting from FLUSH
through NEUTRAL toward BASE across `data/history.jsonl` entries, not
any single print.

### Status line

`SCN LEAN-FLUSH -0.17 etf+0 fnd+0 cbp+0 mac+0 hsh-1 mvrv+0 stb-1`
= regime, composite, then each module's score (`fnd`=funding,
`cbp`=Coinbase premium, `mac`=macro, `hsh`=hash ribbons, `stb`=stables).

## 3. LPPL evidence suite -- falsifying a regime claim (scripts/lppl/)

### The hypothesis under test

"LPPL-as-regime" claims BTC's log price is (a) stationary around a
single power law of log-time anchored at genesis, (b) currently in an
*anti-bubble*: a post-peak decline with log-periodic oscillations and
damping trough depths. The suite does NOT try to prove this; it runs
four independently falsifiable tests daily and accumulates evidence
either way. Each test can kill the claim on its own axis.

### Test 1 · trend (wt 3) -- is the global power law still the best forecaster?

Every evaluation day and horizon h in {30, 90, 180}, three rivals are
fitted on data up to t-h and score the realized price at t with a
Gaussian log-score:

- `pl_full` -- power law on ALL history (the regime claim),
- `pl_recent` -- power law on the trailing 3y ("the trend has bent"),
- `rw` -- random walk with sqrt(h)-scaled variance (no trend info).

**Displayed** (headline flipped by owner ruling 2026-08-29, register
R-3): `trailing-1y MEAN log predictive-score differential/eval (log10)
pl_full vs best rival` -- the per-evaluation-day mean of (pl_full's
log-score - the best rival's), in log10 per eval: -0.6 at 30d means an
average day's realized price was about 4x more likely under the best
rival than under the global power law. The mean carries a Newey-West
standard error (`±… NW`; Bartlett kernel, lag 179 -- overlapping
horizons make daily evidence strongly autocorrelated, so a naive error
bar would be far too tight; a one-off 180-block circular bootstrap
cross-check agreed within 4%) and `band ±…`, the scoring band
re-expressed in per-eval units. The old cumulative SUM stays visible as
`cum` (and the `bf` JSON field): its magnitude scales with cache
density (SBI 3.1: -459 over 364 daily points vs -67 over 52
weekly-stride points for the same period; the per-eval mean held ~-1.26
against ~-1.28), which is exactly why it lost headline status.

**Score (unchanged):** still the cumulative differential against ±1.0
(+1 above +1.0, -1 below -1.0) -- at equal per-horizon eval counts the
mean-vs-band and sum-vs-±1.0 comparisons are the same inequality, and
freezing the score form guarantees no verdict drift from this ruling.

**Interpretation:** this is the suite's designated falsifier. A mean of
-1.29 ± 0.18 across the three horizons is not a subtle reading -- the
trailing year is decisively better described by "the trend bent" (or a
random walk) than by the genesis-anchored power law, and the error bar
says that is signal, not noise. When trend is -1, the overall verdict is
capped at STRESSED no matter how pretty the oscillation looks, and
FALSIFIED if the envelope breaks too.

**Magnitude caveat:** the model's predictive variances ignore parameter
uncertainty (documented simplification), which inflates magnitudes when
price sits far outside the fitted channel. Read the sign, the error
bar, and the ledger trend of the differential -- not the absolute
number alone.

### Test 2 · envelope (wt 3) -- is trough damping intact?

This is a **descriptive cycle heuristic**, not a statistical test: only
three historical troughs support it, so it describes a pattern rather
than proving one. The regime claims trough depth ratios (price/trend at
cycle lows) damp -- each cycle bottoming shallower than the last -- so
this cycle must bottom ABOVE the previous trough's ratio.

**Displayed:** `price/trend 0.559 vs frozen bound 0.358 (floor 0.241; live 0.441/0.441)` --
today's ratio (measured against today's full-history fit), then the
**frozen** thresholds (owner ruling 2026-08-29, register R-8): each
historical trough's ratio measured against the trend *as fitted on data
up to that trough*, so today's re-estimated trend can no longer drag
the reference thresholds around. The old drifting measurements ride
along as `live` (and the `*_live` JSON fields) -- the drift flattered
the model (rising price pulled the bound up with it), which is why it
lost operative status. The bound re-sets only when a subsequent trough
is confirmed. Score thresholds unchanged in form: +1 while ratio >=
bound ("intact"); 0 below the bound while persistence hasn't triggered
("stressed"); -1 after >= 45 consecutive days below 0.95x bound
(strong form broken) or >= 30 days below 0.95x floor (claim dead in
any form).

**Interpretation:** watch the two day-counters, not the ratio alone; a
brief poke below the bound is expected texture, persistence is
falsification. Honesty note the freeze itself surfaced: the frozen
trough sequence is `0.241 -> 0.482 -> 0.358` -- NOT monotonic. Measured
honestly, damping already failed between 2018 and 2022; the heuristic
survives only in the weaker "bottom above the last trough" form this
test actually checks. `freeze_candidate` (M9-4) remains in `--json`
and now equals the operative bound.

### Test 3 · fit (wt 2) -- does a qualified anti-bubble LPPLS fit exist?

Fits `ln P = A + B*tau^m + tau^m * [C1 cos(w ln tau) + C2 sin(w ln tau)]`
post-peak (Filimonov-Sornette linearization: grid over tc/m/w, linear
solve for the rest). The *evidence* is not the fit but its quality:

**Displayed:** `m 0.56, omega 8.6, 4/4 filters; trough none<=+400d @ ~27000; rmse 0.048 (+44% vs sym null)`
- the Sornette qualifying filters: m interior to (0.1, 0.9), omega in
  [6, 13], >= 2.5 oscillations in window, |C|/|B| <= 1. 4/4 = a
  textbook-shaped fit; <= 2 scores -1.
- `trough <date> @ <level>`: the fitted curve's minimum extrapolated up
  to +400 days. `none<=+400d` = the minimum sits on the boundary --
  itself a strike (score downgraded 1), because a real anti-bubble
  should have an interior trough.
- `rmse ... vs sym null`: improvement over a pure power-decay fit with
  no oscillation. Since the 2026-08-29 owner ruling (register R-6) the
  figure shown is `improvement_v2` -- measured against the symmetric,
  RMSE-selected null that cleared the original null's tc-grid-edge
  artifact (29.2% became an honest 27.9% on the day the artifact was
  found); the original figure stays in `--json` as `rmse_impr_pct`.
- report-only diagnostics ride alongside (`b_negative`, `damping` vs
  its 1.0 reference threshold): visible, wired into nothing -- whether
  damping ever GATES the verdict is a deliberately open item.
- `trough std Nd` (when >= 5 history entries): day-to-day stability of
  the projected trough; > 21 days of wander is the classic overfit
  signature and downgrades the score.

**Interpretation:** 4/4 filters with a *stable, interior* trough is the
constructive case. 4/4 filters with `none<=+400d` (as here) reads: the
oscillation structure is real-looking but the model currently refuses
to name a bottom -- structure without a forecast.

### Test 4 · logperiodic (wt 2) -- is the oscillation statistically real?

Guards against seeing omega in autocorrelated noise. Residuals of the
power-decay null are tested for periodicity in ln(tau) via Lomb-Scargle;
significance comes from a parametric bootstrap (seeded). Since the
2026-08-29 owner ruling (register R-7) the p-value we stand behind --
headline AND score -- is the **AR(1)+GARCH(1,1)** bootstrap
(`p_value_v2`, default 1000 sims): it matches crypto's volatility
clustering and re-fits the null on every simulated path, carrying the
refit-and-look-elsewhere variance the plain AR(1) null ignores. The
AR(1) p remains in the line and in `--json` (`p_value`) as reference.

**Displayed:** `LS peak omega 8.5, power 57.1, p = 0.238 (GARCH, 1000 sims; AR(1) ref p 0.376 rho 0.96)`.
Score: +1 if p <= 0.05 with omega in [6, 13]; -1 if p > 0.50 (clearly
noise); else 0 -- unchanged thresholds, now evaluated on the GARCH p.
Note rho 0.96: the residuals are heavily autocorrelated, which is
exactly why raw periodogram power (57) can still be non-significant --
an honest null is doing its job (both nulls agree on that today).
Check omega here against the fit's omega (8.5 vs 8.6): agreement
between two independent estimates is soft corroboration.

### Test 5 · percentile (wt 0, monitor) -- how extreme is the price, age-adjusted?

Perrenod-style: residuals from a log10 price vs log10 age power law,
scaled by an age-dependent sigma from a fitted reciprocal-decay
envelope, giving an age-adjusted Z. **An extreme reading is inherently
ambiguous** -- deepest value ever vs first out-of-sample failure -- so
this test carries no verdict weight; its score encodes what
*disambiguates*:

**Displayed:** `Z -1.82 -> emp pctile 0.19% (Gaussian ref 3.43%); 18d at <=1st pct, 38d at <=5th; NEW RECORD low (prior -1.73 on 2022-12-31)`
- the **empirical** percentile (rank among all history) is the primary
  reading; the Gaussian number is a **reference only**, printed for
  comparison with the published method -- at Z ~ -2 the fat tails
  dominate (0.19% vs 3.43% here) and the empirical rank is the honest one.
- score -1 after >= 60 consecutive days at/below the 1st empirical
  percentile (mean reversion failing = evidence against the
  distribution itself); +1 if an extreme (<= 5th pctile) printed within
  the trailing 90d AND Z has since reverted above -1.0 (model behaving
  as claimed); else 0.
- `NEW RECORD low` (the `!` in the status line): today's Z is the
  deepest age-adjusted reading in Bitcoin's history -- either the best
  value signal the model has ever produced, or its first failure.
  The day-counters tell you which way it's resolving.

### Verdict

`composite = (3*trend + 3*envelope + 2*fit + 2*logperiodic) / 10`, then
`>= +0.50 REGIME-INTACT | >= +0.15 SUPPORTED | > -0.15 INDETERMINATE |
> -0.50 STRESSED | else FALSIFIED`, with overrides: trend AND envelope
both -1 -> FALSIFIED outright; either one -1 -> capped at STRESSED. The
composite is an **evidence index**, not a probability -- a bounded
weighted vote read by band, never an "N% chance the regime holds". A
secondary self-check rides in `--json`: `omega_xcheck` compares the two
independent oscillation-frequency estimates (fit's LPPLS grid ~8.6 vs
logperiodic's Lomb-Scargle peak ~8.5); agreement is soft corroboration.

### Worked example (the run above)

```
trend -1, envelope +1, fit 0, logperiodic 0
composite = (3*-1 + 3*+1 + 0 + 0) / 10 = 0.00 -> INDETERMINATE band,
capped to STRESSED because trend = -1.
```
Read: *the two heavyweight tests disagree head-on* -- out-of-sample
forecasting says the global trend is dead (differential hugely negative), while
the damping envelope says price sits exactly where a damped trough
should hold (0.464 >= 0.434, zero days below). The oscillation is
well-shaped (4/4) but not statistically significant and refuses to
project a bottom, and the valuation monitor just printed the deepest
age-adjusted reading ever. This is the "model under maximal live test"
configuration: the next weeks of the envelope counters and the
differential's trend decide which heavyweight wins.

### Status line

`LPPL STRESSED +0.00 BF-425.5 r0.46 trough --/-- w8.6 p0.24 Z-1.8@0.2%!`
= verdict, composite, the `BF` token (the trend cumulative
differential, unchanged abbreviation), envelope ratio, fit's projected
trough date/level (`--/--` = none interior), fit omega, logperiodic
p-value (the GARCH bootstrap p since the 2026-08-29 ruling),
percentile Z @ empirical percentile, `!` = record low.

### Shadow diagnostics (SHADOW tab -- report-only during the D9 soak)

The Phase-9 statistics revision computes a second, "shadow" version of
six suite internals alongside the frozen ones and surfaces the pair on
the LPPL card's SHADOW tab: the current (frozen) value, an arrow, the
shadow value, and a one-phrase verdict per row. They are additive,
report-only fields on `lppl:latest` -- no verdict, weight, or threshold
moves during the soak -- and each row feeds one pre-registered decision
item (D9-a..g). The representative live numbers below are the ones the
shipped hover text cites.

- **mean/eval (feeds D9-b).** The average forecast-score gap per
  evaluation -- power law vs its best rival, in log10; negative means
  rivals beat the power law that day. Unlike the headline sum (about
  -460), it does not grow just because we evaluate more often -- it is
  the honest size of the effect. -1.26 means that on an average day the
  best rival gave about 18x higher probability to what actually
  happened. Open question: make this the primary trend number?
- **365/730 (feeds D9-c).** The same per-evaluation score at 1-year and
  2-year forecast horizons; these do NOT count toward the verdict yet.
  Negative at 365d (the power law still loses), positive at 730d (it
  WINS at two years) -- matching published research that short horizons
  favour naive models and long horizons favour the power law. Open
  question: should long horizons enter the score?
- **damping (feeds D9-e).** An anti-bubble shape test from the Sornette
  school: a genuine damped anti-bubble's oscillations decay with a
  damping ratio of at least 1. Today's fit scores 0.41 -- it does NOT
  qualify under the standard condition, even though it passes the
  suite's four original filters. Report-only for now. Open question:
  should this gate the fit verdict?
- **impr (feeds D9-e).** How much better the LPPLS curve fits the
  post-peak decline than a plain decay curve. The frozen 29.2% was
  measured with an unfair advantage (the plain curve got a coarser
  parameter search); 27.9% is the fair, like-for-like number -- the
  LPPLS fit still wins, just honestly. The fair search also fixes a bias
  that pushed the plain curve's peak date to the edge of its grid.
- **p(osc) (feeds D9-f).** The probability that the log-periodic wobble
  is just noise. Under the simple noise model (frozen): 0.38; under a
  realistic model with fat tails and volatility clustering (shadow):
  0.24. Both are far above the usual 0.05 bar -- the wobble is NOT
  statistically proven, and the suite is right to say so. Open question:
  which noise model is the headline?
- **freeze (feeds D9-g).** The envelope's support bound. 0.439 is
  today's live value, recomputed daily against a trend that keeps
  drifting as new data arrives; 0.358 is what the bound would be if
  frozen at the 2022 low, as a stricter rule would demand. The gap
  between them is how much the drifting trend flatters the "envelope
  intact" reading. Open question: freeze each cycle's bound?

**How a shadow number becomes a verdict.** The path is deliberate and
gated. A candidate statistic ships first as an additive, report-only
shadow field (no behaviour change); it soaks in view on the SHADOW tab
so the owner can watch the frozen and shadow values diverge across real
days; the owner then rules the matching pre-registered decision item
(D9-a..g); only a ruling flips the headline, and that flip is a reviewed
analytics-semantics change (Golden Rule 4), never a drive-by. Until a
ruling lands, the frozen number stays the one the verdict uses.

## 4. BTCo -- treasury-company balance-sheet stress (scripts/btco/)

### Why

Bitcoin treasury companies are levered, reflexive BTC holders: when
their equity trades above BTC NAV they issue shares to buy more BTC
(the flywheel); below NAV the flywheel dies and leverage turns them
into potential forced sellers. The aggregate stress score is an
E'-branch tripwire; per-company rows are relative-value context.

### Per-company metrics

| column | definition | interpretation |
|---|---|---|
| `sats/shD` | BTC * 1e8 / diluted shares | raw BTC content per share |
| `CEBE s/sh` | Common-Equity BTC Entitlement: sats per share after netting senior claims, with ITM converts treated as equity (shares added at conversion price, face dropped) and OTM converts + straight debt + preferred netted against the stack | what a common shareholder actually "owns" in BTC terms after everyone senior is paid; the honest sats/share |
| `mNAV` | market cap (basic shares) / BTC NAV | > 1: market pays a premium (flywheel on); < 1: discount (flywheel off) |
| `netNAV` | mcap / (BTC NAV - senior claims) | the premium on the *equity's* claim; `neg` = senior claims exceed BTC NAV (negative equity vs coins) |
| `EV/BTC` | (mcap + senior) / BTC | the all-in price the market pays per coin held; compare to spot |
| `lev` | senior claims / BTC NAV | balance-sheet fragility; >100% = underwater vs coins |
| verdict | on netNAV: DEEP-DISC < 0.90, UNDER < 1.10, FAIR < 1.45, RICH < 1.90, OVER | relative-value bucket |
| `STALE` / `*` | btc_as_of older than 120d / placeholder seed data | **do not trust the row** until refreshed via ingest |

### Stress score (0-100, BTC-weighted)

`45% * share of universe (by BTC held) below mNAV 1  +  35% * median-mNAV
shortfall below 1.40 (scaled over 0.60..1.40)  +  20% * aggregate
leverage (scaled to 50%)`, banded `< 25 CALM | < 50 ELEVATED |
< 75 STRESSED | >= 75 CRITICAL`; suite score +1 at <= 30, -1 at >= 60.

Reading `stress 70 (STRESSED): 96% of BTC-weighted universe below mNAV 1,
median mNAV 1.09, lev 33%`: nearly all BTC-weighted market cap trades
below NAV (flywheel off across the board), median premium barely above
1, aggregate leverage still moderate -- accretion is dead but forced
selling isn't indicated yet. Caveats: operating-business value is
ignored (SMLR/GME/DJT read pessimistic-rich); stress reads
balance-sheet posture, not cash flow.

### Status line

`BTCO 70 STRESSED <1:96% med 1.09 lev 33% stale:6`
= stress score, band, BTC-weighted share below mNAV 1, median mNAV,
aggregate leverage, count of stale entries.

## 5. Quick score reference

| tool | +1 | 0 | -1 |
|---|---|---|---|
| scenario modules | per-module thresholds (section 2 table) | neutral / source down | per-module thresholds |
| lppl trend | trailing differential >= +1.0 | in between | differential <= -1.0 |
| lppl envelope | ratio >= strong bound | stressed, persistence not met | persistence broken (45d/30d) |
| lppl fit | 4/4 filters (minus downgrades) | 3/4 or downgraded | <= 2/4 filters |
| lppl logperiodic | p <= 0.05 and omega in [6,13] | in between | p > 0.50 |
| lppl percentile | extreme printed, then reverted | monitor | >= 60d at <= 1st pctile |
| btco | stress <= 30 | in between | stress >= 60 |
