# The mimir LPPL suite — what it is, what it does, and what it assumes

A one-document overview, current as of 2026-08-11 (Phase 9 deployed).
Deeper detail: docs/METHODOLOGY.md (every displayed field),
docs/LPPL-SUITE.md (implementation), the live dashboard's LPPL card
(ⓘ and SHADOW tab carry these explanations in place).

## What it is

The suite is a public, daily test of one hypothesis: that Bitcoin's
price follows a long-run power law in its age, decorated with
log-periodic oscillations — the framework associated with Didier
Sornette's school (LPPL: log-periodic power law) and, for Bitcoin
specifically, with power-law growth models. The suite does not assume
the hypothesis is true. It is built falsification-first: five
independent tests each look for a way the hypothesis could be failing
right now, and the published verdict is a summary of how much evidence
against it has accumulated. Thresholds were fixed in advance
(pre-registered); nothing about the scoring changes without an
explicit, recorded owner decision.

## What it does, daily

Every day the suite updates its price history, runs five tests, and
publishes a verdict line plus full detail to the dashboard:

    LPPL STRESSED -0.20

The word is the verdict band (REGIME-INTACT → WATCH → STRESSED →
BROKEN → FALSIFIED); the number is the evidence index — a weighted
average of the five test scores, each in {-1, 0, +1}. It is an ordinal
index of evidence, NOT a probability (the tests share data, so their
evidence partly overlaps). Every day's result is appended to a ledger,
and any historical date can be replayed exactly (`--as-of`) — the
replay sees only the data a live run on that day would have seen.

## The five tests

**1. Trend (weight 3) — does the power law still forecast?**
Each day, the global power law and its rivals (a random walk with
drift, a recent-window power law, and — in shadow — a power law plus
one log-periodic mode) are fitted on data up to some past date and
made to forecast the price 30/90/180 days ahead. Each forecast is
scored by how much probability it assigned to what actually happened
(a Gaussian log-score). The statistic is the cumulative log
predictive-score differential (log10) between the power law and its
best rival — formerly mislabeled a "Bayes factor". Negative = rivals
forecast better. Current: the per-evaluation mean is −1.26 (the best
rival gives ~18× higher probability per day at these horizons).
Report-only shadow horizons: −0.11 at 365 days, **+0.16 at 730 days —
the power law wins at the two-year horizon**, matching published
research that short horizons favor naive models.

**2. Envelope (weight 3) — is the damping structure intact?**
Price divided by the fitted power-law trend, compared against the
floor set by past cycle troughs (0.565 → 0.577 → 0.432). A close
below the historical floor would be structural damage. Current ratio
holds ~1% above the floor; bound 0.439. This is a descriptive cycle
heuristic, not an estimated confidence band: three hand-picked
troughs, and the trend it divides by is refitted daily (a bound frozen
at the 2022 trough would sit at 0.358 — the drift is measured and
shown; whether to freeze is pending ruling D9-g).

**3. Fit (weight 2) — is the post-peak decline an LPPLS anti-bubble?**
Fits the LPPLS anti-bubble equation to the window since the detected
cycle peak (2025-10-06) and applies the Sornette-school filters plus
an improvement test against a plain power-decay curve. Current: the
fit qualifies on the original four filters and improves RMSE by 29.2%
(27.9% under the fair, symmetric optimization now computed in
shadow), but its projected trough is unstable → score 0. Two further
standard conditions are now measured report-only: the B < 0 sign
restriction (met) and the damping ratio m·|B|/(ω·|C|) ≥ 1 — **not
met (0.41)**: under the full standard filter set, today's fit does
not qualify as a genuine damped anti-bubble.

**4. Log-periodicity (weight 2) — is the oscillation real?**
A Lomb–Scargle periodogram of the post-peak residuals, taking the
maximum over the frequency grid (which handles the multiple-testing
trap most published LPPL work ignores), tested against simulated
noise. Under the simple AR(1) noise model: p = 0.38. Under the
stronger shadow model (AR(1)+GARCH — fat tails and volatility
clustering, 1,000 simulations, each re-fitted through the same
pipeline as the real data): p = 0.24. Both far above 0.05: **the
oscillation is not statistically demonstrated**, and the suite says
so. The fitted frequency (ω 8.7) and the periodogram peak (8.5) agree
— a self-consistency check now published.

