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
    # M11-7: optional enrichment inputs ride after the required ones (the
    # pipeline passes nil when one is absent/fail-soft; the golden path
    # always has its fixture).
    optional = (spec[:optional] || []).map { |f| JSON.parse(File.read(File.join(PAYLOADS, f))) }
    Publish::Charts.public_send(spec[:fn], *payloads, *optional)
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
    assert_equal 'gex_levels', metas['gex_btc']['tooltip_formatter']
    assert_equal 250, metas['scenario_strip']['height'] # half-quadrant card
    assert_equal 'gex_cp', metas['gex_btc']['legend_widget'] # (p) DERI (c)
    # hooks are opt-in: nobody else declares them
    assert_nil metas['lppl_regime']['tooltip_formatter']
    # M9-13 (owner ruling 2026-08-11): the shadow diagnostics move off the
    # LPPL panels onto a SHADOW tab of the same card. lppl_regime is the
    # default tab (pos 0); lppl_shadow (pos 1) carries the row-hover formatter.
    assert_equal 'lppl_shadow', metas['lppl_shadow']['tooltip_formatter']
    assert_equal %w[lppl LPPL 0], metas['lppl_regime'].values_at('tab_group', 'tab_label', 'tab_pos').map(&:to_s)
    assert_equal %w[lppl SHADOW 1], metas['lppl_shadow'].values_at('tab_group', 'tab_label', 'tab_pos').map(&:to_s)
    assert_nil metas['lppl_shadow']['height'] # a tab, not a stacked half
    assert_nil metas['btco_table']['height']
    assert_nil metas['scenario_strip']['legend_widget']
    # gex_mstr carries no drawn-legend/tooltip hooks: its single net-GEX
    # series does not match gex_levels' per-venue C/P input
    assert_nil metas['gex_mstr']['tooltip_formatter']
    assert_nil metas['gex_mstr']['legend_widget']
    # 2026-08-29 owner ruling (the 2-per-card format): the GEX card is a
    # STACKED card of two [BTC][MSTR] tab pairs -- profile section (pos 0)
    # over trend section (pos 1). Identical label sequences are what the
    # renderer links into ONE switcher (linked stacked tabs).
    assert_equal %w[gex stack 0 260 BTC],
                 metas['gex_btc'].values_at('tab_group', 'group_style', 'tab_pos', 'height', 'tab_label').map(&:to_s)
    assert_equal %w[gex stack 0 260 MSTR],
                 metas['gex_mstr'].values_at('tab_group', 'group_style', 'tab_pos', 'height', 'tab_label').map(&:to_s)
    # btco stays a solo card; LPPL is a two-tab card (M9-13); M10-9 (owner
    # ruling 2026-08-13): scenario + scorecard share one [SCENARIO][SCORES]
    # card -- the audit lives next to what it audits.
    assert_equal 'scenario', metas['scenario_strip']['tab_group']
    assert_equal 'SCENARIO', metas['scenario_strip']['tab_label']
    assert_equal 0, metas['scenario_strip']['tab_pos']
    assert_equal 'scenario', metas['scorecard']['tab_group']
    assert_equal 'SCORES', metas['scorecard']['tab_label']
    assert_equal 1, metas['scorecard']['tab_pos']
    assert_equal 'lppl', metas['lppl_regime']['tab_group']
    assert_nil metas['btco_table']['tab_group']
    # M8-6 as amended 2026-08-10 (owner rulings): vol_surface + vol_basis
    # share the 'vol' card as ONE CARD, TWO STACKED HALF-HEIGHT charts
    # (group_style 'stack'; tab_pos = vertical order, surface on top).
    assert_equal %w[vol stack 0 235],
                 metas['vol_surface'].values_at('tab_group', 'group_style', 'tab_pos', 'height').map(&:to_s)
    assert_equal %w[vol stack 2 235],
                 metas['vol_basis'].values_at('tab_group', 'group_style', 'tab_pos', 'height').map(&:to_s)
    # M8-17 (owner ruling 2026-08-10): the SURFACE section is itself a
    # [BTC][MSTR] tab pair -- vol_surface + vol_surface_mstr share tab_pos 0
    # so the renderer collapses them into ONE tabbed section; tab_label names
    # the button (BTC leads by CARD_ORDER, MSTR second).
    assert_equal 'BTC', metas['vol_surface']['tab_label']
    assert_equal %w[vol stack 0 235 MSTR],
                 metas['vol_surface_mstr'].values_at('tab_group', 'group_style',
                                                     'tab_pos', 'height', 'tab_label').map(&:to_s)
    # M8-16 (owner ruling 2026-08-10): vol_spread + vol_spread_trend share
    # the 'volspread' card the same way -- the current per-tenor bars on top
    # (tab_pos 0), the daily spread trend below (tab_pos 1), both half-height.
    assert_equal %w[volspread stack 0 235],
                 metas['vol_spread'].values_at('tab_group', 'group_style', 'tab_pos', 'height').map(&:to_s)
    assert_equal %w[volspread stack 1 235],
                 metas['vol_spread_trend'].values_at('tab_group', 'group_style', 'tab_pos', 'height').map(&:to_s)
    # 2026-08-29: the trend charts form the LOWER section of the stacked
    # GEX card (pos 1), tab-labelled BTC/MSTR to match the profile pair.
    assert_equal %w[gex stack 1 210 BTC],
                 metas['gex_btc_trend'].values_at('tab_group', 'group_style', 'tab_pos', 'height', 'tab_label').map(&:to_s)
    assert_equal %w[gex stack 1 210 MSTR],
                 metas['gex_mstr_trend'].values_at('tab_group', 'group_style', 'tab_pos', 'height', 'tab_label').map(&:to_s)
    # the vol charts carry no drawn-legend/tooltip renderer hooks;
    # the stacked pairs DO carry height (half a card each)
    %w[vol_surface vol_surface_mstr vol_spread vol_spread_trend vol_basis
       gex_btc_trend gex_mstr_trend].each do |n|
      assert_nil metas[n]['tooltip_formatter'], n
      assert_nil metas[n]['legend_widget'], n
    end
    assert_equal 210, metas['gex_btc_trend']['height'] # lower stacked section
    assert_equal 210, metas['gex_mstr_trend']['height']
    # M10-4: positioning is a SOLO card (no tab_group), no custom tooltip/
    # legend hooks; it carries only the terms glossary and, like lppl_regime,
    # no height (default card height for its three panels).
    assert_nil metas['positioning']['tab_group']
    assert_nil metas['positioning']['tooltip_formatter']
    assert_nil metas['positioning']['legend_widget']
    assert_nil metas['positioning']['height']
    assert_equal Publish::Charts::POSITIONING_TERMS, metas['positioning']['terms']
  end

  # ---- M8-6 vol/gex family structure -----------------------------------

  def test_vol_surface_scales_to_percent_and_omits_null_tenors
    opt = build('vol_surface')
    vol = JSON.parse(File.read(File.join(PAYLOADS, 'payload_vol_latest.json')))
    assert_equal vol['tenors'].map { |t| "#{t['tenor_d']}d" }, opt['xAxis']['data']
    atm = opt['series'].find { |s| s['name'] == 'ATM IV' }
    # decimal fraction -> percent at build time (0.4388 -> 43.88)
    assert_in_delta vol['tenors'].first['atm_iv'] * 100, atm['data'].first, 0.01
    assert_equal 7, atm['symbolSize'] # sparse: a filled dot must read
    # a null-reason tenor is an omitted point, never a zero
    p2 = JSON.parse(JSON.generate(vol))
    p2['tenors'][1].merge!('atm_iv' => nil, 'rr25' => nil, 'fly25' => nil, 'reason' => 'thin')
    a2 = Publish::Charts.vol_surface(p2)['series'].find { |s| s['name'] == 'ATM IV' }
    assert_nil a2['data'][1]
    # the expiry carrier is invisible and out of the legend
    exp = Publish::Charts.vol_surface(p2)['series'].find { |s| s['name'] == 'exp(d)' }
    assert_equal 0, exp['lineStyle']['opacity']
    refute_includes Publish::Charts.vol_surface(p2)['legend']['data'], 'exp(d)'
  end

  # M8-17: vol_surface_mstr shares vol_surface's option body (they tab into
  # one SURFACE section) -- byte-identical for the SAME payload except the
  # title prefix, so the MSTR tab is a true "same set-up" surface.
  def test_vol_surface_mstr_is_the_btc_body_with_an_mstr_title
    mstr = JSON.parse(File.read(File.join(PAYLOADS, 'payload_vol_mstr.json')))
    as_btc  = Publish::Charts.vol_surface(mstr)      # same payload, BTC title
    as_mstr = Publish::Charts.vol_surface_mstr(mstr) # same payload, MSTR title
    assert_match(/\AMSTR vol surface · ATM /, as_mstr['title']['text'])
    assert_match(/\AVol surface · ATM /, as_btc['title']['text'])
    # everything but the title text is identical -> one set-up, two labels
    assert_equal as_btc.reject { |k, _| k == 'title' },
                 as_mstr.reject { |k, _| k == 'title' }
    assert_equal as_btc['title'].reject { |k, _| k == 'text' },
                 as_mstr['title'].reject { |k, _| k == 'text' }
    # the real MSTR fixture drives real curves (30d ATM ~86%)
    atm = as_mstr['series'].find { |s| s['name'] == 'ATM IV' }['data']
    assert(atm.compact.all? { |v| v > 0 }, 'MSTR ATM IV points are live percentages')
  end

  def test_vol_spread_bars_and_dots_carry_tenor_gradient
    # Owner ruling 2026-08-29 (register R-9): bars and the leg-line dots
    # are colour-coded by TENOR (the same gradient as the trend below),
    # not by sign -- sign reads from bar direction against zero.
    opt = build('vol_spread')
    sp  = JSON.parse(File.read(File.join(PAYLOADS, 'payload_vol_spread.json')))
    tenor_colors = sp['tenors'].map { |t| Publish::Charts::VOL_TENOR_COLORS.fetch(t['tenor_d']) }
    bar = opt['series'].find { |s| s['name'] == 'spread' }
    assert_equal 'bar', bar['type']
    bar['data'].each_with_index do |d, i|
      next if d.nil?

      assert_equal tenor_colors[i], d['itemStyle']['color']
    end
    legs = opt['series'].select { |s| s['type'] == 'line' }
    assert_equal %w[MSTR BTC], legs.map { |s| s['name'] }
    legs.each do |s|
      # dots take the tenor colour; the connecting line keeps the leg colour.
      s['data'].each_with_index do |d, i|
        next if d.nil?

        assert_equal tenor_colors[i], d['itemStyle']['color']
      end
      assert s['lineStyle']['color'], 'leg line keeps its own colour'
    end
    # a dead leg drops its line points and that tenor's bar (nil, not zero)
    sp['tenors'].each { |t| t['mstr'] = { 'expiry_d' => nil, 'atm_iv' => nil, 'reason' => 'down' }; t['spread_atm'] = nil }
    d2 = Publish::Charts.vol_spread(sp)
    assert(d2['series'].find { |s| s['name'] == 'MSTR' }['data'].all?(&:nil?))
    assert(d2['series'].find { |s| s['name'] == 'spread' }['data'].all?(&:nil?))
  end

  def test_vol_spread_trend_lines_per_tenor_scaled_with_gaps
    opt = build('vol_spread_trend')
    sp  = JSON.parse(File.read(File.join(PAYLOADS, 'payload_vol_spread.json')))
    # x axis = the history dates in order; one line series per tenor.
    assert_equal sp['history'].map { |r| r['date'] }, opt['xAxis']['data']
    assert_equal %w[7d 14d 21d 30d 45d 90d 180d], opt['series'].map { |s| s['name'] }
    opt['series'].each do |s|
      assert_equal 'line', s['type']
      assert_equal 6, s['symbolSize'] # sparse: a single day reads as a dot
    end
    # Owner ruling 2026-08-29 (register R-9): the six tenors take the
    # spectral gradient 7d red -> 90d dark blue, single-sourced in
    # VOL_TENOR_COLORS -- line, dots and legend swatch all follow.
    expected = Publish::Charts::VOL_SPREAD_TREND_TENORS.map { |td| Publish::Charts::VOL_TENOR_COLORS.fetch(td) }
    assert_equal expected, opt['series'].map { |s| s['itemStyle']['color'] }
    assert_equal expected, opt['series'].map { |s| s['lineStyle']['color'] }
    # decimal spread -> vol points at build time (0.402 -> 40.2, 1dp)
    first7 = opt['series'].find { |s| s['name'] == '7d' }['data'].first
    assert_in_delta 40.2, first7, 0.001
    # the synthetic null 45d spread on 2026-06-30 is a GAP (nil), never a zero
    idx45 = sp['history'].index { |r| r['date'] == '2026-06-30' }
    assert_nil opt['series'].find { |s| s['name'] == '45d' }['data'][idx45]
    # empty history still yields a valid option: empty axis + 7 empty series
    empty = Publish::Charts.vol_spread_trend('history' => [])
    assert_equal [], empty['xAxis']['data']
    assert_equal 7, empty['series'].size
    assert(empty['series'].all? { |s| s['data'].empty? })
    assert_match(/Spread trend · 0d history/, empty['title']['text'])
  end

  def test_vol_basis_omits_sub_day_tenors_and_marks_zero
    opt = build('vol_basis')
    line = opt['series'].first
    assert_equal 0, line['markLine']['data'].first['yAxis'] # fair-value line
    # a synthetic sub-1-day tenor is dropped as microstructure noise
    p2 = JSON.parse(File.read(File.join(PAYLOADS, 'payload_basis_latest.json')))
    p2['basis']['tenors'].unshift('instrument' => 'BTC-PERP-ish', 'days' => 0.4,
                                  'mark' => 1.0, 'basis_ann_pct' => 999.0)
    x2 = Publish::Charts.vol_basis(p2)['xAxis']['data']
    refute_includes x2, '0d'
    refute(Publish::Charts.vol_basis(p2)['series'].first['data'].include?(999.0))
  end

  def test_gex_trend_title_suffix_only_with_cross_check
    trend = JSON.parse(File.read(File.join(PAYLOADS, 'payload_gex_trend.json')))
    check = JSON.parse(File.read(File.join(PAYLOADS, 'payload_gex_check.json')))
    withc = Publish::Charts.gex_trend(trend, check)['title']['text']
    assert_match(/GEX trend · flip dist \+3\.67% · 5d long_gamma · MP Δ/, withc)
    # gex_check absent => suffix gracefully omitted, chart still renders
    without = Publish::Charts.gex_trend(trend)['title']['text']
    assert_equal 'GEX trend · flip dist +3.67% · 5d long_gamma', without
    # price levels scaled to $k with filled dots (sparse-data rule)
    spot = Publish::Charts.gex_trend(trend)['series'].find { |s| s['name'] == 'spot' }
    assert_equal 62.0, spot['data'].first
    assert_equal 7, spot['symbolSize']
  end

  # ---- gex_mstr_trend structure (M8-18) --------------------------------

  def test_gex_mstr_trend_reads_the_mstr_block_in_raw_dollars
    opt = build('gex_mstr_trend')
    # title from the mstr stats block (no MP cross-check tail -- BTC-only)
    assert_equal 'MSTR GEX trend · flip dist +8.91% · 5d long_gamma',
                 opt['title']['text']
    refute_includes opt['title']['text'], 'MP'
    # four price lines, filled dots, MSTR's own axis in raw dollars ($)
    assert_equal %w[spot flip CW PW], opt['series'].map { |s| s['name'] }
    assert_equal 'price ($)', opt['yAxis']['name']
    spot = opt['series'].find { |s| s['name'] == 'spot' }
    assert_equal 95.0, spot['data'].first # raw dollars, NOT /1000 like BTC
    assert_equal 7, spot['symbolSize']
    # x axis = the mstr history dates, compacted to MM-DD
    trend = JSON.parse(File.read(File.join(PAYLOADS, 'payload_gex_trend.json')))
    assert_equal trend['mstr']['series'].map { |r| r['date'][5..] }, opt['xAxis']['data']
  end

  def test_gex_mstr_trend_degrades_on_absent_mstr_block
    # no 'mstr' key at all -> a valid, empty option (honest pre-accumulation)
    opt = Publish::Charts.gex_mstr_trend({})
    assert_equal [], opt['xAxis']['data']
    assert(opt['series'].all? { |s| s['data'].empty? })
    assert_equal 'MSTR GEX trend · flip dist n/a · 0d ', opt['title']['text']
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
    opt = build('gex_btc')
    assert_equal 2 + active_venues.size * 2, opt['series'].size
    # aggregates FIRST so the hover bubble leads with them, side colors
    assert_equal %w[C P], opt['series'].first(2).map { |s| s['name'] }
    assert_equal %w[#0f7a5c #c63939],
                 opt['series'].first(2).map { |s| s['itemStyle']['color'] }
    labels = active_venues.map { |v| v == 'Deribit' ? 'DERI' : v }
    assert_equal labels.flat_map { |v| ["#{v} C", "#{v} P"] },
                 opt['series'].drop(2).map { |s| s['name'] }
    # drawn legend hidden in favour of the renderer's (p) VENUE (c)
    # widget; data kept so the component still owns selection state
    assert_equal opt['series'].drop(2).map { |s| s['name'] }, opt['legend']['data']
    assert_equal false, opt['legend']['show']
  end

  def test_gex_profile_call_and_put_columns_overlay_exactly
    # round 4: the calls stack sits exactly on the puts stack at each
    # level (barGap -100%), not side by side
    build('gex_btc')['series'].each do |s|
      assert_equal '-100%', s['barGap'], "#{s['name']}" if s['type'] == 'bar'
    end
  end

  def test_value_axis_names_ride_the_axis_not_the_title_row
    # round 4: names at the axis top collided with the one-line titles;
    # rotated mid-axis placement in the left gutter cannot
    y0 = build('scenario_strip')['yAxis'].first
    assert_equal %w[middle 44], [y0['nameLocation'], y0['nameGap'].to_s]
    build('lppl_regime')['yAxis'].each do |y|
      assert_equal 'middle', y['nameLocation'], y['name']
    end
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
    opt = build('gex_btc')
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
    marks = first_bar(build('gex_btc'))['markLine']['data']
    labels = marks.map { |m| m['label']['formatter'] }
    # spot added 2026-08-11 (owner parity ruling: MSTR tab had it, BTC lacked it)
    assert_equal %w[spot flip CW PW], labels
    marks.each { |m| assert_match(/\A\d+(\.\d)?k\z/, m['xAxis']) } # snapped to category
  end

  def test_gex_profile_no_flip_markline_when_absent
    p2 = JSON.parse(JSON.generate(gex_payload))
    p2['combined']['gamma_flip'] = nil
    marks = first_bar(Publish::Charts.gex_profile(p2))['markLine']['data']
    refute_includes marks.map { |m| m['label']['formatter'] }, 'flip'
  end

  def test_gex_profile_levels_ascend_and_data_aligns
    opt = build('gex_btc')
    labels = opt['xAxis']['data']
    assert_equal labels, labels.sort_by { |l| l.to_f } # ascending BTC axis
    opt['series'].each do |s|
      next unless s['type'] == 'bar'

      assert_equal labels.size, s['data'].size, "#{s['name']} misaligned with axis"
    end
  end

  # ---- M7-8: stale marking (synthetic stale payloads) ------------------
  # All-fresh goldens are proven byte-identical by the golden harness
  # above; these pin the STALE path with hand-built payloads (the fixtures
  # carry no stale markers).

  def test_gex_profile_stale_venue_gets_bang_and_title_lists_it
    p2 = JSON.parse(JSON.generate(gex_payload))
    p2['venues'] = active_venues.map { |n| { 'name' => n, 'stale' => n == 'Deribit' } }
    p2['sources'] = [{ 'name' => 'deribit_index', 'stale' => true },
                     { 'name' => 'deribit_book', 'stale' => true }]
    opt = Publish::Charts.gex_profile(p2)
    names = opt['series'].map { |s| s['name'] }
    # the stale Deribit venue's series carry the bang; fresh venues do not
    assert_includes names, 'DERI! C'
    assert_includes names, 'DERI! P'
    refute_includes names, 'DERI C'
    assert_includes names, 'IBIT C' # a fresh venue is untouched
    # title lists spot (deribit_index stale) and the stale venue label
    assert_equal 'GEX $M/1% · spot 62.0k · stale: spot, DERI',
                 opt['title']['text']
    # the bang rides through render.js's /^(.*) ([CP])$/ into the venue name
    m = /^(.*) ([CP])$/.match('DERI! C')
    assert_equal 'DERI!', m[1]
  end

  def test_gex_profile_all_fresh_has_no_bang_or_stale_suffix
    p2 = JSON.parse(JSON.generate(gex_payload))
    p2['venues'] = active_venues.map { |n| { 'name' => n } } # no stale flags
    opt = Publish::Charts.gex_profile(p2)
    refute(opt['series'].any? { |s| s['name'].include?('!') })
    refute_includes opt['title']['text'], 'stale'
  end

  def test_gex_mstr_title_marks_stale_when_chain_cached
    p2 = JSON.parse(JSON.generate(mstr_payload))
    p2['stale'] = true
    assert_includes Publish::Charts.gex_mstr(p2)['title']['text'], '· stale'
    # fresh (no key) stays clean -- proven by the byte-identical golden too
    refute_includes build('gex_mstr')['title']['text'], 'stale'
  end

  def test_btco_title_marks_spot_stale
    p2 = JSON.parse(JSON.generate(btco_latest))
    p2['spot_stale'] = true
    assert_includes Publish::Charts.btco_table(p2)['title']['text'], '· spot stale'
    refute_includes build('btco_table')['title']['text'], 'spot stale'
  end

  # ---- gex_mstr structure (M6-3) ---------------------------------------

  def mstr_payload
    @mstr_payload ||= JSON.parse(File.read(File.join(PAYLOADS, 'payload_gex_mstr.json')))
  end

  def test_gex_mstr_title_carries_spot_from_fixture
    # spot 102.22 rendered raw-dollar (below 1k), one-line 13px title
    opt = build('gex_mstr')
    assert_equal 'MSTR GEX $M/1% · spot 102.22', opt['title']['text']
    assert_equal 13, opt['title']['textStyle']['fontSize']
  end

  def test_gex_mstr_one_net_bar_per_strike_coloured_by_sign
    opt = build('gex_mstr')
    bar = opt['series'].find { |s| s['type'] == 'bar' }
    assert_equal 'net GEX', bar['name']
    assert_equal 1, opt['series'].size # single-venue: one series, no C/P split
    strikes = mstr_payload['profile'].keys.sort_by(&:to_f)
    assert_equal strikes.size, bar['data'].size
    assert_equal opt['xAxis']['data'].size, bar['data'].size
    # each bar's colour tracks the sign of its net gamma (teal long / red short)
    bar['data'].each_with_index do |d, i|
      want = d['value'].negative? ? '#c63939' : '#0f7a5c'
      assert_equal want, d['itemStyle']['color'], "strike #{strikes[i]}"
    end
  end

  def test_gex_mstr_marklines_spot_flip_and_walls_snapped
    marks = build('gex_mstr')['series'].first['markLine']['data']
    assert_equal %w[spot flip CW PW], marks.map { |m| m['label']['formatter'] }
    # walls snap to the exact fixture strikes (107 CW, 80 PW)
    cw = marks.find { |m| m['label']['formatter'] == 'CW' }
    pw = marks.find { |m| m['label']['formatter'] == 'PW' }
    assert_equal '107', cw['xAxis']
    assert_equal '80', pw['xAxis']
    # spot snaps to the nearest strike (102 for spot 102.22)
    assert_equal '102', marks.first['xAxis']
    # label banding (Gate 6 owner report): walls raised into the upper
    # band, spot/flip in the lower (no offset); grid top makes the zone
    [cw, pw].each { |m| assert_equal [0, -14], m['label']['offset'] }
    marks.first(2).each { |m| refute m['label'].key?('offset') }
    assert_equal 56, build('gex_mstr')['grid']['top']
  end

  def test_gex_profile_wall_labels_raised_and_label_zone
    opt = build('gex_btc')
    marks = opt['series'].map { |s| s['markLine'] }.compact.first['data']
    %w[CW PW].each do |w|
      m = marks.find { |x| x['label']['formatter'] == w }
      assert_equal [0, -14], m['label']['offset'], "#{w} not raised"
    end
    flip = marks.find { |x| x['label']['formatter'] == 'flip' }
    refute flip['label'].key?('offset')
    # M8-18 R4: top 66 clears the 2-row top-right toggle widget above the
    # raised wall labels (the (p) VENUE (c) grid moved off the right margin).
    assert_equal 66, opt['grid']['top']
    # the widened plot: right margin freed for the plot (widget is top now)
    assert_equal 12, opt['grid']['right']
    assert_equal 42, opt['grid']['left']
  end

  def test_gex_mstr_default_zoom_is_spot_plus_minus_30pct
    zoom = build('gex_mstr')['dataZoom'].first
    assert_equal 'inside', zoom['type']
    # startValue/endValue are real category labels drawn from the strikes
    labels = build('gex_mstr')['xAxis']['data']
    assert_includes labels, zoom['startValue']
    assert_includes labels, zoom['endValue']
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
    # M8-18 R5: the drift arrow rides the title. The fixture rises
    # (latest +0.083 vs -0.333 four readings back) -> ↗.
    assert_equal 'Scenario NEUTRAL +0.08 ↗', opt['title']['text']
  end

  # M8-18 R5 (owner ruling 2026-08-10): the composite-drift arrow. drift =
  # latest composite minus the composite 7 readings earlier (or earliest when
  # shorter); > +0.02 ↗, < -0.02 ↘, else →; no arrow under 2 readings.
  def scn_title(latest_comp, comps, regime: 'NEUTRAL')
    latest = { 'regime' => regime, 'composite' => latest_comp, 'modules' => [] }
    history = { 'entries' => comps.map { |c| { 'ts' => '2026-08-01T00:00:00Z', 'composite' => c } } }
    Publish::Charts.scenario_strip(latest, history)['title']['text']
  end

  def test_scenario_title_drift_arrow_rising_falling_flat_and_short_history
    assert_equal 'Scenario NEUTRAL +0.30 ↗', scn_title(0.30, [0.0, 0.1, 0.30])
    assert_equal 'Scenario NEUTRAL -0.30 ↘', scn_title(-0.30, [0.2, 0.0, -0.30])
    # |drift| within the 0.02 dead-band reads flat (→); +0.02 exactly is flat
    assert_equal 'Scenario NEUTRAL +0.10 →', scn_title(0.10, [0.09, 0.10])
    assert_equal 'Scenario NEUTRAL +0.30 →', scn_title(0.30, [0.28, 0.30])
    # fewer than 2 readings -> NO arrow at all
    assert_equal 'Scenario NEUTRAL +0.10', scn_title(0.10, [0.10])
    assert_equal 'Scenario NEUTRAL +0.10', scn_title(0.10, [])
    # exactly "7 readings earlier": with 9 entries the reference is the
    # 8th-from-last (index 1), so a spike 8 readings back (index 0) is ignored
    comps = [0.9, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.05]
    assert_equal 'Scenario NEUTRAL +0.05 ↗', scn_title(0.05, comps)
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
    assert_equal hist['entries'].size, data.size
    # M8-10: healthy entries stay bare [ts, composite] pairs; a blind entry
    # (M8-8 marker) becomes a styled object so the line still reads its value.
    hist['entries'].zip(data).each do |e, pt|
      if e['blind']
        assert_equal [e['ts'], e['composite']], pt['value']
      else
        assert_equal [e['ts'], e['composite']], pt
      end
    end
  end

  # M8-10: a blind day renders as a hollow (transparent-fill) grey marker,
  # visibly degraded from a real neutral print.
  def test_scenario_blind_day_renders_hollow_grey_marker
    opt = build('scenario_strip')
    hist = JSON.parse(File.read(File.join(PAYLOADS, 'payload_scenario_history.json')))
    blind_ts = hist['entries'].select { |e| e['blind'] }.map { |e| e['ts'] }
    refute_empty blind_ts, 'fixture must carry a synthetic blind row (README)'
    styled = opt['series'].first['data'].select { |d| d.is_a?(Hash) }
    assert_equal blind_ts, styled.map { |d| d['value'].first }
    styled.each do |d|
      assert_equal 'transparent', d['itemStyle']['color'], 'blind marker is hollow'
      assert_equal '#9aa0a6', d['itemStyle']['borderColor'], 'blind marker is grey'
    end
    # and the meta help names the convention
    assert_match(/hollow\/grey/, Publish::Charts::CHARTS['scenario_strip'][:meta]['help'])
  end

  # ---- lppl_regime structure -------------------------------------------

  def lppl_latest
    @lppl_latest ||= JSON.parse(File.read(File.join(PAYLOADS, 'payload_lppl_latest.json')))
  end

  def lppl_ledger
    @lppl_ledger ||= JSON.parse(File.read(File.join(PAYLOADS, 'payload_lppl_ledger.json')))
  end

  def test_lppl_three_panels_ratio_bf_z
    # M9-13: the shadow scoreboard left lppl_regime; it is once again the
    # three full-width evidence panels, tight right margin, whole-card link.
    opt = build('lppl_regime')
    assert_equal 3, opt['grid'].size
    assert_equal %w[ratio log10\ BF Z], opt['series'].map { |s| s['name'] }
    assert_equal 24, opt['grid'].first['right'] # full-width panels, tight margin
    assert_equal [{ 'xAxisIndex' => 'all' }], opt['axisPointer']['link']
    refute opt['series'].any? { |s| s['name'] == 'shadow' }
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
    n       = led['entries'].size
    dead_ts = led['entries'].first['ts']
    led['entries'].first['bf'] = nil # a dead point
    opt = Publish::Charts.lppl_regime(lppl_latest, led)
    bf = opt['series'].find { |s| s['name'] == 'log10 BF' }
    # the null point is dropped (fixture-size-independent: pinning
    # counts, not emptiness -- a payload refresh must not break this),
    # ratio/z survive with every entry
    assert_equal n - 1, bf['data'].size
    refute(bf['data'].any? { |ts, _| ts == dead_ts })
    assert_equal n, opt['series'].first['data'].size
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

  # ---- M9-13 shadow diagnostics (the SHADOW tab) -----------------------

  def shadow_stat_series(opt)
    opt['series'].find { |s| s['name'] == 'stat' }
  end

  def test_lppl_shadow_rows_frozen_shadow_verdict
    opt = build('lppl_shadow')
    # one grid, hidden value x + category y with a slot per row
    assert_equal 1, opt['grid'].size
    yax = opt['yAxis'].first
    assert_equal 'category', yax['type']
    assert_equal (0..6).to_a, yax['data'] # 7 slots (M12-4: + bubble x-ref)
    assert_equal false, yax['axisLabel']['show']
    # title carries the honest row count (fontSize 13)
    assert_equal 'Shadow checks · 7 rows', opt['title'].first['text']
    assert_equal 13, opt['title'].first['textStyle']['fontSize']
    # the visible columns and their build-time-scaled values, in order
    stat = shadow_stat_series(opt)
    assert_equal 0, stat['symbolSize']
    assert_equal true, stat['silent']
    assert_equal %w[mean/eval 365/730 damping impr p(osc) freeze bubble],
                 stat['data'].map { |d| d['title'] }
    # M11-6 (rulings 2026-08-29): reference column = the old/demoted
    # value, operative column = the number now in force; graduated rows
    # say so in the verdict. mean/eval carries the NW error bar.
    assert_equal ['-427.34', '-0.11', '>=1', '43.5%', '.19', '.435', '-0.99'],
                 stat['data'].map { |d| d['frozen'] }
    assert_equal ['-1.17±.17', '+0.15', '0.41', '27.9%', '.24', '.358', 'pct 61'],
                 stat['data'].map { |d| d['shadow'] }
    assert_equal ['headline 08-29', 'wins at 2y · report-only',
                  'not met · report-only', 'headline 08-29',
                  'still noise · headline 08-29', 'adopted 08-29',
                  'MID · advisory'],
                 stat['data'].map { |d| d['verdict'] }
  end

  def test_lppl_shadow_rows_carry_owner_explanations
    stat = shadow_stat_series(build('lppl_shadow'))
    # every row's hover text is the verbatim owner-approved paragraph,
    # keyed by stat, and names the ruling it feeds
    stat['data'].each do |d|
      assert_equal Publish::Charts::LPPL_SHADOW_EXPLAIN[d['title']], d['explanation']
    end
    mean = stat['data'].find { |d| d['title'] == 'mean/eval' }
    assert_match(/GRADUATED 2026-08-29/, mean['explanation'])
    assert_match(/Newey-West error bar/, mean['explanation'])
  end

  # M12-4: the bubble x-ref row rides the OPTIONAL bubble:ref input --
  # nil or fail-soft drops JUST that row (the tab never skips).
  def test_lppl_shadow_bubble_row_optional
    lat = JSON.parse(JSON.generate(lppl_latest))
    no_bubble = Publish::Charts.lppl_shadow(lat, nil)
    refute_includes shadow_stat_series(no_bubble)['data'].map { |d| d['title'] }, 'bubble'
    assert_equal 'Shadow checks · 6 rows', no_bubble['title'].first['text']
    failsoft = Publish::Charts.lppl_shadow(lat, { 'unavailable' => true })
    refute_includes shadow_stat_series(failsoft)['data'].map { |d| d['title'] }, 'bubble'
  end

  def test_lppl_shadow_axis_tooltip_contract
    # frozen tooltip contract: confine true + fontSize 11 (renderer swaps
    # in the never-clip position + lppl_shadow formatter at runtime), and
    # axis trigger so hovering anywhere on a row fires it
    tip = build('lppl_shadow')['tooltip']
    assert_equal 'axis', tip['trigger']
    assert_equal true, tip['confine']
    assert_equal 11, tip['textStyle']['fontSize']
  end

  def test_lppl_shadow_row_absent_when_field_missing
    lat = JSON.parse(JSON.generate(lppl_latest))
    fld = ->(n) { lat['tests'].find { |t| t['name'] == n }['detail'] }
    # the freeze row reads the M11-5 shape (bound_live) first, so a
    # pre-M9-4 payload must lack BOTH bound_live and freeze_candidate
    fld.call('envelope').delete('freeze_candidate')
    fld.call('envelope').delete('bound_live')        # drops the freeze row
    fld.call('logperiodic').delete('p_value_v2')     # drops the p(osc) row
    stat = shadow_stat_series(Publish::Charts.lppl_shadow(lat))
    assert_equal 4, stat['data'].size # 6 rows minus the two dropped
    titles = stat['data'].map { |d| d['title'] }
    refute_includes titles, 'freeze'
    refute_includes titles, 'p(osc)'
    # the title's row count follows the surviving rows
    assert_equal 'Shadow checks · 4 rows',
                 Publish::Charts.lppl_shadow(lat)['title'].first['text']
  end

  def test_lppl_shadow_degrades_gracefully_with_no_shadow_fields
    lat = JSON.parse(JSON.generate(lppl_latest))
    td = ->(n) { lat['tests'].find { |t| t['name'] == n }['detail'] }
    %w[per_horizon per_horizon_long].each { |k| td.call('trend').delete(k) }
    td.call('envelope').delete('freeze_candidate')
    td.call('envelope').delete('bound_live')
    %w[damping improvement_v2].each { |k| td.call('fit').delete(k) }
    td.call('logperiodic').delete('p_value_v2')
    opt = Publish::Charts.lppl_shadow(lat)
    assert_empty opt['series'] # no rows -> nothing drawn (fail-soft)
    assert_equal 'Shadow checks · 0 rows', opt['title'].first['text']
    assert_equal 'awaiting shadow fields', opt['title'].last['text']
    assert_equal opt, JSON.parse(JSON.generate(opt)) # still JSON-safe
  end

  def test_lppl_compact_strips_leading_zero
    assert_equal '.24', Publish::Charts.lppl_compact(0.238, 2)
    assert_equal '-.11', Publish::Charts.lppl_compact(-0.108, 2)
    assert_equal '1.40', Publish::Charts.lppl_compact(1.4, 2)
  end

  # ---- zoomable date axes (owner ruling 2026-08-29) --------------------
  # The time-series charts get the gex_btc idiom: INSIDE dataZoom (wheel
  # zoom + drag pan, no slider) on their date axes -- every linked panel
  # zooms together; a non-time companion axis (the scenario 'now' heatmap
  # column) stays out. Default window = full range.
  DATE_ZOOM = {
    'vol_spread_trend' => [0],
    'scenario_strip'   => [0],     # NOT the heatmap 'now' column (axis 1)
    'positioning'      => [0, 1, 2],
    'lppl_regime'      => [0, 1, 2],
    'gex_btc_trend'    => [0],
    'gex_mstr_trend'   => [0]
  }.freeze

  def test_time_series_charts_carry_inside_date_zoom
    DATE_ZOOM.each do |name, axes|
      zoom = build(name)['dataZoom']
      assert_kind_of Array, zoom, "#{name}: dataZoom missing"
      assert_equal 1, zoom.size, "#{name}: exactly one zoom entry"
      assert_equal 'inside', zoom.first['type'], "#{name}: inside only, no slider"
      assert_equal axes, zoom.first['xAxisIndex'], "#{name}: linked panels zoom together"
      refute zoom.first.key?('startValue'), "#{name}: default window is the full range"
    end
  end

  def test_non_time_charts_stay_unzoomed
    %w[vol_spread vol_surface btco_table lppl_shadow scorecard].each do |name|
      refute build(name).key?('dataZoom'), "#{name}: no date axis, no zoom"
    end
  end

  # ---- positioning structure (M10-4) -----------------------------------

  def positioning_doc
    @positioning_doc ||= JSON.parse(File.read(File.join(PAYLOADS, 'payload_positioning_latest.json')))
  end

  def test_positioning_three_panels_share_one_date_axis
    opt = build('positioning')
    # three grids, identical left/right so a vertical slice aligns exactly
    assert_equal 3, opt['grid'].size
    lefts  = opt['grid'].map { |g| g['left'] }.uniq
    rights = opt['grid'].map { |g| g['right'] }.uniq
    assert_equal 1, lefts.size, 'grids must share one left for alignment'
    assert_equal 1, rights.size, 'grids must share one right for alignment'
    # only the bottom panel draws the shared dates; the upper two hide theirs
    assert_equal false, opt['xAxis'][0]['axisLabel']['show']
    assert_equal false, opt['xAxis'][1]['axisLabel']['show']
    refute opt['xAxis'][2].key?('axisLabel'), 'bottom panel draws its date labels'
    opt['xAxis'].each { |x| assert_equal 'time', x['type'] }
    # hovering locks a vertical slice across all panels
    assert_equal [{ 'xAxisIndex' => 'all' }], opt['axisPointer']['link']
  end

  def test_positioning_series_panels_and_liq_overlay
    opt = build('positioning')
    by = opt['series'].to_h { |s| [s['name'], s] }
    # OI on panel 0, the three crowd ratios on panel 1 (taker on the right
    # axis, yAxisIndex 2), the liquidation bars on panel 2.
    assert_equal [0, 0], by['OI $B'].values_at('xAxisIndex', 'yAxisIndex')
    assert_equal [1, 1], by['global L/S'].values_at('xAxisIndex', 'yAxisIndex')
    assert_equal [1, 1], by['top L/S'].values_at('xAxisIndex', 'yAxisIndex')
    assert_equal [1, 2], by['taker buy%'].values_at('xAxisIndex', 'yAxisIndex')
    assert_equal 'right', opt['yAxis'][2]['position'] # taker % on the right axis
    # density-aware symbols (2026-08-29): the 365d real fixture is dense,
    # so the lines drop their per-point dots; a sparse (<60pt) series
    # keeps them (the sparse-data rule) -- pinned via a truncated doc
    %w[OI\ $B global\ L/S top\ L/S taker\ buy%].each do |n|
      assert_equal false, by[n]['showSymbol'], "#{n}: dense series draws the line alone"
      assert_equal 'circle', by[n]['symbol'] # emphasis/hover dot stays configured
    end
    sparse = Publish::Charts.positioning_line('x', [['2026-08-01', 1.0]] * 30, '#fff', 0, 0)
    assert_equal true, sparse['showSymbol'], 'sparse series keeps its filled dots'
    # opposed liquidation bars overlay on the same day (barGap -100%); longs
    # plotted DOWN (negated) in red, shorts UP in teal
    long = by['long liq $M']; short = by['short liq $M']
    assert_equal ['bar', '-100%', Publish::Charts::POS_LONG],
                 long.values_at('type', 'barGap').push(long['itemStyle']['color'])
    assert_equal Publish::Charts::POS_SHORT, short['itemStyle']['color']
    # the fixture's long liqs are positive $M -> plotted negative (down)
    src = positioning_doc['series']['long_liq']
    assert_equal src.map { |d, v| [d, -v] }, long['data']
    assert_equal positioning_doc['series']['short_liq'], short['data']
  end

  def test_positioning_legend_only_crowd_ratios_with_terms
    opt = build('positioning')
    # the crowd ratios + the M11-7 reserves curve carry a drawn legend
    assert_equal ['global L/S', 'top L/S', 'taker buy%', 'reserves'], opt['legend']['data']
    # every legend name has a glossary term (the terms hook attaches here)
    terms = Publish::Charts::CHARTS['positioning'][:meta]['terms']
    opt['legend']['data'].each { |n| assert terms.key?(n), "no term for #{n}" }
  end

  # M11-7 (owner ruling 2026-08-29): the reserves curve rides the OI
  # panel's right axis from the OPTIONAL reserves:latest input; a nil
  # input degrades to an empty series -- the card renders, never skips.
  def test_positioning_reserves_curve_on_oi_right_axis
    opt = build('positioning')
    resv = opt['series'].find { |s| s['name'] == 'reserves' }
    assert resv, 'reserves series present when the optional payload is'
    assert_equal [0, 4], resv.values_at('xAxisIndex', 'yAxisIndex')
    assert_equal Publish::Charts::POS_RESV, resv['itemStyle']['color']
    ax = opt['yAxis'][4]
    assert_equal [0, 'right'], ax.values_at('gridIndex', 'position')
    refute ax.key?('name'), 'unnamed axis: wide M-BTC ticks + a rotated name collide'
    # data = the reserves payload's card series CLIPPED (both ends) to the
    # positioning window (each grid owns its time axis; a longer tail on
    # either side would stretch panel 0 and break vertical-slice alignment)
    fixture = JSON.parse(File.read(File.join(PAYLOADS, 'payload_reserves_latest.json')))
    from = positioning_doc['series'].values.map { |pts| pts.first.first }.min
    to   = positioning_doc['series'].values.map { |pts| pts.last.first }.max
    assert_equal fixture['series']['total_mbtc'].select { |d, _| d >= from && d <= to },
                 resv['data']
    assert_operator resv['data'].first.first, :>=, from
    assert_operator resv['data'].last.first, :<=, to
    # frozen axis indices 0..3 unchanged (nothing renumbers)
    assert_equal 'right', opt['yAxis'][2]['position']
  end

  def test_positioning_without_reserves_input_degrades_not_skips
    opt = Publish::Charts.positioning(positioning_doc, nil)
    resv = opt['series'].find { |s| s['name'] == 'reserves' }
    assert_equal [], resv['data'], 'nil optional input -> empty curve'
    assert_equal 5, opt['yAxis'].size # axis still declared (static option)
    assert_equal opt, JSON.parse(JSON.generate(opt)) # JSON-safe
    # single-arg call (pre-M11-7 pipeline shape) still works too
    assert Publish::Charts.positioning(positioning_doc)['series']
      .any? { |s| s['name'] == 'reserves' }
  end

  def test_positioning_title_warmup_and_scored
    # the fixture is a REAL 365d capture (2026-08-29) -> scored title
    assert_equal 'Positioning · 0 · crowd SHORT', build('positioning')['title']['text']
    # scored variants (0 shown bare, not +0)
    scored = JSON.parse(JSON.generate(positioning_doc))
    scored['crowding'] = 'LONG'
    scored['score'] = -1
    assert_equal 'Positioning · -1 · crowd LONG', Publish::Charts.positioning(scored)['title']['text']
    # the designed WARMUP state stays honest (never blank): n/91d from the
    # crowd series length
    warm = JSON.parse(JSON.generate(positioning_doc))
    warm['crowding'] = 'WARMUP'
    warm['series']['global_ls'] = warm['series']['global_ls'].first(30)
    assert_equal 'Positioning · WARMUP 30/91d', Publish::Charts.positioning(warm)['title']['text']
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
    assert_equal 'BTCo stress 69 STRESSED', title['text']
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
