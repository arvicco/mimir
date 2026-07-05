# test/fixtures/payloads -- recorded suite payloads for chart goldens

The `payload` members of a real dry-run artifact set
(`PUBLISH_DRY_RUN=1 ruby publish/publish.rb`, recorded 2026-07-05 from
live suite runs). These are the DETERMINISTIC inputs to the chart-spec
goldens (`test/golden/`): same payload in, same ECharts option out, so
a golden diff can only mean the chart code changed.

Regenerate deliberately (a payload refresh changes every dependent
golden, which then needs visual re-review + `rake golden:approve`):
run the dry-run publish, then copy each artifact's `payload` member
into `payload_<key>.json` here.
