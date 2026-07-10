#!/usr/bin/env ruby
# frozen_string_literal: true
#
# gex_trend.rb -- descriptive time-series over the daily BTC-combined GEX
# snapshots in data/gex_history/ (one JSON per day, written by the GEX
# producer, accumulating since 2026-07-06). Turns the pile of daily files
# that NOTHING read into a time-aware view: flip-point distance per day,
# call/put wall migration, and gamma-regime persistence.
#
#   ruby scripts/gex_trend.rb              # full history, aligned table + footer
#   ruby scripts/gex_trend.rb --days 14    # only the last 14 daily files
#   ruby scripts/gex_trend.rb --json       # machine dump {ts,days,series,stats}
#
# DESCRIPTIVE ONLY -- NO SCORING. Every number here is read straight from
# the snapshots or is simple day-over-day arithmetic over them: no
# thresholds, weights, probabilities, or signals are applied, and the
# `regime` column merely restates the label each snapshot already recorded
# (Golden Rule 4 -- analytics semantics are owner research decisions; this
# tool only makes the existing data time-aware).
#
#   flip_dist_pct = (btc_spot - gamma_flip) / btc_spot * 100 (2dp) -- how
#   far spot sits above (+) / below (-) the day's gamma-flip level.
#   NETGEX$M column = combined net_gex_usd_per_1pct / 1e6 (display scaling
#   only; the --json series carries the raw value).
#
# Data source: data/gex_history/*.json (BTC_DATA_DIR/gex_history when
# BTC_DATA_DIR is set), read-only, sorted by filename date. Missing or
# corrupt daily files are skipped with a note on stderr, never fatal; zero
# usable days prints a note and exits 0 (fail-soft). NO network.
#
# Caveat: history starts 2026-07-06, so windows longer than the accumulated
# history simply return everything on disk.

require 'json'
require 'time'
require_relative '../lib/btc/env'
require_relative '../lib/btc/gex_history'

DEFAULT_DIR = File.expand_path('../data/gex_history', __dir__)

json_mode = ARGV.include?('--json')
days = nil
if (i = ARGV.index('--days'))
  days = ARGV[i + 1].to_i
end

dir = BTC::Env.data_dir('gex_history', DEFAULT_DIR)

# Load every daily file, sorted by filename (YYYY-MM-DD.json => chronological).
# A corrupt/unreadable file is skipped with a note, never fatal.
snaps = Dir.glob(File.join(dir, '*.json')).sort.filter_map do |path|
  JSON.parse(File.read(path))
rescue JSON::ParserError, SystemCallError => e
  warn "gex_trend: skipping #{File.basename(path)}: #{e.class}: #{e.message}"
  nil
end

# --days N window: keep the last N daily files (before dropping malformed days).
snaps = snaps.last(days) if days && days.positive?

rows  = BTC::GexHistory.series(snaps)
stats = BTC::GexHistory.stats(rows)

if json_mode
  puts JSON.pretty_generate(ts: Time.now.utc.iso8601, days: rows.length,
                            series: rows, stats: stats)
  exit 0
end

if rows.empty?
  warn "gex_trend: no usable GEX snapshots in #{dir} (history starts 2026-07-06)"
  exit 0
end

# ---- aligned human table ---------------------------------------------------
dash    = ->(v) { v.nil? ? '-' : v }
int_s   = ->(v) { v.nil? ? '-' : format('%d', v) }
spot_s  = ->(v) { v.nil? ? '-' : format('%.1f', v.to_f) }
dist_s  = ->(v) { v.nil? ? '-' : format('%+.2f', v) }
gexm_s  = ->(v) { v.nil? ? '-' : format('%+.1f', v.to_f / 1e6) }

HDR = '%-11s %10s %8s %8s %8s %8s %11s  %s'
ROW = HDR

puts format(HDR, 'DATE', 'SPOT', 'FLIP', 'DIST%', 'CW', 'PW', 'NETGEX$M', 'REGIME')
rows.each do |r|
  puts format(ROW, r['date'], spot_s.call(r['spot']), int_s.call(r['flip']),
              dist_s.call(r['flip_dist_pct']), int_s.call(r['cw']),
              int_s.call(r['pw']), gexm_s.call(r['net_gex']), dash.call(r['regime']))
end

# ---- stats footer ----------------------------------------------------------
puts
puts format('days=%d  regime=%s (%dd run)  transitions=%d  cw_moves=%d  pw_moves=%d',
            stats['days'], dash.call(stats['regime']), stats['regime_days'],
            stats['transitions'], stats['cw_moves'], stats['pw_moves'])
puts format('flip_dist%%: min=%s  max=%s  last=%s',
            dist_s.call(stats['flip_dist_pct_min']),
            dist_s.call(stats['flip_dist_pct_max']),
            dist_s.call(stats['flip_dist_pct_last']))
