#!/usr/bin/env ruby
# frozen_string_literal: true
#
# bubble_ref.rb -- independent bubble-gauge cross-reference (M12-4,
# Q-12). Publishes Coinglass's bitcoin bubble-index (daily history back
# to 2010) as an OUTSIDE check to sit beside the LPPL verdict -- the
# same evidence philosophy as the ingest ref lines: what does an
# independent instrument say about the thing we compute?
#
# ADVISORY ONLY. This is NEVER an input to the LPPL suite, the scenario
# composite, or any score -- it renders as one row on the LPPL card's
# SHADOW tab (via chart:lppl_shadow's optional input) and nothing else
# reads it. No thresholds here feed any verdict (Golden Rule 4 clean).
#
# USAGE
#   ruby scripts/bubble_ref.rb          # aligned human line
#   ruby scripts/bubble_ref.rb --json   # one machine line (frozen contract)
#
# --json FIELDS (frozen contract from birth; additive-only changes)
#   name 'bubble_ref', ts, value (latest bubble_index), date (its
#   date_string), pct (linear-rank percentile of the latest value among
#   the FULL fetched history -- the honest own-history read), band
#   (HIGH >= 80th pct / MID / LOW <= 20th pct, the house 80/20 idiom --
#   descriptive labels, not scores), n_days (history depth).
#
# DATA SOURCE
#   BTC::Coinglass.bubble_index (health-registered), via SourceCache
#   with a 24h ttl -- one API hit per day. Key: ENV['COINGLASS_API_KEY'].
#   Fail-soft: any error prints {'unavailable': true} with a reason and
#   exits 0 -- a dead gauge never breaks the publish (the SHADOW row
#   simply drops).

require_relative '../lib/btc/coinglass'
require 'json'
require 'time'

module BubbleRef
  module_function

  TTL = 86_400

  # Linear rank: share of history strictly below the latest value, %.
  def percentile(value, values)
    return nil if values.empty?

    100.0 * values.count { |v| v < value } / values.size
  end

  def band(pct)
    return 'HIGH' if pct >= 80.0
    return 'LOW'  if pct <= 20.0

    'MID'
  end

  # rows -> the payload hash (pure; exact-value unit tested).
  def compute(rows)
    raise 'no bubble-index rows' if rows.to_a.empty?

    values = rows.map { |r| r['bubble_index'].to_f }
    latest = rows.last
    pct = percentile(latest['bubble_index'].to_f, values)
    { 'value' => latest['bubble_index'].to_f.round(3),
      'date' => latest['date_string'].to_s,
      'pct' => pct.round(1), 'band' => band(pct),
      'n_days' => rows.size }
  end

  def run
    ts = Time.now.utc
    body = begin
      compute(BTC::Coinglass.bubble_index(cache: 'cg_bubble_index', ttl: TTL))
    rescue StandardError => e
      reason = e.is_a?(BTC::Coinglass::TierGated) ? 'tier-gated' : e.message
      out = { 'name' => 'bubble_ref', 'ts' => ts.iso8601,
              'headline' => "unavailable (#{reason})", 'unavailable' => true }
      puts(ARGV.include?('--json') ? JSON.generate(out) : out['headline'])
      exit 0
    end

    headline = format('bubble idx %+.2f (%s) | pct %.0f of %d days | %s',
                      body['value'], body['date'], body['pct'],
                      body['n_days'], body['band'])
    if ARGV.include?('--json')
      puts JSON.generate({ 'name' => 'bubble_ref', 'ts' => ts.iso8601,
                           'headline' => headline }.merge(body))
    else
      puts headline
    end
  end
end

BubbleRef.run if __FILE__ == $PROGRAM_NAME
