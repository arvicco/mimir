# BTCo data sources -- research findings (2026-07-08)

Owner ruling that triggered this: "BTCo ingest process seems to be
unreliable and prone to errors. I suggest we do deep research to find
out if this very data is available somewhere reliably."

Method: deep-research workflow (5 search angles, 21 sources fetched,
101 claims extracted, 25 adversarially verified 3-vote: 18 confirmed /
7 killed) merged with live endpoint probes run from this box the same
evening. Everything below marked LIVE was reproduced locally; the rest
carries the workflow's citation.

## Verdict

No single free source covers all four needs (BTC count + as-of,
cover-page shares, debt/pref, convert tranches). A three-legged
architecture does, and it shrinks -- not eliminates -- the AI
extraction surface. Per-tranche convertible terms for US filers are
the irreducible remainder: they exist only as dimensional facts in each
filing's inline-XBRL instance (deterministically parseable, no AI
needed) or in exhibit text.

## Source-by-source

### CoinGecko treasuries (BTC counts) -- ADOPT as sanity ref
- LIVE: `GET https://api.coingecko.com/api/v3/companies/public_treasury/bitcoin`
  -- keyless, plain JSON, 175 companies, ALL 8 of our tickers present.
  MSTR 843,775 and DJT 9,542.16 match our owner-verified numbers
  exactly. NO as-of dates on this snapshot endpoint.
- The newer Treasuries API adds per-entity `holding_chart` (timestamped
  series) and `transaction_history` with `source_url` links to the
  underlying 8-K PDFs (filing-level provenance). Demo tier: 365d
  lookback, page-1 history; full depth is paid Analyst+.
- Verified 3-0 against docs + live curls. Timestamps are CoinGecko's
  curated snapshot dates, one layer removed from SEC as-of dates.

### SEC data.sec.gov XBRL JSON (shares, aggregate debt) -- ADOPT
- Free, keyless, declared User-Agent required (403 + ~10min IP block
  without), fair-access 10 req/s, near-real-time after dissemination.
  Automated fetching explicitly sanctioned. (3-0, live-reproduced.)
- `companyconcept/CIK##########/dei/EntityCommonStockSharesOutstanding.json`
  = true point-in-time cover-page counts WITH dates (EDGAR XBRL Guide
  §3.2.3 instant-period spec), exactly the number the schema wants.
  LIVE: DJT 276,953,828 @2026-05-06 matches the owner-applied count;
  NAKA shows 696,085,586 @2026-05-11 (10-Q) -- one filing NEWER than
  what we applied from the 10-K.
