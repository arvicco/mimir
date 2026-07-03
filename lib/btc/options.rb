# frozen_string_literal: true
#
# options.rb -- shared options math and instrument parsing for the GEX
# tools (gex.rb, gex_us.rb, gex_btc_combined.rb) and suite modules.
# Pure functions only: no IO, no ENV, no ARGV. Extracted verbatim from
# the three previously-duplicated copies (TOOL-REVIEW.md F-14).

module BTC
  module Options
    MONTHS = Hash[%w[JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC]
                    .each_with_index.map { |m, i| [m, i + 1] }].freeze

    OSI = /\A[A-Z]+(\d{6})([CP])(\d{8})\z/

    YEAR_S = 365.25 * 86_400 # seconds per Julian year, the tools' T unit

    module_function

    # Dealer-positioning sign convention (naive dealer model): dealers
    # long calls (+), short puts (-). THE semantics-critical constant of
    # the GEX family -- defined exactly once.
    def sign(cp)
      cp == 'C' ? 1.0 : -1.0
    end

    def norm_pdf(x)
      Math.exp(-0.5 * x * x) / Math.sqrt(2 * Math::PI)
    end

    # Black-Scholes gamma with r = 0 (options priced off futures/forwards).
    def bs_gamma(s, k, t, v)
      return 0.0 if t <= 0 || v <= 0 || s <= 0 || k <= 0

      sq = v * Math.sqrt(t)
      d1 = (Math.log(s / k) + 0.5 * v * v * t) / sq
      norm_pdf(d1) / (s * sq)
    end

    # Gamma at hypothetical spot s: recompute via BS when IV is present,
    # fall back to the venue-provided static gamma (:gp) otherwise.
    def gamma_at(o, s)
      o[:iv] > 0 ? bs_gamma(s, o[:k], o[:t], o[:iv]) : o[:gp]
    end

    # Deribit expiry code ('27MAR26', '3JUL26') -> Time (08:00 UTC) or nil.
    def deribit_expiry(exp)
      m = exp && exp.match(/\A(\d{1,2})([A-Z]{3})(\d{2})\z/) or return nil
      mon = MONTHS[m[2]] or return nil
      Time.utc(2000 + m[3].to_i, mon, m[1].to_i, 8)
    end

    # OSI option symbol ('IBIT260327C00100000'; embedded spaces tolerated)
    # -> [expiry Time (21:00 UTC -- 4pm ET ignoring DST), 'C'|'P', strike]
    # or nil.
    def parse_osi(sym)
      m = OSI.match(sym.to_s.delete(' ')) or return nil
      d = m[1]
      [Time.utc(2000 + d[0, 2].to_i, d[2, 2].to_i, d[4, 2].to_i, 21),
       m[2], m[3].to_f / 1000.0]
    end

    # First zero crossing of net GEX over spot*[lo, hi]: yields each
    # hypothetical level x to the block, linearly interpolates the
    # crossing. Returns the unrounded level or nil (rounding stays at the
    # call sites, which historically differ).
    def gamma_flip(spot, lo = 0.70, hi = 1.30, step = 0.005)
      vals = (lo..hi).step(step).map do |f|
        x = spot * f
        [x, yield(x)]
      end
      cross = vals.each_cons(2).find { |(_, a), (_, b)| a.negative? ^ b.negative? }
      return nil unless cross

      (x0, y0), (x1, y1) = cross
      x0 - y0 * (x1 - x0) / (y1 - y0)
    end

    # Strike profile (level -> gex) restricted to +-band of spot ->
    # [near, call_wall, put_wall]; walls are [level, gex] pairs or nil.
    def walls(profile, spot, band = 0.30)
      near = profile.select { |k, _| (k - spot).abs / spot <= band }
      [near, near.max_by { |_, v| v }, near.min_by { |_, v| v }]
    end
  end
end
