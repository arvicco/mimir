# TOOL-REVIEW.md -- Phase 0 inventory & review memo (M0-2)

*Reviewed 2026-07-03 (Fable, full read of all 22 files, ~3,000 lines).
Purpose: per-tool maturity assessment and the findings list that seeds
Phase 1's refactor packets. Dispositions: **[fix-P1]** behavior-preserving
refactor packet · **[decision]** owner call required (behavior/semantics
would change) · **[document]** note in README/headers, no code change ·
**[P2]** consideration for the publish pipeline design. Owner marks each
finding AGREED / DEFERRED / REJECTED at the M0-2 review.*

## 1. Inventory & maturity verdicts

| tool | purpose | live sources | contracts | maturity verdict |
|---|---|---|---|---|
| `gex.rb` | Deribit BTC/ETH strike-level GEX, flip, walls | Deribit public API | `--json`, `--tmux` -> `/tmp/gex_<ccy>.status` | **Mature.** Compact, self-contained, math sound. Hard-aborts on fetch error (see F-7). |
| `gex_us.rb` | GEX for US-listed chains (IBIT, MSTR...) | CBOE delayed quotes, Deribit index (BTC annotation) | `--json` (object OR array -- see F-10), `--tmux` per ticker | **Mature.** Same math family as gex.rb; CBOE static-gamma fallback is a nice touch. |
| `gex_btc_combined.rb` | cross-venue BTC GEX on one BTC axis | Deribit + CBOE (9 ETFs) | `--json`, `--tmux` | **Settling.** Newer composition of the two above; venue fail-soft is right; unit handling verified consistent. This is the one the dashboard uses (v1:gex:combined). |
| `scenario/` (7 modules + aggregator) | -1/0/+1 regime composite | farside (scrape), Binance, Deribit, Coinbase, FRED, mempool.space, Coin Metrics, DefiLlama | module JSON contract via `Common.report`; `--json`, `--tmux`, `--history` -> `~/.scenario_history.jsonl` | **Mature.** The house style at its best: uniform fail-soft, subprocess isolation with timeouts, weights documented as tunable-later (research decision). |
| `lppl/` (prices + 5 tests + aggregator) | LPPL falsification suite, verdict + ledger | CryptoCompare (prices only; tests run off the cache) | module contract; `--json`, `--tmux`, `--history`, `--skip-update` | **New but rigorous.** Most math-dense code in the repo (RangeReg, gauss_solve, Filimonov-Sornette fit, Lomb-Scargle + AR(1) bootstrap). Deterministic seed already in place. Needs its data caches built before first real run; characterization (M0-6) is the priority. |
| `btco/btco.rb` | treasury-company universe metrics + stress score | Deribit index, Stooq (px+FX), EDGAR (`--check-filings`) | `--json`, `--tmux`; `--universe` override | **New; numbers not yet trustworthy** -- every universe entry is `placeholder: true` seed data (README says so honestly). One confirmed latent bug (F-1). |
| `btco/ingest.rb` | EDGAR discovery -> AI/heuristic extraction -> proposal -> human apply, with audit ledger | EDGAR submissions/archives, Claude API (optional) | proposal JSON schema (frozen, Golden Rule 5); universe.json only via `--apply` | **Newest, barely exercised.** Design is genuinely good (propose/review/apply split, dedupe vs disposable state + authoritative ledger, content-hash manual ingestion). Needs fixture tests before trusting it in cron (Phase 1 packet already planned). |

## 2. Findings

### Bugs / correctness

- **F-1 · btco.rb convert FX math** `scripts/btco/btco.rb:166` -- universe.json
  convention is face in **USD**, conv_price in **listing ccy**. ITM shares
  should be `face / conv_usd = face * rate / conv_listing`; code computes
  `face / (cp*rate) / rate` = understated by rate^2 for non-USD listings.
  Harmless today (only JPY listing, Metaplanet, has no converts) but wrong
  the day it does. The correct-fix diff is one line. **[decision]** -- it
  changes (future) published numbers; recommend fix + regression test in
  Phase 1 while still provably latent.
  **RESOLVED 2026-07-03: owner approved; extracted to
  scripts/btco/metrics.rb with characterization (f6ed522), fixed with
  red-first JPY regression tests (32c0607). USD outputs byte-identical.**
- **F-2 · fit.rb side effect on every run** `scripts/lppl/fit.rb:172` --
  appends to `data/fit_history.jsonl` unconditionally (not gated by
  `--history` like every other writer). The trough-stability downgrade
  reads the same file, so ad-hoc/multiple daily runs pollute the stability
  signal and can change the score. **[decision]** -- gating it behind
  `--history` changes scoring inputs; alternative is documenting
  "run once daily" as an operational contract. Either way tests must use
  an isolated data dir (BTC_DATA_DIR, Phase 1).
  **RESOLVED 2026-07-03: owner approved; append now gated on --history,
  lppl.rb passes the flag through so the daily cron run still feeds the
  tracker (9bd5c5a).**
