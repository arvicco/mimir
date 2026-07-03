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

require_relative 'common'
require_relative '../../lib/btc/options'

NAME = 'funding'

begin
  hist = Common.get_json('https://fapi.binance.com/fapi/v1/fundingRate?symbol=BTCUSDT&limit=21')
  cur  = Common.get_json('https://fapi.binance.com/fapi/v1/premiumIndex?symbol=BTCUSDT')
rescue StandardError => e
  Common.fail_soft(NAME, e.message)
end

rates = hist.map { |h| h['fundingRate'].to_f }
Common.fail_soft(NAME, 'no funding history') if rates.empty?
avg7  = rates.inject(:+) / rates.size
now_r = cur['lastFundingRate'].to_f

basis = nil
begin
  spot = Common.get_json('https://www.deribit.com/api/v2/public/get_index_price?index_name=btc_usd')
               .fetch('result').fetch('index_price').to_f
  futs = Common.get_json('https://www.deribit.com/api/v2/public/get_book_summary_by_currency?currency=BTC&kind=future')
               .fetch('result')
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

Common.report(NAME, score,
              format('funding 7d avg %+.4f%%/8h, now %+.4f%%; basis %s',
                     avg7 * 100, now_r * 100,
                     basis ? format('%+.1f%% ann.', basis * 100) : 'n/a'),
              'note' => (basis && basis < 0 ? 'NEGATIVE basis: capitulation regime' : nil))
