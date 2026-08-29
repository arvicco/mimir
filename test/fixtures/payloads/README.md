# test/fixtures/payloads -- recorded suite payloads for chart goldens

The `payload` members of a real dry-run artifact set
(`PUBLISH_DRY_RUN=1 ruby publish/publish.rb`, recorded 2026-07-06 from
live suite runs). These are the DETERMINISTIC inputs to the chart-spec
goldens (`test/golden/`): same payload in, same ECharts option out, so
a golden diff can only mean the chart code changed.

Regenerate deliberately (a payload refresh changes every dependent
golden, which then needs visual re-review + `rake golden:approve`):
run the dry-run publish, then copy each artifact's `payload` member
into `payload_<key>.json` here.

## Hand-added synthetic rows (not from the recorded set)

- `payload_lppl_latest.json` (M9-11) was extended with the Phase-9
  **shadow fields** the recorded 2026-07-06 run predates, so the
  `lppl_regime` golden exercises the right-side shadow scoreboard. Added
  additively (frozen fields untouched): `trend.detail.per_horizon` +
  `per_horizon_long` (mean_per_eval per horizon), `envelope.detail.
  freeze_candidate`, `fit.detail.b_negative`/`damping`/
  `damping_ref_threshold`/`null_v2`/`improvement_v2`, and
  `logperiodic.detail.p_value_v2`/`sims_v2`. Values are realistic and
  internally consistent (per_horizon sums match the frozen
  `bf_by_horizon`); they are synthetic, not a live capture. Keep them on
  any refresh (re-add, or regenerate from a real `lppl.rb --json` cache).
  M11-6 extended it again for the 2026-08-29 ruling flips:
  `trend.detail.headline_mean` (value = the per_horizon means' sum), and
  the envelope's frozen-rule shape -- `bound`/`floor`/`trough_ratios`
  now hold the FROZEN values (0.358/0.242) with the old drifting values
  moved to `bound_live`/`floor_live`/`trough_ratios_live` (0.435), the
  same shape a post-M11-5 live run emits. The lppl_regime golden's
  bound/floor markLines follow the frozen values.

- `payload_reserves_latest.json` (M11-7) is fully SYNTHETIC (deterministic
  cosine-drift series, 120 days ending 2026-08-11 to match the positioning
  fixture's window): the module shipped before its upstream fixture was
  recorded. Once `coinglass_exchange_balance_chart.json` lands (owner:
  `rake fixtures:record SOURCES=coinglass_exchange`), regenerate it
  offline via the contract harness (fake transport + FAKE_NOW) and
  re-bless the positioning golden.

- `payload_scenario_history.json` carries a trailing **synthetic blind
  row** (`2026-07-07`, `"blind": true`, composite 0.0) so the M8-10
  scenario_strip golden exercises the hollow/grey blind-day marker. The
  recorded 2026-07-06 run had no outage, so no real blind row existed to
  capture. Keep this row on any refresh (re-append it).

- `payload_vol_mstr.json` (M8-17) is the REAL `scripts/vol_mstr.rb --json`
  output, generated OFFLINE through the contract harness (fake transport +
  the recorded `cboe_options_mstr.json` fixture) under the vol_spread clock
  `FAKE_NOW=2026-07-04T19:00:00Z` (keeps the fixture's expiries in the
  future). Regenerate with:
  `RUBYOPT="-Itest/support -rfake_transport" FAKE_NOW=2026-07-04T19:00:00Z
  BTC_DATA_DIR=$(mktemp -d) ruby scripts/vol_mstr.rb --json`. Already minimal
  (3 tenors); drives the `vol_surface_mstr` golden.

- `payload_gex_trend.json` carries a **synthetic `mstr` block** (M8-18): the
  additive top-level `mstr` = `{series, stats}` that `scripts/gex_trend.rb
  --json` now emits from the MSTR entries of each snapshot's `us` capture. 5
  days (`2026-07-06`..`2026-07-10`) of MSTR spot/flip/CW/PW on MSTR's own dollar
  axis (~$95-101), drifting up, all `long_gamma`. The recorded 2026-07-06 set
  predates the `mstr` field, so it is hand-added; it drives the
  `gex_mstr_trend` golden. Keep it on any refresh (or regenerate from real
  snapshots once several days of `us` captures exist).

- `payload_vol_spread.json` carries a **synthetic `history` block** (M8-16):
  10 days (`2026-06-25`..`2026-07-04`), 5 tenors each (7/14/21/45/90d),
  spreads drifting ~0.40-0.47, with a deliberate **null 45d spread on
  `2026-06-30`** so the `vol_spread_trend` golden exercises the gap path
  (a null point, never a zero). The daily history did not exist when the
  set was recorded, so it is hand-added; keep it on any refresh.

- `payload_positioning_latest.json` is a **synthetic** `scripts/scenario/
  positioning.rb --json` payload (M10-4): 30 daily points across the six
  additive `series` (oi_close $B, global_ls / top_ls ratios, taker_buy %,
  long_liq / short_liq $M), generated through the REAL producer helpers
  (`build_series` + the band methods) so the shape is faithful. Thirty days
  is under the 91-value band window, so every band is **WARMUP** and the
  score 0 -- it drives the `chart_positioning` golden's designed WARMUP
  title AND fills all three panels. Regenerate from real Coinglass history
  once ≥91 days have accumulated.
