# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'
require_relative '../../scripts/dist/dist'

# M13-5: the dist producer's pure builders + ledger/snapshot IO.
# Network paths live in the contract tests; everything here is offline.
class TestDistBuilders < Minitest::Test
  NOW = Time.utc(2026, 9, 1, 12)

  def raw_row(exp, strike, cp, oi: 5.0, iv: 55.0, u: 80_000.0)
    { 'instrument_name' => "BTC-#{exp}-#{strike}-#{cp}",
      'open_interest' => oi, 'mark_iv' => iv, 'underlying_price' => u }
  end

  def test_parse_book_filters_dead_expired_and_near_expiry_rows
    rows = [
      raw_row('25SEP26', 80_000, 'C'),                 # live, 24d out
      raw_row('25SEP26', 80_000, 'P', oi: 0.0),        # no OI
      raw_row('25SEP26', 90_000, 'C', iv: 0.0),        # no mark iv
      raw_row('28AUG26', 80_000, 'C'),                 # already expired
      raw_row('02SEP26', 80_000, 'C'),                 # expires within 36h
      { 'instrument_name' => 'BTC-BAD', 'open_interest' => 5, 'mark_iv' => 50 }
    ]
    book = Dist.parse_book(rows, NOW, 80_000.0)
    assert_equal 1, book.size
    r = book.first
    assert_equal 80_000.0, r[:k]
    assert_equal 'C', r[:cp]
    assert_in_delta 0.55, r[:iv], 1e-12
    assert_in_delta (Time.utc(2026, 9, 25, 8) - NOW) / BTC::Options::YEAR_S, r[:t], 1e-12
  end

  def test_realized_sigma_zero_for_constant_and_nil_for_short
    assert_in_delta 0.0, Dist.realized_sigma([100.0] * 30), 1e-12
    assert_nil Dist.realized_sigma([100.0, 101.0])
  end

  def test_realized_sigma_exact_on_alternating_returns
    # returns alternate +r, -r with r = ln(1.02): mean 0, var = r^2 * n/(n-1)
    px = [100.0]
    20.times { |i| px << px.last * (i.even? ? 1.02 : 1 / 1.02) }
    r = Math.log(1.02)
    expect = Math.sqrt(r * r * (20.0 / 19.0) * 365.25)
    assert_in_delta expect, Dist.realized_sigma(px), 1e-9
  end

  def test_ladder_is_spot_relative_rounded_to_500
    lad = Dist.ladder(80_000.0)
    assert_equal 56_000.0, lad.first
    assert_equal 104_000.0, lad.last
    assert_equal 13, lad.size
    assert(lad.all? { |k| (k % 500).zero? })
  end

  def test_lognormal_quantiles_median_and_symmetry
    w = 0.04
    q = Dist.lognormal_quantiles(100_000.0, w)
    med = q.find { |tau, _| tau == 0.5 }[1]
    assert_in_delta 100_000.0 * Math.exp(-w / 2), med, 1e-6
    assert_in_delta 0.5, Dist.lognormal_digital(100_000.0, w, med), 1e-9
  end

  def flat_board(iv_pct: 55.0)
    %w[25SEP26 25DEC26].flat_map do |exp|
      (55_000..110_000).step(5_000).flat_map do |strike|
        %w[C P].map { |cp| raw_row(exp, strike, cp, iv: iv_pct) }
      end
    end
  end

  def closes_series
    px = [70_000.0]
    120.times { |i| px << px.last * (i.even? ? 1.015 : 1 / 1.015) }
    px
  end

  def test_build_day_row_shape_and_consistency
    built = Dist.build_day(flat_board, 80_000.0, closes_series,
                           '2026-09-01', '2026-09-01T04:00:00Z')
    row = built['row']
    assert_equal %w[calendar_violations date horizons input_hash known_at
                    n_degraded n_slices schema spot ts],
                 row.keys.sort
    assert_equal row['known_at'], row['ts'] # the tail stale-guard field
    assert_equal 2, row['n_slices']
    assert_equal 0, row['n_degraded']
    assert_match(/\A[0-9a-f]{64}\z/, row['input_hash'])
    assert_equal [7, 30, 90], row['horizons'].map { |h| h['d'] }

    h30 = row['horizons'][1]
    assert_equal %w[components d degraded extrapolated forward ladder t touch_rn],
                 h30.keys.sort
    assert_equal %w[ln_atm rn rw], h30['components'].keys.sort
    # flat 55-vol board: rn median ~ forward * exp(-w/2)
    w = 0.55 * 0.55 * h30['t']
    med = h30['components']['rn']['quantiles'].find { |t, _| t == 0.5 }[1]
    assert_in_delta h30['forward'] * Math.exp(-w / 2), med, h30['forward'] * 0.005
    # digitals parallel the ladder, decreasing in strike
    digs = h30['components']['rn']['digitals']
    assert_equal h30['ladder'].size, digs.size
    assert_equal digs.sort.reverse, digs
    # the 7d horizon interpolates below the first (24d) expiry -> flagged
    assert row['horizons'][0]['extrapolated']
    refute h30['extrapolated']
  end

  def test_build_day_row_is_deterministic
    a = Dist.build_day(flat_board, 80_000.0, closes_series, '2026-09-01', 'K')
    b = Dist.build_day(flat_board, 80_000.0, closes_series, '2026-09-01', 'K')
    assert_equal a['row'], b['row']
  end

  def test_payload_carries_the_frozen_summary_fields
    built = Dist.build_day(flat_board, 80_000.0, closes_series,
                           '2026-09-01', 'K', as_of: '2026-09-01')
    p = built['payload']
    assert_equal %w[as_of calendar_violations date divergence edge headline
                    horizons n_degraded n_slices name scoring spot ts],
                 p.keys.sort
    assert_equal 'dist', p['name']
    assert_equal '2026-09-01', p['as_of']
    assert_nil p['scoring'] # the pure builder never carries scores
    assert_nil p['divergence'] # no second venue passed
    assert_nil p['edge'] # no VRP history passed
    assert_equal %w[d degraded extrapolated forward median median_rwm
                    p05 p25 p75 p95 sigma_atm sigma_rw tilt_scale vrp],
                 p['horizons'].first.keys.sort
    assert_match(/med30 .* slices/, p['headline'])
  end
