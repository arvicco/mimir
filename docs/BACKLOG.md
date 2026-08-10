# Backlog

Work packets for the dev loop (see `docs/DEV-LOOP.md`). Statuses:
`ready` -> `in-progress` -> `done` | `blocked: <reason>`. The executing
session updates its packet's status and appends one line to
`docs/WORKLOG.md`. Phase N+1 packets are elaborated only at Gate N.

Tiering (revised at Gate 1, owner-ruled 2026-07-04 -- see DEV-LOOP.md
section 2): tiers are assigned per packet at elaboration; `fable` is
NOT the default and carries a one-line justification on coding packets
(first-of-kind / cross-cutting / secret-adjacent / semantics-adjacent);
default to the cheaper tier when in doubt (failed verification bumps
one tier, costing one retry). Phases 0-1 below predate this: they ran
under the Stage 0 all-Fable rule, which ended at Gate 1.

---

## Phase 0 -- inventory, documentation + safety net (branch: phase-0)

## M0-1 · Loop bootstrap: branch, permissions, CI, backlog  [tier: fable] [status: done] [deps: --]
Goal: `phase-0` branch; `.claude/settings.json` permission profile
      (sandbox-freedom inside the repo, hard deny on wrangler /
      fixtures:record / main pushes / secrets paths); GitHub Actions CI
      (`rake compat` + `rake test` on ubuntu + macos-arm64, Ruby 3.3);
      this backlog + `docs/WORKLOG.md`.
Acceptance: branch pushed; first CI run green on both OSes; backlog
      carries all Phase 0 packets with goals/acceptance.

