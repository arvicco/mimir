# frozen_string_literal: true
#
# flows.rb -- US spot-BTC ETF daily net flows: source-agnostic parsing
# shared by scripts/scenario/etf_flows.rb, the fixture recorder and the
# health probes (cross-suite consumers -> BTC::*). Pure functions: no
# IO, no ENV.
#
# parse_flows replaces the tag-strip + regex-soup parser whose number
# run swallowed each next row's day-of-month -- halving the rows AND
# reporting day numbers as daily totals (TOOL-REVIEW.md F-22). Parsing
# is per <tr>/<td>: a data row's FIRST cell is a date, the day's net
# total is its LAST numeric cell, (123.4) is negative. Header and
# Total/Average/Minimum/Maximum summary rows have no date cell and
# drop out naturally.

require 'time'

module BTC
  module Flows
    DATE_RE = /\A\d{1,2}\s+[A-Z][a-z]{2}\s+\d{4}\z/
    NUM_RE  = /\A\(?-?[\d,]+(?:\.\d+)?\)?\z/

    module_function

    # farside-style HTML flows table -> [[Time, Float US$m], ...] ascending.
    def parse_flows(html)
      html.scan(%r{<tr[^>]*>(.*?)</tr>}mi).filter_map do |(row)|
        cells = row.scan(%r{<t[dh][^>]*>(.*?)</t[dh]>}mi).map do |(c)|
          c.gsub(/<[^>]+>/, ' ').gsub(/&(?:[a-z]+|#\d+);/i, ' ').strip
        end
        next unless cells.first =~ DATE_RE

        num = cells.reverse.find { |c| c =~ NUM_RE }
        next unless num

        neg = num.start_with?('(', '-')
        val = num.delete('(),-').to_f
        [Time.parse("#{cells.first} 00:00:00 UTC"), neg ? -val : val]
      end.sort_by { |d, _| d }
    end

    # CoinGlass /api/etf/bitcoin/flow-history data rows (timestamp in
    # ms, flow_usd in raw USD) -> the same [[Time, Float US$m], ...].
    def from_coinglass(rows)
      rows.to_a.filter_map do |r|
        ts = r['timestamp'].to_i
        next if ts <= 0

        [Time.at(ts / 1000).utc, r['flow_usd'].to_f / 1e6]
      end.sort_by { |d, _| d }
    end
  end
end
