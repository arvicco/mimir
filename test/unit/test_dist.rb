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
                    n_degraded n_slices schema spot],
                 row.keys.sort
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
    assert_equal %w[as_of calendar_violations date headline horizons
                    n_degraded n_slices name spot ts],
                 p.keys.sort
    assert_equal 'dist', p['name']
    assert_equal '2026-09-01', p['as_of']
    assert_equal %w[d degraded extrapolated forward median p05 p95
                    sigma_atm sigma_rw],
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
