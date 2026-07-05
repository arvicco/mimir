# Dashboard design (Phase 4)

The spec M4-2/M4-3 implement against. Constraints come from
`.claude/skills/mimir-design/SKILL.md` (owner rulings, Gate 3 rounds
1-4) -- nothing here overrides that file; this doc only adds the
production-surface decisions on the axes the rulings leave free.
Owner sign-off at Phase 4 planning; changes after that are new rulings.

## Subject and job

mimir: one owner's BTC analytics wall -- pre-computed evidence
(GEX / scenario / LPPL / BTCo), published to KV, aged honestly.
The page's single job: *what is the tape saying now, and how fresh is
the data behind it?* One screen, no navigation, no marketing copy.

## Inherited (already ruled, restated for the implementer)

- Dark surface: page #14171c, cards #1b1f26 / border #2a2f38; ECharts
  built-in dark theme, spec backgroundColor transparent.
- 2x2 quadrant grid exactly as preview.html has it after round 4:
  BTCo top-left, GEX top-right, LPPL bottom-left, Scenario (250px
  card) bottom-right. It survived four review rounds; do not rearrange.
- Compact one-line 13px chart titles carrying the load-bearing number;
  instant CSS hover bubbles from envelope meta; the three renderer
  hooks (tooltip_formatter, height, legend_widget) exactly as
  preview.html implements them.
- Palette anchors per the skill; bright = active, dim = inactive.

## New decisions (the design pass)

**Type: numbers are the identity.** Two roles, zero webfonts:
- data face: `ui-monospace, "SF Mono", Menlo, monospace` for EVERY
  number and status token -- strip chips, badges, ages, healthz. With
  `font-variant-numeric: tabular-nums` so ticking values never jitter.
- prose face: the existing system-sans stack for titles, bubbles, copy.
The owner lives in tmux; the dashboard speaks the same dialect. This
replaces any temptation toward decorative display type.

**Signature: the live age ticker.** The product's honest core is
"pre-built and aged, not live" -- so age IS the hero metric. Each
card's badge shows the staleness dot plus a live-counting age
(`4m12s`, mono, one shared 1 s setInterval; whole-page, cheap). Color
still by ttl bands (green <= ttl, amber <= 3x, red beyond). The header
right slot shows the newest `generated_at` over all keys as
`pub HH:MMZ` plus `n/11 fresh`. No other motion anywhere
(prefers-reduced-motion: the tick updates text only, exempt by
nature; everything else static).

**Layout wireframe** (header tightens preview's two rows into one):

```
| mimir            . gex@19:48 . scn@19:48 . lppl@06:10 ...   pub 19:48Z 11/11 |
| BTCo stress 70 STRESSED    4m12s .| GEX $M/1% . spot 62.7k     (p) DERI (c) |
|   [bars + gauge]                  |   [histogram]               (p) IBIT (c) |
|-----------------------------------+------------------------------------------|
| LPPL STRESSED +0.00       12h04m .| Scenario LEAN-FLUSH -0.17        4m12s . |
|   [3 panels]                      |   [250px strip + module column]          |
```

**Failure copy is direction, not mood.** Worker unreachable: banner
"API unreachable -- charts show nothing until /api/v1/index answers.
Check the Worker: `curl https://<host>/healthz`." Missing key: the
card says which key 404'd and which producer publishes it. Stale-red
badge needs no words -- the ticking age is the explanation.

**Quality floor.** Toggle/hover affordances are real `<button>`s
(reset styling) with a visible :focus-visible ring (#e6a23c, the
amber anchor); bubbles openable via focus, not hover-only. Grid
collapses to one column under 1100px (as preview). No npm, no build:
ECharts via the ONE pinned CDN tag + SRI hash; render code shared
with preview.html via plain `<script src="render.js">`.

## Architecture consequences

- `web/render.js` -- the single renderer: card builder, staleness
  math, bubble builder, FORMATTERS + WIDGETS registries, age ticker.
  preview.html and index.html both load it; hooks live in ONE place.
- `web/index.html` -- production loader: same-origin `/api/v1/:key`
  fetches, healthz banner, header strip. Dumb: no state beyond the
  charts array and one interval.
- `web/preview.html` -- stays the offline Gate surface: local
  `../data/publish_preview/` paths, no auth, keeps working with zero
  network beyond the CDN tag.
