# frozen_string_literal: true
#
# vol.rb -- implied-volatility surface & skew from a Deribit option book.
# Pure functions only: no IO, no ENV, no ARGV. First of the vol family
# (M8-1); the IV-extraction seam M8-2/M8-5 reuse.
#
# PURPOSE
#   gex.rb already parses mark_iv per instrument but discards it after the
#   gamma calc. Vol.surface re-reads the same book rows and reports, per
#   tenor bucket, the three numbers the options desk actually watches:
#   ATM implied vol, 25-delta risk reversal (skew), and 25-delta butterfly
#   (smile curvature). GEX says how dealers are positioned; skew says what
#   the market pays for tails.
#
# INPUT
#   book: array of rows shaped exactly as gex.rb builds them --
#     { k:  strike (Float),
#       cp: 'C' | 'P',
#       t:  time to expiry in YEARS (Float, Julian-year basis),
#       iv: mark IV as a FRACTION (0.45 == 45%),
#       oi: open interest,
#       u:  the row's own underlying/forward price }
#   Rows are grouped into expiries by their +t+ (each Deribit expiry has one
#   t), so the caller need not pre-bucket.
#
# SEMANTICS (owner-approved 2026-07-10 -- do not deviate)
#   * days = t * 365.25 (same Julian-year basis as BTC::Options::YEAR_S).
#   * For each target tenor pick the EXPIRY whose days are closest to the
#     target (ties -> first). The same expiry may back two targets when the
#     board is thin; expiry_d makes that degeneracy visible.
#   * ATM strike = the strike nearest that expiry's underlying u (mean u of
#     the expiry's rows). atm_iv = mean of the C and P iv at that strike, or
#     whichever side exists.
#   * 25-delta selection: compute BTC::Options.bs_delta from each row's OWN
#     iv and u; pick the call whose delta is closest to +0.25 and the put
#     whose delta is closest to -0.25. Nearest strike, NO interpolation
#     (v1 simplification).
#   * rr25  = iv(25d call) - iv(25d put)
#   * fly25 = (iv(25d call) + iv(25d put)) / 2 - atm_iv
#
# FAIL-SOFT
#   A tenor whose chosen expiry has fewer than 3 calls OR fewer than 3 puts
#   reports atm_iv when computable but rr25 = fly25 = nil and a human
#   'reason'. An empty board reports every field nil/0 with a reason. The
#   'reason' key is ALWAYS present (nil on success) so scripts/vol.rb's
#   --json field set stays constant regardless of which tenors degrade.
#
# CAVEATS
#   Nearest-strike 25-delta with no interpolation is coarse on sparse
#   boards; rr25/fly25 read as indicative, not tradeable quotes. Inverse
#   (coin-margined) BTC/ETH board only, matching gex.rb's coverage.

require_relative 'options'

module BTC
  module Vol
    MIN_SIDE = 3 # calls AND puts needed before rr25/fly25 are computed
    DEFAULT_TARGETS = [7, 30, 90].freeze

    module_function

    # book -> array of per-tenor hashes, one per target (in target order).
    # Each hash: { tenor_d:, expiry_d:, atm_iv:, rr25:, fly25:, n_calls:,
    #              n_puts:, reason: }.
    def surface(book, targets: DEFAULT_TARGETS)
      expiries = book.group_by { |o| o[:t] }.map do |t, rows|
        { days: t * 365.25, rows: rows } # Julian-year basis (== YEAR_S)
      end
      targets.map { |target| tenor(target, expiries) }
    end

    # One target tenor against the pre-grouped expiries.
    def tenor(target, expiries)
      if expiries.empty?
        return row(target, nil, nil, nil, nil, 0, 0, 'no expiries in book')
      end

      chosen   = expiries.min_by { |e| (e[:days] - target).abs }
      rows     = chosen[:rows]
      calls    = rows.select { |r| r[:cp] == 'C' }
      puts_    = rows.select { |r| r[:cp] == 'P' }
      expiry_d = chosen[:days].round(1)

      atm_iv = atm_iv(rows)

      if calls.size < MIN_SIDE || puts_.size < MIN_SIDE
        reason = format('thin tenor: %d calls, %d puts (need %d each)',
                        calls.size, puts_.size, MIN_SIDE)
        return row(target, expiry_d, atm_iv, nil, nil, calls.size, puts_.size, reason)
      end

      c25 = nearest_delta(calls, 0.25)
      p25 = nearest_delta(puts_, -0.25)
      rr  = c25[:iv] - p25[:iv]
      fly = atm_iv && ((c25[:iv] + p25[:iv]) / 2.0 - atm_iv)

      row(target, expiry_d, atm_iv, rr, fly, calls.size, puts_.size, nil)
    end

    # Mean u of the rows -> nearest strike -> mean iv of the C/P at it.
    def atm_iv(rows)
      return nil if rows.empty?

      u      = rows.sum { |r| r[:u] } / rows.size
      atm_k  = rows.min_by { |r| (r[:k] - u).abs }[:k]
      ivs    = rows.select { |r| r[:k] == atm_k }.map { |r| r[:iv] }
      ivs.empty? ? nil : ivs.sum / ivs.size
    end

    # Row whose bs_delta (own iv + own u) is closest to +target.
    def nearest_delta(rows, target)
      rows.min_by do |r|
        (BTC::Options.bs_delta(r[:u], r[:k], r[:t], r[:iv], r[:cp]) - target).abs
      end
    end

    def row(tenor_d, expiry_d, atm_iv, rr25, fly25, n_calls, n_puts, reason)
      { tenor_d: tenor_d, expiry_d: expiry_d, atm_iv: atm_iv,
        rr25: rr25, fly25: fly25, n_calls: n_calls, n_puts: n_puts,
        reason: reason }
    end
  end
end