**5. Percentile (weight 0) — how stretched is valuation?**
The deviation from trend as a Z-score and an empirical percentile
(the primary number; the Gaussian mapping is reference only). Current
reading is the deepest in history (~0.02 percentile). Deliberately
weightless — it monitors, it does not vote.

## The statistics, honestly

- Forecast competition, not curve admiration: the trend test scores
  out-of-sample predictions, the only place a model can't flatter
  itself. But its frozen horizons (30/90/180d) sit where published
  evidence says nothing beats naive models — the headline is a
  short-horizon statement. Long horizons run in shadow before any
  scoring change (ruling D9-c).
- Magnitudes vs signs: the cumulative differential's size scales with
  how densely the history is evaluated (measured: −459 over 364
  evaluations vs −67 over 52 on identical data). The density-honest
  reading is the per-evaluation mean; making it the headline is
  pending ruling D9-b.
- Null models matter: the fit's rival curve now gets the same
  optimization effort as the LPPLS fit (in shadow), and the
  oscillation test's noise model was upgraded from AR(1) to
  AR(1)+GARCH (in shadow). Both made the evidence *more* honest
  without changing any conclusion.
- The rival the hypothesis predicts: a power law plus one rigid
  log-periodic mode explains 34% of in-sample residual variance
  (reproducing the SBI reviewers' check) yet adds nothing
  out-of-sample and slightly degrades 90/180-day forecasts — on
  present evidence the oscillation is descriptive structure, not
  predictive signal.

## Assumptions and limitations

1. The null trend is a power law in log(age) fitted to the full
   history — the hypothesis under test supplies its own baseline.
2. One asset, one history: there is no cross-sectional validation;
   every "significance" statement leans on simulated nulls, whose own
   assumptions (even the GARCH upgrade) are approximations.
3. Two different clocks: the full-history oscillation lives in
   log(age); the post-peak fit lives in log(time-since-peak). Their
   frequencies (8.7 vs 8.6) are numerically close but are different
   objects and are never conflated in the outputs.
4. The trailing 1-year evaluation window spans only 0.058 in
   log-age — in the model's own natural clock, recent evidence is
   thin by construction.
5. Data: daily closes (Coin Metrics), crash-safe caches, fail-soft
   sources; a day when every input is dead is recorded as blind, not
   as a neutral reading.
6. Peak detection, filter bands, weights, and verdict thresholds are
   research decisions frozen in advance; every proposed change is a
   numbered decision item ruled on by the owner with data in view.

## The shadow program (current phase)

Since Phase 9, every proposed statistical upgrade runs *beside* the
frozen number, not instead of it. The dashboard's LPPL card carries a
SHADOW tab with six frozen-vs-shadow comparisons (each explains
itself on hover):

| row | frozen → shadow | pending ruling |
|---|---|---|
| mean/eval | −461 (sum) → −1.26 (per-eval) | D9-b: make the mean primary? |
| 365/730 | −0.11 / +0.16 (report-only) | D9-c: do long horizons score? |
| damping | requirement ≥1 → observed 0.41 | D9-e: should it gate the fit verdict? |
| impr | 29.2% → 27.9% (symmetric) | D9-e |
| p(osc) | 0.38 → 0.24 (GARCH) | D9-f: which p is headline? |
| freeze | 0.439 → 0.358 (frozen-at-trough) | D9-g: freeze the bound? |

(D9-a — refuse a composite when a weight-3 test is blind — and D9-d —
adopt the PL+LP1 rival into scoring — complete the set.) The shadow
numbers accumulate daily; the rulings happen when the owner judges
the soak sufficient. No verdict changes until then.

## Provenance

The suite was reviewed end-to-end in July 2026 by the Scientific
Bitcoin Institute (three independent reviewers; the review reproduced
every headline number). Phase 9 implemented that review as its
specification; four of its empirical claims were confirmed on our own
data and one expectation (the predictive value of the log-periodic
mode) was overturned out-of-sample. Current verdict: **STRESSED
(−0.20)** — the power law forecasts poorly at short horizons and the
valuation is at record lows relative to trend, but the envelope
holds, the anti-bubble fit is not fully qualified, and the
oscillation remains unproven.
