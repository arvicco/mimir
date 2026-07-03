#!/usr/bin/env ruby
# frozen_string_literal: true
#
# onchain_value.rb -- MVRV and realized price from the free Coin Metrics
# community API. Slow floor gauge: prior cycle bottoms formed at
# MVRV ~0.75-0.85 with spot converging on realized price.
#
#   score +1  MVRV <= 0.85 (terminal value zone)
#   score -1  MVRV >= 2.5  (froth; irrelevant in a drawdown, kept for
#             symmetry so the module works across the whole cycle)
#   score  0  in between

require_relative 'common'

NAME  = 'onchain'
start = (Time.now.utc - 10 * 86_400).strftime('%Y-%m-%d')
URL   = 'https://community-api.coinmetrics.io/v4/timeseries/asset-metrics' \
        '?assets=btc&metrics=CapMrktCurUSD,CapRealUSD,SplyCur,PriceUSD' \
        "&frequency=1d&start_time=#{start}&page_size=100"

begin
  rows = Common.get_json(URL)['data']
rescue StandardError => e
  Common.fail_soft(NAME, e.message)
end
Common.fail_soft(NAME, 'no data rows') if rows.nil? || rows.empty?

r    = rows.last
mcap = r['CapMrktCurUSD'].to_f
rcap = r['CapRealUSD'].to_f
sply = r['SplyCur'].to_f
px   = r['PriceUSD'].to_f
Common.fail_soft(NAME, 'zero-valued fields') if rcap <= 0 || sply <= 0

mvrv = mcap / rcap
rp   = rcap / sply

score = if mvrv <= 0.85
          1
        elsif mvrv >= 2.5
          -1
        else
          0
        end

Common.report(NAME, score,
              format('MVRV %.2f, realized price %.0f vs spot %.0f (%s)',
                     mvrv, rp, px, r['time'].to_s[0, 10]))
