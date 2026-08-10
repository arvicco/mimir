# frozen_string_literal: true
#
# M8-3: exact-value unit tests for BTC::GexCheck -- the pure comparison
# math behind the options-positioning cross-check (nearest-expiry pick,
# OI weighting, pct deltas). No IO, no network; the recorded max-pain /
# option-info fixtures drive the fixture-shaped cases.

require_relative '../test_helper'
require_relative '../../lib/btc/gex_check'
require 'time'

class TestGexCheck < Minitest::Test
  MP   = 'coinglass_max_pain.json'
  INFO = 'coinglass_option_info.json'

  def mp_rows
    json_fixture(MP)['data']
  end

  def info_rows
    json_fixture(INFO)['data']
  end

  # ---- parse_date -------------------------------------------------------

  def test_parse_date_yymmdd
    assert_equal Date.new(2026, 7, 11), BTC::GexCheck.parse_date('260711')
  end

  def test_parse_date_blank_and_garbage_are_nil
    assert_nil BTC::GexCheck.parse_date('')
    assert_nil BTC::GexCheck.parse_date(nil)
    assert_nil BTC::GexCheck.parse_date('not-a-date')
  end

  # ---- nearest_expiry ---------------------------------------------------

  def test_nearest_expiry_picks_soonest_future_row
    now  = Time.parse('2026-07-04T18:27:00Z')
    near = BTC::GexCheck.nearest_expiry(mp_rows, now)
    assert_equal '260711', near['date']
  end

  def test_nearest_expiry_skips_past_expiries
    now  = Time.parse('2026-07-12T00:00:00Z') # 07-11 already past
    near = BTC::GexCheck.nearest_expiry(mp_rows, now)
    assert_equal '260712', near['date']
  end

  def test_nearest_expiry_all_past_falls_back_to_first_row
    now  = Time.parse('2027-01-01T00:00:00Z') # every fixture expiry past
    near = BTC::GexCheck.nearest_expiry(mp_rows, now)
    assert_equal '260711', near['date'] # first row, deterministic fallback
  end

  def test_nearest_expiry_empty_is_nil
    assert_nil BTC::GexCheck.nearest_expiry([], Time.now)
    assert_nil BTC::GexCheck.nearest_expiry(nil, Time.now)
  end

  # ---- max_pain_price ---------------------------------------------------

  def test_max_pain_price_parses_string_field
    assert_in_delta 63500.0, BTC::GexCheck.max_pain_price(mp_rows.first), 1e-9
  end

  def test_max_pain_price_nil_row_is_nil
    assert_nil BTC::GexCheck.max_pain_price(nil)
    assert_nil BTC::GexCheck.max_pain_price('max_pain_price' => '')
  end

  # ---- oi_weighted_max_pain --------------------------------------------

  def test_oi_weighted_max_pain_exact
    # sum(mp*(call+put)) / sum(call+put) over the 4 fixture rows.
    assert_in_delta 63530.180956, BTC::GexCheck.oi_weighted_max_pain(mp_rows), 1e-4
  end

  def test_oi_weighted_max_pain_empty_is_nil
    assert_nil BTC::GexCheck.oi_weighted_max_pain([])
    assert_nil BTC::GexCheck.oi_weighted_max_pain(nil)
  end

  def test_oi_weighted_single_row_is_that_price
    row = [{ 'max_pain_price' => '70000', 'call_open_interest' => 10.0,
             'put_open_interest' => 5.0 }]
    assert_in_delta 70000.0, BTC::GexCheck.oi_weighted_max_pain(row), 1e-9
  end

  def test_oi_weighted_zero_weight_is_nil
    row = [{ 'max_pain_price' => '70000', 'call_open_interest' => 0.0,
             'put_open_interest' => 0.0 }]
    assert_nil BTC::GexCheck.oi_weighted_max_pain(row)
  end

  # ---- deribit_oi_share -------------------------------------------------

  def test_deribit_oi_share_from_info
    assert_in_delta 82.21, BTC::GexCheck.deribit_oi_share(info_rows), 1e-9
  end

  def test_deribit_oi_share_absent_is_nil
    assert_nil BTC::GexCheck.deribit_oi_share([{ 'exchange_name' => 'OKX' }])
    assert_nil BTC::GexCheck.deribit_oi_share([])
  end

  # ---- pct_delta --------------------------------------------------------

  def test_pct_delta_exact
    assert_in_delta 22.12, BTC::GexCheck.pct_delta(63500.0, 52000), 1e-9
    assert_in_delta 5.83,  BTC::GexCheck.pct_delta(63500.0, 60000), 1e-9
    assert_in_delta 0.59,  BTC::GexCheck.pct_delta(63500.0, 63128.1), 1e-9
  end

  def test_pct_delta_nil_inputs_and_zero_ref
    assert_nil BTC::GexCheck.pct_delta(nil, 60000)
    assert_nil BTC::GexCheck.pct_delta(63500.0, nil)
    assert_nil BTC::GexCheck.pct_delta(63500.0, 0)
  end

  # ---- compare (assembled blocks) --------------------------------------

  def test_compare_full_fixture_shape
    now  = Time.parse('2026-07-04T18:27:00Z')
    ours = { spot: 63128.1, flip: nil, cw: 60000, pw: 52000 }
    theirs, deltas = BTC::GexCheck.compare(ours, mp_rows, info_rows, now)

    assert_equal '2026-07-11', theirs['nearest']['date']
    assert_in_delta 63500.0, theirs['nearest']['max_pain'], 1e-9
    assert_in_delta 63530.18, theirs['oi_weighted_max_pain'], 1e-9
    assert_equal 4, theirs['expiries']
    assert_in_delta 82.21, theirs['deribit_oi_share'], 1e-9

    assert_in_delta 22.12, deltas['nearest_vs_pw_pct'], 1e-9
    assert_in_delta 5.83,  deltas['nearest_vs_cw_pct'], 1e-9
    assert_in_delta 0.59,  deltas['nearest_vs_spot_pct'], 1e-9
    assert_nil deltas['oiw_vs_flip_pct'] # flip nil -> no ratio
  end

  def test_compare_missing_info_leaves_share_nil
    now  = Time.parse('2026-07-04T18:27:00Z')
    ours = { spot: 63128.1, flip: 61000, cw: 60000, pw: 52000 }
    theirs, deltas = BTC::GexCheck.compare(ours, mp_rows, nil, now)
    assert_nil theirs['deribit_oi_share']
    refute_nil deltas['oiw_vs_flip_pct'] # flip present -> delta computed
  end
end
