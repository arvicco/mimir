#!/usr/bin/env ruby
# frozen_string_literal: true
#
# scorecard.rb -- track-record CLI for our own published signals (P-19).
# Loads the recorded ledgers (LPPL, scenario, GEX history), turns each
# signal into a dated band series, and scores every band against the
# realized forward BTC return via BTC::Scorecard (lib/btc/scorecard.rb,
# M10-5). RESEARCH OUTPUT ONLY: report-only, reads nothing but local
# ledgers + the lppl price cache, writes nothing, changes no payload and
# no analytics semantics.
#
#   ruby scripts/scorecard.rb           # aligned track-record table
#   ruby scripts/scorecard.rb --json    # machine dump (frozen contract)
#
# SEMANTICS (owner ruling D10-a; the authority is lib/btc/scorecard.rb):
#   For a signal stamped during UTC day t, entry = close(t), exit =
#   close(t+h); the outcome is the log return, reported per band as
#   mean_pct / pos_pct next to the same-window unconditional 'ALL' row.
#   NO verdicts, NO p-values -- the reader compares each band against
#   ALL. A horizon cell renders stats only when n >= MIN_N and the
#   series spans >= SPAN_FACTOR*h days; otherwise it is ineligible and
#   every cell prints '--' (the "n too small" footnote).
#
# CAVEAT (overlap): daily-sampled h-day returns overlap heavily, so n
#   overstates independent evidence. The engine's n_eff = n/h (carried in
#   --json) is the honest count; treat the table as descriptive history,
#   not a significance test.
#
# SIGNALS
#   lppl_verdict           band = ledger verdict (STRESSED/NEUTRAL/...)
#   lppl_trend/envelope/fit band = that module's score as '+1'/'0'/'-1'
#   scenario_regime        band = history regime
#   scenario_<module>      one per scores key, band = '+1'/'0'/'-1'
#   gex_gamma_sign         band = 'POS' when spot > gamma flip else 'NEG'
#                          (spot above the flip = positive dealer gamma)
#
# DATA SOURCES (all local, read-only, resolved via BTC::Env.data_dir):
#   <lppl>/prices.csv       daily 'date,close' closes -- the join reference
#   <lppl>/ledger.jsonl     LPPL verdict/score ledger
#   <scenario>/history.jsonl scenario regime/score history
#   <gex_history>/*.json    one BTC-combined GEX snapshot per day
#   Multiple rows for one UTC date dedup to the LAST. Missing/short
#   ledgers degrade to explicit rows:0 signals; every failure is
#   fail-soft (exit 0). NO network.

require 'json'
require 'time'
require_relative '../lib/btc/env'
require_relative '../lib/btc/scorecard'