end

class TestDistLedgerIO < Minitest::Test
  def test_append_ledger_once_per_date
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'ledger.jsonl')
      assert Dist.append_ledger({ 'date' => '2026-09-01', 'x' => 1 }, path)
      refute Dist.append_ledger({ 'date' => '2026-09-01', 'x' => 2 }, path)
      assert Dist.append_ledger({ 'date' => '2026-09-02', 'x' => 3 }, path)
      assert_equal 2, File.readlines(path).size
      assert_equal '2026-09-02', Dist.last_ledger_date(path)
    end
  end

  def test_snapshot_round_trip_and_sha
    Dir.mktmpdir do |dir|
      rows = [{ 'instrument_name' => 'BTC-25SEP26-80000-C', 'open_interest' => 1 }]
      sha = Dist.write_snapshot('2026-09-01', 'K', 80_000.0, rows, dir: dir)
      snap = Dist.read_snapshot('2026-09-01', dir: dir)
      assert_equal rows, snap['rows']
      assert_equal 80_000.0, snap['spot']
      assert_equal sha, snap['sha256']
      assert_nil Dist.read_snapshot('2026-09-02', dir: dir)
    end
  end

  def test_load_closes_respects_cutoff_and_header
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'prices.csv')
      File.write(path, "date,close\n2026-08-30,100.0\n2026-08-31,101.0\n2026-09-01,102.0\n")
      assert_equal [100.0, 101.0], Dist.load_closes('2026-09-01', path)
      assert_equal [], Dist.load_closes('2026-08-30', path)
      assert_equal [], Dist.load_closes('2026-09-01', File.join(dir, 'missing.csv'))
    end
  end
end

