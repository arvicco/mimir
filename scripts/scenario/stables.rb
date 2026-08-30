#!/usr/bin/env ruby
# frozen_string_literal: true
#
# stables.rb -- aggregate USDT+USDC circulating supply via DefiLlama.
# Crypto's internal liquidity: expansion resuming is the earliest reliable
# recovery (C') precursor; contraction is an E' warning.
#
#   score +1  1-month change >= +0.5%
#   score -1  1-month change <= -0.5%
#   score  0  in between

require_relative 'common'

NAME = 'stables'

begin
  data = Scenario.get_json('https://stablecoins.llama.fi/stablecoins?includePrices=false')
rescue StandardError => e
  Scenario.fail_soft(NAME, e.message)
end

grab = ->(h) { h.is_a?(Hash) ? h['peggedUSD'].to_f : 0.0 }
tot  = { now: 0.0, week: 0.0, month: 0.0 }

if Scenario.replay?
  # Replay (M12-1): per-coin daily history via stablecoincharts (ids
  # resolved from the index by symbol -- never hardcoded), truncated to
  # complete days; now/week/month = D-1 and the rows 7/30 days earlier.
  # D12-b caveat: DefiLlama occasionally restates supply series.
  begin
    ids = (data['peggedAssets'] || [])
          .select { |a| %w[USDT USDC].include?(a['symbol']) }
          .map { |a| a['id'] }
    raise 'stablecoin ids not found' if ids.size < 2

    cut = Scenario.as_of.to_i
    require_relative '../../lib/btc/source_cache'
    ids.each do |id|
      rows = BTC::SourceCache
             .fetch_json("llama_charts_#{id}",
                         "https://stablecoins.llama.fi/stablecoincharts/all?stablecoin=#{id}",
                         ttl: 86_400)['data']
             .select { |r| r['date'].to_i < cut }
      raise 'not enough supply history' if rows.size < 31

      # charts rows may carry the total as a hash or a bare number
      read = ->(r) { v = r['totalCirculating']; v.is_a?(Hash) ? v['peggedUSD'].to_f : v.to_f }
      tot[:now]   += read.(rows[-1])
      tot[:week]  += read.(rows[-8])
      tot[:month] += read.(rows[-31])
    end
  rescue StandardError => e
    Scenario.fail_soft(NAME, e.message)
  end
else
  (data['peggedAssets'] || []).each do |a|
    next unless %w[USDT USDC].include?(a['symbol'])

    tot[:now]   += grab.(a['circulating'])
    tot[:week]  += grab.(a['circulatingPrevWeek'])
    tot[:month] += grab.(a['circulatingPrevMonth'])
  end
end

Scenario.fail_soft(NAME, 'no supply data') if tot[:now] <= 0 || tot[:month] <= 0

w = (tot[:now] / tot[:week] - 1) * 100
m = (tot[:now] / tot[:month] - 1) * 100

score = if m >= 0.5
          1
        elsif m <= -0.5
          -1
        else
          0
        end

Scenario.report(NAME, score,
              format('USDT+USDC %.1fB: %+.2f%% 1w, %+.2f%% 1m',
                     tot[:now] / 1e9, w, m))
