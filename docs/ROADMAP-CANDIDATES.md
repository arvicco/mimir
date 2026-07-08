# Roadmap candidates -- planning round 2026-07-08

Owner ask: "Think creatively about capabilities we are missing that
could make the project much more useful. Non-traditional sources?
Approaches? Methods? Any breakthroughs we didn't think of before?"

Everything here is a CANDIDATE: new signals and scoring rules are
research decisions (Golden Rule 4) and land only as owner-approved
packets. Endpoint claims marked PROBED were verified live tonight.

## Theme 1 -- we already own the data; we use a fraction of it

The cheapest capability class in the repo: new math over fetches and
archives we ALREADY make, zero new source risk.

1. **Vol surface & skew suite.** The bi-hourly Deribit options book
   fetch contains every mark IV. We compute GEX from it and throw the
   rest away. Derivable: 25-delta risk reversal (the price of fear),
   butterfly, ATM term structure, and -- once historicized like
   gex_history -- IV rank/percentiles. GEX says how dealers are
   positioned; skew says what the market pays for tails. Together they
   are a regime read neither gives alone.
2. **MSTR-vs-BTC implied vol spread.** We fetch BOTH chains (CBOE MSTR
   + Deribit BTC). The IV spread is the market's live price of
   treasury-company leverage -- a number nobody publishes and the
   natural derivative of the BTCo thesis. Cross-suite, zero new
   fetches.
3. **Futures basis curve.** The Deribit futures book (already fetched
   for gex) gives annualized basis per tenor: contango steepness =
   leverage appetite; backwardation = stress. One small module in the
   scenario family.
4. **GEX history analytics.** data/gex_history/ accumulates a daily
   snapshot that NOTHING reads. Derivable: flip-point distance time
   series, wall migration, gamma-regime persistence and transition
   frequencies. The archive was built for exactly this and is sitting
   idle.
5. **BTCo ledgers as an event database.** capstruct/*.jsonl now records
   dated purchase/issuance events per company. Event studies (what
   happens to MSTR and BTC after purchase announcements), plus
   historicizing the cross-sectional mNAV distribution = a sector
   -stress index with memory. Grows more valuable every week the
   ingest runs.
6. **MSTR preferred yield strip.** STRC/STRK/STRF trade on Nasdaq;
   stooq (already our equity source) serves them. Their yields are the
   market-implied credit stress of the Saylor complex -- the fixed
   -income complement to mNAV. A btco sub-panel.

## Theme 2 -- non-traditional free sources (probed)

7. **CFTC Commitment of Traders** -- PROBED: the Socrata JSON API
   (publicreporting.cftc.gov/resource/gpe5-46if.json) serves weekly
   Traders-in-Financial-Futures rows for Bitcoin contracts keyless:
   dealer / asset-manager / leveraged-fund long-short. The
   institutional-positioning leg scenario lacks entirely. Weekly
   cadence, tiny, stdlib-trivial. (Care: select the CME contract, not
   the Coinbase perp rows the probe surfaced first.)
8. **Prediction-market implied probabilities** -- PROBED: Kalshi's
   public API serves daily/weekly BTC strike markets (KXBTCD series)
   with live prices = a market-implied probability distribution over
   BTC levels. Two uses: (a) a strip on the dashboard; (b) an
   INDEPENDENT calibration reference for our own probability-flavored
   outputs (LPPL regime, stress bands) -- "what does the crowd pay for
   the tail we flag". Polymarket's gamma API also works but needs
   messier event filtering. This is the most genuinely non-traditional
   source in the round.
9. **Sentiment tickers** (alternative.me Fear&Greed): probe came back
   empty tonight; cheap to retry but low information -- optional, last.
10. **Macro block extensions, no new source**: FRED (key already
    provisioned) also serves the trade-weighted dollar (DTWEXBGS),
    2s10s, HY OAS -- candidates for the scenario macro module if the
    owner wants a rates/credit leg.

## Theme 3 -- from dashboard to research instrument (the big road)

11. **Signal scorecard / self-calibration.** We now accumulate our own
    verdict history (LPPL ledger back to 2025-10, scenario history,
    GEX snapshots, publish archives). Build the harness that scores
    every signal against realized forward BTC returns (7/30/90d
    horizons, hit rates, calibration curves) and PUBLISHES the track
    record as a panel. Outcome-first verification applied to the
    analytics themselves: mimir tells us which of its signals actually
    carry information, and its honesty becomes a feature. Compounds
    with data age; starting it early is what makes it valuable later.
12. **Scenario/LPPL replay + backtest harness.** lppl --as-of already
    replays; FRED and Coin Metrics serve full history, so most of the
    scenario composite can replay too. Then any proposed
    threshold/weight change (Golden Rule 4 decisions) comes with a
    backtest instead of vibes. Direct extension of the M6 replay
    machinery.
13. **Composite regime state machine.** LPPL regime x stress band x
    gamma sign collapses into a small discrete state space; the DAILY
    STATE is less interesting than the TRANSITIONS, which become the
    alert events for Theme 4. Rule-based, no AI, fully testable.

## Theme 4 -- push, not pull

14. **ntfy.sh push alerts.** Free topic-based push (plain HTTPS POST,
    stdlib, no account for the basic tier): regime transitions (13),
    gamma flip crossings, new-filing discoveries, ref-vs-model
    divergence triggers (D8-e), publish-health OLD flags. The owner
    should not have to open the dashboard to learn something changed.
    One tiny lib + hooks in the existing agents.
15. **Daily AI morning brief** (brief:latest key). The Anthropic API
    is already integrated (ingest); a 06:50 agent reads the day's
    payloads + histories and writes ten lines: what changed overnight,
    what is stretched, what to watch. Cheap to pilot behind a flag;
    owner-taste-sensitive so it ships as a draft for review first.

## Already queued (do not lose to the shiny)

M7-13 deterministic iXBRL parser (kills the DJT-bug error class);
M7-10 catch-up composite mode; refetch bundle (owner go pending);
3350 price source fix; D8-e divergence alert wiring.

## Suggested picks (loop recommendation)

If three roads: (a) Theme 1 items 1+3 (vol surface + basis -- highest
signal per effort, zero source risk), (b) Theme 2 items 7+8 (COT +
Kalshi -- two probed sources, each one small module + one panel),
(c) Theme 3 item 11 (scorecard -- strategic, compounds with time).
Theme 4 item 14 (ntfy) is the cheap quality-of-life layer that makes
everything else more useful and can ride along any phase.
