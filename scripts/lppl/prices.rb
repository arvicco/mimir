#!/usr/bin/env ruby
# frozen_string_literal: true
#
# prices.rb -- builds/updates the daily BTC-USD close cache (data/prices.csv)
# from CryptoCompare's free histoday endpoint (full history back to 2010,
# no API key). Incremental after first run: one small call per day.
# Today's incomplete candle is always excluded.
#
#   ruby prices.rb           # update cache, print summary
#   ruby prices.rb --json    # machine summary

require_relative 'common'

NAME = 'prices'
URL  = 'https://min-api.cryptocompare.com/data/v2/histoday?fsym=BTC&tsym=USD'

FileUtils.mkdir_p(Common::DATA)

existing = {}
if File.exist?(Common::PRICES)
  File.foreach(Common::PRICES) do |ln|
    d, c = ln.strip.split(',')
    existing[d] = c.to_f if d && d != 'date' && c
  end
end

today = Time.now.utc
mid   = Time.utc(today.year, today.month, today.day)

missing =
  if existing.empty?
    9_999
  else
    ((mid - Time.parse(existing.keys.max + ' 00:00:00 UTC')) / 86_400).to_i
  end

begin
  url =
    if missing > 1800
      URL + '&allData=true'
    else
      URL + "&limit=#{[missing + 3, 30].max}"
    end
  rows = Common.get_json(url).fetch('Data').fetch('Data')
rescue StandardError => e
  Common.fail_soft(NAME, e.message)
end

added = 0
rows.each do |r|
  t = Time.at(r['time'].to_i).utc
  next if t >= mid # incomplete candle

  c = r['close'].to_f
  next if c <= 0

  key = t.strftime('%Y-%m-%d')
  added += 1 unless existing.key?(key)
  existing[key] = c
end

File.open(Common::PRICES, 'w') do |f|
  f.puts 'date,close'
  existing.keys.sort.each { |d| f.puts "#{d},#{existing[d]}" }
end

last = existing.keys.max
Common.report(NAME, 0,
              format('%d rows (%s .. %s), last close %.0f, +%d new',
                     existing.size, existing.keys.min, last,
                     existing[last], added),
              'last_date' => last, 'last_close' => existing[last].round(2),
              'rows' => existing.size)
