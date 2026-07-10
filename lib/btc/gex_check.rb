# frozen_string_literal: true
#
# gex_check.rb -- pure comparison math for the options-positioning
# cross-check (M8-3 / P-5): our own computed GEX walls & gamma flip
# (from scripts/gex.rb) versus Coinglass's Deribit max-pain view. No IO,
# no ENV, no network -- the gex_history.rb / metrics.rb pattern; the
# script scripts/gex_check.rb does the fetching and formatting.
#
# DESCRIPTIVE ONLY -- NO SCORING, NO VERDICT (owner ruling 2026-07-10,
# P-5 report-only): every number here is a distance or a weighted mean
# over the two views. No divergence threshold, no pass/fail, no signal
# is applied (Golden Rule 4 -- a divergence band is a research decision
# to be picked empirically after weeks of data).
#
#   max-pain rows (Coinglass option/max-pain, Deribit) carry:
#     date "YYMMDD", max_pain_price (string), call/put_open_interest.
#   option/info rows carry exchange_name + oi_market_share.
#
# SEMANTICS
#   nearest_expiry     -- the soonest expiry on/after `now`; if EVERY
#                         listed expiry is already past (stale board),
#                         falls back to the FIRST parseable row so the
#                         cross-check still reports something deterministic.
#   oi_weighted_max_pain -- sum(max_pain * (call+put OI)) / sum(call+put
#                         OI) across the listed expiries.
#   pct_delta(v, ref)  -- (v - ref) / ref * 100, 2dp; nil when either
#                         input is missing or ref is zero (no ratio to form).

require 'date'

module BTC
  module GexCheck
    module_function

    # "YYMMDD" -> Date (2026-07-11), or nil when blank/unparseable.
    def parse_date(str)
      s = str.to_s.strip
      return nil if s.empty?

      Date.strptime(s, '%y%m%d')
    rescue ArgumentError
      nil
    end

    # The soonest expiry row on/after +now+ (a Time/Date). Rows are the
    # Coinglass option/max-pain data array. Only rows with a parseable
    # date are considered. Returns the row hash, or nil when none parse.
    # Fallback: if every parseable expiry is already past, returns the
    # FIRST parseable row (input order) -- documented in the header so a
    # stale board still yields a deterministic nearest expiry.
    def nearest_expiry(rows, now)
      parsed = (rows || []).filter_map do |r|
        d = parse_date(r['date'])
        d && [d, r]
      end
      return nil if parsed.empty?

      today  = now.to_date
      future = parsed.select { |d, _| d >= today }
      (future.empty? ? parsed.first : future.min_by { |d, _| d })[1]
    end

    # max_pain_price of a row as a Float (the field is a JSON string),
    # or nil when the row is nil or the field is blank.
    def max_pain_price(row)
      v = row && row['max_pain_price']
      return nil if v.nil? || v.to_s.strip.empty?

      v.to_f
    end

    # call + put open interest of a row (the OI weight), as a Float.
    def oi_weight(row)
      return 0.0 if row.nil?

      row['call_open_interest'].to_f + row['put_open_interest'].to_f
    end

    # OI-weighted mean max pain across the listed expiries. Weight is
    # (call+put OI). nil when no row carries a price or total weight is 0.
    def oi_weighted_max_pain(rows)
      num = 0.0
      den = 0.0
      (rows || []).each do |r|
        mp = max_pain_price(r)
        next if mp.nil?

        w = oi_weight(r)
        num += mp * w
        den += w
      end
      den.zero? ? nil : num / den
    end

    # Deribit's option-OI market share (%) from the option/info rows,
    # for context on how representative the Deribit-only max pain is.
    # nil when no Deribit row is present.
    def deribit_oi_share(info_rows)
      row = (info_rows || []).find { |r| r['exchange_name'] == 'Deribit' }
      row && row['oi_market_share']&.to_f
    end

    # (value - reference) / reference * 100, 2dp. nil when either input
    # is missing or reference is zero.
    def pct_delta(value, reference)
      return nil if value.nil? || reference.nil?

      ref = reference.to_f
      return nil if ref.zero?

      ((value.to_f - ref) / ref * 100).round(2)
    end

    # Build the {theirs, deltas} comparison blocks. +ours+ is a hash with
    # :spot, :flip, :cw, :pw (any may be nil); +mp_rows+ / +info_rows+ are
    # the parsed Coinglass arrays; +now+ freezes the nearest-expiry pick.
    # Returns [theirs_hash, deltas_hash] with string keys (JSON-ready).
    def compare(ours, mp_rows, info_rows, now)
      near     = nearest_expiry(mp_rows, now)
      near_mp  = max_pain_price(near)
      near_dt  = near && parse_date(near['date'])
      oiw      = oi_weighted_max_pain(mp_rows)
      expiries = (mp_rows || []).count { |r| parse_date(r['date']) }

      theirs = {
        'nearest' => {
          'date'     => near_dt&.iso8601,
          'max_pain' => near_mp
        },
        'oi_weighted_max_pain' => oiw&.round(2),
        'expiries'             => expiries,
        'deribit_oi_share'     => deribit_oi_share(info_rows)
      }
      deltas = {
        'nearest_vs_pw_pct'   => pct_delta(near_mp, ours[:pw]),
        'nearest_vs_cw_pct'   => pct_delta(near_mp, ours[:cw]),
        'nearest_vs_spot_pct' => pct_delta(near_mp, ours[:spot]),
        'oiw_vs_flip_pct'     => pct_delta(oiw, ours[:flip])
      }
      [theirs, deltas]
    end
  end
end
