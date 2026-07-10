# frozen_string_literal: true
#
# basis.rb -- pure descriptive math for scripts/basis.rb (M8-4). No IO,
# no ENV, no ARGV: annualized futures basis, perpetual premium, and the
# trailing means of the funding series. DESCRIPTIVE ONLY -- no thresholds,
# verdicts, or regime labels (Golden Rule 4): callers turn these numbers
# into display, never into a score.

module BTC
  module Basis
    module_function

    # Annualized basis in PERCENT for a dated future:
    #   (mark / spot - 1) * (365.25 / days) * 100
    # Returns nil for degenerate inputs (non-positive spot or days).
    def annualized_basis_pct(mark, spot, days)
      return nil if spot.nil? || spot <= 0 || days.nil? || days <= 0

      (mark / spot - 1.0) * (365.25 / days) * 100.0
    end

    # Simple percent premium of a perpetual mark over spot (NOT annualized:
    # a perp has no expiry). Returns nil for non-positive spot.
    def perp_premium_pct(mark, spot)
      return nil if spot.nil? || spot <= 0

      (mark / spot - 1.0) * 100.0
    end

    # Mean of the last n values present (or fewer if the series is shorter
    # than n -- a simple descriptive average over whatever history exists).
    # Returns nil for an empty series.
    def trailing_mean(values, n)
      return nil if values.empty?

      window = values.last(n)
      window.sum.to_f / window.size
    end
  end
end
