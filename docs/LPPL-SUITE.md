# The LPPL Suite, Explained

*A non-statistician's guide to what each test does and why -- companion to
README.md in the `lppl/` suite.*

The suite is easiest to understand as a **test harness for a theory**.
The theory (LPPL as governing regime) makes several independent,
checkable commitments about how Bitcoin's price behaves. Each script
tests one commitment; the aggregator (`lppl.rb`) is the CI verdict. No
single test can validate the theory -- but several of them can kill it,
and all of them accumulate evidence daily.

| test           | commitment tested                        | can it falsify? |
|----------------|------------------------------------------|-----------------|
| trend.rb       | one fixed power-law trend fits the data  | yes -- decisive |
| envelope.rb    | each crash bottoms shallower than last   | yes             |
| fit.rb         | the post-peak decline has the LPPL shape | weakens only    |
| logperiodic.rb | the oscillations are real, not noise     | weakens only    |
| percentile.rb  | (monitor) how rare is today, age-adjusted| context only    |

---

## trend.rb -- the out-of-sample prediction contest

The core LPPL claim is that Bitcoin's log-price wobbles around one fixed
curve: a power law in time. The honest way to test "is this the right
curve?" is **not** to fit it and admire the R-squared -- any flexible
curve fits the past. Instead, this test runs a continuous forecasting
tournament.

Every day in history, three models are handed *only the data available
up to that day* and asked to predict the price 30, 90, and 180 days
later. The contestants:

*the global power law* (the LPPL claim) -- *a power law fitted only to
the last 3 years* (the "trend has bent" hypothesis) -- *a random walk*
(the "there is no trend, just drift" null).

When the future arrives, each prediction is graded. Not just "how
close," but how close **relative to how confident the model claimed to
be**: a model that misses by 10% after claiming plus-or-minus 5%
precision is punished harder than one that missed by 10% while honestly
claiming plus-or-minus 20%. That grading rule is called the *log score*.

The grades accumulate over years of daily predictions. The headline
number -- the **Bayes factor** -- is simply the running score
differential, expressed as odds. BF +1.0 means the accumulated evidence
favors the global power law 10-to-1 over its best rival; BF -1.0 means
10-to-1 against.

This is the component that can genuinely kill the theory, because there
is no arguing with a model that keeps losing a fair forecasting contest
it was allowed to enter on its own terms.

*Engineering note:* recomputing thousands of historical fits daily is
made instant by a prefix-sum trick -- a regression over any date range
reduces to a handful of running sums maintained once, the same idea as
answering range-sum queries with a cumulative array.

---

## fit.rb -- does the decline have the claimed shape?

LPPL says a bust is not random decay. It is a smooth power-law fall with
wobbles superimposed, and the wobbles have a specific signature: each
successive oscillation is *shorter in time* than the last, like a
bouncing ball's bounces converging toward rest.

The equation describing this has **seven knobs**. Fitting seven knobs at
once invites garbage, so the script uses a classic divide-and-conquer
(the Filimonov-Sornette method): three knobs are "hard" -- the pattern's
start time, the decay steepness, the wobble frequency -- and get
brute-forced over a grid. For each grid point, the remaining four knobs
have an *exact* closed-form best answer (a small linear-algebra solve),
computed instantly. Best combination wins; a refinement pass then
sharpens the grid around the winner.

Crucially, **the fit itself is not the evidence** -- fitted curves always
look nice. The evidence is three sanity checks:

**Plausibility filters.** Do the fitted knobs land in the ranges real
historical bubbles and busts occupy, or did the optimizer wander to
weird corners just to chase noise?

**Stability.** Refit tomorrow with one more day of data: does the
projected trough date stay put, or jump by weeks? A real pattern
*converges* as data arrives; an overfit hallucination *wanders*. This is
the single most common way LPPL fits fool people, so the suite measures
it explicitly -- every run appends its parameters to a history file, and
a wandering trough estimate is penalized.

**Improvement over the null.** Does adding the wobble term actually beat
a plain no-wobble decay fit by a meaningful margin?

The forward-looking output -- projected trough date and level -- comes
from extrapolating the fitted curve and finding its minimum. If no
minimum exists within 400 days, that itself counts against the
anti-bubble reading.

---

## envelope.rb -- the "each crash is shallower" claim

Historically, each cycle's bottom has landed *less* far below the trend
line than the previous one: roughly 60% below, then 55%, then 50%.
LPPL-as-regime says this damping continues, so this cycle should bottom
*above* the last cycle's ratio.

