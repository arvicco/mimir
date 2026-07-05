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
# (positional args, in order) + builder function.
#
# No IO, no ENV, no network in this file.

module Publish
  module Charts
    # meta (additive envelope field, 2026-07-05): METHODOLOGY-grade
    # hover help rendered by preview.html/the dashboard -- desc for the
    # title bubble, axes + help behind the info affordance.
    CHARTS = {
      'gex_profile' => {
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
          'help' => 'Legend right: one C (calls, teal) and P (puts, red) ' \
                    'toggle per venue, DERI = Deribit; venues with no open ' \
                    'interest are omitted. Hover a level: the C/P rows on ' \
                    'top are cross-venue aggregates. Lines: flip = net-GEX ' \
                    'zero crossing, CW/PW = biggest call/put walls.'
        }
      },
      'scenario_strip' => {
        inputs: %w[payload_scenario_latest.json payload_scenario_history.json],
        fn: :scenario_strip
      },
      'lppl_regime' => {
        inputs: %w[payload_lppl_latest.json payload_lppl_ledger.json],
        fn: :lppl_regime
      },
      'btco_table' => { inputs: %w[payload_btco_latest.json], fn: :btco_table }
    }.freeze

    module_function

    # gex:combined payload -> per-level put/call bars stacked by venue.
    # Compact form (owner design review 2026-07-05): venues with no data
    # at all are OMITTED, values are $M, the hover bubble leads with the
    # cross-venue C/P aggregates (as two invisible line series ordered
    # first), the legend sits right of the plot as stacked C/P toggles
    # per venue (DERI = Deribit), no slider (inside zoom only).
    def gex_profile(gex)
      venues = gex['profiles'].select { |_, per|
        per.values.any? { |s| s['call'].to_i != 0 || s['put'].to_i != 0 }
      }.keys
      levels = venues.flat_map { |v| gex['profiles'][v].keys }.uniq
                     .sort_by { |k| k.to_i }
      labels = levels.map { |l| level_label(l) }
      bars   = venue_series(gex, venues, levels)
      series = aggregate_series(gex, venues, levels) + bars
      bars.first['markLine'] = mark_lines(gex, levels) if bars.first

      {
        'title' => { 'text' => format('GEX $M/1%% · spot %s',
                                      level_label(gex['btc_spot'].to_i)),
                     'textStyle' => { 'fontSize' => 13 } },
        'tooltip' => { 'trigger' => 'axis', 'axisPointer' => { 'type' => 'shadow' } },
        'legend' => { 'orient' => 'vertical', 'right' => 2, 'top' => 26,
                      'data' => bars.map { |s| s['name'] },
                      'itemWidth' => 12, 'itemHeight' => 8, 'itemGap' => 3,
                      'textStyle' => { 'fontSize' => 11 } },
        'grid' => { 'left' => 52, 'right' => 92, 'top' => 30, 'bottom' => 26 },
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

    def venue_series(gex, venues, levels)
      venues.each_with_index.flat_map do |venue, i|
        per = gex['profiles'][venue]
        [{ 'name' => "#{venue_label(venue)} C", 'type' => 'bar', 'stack' => 'calls',
           'itemStyle' => { 'color' => shade('calls', i, venues.size) },
           'data' => levels.map { |l| musd(per.dig(l, 'call').to_i) } },
         { 'name' => "#{venue_label(venue)} P", 'type' => 'bar', 'stack' => 'puts',
           'itemStyle' => { 'color' => shade('puts', i, venues.size) },
           'data' => levels.map { |l| musd(per.dig(l, 'put').to_i) } }]
      end
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
    # nearest bucketed level so they land on the category axis.
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
                   'label' => { 'formatter' => 'CW' },
                   'lineStyle' => { 'color' => '#0f7a5c', 'type' => 'dashed' } }
      end
      if c['put_wall']
        lines << { 'xAxis' => nearest_label(levels, c['put_wall']['level']),
                   'label' => { 'formatter' => 'PW' },
                   'lineStyle' => { 'color' => '#c63939', 'type' => 'dashed' } }
      end
      { 'symbol' => 'none', 'data' => lines }
    end

    def nearest_label(levels, value)
      level_label(levels.min_by { |l| (l.to_i - value.to_i).abs })
    end

    # ---- scenario_strip (M3-2) ----------------------------------------
    #
    # scenario:latest + scenario:history -> a two-grid strip. Top grid is
    # the composite path (history entries on a time axis, fixed [-1, 1]);
    # dashed markLines mark the four regime boundaries and label the five
    # bands on the right. Bottom grid is a one-row heatmap of the CURRENT
    # seven module scores, coloured by a hidden piecewise visualMap
    # (-1 red / 0 grey / +1 teal). Degenerate-safe: a single history point
    # renders as one symbol, no ratios or windows are computed.

    # Regime boundaries and the band each interval maps to (band label is
    # anchored at the interval midpoint so it rides beside its zone).
    SCN_THRESHOLDS = [-0.40, -0.10, 0.10, 0.40].freeze
    SCN_BANDS = [[-0.70, 'FLUSH'], [-0.25, 'LEAN-FLUSH'], [0.0, 'NEUTRAL'],
                 [0.25, 'BASE'], [0.70, 'RECOVERY']].freeze

    def scenario_strip(latest, history)
      modules  = latest['modules'] || []
      names    = modules.map { |m| m['mod'] }
      comp     = (history['entries'] || []).map { |e| [e['ts'], e['composite']] }
      heat     = modules.each_with_index.map { |m, i| [i, 0, m['score']] }

      {
        'title' => {
          'text' => 'Scenario composite',
          'subtext' => format('%s · composite %+.3f · %s', latest['regime'].to_s,
                              latest['composite'].to_f, latest['ts'].to_s)
        },
        'tooltip' => { 'trigger' => 'axis' },
        'grid' => [
          { 'left' => 92, 'right' => 96, 'top' => 70, 'height' => '54%' },
          { 'left' => 92, 'right' => 96, 'top' => '74%', 'height' => '15%' }
        ],
        'xAxis' => [
          { 'type' => 'time', 'gridIndex' => 0 },
          { 'type' => 'category', 'gridIndex' => 1, 'data' => names,
            'axisLabel' => { 'interval' => 0, 'rotate' => 30 } }
        ],
        'yAxis' => [
          { 'type' => 'value', 'gridIndex' => 0, 'min' => -1, 'max' => 1,
            'name' => 'composite' },
          { 'type' => 'category', 'gridIndex' => 1, 'data' => ['score'] }
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
            'yAxisIndex' => 0, 'showSymbol' => true, 'symbolSize' => 6,
            'lineStyle' => { 'color' => '#3b6ea5' }, 'data' => comp,
            'markLine' => scenario_bands },
          { 'name' => 'modules', 'type' => 'heatmap', 'xAxisIndex' => 1,
            'yAxisIndex' => 1, 'data' => heat,
            'label' => { 'show' => true, 'formatter' => '{@[2]}' } }
        ]
      }
    end

    # Four dashed boundary lines (numeric label on the left) plus five
    # invisible carrier lines whose only job is a right-flush band label.
    def scenario_bands
      thresholds = SCN_THRESHOLDS.map do |t|
        { 'yAxis' => t, 'lineStyle' => { 'type' => 'dashed', 'color' => '#c9ccd1' },
          'label' => { 'position' => 'start', 'formatter' => format('%+.2f', t) } }
      end
      bands = SCN_BANDS.map do |y, name|
        { 'yAxis' => y, 'lineStyle' => { 'opacity' => 0 },
          'label' => { 'position' => 'end', 'formatter' => name, 'color' => '#6b7178' } }
      end
      { 'symbol' => 'none', 'silent' => true, 'data' => thresholds + bands }
    end

    # ---- lppl_regime (M3-3) -------------------------------------------
    #
    # lppl:latest + lppl:ledger -> three time-aligned panels of the
    # EVIDENCE trajectory (the published payloads carry no price series, so
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

      ratio_series = {
        'name' => 'ratio', 'type' => 'line', 'xAxisIndex' => 0, 'yAxisIndex' => 0,
        'showSymbol' => true, 'data' => ratio, 'markLine' => envelope_lines(env)
      }
      unless ratio.empty?
        ratio_series['markPoint'] = {
          'symbol' => 'pin', 'symbolSize' => 40,
          'data' => [{ 'coord' => ratio.last, 'value' => format('%.3f', ratio.last[1].to_f) }]
        }
      end

      titles = [{
        'text' => 'LPPL evidence',
        'subtext' => format('%s · composite %+.2f · %s', latest['verdict'].to_s,
                            latest['composite'].to_f, latest['ts'].to_s)
      }]
      note = trough_note(fit)
      if note
        titles << { 'text' => note, 'top' => '68%', 'right' => 24,
                    'textStyle' => { 'fontSize' => 11, 'fontWeight' => 'normal',
                                     'color' => '#6b7178' } }
      end

      {
        'title' => titles.size == 1 ? titles.first : titles,
        'tooltip' => { 'trigger' => 'axis', 'axisPointer' => { 'type' => 'cross' } },
        'axisPointer' => { 'link' => [{ 'xAxisIndex' => 'all' }] },
        'grid' => [
          { 'left' => 72, 'right' => 30, 'top' => 70, 'height' => '18%' },
          { 'left' => 72, 'right' => 30, 'top' => '42%', 'height' => '18%' },
          { 'left' => 72, 'right' => 30, 'top' => '68%', 'height' => '18%' }
        ],
        'xAxis' => [
          { 'type' => 'time', 'gridIndex' => 0, 'axisLabel' => { 'show' => false } },
          { 'type' => 'time', 'gridIndex' => 1, 'axisLabel' => { 'show' => false } },
          { 'type' => 'time', 'gridIndex' => 2 }
        ],
        'yAxis' => [
          { 'type' => 'value', 'gridIndex' => 0, 'name' => 'ratio' },
          { 'type' => 'value', 'gridIndex' => 1, 'name' => 'log10 BF' },
          { 'type' => 'value', 'gridIndex' => 2, 'name' => 'Z' }
        ],
        'series' => [
          ratio_series,
          { 'name' => 'log10 BF', 'type' => 'line', 'xAxisIndex' => 1,
            'yAxisIndex' => 1, 'showSymbol' => true, 'data' => bf,
            'markLine' => { 'symbol' => 'none', 'silent' => true,
                            'data' => [{ 'yAxis' => 0,
                                         'lineStyle' => { 'type' => 'dashed',
                                                          'color' => '#9aa0a6' } }] } },
          { 'name' => 'Z', 'type' => 'line', 'xAxisIndex' => 2, 'yAxisIndex' => 2,
            'showSymbol' => true, 'data' => z }
        ]
      }
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
      if env['bound']
        data << { 'yAxis' => env['bound'], 'lineStyle' => { 'type' => 'dashed', 'color' => '#e6a23c' },
                  'label' => { 'formatter' => format('bound %.3f', env['bound'].to_f) } }
      end
      if env['floor']
        data << { 'yAxis' => env['floor'], 'lineStyle' => { 'type' => 'dashed', 'color' => '#c63939' },
                  'label' => { 'formatter' => format('floor %.3f', env['floor'].to_f) } }
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
        'title' => {
          'text' => 'BTCo universe',
          'subtext' => format('%s · %s', latest['headline'].to_s, latest['ts'].to_s)
        },
        'tooltip' => { 'trigger' => 'axis', 'axisPointer' => { 'type' => 'shadow' } },
        'legend' => { 'top' => 44, 'data' => %w[mNAV netNAV] },
        'grid' => { 'left' => 120, 'right' => '34%', 'top' => 96, 'bottom' => 40 },
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
            'center' => ['84%', '58%'], 'radius' => '40%',
            'axisLine' => { 'lineStyle' => { 'width' => 14, 'color' => [
              [0.25, '#0f7a5c'], [0.5, '#e6a23c'], [0.75, '#e08e0b'], [1, '#c63939']
            ] } },
            'pointer' => { 'width' => 4 },
            'title' => { 'offsetCenter' => [0, '-40%'] },
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
  end
end