# Full-board surface-fit quality pins -- SKIP until the owner records
# the deribit_book_full fixture (Gate-13 runbook step; pending_ok in
# the registry). "now" derives from the fixture's own earliest expiry
# so the pin never ages out.
class TestDistFullBookQuality < Minitest::Test
  FIXTURE = File.expand_path('../fixtures/deribit_book_full.json', __dir__)

  def test_full_board_fits_svi_slices_and_builds_sane_densities
    skip 'deribit_book_full.json not recorded yet (Gate-13 step)' unless File.exist?(FIXTURE)

    rows = JSON.parse(File.read(FIXTURE))['result']
    expiries = rows.filter_map { |r| BTC::Options.deribit_expiry(r['instrument_name'].split('-')[1]) }
    now = expiries.min - 2.1 * 86_400
    spot = rows.sum { |r| r['underlying_price'].to_f } / rows.size
    book = Dist.parse_book(rows, now, spot)
    slices = BTC::Density.slices(book)

    svi = slices.select { |s| s[:method] == 'svi' }
    assert_operator svi.size, :>=, 3, 'a full board should fit >= 3 SVI slices'
    ok = svi.count { |s| s[:butterfly_ok] }
    assert_operator ok, :>=, (svi.size * 0.8).ceil,
                    'most SVI slices should pass the Durrleman check'

    den = BTC::Density.horizon_density(slices, 30 / 365.25)
    assert_in_delta 1.0, den[:integral_raw], 0.1
    qs = den[:quantiles].map(&:last)
    assert_equal qs.sort, qs
    assert_kind_of Array, BTC::Density.calendar_violations(slices)
  end
end

# M13-6: the resolution pass. A synthetic backdated ledger must resolve
# to hand-computed scores, exactly once.
class TestDistResolution < Minitest::Test
  def ledger_row(date)
    { 'date' => date, 'horizons' => [
      { 'd' => 7, 'ladder' => [90.0, 100.0, 110.0],
        'components' => {
          'rn' => { 'quantiles' => [[0.25, 90.0], [0.5, 100.0], [0.75, 110.0]],
                    'digitals' => [0.8, 0.5, 0.2] },
          'rw' => { 'quantiles' => [[0.25, 80.0], [0.5, 100.0], [0.75, 120.0]],
                    'digitals' => [0.7, 0.5, 0.3] }
        } }
    ] }
  end

  def test_resolve_scores_matured_rows_exactly_once
    rows = [ledger_row('2026-08-01'), ledger_row('2026-08-20')]
    closes = { '2026-08-08' => 105.0 } # only the first row's 7d matured
    recs = Dist.resolve(rows, Set.new, closes)
    assert_equal 1, recs.size
    r = recs.first
    assert_equal ['2026-08-01', 7, '2026-08-08', 105.0],
                 [r['date'], r['d'], r['matured'], r['y']]

    rn = r['scores']['rn']
    # crps: grid [[.25,90],[.5,100],[.75,110]], y=105:
    # rho(90)=15*.25, rho(100)=5*.5, rho(110)=5*.25 -> sum 7.5 -> 2/3*7.5 = 5.0
    assert_in_delta 5.0, rn['crps'], 1e-9
    # pit: halfway 100..110 between taus .5..: .5 + .25*0.5 = .625
    assert_in_delta 0.625, rn['pit'], 1e-9
    # log: bracket .5->.75 over 100->110: ln(0.025)
    assert_in_delta Math.log(0.025).round(4), rn['log'], 1e-9
    # brier over ladder: y=105 -> hits [T,T,F] vs p [.8,.5,.2]:
    # (.04 + .25 + .04)/3
    assert_in_delta 0.11, rn['brier_mean'], 1e-9

    # idempotence: the scored key suppresses a second pass
    assert_empty Dist.resolve(rows, Set.new(['2026-08-01:7']), closes)
  end

  def test_scoring_summary_aggregates_and_skills
    recs = [
      { 'd' => 7, 'scores' => { 'rn' => { 'crps' => 4.0, 'log' => -3.0 },
                                'rw' => { 'crps' => 6.0, 'log' => -3.5 } } },
      { 'd' => 7, 'scores' => { 'rn' => { 'crps' => 6.0, 'log' => -2.0 },
                                'rw' => { 'crps' => 8.0, 'log' => -3.0 } } }
    ]
    s = Dist.scoring_summary(recs)
    assert_equal 2, s['n_resolved']
    h7 = s['horizons'].find { |h| h['d'] == 7 }
    assert_equal 2, h7['n']
    assert_in_delta 5.0, h7['crps']['rn'], 1e-9
    assert_in_delta 7.0, h7['crps']['rw'], 1e-9
    skill = h7['skill_log_vs_rw']['rn']
    assert_in_delta 0.75, skill['mean'], 1e-9 # (0.5 + 1.0)/2
    assert_equal 2, skill['n']
    assert_in_delta BTC::Stats.newey_west_se([0.5, 1.0], lag: 6).round(4),
                    skill['se'], 1e-9
    # horizons with no resolutions report n 0, empty maps
    assert_equal 0, s['horizons'].find { |h| h['d'] == 30 }['n']
  end
