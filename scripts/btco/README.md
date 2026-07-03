# btco -- Bitcoin treasury company analyser

Universe metrics, per-company valuation verdicts, aggregate stress score,
and an intelligent filing-ingestion pipeline that keeps each company's
capital-structure model current. Ruby >= 2.5, stdlib only. Fits the
scenario/lppl suite conventions (--json / --tmux / fail-soft, score in
-1/0/+1).

## Filing ingestion (ingest.rb)

The cap-structure model per company (universe.json) is updated through an
ingest -> propose -> review -> apply pipeline with a full audit trail:

    ruby ingest.rb                   # EDGAR discovery + analysis of NEW
                                     #   filings -> capstruct/pending/
    ruby ingest.rb --review          # pending proposals with field diffs
    ruby ingest.rb --apply <acc>     # apply one to universe.json (backup kept)
    ruby ingest.rb --apply-all-high  # apply all ai/high-confidence proposals
    ruby ingest.rb --dismiss <acc>   # reject
    ruby ingest.rb --file t.txt --ticker 3350   # non-EDGAR docs (TDnet etc.)
    ruby ingest.rb --dry             # discovery only

With ANTHROPIC_API_KEY set, keyword-windowed filing excerpts plus the
company's current model go to the Claude API (BTCO_MODEL, default
claude-sonnet-4-6) under a strict-JSON extraction schema -- the model
reports only what the document states, nulls for everything else, plus a
confidence grade and one-line summary. Without a key it degrades to regex
candidates at confidence=low. Nothing ever mutates universe.json except
an explicit --apply; applied changes append to capstruct/<TICKER>.jsonl
(what changed, from which filing, extracted how, at what confidence), so
the current model is always reconstructible and auditable.

## Design decision worth knowing

Fundamentals (BTC held, share counts, senior claims, convert tranches)
are **human-maintained** in `universe.json` with per-entry as-of dates.
Only prices (Stooq, keyless, US+JP), FX (Stooq) and BTC spot (Deribit)
are fetched live. `--check-filings` queries EDGAR's submissions API for
filings newer than each entry's `btc_as_of` and prints direct URLs, so
updates are deliberate reads of primary documents, not blind scrapes of
aggregator sites. Entries older than 120 days are flagged STALE in every
output; seed data ships with `placeholder: true` and MUST be refreshed
before the numbers mean anything.

## Metrics

- **sats/shD** -- sats per assumed-diluted share
- **CEBE sats/sh** -- Common-Equity BTC Entitlement: sats per diluted
  common after netting senior claims (straight debt + OTM convert face +
  preferred liquidation) against the stack; ITM converts treated as
  equity (shares added at conversion price, face dropped from debt)
- **mNAV** (mcap / BTC NAV), **netNAV** (mcap / (NAV - senior)),
  **EV/BTC** (price paid per coin), **lev** (senior / NAV)

Verdict bands on netNAV: DEEP-DISC <0.90 | UNDER <1.10 | FAIR <1.45 |
RICH <1.90 | OVER.

## Stress score (0-100, BTC-weighted)

45% share of universe below mNAV 1 (accretive-issuance flywheel off) +
35% median-mNAV shortfall below 1.40 + 20% aggregate leverage.
Bands: <25 CALM, <50 ELEVATED, <75 STRESSED, >=75 CRITICAL.
Suite score: +1 (<=30), -1 (>=60), else 0 -- drop-in as an eighth
scenario.rb module (E'-branch tripwire) by adding
['../btco/btco', w] to MODULES, or run standalone.

## Usage

    ruby btco.rb                  # table + stress summary
    ruby btco.rb --check-filings  # EDGAR: what changed since my as-of dates?
    ruby btco.rb --json | --tmux  # suite integration
    export EDGAR_UA='name email'  # SEC asks for identifying UA

## Known limits

Operating-business value ignored (SMLR/GME/DJT read pessimistic-rich);
non-US filings (Metaplanet/TDnet) not covered by --check-filings; FX via
usd<ccy> Stooq pairs (JPY seeded); preferred dividends and interest
coverage not modelled -- stress reads balance-sheet posture, not cash
flow. Convert ITM test uses current price vs conversion price only (no
soft-call / make-whole logic).
