#!/usr/bin/env ruby
# frozen_string_literal: true
#
# cb_premium.rb -- Coinbase (BTC-USD) vs Binance (BTC-USDT) spot premium.
# Persistent positive premium at the lows = US institutional accumulation
# (B'-supportive); persistent discount = distribution continuing.
#
#   score +1  premium >= +10 bps
#   score -1  premium <= -10 bps
#   score  0  inside the band
#
# USDT/USD peg drift adds ~+-5 bps of noise; the band absorbs it. For trend
# rather than snapshot, rely on scenario.rb --history accumulation.

require_relative 'common'

NAME = 'cb_premium'

begin
  cb = Common.get_json('https://api.exchange.coinbase.com/products/BTC-USD/ticker')['price'].to_f
  bn = Common.get_json('https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT')['price'].to_f
rescue StandardError => e
  Common.fail_soft(NAME, e.message)
end
Common.fail_soft(NAME, 'bad quote') if cb <= 0 || bn <= 0

prem  = (cb / bn - 1.0) * 10_000
score = if prem >= 10
          1
        elsif prem <= -10
          -1
        else
          0
        end

Common.report(NAME, score,
              format('coinbase %+.1f bps vs binance (CB %.2f / BN %.2f)',
                     prem, cb, bn))