end

# M13-7: the IBIT second venue -- BTC-axis conversion, KL divergence.
class TestDistIbitLeg < Minitest::Test
  NOW = Time.utc(2026, 9, 1, 12)
  BTC_SPOT = 80_000.0

  # OSI: IBIT + YYMMDD + C/P + strike*1000 (8 digits). Strike 45 -> 00045000.
  def osi(yymmdd, cp, strike)
    format('IBIT%s%s%08d', yymmdd, cp, (strike * 1000).round)
  end

  def chain(strikes, iv: 0.55, spot: 45.0)
    { 'current_price' => spot,
      'options' => strikes.flat_map do |s|
        %w[C P].map do |cp|
          { 'option' => osi('270326', cp, s), 'open_interest' => 10.0, 'iv' => iv }
        end
      end }
  end

  def test_parse_ibit_converts_strikes_to_the_btc_axis
    rows = Dist.parse_ibit(chain([45.0]), BTC_SPOT, NOW)
    assert_equal 2, rows.size
    r = rows.first
    assert_in_delta BTC_SPOT, r[:k], 1e-6 # 45 / (45/80000)
    assert_equal BTC_SPOT, r[:u]
    assert_in_delta 0.55, r[:iv], 1e-12
  end

  def test_parse_ibit_nil_on_empty_or_priceless_chains
    assert_nil Dist.parse_ibit({ 'options' => [] }, BTC_SPOT, NOW)
    assert_nil Dist.parse_ibit({ 'current_price' => 0.0 }, BTC_SPOT, NOW)
  end

  def test_kl_zero_for_identical_and_matches_lognormal_closed_form
    mk = lambda do |sigma|
      t = 30 / 365.25
      strikes = (50_000..130_000).step(5_000)
      book = strikes.flat_map do |k|
        %w[C P].map { |cp| { k: k.to_f, cp: cp, t: t, iv: sigma, oi: 1.0, u: BTC_SPOT } }
      end
      BTC::Density.horizon_density(BTC::Density.slices(book), t)
    end
    a = mk.call(0.5)
    assert_in_delta 0.0, BTC::Density.kl(a, a), 1e-8

    b = mk.call(0.6)
    t = 30 / 365.25
    s1 = 0.5 * Math.sqrt(t)
    s2 = 0.6 * Math.sqrt(t)
    mu1 = -0.5 * s1**2
    mu2 = -0.5 * s2**2
    closed = Math.log(s2 / s1) + (s1**2 + (mu1 - mu2)**2) / (2 * s2**2) - 0.5
    assert_in_delta closed, BTC::Density.kl(a, b), closed * 0.05
  end

  def test_build_day_divergence_present_with_second_venue
    board = %w[25SEP26 25DEC26].flat_map do |exp|
      (55_000..110_000).step(5_000).flat_map do |strike|
        %w[C P].map do |cp|
          { 'instrument_name' => "BTC-#{exp}-#{strike}-#{cp}",
            'open_interest' => 5.0, 'mark_iv' => 55.0, 'underlying_price' => BTC_SPOT }
        end
      end
    end
    ibit_strikes = (30.0..62.0).step(2.5).to_a
    ibit = { 'data' => chain(ibit_strikes, iv: 0.55, spot: 45.0),
             'as_of' => '2026-09-01T00:00:00Z', 'stale' => false }
    built = Dist.build_day(board, BTC_SPOT, [], '2026-09-01', 'K', ibit: ibit)
    div = built['payload']['divergence']
    refute_nil div
    assert_equal false, div['stale']
    assert_equal [7, 30, 90], div['horizons'].map { |h| h['d'] }
    div['horizons'].each do |h|
      next if h['kl'].nil?

      assert_operator h['kl'], :>=, 0.0
    end
  end
end

