#!/usr/bin/env ruby
# frozen_string_literal: true
#
# gex_check.rb -- options-positioning cross-check (M8-3 / P-5): our own
# computed GEX walls & gamma flip versus Coinglass's Deribit max-pain
# view. An advisory, OUTCOME-FIRST sanity check ON the GEX suite -- same
# philosophy as the BTCo ingest ref lines: it never feeds a score and
# never gates anything.
#
#   ruby scripts/gex_check.rb          # aligned human table
#   ruby scripts/gex_check.rb --json   # machine dump (frozen contract)
#
# WHAT IT COMPARES (DESCRIPTIVE ONLY -- owner ruling 2026-07-10, P-5
# report-only: NO divergence threshold, NO verdict, NO pass/fail; the
# band gets picked empirically after weeks of data, Golden Rule 4):
#   - nearest-expiry Deribit max pain vs our put_wall / call_wall / spot
#     (absolute and % distances)
#   - OI-weighted max pain across the listed expiries vs our gamma_flip
#   - Deribit's option-OI market share (context: how representative the
#     Deribit-only max pain is)
#
# OURS comes from `ruby scripts/gex.rb --json` run as a subprocess (the
# ops/gex_snapshot.rb pattern; gex.rb is Deribit-only, matching the
# Deribit max-pain source). THEIRS comes from the BTC::Coinglass seam
# (option/max-pain + option/info) -- the key is read ONLY through that
# seam, never here.
#
# FAIL-SOFT (Golden Rule: a dead API must never break an aggregate):
#   Coinglass down / no COINGLASS_API_KEY  -> theirs & deltas null, a
#   top-level `reason` explains, EXIT 0. Our own gex.rb failing likewise
#   nulls the `ours` block with a reason and still exits 0 -- this tool
#   is advisory and must never break anything downstream.
#
# --json CONTRACT (frozen from birth; every field always present, null
# where an input was unavailable):
#   { ts, spot,
#     ours:   { flip, cw, pw },
#     theirs: { nearest: { date, max_pain }, oi_weighted_max_pain,
#               expiries, deribit_oi_share } | null,
#     deltas: { nearest_vs_pw_pct, nearest_vs_cw_pct,
#               nearest_vs_spot_pct, oiw_vs_flip_pct } | null,
#     reason }                       # reason null on full success

require 'json'
require 'time'
require 'timeout'
require_relative '../lib/btc/coinglass'
require_relative '../lib/btc/gex_check'

json_mode = ARGV.include?('--json')
now       = Time.now.utc
reasons   = []

# ---- OURS: shell gex.rb --json (Deribit board) -----------------------------
GEX = File.expand_path('gex.rb', __dir__)

ours =
  begin
    out = +''
    Timeout.timeout(60) { IO.popen(['ruby', GEX, '--json']) { |io| out = io.read.to_s } }
    raise "gex.rb exit #{$?.exitstatus}" unless $?.success?

    j = JSON.parse(out)
    { spot: j['spot'], flip: j['gamma_flip'],
      cw: j.dig('call_wall', 'strike'), pw: j.dig('put_wall', 'strike'),
      ts: j['ts'] }
  rescue StandardError => e
    reasons << "our GEX view unavailable: #{e.message[0, 120]}"
    { spot: nil, flip: nil, cw: nil, pw: nil, ts: nil }
  end

# ---- THEIRS: Coinglass Deribit max pain + per-exchange OI ------------------
mp_rows = nil
info_rows = nil
begin
  mp_rows   = BTC::Coinglass.max_pain            # per-expiry Deribit max pain
  info_rows = BTC::Coinglass.option_info         # per-exchange option OI
rescue StandardError => e
  # Seam messages carry only endpoint path / envelope code (no secret);
  # the missing-key Error names COINGLASS_API_KEY, which is what the
  # operator needs to see.
  reasons << "Coinglass cross-check unavailable: #{e.message[0, 120]}"
end

if mp_rows || info_rows
  theirs, deltas = BTC::GexCheck.compare(ours, mp_rows, info_rows, now)
else
  theirs = nil
  deltas = nil
end

reason = reasons.empty? ? nil : reasons.join('; ')

result = {
  'ts'   => ours[:ts] || now.iso8601,
  'spot' => ours[:spot],
  'ours' => { 'flip' => ours[:flip], 'cw' => ours[:cw], 'pw' => ours[:pw] },
  'theirs' => theirs,
  'deltas' => deltas,
  'reason' => reason
}

# ---- output ----------------------------------------------------------------
if json_mode
  puts JSON.pretty_generate(result)
  exit 0
end

fmt_lvl = ->(v) { v ? format('%d', v.round) : '--' }
fmt_pct = ->(v) { v ? format('%+.2f%%', v) : '--' }
fmt_abs = ->(a, b) { a && b ? format('%+d', (a - b).round) : '--' }

puts format('GEX cross-check (Deribit)   %s', result['ts'])
puts format('  our spot            %s', fmt_lvl.(ours[:spot]))
puts format('  our call wall       %s', fmt_lvl.(ours[:cw]))
puts format('  our put wall        %s', fmt_lvl.(ours[:pw]))
puts format('  our gamma flip      %s', fmt_lvl.(ours[:flip]))
puts

if theirs
  near_mp  = theirs.dig('nearest', 'max_pain')
  near_dt  = theirs.dig('nearest', 'date') || '--'
  puts format('  nearest expiry      %s   max pain %s', near_dt, fmt_lvl.(near_mp))
  puts format('    vs put wall       %-9s (%s)', fmt_abs.(near_mp, ours[:pw]),
              fmt_pct.(deltas['nearest_vs_pw_pct']))
  puts format('    vs call wall      %-9s (%s)', fmt_abs.(near_mp, ours[:cw]),
              fmt_pct.(deltas['nearest_vs_cw_pct']))
  puts format('    vs spot           %-9s (%s)', fmt_abs.(near_mp, ours[:spot]),
              fmt_pct.(deltas['nearest_vs_spot_pct']))
  puts
  oiw = theirs['oi_weighted_max_pain']
  puts format('  OI-wtd max pain     %s   (%d expiries)', fmt_lvl.(oiw), theirs['expiries'])
  puts format('    vs gamma flip     %-9s (%s)', fmt_abs.(oiw, ours[:flip]),
              fmt_pct.(deltas['oiw_vs_flip_pct']))
  share = theirs['deribit_oi_share']
  puts format('  Deribit OI share    %s', share ? format('%.1f%%', share) : '--')
else
  puts format('  cross-check unavailable: %s', reason)
end
