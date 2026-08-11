# frozen_string_literal: true
#
# chart_specs.rb -- pure payload -> ECharts-option builders (M3-1,
# ARCHITECTURE.md section 6 Phase 3). A chart payload IS the ECharts
# option object: string keys only, fully JSON-serializable (string
# templates, never callbacks), deterministic for a given input -- the
# dashboard renders with one setOption(envelope.payload) call.
#
# CONTRACT: each chart's top-level option structure is FROZEN once its
# golden (test/golden/chart_<name>.json) is blessed. The golden is the
# contract test: it regenerates the spec from the committed payload
# fixtures (test/fixtures/payloads/) and byte-diffs. A red golden is a
# QUESTION FOR A HUMAN -- review the rendered result in preview.html,
# then `rake golden:approve` re-blesses. Never auto-approve.
#
# CHARTS is the registry the golden test, rake golden:approve and the
# publish pipeline (M3-5) all iterate: name -> payload fixture inputs
# (positional args, in order) + builder function + meta.
#
# RENDERER HOOKS (2026-07-05, owner design review): setOption(payload)
# stays verbatim, with exactly three meta-declared exceptions the render
# layer (preview.html, later the dashboard) owns:
#   meta['tooltip_formatter'] -- the NAME of a formatter in the
#     renderer's registry (currently only 'gex_levels': header line =
#     level + cross-venue C/P totals, then one line per venue, calls
#     green / puts red -- aggregation no JSON string template can do).
#     An unknown name renders with the default tooltip.
#   meta['height'] -- card pixel-height hint (scenario strip is half a
#     quadrant).
#   meta['legend_widget'] -- the NAME of an HTML legend widget in the
#     renderer's registry (currently only 'gex_cp': one line per venue,
#     `(p) DERI (c)` -- p/c toggle one side, the venue name both; owner
#     review round 4). The spec ships legend.show=false so ECharts still
#     owns series selection; the widget drives it via legend actions.
#   meta['tab_group'] (+ tab_label / tab_pos) -- M6-4, owner ruling D7-c
#     (2026-07-06): charts sharing a tab_group render into ONE dashboard
#     card as tabs -- 'gex' (gex_btc [BTC] + gex_mstr [MSTR] + gex_btc_trend
#     [BTC TREND] + gex_mstr_trend [MSTR TREND], M8-6/M8-18) and 'vol'
#     (vol_surface [SURFACE] + vol_basis [BASIS];
#     vol_spread is a SOLO card since 2026-08-10, owner 3x2-grid ruling).
#     tab_label is the button text; tab_pos fixes the tab order
#     (ascending) so BTC leads even though the index sorts gex_mstr
#     first.
#     The renderer builds the card from the first group member it loads
#     and attaches the rest; each key keeps its own header liveness dot.
# All four are part of the chart contract; add a hook only with an owner
# ruling.
#
# No IO, no ENV, no network in this file.

