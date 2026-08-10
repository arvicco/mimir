# frozen_string_literal: true
#
# gex_history.rb -- descriptive time-series analytics over the daily GEX
# snapshots accumulated in data/gex_history/ (one JSON per day, since
# 2026-07-06). Pure functions over an array of already-parsed snapshot
# hashes, sorted ascending by date by the caller. No IO, no ENV, no
# network (the metrics.rb / validate_core.rb pattern).
#
# PURELY DESCRIPTIVE: no thresholds, no scores, no signals, no regime
# judgments beyond restating the `regime` string each snapshot already
# recorded (Golden Rule 4 -- scoring thresholds/weights/regime rules are
# owner research decisions; this module only makes the existing data
# time-aware).
#
# Each daily snapshot carries btc_combined.combined{net_gex_usd_per_1pct,
# regime, gamma_flip, call_wall{level,gex}, put_wall{level,gex}, ...} plus
# btc_combined.btc_spot, and a `us` array of the day's per-underlying
# gex_us.rb captures (IBIT, MSTR). Days missing btc_combined or its combined
# block are skipped (fail-soft: a partial/corrupt daily file never breaks the
# series); #mstr_series (M8-18) reads the MSTR `us` entry the same way, on
# MSTR's own dollar axis.
#
#   flip_dist_pct = (btc_spot - gamma_flip) / btc_spot * 100, 2dp -- how
#   far spot sits above (+) / below (-) the day's gamma-flip level.

module BTC
  module GexHistory
    module_function

    # Per-day rows drawn from btc_combined.combined (+ btc_combined.btc_spot).
    # snaps: array of parsed snapshot hashes, date-ascending. Returns rows in
    # the same order; days without a usable combined block are dropped.
    def series(snaps)
      (snaps || []).filter_map do |snap|
        bc = snap.is_a?(Hash) ? snap['btc_combined'] : nil
        c  = bc.is_a?(Hash) ? bc['combined'] : nil
        next unless c.is_a?(Hash)

        spot = bc['btc_spot']
        flip = c['gamma_flip']
        {
          'date' => snap['date'],
          'spot' => spot,
          'flip' => flip,
          'flip_dist_pct' => flip_dist_pct(spot, flip),
          'cw' => c.dig('call_wall', 'level'),
          'pw' => c.dig('put_wall', 'level'),
          'net_gex' => c['net_gex_usd_per_1pct'],
          'regime' => c['regime']
        }
      end
    end

    # Per-day rows for MicroStrategy (MSTR) drawn from each snapshot's `us`
    # capture (M8-18). Each daily snapshot carries a `us` array = the verbatim
    # gex_us.rb --json output per US underlying; the MSTR entry holds
    # {spot, gamma_flip, call_wall{strike}, put_wall{strike},
    # net_gex_usd_per_1pct, regime}. Same row shape as #series (so #stats
    # works unchanged), on MSTR's OWN dollar axis. Days without a usable MSTR
    # capture are dropped (an honest gap), exactly like #series drops days
    # without a combined block. Note the walls sit under 'strike' here (the
    # single-name chain), not the BTC combined block's 'level'.
    def mstr_series(snaps)
      (snaps || []).filter_map do |snap|
        m = mstr_entry(snap)
        next unless m.is_a?(Hash)

        spot = m['spot']
        flip = m['gamma_flip']
        {
          'date' => snap['date'],
          'spot' => spot,
          'flip' => flip,
          'flip_dist_pct' => flip_dist_pct(spot, flip),
          'cw' => m.dig('call_wall', 'strike'),
          'pw' => m.dig('put_wall', 'strike'),
          'net_gex' => m['net_gex_usd_per_1pct'],
          'regime' => m['regime']
        }
      end
    end

    # The MSTR element of a snapshot's `us` capture array, or nil when the
    # snapshot has no `us` array or no MSTR entry (fail-soft: a partial daily
    # file never breaks the series).
    def mstr_entry(snap)
      us = snap.is_a?(Hash) ? snap['us'] : nil
      return nil unless us.is_a?(Array)

      us.find { |e| e.is_a?(Hash) && e['ticker'] == 'MSTR' }
    end

    # (spot - flip) / spot * 100, rounded to 2dp. nil when either input is
    # missing or spot is non-positive (no ratio to form).
    def flip_dist_pct(spot, flip)
      return nil if spot.nil? || flip.nil?

      s = spot.to_f
      return nil if s <= 0

      ((s - flip.to_f) / s * 100).round(2)
    end

    # Descriptive stats over #series rows (date-ascending). Restates the
    # recorded regimes over time; invents no new labels.
    #   days:               usable-day count
    #   regime:             the current (last) day's recorded regime
    #   regime_days:        length of the terminal run of identical regime
    #   transitions:        day-over-day regime changes
    #   cw_moves/pw_moves:  days the call/put wall level changed vs prior day
    #   flip_dist_pct_*:    min / max (over days that have one) / last
    def stats(rows)
      rows = rows || []
      regimes = rows.map { |r| r['regime'] }
      dists   = rows.filter_map { |r| r['flip_dist_pct'] }
      {
        'days' => rows.length,
        'regime' => rows.empty? ? nil : regimes.last,
        'regime_days' => terminal_run(regimes),
        'transitions' => changes(regimes),
        'cw_moves' => changes(rows.map { |r| r['cw'] }),
        'pw_moves' => changes(rows.map { |r| r['pw'] }),
        'flip_dist_pct_min' => dists.min,
        'flip_dist_pct_max' => dists.max,
        'flip_dist_pct_last' => rows.empty? ? nil : rows.last['flip_dist_pct']
      }
    end

    # Length of the terminal run of values equal to the last one.
    def terminal_run(seq)
      return 0 if seq.empty?

      last = seq.last
      run = 0
      seq.reverse_each { |v| v == last ? run += 1 : break }
      run
    end

    # Count of day-over-day value changes (nil vs a level counts as a change).
    def changes(seq)
      seq.each_cons(2).count { |a, b| a != b }
    end
  end
end
