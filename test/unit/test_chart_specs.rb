# frozen_string_literal: true

# M3-1: chart-spec builders. Two layers of pinning:
#   1. GOLDEN: each registered chart regenerates from its committed
#      payload fixtures and byte-diffs against test/golden/ -- a red
#      diff is presented for human review (preview.html), never
#      auto-blessed; `rake golden:approve` re-blesses after review.
#   2. Targeted assertions on the load-bearing structure (series
#      shape, markLines, determinism) so failures localize.

require_relative '../test_helper'
require_relative '../../publish/chart_specs'

class TestChartSpecs < Minitest::Test
  PAYLOADS = File.expand_path('../fixtures/payloads', __dir__)
  GOLDEN   = File.expand_path('../golden', __dir__)

  def build(name)
    spec = Publish::Charts::CHARTS.fetch(name)
    payloads = spec[:inputs].map { |f| JSON.parse(File.read(File.join(PAYLOADS, f))) }
    Publish::Charts.public_send(spec[:fn], *payloads)
  end

  # ---- golden harness (every registered chart) -------------------------

  Publish::Charts::CHARTS.each_key do |name|
    define_method("test_golden_#{name}") do
      golden = File.join(GOLDEN, "chart_#{name}.json")
      assert File.exist?(golden),
             "no golden for #{name} -- generate + review, then rake golden:approve"
      got = JSON.pretty_generate(build(name)) + "\n"
      assert_equal File.read(golden), got,
                   "chart '#{name}' drifted from its golden. Review the rendered " \
                   'result in preview.html; if the change is intended, re-bless ' \
                   'with rake golden:approve. NEVER approve without looking.'
    end

    define_method("test_#{name}_is_deterministic_and_json_safe") do
      a = build(name)
      assert_equal a, build(name)
      assert_equal a, JSON.parse(JSON.generate(a)) # nothing non-serializable
    end
  end

  # ---- design-review round 2 (2026-07-05) --------------------------------

  def test_every_tooltip_confined_to_the_viewport
    Publish::Charts::CHARTS.each_key do |name|
      tip = build(name)['tooltip']
      assert_equal true, tip['confine'], "#{name}: tooltip must not escape the screen"
      assert_equal 11, tip['textStyle']['fontSize']
    end
  end

  def test_renderer_hooks_declared_in_meta
    metas = Publish::Charts::CHARTS.transform_values { |s| s[:meta] }
    assert_equal 'gex_levels', metas['gex_profile']['tooltip_formatter']
    assert_equal 250, metas['scenario_strip']['height'] # half-quadrant card
    # hooks are opt-in: nobody else declares them
    assert_nil metas['lppl_regime']['tooltip_formatter']
    assert_nil metas['btco_table']['height']
  end

  # ---- gex_profile structure -------------------------------------------

  def gex_payload
    @gex_payload ||= JSON.parse(File.read(File.join(PAYLOADS, 'payload_gex_combined.json')))
  end

  def active_venues
    gex_payload['profiles'].select { |_, per|
      per.values.any? { |s| s['call'].to_i.abs >= 50_000 || s['put'].to_i.abs >= 50_000 }
    }.keys
  end

  def first_bar(opt)
    opt['series'].find { |s| s['type'] == 'bar' }
  end

  def test_gex_profile_two_series_per_active_venue_plus_aggregates
    opt = build('gex_profile')
    assert_equal 2 + active_venues.size * 2, opt['series'].size
    # aggregates FIRST so the hover bubble leads with them, side colors
    assert_equal %w[C P], opt['series'].first(2).map { |s| s['name'] }
    assert_equal %w[#0f7a5c #c63939],
                 opt['series'].first(2).map { |s| s['itemStyle']['color'] }
    labels = active_venues.map { |v| v == 'Deribit' ? 'DERI' : v }
    assert_equal labels.flat_map { |v| ["#{v} C", "#{v} P"] },
                 opt['series'].drop(2).map { |s| s['name'] }
    # legend only lists the venue toggles, right of the plot, vertical
    assert_equal opt['series'].drop(2).map { |s| s['name'] }, opt['legend']['data']
    assert_equal 'vertical', opt['legend']['orient']
  end

  def test_gex_profile_zero_and_negligible_venues_excluded_entirely
    p2 = JSON.parse(JSON.generate(gex_payload))
    p2['profiles']['DEADEX'] = { '62000' => { 'call' => 0, 'put' => 0 } }
    # a live-but-invisible book: rounds to 0.00M at display precision
    p2['profiles']['DUSTEX'] = { '62000' => { 'call' => 9_000, 'put' => -8_000 } }
    opt = Publish::Charts.gex_profile(p2)
    names = opt['series'].map { |s| s['name'] } + opt['legend']['data']
    refute names.any? { |n| n.include?('DEADEX') || n.include?('DUSTEX') }
  end

  def test_gex_profile_values_scaled_to_millions
    opt = build('gex_profile')
    level = gex_payload['profiles']['Deribit'].keys.max_by { |l|
      gex_payload['profiles']['Deribit'][l]['call'].to_i.abs
    }
    raw = gex_payload['profiles']['Deribit'][level]['call'].to_i
    levels = active_venues.flat_map { |v| gex_payload['profiles'][v].keys }.uniq
                          .sort_by { |k| k.to_i }
    deri_c = opt['series'].find { |s| s['name'] == 'DERI C' }
    assert_in_delta raw / 1e6, deri_c['data'][levels.index(level)], 0.01
  end

  def test_gex_profile_marklines_flip_and_walls
    marks = first_bar(build('gex_profile'))['markLine']['data']
    labels = marks.map { |m| m['label']['formatter'] }
    assert_equal %w[flip CW PW], labels # the fixture payload has all three
    marks.each { |m| assert_match(/\A\d+(\.\d)?k\z/, m['xAxis']) } # snapped to category
  end

  def test_gex_profile_no_flip_markline_when_absent
    p2 = JSON.parse(JSON.generate(gex_payload))
    p2['combined']['gamma_flip'] = nil
    marks = first_bar(Publish::Charts.gex_profile(p2))['markLine']['data']
    refute_includes marks.map { |m| m['label']['formatter'] }, 'flip'
  end

  def test_gex_profile_levels_ascend_and_data_aligns
    opt = build('gex_profile')
    labels = opt['xAxis']['data']
    assert_equal labels, labels.sort_by { |l| l.to_f } # ascending BTC axis
    opt['series'].each do |s|
      next unless s['type'] == 'bar'

      assert_equal labels.size, s['data'].size, "#{s['name']} misaligned with axis"
    end
  end

  # ---- scenario_strip structure ----------------------------------------

  def scn_latest
    @scn_latest ||= JSON.parse(File.read(File.join(PAYLOADS, 'payload_scenario_latest.json')))
  end

  def test_scenario_heatmap_one_cell_per_module_with_scores
    opt = build('scenario_strip')
    heat = opt['series'].find { |s| s['type'] == 'heatmap' }['data']
    scores = scn_latest['modules'].map { |m| m['score'] }
    assert_equal 7, heat.size
    assert_equal scn_latest['modules'].size, heat.size
    # compact form: vertical column [col 0, row 0..6, score]; single column,
    # one row per module (names on the y axis), scores in order/-1..1
    assert_equal [0], heat.map { |c| c[0] }.uniq
    assert_equal (0...heat.size).to_a, heat.map { |c| c[1] }
    assert_equal scores, heat.map { |c| c[2] }
    heat.each { |c| assert_includes(-1..1, c[2]) }
  end

  def test_scenario_heatmap_is_narrow_right_column_with_module_names
    opt = build('scenario_strip')
    # grid[1] is a narrow fixed-width column pinned to the right, not a row
    g1 = opt['grid'][1]
    assert_equal 20, g1['width']
    assert_equal 12, g1['right']
    # module names live on the heatmap's category y axis (7 rows), no rotate
    heat = opt['series'].find { |s| s['type'] == 'heatmap' }
    yheat = opt['yAxis'][heat['yAxisIndex']]
    assert_equal 'category', yheat['type']
    assert_equal scn_latest['modules'].map { |m| m['mod'] }, yheat['data']
    assert_equal 7, yheat['data'].size
    refute yheat['axisLabel'].key?('rotate')
  end

  def test_scenario_title_is_one_line_carrying_regime_and_composite
    opt = build('scenario_strip')
    refute opt['title'].key?('subtext')
    assert_equal 13, opt['title']['textStyle']['fontSize']
    assert_equal 'Scenario LEAN-FLUSH -0.17', opt['title']['text']
  end

  def test_scenario_visual_map_hidden_and_scoped_to_heatmap
    vm = build('scenario_strip')['visualMap'].first
    assert_equal false, vm['show']
    assert_equal 1, vm['seriesIndex'] # the heatmap, not the line
    assert_equal 2, vm['dimension']
    assert_equal [-1, 0, 1], vm['pieces'].map { |p| p['value'] }
  end

  def test_scenario_composite_axis_fixed_and_bands_labelled
    opt = build('scenario_strip')
    y0 = opt['yAxis'].first
    assert_equal(-1, y0['min'])
    assert_equal 1, y0['max']
    marks = opt['series'].first['markLine']['data']
    # four numeric boundaries + five band labels = nine markLine entries
    assert_equal 9, marks.size
    assert_equal [-0.40, -0.10, 0.10, 0.40],
                 marks.map { |m| m['label']['formatter'] }.grep(/\A[+-]0\.\d0\z/).map(&:to_f)
    assert_equal %w[FLUSH LEAN-FLUSH NEUTRAL BASE RECOVERY],
                 marks.map { |m| m['label']['formatter'] } & %w[FLUSH LEAN-FLUSH NEUTRAL BASE RECOVERY]
  end

  def test_scenario_composite_series_reads_history_entries
    opt = build('scenario_strip')
    hist = JSON.parse(File.read(File.join(PAYLOADS, 'payload_scenario_history.json')))
    data = opt['series'].first['data']
    assert_equal hist['entries'].map { |e| [e['ts'], e['composite']] }, data
  end

  # ---- lppl_regime structure -------------------------------------------

  def lppl_latest
    @lppl_latest ||= JSON.parse(File.read(File.join(PAYLOADS, 'payload_lppl_latest.json')))
  end

  def lppl_ledger
    @lppl_ledger ||= JSON.parse(File.read(File.join(PAYLOADS, 'payload_lppl_ledger.json')))
  end

  def test_lppl_three_panels_ratio_bf_z
    opt = build('lppl_regime')
    assert_equal 3, opt['grid'].size
    assert_equal %w[ratio log10\ BF Z], opt['series'].map { |s| s['name'] }
    # each panel bound to its own grid via matching axis indices
    opt['series'].each_with_index do |s, i|
      assert_equal i, s['xAxisIndex']
      assert_equal i, s['yAxisIndex']
    end
  end

  def test_lppl_envelope_lines_from_latest_detail
    marks = build('lppl_regime')['series'].first['markLine']['data']
    env = lppl_latest['tests'].find { |t| t['name'] == 'envelope' }['detail']
    ys = marks.map { |m| m['yAxis'] }
    assert_includes ys, env['bound']
    assert_includes ys, env['floor']
  end

  def test_lppl_skips_null_ledger_fields_without_crashing
    led = JSON.parse(JSON.generate(lppl_ledger))
    led['entries'].first['bf'] = nil # a dead point
    opt = Publish::Charts.lppl_regime(lppl_latest, led)
    bf = opt['series'].find { |s| s['name'] == 'log10 BF' }
    assert_empty bf['data'] # the null point is dropped, ratio/z survive
    assert_equal 1, opt['series'].first['data'].size
  end

  def test_lppl_trough_note_added_only_when_present
    # fixture fit detail carries no trough -> single title hash, no note
    assert_kind_of Hash, build('lppl_regime')['title']
    lat = JSON.parse(JSON.generate(lppl_latest))
    fit = lat['tests'].find { |t| t['name'] == 'fit' }['detail']
    fit['trough_date'] = '2025-09-08'
    fit['trough_px'] = 27_700
    title = Publish::Charts.lppl_regime(lat, lppl_ledger)['title']
    assert_kind_of Array, title
    assert_match(/trough ~2025-09-08 @27700/, title.last['text'])
  end

  def test_lppl_title_is_one_line_carrying_verdict_and_composite
    # no-trough fixture -> title is a single hash (see trough test above)
    title = build('lppl_regime')['title']
    refute title.key?('subtext')
    assert_equal 13, title['textStyle']['fontSize']
    assert_equal 'LPPL STRESSED +0.00', title['text']
  end

  # ---- btco_table structure --------------------------------------------

  def btco_latest
    @btco_latest ||= JSON.parse(File.read(File.join(PAYLOADS, 'payload_btco_latest.json')))
  end

  def test_btco_sorted_by_btc_desc_with_flagged_rows
    opt = build('btco_table')
    labels = opt['yAxis']['data']
    # MSTR holds the most BTC in the fixture -> first category
    assert_match(/\AMSTR\b/, labels.first)
    # every fixture row is both placeholder and stale -> both flags visible
    labels.each do |l|
      assert_includes l, '*', "#{l} missing placeholder flag"
      assert_includes l, 'STALE', "#{l} missing stale flag"
    end
    btcs = btco_latest['companies'].sort_by { |c| -c['btc'] }.map { |c| c['btc'] }
    assert_equal btcs, btcs.sort.reverse # sanity: descending
  end

  def test_btco_netnav_nulls_left_as_gaps
    opt = build('btco_table')
    companies = btco_latest['companies'].sort_by { |c| -c['btc'] }
    net = opt['series'].find { |s| s['name'] == 'netNAV' }['data']
    assert_equal companies.map { |c| c['net_mnav'] }, net
    assert_includes net, nil # GME carries a null net_mnav
  end

  def test_btco_gauge_value_is_stress_with_band_detail
    gauge = build('btco_table')['series'].find { |s| s['type'] == 'gauge' }
    assert_equal btco_latest['stress'], gauge['data'].first['value']
    assert_equal btco_latest['band'], gauge['detail']['formatter']
  end

  def test_btco_nav_parity_markline_at_one
    marks = build('btco_table')['series'].first['markLine']['data']
    parity = marks.find { |m| m['label']['formatter'] == 'NAV parity' }
    assert_equal 1.0, parity['xAxis']
  end

  def test_btco_title_is_one_line_carrying_stress_and_band
    title = build('btco_table')['title']
    refute title.key?('subtext')
    assert_equal 13, title['textStyle']['fontSize']
    assert_equal 'BTCo stress 70 STRESSED', title['text']
  end

  # ---- meta registry (hover help) --------------------------------------

  def test_every_chart_registers_meta_with_desc_axes_help
    Publish::Charts::CHARTS.each do |name, spec|
      meta = spec[:meta]
      refute_nil meta, "#{name} is missing its meta hover help"
      assert_kind_of String, meta['desc']
      assert_kind_of Hash, meta['axes']
      assert(meta['axes']['x'] && meta['axes']['y'], "#{name} axes need x + y")
      assert_kind_of String, meta['help']
    end
  end
end