## M0-2 · Tool inventory & review memo  [tier: fable] [status: done -- all findings owner-ruled and executed; open at Gate 0: optional R-3/6/7, flagged R-11/12/13 (R-12 needs an analytics ruling)] [deps: --]
Goal: `docs/TOOL-REVIEW.md` covering every tool under `scripts/`
      (gex.rb, gex_us.rb, gex_btc_combined.rb, scenario/* incl. all 7
      modules, lppl/* incl. all 5 evidence tests, btco.rb, ingest.rb):
      purpose, data sources, output contracts (--json/--tmux shapes),
      maturity assessment (battle-tested vs new/barely-used), suspected
      weak spots, duplication across tools, refactor candidates.
      Read-only packet: no code changes.
Acceptance: memo covers 100% of scripts/; each tool has an explicit
      maturity verdict and a (possibly empty) refactor-candidate list;
      owner has reviewed and the agreed findings are marked -- these
      seed Phase 1's M1-13..n refactor packets.

## M0-3 · README.md v1  [tier: fable] [status: done -- owner accepted 2026-07-04] [deps: M0-2]
Goal: user-facing README at repo root: what each tool does today, exact
      commands (incl. --json/--tmux/--skip-update flags), required ENV
      per tool, per-tool maturity honestly stated (from the M0-2 memo),
      and an explicit "not yet implemented" list (publish pipeline,
      charts, dashboard). A newcomer reading only the README knows
      exactly what the tools can do today.
Acceptance: owner accepts; every documented command actually runs;
      nothing implemented is missing, nothing missing is claimed.

## M0-4 · Characterization: bs_gamma  [tier: fable] [status: done] [deps: --]
Goal: pin Black-Scholes gamma as implemented in the gex tools: exact
      known values (precomputed reference points), put/call gamma
      symmetry, edge behavior (deep ITM/OTM, near-zero time). Pattern:
      test/unit/test_lppl_common.rb.
Acceptance: rake test green; values pinned to current behavior (no
      "fixes" -- deviations become decision items); no network.

## M0-5 · Characterization: OSI/Deribit instrument parsing  [tier: fable] [status: done] [deps: --]
Goal: pin instrument-name parsing in gex.rb (Deribit: BTC-27MAR26-100000-C
      shapes) and gex_us.rb (OSI: IBIT260327C00100000 shapes): expiry,
      strike, type extraction; malformed-input behavior as-is.
Acceptance: rake test green; both parsers covered incl. month map and
      decimal-strike handling; no network.

## M0-6 · Characterization: percentile envelope fit + Lomb-Scargle  [tier: fable] [status: done] [deps: --]
Goal: pin lppl/envelope.rb percentile-envelope fitting and the
      Lomb-Scargle periodogram (logperiodic.rb) on synthetic inputs:
      envelope on a constructed series with known percentile bands;
      Lomb-Scargle peak frequency/power on a synthetic sinusoid (exact
      tolerance policy set here -- this packet defines the numerical
      tolerance conventions for the whole suite).
Acceptance: rake test green; synthetic generators seeded
      (Random.new(42)); tolerances documented in-test; no network.

## M0-7 · Characterization: btco metrics math  [tier: fable] [status: done] [deps: --]
Goal: pin CEBE / mNAV / convert ITM-OTM treatment from btco.rb on a
      small synthetic universe (hand-built company entries exercising
      each branch: converts ITM, OTM, at boundary; missing fields).
Acceptance: rake test green; synthetic universe as inline fixture (no
      real universe.json dependency); every metric branch hit; no network.

## M0-8 · Characterization: ingest pure parts  [tier: fable] [status: done] [deps: --]
Goal: pin ingest.rb's pure functions: `excerpt` windowing (boundaries,
      overlaps, short docs) and `diff_against` (added/changed/removed
      detection on synthetic before/after models).
Acceptance: rake test green; no ANTHROPIC_API_KEY needed, no network;
      extraction prompt/schema untouched (contract, Golden Rule 5).

## M0-9 · Methodology documentation  [tier: fable] [status: done] [deps: M0-2]
Goal: docs/METHODOLOGY.md for new users (owner request 2026-07-04):
      per-tool rationale, model assumptions, every displayed field and
      its interpretation, token-by-token status-line decodes, worked
      readings of real output, honest caveats (GEX sign trust, trend-BF
      magnitude/cache-density, empirical-vs-gaussian percentile).
Acceptance: a newcomer can decode any tool's terminal output unaided;
      linked from README; owner review at Gate 0.

## Gate 0 (human)
~~Byte-identical vs pre-import captures~~ amended (no pre-import copies
survived): characterization suite + loop-run capture review
(TOOL-REVIEW.md section 6, done 2026-07-04). Memo + README accepted.
Remaining owner actions: sign off F-16 (Coin Metrics price source),
rule F-17 (btco quote-source replacement), eyeball the first LPPL
readings, merge PR `phase-0 -> main`.

---

## Phase 1 -- fixtures + contract tests (branch: phase-1)
Gate 0 closed 2026-07-04 (PR #1). M1-1..5 (seam + migration) and M1-12
(BTC_DATA_DIR) were delivered in Phase 0, as were the memo refactors.
All [tier: fable] (Stage 0).

## M1-6 · Implement rake fixtures:record  [tier: fable] [status: done -- implementation; recording itself is the owner-run Gate 1 step] [deps: --]
Goal: replace the Rakefile stub: for each registered upstream response
      shape, fetch once through BTC::Http, trim to minimum size (drop
      rows beyond what parsers need), redact anything sensitive, write
      test/fixtures/<source>_<shape>.json + per-file provenance note
      (url, retrieved date). Reuses lib/btc/health.rb's SOURCES where
      shapes align; adds fixture-only shapes (full option book slice,
      farside HTML sample, EDGAR filing excerpt, stooq gone -- cboe
      quote). RUNNING it stays owner-only (network; deny-listed).
Acceptance: task implemented + unit-tested against a fake transport
      (writes correct layout without network); rake gates green.

## M1-7 · Contract tests: gex family --json  [tier: fable] [status: done -- gex_us pins self-enable once the owner re-records cboe_options.json (F-20)] [deps: M1-6]
Goal: test/contract/ pins field presence/types (not values) for
      gex.rb, gex_us.rb (BOTH shapes: single-ticker object, multi
      array -- F-10), gex_btc_combined.rb (venues[], combined{},
      profile{}), via fixtures + injected transport.
Acceptance: red against a mutated fixture, green against real; no network.

## M1-8 · Contract tests: scenario modules + aggregator  [tier: fable] [status: done -- etf_flows/cb_premium success pins self-enable on the owner re-record (F-21/F-22)] [deps: M1-6]
Goal: per-module --json contract (name/score/headline/ts; the
      funding/onchain name quirks pinned -- F-11), fail-soft shape with
      'unavailable': true (F-12), one-JSON-line stdout discipline
      (F-9), aggregator composite/regime fields.
Acceptance: every module covered; no network.

## M1-9 · Contract tests: lppl tests + aggregator  [tier: fable] [status: done] [deps: M1-6]
Goal: per-test --json contracts on a synthetic price cache written to
      a temp BTC_DATA_DIR (tests run the real scripts offline); ledger
      line field set; status_line format.
Acceptance: all five tests + aggregator covered; no network.

## M1-10 · Contract tests: btco --json  [tier: fable] [status: done] [deps: M1-6]
Goal: success shape (companies[], stress fields) on a synthetic
      universe + fixture quotes; fail-soft shape; --tmux line format.
Acceptance: covered incl. STALE/placeholder flags; no network.

## M1-11 · Contract test: ingest proposal schema  [tier: fable] [status: done] [deps: --]
Goal: proposal JSON shape (ticker/accession/form/diff/extraction keys)
      + diff computation on fixture excerpts; extraction prompt/schema
      text pinned verbatim (Golden Rule 5 tripwire).
Acceptance: no ANTHROPIC_API_KEY, no network.

## M1-14 · F-22: per-row flows parser (BTC::Flows)  [tier: fable] [status: done -- owner-approved analytics fix 2026-07-04] [deps: --]
Goal: replace etf_flows' tag-strip regex (swallowed each next row's
      day-of-month: rows halved AND day numbers reported as daily
      totals) with per-<tr>/<td> parsing; exact-value pins against the
      recorded real page; scoring/thresholds byte-identical; pre-fix
      history flagged in README/METHODOLOGY.
Acceptance: unit pins green (13 rows, -222.6/-296.0/+223.5); recorder
      trim counts with the new parser; contract skip flips live.

## M1-15 · F-23: etf_flows source chain + CoinGlass leg  [tier: fable] [status: done -- coinglass fixture records on the owner's next keyed run] [deps: M1-14]
Goal: farside direct -> Internet Archive latest raw snapshot (new
      BTC::Http.get_follow) -> CoinGlass flow-history (COINGLASS_API_KEY,
      free Hobbyist), first source with >= 10 rows; additive 'source'
      field in --json; recorder + health registry mirror the chain
      (farside direct soft-registered: WARN not FAIL).
Acceptance: rake green; fail-soft only when all three legs dead;
      SECRET_ENV redacts the new key; .env.example updated.

## M1-16 · rake fixtures:verify -- automated fixture safety digest  [tier: opus -- spec-driven implementation; registry/probe pattern exists in health.rb to copy] [status: done -- first delegated packet under the new tiering; Fable spec + review, Opus implementation] [deps: M1-15]
Goal: owner-ruled 2026-07-04 ("don't load onto human what automation
      is meant for"): replace the Gate 1 eyeball-the-diff step with an
      offline task printing one digest line per fixture (recorded-at,
      load-bearing stats: spot, expiry ranges, row counts, last dates)
      plus hard safety checks (secret-leak scan, JSON/HTML parse,
      README provenance drift) and aging WARNs (near-expiry boards,
      old recordings). Runs at the end of fixtures:record and joins
      the default rake gate.
Acceptance: rake fixtures:verify all OK/WARN on the committed
      fixtures; FAIL (nonzero exit) on missing file, unparseable
      fixture, secret material, or README drift -- each pinned by a
      unit test; no network; rake green.

## Gate 1 (human)
Recording + keyed re-record done 2026-07-04 (F-20/21/22/23 fixes all
recorded through). Owner checklist, all automated per the 2026-07-04
ruling: `rake fixtures:verify` all OK/WARN (digest numbers sane vs
your screen), `rake test:contract` 0 skips (confirmed), README
updated; merge PR phase-1 -> main. (F-4's code half remains a Phase 2
design input.)

---

## Phase 2 -- publish pipeline (branch: phase-2)
Gate 1 closed 2026-07-04 (PR #2). First phase elaborated and executed
under the revised tiering policy (DEV-LOOP.md section 2). Scope:
ARCHITECTURE.md section 6 Phase 2; KV contracts in section 4.1/4.2.
PUBLISH_DRY_RUN=1 is the default until Gate 2; nothing here touches
the network except through BTC::Http, and no model ever runs a real
publish (Golden Rule 3).

## M2-1 · publish/kv_client.rb  [tier: fable -- secret-adjacent (CF_API_TOKEN) + first-of-family: retry/redaction pattern everything downstream copies] [status: done] [deps: --]
Goal: PUT/GET against the Cloudflare KV REST API through BTC::Http:
      bearer auth from ENV (CF_ACCOUNT_ID/CF_KV_NAMESPACE_ID/
      CF_API_TOKEN), bounded retries with backoff on 429/5xx, never
      logs or raises token or payload bodies (error paths redact);
      env-gated read-only probe registered in health.rb SOURCES.
Acceptance: unit tests against a fake transport pin: auth header,
      retry/backoff schedule and cap, non-retryable 4xx behavior,
      redaction of token in every error path (incl. StatusError
      bodies); rake green; no network in tests.

## M2-2 · publish envelope + index (pure)  [tier: opus -- fully specified in ARCHITECTURE.md 4.2, pure functions with contract tests] [status: done -- Opus implementation, Fable spec + review, zero deviations] [deps: --]
Goal: publish/envelope.rb: wrap(key, payload, ttl_hint_s, now:) ->
      {v:1, key:, generated_at:, ttl_hint_s:, source:, payload:} per
      ARCHITECTURE 4.2 verbatim (source: hostname); build_index(rows)
      -> v1:index payload listing every key with generated_at. The
      envelope field set is a NEW frozen contract: contract test pins
      exact keys in the same commit.
Acceptance: exact-value unit tests (fixed now:); contract test on the
      field set; rake green; no IO in the module.

## M2-3 · publish/publish.rb orchestrator (dry-run first)  [tier: opus -- glue against M2-1/M2-2 with a written spec and offline oracle] [status: done -- Opus implementation, Fable spec + review] [deps: M2-1, M2-2]
Goal: collect the four suites' freshest --json outputs (BTC::Suite
      subprocess runs; scenario history + lppl ledger tails per
      ARCHITECTURE 4.1), wrap envelopes, and: PUBLISH_DRY_RUN=1
      (default) -> write the full artifact set to
      data/publish_preview/ and /tmp/publish.status line; real mode
      (explicit PUBLISH_DRY_RUN=0 + CF_* env) -> kv_client PUTs of
      v1:* keys + v1:index. A failed suite publishes its fail-soft
      JSON, never blocks the others.
Acceptance: dry-run layout + status-line format pinned offline via
      fake transport + synthetic suite outputs; per-key envelope
      correctness; no network in tests; rake green. Real-mode PUTs
      exercised only against the fake transport.

## Gate 2 (human)
Owner reviews the dry-run artifact set (data/publish_preview/ -- the
loop provides exact files + what sane looks like), creates the KV
namespace + scoped token (dashboard or wrangler, human-only), runs the
first real publish by hand. README updated before the gate.

---

## Phase 3 -- chart specs (branch: phase-3)
Gate 2 closed 2026-07-04 (PR #3; first real publish 7/7 keys LIVE).
Scope: ARCHITECTURE.md section 6 Phase 3 -- publish/chart_specs.rb as
pure payload->ECharts-option functions, golden-file tests, offline
preview harness. Chart payloads ARE the ECharts option object
(envelope adds provenance; the dashboard just calls setOption) -- the
option's top-level structure is a frozen contract per chart once its
golden is blessed. Goldens are DETERMINISTIC: generated from committed
payload fixtures (recorded real suite outputs), never from live runs;
`rake golden:approve` re-generates from fixtures and blesses only
after the human eyeballs preview.html (Gate 3).

## M3-1 · gex_profile spec + golden harness + payload fixtures  [tier: fable -- first-of-family: sets the chart-spec pattern, the golden workflow, and an additive analytics-output change] [status: done -- golden is PROVISIONAL until Gate 3 visual review re-blesses] [deps: --]
Goal: (a) record committed payload fixtures (test/fixtures/
      payload_<suite>.json) from the live dry-run artifacts;
      (b) additive gex_btc_combined.rb --json field: per-level
      put/call split and per-venue profiles (the chart needs them;
      combined profile today is net-only) -- ADDITIVE, contract test
      updated same commit, no scoring/semantics change;
      (c) publish/chart_specs.rb with gex_profile(payload): per-strike
      bars (put/call split), flip + wall markLines, per-venue legend
      toggle, BTC axis; (d) the golden test harness: spec generated
      from the payload fixture byte-diffed against test/golden/
      chart_gex_profile.json, failing diff PRESENTED never
      auto-blessed; rake golden:approve reworked to regenerate from
      fixtures (deterministic) post-review.
Acceptance: rake green with the golden present; harness red on any
      spec drift; gex_btc_combined contract test covers the additive
      field; no network.

## M3-2 · scenario_strip spec  [tier: opus -- pattern-following against M3-1's harness + a written spec] [status: done -- Opus batch, Fable spec + review; goldens PROVISIONAL until Gate 3] [deps: M3-1]
Goal: scenario_strip(latest, history): composite time series from the
      history tail + current module score heat-strip (7 modules,
      -1/0/+1 colors), regime bands annotated.
Acceptance: golden green from payload fixtures; rake green.

## M3-3 · lppl_regime spec  [tier: opus -- pattern-following, same harness] [status: done -- Opus batch, Fable spec + review; goldens PROVISIONAL until Gate 3] [deps: M3-1]
Goal: lppl_regime(latest, ledger): log price vs trend + damping
      envelope bands, projected trough marker, BF sparkline,
      percentile/Z panel (grid layout).
Acceptance: golden green from payload fixtures; rake green.

## M3-4 · btco_table spec  [tier: opus -- pattern-following, same harness] [status: done -- Opus batch, Fable spec + review; goldens PROVISIONAL until Gate 3] [deps: M3-1]
Goal: btco_table(latest): universe table via ECharts dataset (sortable
      columns), stress gauge, STALE/placeholder rows visually flagged.
Acceptance: golden green from payload fixtures; rake green.

## M3-5 · publish pipeline emits v1:chart:* keys  [tier: opus -- glue against the M3-1 pattern; PUB status count changes are contract-test updates in the same commit] [status: done -- Opus implementation, Fable spec + review] [deps: M3-1, M3-2, M3-3, M3-4]
Goal: Pipeline.run generates the four chart envelopes from the
      just-collected payloads (chart ttl = its source key's ttl) and
      publishes/previews them; expected-count in the PUB status line
      grows accordingly (frozen contract: tests updated same commit).
      A skipped source key skips its chart.
Acceptance: dry-run preview carries chart_*.json; unit pins updated;
      rake green.

## M3-6 · web/preview.html offline review harness  [tier: opus -- small fully-specified JS; flagged web/: minimal dumb JS, ECharts via pinned CDN tag, no npm] [status: done -- Opus implementation, Fable spec + review; serve command fixed to python3 (webrick left the Ruby stdlib)] [deps: M3-5]
Goal: static page rendering every chart_*.json from
      data/publish_preview/ side by side (fetch relative paths; run
      via `ruby -run -e httpd data/publish_preview` or file://-safe
      inline loader), staleness badge from each envelope's
      generated_at/ttl_hint_s. ECharts pinned to an exact CDN version
      tag. This is the Gate 3 visual-review surface.
Acceptance: owner can open it and see all four charts rendered from
      the committed preview artifacts; no build step, no npm.

## M3-7 · Gate 3 feedback: envelope meta + compact GEX rework  [tier: fable -- envelope contract change + the compact pattern the other charts copy] [status: done] [deps: M3-6]
Goal: owner design review 2026-07-05: (a) additive envelope 'meta'
      (desc/axes/help strings for hover bubbles, chart envelopes only,
      sourced from METHODOLOGY-grade summaries in the CHARTS registry,
      passed through the pipeline); (b) gex_profile compaction: venues
      with all-zero data excluded entirely, series values scaled to $M,
      call/put aggregate rows pinned to the top of the hover bubble
      (green/red), right-side vertical legend as venue C/P stacked
      pairs (DERI for Deribit), no slider (inside zoom only), one-line
      small title, tight grid margins.
Acceptance: goldens re-blessed; envelope meta pinned additively; zero
      venue exclusion + $M scaling + aggregate-first tooltip pinned in
      unit tests; rake green.

## M3-8 · Gate 3 feedback: compact scenario/lppl/btco + preview hover bubbles  [tier: opus -- applying the M3-7 pattern per written spec] [status: done -- Opus implementation, Fable spec + review] [deps: M3-7]
Goal: scenario module scoreboard moves right of the chart (vertical),
      compact one-line titles + tight grids on all three, meta strings
      for each, preview.html: compact header/status strip, per-card
      hover bubble rendering envelope meta (title hover = description,
      i-affordance = axes + UX help).
Acceptance: goldens re-blessed; rake green; owner re-review.

## M3-9 · Gate 3 feedback round 2: hover UX + tooltip aggregation + significance filter  [tier: fable -- introduces the renderer-hook contract (named formatter registry + height hint)] [status: done] [deps: M3-8]
Goal: owner review round 2: instant structured hover bubbles (native
      title= tooltips too slow/unformattable -- CSS popover anchored
      inside the card, desc/axes/help paragraphs, viewport-safe);
      ECharts tooltips confined to the viewport on all charts; gex
      hover restructured to one line per venue ("DERI: 10.5M -5.33M",
      calls green puts red) with cross-venue totals on the level
      header line -- needs the new meta.tooltip_formatter renderer
      hook ('gex_levels'); venues invisible at $M display precision
      (<0.05M everywhere) excluded from the chart completely;
      scenario card height-hinted to half a quadrant (meta.height).
Acceptance: goldens re-blessed; hooks pinned (opt-in only); rake
      green; owner re-review.

## M3-10 · Gate 3 feedback round 3: dark theme + visual self-review loop  [tier: fable -- render-contract change (theme) + a new loop practice] [status: done] [deps: M3-9]
Goal: owner review round 3 ("grey text too dark; active/inactive legend
      inverted; do you lack design intuition?"): root cause was ECharts
      LIGHT-theme defaults on a dark page (title/legend text #333,
      inactive legend brighter than active) AND the loop designing
      blind. Fixed: renderer inits with the built-in dark theme (specs
      set backgroundColor transparent), page greys brightened, sparse
      series get filled 7px symbols (default emptyCircle ring is
      invisible on dark), lppl bound/floor labels separated to opposite
      line ends, panel grid clears the title. NEW LOOP PRACTICE: the
      loop headless-screenshots preview.html (Chrome --headless) and
      reviews the pixels itself before every owner handoff.
Acceptance: goldens re-blessed; self-review screenshot attached to the
      handoff; rake green.

## M3-11 · Gate 3 feedback round 4: axis-name collisions, grouped C/P toggles, bar overlay  [tier: fable -- adds a third renderer hook (legend_widget contract) + coupled visual iteration; the spec tweaks alone would be sonnet] [status: done -- goldens PROVISIONAL until Gate 3] [deps: M3-10]
Goal: owner review round 4: (a) scenario/lppl y-axis names collided
      with the one-line titles -- names now ride the axis itself
      (nameLocation middle, rotated in the left gutter; bottom
      placement would collide with the time labels instead);
      (b) GEX legend's two lines per venue -> one-line grouped toggle
      `(p) DERI (c)`: p/c click one side, the venue name clicks both.
      Needs an HTML control the canvas legend can't express -> THIRD
      renderer hook meta.legend_widget (name in a renderer widget
      registry, same pattern as tooltip_formatter); spec ships
      legend.show=false so ECharts still owns selection state;
      (c) GEX call/put columns at the same level now overlay exactly
      (barGap -100%; safe -- calls >= 0, puts <= 0).
Acceptance: goldens re-blessed after self-screenshot review; hook
      pinned in tests + chart_specs header + mimir-design skill; rake
      green; owner re-review.

## Gate 3 (human)  [status: CLOSED 2026-07-05 -- PR #4 merged after four review rounds; goldens owner-blessed]
Owner opens web/preview.html against a fresh dry-run, eyeballs all
four charts (the loop provides exact commands + what sane looks
like), runs `rake golden:approve`, merges PR phase-3 -> main.

# Phase 4 -- Cloudflare layer (branch phase-4, ARCHITECTURE section 6)

Design spec: docs/DASHBOARD-DESIGN.md (frontend-design pass on top of
.claude/skills/mimir-design). Deploys stay HUMAN actions (Golden Rule
3): the loop prepares wrangler.toml and prints exact commands only.

## M4-1 · Worker API: web/worker.mjs + wrangler.toml + node test harness  [tier: fable -- secret-adjacent (optional AUTH_TOKEN bearer) + first-of-kind runtime/test contract for JS in this repo] [status: done -- .mjs not .js (node ESM without a package.json); 12 node tests incl. URL-normalization pin] [deps: --]
Goal: GET /api/v1/:key -> KV envelope verbatim (Cache-Control
      public/max-age=60, X-Generated-At, X-Data-Age-Seconds), 404
      unknown key (strict key allowlist regex), 401 when AUTH_TOKEN is
      set and bearer mismatches (constant-time compare; never echo the
      token), GET /healthz -> {ok:true,worker_ts}. Pure exported
      handler(request, env) so tests inject a fake KV; wrangler.toml
      with MIMIR binding prepared, NOT deployed. Test harness:
      `node --test test/web/` (node built-in runner, zero npm),
      wired as rake web:test -- joins the default gate when node is
      present, WARNs otherwise; CI has node on both OSes.
Acceptance: routing/auth/header matrix pinned incl. 404/401 paths and
      redaction; rake green; no deploy performed.

## M4-2 · shared renderer web/render.js extracted from preview.html  [tier: opus -- refactor of four-round-reviewed code against a written spec; oracle = pixel-identical preview screenshots + node --check] [status: done] [deps: --]
Goal: card builder, staleness math, bubble builder, FORMATTERS +
      WIDGETS registries, age-ticker util move to web/render.js
      (plain script, no modules/build); preview.html slims to a
      loader using it. Hooks then live in ONE place for both surfaces.
Acceptance: before/after headless screenshots of preview.html match
      (chart pixels identical; header/badge changes only if M4-3
      pulls them in later); node --check both files; rake green.

## M4-3 · production dashboard web/index.html  [tier: opus -- implements docs/DASHBOARD-DESIGN.md against the M4-2 renderer; fable reviews with screenshots per DEV-LOOP 6b] [status: done] [deps: M4-1, M4-2]
Goal: same-origin /api/v1/ loader with the design doc's header (one
      line: name, per-key chips, pub HH:MMZ n/11 fresh), live age
      tickers (the signature), healthz-aware failure banner with
      directive copy, mono-numeral type system, focus-visible ring,
      one-column collapse <1100px. Local review path: rake preview
      serves it against data/publish_preview with a stub /api shim
      (test-only, in the preview server).
Acceptance: self-screenshot review (static + Playwright interaction
      states) BEFORE owner handoff; mimir-design skill checklist
      passes; rake green.

## M4-4 · ECharts SRI pin on both pages  [tier: sonnet -- mechanical with a deterministic oracle (hash recomputed from the pinned CDN artifact by a checked-in script)] [status: done -- integrity= + crossorigin= added to both pages; drift check lives in BTC::Health.scan_sri (lib/btc/health.rb), wired into rake health; 7 unit tests in test/unit/test_btc_health.rb] [deps: M4-2, M4-3]
Goal: integrity= + crossorigin on the ONE pinned CDN tag in
      preview.html and index.html; tools/sri_check.rb (stdlib)
      recomputes and compares -- registered so rake health catches
      drift offline against a committed hash file.
Acceptance: both pages carry the same pinned version + hash; tamper
      test red-checked; rake green.

## M4-5 · rake deploy task + docs/DEPLOY.md + README  [tier: opus -- owner-run automation wrapping wrangler with pre-flight checks; fable reviews (deploy adjacency)] [status: done -- lib/btc/deploy.rb (pure preflight/substitute/smoke + injectable runner/http orchestrator), rake deploy (refuses under CI, not in default gate, deny-list target), 21 unit tests, docs/DEPLOY.md, README->Phase 4] [deps: M4-1, M4-3, M4-4]
Goal: owner ruling 2026-07-05 -- automation over a command list: a
      `rake deploy` task the OWNER runs (never the loop / never CI --
      Golden Rule 3 stands; the task refuses under CI env). Pre-flight:
      rake green, wrangler + CF_* env present, config generated from
      the committed wrangler.toml template with the namespace id from
      ENV; then wrangler deploy + Pages publish, post-deploy smoke
      probes (healthz 200, index key 200 + sane age, one 404 path).
      docs/DEPLOY.md documents the task, first-time setup (Pages
      project, route), rollback; README updated to the Phase 4
      capability set (honest about what does not work yet).
Acceptance: dry-run mode proves the pipeline without network; the
      task is deny-listed for the loop like fixtures:record; a
      newcomer could deploy from the doc alone; rake green.

## M4-7 · BTCo literal sortable table on the dashboard  [tier: opus -- renderer-side HTML from the published btco:latest payload against the design doc addendum; no new keys, no analytics] [status: done -- ruled in by owner (D4-b) 2026-07-05] [deps: M4-2, M4-3]
Goal: plain <table> next to the bars chart: ticker, BTC held, mNAV,
      netNAV, leverage, as_of; STALE/placeholder flags carried over;
      tiny vanilla column sort (click header, mono numerals, no
      libraries). Renders from the same v1:btco:latest envelope the
      chart uses.
Acceptance: self-screenshot + Playwright sort-interaction review
      before owner handoff; mimir-design checklist passes; rake green.

## M4-8 · Live review round 5: in-quadrant BTCo table + viewport-aware bubbles  [tier: fable -- shared-renderer behavior change + coupled visual iteration] [status: done] [deps: M4-7]
Goal: owner review of the LIVE site: (a) the BTCo universe table moves
      INSIDE the btco_table quadrant (chart shrinks to 290px, table
      below it in the same card; the full-width bottom strip is gone --
      kept only as the fallback when the chart card is absent);
      (b) hover bubbles flip UPWARD when the default position would
      clip at the viewport bottom (render.js measures on open, both
      pages carry .bubble.up). Both recorded as general rulings in the
      mimir-design skill (owner: "make bubble requirement part of
      general design guideline").
Acceptance: Playwright pins top-row bubble opens down, edge-of-viewport
      bubble flips and stays fully visible, table lives in-quadrant with
      no .wide strip; screenshots reviewed; rake green.

## Gate 4 (human)  [status: CLOSED 2026-07-06 -- PR #5 merged; owner ran rake deploy, site LIVE, smoke 4/4, noindex verified live]
Owner does first-time CF setup (Pages project + Worker route), runs
`rake deploy` (M4-5), walks the smoke checklist against the live
host, merges PR phase-4 -> main.

## Decision items -- RESOLVED at Phase 4 planning (owner, 2026-07-05)
- D4-a LPPL price-vs-trend panel: PARKED for v1.1 (needs a new
  published price-series key; analytics-adjacent).
- D4-b BTCo literal sortable table: RULED IN -> M4-7.
- D4-c Worker auth: PUBLIC-READ at Gate 4. Trade-off recorded: a
  bearer token in a browser dashboard is the weakest option (token
  must live client-side; caching goes private); Cloudflare Access is
  the real lock but is console-config, addable later with NO code
  change. Payloads are derived market analytics (no secrets);
  exposure = hostname discovery + KV read quota, mitigated by
  max-age=60, unguessable project name, noindex. AUTH work pushed to
  the END of the queue (below). The worker keeps the dormant
  AUTH_TOKEN branch from the committed M4-1 spec so flipping it on
  never needs a code change.

---

## Phase 5 -- ops integration (branch: phase-5)

Elaborated at Gate 4 close, amended at the 2026-07-06 multi-phase plan
approval (ARCHITECTURE.md section 6 Phase 5). Everything here PREPARES
ops artifacts; installing launchd agents on novo and running the soak
are HUMAN actions (Golden Rule 3, DEV-LOOP section 7). publish.rb runs
the four suites as subprocesses and publishes in one pass, so there is
ONE scheduled publisher job, bi-hourly (D5-a). Ingest is NOT scheduled
in this phase (D6-a: interactive; Phase 6 adds a discovery-alert job).

## M5-1 · ops/ wrapper + prepared launchd agent (publisher)  [tier: opus -- prepared-not-installed cron/launchd entries vs a written spec (named at this tier in DEV-LOOP section "Opus"); fable reviews (secret-adjacent: env-file sourcing)] [status: done -- opus, fable review extended the --apply ban to plists] [deps: --]
Goal: new top-level `ops/` dir: (a) `ops/run_publish.sh` -- sh wrapper
      that sources `~/.config/mimir/env` (MIMIR_ENV_FILE overridable;
      refuses with a clear, secret-free message if absent), cds to the
      repo, execs `PUBLISH_DRY_RUN=0 ruby publish/publish.rb`, appends
      stdout+stderr to `~/Library/Logs/mimir/publish.log` (publish
      already redacts; wrapper never echoes env). Exit code passes
      through (publish is nonzero on real-publish failure -- that is
      the cron alarm). (b) launchd plist `ops/com.mimir.publish.plist`
      (StartInterval 7200 per D5-a), absolute paths via an install-time
      sed step documented in RUNBOOK; RunAtLoad false; launchd's
      no-overlap semantics noted in the plist comments.
Acceptance: `bash -n` + plist well-formedness/required-keys checks
      wired into `rake health` as offline scans (registered, so drift
      fails the gate; pure-Ruby XML check, portable to CI -- plutil is
      macOS-only); env-missing refusal pinned by a unit test shelling
      the wrapper with a fake HOME; no secrets in any ops file; rake
      green.

## M5-2 · Publish health line for the tmux bar  [tier: sonnet -- small pure formatter over the existing frozen /tmp/publish.status contract with an exact-value test oracle; two failures bump to opus] [status: done -- sonnet first pass; fable review added ops/ to rake compat] [deps: --]
Goal: `ops/publish_health.rb` -- stdlib one-shot for `status-right`:
      reads /tmp/publish.status (`PUB LIVE 11/11 keys 12:00 UTC`
      contract, untouched) plus the file's mtime and prints ONE short
      line, e.g. `PUB 11/11 0:37` with tmux colour codes: green when
      age < 2x the publish interval, amber < 6x, red beyond or when
      the file is missing/unparseable (prints `PUB ?` -- fail-soft,
      exit 0, never breaks the bar). Interval from MIMIR_PUBLISH_
      INTERVAL_MIN env (default 120, matching D5-a). This output is a NEW
      frozen --tmux contract: exact-value contract tests in the same
      commit; RUNBOOK documents the status-right snippet.
Acceptance: contract tests pin fresh/amber/red/missing/garbled cases
      byte-exactly (injected clock + path); exit 0 in all cases; rake
      green.

## M5-3 · docs/RUNBOOK.md  [tier: opus -- runbook drafting is named at this tier in DEV-LOOP; fable reviews against the runbook-style ruling (numbered do-this steps + EXPECT lines, background quarantined at the end)] [status: done -- opus draft; fable review fixed publish-summary literals, --binding MIMIR, realistic waits -- 03ae48e] [deps: M5-1, M5-2]
Goal: the owner's operations runbook, one numbered procedure per
      section, exact commands + EXPECT lines: install the launchd
      agents on novo (sed paths, cp to ~/Library/LaunchAgents,
      launchctl bootstrap/print, verify first scheduled run in the
      log + on the live dashboard), uninstall/pause, add the tmux
      health line, rotate CLOUDFLARE_API_TOKEN (create new -> swap in
      ~/.config/mimir/env -> verify publish + deploy -> revoke old),
      re-create the KV namespace (new id -> env -> `rake deploy`),
      purge a single key, recover from stale-everything (diagnose
      order: launchd job state -> publish.log -> upstream sources via
      `rake health:sources` -> manual `PUBLISH_DRY_RUN=0` run), code-
      only redeploy (`DEPLOY_SKIP_PUBLISH=1 rake deploy`), and the
      KV free-tier quota math at the D5-a cadence. Background section
      (what runs when, file map) quarantined at the end.
Acceptance: every command copy-pasteable with an EXPECT line; a
      newcomer could operate novo from this doc alone; README gains a
      one-line pointer; no secrets anywhere.

## M5-4 · Gate 5 soak checklist + README refresh  [tier: fable -- gate-defining document, cross-cutting review of the whole phase] [status: done] [deps: M5-1..3, M5-5]
Goal: BACKLOG Gate 5 entry expanded into the concrete soak protocol:
      owner installs agents (RUNBOOK), verifies green for ~48h, then
      the week-long soak continues in parallel with Phase 6 and closes
      at Gate 6 (v1 tag). Daily 1-minute check (dashboard n/11 fresh,
      tmux line green, gex snapshot file present); log every staleness
      incident as date · key · cause · minutes-stale; at Gate 6 review
      KV writes/day vs free tier (expected: 11 keys x 12 runs =
      132/day vs 1000 limit at bi-hourly D5-a) and upstream API quota
      behavior. README updated to the Phase 5 capability set before
      the gate (Workflow rule 5).
Acceptance: checklist is executable as written; README honest about
      what does not work yet (universe.json placeholder caveat
      stays); rake green; phase ends with the Gate 5 handoff summary,
      not an action.

## M5-5 · Daily GEX snapshot writer  [tier: sonnet -- small injectable-runner script following the established BTC::Deploy pattern, deterministic test oracle; two failures bump to opus] [status: ready] [deps: --]
Goal: `ops/gex_snapshot.rb` -- stdlib one-shot with an injectable
      runner (pattern: lib/btc/deploy.rb): runs
      `ruby scripts/gex_btc_combined.rb --json` and
      `ruby scripts/gex_us.rb IBIT MSTR --json` as subprocesses and
      writes ONE dated file
      `BTC::Env.data_dir('gex_history','data/gex_history')/YYYY-MM-DD.json`
      containing `{date, captured_at, btc_combined: <verbatim parsed
      --json>, us: <verbatim>, errors: {...}}`. Date-guard: if today's
      file exists, exit 0 without touching it (idempotent under
      re-runs). Tool failures are recorded per-tool in `errors` and
      never abort the other capture; exit nonzero only if BOTH fail.
      Local-only (data/ is gitignored, never KV, never git). Plus
      `ops/run_gex_snapshot.sh` (same env-wrapper shape as M5-1) and
      `ops/com.mimir.gex-snapshot.plist` (daily StartCalendarInterval).
      Rationale: Deribit/CBOE are now-data -- unbackfillable; U3
      (expiry_low, Phase 9) consumes this archive for its max-put
      strike track.
Acceptance: unit tests with a fake runner pin file shape, date-guard,
      partial-failure and both-fail paths; wrapper/plist pass the M5-1
      health scans; no network in tests; rake green.
Status note: done (sonnet first pass, no deviations; fable review
      clean) -- 78f24d1.

## M5-6 · rake ops:install|status|uninstall -- interactive ops installer  [tier: opus -- owner-run automation wrapping launchctl with programmatic verification, the rake deploy pattern; fable spec + review (secret-adjacent, system-state mutating)] [status: done -- opus vs spec, deviations reviewed; TTY refusal verified live against the loop's own shell -- 95a48a8] [deps: M5-1, M5-2, M5-5]
Goal: owner ruling 2026-07-06 (live from the gold staging install):
      "wrapped in the interactive script instead of loading human with
      tasks humans bad at" -- the RUNBOOK 1-2/4 copy-paste blocks
      (REPO shell state, sed, bootstrap, sleep-then-eyeball) become
      lib/btc/ops.rb + three Rake tasks, owner-run ONLY (refuse under
      CI and when stdin is not a TTY -- which also locks the loop
      out). install: pre-flight table (env file presence/mode/keys
      export-aware, ruby, wrappers, plists via the health scans,
      launchctl present) -> render __REPO__ -> write to
      ~/Library/LaunchAgents -> bootout-if-loaded -> bootstrap ->
      verify state via launchctl print -> per agent an interactive
      "kickstart now? [y/N]" that POLLS the log for the new run marker
      + summary line (no sleeps, no eyeballing), checks
      /tmp/publish.status freshness and the dated snapshot file, and
      prints a PASS/FAIL verification table. status: one command --
      agents' state/last-exit, last log marker + summary each, status
      file line + age, newest snapshot date. uninstall: confirm,
      bootout both, rm installed plists. RUNBOOK sections 1-2/4
      collapse to script invocations + EXPECT; manual commands move to
      the Background section as fallback reference.
Acceptance: BTC::Ops fully injectable (runner/io/clock/home/repo,
      poll sleeper); unit tests cover pre-flight fails, install happy
      path, already-loaded reinstall, kickstart verify success/timeout
      /failure-line, declined prompts, uninstall; CI refusal + TTY
      refusal pinned; no secret ever read or printed (env checks are
      presence-only); rake green; RUNBOOK updated in the same packet.

## M5-7 · rake ops:tmux -- interactive tmux health-line installer  [tier: opus -- extends BTC::Ops in the M5-6 pattern (injectable runner, TTY-gated); fable spec + review] [status: done -- opus vs spec, 8 new tests incl. never-writes-a-file pin -- 2f9149c] [deps: M5-6]
Goal: owner ruling 2026-07-06 (after the manual tmux merge fumble on
      gold: placeholder path left in, free-line guessing, align
      semantics): a script for everything scripts are good at, and it
      NEVER edits ~/.tmux.conf. `rake ops:tmux` (owner-run, CI+TTY
      refusal via the existing Ops.run): 1) pre-checks -- tmux on
      PATH, server running (if not: print the static snippet with the
      REAL repo path and exit), ops/publish_health.rb executes and its
      token is shown; 2) inspect the live server -- `status` count,
      `status-interval`, each status-format[i], and whether our token
      is already present (idempotent: report where, offer nothing);
      3) propose ONE variant fitted to what it found -- dedicated line
      on the first free index (only if one is free at the CURRENT
      status count; never suggest growing the bar unprompted) else
      append `#[align=right]#(ruby <real path>)` to the last occupied
      format (a second align run starts its own right section --
      verified live); 4) prompt "apply live now? [y/N]" -> tmux set -g
      on the running server (reversible, nothing persisted), confirm
      status-interval is set (offer 30 if 0/unset), then EXPECT line;
      5) always finish by printing the exact ~/.tmux.conf line(s) to
      paste for persistence. RUNBOOK section 3 collapses to the task;
      manual variants move to the Background fallback.
Acceptance: BTC::Ops.tmux fully injectable (runner/io/input); tests
      cover no-server, token-already-present idempotence, free-line vs
      merge proposal paths, declined vs applied prompts, interval
      offer; never writes any file (pinned: fake fs untouched); real
      repo path substituted everywhere (no placeholders in output);
      rake green; RUNBOOK updated in the same packet.

## Gate 5 (human) -- concrete checklist (M5-4)  [status: CLOSED 2026-07-06 -- PR #6 merged (1d065b9)]
Owner merged same-day after the gold install proved the chain live
(unattended scheduled publish, snapshot with date-guard, tmux token).
Still open and carried forward: the week-long soak (daily 1-min check),
the KV-quota review, and the novo promotion steps -- reviewed at the
first gate after ~Jul 13.
Staged rollout (owner ruling 2026-07-06): the first install happens on
GOLD as staging, novo gets it only after the 48h-green proof. The KV
namespace is shared -- staging publishes are real publishes (that is
the point: they prove the pipeline against the live dashboard). At
promotion: run the same install on novo, then BOOTOUT the gold agents
(RUNBOOK section 4) so there is exactly one writer (two would double
the 132/day KV write expectation), and copy data/gex_history/ across
once so the snapshot archive has no gap.
Day 0 (install on gold, ~15 min, all commands in docs/RUNBOOK.md):
1. RUNBOOK section 1: env file present + private, keys present
   (names-only check), wrapper smoke test.
2. RUNBOOK section 2: install BOTH agents, kickstart each once,
   verify: log markers, `publish LIVE: 11 written`, dashboard header
   at the current minute, dated gex_history file on disk.
3. RUNBOOK section 3: tmux line added, shows green.
Day 1-2 (green-for-48h = the gate condition):
4. Twice, roughly a day apart: dashboard header `pub HH:MMZ · 11/11
   fresh` with age < 2h, tmux line green, `ls` shows a new snapshot
   file for each calendar day.
5. Any failure: RUNBOOK section 8 (strict diagnose order); log the
   incident as date · key · cause · minutes-stale in a soak note.
Then: merge PR phase-5 -> main. The week-long soak continues in
parallel (daily 1-minute check = step 4 + RUNBOOK section 9 weekly
checks); it closes at Gate 6 with the KV-quota review (expect ~132
writes/day) and the v1 tag.

---

## Phases 6-10 -- skeletons (owner-approved sequence, 2026-07-06)

Full Goal/Acceptance elaboration happens at the preceding gate (loop
rule). Details in ARCHITECTURE.md section 6; concepts in
docs/improvements.md + docs/scenario_upgrades.md.

**Phase 6 -- LPPL history backfill + MSTR GEX panel** (swapped ahead
of ingest, owner ruling 2026-07-06 -- autonomous work first).
Elaborated 2026-07-06 at Gate 5 close; packets below.

## M6-1 · lppl `--as-of DATE` replay mode  [tier: opus vs fable spec] [status: done 2026-07-06, 1d248ec]
Review notes: opus added calendar-rollover hardening (Time.utc rolls
2026-02-30 -> Mar-02; round-trip check aborts) -- approved; replay
still computes would-be trend rows before discarding (harmless,
2.9s/day total, minimal-diff accepted). Smoke: replayed 2026-07-05
matches the recorded ledger entry on all six fields.
Goal: additive replay flag on scripts/lppl/lppl.rb (and passed through
      to every module): compute the suite verdict exactly as it would
      have been computed on DATE, from the price cache alone.
      Current-day semantics byte-identical when the flag is absent
      (characterization first). Mechanics per the survey:
      1) price series truncated IN MEMORY to rows <= DATE (prices.csv
         never rewritten; --skip-update implied by --as-of);
      2) every `Time.now.utc` anchor frozen to DATE midnight UTC --
         lppl.rb ts, report.rb module ts, fit.rb history ts,
         trend.rb 1y-lookback cutoff;
      3) date-evolving state read-filtered, never truncated on disk:
         trend_scores.csv rows with date <= DATE (appends naturally
         bounded by the truncated series), fit_history.jsonl entries
         with ts <= DATE (the stability window sees only what a run
         on DATE could have seen);
      4) `--history` still explicit: replay without it writes nothing.
      NO math/threshold change anywhere -- same estimators, same
      Random.new(42) bootstrap, same sims count (pin it in replay).
Acceptance: characterization pins current no-flag behavior BEFORE the
      change; `--as-of <each of the recorded ledger days> --history`
      into a scratch BTC_DATA_DIR reproduces the recorded entries
      byte-identically modulo ts (ts frozen to DATE-midnight is the
      documented, tested difference); --json/--tmux contracts
      unchanged (additive only: replay mode may add an `as_of` field
      -- contract test in the same commit); rake green.

## M6-2 · staged backfill driver + verification protocol  [tier: fable (wrote driver too -- held all replay semantics)] [status: done 2026-07-06, cf494e2] [deps: M6-1]
Review notes: executed same day -- 273 days (2025-10-06 peak, matching
D7-a exactly -> 2026-07-05) staged clean in ~14 min; stage-B overlap
diff = MATCH on every field for both recorded days (ts excluded as
documented; the 07-05 live duplicate collapses to first entry).
Promotion commands printed by rake lppl:backfill_diff, owner runs them
at Gate 6. Staged history: STRESSED all 273 days, bf -333 -> -426,
ratio 1.11 -> 0.47, fit appears ~day 90 (183 fit-history entries).
Goal: rake `lppl:backfill` -- sequential day-by-day replay from the
      Oct-2025 cycle peak (D7-a) to the day before the live ledger
      starts, writing ledger + fit_history into a STAGING dir via the
      existing BTC_DATA_DIR seam (real files untouched by construction).
      Resumable (skips dates already in the staging ledger), progress
      line per day, runtime estimated up front (~270 days x one offline
      suite run). Verification is two-stage because the fit-history
      stability window evolves with the ledger:
      stage A (exactness): replay each already-recorded day under the
        recorded starting state -> byte-identical (M6-1 acceptance);
      stage B (consistency): full sequential rebuild including the
        recorded days -> field-level diff vs the live ledger on the
        overlap presented to the owner (stability-derived fields MAY
        legitimately differ -- the rebuilt run sees 9 months of fit
        history where the live run saw 0-2 entries; the diff report
        says exactly which fields and why).
      The one-shot promotion of staging -> live ledger/fit_history is
      an OWNER action at Gate 6: task prints the exact copy commands
      incl. timestamped backup of the current files; the loop never
      runs them (Golden Rule 3 discipline applied to data).
      D7-b gate: before the rebuild is blessed, owner confirms whether
      any pre-handoff ledger files exist anywhere -- import beats
      recompute for covered dates.
Acceptance: driver tests with fake runner (sequential order, resume,
      staging isolation pinned -- real data/ paths never opened for
      write); stage-A green; stage-B diff report produced; publish
      tail (lppl:ledger, 365-line tail) verified against the staged
      ledger size in a dry-run; rake green.

## M6-3 · gex:mstr producer + chart spec  [tier: opus] [status: done 2026-07-06, c8c117f]
Review notes: two spec corrections by the implementer, both accepted:
(1) the true key growth is 11 -> 13 (producer AND chart each count;
the owner-approved "12" undercounted -- flagged in the gate summary);
(2) key is gex:mstr / v1:gex:mstr, matching gex:combined's shape (the
skeleton's "gex_mstr:latest" was loose wording). Sibling builder, not
an adapter (gex_us payloads carry NET gamma per strike -- no call/put
split to stack). KV budget moves to 156 writes/day when deployed.
Goal: publish MSTR dealer-gamma alongside the BTC family. gex_us.rb
      already handles MSTR (CBOE single-name chain; the CBOE source is
      already in health SOURCES); NOT mergeable into gex_btc_combined
      -- MSTR gamma lives on MSTR's own price axis (pinned in that
      script's header). Work: PRODUCERS entry
      ['gex:mstr', gex_us.rb MSTR --json, 60, 1_800] (11 -> 12 keys);
      `gex_mstr` chart spec -- single-venue profile on the MSTR price
      axis reusing the gex_profile visual grammar (call/put bars,
      flip/call-wall/put-wall marklines, gex_levels tooltip formatter;
      whether to reuse :gex_profile via payload adapter or a sibling
      builder decided in the spec); payload fixture recorded per the
      documented dry-run procedure + golden; contract updates in the
      same commit: pipeline key-list/count tests 11 -> 12, publish
      health test strings, index growth is additive by construction.
      PUB token expectation moves to 12/12 -- RUNBOOK/soak-note
      mention in the same packet (publish_health derives n/m at run
      time; only test strings pin it).
Acceptance: dry-run publish shows 12/12 with v1:gex_mstr:latest +
      v1:chart:gex_mstr in the index; golden reviewed at real
      geometry; contract tests updated additively; rake green.

## M6-4 · MSTR quadrant presentation  [tier: opus impl, fable design review] [status: done 2026-07-06, 4c96867] [deps: M6-3]
Review notes: fable review fix -- delegated roving tabindex had no
arrow-key handlers (inactive tab keyboard-unreachable); all tab
buttons stay naturally focusable (.sortbtn convention). Implementer
corrected the packet premise: goldens carry the OPTION only (meta
lives in the envelope), so tab meta changes NO golden. Playwright 6/6
at real geometry on both pages; badge ticker compatible with both
badge shapes; SKILL.md hook count 3 -> 4 updated by fable (agent
correctly blocked from the out-of-scope file). Follow-up commit
e95989a: M6-3's fixture+golden were untracked (commit -am stages only
tracked files) -- CI red on the three intermediate commits.
Goal: render chart:gex_mstr per D7-c ruling (Option A): card TABS in
      the GEX quadrant -- new `tab_group` meta hook + tab widget in
      render.js (registry pattern like legend_widget); grouped chart
      keys collapse into one card, [BTC][MSTR] buttons swap the chart;
      2x2 grid preserved; separate liveness dots stay in the header.
      render.js rev bump, unified across index.html +
      preview.html (one design, owner ruling 2026-07-06), mimir-design
      skill governs, DEV-LOOP 6b self-screenshots at REAL card
      geometry + Playwright interaction check (tab switching or card
      presence) before owner handoff.
Acceptance: per ruling; liveHeader dot appears for the new chart key;
      goldens/screenshots reviewed; rake + web:test green.

## M6-5 · README + Gate 6 prep  [tier: fable] [status: todo] [deps: M6-1..4]
Goal: README updated for replay + MSTR capabilities (honest about the
      ledger being backfilled-then-blessed, not organically grown);
      Gate 6 checklist written concretely: stage-B diff review +
      ledger blessing + one-shot promotion commands, MSTR visual
      sign-off, soak-week review (window ends ~Jul 13; if Gate 6 lands
      after, the KV-quota review from the Gate 5 carry-over closes
      here), D7-b answer recorded.
Acceptance: newcomer-readable README; gate checklist is runbook-style
      (numbered steps + EXPECT lines).

## Gate 6 (human) -- checklist  [status: CLOSED 2026-07-06 -- PR #7 merged (5227c75); ledger promoted (275 entries); step 3's rake deploy still pending when convenient]
(M6-5; rewritten per owner feedback: runbook style, promotion wrapped
in an interactive task)
All in ~/Dev/mimir on gold. ~5 min.

1. Promote the backfilled LPPL history (interactive; shows the
   verification diff, asks once, backs up and merges BOTH history
   files):

       rake lppl:promote

   EXPECT: `2026-07-04: match` and `2026-07-05: match` in the diff,
   then the `[y/N]` prompt; after `y`, one line per file ending
   `= N lines (backup ...)` and `promoted.`

2. Look at the tabs:

       rake preview

   Open http://localhost:8000/web/preview.html
   EXPECT: the GEX card shows [BTC] [MSTR] buttons, BTC selected;
   clicking MSTR swaps the chart, the title and the hover help; the
   grid stays 2x2.

3. Merge PR #7 (https://github.com/arvicco/mimir/pull/7), then
   `rake deploy` when convenient.
   EXPECT after deploy: live dashboard shows the tabs and the full
   LPPL history curve.

Background (no action needed): the tmux token reads `PUB 13/13` from
the next scheduled publish (156 KV writes/day, supersedes 132); the
Gate 5 soak-week review moves to Gate 7 if this merges before Jul 13;
`rake lppl:backfill_diff` re-prints the verification diff read-only
any time.

**Phase 7 -- BTCo ingest to real data** (owner-interactive; Gate 7 =
v1 tag). Elaborated 2026-07-06 at Gate 6 close; packets below.
Ground truth from the survey: ingest.rb is complete in design
(discover -> extract [AI w/ heuristic fallback] -> propose ->
review/dismiss -> apply w/ backup + per-ticker audit ledger) but the
flow past the text helpers is UNTESTED and it has never been run
(capstruct/pending/ empty, no state.json). universe.json: all 7
companies placeholder:true; XXI + NAKA carry cik:null so EDGAR
discovery skips them (their real CIKs -- XXI 2070457, NAKA 1946573 --
were verified on EDGAR pre-swap but never written in). ingest.rb
--dry is already exactly the D6-a alert primitive: discovery listing
only, no fetch, no AI, and state.json is NOT persisted under --dry.

## M7-1 · ingest flow characterization  [tier: opus vs fable spec] [status: done 2026-07-06, 8285592+f2b6514+fd6e325]
Review notes: 12 tests, zero production diff from the agent; three
findings, all resolved same phase by fable: A --file pending-dedup
never matched (dash mismatch) -- fixed, pins flipped; B backup-stamp
same-second collision -- fixed with -N uniquify; C the M1-11 contract
sandbox COPIED lib/, silently defeating the fake transport and
hitting the real SEC (Golden Rule 6) -- symlink fix, verified offline
under a broken proxy. Lesson for every future sandbox harness:
symlink lib/, never copy (reopening BTC::Http resets the injected
transport).
Goal: pin the untested 80% of ingest.rb behind tests BEFORE the
      shakedown relies on it: proposal write -> --review -> --apply
      round-trip (universe.json updated in place, placeholder flips
      false, timestamped .bak created, TICKER.jsonl ledger line
      appended, proposal file deleted); --dismiss; --apply-all-high
      (incl. the reload-between-applies behavior); --status; state.json
      round-trip + the seen-cap; dedupe tripod (state seen, ledger
      accessions, --file content hash); --dry persists nothing.
      All against tmpdir copies of universe.json + fake EDGAR transport
      (BTC::Http seam) + a stubbed extraction seam -- if the Claude API
      call is not already injectable, extract it behind a module
      function in a behavior-preserving, characterize-first refactor
      (flag the diff). NO network, NO ANTHROPIC_API_KEY in tests; the
      prompt/schema contract pins (M1-11) stay untouched.
Acceptance: every CLI mode covered by at least one test; real
      capstruct/ and universe.json byte-untouched by the suite
      (the /tmp-clobber lesson); rake green.

## M7-2 · discovery-alert job + status contract  [tier: opus] [status: done 2026-07-06, d343851] [deps: M7-1]
Review notes: fable review catch -- the ops:tmux idempotence check
treated a pre-M7-2 bar (health token, no ingest fragment) as done, so
an already-installed box (gold!) could never receive the upgrade;
added the in-place append variant + test. Token contract: ING n! /
empty-on-quiet / ING ? on broken discovery, always exit 0.
Integration test proves submissions-endpoint-only + no state.json.
Goal: the D6-a scheduled piece. (a) additive `--dry --json` surface on
      ingest.rb: one JSON line {new: n, filings: [{ticker, form, date,
      accession}...]} -- contract test same commit; (b) ops/btco_alert.rb
      reading that surface and writing the status token (form per D8-a
      ruling; proposal: token only when n>0, empty file otherwise so a
      packed bar stays quiet on quiet days); (c) daily launchd plist +
      wrapper following the M5-1 conventions (bash -n / rexml scans
      pick them up automatically -- verify), NO --apply anywhere near
      it (repo-wide scan already bans it in ops/); (d) rake
      ops:install/status/uninstall/tmux extended from two agents to
      three; (e) RUNBOOK section, runbook-style.
Acceptance: alert job provably does no fetch/AI/state-write (test:
      fake transport counts requests -- submissions endpoint only;
      state.json absent after run); ops tasks green on the fake fs
      suite; rake green.

## M7-5 · daily evidence agent + content-recency guard  [tier: opus vs fable spec] [status: done 2026-07-07, f1134eb]
Incident response, owner-ruled: the retired cron's --history duty as
the 4th managed agent (06:45 local) + the PUB! ... OLD token when a
published tail's newest entry exceeds 30h. Verification discipline
rules recorded in CLAUDE.md + DEV-LOOP 6b same day (2c3a348).

## M7-6 · pipeline keep-last-good hardening  [tier: fable] [status: done 2026-07-07, 08c709c]
Incident response: index carries last-good rows for skipped keys
(vanishing-chart bug); junk-chart guard (charts never built from
fail-soft payloads -- the NaN gauge). Both proven on the live surface
during the Deribit outage.

## M7-8 · per-source last-good cache + partial computation  [tier: fable design, opus impl] [status: done 2026-07-07, 4dc617c]
Owner: one dead provider must never blank a card; suites combine
cached-stale + fresh sources, stale sources marked (amber/!). Plan:
(a) lib/btc/source_cache.rb read-through last-good cache over BTC::Http
(48h hard cap proposed); (b) gex family adoption + additive 'sources'
payload member + stale venue marking; (c) btco adoption (stale spot
marks gauge/mNAV, table rows already flag); (d) renderer stale
indicators, both pages, Playwright + 6b checklist. Scenario modules
EXPLICITLY out (score-0 vs stale-reuse = Phase 9 research decision).
Mixing time bases is an owner-ruled semantics change (this ruling).

## M7-9 · third-party sanity refs in --review  [tier: fable] [status: done 2026-07-07, 866eb97+df31a97] [owner request, mid-session]
BTC::TreasuryRef reads the bitcointreasuries.net table (SourceCache
name 'treasury_ref', alias 3350->Metaplanet); --review prints a ref
line per proposal, ⚠ at >2% divergence, silent when the ref is dead
(advisory only). Coinglass evaluated and REJECTED for cause: our tier
has ETF flows only, no per-company treasury endpoint.

## M7-11 · CoinGecko second BTC ref in --review  [tier: fable] [status: done 2026-07-08]
lib/btc/coingecko_ref.rb (keyless snapshot, SourceCache
'coingecko_treasury', symbol-prefix + name-alias lookup); --review
prints BOTH aggregator ref lines (two refs disagreeing is itself a
signal). Soft health entry; fixture recorded. Research basis:
docs/BTCO-DATA-SOURCES.md. Follow-up decision item D8-e: wire the
divergence (ref ahead of model) into the daily btco-alert as a
discovery trigger -- ING token contract change, owner must rule.

## M7-12 · SEC XBRL dei cover-count shares ref  [tier: fable] [status: done 2026-07-08]
lib/btc/sec_shares.rb: companyconcept dei/EntityCommonStockShares
Outstanding -> latest cover-page count WITH as-of date + form; --review
prints a shares ref line when a proposal touches shares_basic (2%
divergence warning). Multi-class filers (MSTR, ASST) are API-invisible
(dimensional facts) -> nil, no line; their counts stay manual until
M7-13. Soft health entry; per-CIK SourceCache. Also fixed: the flow
harness leaked SourceCache writes into the real data/source_cache/
(BTC_DATA_DIR now sandboxed in run_ingest).

## M7-13 · deterministic filing-iXBRL parser  [tier: fable design, opus impl] [status: elaborated 2026-07-08, awaiting owner go]
The research's biggest de-risking win, NOT yet built: parse each
filing's inline-XBRL instance for (a) per-class dei cover counts
(multi-class filers -- closes the M7-12 gap for MSTR/ASST) and (b)
dimensional per-tranche convert facts (us-gaap DebtInstrumentFaceAmount
/ DebtInstrumentConvertibleConversionPrice1 with axis/member contexts)
-- replacing the AI-extraction error class that produced the DJT
conv_price 1000x bug and the double-counted note. stdlib-only XML-ish
parsing of ix: tags; proposals flow through the normal review/apply
pipeline with mode 'xbrl'. Caveat pinned in the research: 8-K-exhibit
-only terms never carry iXBRL -- those stay on the AI path.

## M7-14 · tracker-sourced proposals (3350)  [tier: fable] [status: done 2026-07-08]
ingest --tracker <T>: StrategyTracker's open feed (the engine behind
Metaplanet's official analytics page) -> ONE reviewed proposal from the
latest treasury_table row (btc/btc_as_of/shares_basic only -- diluted
is tracker-computed, debt currency-ambiguous, both omitted per the
schema honesty rule; url = the linked TDnet disclosure PDF). Same
pending/review/apply pipeline + ledger; dedup by row hash; as-of guard
applies. ToS caveat recorded in docs/BTCO-DATA-SOURCES.md.

## M7-15 · per-ticker objective validation (validate.rb)  [tier: fable] [status: core done 2026-07-09; AI research layer = M7-15b todo]
Owner ruling: "NONE of the ratios on file are close to what other
researchers report... we need an objective source of truth; the
universe filling process seems not grounded in reality." Built:
scripts/btco/validate.rb (+validate_core.rb, 13 unit tests) -- per
ticker prints OURS (the served row), EXTERNAL (StrategyTracker's
published mNAV + inputs, bitcointreasuries/coingecko btc counts, SEC
dei cover shares), RECONCILE (our-vs-tracker mNAV decomposed into the
four input factors; dominant factor NAMES the divergent input;
residual ~1 proves definitions agree), NEEDS (plain-words to-dos with
exact commands). First live run: engine + definitions CONFIRMED
against externals (ASST matches exactly; MSTR -6.4% fully explained,
dominant = share count 350.4M Apr cover vs tracker 371.6M Jul-6 --
ATMs outrun quarterly covers); every remaining oddity now has a named
cause. M7-15b (todo): AI research layer -- dossier + web research per
ticker for the fields no structured source covers (cash!, non-BTC
business value, pref/convert terms); expected to formalize the "add
cash to the model" decision.

## D8-f · 3350 price source  [RESOLVED 2026-07-10 -- owner: "3350.T is literally on Yahoo"]
stooq's quote API is dead upstream (F-17); the recomposed 3350 entry
carries no manual_px -> Metaplanet has NO dashboard row despite real
data. Options: (a) manual_px + an owner refresh routine; (b) small
packet: btco.rb prices 3350 from the StrategyTracker feed's USD
stockPrice (source already registered; adds a btco runtime dependency
on a third-party tracker). Owner picks.

## M7-16 · baseline-reset + per-field freshness gate  [tier: fable] [status: applied 6/8 2026-07-10 -- MSTR/XXI/DJT/ASST/BLSH/ABTC grounded; NAKA + 3350 remain] [owner-ruled]
THE PROCESS (owner ruling 2026-07-10, verbatim intent): "We need a
separate regime to establish ground truth on shares/BTC counts AS OF
CURRENT MOMENT, and then run our universe through it. THEN any
ingestion should be tested against LATEST KNOWN GOOD ticker state, to
check if it's adding fresh info OR just trying to apply stale data."
(a) Per-field freshness gate: universe entries gain an additive
    as_of map (field -> date of the latest known-good statement);
    propose-time strips any field whose provenance date does not beat
    the model's (generalizing the btc as-of guard to EVERYTHING);
    apply stamps the dates. Supersedes M7-10's motivation.
(b) Baseline mode (ingest --baseline TICKER): AI + web-search research
    session takes the full dossier (our entry, ledger, all structured
    refs, latest filings) and produces ONE ground-truth-as-of-today
    proposal with per-field value/as_of/source; owner reviews; apply
    REPLACES the entry and stamps every as_of. Pilot: XXI + ABTC (the
    two broken entries), then the whole universe.
Prior failures this answers: XXI 4x-duplicated convert + btc regressed
below aggregate reality; ABTC invisible reverse split; MSTR ATM-delta
share drift. D8-f (3350 price) stays open.

## M7-10 · catch-up composite mode  [tier: fable design] [status: SUPERSEDED by M7-16 2026-07-10]
Walk filings newest->older until every field has been stated once;
emit ONE composite proposal per company with per-field provenance
(filing + date per field). Solves both field completeness on sparse
filers and the current no-per-field-date limitation that forces the
"apply newest last" discipline. NOTE 2026-07-08: scope against the
data-source research findings first -- structured sources (SEC
companyfacts dei counts, CoinGecko treasury list) may shrink what
extraction still has to do.

## M7-3 · CIK enablement + owner shakedown  [tier: fable prep, OWNER sessions] [status: sessions complete 2026-07-08, 9354ceb..dc0c8df -- 6/8 real, residuals below] [deps: M7-1]
RESIDUALS (2026-07-08): XXI + 3350 remain placeholder seeds @2025-06-30
(XXI's count 43,514 matches CoinGecko's current figure, so the seed is
right but unledgered; 3350 is BADLY stale -- CoinGecko shows Metaplanet
at 43,000 vs our 15,555 -- and its TDnet --file path was never run;
3350 also returned "no price, skipped" in the 07-08 smoke). BLSH
placeholder:false but shares_basic null (the 6-K stated no outstanding
count; renders dim -- by design). NAKA shares one filing behind (SEC
companyfacts dei: 696,085,586 @2026-05-11 10-Q vs applied 690,018,254
@10-K) and its pending 10-K btc (5,342 @2025-12-31) is newer than the
model's 5,765 @2025-08-31 -- CoinGecko shows 4,467 today, so a fresher
filing likely exists. MSTR 2029 convert face edit ($3.0B -> $1.5B per
the May-15 8-K) still awaiting owner yes/no. 3 DJT pendings recommended
for dismiss. ops:install DONE 2026-07-08 (owner ran it; all 4 agents
PASS -- suite-history + btco-alert now scheduled; the ING 128! count
is the recomposed universe's old discovery floors, shrinks as newest
filings are analysed/dismissed). Remaining finish line: 3350 tracker
proposal apply (pending, both refs match), XXI ledgering, BLSH
shares, 2029 convert yes/no, ops:tmux (optional ING token).
Goal: (a) write XXI cik 2070457 + NAKA cik 1946573 into universe.json
      -- a deliberate human-approved edit (Golden Rule: universe.json
      changes only via reviewed proposals or deliberate human edit;
      this is plumbing, not fundamentals -- flagged for owner approval
      in the phase plan); (b) owner-session runbook (numbered + EXPECT):
      env presence checks (EDGAR_UA, ANTHROPIC_API_KEY -- names only),
      then per US-listed company: discover latest 10-Q/8-K, review the
      AI proposal, apply or dismiss; 3350 (Metaplanet) via --file with
      an owner-supplied TDnet document; XXI/NAKA via EDGAR once (a)
      lands, --file fallback if their filings predate coverage;
      (c) shakedown continues until no placeholder:true remains
      (extraction schema reports ABSOLUTE numbers -- latest filing per
      company suffices, no backlog replay).
      SESSION RUNBOOK (prepared 2026-07-06, present fresh at session):
      0. owner approves the CIK patch (one word); loop edits + commits.
      1. env presence: grep -cE '^(export +)?(EDGAR_UA|ANTHROPIC_API_KEY)=.'
         ~/.config/mimir/env  -> EXPECT 2.
      2-4. per US company (MSTR SMLR GME DJT XXI NAKA):
         ingest.rb --ticker T --limit 3  -> proposals;
         --review  -> diffs; --apply <acc> or --dismiss <acc>.
      5. Metaplanet 3350 via --file <TDnet doc> --ticker 3350.
      6. --status + grep placeholder count -> EXPECT 0.
      7. rake ops:install (adds the alert agent, idempotent for the
         other two) + rake ops:tmux (offers the ING append).
      8. optional immediate publish, else the bi-hourly agent carries
         the real data to the dashboard within 2 h.
Acceptance: universe.json fully real (7/7 placeholder:false), every
      change carried by a ledger line + backup; next publish shows
      real BTCo data on the dashboard; the session runbook survived
      contact with the owner.

## M7-4 · README + Gate 7 checklist + v1 prep  [tier: fable] [status: done 2026-07-10]
README rewritten: btco section describes the two-regime process
(baseline + gated increments), validate.rb, real 8/8 universe; ops
section reflects the 4 installed agents; not-implemented list refreshed
(3350 price, refetch, cash-model, Phase 8 candidates).

## M7-17 · SBI review triage: C1 KEYRE fix + blast-radius check + CI parity  [tier: fable] [status: done 2026-08-09]
Goal: the SBI consolidated review (2026-07-31, vs phase-6 5227c75)
      confirmed three code bugs; the two that touch phase-7's active
      surface land before Gate 7. C1: KEYRE /x free-spacing killed 6
      of 10 keyword phrases -> excerpts blind to preferred/notes/share
      sections; fixed (\s+ gaps), phrase tests added, contract pin
      updated, outcome-checked on the real MSTR 8-K fixture. Blast
      radius: all at-risk ai-mode applies (07-07..09) superseded by
      the externally-reconciled M7-16 baseline sweep; residual = false
      negatives only, fixed forward. C7: CI gained rake health +
      fixtures:verify (gate parity). C2 -> decision item D8-h.
Deferred to phase-8/9 per .docs/lppl-improvements.md (local notes):
      C4 web hardening, C5 atomic prices.csv, C6 as-of write guard,
      C8 trio; R1-R10 statistics revisions are all Golden-Rule-4
      decision items, none acted on.

## OWNER RULING 2026-08-10 -- BTCo DEVELOPMENT FROZEN
The owner stopped all BTCo (treasury-company) development, pending a
serious rethink: "Treasury dashboard is completely broken/unrepairable,
we stop its development now." Trigger: the 2026-08-10 Gate 7 attempt --
stale rows (XXI/DJT past 120d, MSTR shares a month behind), a
heuristic-mode ingest run that dismissed the BTC-count 8-Ks, and a
wrong CLI hint, on top of the maintenance load the ingest loop demands.
Effect on plans:
- No new BTCo packets. M7-15b (AI research layer), D8-h
  (shares_diluted convention) and D8-e (divergence-alert wiring) are
  FROZEN, not resolved.
- Phase-8 family D proposals (P-14 pref yield, P-15 ledger event
  studies) and any BTCo-card placements in DEV-PROPOSALS.md: FROZEN.
- Code stays in the tree (scripts/btco/, ledgers, tests keep passing);
  nothing is deleted. Decommissioning inventory rules apply if any
  production surface (dashboard card, btco-alert agent, publish keys)
  is later retired -- owner decides that at Gate 7, see the runbook.
- Focus shifts to: Gate 7 (reduced scope) -> Gate 8 (vol/GEX family,
  already built on phase-8) -> Phase 9 (LPPL statistics revision).

## GATE 7 CHECKLIST -- moved to docs/Gate-7-runbook.md (owner ruling
2026-07-11: gate instructions always live in a dedicated
Gate-N-runbook.md, fully specific -- commands, links, EXPECT lines).
Run that file on/after the July 13 soak review.

## Decision items -- Phase 7
- D8-g Blind-zero history rows (filed 2026-07-13 after the overnight
  outage): when EVERY scenario module is fail-soft-unavailable, the
  daily suite-history append still writes composite 0.0/NEUTRAL with
  no marker -- indistinguishable from a real neutral day in the
  published 90d strip. Options: (a) skip the append when all modules
  are unavailable (gap in the series, honest); (b) append with an
  additive `blind: true` field the chart can grey out (contract
  change, additive); (c) leave as-is and rely on the worklog. Owner
  picks; touches append semantics, so loop will not act alone.
- D8-h shares_diluted convention (filed 2026-08-09; SBI review finding
  C2): universe.json / metrics.rb / the extraction prompt never define
  whether shares_diluted is converts-inclusive "assumed diluted" or
  outstanding-plus-ITM-only. metrics.rb takes max(diluted, basic) for
  per-share entitlements, so a converts-inclusive seed double-counts
  ITM convert shares in CEBE and double-penalizes OTM tranches (the
  MSTR seed is suspected converts-inclusive); the prompt says only
  "shares OUTSTANDING". Owner picks the convention; then it gets
  written into the universe schema note, metrics.rb header and the
  extraction prompt in one commit, and existing seeds reconciled.
  Until ruled: no code change (Golden Rule 4).
  FROZEN 2026-08-10 with the BTCo development stop -- moot until the
  rethink.
- D8-a Alert token: **RESOLVED 2026-07-06 -- owner: "fine to place
  near general mimir status info"** -- token joins the mimir status
  cluster (second line right section), written only when n > 0
  (quiet bar on quiet days).
- D8-b EDGAR_UA: **RESOLVED 2026-07-06 -- owner set it** (presence
  verified at session start, never printed).
- D8-c Shakedown scheduling: **RESOLVED 2026-07-06 -- ~8 h out**
  (owner, evening ruling -> session ~2026-07-07 morning). Session
  runbook + the XXI/NAKA CIK edit approval open the session.

Soak close + KV quota review land at whichever gate follows the soak
week; v1 tags at Gate 7 (real BTCo data, per the standing ruling).

**Phase 8 -- Coinglass groundwork + module upgrades** (improvements.md
steps 1-5): lib/btc/coinglass.rb + TTL cache + tier probe; A1 etf_flows
swap; B1 liqmap.rb; A2 cohort; A3/A4 -- all detail-only/parallel-run
behind the research gate; scenario history seeded where sources permit.

**Phase 9 -- scenario v2 hypothesis modules** (scenario_upgrades.md):
U1/U2 first, U4 early, U3/U5/U6 monitors, U7 housekeeping; weight-0
entries with pre-registered kill criteria; weight/threshold changes
batched as research decisions on ledger evidence.

**Phase 10 -- dashboard round 2**: flow_decay_curve, cohort_panel,
expiry_timeline, macro_clock, liq_topology specs + D4-a LPPL price
panel; layout outgrows four quadrants -- full mimir-design pass.

## Decision items -- Phase 5+ planning (owner-ruled 2026-07-06 with the
multi-phase plan approval)
- D5-a Publish cadence: **RESOLVED -- bi-hourly (StartInterval 7200)**.
  Cost basis: 12 runs/day x 11 keys = 132 KV writes/day (13% of free
  tier); upstream APIs hit 12x/day, all sources quota-safe. Chart TTLs
  derive from source ttl_hints -- no spec change.
- D6-a Ingest scheduling: **RESOLVED -- ingestion stays INTERACTIVE**.
  The only scheduled piece is a daily new-filing DISCOVERY ALERT (list
  + count surfaced to the status layer; no fetch, no AI, no state
  mutation, no API spend). Analysis/review/apply happen in owner
  sessions. The alert job is Phase 6 work (built with its status
  contract), NOT an M5-1 deliverable.
- D7-a Backfill window: **RESOLVED -- from the Oct-2025 peak.**
- D7-b Import of pre-handoff ledger files: **RESOLVED 2026-07-06 --
  none usable ("handoff was garbled"); full recompute from the
  Oct-2025 peak is the blessed path.**
- D7-c MSTR GEX quadrant presentation: **RESOLVED 2026-07-06 --
  Option A, card TABS in the GEX quadrant** (new `tab_group` renderer
  hook in render.js, same registry pattern as legend_widget; keeps the
  2x2 grid; both charts stay separate KV keys with separate liveness
  dots; machinery reused when Phase 10 outgrows four quadrants).
  Merged series had been ruled out on axes (MSTR gamma lives on MSTR's
  own price axis). Contract changes for the phase (additive lppl
  `as_of` field, publish key count 11 -> 12) approved same day.
- v1 tag scope: **RESOLVED -- as proposed** (v1 tags at Gate 6: real
  BTCo data live + soak week complete; later phases are v1.x).

## Queue tail (post-v1, owner-ruled order)
- AUTH: Cloudflare Access in front of the Worker host (email OTP; free
  tier; service-token headers for curl/tmux consumers) -- or simply
  set the AUTH_TOKEN secret for API-only consumers. Console/ops work;
  no code change required.
- (D4-a LPPL price-vs-trend panel: no longer queue tail -- scheduled
  into Phase 10 at the 2026-07-06 plan approval.)