- **F-3 · btco.rb mcap uses basic shares** `scripts/btco/btco.rb:176` --
  mNAV/netNAV numerator is `px * shares_basic` while sats/sh and CEBE use
  diluted counts. Plausibly deliberate (mcap is a market observable);
  needs an owner ruling so tests pin the intended definition.
  **[decision -- confirm semantics, likely no change]**
  **RESOLVED 2026-07-03: confirmed deliberate (mcap = market observable);
  documented in the btco.rb header, no code change. M0-7 tests pin it.**

### Robustness / conventions

- **F-4 · gex family aborts; suite modules fail soft** -- gex.rb /
  gex_us.rb / combined `abort` on fetch failure (combined is per-venue
  fail-soft but aborts if the Deribit index call dies). The suite
  convention (report score 0, exit 0) doesn't apply to them today because
  nothing aggregates them -- but Phase 2's publisher will. Options: align
  them to fail-soft JSON, or have the publisher treat nonzero exit as
  keep-stale. **[P2 -- design input, no change now]**
  **RESOLVED 2026-07-03: failure mode documented in all three gex headers
  ("nonzero exit = keep-last-good"); code-level fail-soft stays open for
  Phase 2 publisher design -- the gex --json contract has no score field,
  so inventing a failure shape now would front-run that design.**
- **F-5 · btco.rb also aborts** (universe missing, Deribit index, no
  companies priced) while its own README claims it "fits the suite
  conventions (fail-soft)". Claim and code disagree. **[decision]** --
  either make it fail-soft (score-0 JSON matches the module contract) or
  fix the README. Recommend fail-soft: it is listed as a potential 8th
  scenario module.
  **RESOLVED 2026-07-03: owner approved fail-soft; all four aborts now
  report score 0 / exit 0 in the module contract shape, verified offline
  in both output modes (7490b65).**
- **F-6 · secret in URL** `scripts/scenario/macro.rb:23` -- FRED_API_KEY
  is query-string-interpolated; today's error paths don't echo URLs, but
  one careless edit would. Phase 1 http seam should redact query strings
  in all error messages by construction. **[fix-P1 -- fold into M1-1]**
  **RESOLVED 2026-07-03: BTC::Env.redact (credential query params by
  pattern + literal SECRET_ENV values) applied to every headline and
  string detail inside BTC::Report -- redaction by construction at the
  single output funnel (d225614).**
- **F-7 · US option expiry fixed at 21:00 UTC** (gex_us, combined) -- 4pm
  ET is 20:00 UTC in DST; up to 1h of T error, negligible at daily
  horizons. Deribit's 08:00 is exact. **[document]**
  **RESOLVED 2026-07-03: documented in the gex_us.rb header and in
  BTC::Options.parse_osi's doc (which now owns the 21:00 constant for
  both consumers).**
- **F-8 · artifact locations inconsistent** -- scenario history in
  `~/.scenario_history.jsonl` (HOME), lppl ledger + caches in-tree
  `data/`, all status lines in `/tmp`. BTC_DATA_DIR (Phase 1, planned)
  unifies; scenario's HOME path needs a migration decision then.
  **[fix-P1, flag path change at gate]**
  **RESOLVED 2026-07-03: owner approved; lib/btc/env.rb resolves
  $BTC_DATA_DIR/<suite>/ with in-tree defaults, lppl.rb's ledger no
  longer bypasses the shared dir, scenario history moved to
  scenario/data/history.jsonl with verified one-time auto-migration
  from ~/.scenario_history.jsonl. Deliberate exceptions documented:
  /tmp status lines, btco capstruct/ audit trail (38d4e7a).**
- **F-9 · aggregators parse `lines.last`** (scenario.rb:53, lppl.rb:48) --
  any stray stdout from a module breaks its JSON parse (caught -> score 0,
  so it degrades, not crashes). Contract tests will pin module stdout
  discipline. **[document; contract tests cover]**
  **RESOLVED 2026-07-03: stdout discipline documented in both
  aggregator headers (exactly one JSON line per module in --json mode);
  test pinning remains with M1-7..11.**

### Contract quirks (pin in tests, do not change)

- **F-10 · gex_us.rb --json shape varies**: single ticker -> object,
  multiple -> array (gex_us.rb:203). Frozen contract; pin both shapes.
  **RESOLVED 2026-07-03: called out explicitly in the gex_us.rb usage
  header; test pinning at M1 contract tests.**
