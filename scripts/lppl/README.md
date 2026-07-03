# lppl -- daily LPPL falsification/strengthening suite

Four independently falsifiable commitments of "LPPL as governing regime",
each tested daily against public data, aggregated into a verdict and an
evidence ledger. Ruby >= 2.5, stdlib only.

## Layout

| file            | role                                                    |
|-----------------|---------------------------------------------------------|
| prices.rb       | daily BTC-USD close cache (CryptoCompare, keyless)      |
| trend.rb        | T1: prequential out-of-sample BF, global power law vs   |
|                 |     "trend has bent" (3y-window PL) vs random walk      |
| envelope.rb     | T2: damped trough-ratio envelope + breach persistence   |
| fit.rb          | T3: anti-bubble LPPLS fit (Filimonov-Sornette           |
|                 |     linearization), Sornette filters, stability track   |
| logperiodic.rb  | T4: Lomb-Scargle significance of the oscillation vs     |
|                 |     AR(1) bootstrap null                                |
| percentile.rb   | T5 (wt 0, monitor): Perrenod age-adjusted valuation     |
|                 |     percentile -- empirical rank + record/persistence   |
| lppl.rb         | aggregator: verdict, tmux status, ledger                |
| common.rb       | shared: cache, O(1) range regression, 4x4 solver,       |
|                 |     peak detection, power-decay null                    |

## Run

    ruby lppl.rb                 # full run (updates prices first)
    ruby lppl.rb --tmux          # 'LPPL STRESSED -0.20 BF+0.4 r0.44
                                 #  trough 12Nov26/54k w7.9 p0.04'
                                 #  -> /tmp/lppl.status
    ruby lppl.rb --history       # also append data/ledger.jsonl
    ruby trend.rb                # any test runs standalone with detail

First run: downloads full price history and bootstraps the prequential
score cache from 2017 at weekly stride (a minute or two). Subsequent runs
append only newly matured evaluation dates. logperiodic runtime is
dominated by bootstrap sims (`--sims N`, default 100).

## Cron (after UTC close)

    15 0 * * *  cd $HOME/Dev/bitcoin/lppl && /usr/bin/ruby lppl.rb --tmux --history

## Reading the verdict

- The **trend BF** is the headline falsifier: cumulative out-of-sample
  evidence, ~10^BF odds for the global power law vs its best rival over
  the trailing year. Drifting decisively negative kills the regime claim
  regardless of oscillation aesthetics.
- **envelope** encodes the damping claim (trough ratios 0.40 -> 0.45 ->
  0.50 -> this cycle must print higher). It is expected to read *stressed*
  at current levels -- that is the model being genuinely tested, not a bug.
  Sustained persistence below the floors flips it to broken.
- **fit** scores structure quality, not price direction: filters + trough
  projection stability across runs. A wandering trough date is the classic
  LPPL overfit signature and is penalized explicitly.
- **logperiodic** guards against seeing omega in autocorrelated noise.
- **percentile** carries no verdict weight by design: an extreme reading is
  ambiguous between "deepest value ever" and "first out-of-sample failure".
  Its score encodes what disambiguates -- persistence at <=1st percentile
  (>= 60d flips it negative) or observed mean reversion after an extreme
  (flips positive). The `!` in the status line marks a record-low Z. The
  empirical percentile is the one to trust; the Gaussian number is printed
  for comparison with the published method.

The decisive single observation (does the trough land inside the fitted
window at the fitted depth) resolves once, in Q4 -- the daily BF and the
ledger are the drumbeat; that event is the verdict.

## Honest limits

Relative evidence only: the suite ranks LPPL against the specified rivals;
it cannot validate the model absolutely. The envelope rests on n = 3
historical troughs. Trend-model predictive variances ignore parameter
uncertainty (documented simplification). Extending the rival set in
trend.rb (e.g. a log-logistic saturation model) is a localized change:
add a model branch and it enters the BF automatically.
