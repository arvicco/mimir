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
require_relative '../../lib/btc/coinglass'

NAME = 'cb_premium'

# Replay (M12-1): live spot tickers have no dated past; the replay rides
# Coinglass's coinbase-premium-index daily history as a PROXY (D12-b
# caveat: their premium is computed against their own composite, not our
# Binance leg -- direction-consistent, not identical; the headline says
# 'replay-proxy'). bps derived unit-safely from the absolute premium and
# the Coinbase price, never from the provider's rate field.
if Scenario.replay?
  begin
    rows = BTC::Coinglass.get('coinbase-premium-index', { interval: '1d' })
    rows = Scenario.truncate_ms(rows)
    raise 'no premium history before the replay date' if rows.empty?

    r  = rows.last
    cb = r['coinbase_price'].to_f
    other = cb - r['premium'].to_f
    raise 'bad proxy row' if cb <= 0 || other <= 0
  rescue StandardError => e
    Scenario.fail_soft(NAME, e.message)
  end
  prem = (cb / other - 1.0) * 10_000
  bn = other
else
  begin
    cb = Scenario.get_json('https://api.exchange.coinbase.com/products/BTC-USD/ticker')['price'].to_f
    bn = Scenario.get_json('https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT')['price'].to_f
  rescue StandardError => e
    Scenario.fail_soft(NAME, e.message)
  end
  Scenario.fail_soft(NAME, 'bad quote') if cb <= 0 || bn <= 0

  prem = (cb / bn - 1.0) * 10_000
end
score = if prem >= 10
          1
        elsif prem <= -10
          -1
        else
          0
        end

Scenario.report(NAME, score,
              format('coinbase %+.1f bps vs %s (CB %.2f / %.2f)',
                     prem, Scenario.replay? ? 'composite [replay-proxy]' : 'binance',
                     cb, bn))
