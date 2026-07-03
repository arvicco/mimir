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
  data = Common.get_json('https://stablecoins.llama.fi/stablecoins?includePrices=false')
rescue StandardError => e
  Common.fail_soft(NAME, e.message)
end

grab = ->(h) { h.is_a?(Hash) ? h['peggedUSD'].to_f : 0.0 }
tot  = { now: 0.0, week: 0.0, month: 0.0 }

(data['peggedAssets'] || []).each do |a|
  next unless %w[USDT USDC].include?(a['symbol'])

  tot[:now]   += grab.(a['circulating'])
  tot[:week]  += grab.(a['circulatingPrevWeek'])
  tot[:month] += grab.(a['circulatingPrevMonth'])
end

Common.fail_soft(NAME, 'no supply data') if tot[:now] <= 0 || tot[:month] <= 0

w = (tot[:now] / tot[:week] - 1) * 100
m = (tot[:now] / tot[:month] - 1) * 100

score = if m >= 0.5
          1
        elsif m <= -0.5
          -1
        else
          0
        end

Common.report(NAME, score,
              format('USDT+USDC %.1fB: %+.2f%% 1w, %+.2f%% 1m',
                     tot[:now] / 1e9, w, m))
