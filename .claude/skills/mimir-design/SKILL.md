---
name: mimir-design
description: The mimir owner's dashboard/chart design system plus the repo's hard rendering constraints. Consult this BEFORE any visual work in this repo — writing or changing chart specs (publish/chart_specs.rb), anything under web/, ECharts options, goldens, hover/tooltip behavior, colors, layout, or when writing the spec for a subagent that will do such work. Trigger even for "small tweaks": most review-round failures here were small tweaks that violated a standing ruling.
---

# mimir design system

Distilled from the owner's Gate 3 review rounds (2026-07-05). Every rule
below was paid for with a human review cycle; violating one costs
another. When a new ruling lands, add it here in the same commit.

## Hard rendering constraints (architecture, not taste)

- A chart payload IS the ECharts option, published as JSON through KV.
  String keys, string-template formatters only — a JavaScript function
  anywhere in an option breaks serialization and the round-trip test.
- The renderer initializes ECharts with the built-in **dark theme**;
  specs set `'backgroundColor' => 'transparent'`. Do not hand-pick
  text/axis/legend colors the theme already tunes — the light-theme
  defaults (near-black titles, inactive-brighter-than-active legends)
  are exactly what the owner rejected.
- Exactly five renderer hooks exist, declared in envelope meta:
  `tooltip_formatter` (a NAME in the renderer's formatter registry),
  `height` (card pixels), `legend_widget` (a NAME in the renderer's
  HTML widget registry; the spec ships `legend.show=false` but keeps
  `legend.data` so ECharts still owns selection state and the widget
  drives it via legend actions), `tab_group` (+ `tab_label` /
  `tab_pos`; charts sharing a group render into ONE card as tabs --
  owner ruling D7-c 2026-07-06, the GEX card), and `group_style:
  'stack'` (owner ruling 2026-08-10: a tab_group rendered as ONE card
  with every member ALWAYS visible, stacked vertically by tab_pos,
  each member keeping its own head/badge/bubble at meta.height -- the
  vol_surface + vol_basis card). Add a new hook only with an owner
  ruling.

- Card placement (owner ruling 2026-08-10): the dashboard is a 3x2
  grid -- row 1 GEX · Volatility(stacked) · Vol-Spread, row 2
  Scenario · LPPL · BTCo. Order lives in render.js CARD_ORDER (the
  published index stays alphabetical); 3 columns is the norm, 2 under
  1160px, 1 under 780px. Never restore a breakpoint that turns a
  normal laptop window into 2 columns.
- Every chart registers `meta` (desc / axes / help) — 2-4 sentences
  compressed from docs/METHODOLOGY.md, rendered as hover bubbles.
- Goldens regenerate deterministically from test/fixtures/payloads/. A
  red golden is a question for a human; bless only via
  `rake golden:approve` after LOOKING at the rendered result.
- web/ stays single-file, inline CSS, vanilla JS, ECharts via one
  pinned CDN tag, no npm, no build step, served by `rake preview`.

## The owner's rulings

**Compact beats airy.** One-line ~13px titles that carry the
load-bearing number inline (`GEX $M/1% · spot 62.7k`,
`BTCo stress 70 STRESSED`); no subtexts; tight grid margins; no zoom
sliders (inside zoom with a sensible default window); no paginated or
scrolling legends. Whitespace is not a feature here — density is.

**Side panels go right, not below.** Legends, scoreboards, module
strips: vertical columns to the right of the plot, so rows stack
line-by-line and the plot keeps its height.

**An entity's views share its quadrant.** A chart's companion views
(the BTCo literal table) live INSIDE that chart's card -- shrink the
chart to make room -- never as a separate strip elsewhere on the page
(round 5: the full-width bottom table was rejected). One subject, one
card.

**Hover help everywhere, instantly.** Never native `title=` attributes
(fixed browser delay, unstyled blob). Card-level CSS bubbles open on
hover with structured paragraphs: description, `x —` / `y —` axis
meanings, `how —` usage. Canvas internals can't carry HTML bubbles, so
axis/UX explanations ride the card title + ⓘ affordance.

**Overlays never clip at the viewport.** ANYTHING that floats --
meta bubbles, ECharts data tooltips, future popovers -- must be fully
visible or change sides (rounds 5/5b: bottom-row bubbles AND canvas
tooltips were cut). Bubbles: measure-on-open flips `.bubble.up`
(orient() in render.js). Chart tooltips: `confine: true` is NOT
enough -- it confines to the chart CONTAINER, which itself can extend
below the fold, and ECharts applies confine AFTER any position
callback, clamping a flipped tooltip right back. The renderer
therefore applies a universal viewport-aware `tooltip.position`
callback WITH `confine: false` to every chart (tooltipPosition() in
render.js; payloads stay JSON -- functions are render-layer only).
Verify any floating element with a short-viewport Playwright run that
measures the REAL DOM (the ECharts tooltip is the `z-index: 9999999`
div), hovering via raw mouse.move -- locator.hover() auto-scrolls and
silently defeats edge-of-viewport scenarios.

**Hover data reads as one line per entity.** Aggregate — never one row
per series. Pattern: header `54k: +20.5M −15.33M` (level + totals),
then `DERI: +10.5M −5.33M` per venue; calls/positive in teal, puts/
negative in red; entities empty at that point omitted. Needs a
registry formatter — declare it in meta, implement it in the renderer.

**Filter insignificance out completely.** An entity invisible at
display precision (e.g. a venue whose whole book rounds to 0.00M)
appears NOWHERE — not in the legend, not in series, not in hover.
Zero-rows are noise the owner explicitly rejected, twice.

**Scale values at build time.** Emit data in the unit the human reads
($M, 2dp) so tooltips and axes need no client-side formatting.

**Sparse data must still be visible.** History files start with one
entry. Line series use filled symbols (`'symbol' => 'circle'`,
size ≥ 6) — the ECharts default emptyCircle ring is an invisible speck
on dark. A single point must read as a clear dot.

**Labels never collide.** Near-equal markLines (bound/floor) get
labels at opposite line ends; panel grids clear the title row. If two
labels CAN overlap for plausible data, they eventually will.

**Axis names ride the axis, not the title row.** A y-axis `name` at
the default top position lands in the title's line (round 4: scenario
and LPPL collided). Use `nameLocation: 'middle'` (rotated, in the left
gutter, `nameGap` ~44 with grid left ~60); the bottom would collide
with the time labels instead.