- **F-11 · module `name` fields differ from filenames**: funding_basis.rb
  reports `funding`, onchain_value.rb reports `onchain`. Aggregator keys
  by filename, so only standalone `--json` consumers see it. Frozen; pin.
  **RESOLVED 2026-07-03: noted in both module headers as frozen;
  test pinning at M1 contract tests.**
- **F-12 · fail-soft exits 0 with score 0** everywhere in scenario/lppl --
  the publisher must distinguish "healthy 0" from "unavailable 0" via the
  headline text only. **[P2 -- envelope design should carry a status]**
  **RESOLVED 2026-07-03: fail_soft's JSON now carries an additive
  'unavailable': true marker (single change in BTC::Report; human and
  --tmux output untouched). Phase 2's envelope reads the field instead
  of parsing headlines; M1 contract tests pin it (d225614).**

### Duplication (Phase 1 extraction candidates)

- **F-13 · five near-identical HTTP helpers** (gex.rb, gex_us/combined,
  scenario/common, lppl/common, btco x2 incl. ingest's POST-capable one)
  with drifting timeouts (read 20/30/60/120s) and UA strings. This IS the
  planned `lib/btc/http.rb` seam (M1-1). Ingest's POST + long timeout is
  the superset case; design for it.
  **RESOLVED 2026-07-03: owner pulled M1-1's seam forward. BTC::Http
  (get/get_json/post, injectable transport, StatusError with code+body
  but the historical 'HTTP <n>' message) + fake-transport tests; all
  six call sites are thin wrappers preserving UA/timeout/error shape;
  net/http gone from scripts/. Remaining M1-1 scope at Phase 1: fixture
  recording (rake fixtures:record) and per-suite contract tests
  (6435e7a, b416b82).**
- **F-14 · BS gamma + norm_pdf x3, MONTHS x3, OSI regex x2, arg() x5,
  flip-scan/wall block x3** across the gex family (+ scenario/common's
  MONTHS). A `lib/btc/` math+parse module would cut ~150 duplicated lines.
  Tension with the "scripts are standalone" design: extraction couples
  them to lib/. Recommend extracting math/parsing (pure, test-heavy,
  drift-dangerous: three copies of bs_gamma can silently diverge) and
  leaving presentation duplication alone. **[decision -- scope of
  extraction: http-only vs http+math/parse]**
  **RESOLVED 2026-07-03: owner approved math/parse extraction.
  lib/btc/options.rb (bs_gamma/gamma_at, Deribit+OSI parsing,
  gamma_flip, walls) + lib/btc/util.rb (arg), pinned by exact-value
  tests before adoption; gex family -133/+43 lines (9b22457, 1bdfef1).
  Presentation duplication (fmt lambdas, table rendering) left alone as
  recommended. HTTP stays with M1-1.**
- **F-15 · scenario/common.rb and lppl/common.rb share report/fail_soft**
  almost verbatim (width 14 vs 12 in one format string). Fold into the
  same lib decision as F-14.
  **RESOLVED 2026-07-03: lib/btc/report.rb with per-suite widths as
  parameters, output pinned byte-for-byte by tests; both Commons and
  btco's fail_soft delegate. Verified offline in all three suites,
  both output modes (d82b845).**

## 3. What was checked and found sound

- Combined-GEX unit handling: per-instrument dollar gamma per 1% on each
  underlying's own axis, BTC-equivalent strikes via live ratio, OI
  BTC-normalized for cross-venue P/C -- reconciles with per-venue tools.
- RangeReg prefix-sum algebra incl. SSE identity; gauss_solve partial
  pivoting; trend.rb's prequential cache append logic (header/dedupe
  correct); envelope walk-back persistence counters; percentile
  half-normal envelope; Lomb-Scargle + seeded AR(1) bootstrap.
- ingest.rb state model: state.json genuinely disposable (ledger is
  authoritative), failed analyses retry, manual ingestion deduped by
  content hash, apply is backup-then-mutate with ledger append.
- Secrets: no key is ever printed; ENV-only access throughout (F-6 is a
  hardening note, not a leak).

## 4. Proposed Phase 1 refactor list (seeds M1-13..n; owner to approve)

