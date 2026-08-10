# Dev proposals -- consolidated capability menu (2026-07-08)

Supersedes docs/ROADMAP-CANDIDATES.md (same-day planning round, folded
in here with the Coinglass survey the owner requested). Companion to
docs/BTCO-DATA-SOURCES.md (ingest data-source research, already partly
adopted as M7-11/12/14).

Ground rules for everything below: new signals, scores, weights and
score-contributions are research decisions (Golden Rule 4) -- each
proposal ships only as an owner-approved packet; every new fetch goes
through BTC::Http + BTC::SourceCache with a fixture, a health-registry
entry and fail-soft behavior; every new card follows the mimir-design
skill and the DEV-LOOP 6b surface checklist; renderer/chart-spec
contracts stay additive.

PROBED = verified live from gold with our provisioned key/no key on
2026-07-08. Our Coinglass tier turned out far richer than the M7-9
note assumed ("ETF flows only" is wrong for the CURRENT tier): 13
useful endpoint families answered `code:0` tonight.

## What the probes established

Coinglass v4, our key (all PROBED, daily interval, JSON):
- futures/open-interest/aggregated-history (OI OHLC)
- futures/funding-rate/oi-weight-history (OI-weighted funding)
- futures/liquidation/aggregated-history (needs exchange_list param)
- futures/global-long-short-account-ratio/history + top-long-short
  -position-ratio/history (Binance et al.)
- futures/taker-buy-sell-volume/history
- option/info (per-exchange options OI/volume), option/max-pain
  (per-expiry, Deribit)
- index/fear-greed-history, coinbase-premium-index,
  index/puell-multiple (5.8k rows), index/bitcoin/bubble-index (5.8k
  rows back to ~2010), etf/bitcoin/aum
Free, keyless (PROBED earlier tonight): CFTC COT Socrata JSON (weekly
TFF positioning, Bitcoin contracts), Kalshi public API (daily BTC
strike markets = implied probability ladder), CoinGecko treasuries.
Rate limits: hobbyist-tier per-minute caps are not published in the
.md exports -- to be confirmed before any bi-hourly adoption; daily
cadence is safely inside any published tier.

---

## A. GEX / volatility family (mostly data we already fetch)

**P-1 · Vol surface & skew card.** The bi-hourly Deribit book fetch
carries mark IV for every strike; we compute GEX and discard the vol
info. Compute 25-delta risk reversal, butterfly, ATM IV by tenor;
snapshot daily (gex_history pattern) so IV rank/percentiles emerge
after a few weeks. GEX says how dealers are positioned; skew says what
the market pays for tails -- the two together are a positioning-vs
-fear regime read. New producer + one card (or a tab on the GEX card,
D7-c machinery). No new sources. Effort: M. Decision: metric
definitions + card layout.

**P-2 · MSTR-vs-BTC implied-vol spread.** We already fetch BOTH chains
(CBOE MSTR, Deribit BTC). The IV spread is the market's live price of
treasury-company leverage -- nobody publishes this; it is the natural
derivative of the BTCo thesis and reuses P-1's IV extraction. Strip on
the BTCo card or the vol card. Effort: S (after P-1). Decision: tenor
matching rule (nearest-expiry pairing).

**P-3 · Futures basis & funding composite.** Deribit futures book
(fetched, unused) gives annualized basis per tenor; Coinglass
OI-weighted funding (PROBED) gives the cleaner funding series we
currently approximate with single-exchange Binance. Contango steepness
= leverage appetite; basis collapse/backwardation = stress. Small
scenario-family module + a sparkline strip. Effort: S-M. Decision:
whether it joins the scenario score or stays display-only.

**P-4 · GEX history analytics.** data/gex_history/ accumulates daily
snapshots NOTHING reads. Flip-point distance time series, CW/PW wall
migration, gamma-regime persistence/transition stats. Feeds the P-17
state machine and makes the GEX card's story time-aware. Pure local
computation. Effort: S-M. Decision: which derived series get published.

**P-5 · Options positioning cross-check.** Coinglass option/info +
max-pain (PROBED) vs our own computed walls: does Deribit max pain
agree with our CW/PW? Divergence = either our math or crowd
positioning shifted -- an outcome-first check on the GEX suite itself,
same philosophy as the ingest ref lines. Line on the GEX card + a
health-style test. Effort: S. Decision: divergence threshold.

