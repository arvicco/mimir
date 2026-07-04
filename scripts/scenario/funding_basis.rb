#!/usr/bin/env ruby
# frozen_string_literal: true
#
# funding_basis.rb -- perp funding (Binance BTCUSDT) plus annualized basis
# of the nearest dated Deribit future. Contrarian positioning gauge:
#
#   score +1  7d avg funding <= -0.010%/8h (crowded shorts = squeeze fuel)
#   score -1  7d avg funding >= +0.010%/8h (longs crowded, downside room)
#   score  0  otherwise
#
# Basis is context, not score: negative annualized basis has historically
# marked terminal capitulation regimes (precedes bottoms by days-weeks).
#
# NOTE: self-reports name 'funding' (not the filename) in --json -- frozen
# contract; the aggregator keys by filename, so only standalone consumers
# see the difference.

require_relative 'common'
require_relative '../../lib/btc/options'
require_relative '../../lib/btc/deribit'

NAME = 'funding'

begin
  hist = Scenario.get_json('https://fapi.binance.com/fapi/v1/fundingRate?symbol=BTCUSDT&limit=21')
  cur  = Scenario.get_json('https://fapi.binance.com/fapi/v1/premiumIndex?symbol=BTCUSDT')
rescue StandardError => e
  Scenario.fail_soft(NAME, e.message)
end

rates = hist.map { |h| h['fundingRate'].to_f }
Scenario.fail_soft(NAME, 'no funding history') if rates.empty?
avg7  = rates.inject(:+) / rates.size
now_r = cur['lastFundingRate'].to_f

basis = nil
begin
  spot = BTC::Deribit.index_price('btc_usd')
  futs = BTC::Deribit.book_summary('BTC', 'future')
  nearest = futs.map do |f|
    parts = f['instrument_name'].split('-')
    next unless parts.size == 2 && parts[0] == 'BTC'

    t = BTC::Options.deribit_expiry(parts[1])
    next unless t

    yrs = (t - Time.now.utc) / BTC::Options::YEAR_S
    yrs > 0.02 ? [yrs, f['mark_price'].to_f] : nil
  end.compact.min_by { |yrs, _| yrs }
  basis = nearest && (nearest[1] / spot - 1.0) / nearest[0]
rescue StandardError
  basis = nil
end

score = if avg7 <= -0.0001
          1
        elsif avg7 >= 0.0001
          -1
        else
          0
        end

Scenario.report(NAME, score,
              format('funding 7d avg %+.4f%%/8h, now %+.4f%%; basis %s',
                     avg7 * 100, now_r * 100,
                     basis ? format('%+.1f%% ann.', basis * 100) : 'n/a'),
              'note' => (basis && basis < 0 ? 'NEGATIVE basis: capitulation regime' : nil))