module Publish
  module Charts
    # meta (additive envelope field, 2026-07-05): METHODOLOGY-grade
    # hover help rendered by preview.html/the dashboard -- desc for the
    # title bubble, axes + help behind the info affordance.
    CHARTS = {
      # M8-18 (owner ruling 2026-08-10): chart key renamed gex_profile ->
      # gex_btc (the builder fn stays :gex_profile -- an internal detail).
      'gex_btc' => {
        inputs: %w[payload_gex_combined.json], fn: :gex_profile,
        meta: {
          'desc' => 'Dollar gamma dealers must re-hedge per 1% BTC move, ' \
                    'bucketed by BTC-equivalent strike across Deribit and the ' \
                    'US spot-ETF option chains. Above zero = long gamma ' \
                    '(dealer hedging pins price); below zero = short gamma ' \
                    '(hedging amplifies moves). Naive dealer model: trust ' \
                    'levels and walls more than the sign (METHODOLOGY.md).',
          'axes' => { 'x' => 'BTC price level (bucketed strikes, zoomed to ' \
                             'spot +-30% by default; wheel/drag to zoom out)',
                      'y' => 'net dealer gamma, $M per 1% BTC move' },
          'help' => 'Toggles right, one line per venue: (p) DERI (c) -- ' \
                    'click (c)/(p) to show/hide that side (calls teal, puts ' \
                    'red), click the venue name for both; DERI = Deribit; ' \
                    'venues with no open interest are omitted. Hover a level: ' \
                    'the header line is the cross-venue total, then one line ' \
                    'per venue with calls green / puts red. Lines: flip = ' \
                    'net-GEX zero crossing, CW/PW = biggest call/put walls.',
          # renderer hooks (header note): per-venue one-line hover rows
          # need aggregation, and the grouped (p) VENUE (c) toggles need
          # HTML, neither of which a JSON option can express
          'tooltip_formatter' => 'gex_levels',
          'legend_widget' => 'gex_cp',
          # tab-group hook (M6-4, owner ruling D7-c 2026-07-06; extended M8-18
          # 2026-08-10): the GEX card is now four tabs --
          # [BTC][MSTR][BTC TREND][MSTR TREND]. tab_pos is explicit because the
          # index sorts keys alphabetically yet BTC must be the default/first tab.
          'tab_group' => 'gex', 'tab_label' => 'BTC', 'tab_pos' => 1
        }
      },
      'gex_mstr' => {
        inputs: %w[payload_gex_mstr.json], fn: :gex_mstr,
        meta: {
          'desc' => 'Dollar gamma dealers must re-hedge per 1% MSTR move, ' \
                    'bucketed by strike on MSTR\'s own price axis (CBOE ' \
                    'single-name chain). Above zero = long gamma (dealer ' \
                    'hedging pins price); below zero = short gamma (hedging ' \
                    'amplifies moves). MSTR gamma is deliberately NOT merged ' \
                    'into the BTC-equivalent profile -- it lives on the equity, ' \
                    'not the coin. Naive dealer model: trust levels and walls ' \
                    'more than the sign (METHODOLOGY.md).',
          'axes' => { 'x' => 'MSTR price level (strikes, zoomed to spot +-30% ' \
                             'by default; wheel/drag to zoom out)',
                      'y' => 'net dealer gamma, $M per 1% MSTR move (per bar: ' \
                             'teal = long, red = short)' },
          'help' => 'One bar per strike, teal above zero (net long gamma) / ' \
                    'red below (net short). The CBOE chain reports net gamma ' \
                    'per strike, not a call/put split, so bars are single-sided. ' \
                    'Lines: spot (grey), flip = net-GEX zero crossing (amber), ' \
                    'CW/PW = biggest call/put walls.',
          # no tooltip_formatter: the gex_levels formatter aggregates per-venue
          # call/put series (C/P + '<venue> C/P'), which this single net-GEX
          # series does not carry -- the default axis tooltip is correct here.
          # tab-group hook (M6-4, owner ruling D7-c 2026-07-06): shares the
          # BTC gex_profile card as the second [MSTR] tab (BTC is tab_pos 1).
          'tab_group' => 'gex', 'tab_label' => 'MSTR', 'tab_pos' => 2
        }
      },
      'scenario_strip' => {
        inputs: %w[payload_scenario_latest.json payload_scenario_history.json],
        fn: :scenario_strip,
        meta: {
          'desc' => 'Seven cheap, independent signals -- ETF flows, funding, ' \
                    'Coinbase premium, macro liquidity, hash ribbons, MVRV, ' \
                    'stablecoin supply -- each scored -1/0/+1 for whether the ' \
                    'tape supports flush, base or recovery at its own horizon. ' \
                    'The weighted composite (sum(weight*score)/12) is banded ' \
                    'FLUSH/LEAN-FLUSH/NEUTRAL/BASE/RECOVERY; its DRIFT across ' \
                    'successive readings is the signal, not any single print ' \
                    '(METHODOLOGY.md).',
          'axes' => { 'x' => 'time -- successive composite readings (watch the ' \
                             'drift, not one print)',
                      'y' => 'weighted composite, fixed -1..+1; dashed lines ' \
                             'mark the five regime-band boundaries' },
          'help' => 'Right column: one heatmap cell per module (red -1 / grey ' \
                    '0 / teal +1), the seven current scores top to bottom. ' \
                    'Inside band labels name each composite zone; hover the ' \
                    'line for each reading. A hollow/grey point is a day ' \
                    'recorded during a data outage (composite forced to 0) -- ' \
                    'not a real neutral print.',
          # renderer hook: half-height card (owner review 2026-07-05 --
          # the strip was vertically stretched at full quadrant height)
          'height' => 250
        }
      },
      'lppl_regime' => {
        inputs: %w[payload_lppl_latest.json payload_lppl_ledger.json],
        fn: :lppl_regime,
        meta: {
          'desc' => 'The LPPL-as-regime claim -- BTC log price is an ' \
                    'anti-bubble around a genesis-anchored power law -- is not ' \
                    'proven but continually FALSIFIED: four independent tests ' \
                    'run daily and accumulate evidence either way, any one able ' \
                    'to kill it. This chart plots the evidence LEDGER over ' \
                    'time, not price vs trend (METHODOLOGY.md).',
          'axes' => { 'x' => 'time -- daily evaluation points across the ledger',
                      'y' => 'three stacked panels: (top) price/trend ratio vs ' \
                             'the damping-envelope bound/floor; (mid) ' \
                             'trailing-1y log10 Bayes factor pl_full vs best ' \
                             'rival, with its zero line; (bottom) age-adjusted ' \
                             'percentile Z' },
          'help' => 'markLines: envelope bound (amber) and floor (red) on the ' \
                    'ratio panel, zero line on BF; the pin marks the latest ' \
                    'ratio. Read the SIGN and drift of BF, not its absolute ' \
                    'size; a trough note appears over Z only when the fit ' \
                    'names an interior bottom. Right: the shadow scoreboard, ' \
                    'each Phase-9 shadow field beside its frozen original -- ' \
                    'mean/eval, the density-honest per-evaluation trend mean ' \
                    '(D9-b); 365/730, the report-only long-horizon means ' \
                    '(D9-c); damping, the fit anti-bubble condition, and impr, ' \
                    'frozen vs symmetric-null RMSE improvement (both D9-e); ' \
                    'p(osc), AR(1) vs GARCH bootstrap p (D9-f); freeze, the ' \
                    'live envelope bound vs its pre-trough freeze candidate ' \
                    '(D9-g). A missing shadow field hides its row.'
        }
      },
      'btco_table' => {
        inputs: %w[payload_btco_latest.json], fn: :btco_table,
        meta: {
          'desc' => 'Bitcoin treasury companies are levered, reflexive ' \
                    'holders: above BTC NAV they issue shares to buy more ' \
                    '(flywheel on), below NAV they risk becoming forced ' \
                    'sellers. The 0-100 stress score is BTC-weighted -- 45% ' \
                    'share of universe below mNAV 1, 35% median-mNAV shortfall ' \
                    'below 1.40, 20% aggregate leverage -- banded ' \
                    'CALM/ELEVATED/STRESSED/CRITICAL. Rows flagged * ' \
                    '(placeholder) or STALE are not yet trustworthy ' \
                    '(METHODOLOGY.md).',
          'axes' => { 'x' => 'NAV multiple (mcap / BTC NAV); dashed line at ' \
                             '1.0 is NAV parity',
                      'y' => 'company, sorted by BTC held (largest at top); ' \
                             '* = placeholder seed, STALE = btc_as_of > 120d' },
          'help' => 'Two bars per row: mNAV (market cap / BTC NAV) and netNAV ' \
                    '(premium on the equity claim after senior claims), nulls ' \
                    'left as gaps. The gauge shows aggregate stress 0-100 in ' \
                    'green/amber/orange/red bands with the regime band as its ' \
                    'detail text.'
        }
      },
      # ---- M8-6: the GEX/volatility family (Phase 8A stage 2) ----------
      # vol_surface + vol_basis share ONE dashboard card as two STACKED
      # half-height charts (tab_group 'vol', group_style 'stack').
      # vol_spread + vol_spread_trend likewise share ONE stacked card
      # (tab_group 'volspread', owner ruling 2026-08-10): current per-tenor
      # spread bars on top, the daily spread trend below. gex_trend joins
      # the existing GEX card as [TREND].
      'vol_surface' => {
        inputs: %w[payload_vol_latest.json], fn: :vol_surface,
        meta: {
          'desc' => 'The implied-vol term structure from Deribit\'s BTC option ' \
                    'chain at three nominal tenors: ATM IV is the at-the-money ' \
                    'level, RR25 the 25-delta risk reversal (call IV minus put ' \
                    'IV) and FLY25 the 25-delta butterfly. GEX says where dealers ' \
                    'are positioned; skew says what the market pays to insure the ' \
                    'tails -- a negative RR25 means downside puts cost more than ' \
                    'upside calls (fear).',
          'axes' => { 'x' => 'requested tenor (7/30/90d); the actual option ' \
                             'expiry backing each rides the tooltip as exp(d)',
                      'y' => 'left: ATM implied vol (%); right: 25-delta skew in ' \
                             'vol points (RR25 red, FLY25 amber)' },
          'help' => 'ATM IV (teal) reads on the left axis; RR25 (red) and FLY25 ' \
                    '(amber) are vol points on the right. A tenor whose chain was ' \
                    'too thin (reason set) is dropped, not drawn as zero. ' \
                    'Negative RR25 = downside fear; a rising FLY25 = fatter tails.',
          # stacked card (owner ruling 2026-08-10): surface + basis are
          # one card, two half-height charts -- group_style 'stack',
          # tab_pos = vertical order, height = half a card. The SURFACE
          # section is itself a [BTC][MSTR] tab pair (owner ruling
          # 2026-08-10, M8-17): vol_surface + vol_surface_mstr share
          # tab_pos 0, so the renderer collapses them into one tabbed
          # section; tab_label names the button (BTC leads, lower CARD_ORDER).
          'tab_group' => 'vol', 'group_style' => 'stack', 'tab_pos' => 0,
          'tab_label' => 'BTC', 'height' => 235
        }
      },
      # M8-17: the MSTR vol surface -- same builder body as vol_surface, an
      # MSTR title. Shares vol_surface's tab_pos 0 so the SURFACE section of
      # the stacked vol card carries [BTC][MSTR] tabs (owner ruling 2026-08-10).
      'vol_surface_mstr' => {
        inputs: %w[payload_vol_mstr.json], fn: :vol_surface_mstr,
        meta: {
          'desc' => 'The implied-vol term structure from MicroStrategy\'s ' \
                    'own option chain (CBOE single-name, USD cash-settled) at ' \
                    'three nominal tenors: ATM IV is the at-the-money level, ' \
                    'RR25 the 25-delta risk reversal (call IV minus put IV) and ' \
                    'FLY25 the 25-delta butterfly. MSTR is a levered, reflexive ' \
                    'BTC holder, so its vol persistently trades richer than ' \
                    'BTC\'s -- the [BTC] tab is the coin, this is the equity.',
          'axes' => { 'x' => 'requested tenor (7/30/90d); the actual option ' \
                             'expiry backing each rides the tooltip as exp(d)',
                      'y' => 'left: ATM implied vol (%); right: 25-delta skew in ' \
                             'vol points (RR25 red, FLY25 amber)' },
          'help' => 'ATM IV (teal) reads on the left axis; RR25 (red) and FLY25 ' \
                    '(amber) are vol points on the right. MSTR options are ' \
                    'USD-settled single-name, so the listed chain is shorter ' \
                    'than BTC\'s -- a thin 90d tenor drops honestly (reason set), ' \
                    'never drawn as zero. Negative RR25 = downside fear.',
          # the MSTR half of the SURFACE section (owner ruling 2026-08-10):
          # same tab_pos 0 as vol_surface so the renderer tabs the two into
          # one section; MSTR is the second tab (BTC leads by CARD_ORDER).
          'tab_group' => 'vol', 'group_style' => 'stack', 'tab_pos' => 0,
          'tab_label' => 'MSTR', 'height' => 235
        }
      },
      'vol_spread' => {
        inputs: %w[payload_vol_spread.json], fn: :vol_spread,
        meta: {
          'desc' => 'The market\'s live price of treasury-company leverage: ' \
                    'MSTR\'s ATM implied vol minus BTC\'s, tenor by tenor. MSTR ' \
                    'is a levered, reflexive BTC holder, so its options ' \
                    'persistently trade richer; the spread (vol points) is how ' \
                    'much extra the option market charges for that leverage now.',
          'axes' => { 'x' => 'requested tenor (7/30/90d)',
                      'y' => 'implied vol (%): bars = the MSTR-minus-BTC ATM ' \
                             'spread in vol points, lines = each leg\'s ATM IV ' \
                             '(MSTR bright, BTC dim)' },
          'help' => 'Bars are the ATM spread (teal positive, red negative); the ' \
                    'two lines are the raw ATM IV of each leg, so you can see ' \
                    'whether a move came from MSTR richening or BTC cheapening. A ' \
                    'leg whose chain failed drops its line and that tenor\'s bar.',
          # stacked with its trend since 2026-08-10 (owner ruling): the
          # current per-tenor bars ride on top (tab_pos 0), the daily spread
          # trend below (vol_spread_trend, tab_pos 1) -- group_style 'stack',
          # height = half a card, exactly like the vol_surface/vol_basis card.
          'tab_group' => 'volspread', 'group_style' => 'stack', 'tab_pos' => 0,
          'height' => 235
        }
      },
      'vol_spread_trend' => {
        # SAME payload as vol_spread (the spread producer's --json carries the
        # daily "history"), a different builder -- the trend view below the bars.
        inputs: %w[payload_vol_spread.json], fn: :vol_spread_trend,
        meta: {
          'desc' => 'The MSTR-minus-BTC ATM vol spread over time, one line per ' \
                    'tenor (7/14/21/45/90d). This is the same treasury-company ' \
                    'leverage premium as the bars above, but as a term-structure ' \
                    'trend: it accumulates one point per day from the first ' \
                    'deploy, so early history is short and fills in daily.',
          'axes' => { 'x' => 'day (one daily reading per UTC date, oldest left)',
                      'y' => 'MSTR-minus-BTC ATM spread in vol points, per tenor' },
          'help' => 'Each line is one requested tenor\'s spread history; a rising ' \
                    'line means MSTR options are richening versus BTC at that ' \
                    'tenor. A day whose leg failed leaves a gap, never a zero. ' \
                    'The chart starts nearly empty and grows a point per day.',
          # stacked below vol_spread (owner ruling 2026-08-10) -- half a card.
          'tab_group' => 'volspread', 'group_style' => 'stack', 'tab_pos' => 1,
          'height' => 235
        }
      },
      'vol_basis' => {
        inputs: %w[payload_basis_latest.json], fn: :vol_basis,
        meta: {
          'desc' => 'The annualized basis of Deribit\'s dated BTC futures over ' \
                    'spot, per expiry, plus the perpetual funding rate. Positive ' \
                    'basis / positive funding = the market pays to be long ' \
                    '(contango, leverage demand); a flip negative is ' \
                    'deleveraging or fear. Funding is quoted per 8h; the ' \
                    '1d/7d/30d means show whether the current print is an outlier.',
          'axes' => { 'x' => 'days to expiry of each dated future (sub-1-day ' \
                             'tenors omitted as microstructure noise)',
                      'y' => 'annualized basis over spot (%); the dashed line is ' \
                             '0 (fair)' },
          'help' => 'The amber line is each future\'s annualized basis; above 0 ' \
                    '= contango. The title carries the latest perpetual funding ' \
                    '(%/8h) and its 1d/7d/30d means. If the futures leg is down ' \
                    'the line is empty and only funding remains.',
          # stacked card (owner ruling 2026-08-10) -- below vol_surface
          'tab_group' => 'vol', 'group_style' => 'stack', 'tab_pos' => 2,
          'height' => 235
        }
      },
      # M8-18 (owner ruling 2026-08-10): chart key renamed gex_trend ->
      # gex_btc_trend, tab_label 'TREND' -> 'BTC TREND' (fn stays :gex_trend).
      'gex_btc_trend' => {
        inputs: %w[payload_gex_trend.json payload_gex_check.json], fn: :gex_trend,
        meta: {
          'desc' => 'A time series over the daily BTC-combined GEX snapshots ' \
                    '(accumulating since 2026-07-06): where spot sat each day ' \
                    'relative to the gamma flip and the call/put walls, and how ' \
                    'long the current gamma regime has held. Descriptive only -- ' \
                    'every level is read straight from that day\'s snapshot, no ' \
                    'scoring. The MP delta cross-checks our flip vs Coinglass ' \
                    'max-pain.',
          'axes' => { 'x' => 'day (the last N daily snapshots)',
                      'y' => 'BTC price level ($k): spot (white), gamma flip ' \
                             '(amber), call wall (teal), put wall (red)' },
          'help' => 'Four price levels per day: spot vs the gamma flip (dealers ' \
                    'pin above it, amplify below) and the call/put walls. The ' \
                    'title carries flip distance last, the regime run length, ' \
                    'and -- when the Coinglass cross-check is present -- MP ' \
                    'Delta, spot vs their max-pain. Sparse history reads as ' \
                    'filled dots.',
          # joins the existing GEX card (D7-c) as the third tab after
          # [BTC](pos 1) and [MSTR](pos 2); pos 3 keeps [BTC TREND] before
          # [MSTR TREND](pos 4).
          'tab_group' => 'gex', 'tab_label' => 'BTC TREND', 'tab_pos' => 3
        }
      },
      # M8-18 (owner ruling 2026-08-10): the daily MSTR GEX trend. Reads the
      # SAME gex:trend payload as [BTC TREND], but from its additive top-level
      # 'mstr' block (scripts/gex_trend.rb: {series, stats} over the MSTR `us`
      # captures, MSTR's own dollar axis). Fourth tab of the GEX card, after
      # [BTC TREND]. No max-pain cross-check (that is BTC-only), so no gex:check
      # input.
      'gex_mstr_trend' => {
        inputs: %w[payload_gex_trend.json], fn: :gex_mstr_trend,
        meta: {
          'desc' => 'A time series over the daily MSTR GEX snapshots ' \
                    '(accumulating since 2026-07-06): where MSTR spot sat each ' \
                    'day relative to its own gamma flip and call/put walls, on ' \
                    'the equity\'s dollar axis. Descriptive only -- every level ' \
                    'is read straight from that day\'s single-name chain ' \
                    'snapshot, no scoring. MSTR gamma lives on the equity, not ' \
                    'the coin, so it is never merged into the BTC trend.',
          'axes' => { 'x' => 'day (the last N daily snapshots)',
                      'y' => 'MSTR price level ($): spot (white), gamma flip ' \
                             '(amber), call wall (teal), put wall (red)' },
          'help' => 'Four price levels per day: MSTR spot vs its gamma flip ' \
                    '(dealers pin above it, amplify below) and the call/put ' \
                    'walls. The title carries flip distance last and the regime ' \
                    'run length. Sparse history reads as filled dots; a day with ' \
                    'no MSTR capture is an honest gap.',
          # fourth tab of the GEX card, after [BTC TREND](pos 3).
          'tab_group' => 'gex', 'tab_label' => 'MSTR TREND', 'tab_pos' => 4
        }
      }
    }.freeze

    module_function

    # gex:combined payload -> per-level put/call bars stacked by venue.
    # Compact form (owner design review 2026-07-05): venues with no data
    # at all are OMITTED, values are $M, the hover bubble leads with the
    # cross-venue C/P aggregates (as two invisible line series ordered
    # first), the built-in legend is hidden (show false, data kept so it
    # still owns selection state) in favour of the renderer's grouped
    # (p) VENUE (c) toggle widget (meta.legend_widget, owner review
    # round 4), no slider (inside zoom only).
    # A venue earns a place on the chart only if it is VISIBLE at the
    # $M display precision somewhere -- venues whose whole book rounds
    # to 0.00M everywhere are noise rows in the legend and hover
    # (owner review round 2).
    GEX_MIN_MUSD = 0.05

    def gex_profile(gex)
      venues = gex['profiles'].select { |_, per|
        per.values.any? { |s|
          musd(s['call']).abs >= GEX_MIN_MUSD || musd(s['put']).abs >= GEX_MIN_MUSD
        }
      }.keys
      levels = venues.flat_map { |v| gex['profiles'][v].keys }.uniq
                     .sort_by { |k| k.to_i }
      labels = levels.map { |l| level_label(l) }
      stale  = stale_venue_names(gex)
      bars   = venue_series(gex, venues, levels, stale)
      series = aggregate_series(gex, venues, levels) + bars
      bars.first['markLine'] = mark_lines(gex, levels) if bars.first

      {
        # the renderer inits with the ECharts DARK THEME (professionally
        # tuned text/legend/axis colors incl. dim-inactive legend states);
        # transparent bg lets the card surface show through
        'backgroundColor' => 'transparent',
        'title' => { 'text' => format('GEX $M/1%% · spot %s%s',
                                      level_label(gex['btc_spot'].to_i),
                                      gex_stale_suffix(gex, venues, stale)),
                     'textStyle' => { 'fontSize' => 13 } },
        'tooltip' => { 'trigger' => 'axis', 'confine' => true, 'textStyle' => { 'fontSize' => 11 }, 'axisPointer' => { 'type' => 'shadow' } },
        # hidden: the renderer's (p) VENUE (c) widget (meta.legend_widget)
        # replaces the drawn legend; the component stays so legend actions
        # keep driving series selection
        'legend' => { 'show' => false, 'data' => bars.map { |s| s['name'] } },
        # M8-18 R4 (owner ruling 2026-08-10): the widget moved to the TOP-RIGHT
        # (was a right-margin column), so right drops 92 -> 12 and left 52 -> 42
        # (fits the $M value labels) -- a visibly wider plot. top 56 -> 66 so
        # the raised wall labels (grid.top - 14) sit a clear row BELOW the 2-row
        # widget (which ends ~34px): screenshot showed CW brushing the DERI
        # toggle at top 56.
        'grid' => { 'left' => 42, 'right' => 12, 'top' => 66, 'bottom' => 26 },
        'xAxis' => { 'type' => 'category', 'data' => labels },
        'yAxis' => { 'type' => 'value' },
        # all levels stay in the data; the default window shows the
        # +-30% band around spot (deep-OTM tails reachable by zoom-out)
        'dataZoom' => [
          { 'type' => 'inside',
            'startValue' => nearest_label(levels, gex['btc_spot'].to_f * 0.7),
            'endValue' => nearest_label(levels, gex['btc_spot'].to_f * 1.3) }
        ],
        'series' => series
      }
    end

    # ---- gex_profile internals ----------------------------------------

    def level_label(level)
      v = level.to_i
      (v % 1000).zero? ? "#{v / 1000}k" : format('%.1fk', v / 1000.0)
    end

    def musd(cents_scale_value)
      (cents_scale_value.to_f / 1e6).round(2)
    end

    def venue_label(venue)
      venue == 'Deribit' ? 'DERI' : venue
    end

    # Two invisible line series named C / P, ordered FIRST so the axis
    # hover bubble leads with the cross-venue aggregates in the side
    # colors ("54k: C 10.5 P -5.33", $M).
    def aggregate_series(gex, venues, levels)
      [%w[C call #0f7a5c], %w[P put #c63939]].map do |name, side, color|
        { 'name' => name, 'type' => 'line', 'showSymbol' => false, 'silent' => true,
          'lineStyle' => { 'opacity' => 0 }, 'itemStyle' => { 'color' => color },
          'data' => levels.map { |l|
            musd(venues.sum { |v| gex['profiles'][v].dig(l, side).to_i })
          } }
      end
    end

    def venue_series(gex, venues, levels, stale = [])
      venues.each_with_index.flat_map do |venue, i|
        per = gex['profiles'][venue]
        # stale marking (M7-8): a venue whose book came from cache gets a
        # trailing '!' on its label ('DERI! C'); render.js's gex_levels
        # formatter and gex_cp widget both parse /^(.*) ([CP])$/, so the
        # bang rides through into m[1] with no renderer change.
        label = stale.include?(venue) ? "#{venue_label(venue)}!" : venue_label(venue)
        # barGap -100% overlays the calls stack exactly on the puts stack
        # at each level (safe: calls >= 0, puts <= 0 -- they never cover
        # each other); the default side-by-side placement read as a
        # misalignment (owner review round 4)
        [{ 'name' => "#{label} C", 'type' => 'bar', 'stack' => 'calls',
           'barGap' => '-100%',
           'itemStyle' => { 'color' => shade('calls', i, venues.size) },
           'data' => levels.map { |l| musd(per.dig(l, 'call').to_i) } },
         { 'name' => "#{label} P", 'type' => 'bar', 'stack' => 'puts',
           'barGap' => '-100%',
           'itemStyle' => { 'color' => shade('puts', i, venues.size) },
           'data' => levels.map { |l| musd(per.dig(l, 'put').to_i) } }]
      end
    end

    # Names of venues whose book came from cache this run (M7-8): the
    # additive per-venue 'stale' flag on the gex_btc_combined payload.
    # Absent on all-fresh payloads -> [] -> byte-identical goldens.
    def stale_venue_names(gex)
      (gex['venues'] || []).select { |v| v['stale'] }.map { |v| v['name'] }
    end

    # Title suffix ' · stale: <names>' when any source is stale (M7-8):
    # stale venue labels plus 'spot' when the Deribit index came from
    # cache. Empty (no suffix) on all-fresh payloads.
    def gex_stale_suffix(gex, venues, stale)
      names = []
      if (gex['sources'] || []).any? { |s| s['name'] == 'deribit_index' && s['stale'] }
        names << 'spot'
      end
      names += venues.select { |v| stale.include?(v) }.map { |v| venue_label(v) }
      names.empty? ? '' : " · stale: #{names.join(', ')}"
    end

    # Teal (calls) / red (puts) base hues, lightened stepwise per venue
    # index -- deterministic, any venue count.
    def shade(side, index, count)
      base = side == 'calls' ? [22, 122, 92] : [198, 57, 57]
      t = count > 1 ? index.to_f / (count - 1) : 0.0
      rgb = base.map { |c| (c + (232 - c) * t * 0.72).round }
      format('#%02x%02x%02x', *rgb)
    end

    # Flip (solid amber) + call/put walls (dashed) snapped to the
    # nearest bucketed level so they land on the category axis. Wall
    # labels are raised into the upper band of the grid-top label zone
    # so an adjacent wall+flip pair can never garble ("PWlip") and no
    # label reaches the title (owner report, Gate 6 preview).
    WALL_RAISE = { 'offset' => [0, -14] }.freeze

    def mark_lines(gex, levels)
      c = gex['combined'] || {}
      lines = []
      if c['gamma_flip']
        lines << { 'xAxis' => nearest_label(levels, c['gamma_flip']),
                   'label' => { 'formatter' => 'flip' },
                   'lineStyle' => { 'color' => '#e6a23c', 'type' => 'solid', 'width' => 2 } }
      end
      if c['call_wall']
        lines << { 'xAxis' => nearest_label(levels, c['call_wall']['level']),
                   'label' => { 'formatter' => 'CW' }.merge(WALL_RAISE),
                   'lineStyle' => { 'color' => '#0f7a5c', 'type' => 'dashed' } }
      end
      if c['put_wall']
        lines << { 'xAxis' => nearest_label(levels, c['put_wall']['level']),
                   'label' => { 'formatter' => 'PW' }.merge(WALL_RAISE),
                   'lineStyle' => { 'color' => '#c63939', 'type' => 'dashed' } }
      end
      { 'symbol' => 'none', 'data' => lines }
    end

    def nearest_label(levels, value)
      level_label(levels.min_by { |l| (l.to_i - value.to_i).abs })
    end

    # ---- gex_mstr (M6-3) ----------------------------------------------
    #
    # gex:mstr payload (scripts/gex_us.rb MSTR --json, a single object) ->
    # the single-venue variant of the gex_profile grammar, on MSTR's own
    # price axis (D7-c: the two GEX charts share one card as tabs, so the
    # dark theme, palette, fonts and title/tooltip shapes match). SIBLING
    # builder, not a gex_profile adapter: gex_us's payload carries NET
    # gamma per strike ({strike => signed $}) -- calls and puts are already
    # summed by inst_gex, so there is no call/put split to stack, and its
    # walls sit under top-level call_wall/put_wall['strike'] (not a nested
    # 'combined' with ['level']). One bar per strike, coloured per bar
    # teal (net long) / red (net short); markLines for spot, flip and the
    # call/put walls. Shares musd (and the palette) with gex_profile.
    GEX_TEAL = '#0f7a5c'
    GEX_RED  = '#c63939'

    def gex_mstr(gex)
      profile = gex['profile'] || {}
      levels  = profile.keys.sort_by { |k| k.to_f }
      bars = levels.map do |l|
        m = musd(profile[l].to_i)
        { 'value' => m, 'itemStyle' => { 'color' => m.negative? ? GEX_RED : GEX_TEAL } }
      end

      {
        # the renderer inits with the ECharts DARK THEME (professionally
        # tuned text/legend/axis colors); transparent bg lets the card
        # surface show through -- identical framing to gex_profile
        'backgroundColor' => 'transparent',
        # ' · stale' when the CBOE chain came from cache (M7-8, gex_us
        # top-level 'stale'); absent on all-fresh payloads
        'title' => { 'text' => format('MSTR GEX $M/1%% · spot %s%s', mstr_label(gex['spot']),
                                      gex['stale'] ? ' · stale' : ''),
                     'textStyle' => { 'fontSize' => 13 } },
        'tooltip' => { 'trigger' => 'axis', 'confine' => true, 'textStyle' => { 'fontSize' => 11 }, 'axisPointer' => { 'type' => 'shadow' } },
        # M8-18 R4 (owner ruling 2026-08-10): left/right tightened to match the
        # BTC tab (42/12; no widget here) for a visibly wider plot. top 56 keeps
        # the two-band markline label zone (flip/spot lower, walls raised).
        'grid' => { 'left' => 42, 'right' => 12, 'top' => 56, 'bottom' => 26 },
        'xAxis' => { 'type' => 'category', 'data' => levels.map { |l| mstr_label(l) } },
        'yAxis' => { 'type' => 'value' },
        # all strikes stay in the data; the default window shows the
        # +-30% band around spot (deep-OTM tails reachable by zoom-out)
        'dataZoom' => [
          { 'type' => 'inside',
            'startValue' => nearest_mstr_label(levels, gex['spot'].to_f * 0.7),
            'endValue' => nearest_mstr_label(levels, gex['spot'].to_f * 1.3) }
        ],
        'series' => [
          { 'name' => 'net GEX', 'type' => 'bar', 'data' => bars,
            'markLine' => mstr_mark_lines(gex, levels) }
        ]
      }
    end

    # ---- gex_mstr internals -------------------------------------------

    # Strike/price label on the MSTR dollar axis: raw dollars below 1k,
    # 'k'-compacted above (matches gex_us.rb's own price formatting).
    def mstr_label(value)
      v = value.to_f
      v >= 1000 ? format('%.1fk', v / 1000.0) : format('%g', v.round(2))
    end

    def nearest_mstr_label(levels, value)
      mstr_label(levels.min_by { |l| (l.to_f - value.to_f).abs })
    end

    # Spot (solid grey) + flip (solid amber) + call/put walls (dashed)
    # snapped to the nearest strike so they land on the category axis.
    def mstr_mark_lines(gex, levels)
      lines = []
      if gex['spot']
        lines << { 'xAxis' => nearest_mstr_label(levels, gex['spot']),
                   'label' => { 'formatter' => 'spot' },
                   'lineStyle' => { 'color' => '#c9ccd1', 'type' => 'solid', 'width' => 1 } }
      end
      if gex['gamma_flip']
        lines << { 'xAxis' => nearest_mstr_label(levels, gex['gamma_flip']),
                   'label' => { 'formatter' => 'flip' },
                   'lineStyle' => { 'color' => '#e6a23c', 'type' => 'solid', 'width' => 2 } }
      end
      if gex['call_wall']
        lines << { 'xAxis' => nearest_mstr_label(levels, gex['call_wall']['strike']),
                   'label' => { 'formatter' => 'CW' }.merge(WALL_RAISE),
                   'lineStyle' => { 'color' => GEX_TEAL, 'type' => 'dashed' } }
      end
      if gex['put_wall']
        lines << { 'xAxis' => nearest_mstr_label(levels, gex['put_wall']['strike']),
                   'label' => { 'formatter' => 'PW' }.merge(WALL_RAISE),
                   'lineStyle' => { 'color' => GEX_RED, 'type' => 'dashed' } }
      end
      { 'symbol' => 'none', 'data' => lines }
    end

    # ---- scenario_strip (M3-2) ----------------------------------------
    #
    # scenario:latest + scenario:history -> a two-grid strip. Compact form
    # (owner design review 2026-07-05): one-line 13px title carries regime +
    # composite, no subtext. The MAIN grid (left) is the composite path
    # (history entries on a time axis, fixed [-1, 1]); dashed markLines mark
    # the four regime boundaries with band labels sitting INSIDE at the left
    # edge. The heatmap is now a narrow vertical COLUMN right of the main
    # grid: one cell per module (1 col x 7 rows), module names on its y axis,
    # coloured by a hidden piecewise visualMap (-1 red / 0 grey / +1 teal).
    # Degenerate-safe: a single history point renders as one symbol.

    # Regime boundaries and the band each interval maps to (band label is
    # anchored at the interval midpoint so it rides beside its zone).
    SCN_THRESHOLDS = [-0.40, -0.10, 0.10, 0.40].freeze
    SCN_BANDS = [[-0.70, 'FLUSH'], [-0.25, 'LEAN-FLUSH'], [0.0, 'NEUTRAL'],
                 [0.25, 'BASE'], [0.70, 'RECOVERY']].freeze

    # M8-10: a day recorded during a data outage (M8-8 blind marker: every
    # scored module unavailable, composite forced to 0) renders as a hollow
    # grey marker so it never reads as a real neutral print. Healthy entries
    # stay bare [ts, composite] pairs (the composite line is unbroken).
    SCN_BLIND_ITEM = { 'color' => 'transparent', 'borderColor' => '#9aa0a6',
                       'borderWidth' => 1.5 }.freeze

    def scenario_strip(latest, history)
      modules  = latest['modules'] || []
      names    = modules.map { |m| m['mod'] }
      comp     = (history['entries'] || []).map do |e|
        pt = [e['ts'], e['composite']]
        e['blind'] ? { 'value' => pt, 'symbol' => 'circle', 'symbolSize' => 6,
                       'itemStyle' => SCN_BLIND_ITEM } : pt
      end
      # heatmap is now a vertical column: [col 0, row = module index, score]
      heat     = modules.each_with_index.map { |m, i| [0, i, m['score']] }

      {
        # the renderer inits with the ECharts DARK THEME (professionally
        # tuned text/legend/axis colors incl. dim-inactive legend states);
        # transparent bg lets the card surface show through
        'backgroundColor' => 'transparent',
        'title' => {
          'text' => format('Scenario %s %+.2f%s', latest['regime'].to_s,
                           latest['composite'].to_f,
                           scenario_drift_suffix(latest, history)),
          'textStyle' => { 'fontSize' => 13 }
        },
        'tooltip' => { 'trigger' => 'axis', 'confine' => true, 'textStyle' => { 'fontSize' => 11 } },
        # main grid (composite) left, tight; narrow heatmap column right of it
        'grid' => [
          { 'left' => 60, 'right' => 122, 'top' => 30, 'bottom' => 26 },
          { 'right' => 12, 'width' => 20, 'top' => 30, 'bottom' => 26 }
        ],
        'xAxis' => [
          { 'type' => 'time', 'gridIndex' => 0 },
          { 'type' => 'category', 'gridIndex' => 1, 'data' => ['now'],
            'axisLabel' => { 'show' => false }, 'axisTick' => { 'show' => false } }
        ],
        'yAxis' => [
          # name rides the axis (rotated, left gutter): at the default top
          # position it collided with the one-line title, and at the bottom
          # it would collide with the time labels (owner review round 4)
          { 'type' => 'value', 'gridIndex' => 0, 'min' => -1, 'max' => 1,
            'name' => 'composite', 'nameLocation' => 'middle', 'nameGap' => 44 },
          { 'type' => 'category', 'gridIndex' => 1, 'data' => names,
            'inverse' => true, 'axisTick' => { 'show' => false },
            'axisLabel' => { 'interval' => 0, 'fontSize' => 11 } }
        ],
        # scoped to the heatmap (seriesIndex 1, dimension 2 = the score);
        # hidden -- it is a colour scale, not a user control.
        'visualMap' => [
          { 'type' => 'piecewise', 'show' => false, 'seriesIndex' => 1,
            'dimension' => 2, 'min' => -1, 'max' => 1,
            'pieces' => [
              { 'value' => -1, 'color' => '#c63939' },
              { 'value' => 0, 'color' => '#9aa0a6' },
              { 'value' => 1, 'color' => '#0f7a5c' }
            ] }
        ],
        'series' => [
          { 'name' => 'composite', 'type' => 'line', 'xAxisIndex' => 0,
            'yAxisIndex' => 0, 'showSymbol' => true, 'symbol' => 'circle', 'symbolSize' => 6,
            'lineStyle' => { 'color' => '#3b6ea5' }, 'data' => comp,
            'markLine' => scenario_bands },
          { 'name' => 'modules', 'type' => 'heatmap', 'xAxisIndex' => 1,
            'yAxisIndex' => 1, 'data' => heat,
            'label' => { 'show' => true, 'formatter' => '{@[2]}' } }
        ]
      }
    end

    # M8-18 R5 (owner ruling 2026-08-10): a trailing drift arrow on the title,
    # ' ↗' / ' ↘' / ' →'. drift = the latest composite (the number the title
    # already shows) minus the composite 7 readings earlier in the history
    # (or the earliest available when the history is shorter). > +0.02 rises
    # (↗), < -0.02 falls (↘), else flat (→). No arrow (empty suffix) when the
    # history has fewer than 2 readings -- there is no direction to draw. The
    # drift is the signal, not any single print (METHODOLOGY.md).
    def scenario_drift_suffix(latest, history)
      comps = (history['entries'] || []).map { |e| e['composite'].to_f }
      return '' if comps.size < 2

      ref = comps[[comps.size - 8, 0].max] # 7 readings before the latest, or earliest
      drift = latest['composite'].to_f - ref
      arrow = drift > 0.02 ? '↗' : (drift < -0.02 ? '↘' : '→')
      " #{arrow}"
    end

    # Four dashed boundary lines (numeric label on the left) plus five
    # invisible carrier lines whose only job is a right-flush band label.
    def scenario_bands
      thresholds = SCN_THRESHOLDS.map do |t|
        { 'yAxis' => t, 'lineStyle' => { 'type' => 'dashed', 'color' => '#c9ccd1' },
          'label' => { 'position' => 'start', 'formatter' => format('%+.2f', t) } }
      end
      # band labels sit INSIDE the plot at the left edge so the narrow
      # heatmap column can hug the right without a wide right margin.
      bands = SCN_BANDS.map do |y, name|
        { 'yAxis' => y, 'lineStyle' => { 'opacity' => 0 },
          'label' => { 'position' => 'insideStartTop', 'formatter' => name,
                       'color' => '#6b7178' } }
      end
      { 'symbol' => 'none', 'silent' => true, 'data' => thresholds + bands }
    end

    # ---- lppl_regime (M3-3) -------------------------------------------
    #
    # lppl:latest + lppl:ledger -> three time-aligned panels of the
    # EVIDENCE trajectory. Compact form (owner design review 2026-07-05):
    # one-line 13px title carries verdict + composite, no subtext, tight
    # evenly-spaced grids. (The published payloads carry no price series, so
    # the ARCHITECTURE log-price panel is out of scope here): ratio vs the
    # current damping envelope (bound/floor from latest's envelope test),
    # log10 Bayes factor vs its zero line, and the Z path. Null ledger
    # fields are skipped so a broken point never breaks a panel. If latest'
    # fit test detail carries trough_date/trough_px, a text-only note is
    # added over the Z panel (the trough lies beyond the x range).

    def lppl_regime(latest, ledger)
      entries = ledger['entries'] || []
      ratio   = ledger_series(entries, 'ratio')
      bf      = ledger_series(entries, 'bf')
      z       = ledger_series(entries, 'z')
      env     = lppl_detail(latest, 'envelope') || {}
      fit     = lppl_detail(latest, 'fit') || {}

      # M9-11: the Phase-9 shadow fields become a right-side scoreboard.
      # With no shadow fields the card degrades to its pre-M9-11 form --
      # tight right margin, three panels, the whole-card axisPointer link.
      rows  = lppl_shadow_rows(latest)
      right = rows.empty? ? 24 : 152
      link  = rows.empty? ? [{ 'xAxisIndex' => 'all' }] : [{ 'xAxisIndex' => [0, 1, 2] }]

      ratio_series = {
        'name' => 'ratio', 'type' => 'line', 'xAxisIndex' => 0, 'yAxisIndex' => 0,
        'showSymbol' => true, 'symbol' => 'circle', 'symbolSize' => 7, # a 1-entry ledger must still show as a filled dot
        'data' => ratio, 'markLine' => envelope_lines(env)
      }
      unless ratio.empty?
        ratio_series['markPoint'] = {
          'symbol' => 'pin', 'symbolSize' => 40,
          'data' => [{ 'coord' => ratio.last, 'value' => format('%.3f', ratio.last[1].to_f) }]
        }
      end

      titles = [{
        'text' => format('LPPL %s %+.2f', latest['verdict'].to_s,
                        latest['composite'].to_f),
        'textStyle' => { 'fontSize' => 13 }
      }]
      note = trough_note(fit)
      if note
        # left-anchored over the Z panel: the shadow scoreboard now owns
        # the right margin, so a right-flush note would collide with it.
        titles << { 'text' => note, 'top' => '62%', 'left' => 66,
                    'textStyle' => { 'fontSize' => 11, 'fontWeight' => 'normal',
                                     'color' => '#6b7178' } }
      end

      opt = {
        # the renderer inits with the ECharts DARK THEME (professionally
        # tuned text/legend/axis colors incl. dim-inactive legend states);
        # transparent bg lets the card surface show through
        'backgroundColor' => 'transparent',
        'title' => titles.size == 1 ? titles.first : titles,
        'tooltip' => { 'trigger' => 'axis', 'confine' => true, 'textStyle' => { 'fontSize' => 11 }, 'axisPointer' => { 'type' => 'cross' } },
        'axisPointer' => { 'link' => link },
        # three panels under a one-line title. M8-18 R7 + follow-up (owner
        # rulings 2026-08-10): denser, and ONE date axis for the whole card --
        # the panels are time-synchronized, so the two upper grids hide their
        # entire axis furniture (labels AND ticks AND line), only the bottom
        # grid draws dates; the freed pixels go into panel heights (23->25%)
        # and tighter gaps.
        'grid' => [
          { 'left' => 60, 'right' => right, 'top' => 40, 'height' => '25%' },
          { 'left' => 60, 'right' => right, 'top' => '34%', 'height' => '25%' },
          { 'left' => 60, 'right' => right, 'top' => '61%', 'height' => '25%' }
        ],
        'xAxis' => [
          { 'type' => 'time', 'gridIndex' => 0, 'axisLabel' => { 'show' => false },
            'axisTick' => { 'show' => false }, 'axisLine' => { 'show' => false } },
          { 'type' => 'time', 'gridIndex' => 1, 'axisLabel' => { 'show' => false },
            'axisTick' => { 'show' => false }, 'axisLine' => { 'show' => false } },
          { 'type' => 'time', 'gridIndex' => 2 }
        ],
        # panel names ride their axes (rotated, left gutter): at the top
        # they collided with the title row (owner review round 4)
        'yAxis' => [
          { 'type' => 'value', 'gridIndex' => 0, 'name' => 'ratio',
            'nameLocation' => 'middle', 'nameGap' => 44 },
          { 'type' => 'value', 'gridIndex' => 1, 'name' => 'log10 BF',
            'nameLocation' => 'middle', 'nameGap' => 44 },
          { 'type' => 'value', 'gridIndex' => 2, 'name' => 'Z',
            'nameLocation' => 'middle', 'nameGap' => 44 }
        ],
        'series' => [
          ratio_series,
          { 'name' => 'log10 BF', 'type' => 'line', 'xAxisIndex' => 1,
            'yAxisIndex' => 1, 'showSymbol' => true, 'symbol' => 'circle', 'symbolSize' => 7, 'data' => bf,
            'markLine' => { 'symbol' => 'none', 'silent' => true,
                            'data' => [{ 'yAxis' => 0,
                                         'lineStyle' => { 'type' => 'dashed',
                                                          'color' => '#9aa0a6' } }] } },
          { 'name' => 'Z', 'type' => 'line', 'xAxisIndex' => 2, 'yAxisIndex' => 2,
            'showSymbol' => true, 'symbol' => 'circle', 'symbolSize' => 7, 'data' => z }
        ]
      }
      lppl_attach_shadow(opt, rows)
      opt
    end

    # ---- M9-11 shadow scoreboard --------------------------------------
    #
    # The Phase-9 shadow fields (waves 1-2) surface as a compact right-side
    # scoreboard on the LPPL card: one row per shadow-vs-frozen comparison
    # (frozen value then shadow value) so the D9 rulings can be made with
    # the numbers in front of the owner during the soak. Values flow
    # additively through the lppl:latest payload the publish already
    # carries into chart:lppl_regime. Read DEFENSIVELY -- a missing shadow
    # field drops that ROW (fail-soft; never a null drawn), and with no
    # shadow fields at all the card degrades to its pre-M9-11 three-panel
    # form (see lppl_regime's `right`/`link`). Numbers are scaled/compacted
    # at build time per the design system (leading-zero strip, a '->' arrow
    # glyph for frozen -> shadow). Each row names its decision item in the
    # card help (D9-b/c/e/f/g).

    # ".24" not "0.24" -- probabilities/ratios read compact (design ruling).
    def lppl_compact(value, dp)
      format("%.#{dp}f", value.to_f).sub(/\A(-?)0\./, '\1.')
    end

    # [label, value] pairs for PRESENT shadow fields only (a missing field
    # drops its row). Order = top-to-bottom on the card.
    def lppl_shadow_rows(latest)
      trend = lppl_detail(latest, 'trend') || {}
      env   = lppl_detail(latest, 'envelope') || {}
      fit   = lppl_detail(latest, 'fit') || {}
      lp    = lppl_detail(latest, 'logperiodic') || {}
      rows  = []

      # (D9-b) density-honest trend: the per-evaluation-point mean summed
      # across the three headline horizons -- the density-invariant analog
      # of the frozen trailing-1y BF the BF panel already draws.
      ph = trend['per_horizon']
      if ph.is_a?(Hash)
        means = %w[30 90 180].map { |h| ph.dig(h, 'mean_per_eval') }
        rows << ['mean/eval', format('%.2f', means.sum)] unless means.any?(&:nil?)
      end

      # (D9-c) report-only long horizons: the 365d/730d per-eval means.
      pl = trend['per_horizon_long']
      if pl.is_a?(Hash)
        a = pl.dig('365', 'mean_per_eval')
        b = pl.dig('730', 'mean_per_eval')
        rows << ['365/730', format('%+.2f/%+.2f', a, b)] if a && b
      end

      # (D9-e) fit damping condition D = m|B|/(omega|C|) against its
      # threshold -- '<1' means the anti-bubble damping condition is unmet.
      if (d = fit['damping'])
        thr = fit['damping_ref_threshold'] || 1.0
        rel = d < thr ? '<' : "≥"
        rows << ['damping', format('%.2f (%s%g)', d, rel, thr)]
      end

      # (D9-e) frozen RMSE improvement vs the symmetric-null improvement.
      if (iv = fit['improvement_v2']) && (fr = fit['rmse_impr_pct'])
        rows << ['impr', format("%.1f→%.1f%%", fr, iv)]
      end

      # (D9-f) AR(1) vs GARCH bootstrap p-value for the oscillation.
      if (pv = lp['p_value_v2']) && (fp = lp['p_value'])
        rows << ['p(osc)', "#{lppl_compact(fp, 2)}→#{lppl_compact(pv, 2)}"]
      end

      # (D9-g) live envelope bound vs the pre-trough freeze candidate.
      if (fc = env['freeze_candidate']) && (bd = env['bound'])
        rows << ['freeze', "#{lppl_compact(bd, 3)}→#{lppl_compact(fc, 3)}"]
      end

      rows
    end

    # Append the shadow scoreboard (a 4th grid on the right) to a built
    # lppl_regime option, in place. No-op when there are no shadow rows so
    # the card degrades to its pre-M9-11 three-panel form. The row NAMES
    # ride the category y-axis (right-aligned in the gutter, like the
    # scenario module strip); the VALUES are per-datum labels on an
    # invisible scatter, left-anchored at x=0 in the column. 'silent' + the
    # excluded axisPointer link keep the column out of the crosshair.
    def lppl_attach_shadow(opt, rows)
      return opt if rows.empty?

      # a COMPACT block top-right (density beats airy, owner ruling): the
      # rows cluster below the 'shadow' header rather than spreading full
      # height, so they read as one scoreboard and never imply a row is an
      # annotation of the panel beside it.
      opt['grid'] << { 'right' => 10, 'width' => 78, 'top' => 62, 'height' => 176 }
      opt['xAxis'] << { 'type' => 'value', 'gridIndex' => 3, 'min' => 0, 'max' => 1,
                        'show' => false }
      opt['yAxis'] << {
        'type' => 'category', 'gridIndex' => 3, 'inverse' => true,
        'data' => rows.map(&:first), 'name' => 'shadow', 'nameLocation' => 'start',
        'nameGap' => 12, 'nameTextStyle' => { 'color' => '#8a93a0', 'fontSize' => 11 },
        'axisLine' => { 'show' => false }, 'axisTick' => { 'show' => false },
        'axisLabel' => { 'interval' => 0, 'fontSize' => 11, 'color' => '#9aa0a6' }
      }
      opt['series'] << {
        'name' => 'shadow', 'type' => 'scatter', 'xAxisIndex' => 3, 'yAxisIndex' => 3,
        'symbolSize' => 0, 'silent' => true,
        'data' => rows.each_index.map do |i|
          { 'value' => [0, i],
            'label' => { 'show' => true, 'position' => 'right', 'align' => 'left',
                         'formatter' => rows[i][1], 'fontSize' => 11, 'color' => '#c7ccd1' } }
        end
      }
      opt
    end

    # [ts, value] pairs for a ledger field, dropping entries whose value is
    # null (a dead point must not zero a panel or break the time axis).
    def ledger_series(entries, field)
      entries.filter_map { |e| [e['ts'], e[field]] unless e[field].nil? }
    end

    def lppl_detail(latest, name)
      t = (latest['tests'] || []).find { |x| x['name'] == name }
      t && t['detail']
    end

    # Dashed constant lines for the current envelope bound and floor.
    def envelope_lines(env)
      data = []
      # labels at opposite ends: bound and floor are often near-equal and
      # collide into garble if both sit at the line end
      if env['bound']
        data << { 'yAxis' => env['bound'], 'lineStyle' => { 'type' => 'dashed', 'color' => '#e6a23c' },
                  'label' => { 'position' => 'insideStartTop',
                               'formatter' => format('bound %.3f', env['bound'].to_f) } }
      end
      if env['floor']
        data << { 'yAxis' => env['floor'], 'lineStyle' => { 'type' => 'dashed', 'color' => '#c63939' },
                  'label' => { 'position' => 'insideEndBottom',
                               'formatter' => format('floor %.3f', env['floor'].to_f) } }
      end
      { 'symbol' => 'none', 'silent' => true, 'data' => data }
    end

    def trough_note(fit)
      return nil unless fit['trough_date'] && fit['trough_px']

      format('trough ~%s @%s', fit['trough_date'], fit['trough_px'])
    end

    # ---- btco_table (M3-4) --------------------------------------------
    #
    # btco:latest -> labelled horizontal bars plus a stress gauge (a true
    # sortable table is not expressible in callback-free ECharts JSON).
    # Compact form (owner design review 2026-07-05): one-line 13px title
    # carries stress + band, no subtext, tight margins, gauge sized up.
    # Companies sort by BTC held, descending (largest at top via inverse
    # category axis); rows carry ' *' (placeholder) / ' STALE' (stale)
    # flags in the tick label. Two bars per row (mNAV, netNAV) with nulls
    # left as gaps; a vertical markLine marks NAV parity at 1.0. The gauge
    # (right) shows stress 0-100 in green/amber/orange/red bands with the
    # regime band as its detail text.

    def btco_table(latest)
      companies = (latest['companies'] || []).sort_by { |c| -(c['btc'] || 0).to_f }
      labels    = companies.map { |c| btco_label(c) }

      {
        # the renderer inits with the ECharts DARK THEME (professionally
        # tuned text/legend/axis colors incl. dim-inactive legend states);
        # transparent bg lets the card surface show through
        'backgroundColor' => 'transparent',
        # ' · spot stale' when BTC spot came from cache (M7-8, btco
        # 'spot_stale'): the whole NAV axis is on a stale coin price.
        # Absent on all-fresh payloads -> byte-identical golden.
        'title' => {
          'text' => format('BTCo stress %s %s%s', latest['stress'], latest['band'].to_s,
                           latest['spot_stale'] ? ' · spot stale' : ''),
          'textStyle' => { 'fontSize' => 13 }
        },
        'tooltip' => { 'trigger' => 'axis', 'confine' => true, 'textStyle' => { 'fontSize' => 11 }, 'axisPointer' => { 'type' => 'shadow' } },
        'legend' => { 'top' => 26, 'data' => %w[mNAV netNAV] },
        'grid' => { 'left' => 100, 'right' => '32%', 'top' => 50, 'bottom' => 32 },
        'xAxis' => { 'type' => 'value', 'name' => 'x NAV' },
        'yAxis' => { 'type' => 'category', 'data' => labels, 'inverse' => true },
        'series' => [
          { 'name' => 'mNAV', 'type' => 'bar', 'itemStyle' => { 'color' => '#0f7a5c' },
            'data' => companies.map { |c| c['mnav'] },
            'markLine' => { 'symbol' => 'none', 'silent' => true,
                            'data' => [{ 'xAxis' => 1.0,
                                         'label' => { 'formatter' => 'NAV parity' },
                                         'lineStyle' => { 'type' => 'dashed',
                                                          'color' => '#e6a23c' } }] } },
          { 'name' => 'netNAV', 'type' => 'bar', 'itemStyle' => { 'color' => '#6aa9ff' },
            'data' => companies.map { |c| c['net_mnav'] } },
          { 'name' => 'stress', 'type' => 'gauge', 'min' => 0, 'max' => 100,
            'center' => ['84%', '56%'], 'radius' => '48%',
            # 290px card (renderer height hook): 10 tick labels crowd and
            # overlap at the dial top -- 5 coarser ticks, smaller labels
            'splitNumber' => 5,
            'axisLabel' => { 'fontSize' => 9, 'distance' => 12 },
            'axisLine' => { 'lineStyle' => { 'width' => 14, 'color' => [
              [0.25, '#0f7a5c'], [0.5, '#e6a23c'], [0.75, '#e08e0b'], [1, '#c63939']
            ] } },
            'pointer' => { 'width' => 4 },
            # series title hidden (owner report 2026-07-06): at any inner
            # offset it collides with the tick labels, and 'stress' is
            # already carried by the chart title + the band detail text
            'title' => { 'show' => false },
            'detail' => { 'formatter' => latest['band'].to_s, 'fontSize' => 14,
                          'offsetCenter' => [0, '72%'] },
            'data' => [{ 'value' => latest['stress'], 'name' => 'stress' }] }
        ]
      }
    end

    def btco_label(company)
      s = company['ticker'].to_s
      s += ' *' if company['placeholder']
      s += ' STALE' if company['stale']
      s
    end

    # ---- M8-6 shared palette + scalers --------------------------------
    # Vol charts use the TEXT-weight palette anchors (brighter than the bar
    # anchors) since these are line/skew charts read against the dark card.
    VOL_TEAL  = '#2fbf8f' # ATM IV / call wall lines
    VOL_RED   = '#ef6b6b' # RR25 / put wall lines
    VOL_AMBER = '#e6a23c' # FLY25 / flip / basis lines
    VOL_MSTR  = '#d0d5db' # MSTR leg (brighter)
    VOL_BTC   = '#7a828c' # BTC leg (dimmer)
    VOL_SPOT  = '#d7dce3' # spot level line
    VOL_GREY  = '#6b7178' # invisible carriers / notes

    # vol.rb emits IV/skew as decimal fractions (0.4388 = 43.88%). Scale to
    # the human unit at BUILD time (owner ruling) so axes/tooltips need no
    # client formatting; a nil leg stays nil (an omitted point, never zero).
    def vol_pct(frac)
      frac.nil? ? nil : (frac.to_f * 100).round(2)
    end

    # ---- vol_surface (M8-6) -------------------------------------------
    #
    # vol:latest -> the implied-vol term structure at the three requested
    # tenors. Compact one-line 13px title carries the 30d ATM level. Left
    # axis = ATM IV (%), right axis = the 25-delta skew in vol points (RR25
    # risk reversal, FLY25 butterfly). The nominal tenor's ACTUAL option
    # expiry rides an invisible carrier line (yAxisIndex 2, a hidden axis)
    # so it shows in the axis tooltip as exp(d) -- the gex aggregate-line
    # idiom, pure JSON, no renderer formatter. A tenor whose leg failed
    # (reason set) is an OMITTED point (nil), not a zero.
    #
    # M8-17: vol_surface (BTC) and vol_surface_mstr (MSTR) are the SAME
    # option body with a different title -- they share tab_pos 0 so the
    # renderer tabs them into one SURFACE section. The shared body is
    # vol_surface_option; the two public builders only pick the title
    # prefix, keeping the existing vol_surface golden byte-identical
    # (format('%s · ATM %s','Vol surface',head) == the old literal).
    def vol_surface(vol)
      vol_surface_option(vol, 'Vol surface')
    end

    # MSTR sibling (reads vol:mstr) -- identical body, MSTR title.
    def vol_surface_mstr(vol)
      vol_surface_option(vol, 'MSTR vol surface')
    end

    def vol_surface_option(vol, title_prefix)
      tenors = vol['tenors'] || []
      labels = tenors.map { |t| "#{t['tenor_d']}d" }
      atm    = tenors.map { |t| vol_pct(t['atm_iv']) }
      rr     = tenors.map { |t| vol_pct(t['rr25']) }
      fly    = tenors.map { |t| vol_pct(t['fly25']) }
      expiry = tenors.map { |t| t['expiry_d']&.to_f&.round }
      head   = vol_atm_headline(tenors)

      {
        'backgroundColor' => 'transparent',
        'title' => { 'text' => format('%s · ATM %s', title_prefix, head),
                     'textStyle' => { 'fontSize' => 13 } },
        'tooltip' => { 'trigger' => 'axis', 'confine' => true,
                       'textStyle' => { 'fontSize' => 11 } },
        'legend' => { 'top' => 24, 'data' => %w[ATM\ IV RR25 FLY25] },
        'grid' => { 'left' => 56, 'right' => 56, 'top' => 52, 'bottom' => 28 },
        'xAxis' => { 'type' => 'category', 'data' => labels },
        'yAxis' => [
          # names ride the axes (rotated, in the gutters) so they never land
          # in the one-line title row (owner review round 4)
          { 'type' => 'value', 'name' => 'ATM IV %', 'position' => 'left',
            'nameLocation' => 'middle', 'nameGap' => 44 },
          { 'type' => 'value', 'name' => 'vol pts', 'position' => 'right',
            'nameLocation' => 'middle', 'nameGap' => 40 },
          # hidden carrier axis for exp(d): its ~355 range must not distort
          # the ATM/skew axes, so it draws nothing.
          { 'type' => 'value', 'show' => false }
        ],
        'series' => [
          { 'name' => 'ATM IV', 'type' => 'line', 'yAxisIndex' => 0,
            'symbol' => 'circle', 'symbolSize' => 7, # sparse: a filled dot must read
            'itemStyle' => { 'color' => VOL_TEAL }, 'lineStyle' => { 'color' => VOL_TEAL },
            'data' => atm },
          { 'name' => 'RR25', 'type' => 'line', 'yAxisIndex' => 1,
            'symbol' => 'circle', 'symbolSize' => 7,
            'itemStyle' => { 'color' => VOL_RED }, 'lineStyle' => { 'color' => VOL_RED },
            'data' => rr },
          { 'name' => 'FLY25', 'type' => 'line', 'yAxisIndex' => 1,
            'symbol' => 'circle', 'symbolSize' => 7,
            'itemStyle' => { 'color' => VOL_AMBER }, 'lineStyle' => { 'color' => VOL_AMBER },
            'data' => fly },
          # invisible carrier: adds an "exp(d): <days>" row to the axis
          # tooltip without a drawn line or a legend entry.
          { 'name' => 'exp(d)', 'type' => 'line', 'yAxisIndex' => 2, 'silent' => true,
            'symbol' => 'none', 'lineStyle' => { 'opacity' => 0 },
            'itemStyle' => { 'color' => VOL_GREY }, 'data' => expiry }
        ]
      }
    end

    # Title tail 'ATM <tenor>d <pct>%': prefer the 30d ATM; on a null 30d
    # fall back to the first tenor with a live ATM (labelled with ITS tenor,
    # never a misleading 30d); 'n/a' when the whole surface is empty.
    def vol_atm_headline(tenors)
      t = tenors.find { |x| x['tenor_d'] == 30 && !x['atm_iv'].nil? } ||
          tenors.find { |x| !x['atm_iv'].nil? }
      return 'n/a' unless t

      format('%dd %.1f%%', t['tenor_d'], vol_pct(t['atm_iv']))
    end

    # ---- vol_spread (M8-6) --------------------------------------------
    #
    # vol:spread -> MSTR-minus-BTC ATM implied vol per tenor (the live price
    # of treasury-company leverage). Bars = the spread in vol points (teal
    # positive / red negative, per bar); two thin lines = each leg's raw ATM
    # IV (MSTR brighter, BTC dimmer) so a move is attributable. One shared
    # vol-% axis: the bar height reads against each leg's absolute level. A
    # failed leg drops its line and that tenor's bar (nil, never zero).
    def vol_spread(spread)
      tenors = spread['tenors'] || []
      labels = tenors.map { |t| "#{t['tenor_d']}d" }
      bars   = tenors.map do |t|
        v = vol_pct(t['spread_atm'])
        v.nil? ? nil : { 'value' => v, 'itemStyle' => { 'color' => v.negative? ? GEX_RED : GEX_TEAL } }
      end
      mstr = tenors.map { |t| vol_pct(t.dig('mstr', 'atm_iv')) }
      btc  = tenors.map { |t| vol_pct(t.dig('btc', 'atm_iv')) }

      {
        'backgroundColor' => 'transparent',
        'title' => { 'text' => format('MSTR-BTC IV · %s', vol_spread_headline(tenors)),
                     'textStyle' => { 'fontSize' => 13 } },
        'tooltip' => { 'trigger' => 'axis', 'confine' => true,
                       'textStyle' => { 'fontSize' => 11 } },
        'legend' => { 'top' => 24, 'data' => %w[spread MSTR BTC] },
        'grid' => { 'left' => 56, 'right' => 24, 'top' => 52, 'bottom' => 28 },
        'xAxis' => { 'type' => 'category', 'data' => labels },
        'yAxis' => { 'type' => 'value', 'name' => 'vol %',
                     'nameLocation' => 'middle', 'nameGap' => 44 },
        'series' => [
          # series-level teal so the legend swatch matches the (positive)
          # bars; per-bar itemStyle still overrides negatives to red.
          { 'name' => 'spread', 'type' => 'bar', 'itemStyle' => { 'color' => GEX_TEAL },
            'data' => bars },
          { 'name' => 'MSTR', 'type' => 'line', 'symbol' => 'circle', 'symbolSize' => 6,
            'itemStyle' => { 'color' => VOL_MSTR }, 'lineStyle' => { 'color' => VOL_MSTR, 'width' => 1 },
            'data' => mstr },
          { 'name' => 'BTC', 'type' => 'line', 'symbol' => 'circle', 'symbolSize' => 6,
            'itemStyle' => { 'color' => VOL_BTC }, 'lineStyle' => { 'color' => VOL_BTC, 'width' => 1 },
            'data' => btc }
        ]
      }
    end

    # Title tail '<tenor>d <+spread>': prefer 30d, else the first live spread.
    def vol_spread_headline(tenors)
      t = tenors.find { |x| x['tenor_d'] == 30 && !x['spread_atm'].nil? } ||
          tenors.find { |x| !x['spread_atm'].nil? }
      return 'n/a' unless t

      format('%dd %+.1f', t['tenor_d'], vol_pct(t['spread_atm']))
    end

    # ---- vol_spread_trend (M8-16) -------------------------------------
    #
    # vol:spread's daily "history" -> the MSTR-minus-BTC ATM spread over
    # time, one line per tenor (7/14/21/45/90d). Stacked BELOW the
    # vol_spread bars (owner ruling 2026-08-10): the bars are the current
    # term structure, this is its trend. Values are vol points
    # (spread_atm * 100, 1dp) scaled at build time (design system); a null
    # spread on a date is a gap (nil), never a zero. Filled dots
    # (sparse-data rule) so a single live day reads as a clear point. The
    # dark theme colours the five series (no semantic pair to preserve).
    # Empty history still yields a valid option (empty axis + 5 empty
    # series) -- the acceptable pre-accumulation state.
    VOL_SPREAD_TREND_TENORS = [7, 14, 21, 45, 90].freeze

    def vol_spread_trend(spread)
      history = spread['history'] || []
      dates   = history.map { |r| r['date'] }
      series  = VOL_SPREAD_TREND_TENORS.map do |td|
        { 'name' => "#{td}d", 'type' => 'line', 'symbol' => 'circle', 'symbolSize' => 6,
          'data' => history.map { |r| vol_spread_trend_point(r, td) } }
      end

      {
        'backgroundColor' => 'transparent',
        'title' => { 'text' => format('Spread trend · %dd history', dates.size),
                     'textStyle' => { 'fontSize' => 13 } },
        'tooltip' => { 'trigger' => 'axis', 'confine' => true,
                       'textStyle' => { 'fontSize' => 11 } },
        'legend' => { 'top' => 24, 'data' => VOL_SPREAD_TREND_TENORS.map { |td| "#{td}d" } },
        'grid' => { 'left' => 56, 'right' => 24, 'top' => 52, 'bottom' => 28 },
        'xAxis' => { 'type' => 'category', 'data' => dates },
        'yAxis' => { 'type' => 'value', 'name' => 'spread vol pts',
                     'nameLocation' => 'middle', 'nameGap' => 44 },
        'series' => series
      }
    end

    # The scaled spread (vol points, 1dp) for tenor +td+ on one history row,
    # or nil when that tenor is absent or its spread is null (a gap, never a
    # zero).
    def vol_spread_trend_point(row, td)
      t = (row['tenors'] || []).find { |x| x['tenor_d'] == td }
      return nil unless t && !t['spread_atm'].nil?

      (t['spread_atm'].to_f * 100).round(1)
    end

    # ---- vol_basis (M8-6) ---------------------------------------------
    #
    # basis:latest -> the annualized basis of each dated BTC future over
    # spot (amber line, filled dots) with a 0 markLine, plus the perpetual
    # funding rate on the title. Sub-1-day tenors are omitted (their
    # annualized number is a microstructure artifact). The funding 1d/7d/30d
    # means ride a small secondary title note (the lppl trough-note idiom) --
    # on the chart, dynamic, not an extra series. A dead futures leg leaves
    # the line empty; funding still shows.
    def vol_basis(basis)
      b      = basis['basis'] || {}
      f      = basis['funding'] || {}
      tenors = (b['tenors'] || []).select { |t| t['days'].to_f >= 1 }
      labels = tenors.map { |t| "#{t['days'].to_f.round}d" }
      ann    = tenors.map { |t| t['basis_ann_pct']&.to_f&.round(3) }

      titles = [{ 'text' => format('Basis ann%% · funding %s', basis_funding_head(f)),
                  'textStyle' => { 'fontSize' => 13 } }]
      note = basis_funding_note(f)
      if note
        titles << { 'text' => note, 'top' => '86%', 'right' => 12,
                    'textStyle' => { 'fontSize' => 11, 'fontWeight' => 'normal', 'color' => VOL_GREY } }
      end

      {
        'backgroundColor' => 'transparent',
        'title' => titles.size == 1 ? titles.first : titles,
        'tooltip' => { 'trigger' => 'axis', 'confine' => true,
                       'textStyle' => { 'fontSize' => 11 } },
        'grid' => { 'left' => 56, 'right' => 24, 'top' => 44, 'bottom' => 32 },
        'xAxis' => { 'type' => 'category', 'data' => labels },
        'yAxis' => { 'type' => 'value', 'name' => 'ann basis %',
                     'nameLocation' => 'middle', 'nameGap' => 44 },
        'series' => [
          { 'name' => 'ann basis', 'type' => 'line', 'symbol' => 'circle', 'symbolSize' => 7,
            'itemStyle' => { 'color' => VOL_AMBER }, 'lineStyle' => { 'color' => VOL_AMBER },
            'data' => ann,
            'markLine' => { 'symbol' => 'none', 'silent' => true,
                            'data' => [{ 'yAxis' => 0,
                                         'label' => { 'formatter' => '0' },
                                         'lineStyle' => { 'type' => 'dashed', 'color' => '#9aa0a6' } }] } }
        ]
      }
    end

    # Title funding token '<pct>%/8h' (funding.latest_pct is already %/8h),
    # or 'n/a' when the funding leg is down.
    def basis_funding_head(funding)
      funding['latest_pct'].nil? ? 'n/a' : format('%.3f%%/8h', funding['latest_pct'].to_f)
    end

    # Secondary note with the 1d/7d/30d funding means, or nil when the leg is
    # down (nothing to note).
    def basis_funding_note(funding)
      return nil if funding['latest_pct'].nil?

      format('funding 1d %.3f · 7d %.3f · 30d %.3f (%%/8h)',
             funding['d1_pct'].to_f, funding['d7_pct'].to_f, funding['d30_pct'].to_f)
    end

    # ---- gex_trend (M8-6) ---------------------------------------------
    #
    # gex:trend (+ gex:check for the cross-check suffix) -> the daily GEX
    # snapshot levels over time: spot (white), gamma flip (amber), call wall
    # (teal), put wall (red), all as BTC price in $k with filled dots
    # (sparse history). The title carries flip-distance-last, the regime run
    # length, and -- when the Coinglass cross-check is present -- MP Delta
    # (spot vs their nearest max-pain). gex:check absent/null omits only the
    # suffix; the chart still renders.
    def gex_trend(trend, check = nil)
      rows   = trend['series'] || []
      stats  = trend['stats'] || {}
      labels = rows.map { |r| gex_trend_day(r['date']) }

      {
        'backgroundColor' => 'transparent',
        'title' => { 'text' => gex_trend_title(stats, check),
                     'textStyle' => { 'fontSize' => 13 } },
        'tooltip' => { 'trigger' => 'axis', 'confine' => true,
                       'textStyle' => { 'fontSize' => 11 } },
        'legend' => { 'top' => 24, 'data' => %w[spot flip CW PW] },
        'grid' => { 'left' => 56, 'right' => 24, 'top' => 52, 'bottom' => 28 },
        'xAxis' => { 'type' => 'category', 'data' => labels },
        'yAxis' => { 'type' => 'value', 'name' => 'price ($k)', 'scale' => true,
                     'nameLocation' => 'middle', 'nameGap' => 44 },
        'series' => [
          gex_trend_line('spot', rows, 'spot', VOL_SPOT),
          gex_trend_line('flip', rows, 'flip', VOL_AMBER),
          gex_trend_line('CW',   rows, 'cw',   VOL_TEAL),
          gex_trend_line('PW',   rows, 'pw',   VOL_RED)
        ]
      }
    end

    # A price-level line with filled dots (sparse-data rule); nil levels stay
    # gaps. +scale+ divides the raw level into the display unit -- 1000 for the
    # BTC trend ($k), 1 for the MSTR trend (raw dollars, ~$100-400).
    def gex_trend_line(name, rows, field, color, scale = 1000.0)
      { 'name' => name, 'type' => 'line', 'symbol' => 'circle', 'symbolSize' => 7,
        'itemStyle' => { 'color' => color }, 'lineStyle' => { 'color' => color },
        'data' => rows.map { |r| r[field] && (r[field].to_f / scale).round(2) } }
    end

    # 'YYYY-MM-DD' -> 'MM-DD' (compact category label); pass anything else
    # through untouched.
    def gex_trend_day(date)
      m = /\A\d{4}-(\d{2}-\d{2})\z/.match(date.to_s)
      m ? m[1] : date.to_s
    end

    # 'GEX trend · flip dist <+d>% · <n>d <regime>' plus, when the cross-check
    # is present, ' · MP Δ<+d>%' (spot vs Coinglass nearest max-pain).
    def gex_trend_title(stats, check)
      dist = stats['flip_dist_pct_last']
      base = format('GEX trend · flip dist %s · %dd %s',
                    dist.nil? ? 'n/a' : format('%+.2f%%', dist.to_f),
                    stats['regime_days'].to_i, stats['regime'].to_s)
      mp = check && check['deltas'] && check['deltas']['nearest_vs_spot_pct']
      mp.nil? ? base : base + format(' · MP Δ%+.2f%%', mp.to_f)
    end

    # ---- gex_mstr_trend (M8-18) ---------------------------------------
    #
    # gex:trend's additive 'mstr' block -> the daily MSTR GEX snapshot levels
    # over time: spot (white), gamma flip (amber), call wall (teal), put wall
    # (red), as MSTR price in RAW DOLLARS (~$100-400, so NOT $k-scaled like the
    # BTC trend) with filled dots (sparse history). Mirrors gex_trend's grammar
    # (four price lines, one-line title carrying flip-distance-last + regime run
    # length) but on MSTR's own axis and with NO max-pain cross-check (that is
    # BTC-only). An absent/empty 'mstr' block still yields a valid option.
    def gex_mstr_trend(trend)
      mstr   = trend['mstr'] || {}
      rows   = mstr['series'] || []
      stats  = mstr['stats'] || {}
      labels = rows.map { |r| gex_trend_day(r['date']) }

      {
        'backgroundColor' => 'transparent',
        'title' => { 'text' => gex_mstr_trend_title(stats),
                     'textStyle' => { 'fontSize' => 13 } },
        'tooltip' => { 'trigger' => 'axis', 'confine' => true,
                       'textStyle' => { 'fontSize' => 11 } },
        'legend' => { 'top' => 24, 'data' => %w[spot flip CW PW] },
        'grid' => { 'left' => 56, 'right' => 24, 'top' => 52, 'bottom' => 28 },
        'xAxis' => { 'type' => 'category', 'data' => labels },
        'yAxis' => { 'type' => 'value', 'name' => 'price ($)', 'scale' => true,
                     'nameLocation' => 'middle', 'nameGap' => 44 },
        'series' => [
          gex_trend_line('spot', rows, 'spot', VOL_SPOT, 1.0),
          gex_trend_line('flip', rows, 'flip', VOL_AMBER, 1.0),
          gex_trend_line('CW',   rows, 'cw',   VOL_TEAL, 1.0),
          gex_trend_line('PW',   rows, 'pw',   VOL_RED, 1.0)
        ]
      }
    end

    # 'MSTR GEX trend · flip dist <+d>% · <n>d <regime>' -- no cross-check tail
    # (max-pain is a BTC-only check).
    def gex_mstr_trend_title(stats)
      dist = stats['flip_dist_pct_last']
      format('MSTR GEX trend · flip dist %s · %dd %s',
             dist.nil? ? 'n/a' : format('%+.2f%%', dist.to_f),
             stats['regime_days'].to_i, stats['regime'].to_s)
    end
  end
end
