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

- `payload_vol_spread.json` carries a **synthetic `history` block** (M8-16):
  10 days (`2026-06-25`..`2026-07-04`), 5 tenors each (7/14/21/45/90d),
  spreads drifting ~0.40-0.47, with a deliberate **null 45d spread on
  `2026-06-30`** so the `vol_spread_trend` golden exercises the gap path
  (a null point, never a zero). The daily history did not exist when the
  set was recorded, so it is hand-added; keep it on any refresh.