- CRITICAL TRAP (3-0, live-reproduced): the aggregation APIs
  (companyfacts/companyconcept/frames) EXCLUDE dimensional facts.
  Multi-class filers tag cover counts per class with
  StatementClassOfStockAxis -> MSTR and ASST are ABSENT from the JSON
  APIs (MSTR's dei section carries only EntityPublicFloat). Per-class
  counts live in the filing's iXBRL and must be parsed from the
  document itself -- structured parsing, not AI.
- Aggregate debt tags (us-gaap LongTermDebt etc.) work via the APIs;
  per-tranche convert facts (DebtInstrumentFaceAmount /
  DebtInstrumentConvertibleConversionPrice1) are dimensional ->
  API-invisible, filing-iXBRL only. Also: 8-Ks usually carry only
  cover-page iXBRL, so debt announced via 8-K may never reach the
  XBRL APIs at all.

### StrategyTracker feed (Metaplanet + MSTR/ASST BTC) -- ADOPT for 3350
- `GET https://data.strategytracker.com/latest.json` -> versioned
  pointer to `all.v<ts>.json` (~17.4 MB) / light (~146 KB), keyless,
  ~15min refresh, stdlib-parseable (JSON.parse needs
  `max_nesting: false`). White-labeled by Metaplanet's OFFICIAL
  analytics page (metaplanet.jp/en/analytics -> analytics.metaplanet.jp),
  which is the reassurance -- but NO published API ToS, third-party
  continuity risk. Covers ~19 companies incl. MSTR, 3350.T, ASST --
  NOT XXI/DJT/NAKA/BLSH/ABTC. (3-0, reproduced end-to-end.)
- For 3350 it satisfies ALL FOUR needs: treasury_table with 146 dated
  rows (latest 2026-06-30: 43,000 BTC, 1,281,283,624 outstanding /
  1,631,543,380 diluted -- diluted is tracker-COMPUTED, not a filing
  number), per-instrument debtInstruments (face, dates, isConvertible,
  disclosureLink; USD 1,538,902,620 total, 0 convertible), and
  preferredStocks (MERCURY Class B: JPY 23,610M, par 1000, 4.9%).
  The linked TDnet PDF independently corroborates 43,000 BTC.
  Do NOT generalize: MSTR's debtInstruments array in the same feed is
  EMPTY, and no conversionPrice field exists anywhere in the schema.

### Japanese primary sources (3350 confirmation channel)
- EDINET API v2 official + live (free Subscription-Key for document
  retrieval). TDnet via webapi.yanoshin.jp: keyless JSON list of
  timely disclosures per securities code -- but hobbyist-run, observed
  504s and ~38s handshakes during verification: fail-soft only, never
  load-bearing.

### Rejected / unevaluated
- Bitbo treasuries API: inquiry-only sales, no self-serve, no free
  tier; the self-serve Pro++ API has MSTR-only holdings. DROP. (3-0)
- bitcointreasuries.net: no API; the table we already scrape (M7-9
  ref) stays a sanity ref; its own methodology page concedes faded
  values are carried forward -- treat as advisory.
- Coinglass: confirmed no per-company treasury on our tier (M7-9).
- Commercial fundamentals APIs (FMP/Finnhub/EODHD/AlphaVantage/NDL):
  produced NO surviving claims -- unevaluated, not rejected. Open
  question whether any offers per-class cover counts as a cheap
  cross-check.

## Recommended architecture (proposed packets)

1. **BTC counts**: keep filings as the PRIMARY (they carry the as-of
   date and the audit trail); wire CoinGecko's keyless snapshot in as
   a SECOND sanity ref beside bitcointreasuries (both via SourceCache)
   and -- more importantly -- as a DIVERGENCE TRIGGER: ref > model by
   >2% means "a filing exists that we haven't ingested" and should
   raise the discovery alert. StrategyTracker as the 3350 ref.
2. **Shares outstanding**: new structured fetch,
   `dei:EntityCommonStockSharesOutstanding` per CIK for single-class
   filers (DJT, NAKA, BLSH-if-tagged, ABTC) -- exact cover counts with
   dates, no AI. Multi-class (MSTR, ASST): parse the latest 10-Q/10-K
   iXBRL for the per-class dimensioned facts -- deterministic parser,
   no AI; until built, cover-page reads stay manual.
3. **Capital structure**: aggregate debt via companyfacts us-gaap tags
   as a cross-check; per-tranche converts from filing iXBRL dimensional
   facts (deterministic) -- this REPLACES the error-class that produced
   the DJT conv_price 1000x bug and the double-counted note. Preferred
   liq/8-K-exhibit-only terms remain text extraction.
4. **3350**: StrategyTracker treasury_table as the data source for a
   reviewed proposal flow (same review/apply discipline), EDINET/TDnet
   PDF as primary confirmation.
5. **Irreducible AI/manual remainder**: 8-K-exhibit-only terms, prospectus
   pref terms, and any filer that tags sloppily. The AI path stays as
   the fallback, now with structured cross-checks around it.

## Immediate data findings (from the probes themselves)

- 3350 Metaplanet: our seed 15,555 @2025-06-30 vs 43,000 @2026-06-30
  (StrategyTracker + TDnet PDF + CoinGecko agree) -- WORST staleness
  in the universe.
- NAKA: CoinGecko shows 4,467 vs our 5,765 @2025-08-31 and the pending
  10-K's 5,342 @2025-12-31 -- they kept selling; a fresher filing
  likely exists. Shares also one filing behind (696,085,586
  @2026-05-11).
- ABTC: CoinGecko 7,500 vs our 8,000 @2026-05-01.
- BLSH: CoinGecko 23,300 / bitcointreasuries 24,300 vs our 24,000 --
  refs disagree with each other; filing check warranted.
- XXI: 43,514 everywhere -- our seed is current, just unledgered.

## Caveats (workflow, verbatim intent)

StrategyTracker ToS unverified (open feed, no contract; official
Metaplanet embedding is reassurance only). yanoshin is a single
-maintainer hobby service. CoinGecko free tier caps history at 365d/
page-1. dei presence validation is Warning-level -- occasional filings
may omit the tag. 8-K-only disclosures never reach the XBRL APIs.