# M13-8: the VRP tilt -- the phase's one Golden-Rule-4 item. Zero VRP
# tilts to the identity EXACTLY; estimates only ever see data strictly
# before the build date (replay safety).
class TestDistVrpTilt < Minitest::Test
  BTC_SPOT = 80_000.0

  def flat_board
    %w[25SEP26 25DEC26].flat_map do |exp|
      (55_000..110_000).step(5_000).flat_map do |strike|
        %w[C P].map do |cp|
          { 'instrument_name' => "BTC-#{exp}-#{strike}-#{cp}",
            'open_interest' => 5.0, 'mark_iv' => 55.0, 'underlying_price' => BTC_SPOT }
        end
      end
    end
  end

  def const_closes(from, days, px = 100.0)
    (0..days).to_h { |i| [Dist.date_add(from, i), px] }
  end

  def test_estimate_vrp_exact_on_constant_closes
    vol_hist = (0...12).to_h { |i| [Dist.date_add('2026-06-01', i), { 7 => 0.5 }] }
    closes = const_closes('2026-06-01', 25)
    vrp = Dist.estimate_vrp(vol_hist, closes)
    assert_equal [7], vrp.keys # no 30/90 ivs in history
    assert_in_delta 0.25, vrp[7]['vrp'], 1e-9 # iv^2 - 0
    assert_equal 12, vrp[7]['n']
  end

  def test_estimate_vrp_requires_min_samples_and_matured_windows
    vol_hist = (0...5).to_h { |i| [Dist.date_add('2026-06-01', i), { 7 => 0.5 }] }
    assert_empty Dist.estimate_vrp(vol_hist, const_closes('2026-06-01', 25))
    # 12 days of ivs but closes stop before any 7d window completes
    vol_hist = (0...12).to_h { |i| [Dist.date_add('2026-06-01', i), { 7 => 0.5 }] }
    assert_empty Dist.estimate_vrp(vol_hist, const_closes('2026-06-01', 3))
  end

  def test_tilt_scale_identity_floor_and_cap
    t = 30 / 365.25
    assert_in_delta 1.0, Dist.tilt_scale(0.04, 0.0, t), 1e-12
    assert_in_delta Dist::VRP_SCALE_LO, Dist.tilt_scale(0.01, 5.0, t), 1e-12
    assert_in_delta Dist::VRP_SCALE_HI, Dist.tilt_scale(0.01, -5.0, t), 1e-12
  end

  def test_zero_vrp_rwm_equals_rn_exactly
    slices = BTC::Density.slices(Dist.parse_book(flat_board, Time.utc(2026, 9, 1, 12), BTC_SPOT))
    rec = Dist.horizon_record(slices, 30, BTC_SPOT, nil, vrp: { 'vrp' => 0.0, 'n' => 30 })
    assert_equal rec['components']['rn']['quantiles'],
                 rec['components']['rwm']['quantiles']
    assert_in_delta 1.0, rec['components']['rwm']['scale'], 1e-12
  end

  def test_build_day_with_vrp_history_carries_rwm_and_edge
    vol_hist = (0...15).to_h do |i|
      [Dist.date_add('2026-06-01', i), { 7 => 0.7, 30 => 0.7, 90 => 0.7 }]
    end
    closes = const_closes('2026-06-01', 120)
    built = Dist.build_day(flat_board, BTC_SPOT, [], '2026-09-01', 'K',
                           vol_hist: vol_hist, closes_map: closes)
    h30 = built['row']['horizons'][1]
    rwm = h30['components']['rwm']
    refute_nil rwm
    assert_in_delta 0.49, rwm['vrp'], 1e-6
    assert_operator rwm['scale'], :<, 1.0 # positive VRP narrows the density
    # narrower: rwm 5..95 range inside the rn range
    span = ->(c) { qs = c['quantiles'].to_h; qs[0.95] - qs[0.05] }
    assert_operator span.call(rwm), :<, span.call(h30['components']['rn'])

    edge = built['payload']['edge']
    refute_nil edge
    assert_equal edge['ladder'].size, edge['expiries'].first['ratio'].size
    mid = edge['expiries'].first['ratio'][edge['ladder'].size / 2]
    assert_operator mid, :>, 1.0 # narrower density peaks higher at the middle
  end

  def test_vrp_never_sees_data_on_or_after_the_build_date
    vol_hist = (0...15).to_h do |i|
      [Dist.date_add('2026-09-01', i), { 7 => 0.7 }] # all >= build date
    end
    built = Dist.build_day(flat_board, BTC_SPOT, [], '2026-09-01', 'K',
                           vol_hist: vol_hist,
                           closes_map: const_closes('2026-09-01', 40))
    assert_nil built['row']['horizons'][0]['components']['rwm']
    assert_nil built['payload']['edge']
  end
end
