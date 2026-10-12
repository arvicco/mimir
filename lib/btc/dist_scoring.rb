# frozen_string_literal: true
#
# dist_scoring.rb -- proper scoring rules for published price
# distributions (M13-2, skuld S-A). Every density the dist producer
# publishes is stored as a QUANTILE GRID ([[tau, q], ...], tau
# ascending in (0,1), q the price at that cumulative probability);
# all four rules score that representation directly, so the ledger
# stays compact and the scoring needs no separate density encoding.
#
#   BTC::DistScoring.crps(quantiles, y)       # continuous ranked prob. score
#   BTC::DistScoring.pit(quantiles, y)        # F(y), the calibration draw
#   BTC::DistScoring.log_score(quantiles, y)  # ln density at y (nil off-grid)
#   BTC::DistScoring.brier(p, hit)            # (p - 1{hit})^2 for digitals
#
# SEMANTICS
#   crps       average pinball loss * 2 over the grid's tau levels:
#              (2/N) * sum_i rho_tau_i(y, q_i). Exact for a point mass
#              (-> |y - x|) whenever the tau levels average 0.5, i.e.
#              any symmetric grid; converges to true CRPS as the grid
#              densifies. Lower = better; always >= 0.
#   pit        linear interpolation of tau in q; outside the grid it
#              CLAMPS to the edge taus (a 1..99% grid can never report
#              0 or 1 -- documented, not hidden; tail resolution is
#              bounded by the grid's edge levels).
#   log_score  density between adjacent quantiles is
#              (tau_i+1 - tau_i)/(q_i+1 - q_i); returns ln of the
#              bracket containing y, nil when y falls outside the grid
#              span (unscorable at this grid -- callers record that
#              honestly instead of inventing a tail density).
#   brier      plain quadratic score for a digital's probability.
#
# Pure functions, no IO, no clock. Grids must be strictly ascending in
# both tau and q; a flat (point-mass) q run is tolerated by crps/pit
# but yields nil log_score (zero-width bracket).

module BTC
  module DistScoring
    module_function

    # Continuous ranked probability score from a quantile grid.
    def crps(quantiles, y)
      n = quantiles.size.to_f
      2.0 / n * quantiles.sum do |tau, q|
        y >= q ? (y - q) * tau : (q - y) * (1.0 - tau)
      end
    end

    # Probability integral transform: F(y) interpolated from the grid,
    # clamped to the edge tau levels outside it.
    def pit(quantiles, y)
      return quantiles.first[0] if y <= quantiles.first[1]
      return quantiles.last[0] if y >= quantiles.last[1]

      quantiles.each_cons(2) do |(t0, q0), (t1, q1)|
        next unless y >= q0 && y <= q1
        return t0 if q1 == q0

        return t0 + (t1 - t0) * (y - q0) / (q1 - q0)
      end
      quantiles.last[0] # unreachable with an ascending grid; belt+braces
    end

    # ln density at y from adjacent quantile spacing; nil off-grid or on
    # a zero-width bracket.
    def log_score(quantiles, y)
      return nil if y < quantiles.first[1] || y > quantiles.last[1]

      quantiles.each_cons(2) do |(t0, q0), (t1, q1)|
        next unless y >= q0 && y <= q1
        return nil if q1 == q0

        return Math.log((t1 - t0) / (q1 - q0))
      end
      nil
    end

    # Quadratic (Brier) score for a digital: p = published probability,
    # hit = whether the event occurred.
    def brier(p, hit)
      (p - (hit ? 1.0 : 0.0))**2
    end
  end
end
