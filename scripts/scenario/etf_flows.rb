#!/usr/bin/env ruby
# frozen_string_literal: true
#
# etf_flows.rb -- daily US spot-BTC ETF net flows. The marginal-buyer
# gauge: outflow deceleration is the A'->B' tell, sustained inflows the
# B' confirmation.
#
#   score +1  last-5d net inflow, or outflow shrunk >50% vs prior 5d
#   score -1  last-5d outflow steady/accelerating vs prior 5d
#   score  0  mixed / flat
#
# Sources, tried in order until one yields >= 10 daily rows (F-23):
#   1. farside.co.uk/btc/ (HTML) -- primary; intermittently behind a
#      Cloudflare JS challenge since 2026-07
#   2. the Internet Archive's latest snapshot of the same page
#      (raw web/2id_/ form, redirects followed; captured 2-4x/day, so
#      worst case ~12h lag -- acceptable for EOD flow windows)
#   3. CoinGlass ETF flow history, only when COINGLASS_API_KEY is set
#      (free Hobbyist key: coinglass.com -> API Management)
# Otherwise the module fails soft. The --json detail carries which
# source answered ('source', additive field 2026-07-04).
#
# Parsing is per table row (BTC::Flows): the old tag-strip regex
# swallowed each next row's day-of-month, halving the rows AND
# reporting day numbers as daily totals (F-22) -- history entries for
# this module predating 2026-07-04 are unreliable.

require_relative 'common'
require_relative '../../lib/btc/flows'
require_relative '../../lib/btc/http'

NAME = 'etf_flows'

FARSIDE   = 'https://farside.co.uk/btc/'
ARCHIVE   = 'https://web.archive.org/web/2id_/https://farside.co.uk/btc/'
COINGLASS = 'https://open-api-v4.coinglass.com/api/etf/bitcoin/flow-history'

daily  = nil
source = nil

# Replay (M12-1): HTML scrapes have no dated past -- the replay rides the
# Coinglass flow-history leg EXCLUSIVELY (677 daily rows at adoption),
# truncated to complete days. The row's source field says 'coinglass', so
# a replayed row is honest about which leg answered.
live_legs = Scenario.replay? ? [] :
  [['farside',         -> { Scenario.get(FARSIDE) }],
   ['farside-archive', -> { BTC::Http.get_follow(ARCHIVE, { 'User-Agent' => 'scenario.rb' }, read_timeout: 60) }]]

live_legs.each do |name, fetch|
  rows = begin
    BTC::Flows.parse_flows(fetch.call)
  rescue StandardError
    []
  end
  next if rows.size < 10

  daily  = rows
  source = name
  break
end

if daily.nil? && !ENV['COINGLASS_API_KEY'].to_s.empty?
  begin
    j = Scenario.get_json(COINGLASS, { 'CG-API-KEY' => ENV['COINGLASS_API_KEY'] })
    rows = BTC::Flows.from_coinglass(j['data'])
    rows = rows.select { |t, _| t < Scenario.as_of } if Scenario.replay?
    if rows.size >= 10
      daily  = rows
      source = 'coinglass'
    end
  rescue StandardError
    nil
  end
end

if daily.nil?
  Scenario.fail_soft(NAME, 'no flow source yielded enough rows ' \
                           '(farside blocked? set COINGLASS_API_KEY for the keyed fallback)')
end

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

Scenario.report(NAME, score,
              format('5d net %+.0f$m (prev 5d %+.0f$m), last day %+.0f$m',
                     s5, p5, daily.last[1]),
              'last_5_days_usd_m' => last5.map { |v| v.round }.join(', '),
              'as_of' => daily.last[0].strftime('%Y-%m-%d'),
              'source' => source)