## B. Scenario family (new modules; score membership = owner ruling)

**P-6 · Derivatives-positioning module.** OI history + long/short
account & top-position ratios + taker buy/sell + liquidation history
(all PROBED, one source, daily): a crowd-positioning score
complementing the existing funding module. Extreme long-crowding +
rising OI + heavy long liquidations is the classic flush setup; the
data was previously assumed unavailable on our tier. Effort: M.
Decision: sub-signal definitions, band thresholds, score weight (or
display-only first).

**P-7 · COT institutional module.** CFTC Socrata JSON (PROBED, free,
weekly): leveraged-fund and asset-manager net positioning in CME BTC
futures -- the slow-money leg no current module covers. Weekly cadence
fits the daily agents; tiny fetch. Care: select the CME contract
specifically (the probe's first rows were Coinbase perp entries).
Effort: S-M. Decision: net-positioning normalization (vs OI, vs its
own history) + score membership.

**P-8 · Exchange-reserve module.** Coinglass exchange/balance/list
(PROBED, 21 exchanges): BTC sitting on exchanges -- the classic
supply-overhang / self-custody drain gauge, our first true on-chain
flow signal beyond Coin Metrics ratios. Effort: S-M. Decision: level
-vs-delta framing, score membership.

**P-9 · Coinbase premium gauge.** coinbase-premium-index (PROBED): the
US-institutional-bid proxy; pairs naturally with the ETF-flow module
(flows say what happened yesterday; premium says who is bidding now).
Strip/sparkline, probably display-first. Effort: S.

**P-10 · Cycle-context strip.** Puell multiple + Fear&Greed history
(both PROBED; F&G here replaces the flaky alternative.me idea from the
earlier round). Explicitly DISPLAY-ONLY context, not score inputs,
unless the owner rules otherwise later -- they answer "where in the
cycle are we" while scenario answers "what is stretched this week".
Effort: S. Decision: card placement (candidates for a compact
"context" row).

**P-11 · Macro block extensions.** FRED (key provisioned) also serves
the trade-weighted dollar (DTWEXBGS), 2s10s, HY OAS. A rates/credit
leg for the macro module without any new source or key. Effort: S.
Decision: series choice + score membership.

## C. LPPL family

**P-12 · Independent bubble-gauge cross-reference.** Coinglass
bitcoin/bubble-index (PROBED, history to ~2010): an outside bubble
indicator to sit beside the LPPL verdict -- same evidence-ledger
philosophy as the ingest ref lines ("what does an independent
instrument say about the thing we compute"). Backfillable against our
2025-10..now ledger immediately; a divergence row in the LPPL card.
NOT an input to LPPL -- a check on it. Effort: S-M. Decision: none on
semantics (advisory), card placement only.

**P-13 · Market-implied probability ladder (Kalshi).** PROBED: daily
BTC strike markets give a live implied distribution P(BTC above/below
X). Two uses: (a) a dashboard strip ("crowd prices the -10% tail at
7c this week"); (b) the independent calibration reference for our own
probability-flavored outputs -- when LPPL says STRESSED and the crowd
prices the tail at pennies, that disagreement is exactly the
interesting number. Effort: M (market discovery/rolling tickers need
care). Decision: which tenors/strikes, panel design. ToS posture to
confirm before adoption (public API, no key for reads).

## D. BTCo family — FROZEN (owner ruling 2026-08-10)

All BTCo development is stopped pending a rethink; nothing below is
buildable until the owner reopens it. Kept for the record.

**P-14 · MSTR preferred yield strip.** STRC/STRK/STRF trade on Nasdaq;
stooq (already our equity price source) serves them. Preferred yields
are the market-implied credit stress of the Saylor complex -- the
fixed-income complement to mNAV, and an early-warning line the equity
mNAV can lag. Row/sparkline on the BTCo card. Effort: S-M (dividend
terms are static constants per instrument -- deliberate universe-style
edits). Decision: which instruments, yield convention.

**P-15 · Ledger event studies + mNAV memory.** capstruct/*.jsonl now
accumulates dated purchase/issuance events; the btco payload computes
a cross-sectional mNAV distribution that is never historicized.
Snapshot the cross-section daily (gex_history pattern) and build the
event-study harness (returns around purchase announcements; mNAV
compression episodes). Turns the ingest work into research capital
that compounds. Effort: M. Decision: which derived stats publish.

**Already queued, unchanged:** M7-13 deterministic filing-iXBRL parser
(per-class covers + convert tranches -- kills the DJT-bug error
class); M7-10 catch-up composite mode; D8-e ref-divergence alert
wiring; 3350 price source fix; refetch bundle (owner go pending).

## E. Synthesis & product

**P-16 · Composite regime state machine.** LPPL regime x scenario band
x gamma sign (x P-6 positioning once it exists) collapses to a small
discrete state space. The daily STATE is a card; the TRANSITIONS are
the alert events for P-17. Rule-based, exhaustively testable, no AI.
Effort: M. Decision: the state definitions ARE analytics semantics --
owner workshop required.

**P-17 · ntfy.sh push alerts.** Free topic push, plain HTTPS POST,
stdlib: regime transitions (P-16), gamma-flip crossings, discovery
alerts (today's ING token, pushed), ref-vs-model divergence (D8-e),
publish-health OLD flag. The dashboard is pull; the owner should not
need to look to learn something changed. One tiny lib + hooks in
existing agents; topic name is effectively a secret (ENV). Effort: S.
Decision: alert taxonomy + noise budget (what NEVER pushes).

**P-18 · Daily AI morning brief.** brief:latest key written by a
06:50 agent (Anthropic key already integrated in ingest): ten lines --
what changed overnight, what is stretched, what to watch, from the
payloads + histories. Ships behind a flag as owner-reviewed drafts
first; taste-sensitive. Effort: M. Decision: voice/format, whether it
earns a card.

**P-19 · Signal scorecard / self-calibration.** The strategic road:
score every published signal against realized forward BTC returns
(7/30/90d) from our own accumulating ledgers (LPPL back to 2025-10,
scenario history, GEX snapshots, publish archive) and PUBLISH the
track record. Outcome-first verification applied to the analytics
themselves; mimir's honesty becomes a feature. Starts paying after
months -- which is the argument for starting the accumulation hooks
NOW (P-1/P-4/P-15 snapshots all feed it). Effort: M-L, phased.
Decision: scoring definitions, presentation of "this signal has no
edge" results.

**P-20 · Scenario replay & backtest harness.** lppl --as-of already
replays; FRED/Coin Metrics/Coinglass histories (PROBED depths: puell
5.8k rows, bubble 5.8k, ETF AUM 906) make most scenario modules
replayable too. Every future Golden Rule 4 threshold/weight proposal
then arrives WITH a backtest. Effort: M-L. Decision: per-module
replay fidelity rules (which sources genuinely serve point-in-time
history vs revised series -- revision bias must be documented per
module).

**P-21 · "What changed" diff panel.** Retain N days of payload
history in KV (or reuse the local publish archive) and render a small
"since yesterday" diff: verdict changes, flip moves, new filings,
stale transitions. Cheap once P-4/P-15 snapshots exist. Effort: S-M.

---

## Recommended picks (loop opinion, unchanged in spirit from the
## earlier round, sharpened by the probes)

Wave 1 (highest signal per effort, zero-to-low source risk):
P-1 vol surface, P-3 basis+funding, P-4 GEX history, P-5 max-pain
cross-check -- the "use what we already fetch" wave, plus the
snapshot hooks that P-19 will need.

Wave 2 (new-source, all probed): P-6 derivatives positioning, P-7
COT, P-8 exchange reserves, P-12 bubble-index cross-ref, P-13 Kalshi
ladder.

Wave 3 (product): P-17 ntfy (anytime, small), P-16 state machine
after Wave 1-2 data exists, P-19/P-20 as the standing research road.

Sequencing note: nothing in Wave 1-2 changes existing scores --
everything can land display-only/advisory first and graduate into the
scenario score by explicit later ruling, which keeps Golden Rule 4
clean and lets the scorecard (P-19) referee what earns score
membership.