1. F-1 convert-FX one-line fix + regression test (while provably latent).
2. F-5 btco.rb fail-soft alignment (score-0 JSON on data-source failure).
3. F-2 fit.rb history-write gating (with owner's chosen semantics).
4. F-13 http seam with query-string redaction (= M1-1, already planned).
5. F-14/F-15 extract shared math/parse/report into lib/btc/ -- scope per
   owner decision at the F-14 line.
6. F-8 BTC_DATA_DIR everywhere (= M1-12, already planned) + scenario
   history path migration.

Everything else: [document] items fold into M0-3 README + header updates;
[P2] items are recorded as publish-pipeline design inputs in Phase 2's
packet elaboration.

## 5. Round 2 (2026-07-03): DRY + naming-consistency review

*Second Fable pass over the post-refactor tree, requested by owner.
R-numbered; same dispositions as section 2. "Frozen" = --json/--tmux
contract involved, extra care.*

### DRY -- recommended

- **R-1 · Deribit venue helper.** The index-price fetch appears FIVE
  times (gex.rb, gex_us.rb, combined, funding_basis.rb, btco.rb), the
  book-summary fetch + `.fetch('result')` unwrap three times, and the
  base URL twice as a const (`HOST`, `DERIBIT`) plus three times inline.
  Extract `lib/btc/deribit.rb`: `BTC::Deribit.index_price(ccy)`,
  `.book_summary(ccy, kind:)` over the http seam. Also dissolves R-8.
- **R-2 · Sign convention.** `o[:cp] == 'C' ? 1.0 : -1.0` is spelled out
  six times across the gex family -- and it is THE semantics-critical
  constant (dealer-positioning model). One definition:
  `BTC::Options.sign(cp)`. Zero behavior change, kills silent-drift risk.
- **R-4 · Aggregator subprocess runner.** scenario.rb (inline) and
  lppl.rb (`run_module`) duplicate the Timeout + IO.popen +
  parse-last-stdout-line + degrade-to-score-0 pattern near-verbatim.
  Extract `BTC::Suite.run_module(dir, name, timeout, extra: [])`; each
  aggregator keeps its own result-wrapping and weighting.
- **R-5 · Status-line writer.** `File.write('/tmp/<x>.status', line + "\n")`
  x6. `BTC::Report.status(basename, line)` centralizes the /tmp
  convention (frozen paths preserved byte-for-byte).

### DRY -- optional (smaller wins, owner's call)

- **R-3 · Put/call OI ratio block** x5 (two weightings: raw OI in
  gex/gex_us, BTC-equivalent OI x3 in combined). Extractable as
  `Options.put_call_ratio(book) { |o| weight }`; modest gain.
- **R-6 · ASCII profile bars** x3, identical except the strike-label
  format. Human output only; extract with a label lambda or leave.
- **R-7 · `fmt_m` lambda** identical x3 -> `BTC::Options.fmt_musd` or a
  tiny format helper. NOTE: `fmt_k` variants must NOT be unified -- they
  differ per tool ('103.5k' vs '%gk') and feed --tmux lines (frozen).

### Naming -- recommended

- **R-8 · `get_json` means two different things**: gex.rb's unwraps
  Deribit's result envelope; gex_us/combined/suites return the raw
  parse. Same name, different semantics, adjacent files. Dissolved by
  R-1 (venue helper owns the unwrap; remaining get_json = raw parse
  everywhere).
- **R-9 · `module Common` is defined twice** (scenario/common.rb,
  lppl/common.rb) with different methods INCLUDING two different
  `get_json` implementations. Separate processes today, but any future
  same-process load (tests are one process; a scenario test alongside
  test_lppl_common.rb) silently merges them -- last-loaded get_json
  wins. Rename to `module Scenario` / `module Lppl` (suite-local sed;
  no frozen contract touched).
- **R-10 · Namespace rule.** `BtcoMetrics` (top-level) breaks the
  pattern set by `BTC::*`. Adopt: **suite-local shared code = module
  named after the suite (`Scenario`, `Lppl`, `Btco`); cross-suite code =
  `BTC::*`.** metrics.rb becomes `module Btco` (with R-9 this makes the
  three suites uniform).

### Flag only -- do not touch

- **R-11 · Wall key naming differs in frozen JSON**: gex.rb walls carry
  `strike:`, combined's carry `level:` -- deliberate (real strikes vs
  BTC-axis buckets). Document in M1 contract tests, never rename.
- **R-12 · Net-GEX formula divergence (ANALYTICS decision item)**:
  gex.rb's `net_gex` multiplies by `x*x` (hypothetical index level);
  combined's `gex_at` uses `s*s` (the instrument's scaled underlying).
  For Deribit u ~= index so the numbers nearly agree, but not exactly --
  the two tools will not reconcile to the digit for the same venue.
  Unifying changes published numbers; owner must rule which is intended
  (Golden Rule 4). Until then the near-duplicates stay separate.
- **R-13 · funding/onchain file-vs-name mismatch** (= F-11): renaming
  the files would change the `scores` keys in history.jsonl (breaks
  accumulated history) -- leave documented as is.
