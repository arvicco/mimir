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
    CHARTS = {
      'gex_profile' => { inputs: %w[payload_gex_combined.json], fn: :gex_profile }
      # scenario_strip / lppl_regime / btco_table join here (M3-2..4)
    }.freeze

    module_function

    # gex:combined payload -> per-level put/call bars stacked by venue,
    # flip + wall markLines, BTC category axis, venue toggle via legend.
    def gex_profile(gex)
      venues  = gex['profiles'].keys
      levels  = gex['profiles'].values.flat_map(&:keys).uniq
                   .sort_by { |k| k.to_i }
      labels  = levels.map { |l| level_label(l) }
      series  = venue_series(gex, venues, levels)
      series.first['markLine'] = mark_lines(gex, levels) if series.first

      {
        'title' => {
          'text' => 'BTC combined GEX',
          'subtext' => format('spot %s · $ per 1%% move per level · %s',
                              level_label(gex['btc_spot'].to_i), gex['ts'].to_s)
        },
        'tooltip' => { 'trigger' => 'axis', 'axisPointer' => { 'type' => 'shadow' } },
        'legend' => { 'type' => 'scroll', 'top' => 44 },
        'grid' => { 'left' => 80, 'right' => 30, 'top' => 96, 'bottom' => 60 },
        'xAxis' => { 'type' => 'category', 'data' => labels,
                     'name' => 'BTC level', 'nameLocation' => 'middle',
                     'nameGap' => 34 },
        'yAxis' => { 'type' => 'value', 'name' => 'GEX $/1%' },
        # all levels stay in the data; the default window shows the
        # +-30% band around spot (deep-OTM tails reachable by zoom-out)
        'dataZoom' => [
          { 'type' => 'inside',
            'startValue' => nearest_label(levels, gex['btc_spot'].to_f * 0.7),
            'endValue' => nearest_label(levels, gex['btc_spot'].to_f * 1.3) },
          { 'type' => 'slider', 'height' => 18 }
        ],
        'series' => series
      }
    end

    # ---- gex_profile internals ----------------------------------------

    def level_label(level)
      v = level.to_i
      (v % 1000).zero? ? "#{v / 1000}k" : format('%.1fk', v / 1000.0)
    end

    def venue_series(gex, venues, levels)
      venues.each_with_index.flat_map do |venue, i|
        per = gex['profiles'][venue]
        [{ 'name' => "#{venue} calls", 'type' => 'bar', 'stack' => 'calls',
           'itemStyle' => { 'color' => shade('calls', i, venues.size) },
           'data' => levels.map { |l| per.dig(l, 'call').to_i } },
         { 'name' => "#{venue} puts", 'type' => 'bar', 'stack' => 'puts',
           'itemStyle' => { 'color' => shade('puts', i, venues.size) },
           'data' => levels.map { |l| per.dig(l, 'put').to_i } }]
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
  end
end