**Paired series toggles collapse to one line per entity.** Not one
legend row per series: `(p) DERI (c)` — click `(p)`/`(c)` for one
side, the entity name for both (both-shown → both hidden, anything
else → both shown). Sides keep their series colors; a fully hidden
entity dims whole. This is HTML the canvas legend can't draw — the
`legend_widget` hook exists for it.

**Opposing bar stacks overlay exactly.** When one stack is ≥0 and the
other ≤0 (calls/puts), set `barGap: '-100%'` so both sit on the same
x — the default side-by-side placement reads as misalignment (round
4).

**Bright = active, dim = inactive.** The dark theme handles this;
never override into the inversion.

**Palette anchors**: calls/positive `#0f7a5c` (bars) / `#2fbf8f`
(text); puts/negative `#c63939` / `#ef6b6b`; flip/bound lines amber
`#e6a23c`; stress bands green→amber→orange→red.

## Self-review before any owner handoff (DEV-LOOP.md step 6b)

You design blind unless you look. After any visual change:

1. Rebuild artifacts (offline from committed payloads, or
   `PUBLISH_DRY_RUN=1 ruby publish/publish.rb`), `rake preview`.
2. Screenshot headlessly and READ the image; crop-zoom suspect cards.
   Reproduce at the element's REAL rendered geometry: renderer hooks
   (meta.height) shrink cards, and a repro page at a comfortable size
   can hide crowding that only appears at the true 290px (the btco
   gauge tick collision survived one "fix" exactly this way):
   `'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
   --headless --disable-gpu --screenshot=<png> --window-size=2000,1400
   --hide-scrollbars http://localhost:8000/web/preview.html`
   (`sips --cropToHeightWidth H W --cropOffset Y X <png>` to zoom).
3. For interaction states (hover bubbles, tooltips, legend toggles)
   use the webapp-testing skill (Playwright) — static shots can't hover.
4. When a render mystery appears, isolate it with a minimal repro page
   before guessing (that is how emptyCircle-on-dark was found).
5. Critique your own screenshot against this file, fix, re-shoot.
   Hand the owner only what already passed your eyes.
