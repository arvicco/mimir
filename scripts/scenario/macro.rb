#!/usr/bin/env ruby
# frozen_string_literal: true
#
# macro.rb -- Fed net liquidity (WALCL - TGA - RRP) and 10y real yield
# (DFII10) via FRED. The exogenous variable that separates the C' branch
# from everything else: BTC ETF flows currently track rate expectations.
#
# Needs a free API key (1-minute registration at fred.stlouisfed.org):
#   export FRED_API_KEY=...
# Without a key the module degrades to score 0.
#
#   score +1  net liquidity rising over ~4w AND real yields falling
#   score -1  net liquidity falling AND real yields rising
#   score  0  mixed / no key

require_relative 'common'

NAME = 'macro'
KEY  = ENV['FRED_API_KEY']
Scenario.fail_soft(NAME, 'FRED_API_KEY not set') if KEY.nil? || KEY.empty?

# Replay (M12-1): FRED serves full history windowed by observation_end
# (the day before the replay date). D12-b caveat: these are the REVISED
# series as published today, not the vintage a live run saw (macro data
# gets restated) -- direction usually survives revision, levels can move.
def fred(series, key, limit)
  end_p = Scenario.replay? ? "&observation_end=#{(Scenario.as_of - 86_400).strftime('%Y-%m-%d')}" : ''
  url = 'https://api.stlouisfed.org/fred/series/observations' \
        "?series_id=#{series}&api_key=#{key}&file_type=json" \
        "&sort_order=desc&limit=#{limit}#{end_p}"
  obs = Scenario.get_json(url)['observations'] || []
  obs.reject { |o| o['value'] == '.' }.map { |o| o['value'].to_f }
end

begin
  walcl = fred('WALCL', KEY, 6)       # weekly, $ millions
  tga   = fred('WTREGEN', KEY, 6)     # weekly, $ billions
  rrp   = fred('RRPONTSYD', KEY, 25)  # daily,  $ billions
  dfii  = fred('DFII10', KEY, 25)     # daily,  percent
rescue StandardError => e
  Scenario.fail_soft(NAME, e.message)
end

if walcl.size < 5 || tga.size < 5 || rrp.size < 20 || dfii.size < 20
  Scenario.fail_soft(NAME, 'insufficient series history')
end

nl_now = walcl[0] / 1000.0 - tga[0] - rrp[0]
nl_ago = walcl[4] / 1000.0 - tga[4] - rrp[19]
d_nl   = nl_now - nl_ago
d_ry   = dfii[0] - dfii[19]

score = if d_nl > 0 && d_ry < 0
          1
        elsif d_nl < 0 && d_ry > 0
          -1
        else
          0
        end

Scenario.report(NAME, score,
              format('net liq %.0fB (%+.0fB/4w), 10y real %.2f%% (%+.2fpp/4w)',
                     nl_now, d_nl, dfii[0], d_ry))
