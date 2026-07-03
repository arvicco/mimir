#!/usr/bin/env ruby
# frozen_string_literal: true
#
# etf_flows.rb -- daily US spot-BTC ETF net flows (Farside Investors table).
# The marginal-buyer gauge: outflow deceleration is the A'->B' tell,
# sustained inflows the B' confirmation.
#
#   score +1  last-5d net inflow, or outflow shrunk >50% vs prior 5d
#   score -1  last-5d outflow steady/accelerating vs prior 5d
#   score  0  mixed / flat
#
# NOTE: this is an HTML scrape (farside.co.uk/btc/) -- the only good free
# daily source. Parser is deliberately tolerant, but layout drift will
# degrade it to score 0 rather than crash.

require_relative 'common'

NAME = 'etf_flows'

begin
  html = Common.get('https://farside.co.uk/btc/')
rescue StandardError => e
  Common.fail_soft(NAME, e.message)
end

# Strip tags, find rows "DD Mon YYYY <numbers...>"; last number in the row
# is the day's total in US$m. Negatives appear as (123.4) or -123.4.
text = html.gsub(%r{<[^>]+>}, ' ').gsub(/&[a-z]+;/, ' ')
rows = text.scan(/(\d{1,2}\s+[A-Z][a-z]{2}\s+\d{4})((?:\s+\(?-?[\d,.]+\)?)+)/)

daily = rows.map do |date, nums|
  vals = nums.scan(/\(?-?[\d,.]+\)?/).map do |s|
    neg = s.start_with?('(') || s.start_with?('-')
    v   = s.delete('(),-').to_f
    neg ? -v : v
  end
  vals.empty? ? nil : [Time.parse(date), vals.last]
end.compact.sort_by { |d, _| d }

Common.fail_soft(NAME, 'parse produced too few rows') if daily.size < 10

last5 = daily.last(5).map { |_, v| v }
prev5 = daily[-10, 5].map { |_, v| v }
s5    = last5.inject(:+)
p5    = prev5.inject(:+)

score =
  if s5 > 0 || (s5 < 0 && p5 < 0 && s5.abs < p5.abs * 0.5)
    1
  elsif s5 < 0 && s5.abs >= p5.abs * 0.9
    -1
  else
    0
  end

Common.report(NAME, score,
              format('5d net %+.0f$m (prev 5d %+.0f$m), last day %+.0f$m',
                     s5, p5, daily.last[1]),
              'last_5_days_usd_m' => last5.map { |v| v.round }.join(', '),
              'as_of' => daily.last[0].strftime('%Y-%m-%d'))
