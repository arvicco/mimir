#!/usr/bin/env ruby
# frozen_string_literal: true
#
# onchain_value.rb -- MVRV and realized price from the free Coin Metrics
# community API. Slow floor gauge: prior cycle bottoms formed at
# MVRV ~0.75-0.85 with spot converging on realized price.
# Since 2026-07 the community tier gates CapRealUSD (F-19), so MVRV is
# read directly (CapMVRVCur) and realized price derived as
# PriceUSD / MVRV -- identical quantities, same provider.
#
# NOTE: self-reports name 'onchain' (not the filename) in --json -- frozen
# contract; the aggregator keys by filename, so only standalone consumers
# see the difference.
#
#   score +1  MVRV <= 0.85 (terminal value zone)
#   score -1  MVRV >= 2.5  (froth; irrelevant in a drawdown, kept for
#             symmetry so the module works across the whole cycle)
#   score  0  in between

require_relative 'common'

NAME  = 'onchain'
start = (Time.now.utc - 10 * 86_400).strftime('%Y-%m-%d')
URL   = 'https://community-api.coinmetrics.io/v4/timeseries/asset-metrics' \
        '?assets=btc&metrics=CapMVRVCur,PriceUSD' \
        "&frequency=1d&start_time=#{start}&page_size=100"

begin
  rows = Scenario.get_json(URL)['data']
rescue StandardError => e
  Scenario.fail_soft(NAME, e.message)
end
Scenario.fail_soft(NAME, 'no data rows') if rows.nil? || rows.empty?

r    = rows.last
mvrv = r['CapMVRVCur'].to_f
px   = r['PriceUSD'].to_f
Scenario.fail_soft(NAME, 'zero-valued fields') if mvrv <= 0 || px <= 0

rp = px / mvrv

score = if mvrv <= 0.85
          1
        elsif mvrv >= 2.5
          -1
        else
          0
        end

Scenario.report(NAME, score,
              format('MVRV %.2f, realized price %.0f vs spot %.0f (%s)',
                     mvrv, rp, px, r['time'].to_s[0, 10]))