The test is deliberately simple, because only three historical data
points support the claim. Each day it computes the price-to-trend ratio
and compares it against two lines: the **strong bound** (last cycle's
trough ratio -- damping intact means we stay above it) and the **hard
floor** (the worst ratio ever recorded -- below this, the claim is dead
in any form).

The key mechanism is the **persistence counter**: consecutive days spent
below each line. A brief spike below a floor is noise; a month camped
below it means the distribution has changed. Forty-five sustained days
below the strong bound, or thirty below the hard floor, flips the test
to broken.

This test is *expected* to read "stressed" at current price levels. That
is not a bug -- it is the model genuinely being examined, in real time.

---

## logperiodic.rb -- are the wobbles even real?

The most seductive failure mode in this entire field is staring at noisy
residuals and "seeing" the oscillation -- because random data with memory
(today's error resembling yesterday's) naturally produces slow,
wave-looking excursions. This test guards against that pareidolia.

Step one: remove the smooth decay and keep the leftovers (residuals).

Step two: run a **periodogram** -- think of it as trying every possible
wobble frequency and measuring how much of the leftover signal each one
explains. The *Lomb-Scargle* variant is simply the version that works
when data points are not evenly spaced. Ours are not, because the
theory's clock runs in *logarithmic* time, which stretches the early
days of the decline and compresses the later ones. The strongest
frequency gets a power score.

Step three, the crucial null experiment: generate a few hundred **fake
residual series** that have the same amount of memory and the same
noisiness as the real ones but *zero true oscillation* (an AR(1)
process, seeded deterministically so results are reproducible). Run the
identical frequency scan on every fake and ask: how often does pure
structured noise produce a peak as strong as the real one?

If 30% of the fakes beat it, our wobble is imagination. If fewer than 5%
do -- and the winning frequency lands in the historically plausible band
-- the oscillation is probably real. That "compare against deliberately
generated fakes" move is the **bootstrap**: no distribution tables, no
formulas taken on faith, just simulation.

---

## percentile.rb -- how rare is today, adjusted for Bitcoin's age?

A 40% deviation from trend was a Tuesday in 2013 and would be
apocalyptic in 2026, because the swings shrink as the asset matures. So
raw deviations across eras are not comparable.

The fix: every day's deviation gets rescaled by **how big deviations
typically were at that age**. The "typical size" is itself a fitted
curve that decays as Bitcoin ages (following Perrenod's published
method). The result is a **Z score**: today's deviation measured in
units of "normal for the era."

Today's Z is then ranked two ways. Against a textbook bell curve -- the
published method -- and, more honestly, against the **actual historical
distribution** of Z values, by simply counting what fraction of history
was ever this low. The empirical rank matters because deep in the tail,
the bell-curve assumption is precisely the thing that breaks.

This module deliberately carries **no verdict weight**, because an
extreme reading is ambiguous by construction: it is either the best
value signal the framework has ever produced, *or* the model failing
out-of-sample for the first time. A single 1-in-100 observation cannot
distinguish a rare draw from a changed distribution.

What disambiguates is time. Under the model, extremes revert. So the
score only fires on **persistence** (60+ days pinned at the 1st
percentile: mean reversion is failing, evidence against) or on
**observed reversion** (an extreme printed, then recovered: the model
behaving exactly as advertised). A `!` in the status line marks a new
record-low reading -- deeper, age-adjusted, than any prior cycle bottom.

---

## lppl.rb -- the verdict

A weighted vote. The forecasting contest and the envelope carry the most
weight because they test the load-bearing claims; the shape fit and the
oscillation test carry less because they can strengthen or weaken the
case but cannot settle it alone.

Two overrides sit above the arithmetic. If *both* the forecasting
contest and the envelope say no, the verdict is **FALSIFIED** regardless
of how pretty the curve fit looks. If *either one alone* says no, the
verdict is capped at **STRESSED** -- no amount of oscillation aesthetics
can rescue a theory whose trend is losing or whose envelope has broken.

The daily ledger exists because the decisive single observation -- does
the trough actually land where and when the fit projected -- resolves
only once, in Q4. Everything else is the drumbeat: evidence accumulating,
day by day, in a form that can be audited later. Designed falsification
thresholds beat post-hoc judgment; that is the entire point of writing
them down before the answer arrives.