module SignalScorecard
  module_function

  LPPL_DEFAULT     = File.expand_path('lppl/data', __dir__)
  SCENARIO_DEFAULT = File.expand_path('scenario/data', __dir__)
  GEX_DEFAULT      = File.expand_path('../data/gex_history', __dir__)

  LPPL_SCORE_KEYS = %w[trend envelope fit].freeze

  # ---- pure helpers ----------------------------------------------------------

  # UTC calendar day of an ISO8601 timestamp (the ledger's row date).
  def ts_to_date(ts)
    Time.iso8601(ts).utc.strftime('%Y-%m-%d')
  end

  # Integer module score -> band label: '+1' / '0' / '-1'; nil passes
  # through (a missing score yields no row).
  def fmt_score(score)
    return nil if score.nil?

    n = score.to_i
    n.zero? ? '0' : format('%+d', n)
  end

  # One band row from a timestamp + label; nil when either is absent so
  # the caller's filter_map drops it.
  def band_row(ts, band)
    return nil if ts.nil? || band.nil?

    { 'date' => ts_to_date(ts), 'band' => band }
  end

  # Engine contract: one row per date. Keep the LAST row seen for each
  # date (ledgers append chronologically, so last == most recent).
  def dedup_last_per_day(series)
    by_date = {}
    series.each { |r| by_date[r['date']] = r }
    by_date.values
  end

  # Parse a 'date,close' price stream into { 'YYYY-MM-DD' => close }.
  # Header and sub-dust rows (< 0.05, matching the lppl loader) dropped.
  def parse_prices(lines)
    out = {}
    lines.each do |ln|
      d, c = ln.strip.split(',')
      next if d.nil? || d == 'date'

      v = c.to_f
      next if v < 0.05

      out[d] = v
    end
    out
  end

  # ---- per-source signal extraction ------------------------------------------

  # LPPL ledger rows -> ordered { signal => deduped band series }.
  def lppl_signals(rows)
    sig = {}
    sig['lppl_verdict'] =
      dedup_last_per_day(rows.filter_map { |r| band_row(r['ts'], r['verdict']) })
    LPPL_SCORE_KEYS.each do |k|
      sig["lppl_#{k}"] =
        dedup_last_per_day(rows.filter_map { |r| band_row(r['ts'], fmt_score(dig_score(r, k))) })
    end
    sig
  end

  # Scenario history rows -> regime + one signal per scores key present.
  def scenario_signals(rows)
    sig = {}
    sig['scenario_regime'] =
      dedup_last_per_day(rows.filter_map { |r| band_row(r['ts'], r['regime']) })
    module_keys(rows).each do |k|
      sig["scenario_#{k}"] =
        dedup_last_per_day(rows.filter_map { |r| band_row(r['ts'], fmt_score(dig_score(r, k))) })
    end
    sig
  end

  # GEX daily snapshots -> the gamma-sign signal (spot vs flip). A
  # snapshot missing spot or flip is skipped (no proxy invented).
  def gex_signals(snaps)
    series = snaps.filter_map do |s|
      c    = s['btc_combined'] || {}
      spot = c['btc_spot']
      flip = (c['combined'] || {})['gamma_flip']
      date = s['date'] || (c['ts'] && ts_to_date(c['ts']))
      next nil if spot.nil? || flip.nil? || date.nil?

      { 'date' => date, 'band' => (spot.to_f > flip.to_f ? 'POS' : 'NEG') }
    end
    { 'gex_gamma_sign' => dedup_last_per_day(series) }
  end

  def dig_score(row, key)
    (row['scores'] || {})[key]
  end

  def module_keys(rows)
    rows.flat_map { |r| (r['scores'] || {}).keys }.uniq
  end

  # ---- file loaders (fail-soft) ----------------------------------------------

  def load_jsonl(path)
    return [] unless File.exist?(path)

    File.foreach(path).filter_map do |ln|
      ln = ln.strip
      ln.empty? ? nil : JSON.parse(ln)
    rescue JSON::ParserError
      nil
    end
  end

  def load_gex_snaps(dir)
    return [] unless Dir.exist?(dir)

    Dir.glob(File.join(dir, '*.json')).sort.filter_map do |p|
      JSON.parse(File.read(p))
    rescue JSON::ParserError, SystemCallError
      nil
    end
  end

  def load_prices(path)
    return {} unless File.exist?(path)

    parse_prices(File.foreach(path))
  end

  # ---- assembly --------------------------------------------------------------

  # Load every ledger, build the signal series, score each against the
  # daily closes. Returns [results, provenance].
  def build(lppl_dir:, scenario_dir:, gex_dir:, horizons: BTC::Scorecard::HORIZONS)
    prices    = load_prices(File.join(lppl_dir, 'prices.csv'))
    lppl_rows = load_jsonl(File.join(lppl_dir, 'ledger.jsonl'))
    scen_rows = load_jsonl(File.join(scenario_dir, 'history.jsonl'))
    gex_snaps = load_gex_snaps(gex_dir)

    signals = {}
    signals.merge!(lppl_signals(lppl_rows))
    signals.merge!(scenario_signals(scen_rows))
    signals.merge!(gex_signals(gex_snaps))

    results = signals.transform_values do |series|
      dates = series.map { |r| r['date'] }.sort
      { 'ledger'   => { 'rows' => series.length, 'from' => dates.first, 'to' => dates.last },
        'horizons' => BTC::Scorecard.score(series, prices, horizons: horizons) }
    end

    [results, provenance(lppl_rows, scen_rows, gex_snaps)]
  end

  def provenance(lppl_rows, scen_rows, gex_snaps)
    { 'lppl'     => src_span(lppl_rows.filter_map { |r| ts_to_date(r['ts']) if r['ts'] }),
      'scenario' => src_span(scen_rows.filter_map { |r| ts_to_date(r['ts']) if r['ts'] }),
      'gex'      => src_span(gex_snaps.filter_map { |s| s['date'] }) }
  end

  def src_span(dates)
    ds = dates.sort
    { 'rows' => ds.length, 'from' => ds.first, 'to' => ds.last }
  end

  # ---- --json contract -------------------------------------------------------

  def json_doc(results, horizons)
    { 'generated_at' => Time.now.utc.iso8601,
      'horizons'     => horizons,
      'signals'      => results }
  end

  # ---- terminal table --------------------------------------------------------

  SIG_W   = 22
  BAND_W  = 10
  N_W     = 6
  MEAN_W  = 7
  POS_W   = 6
  GAP     = '   '
  GROUP_W = N_W + 1 + MEAN_W + 1 + POS_W

  def render_table(results, horizons)
    puts group_header(horizons)
    puts col_header(horizons)
    ineligible = false
    results.each do |name, data|
      hs    = data['horizons']
      bands = horizons.flat_map { |h| (hs[h.to_s]['bands'] || {}).keys }.uniq.sort
      puts row_line(name, 'ALL', horizons.map { |h| all_cell(hs[h.to_s]) })
      bands.each do |b|
        puts row_line('', b, horizons.map { |h| band_cell(hs[h.to_s], b) })
      end
      ineligible ||= horizons.any? { |h| !hs[h.to_s]['eligible'] }
    end
    return unless ineligible

    puts
    puts format('-- = ineligible cell (n too small: needs n >= %d and span >= %d*h days)',
                BTC::Scorecard::MIN_N, BTC::Scorecard::SPAN_FACTOR)
  end

  def all_cell(cell)
    return dash_cell unless cell['eligible']

    stat_cell(cell['n'], cell['all']['mean_pct'], cell['all']['pos_pct'])
  end

  def band_cell(cell, band)
    b = cell['eligible'] && (cell['bands'] || {})[band]
    b ? stat_cell(b['n'], b['mean_pct'], b['pos_pct']) : dash_cell
  end

  def stat_cell(n, mean, pos)
    format("%#{N_W}d %+#{MEAN_W}.2f %#{POS_W}.1f", n, mean, pos)
  end

  def dash_cell
    format("%#{N_W}s %#{MEAN_W}s %#{POS_W}s", '--', '--', '--')
  end

  def row_line(sig, band, cells)
    format("%-#{SIG_W}s %-#{BAND_W}s", sig, band) + GAP + cells.join(GAP)
  end

  # Line 1: centered horizon label over each stat group.
  def group_header(horizons)
    prefix = ' ' * (SIG_W + 1 + BAND_W)
    groups = horizons.map do |h|
      lbl = "#{h}d"
      pad = GROUP_W - lbl.length
      (' ' * (pad / 2)) + lbl + (' ' * (pad - pad / 2))
    end
    prefix + GAP + groups.join(GAP)
  end

  # Line 2: N / MEAN% / POS% under each group.
  def col_header(horizons)
    prefix = format("%-#{SIG_W}s %-#{BAND_W}s", 'SIGNAL', 'BAND')
    group  = format("%#{N_W}s %#{MEAN_W}s %#{POS_W}s", 'N', 'MEAN%', 'POS%')
    prefix + GAP + ([group] * horizons.length).join(GAP)
  end

  def render_provenance(prov)
    puts format('sources: lppl %s | scenario %s | gex %s',
                span_str(prov['lppl']), span_str(prov['scenario']), span_str(prov['gex']))
  end

  def span_str(s)
    return '0 rows' if s['rows'].zero?

    format('%d rows %s..%s', s['rows'], s['from'], s['to'])
  end

  # ---- entry point -----------------------------------------------------------

  def main(argv = ARGV)
    horizons = BTC::Scorecard::HORIZONS
    results, prov = build(
      lppl_dir:     BTC::Env.data_dir('lppl', LPPL_DEFAULT),
      scenario_dir: BTC::Env.data_dir('scenario', SCENARIO_DEFAULT),
      gex_dir:      BTC::Env.data_dir('gex_history', GEX_DEFAULT),
      horizons:     horizons
    )

    if argv.include?('--json')
      puts JSON.pretty_generate(json_doc(results, horizons))
    else
      render_table(results, horizons)
      puts
      render_provenance(prov)
    end
    0
  end
end

exit SignalScorecard.main if $PROGRAM_NAME == __FILE__
