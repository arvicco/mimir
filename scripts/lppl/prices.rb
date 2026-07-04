#!/usr/bin/env ruby
# frozen_string_literal: true
#
# prices.rb -- builds/updates the daily BTC-USD close cache
# (data/prices.csv) from the Coin Metrics community API (PriceUSD
# reference rate, keyless, full history back to 2010-07). Incremental
# after first run. The latest (potentially incomplete) day is excluded.
#
#   ruby prices.rb           # update cache, print summary
#   ruby prices.rb --json    # machine summary
#
# Source history: originally CryptoCompare histoday; that endpoint was
# key-gated upstream (HTTP 401, observed 2026-07-04), and no cache
# survived to mix series, so the suite restarted on Coin Metrics --
# the provider onchain_value.rb already trusts. Reference-rate closes
# differ slightly from exchange closes; a data-source decision recorded
# in docs/TOOL-REVIEW.md (F-16).

require_relative 'common'

NAME = 'prices'
URL  = 'https://community-api.coinmetrics.io/v4/timeseries/asset-metrics' \
       '?assets=btc&metrics=PriceUSD&frequency=1d&page_size=10000' \
       '&paging_from=start'

FileUtils.mkdir_p(Lppl::DATA)

existing = {}
if File.exist?(Lppl::PRICES)
  File.foreach(Lppl::PRICES) do |ln|
    d, c = ln.strip.split(',')
    existing[d] = c.to_f if d && d != 'date' && c
  end
end

today = Time.now.utc
mid   = Time.utc(today.year, today.month, today.day)

start = if existing.empty?
          '2010-07-01'
        else
          # small overlap re-reads the tail; upserts are idempotent
          (Time.parse(existing.keys.max + ' 00:00:00 UTC') - 5 * 86_400)
            .strftime('%Y-%m-%d')
        end

rows = []
begin
  url = URL + "&start_time=#{start}"
  loop do
    res = Lppl.get_json(url)
    rows.concat(res['data'].to_a)
    url = res['next_page_url']
    break if url.nil? || res['data'].to_a.empty?
  end
rescue StandardError => e
  Lppl.fail_soft(NAME, e.message)
end

added = 0
rows.each do |r|
  t = Time.parse(r['time']).utc
  next if t >= mid # today's row would be incomplete

  c = r['PriceUSD'].to_f
  next if c <= 0

  key = t.strftime('%Y-%m-%d')
  added += 1 unless existing.key?(key)
  existing[key] = c
end

Lppl.fail_soft(NAME, 'no rows fetched and no cache') if existing.empty?

File.open(Lppl::PRICES, 'w') do |f|
  f.puts 'date,close'
  existing.keys.sort.each { |d| f.puts "#{d},#{existing[d]}" }
end

last = existing.keys.max
Lppl.report(NAME, 0,
            format('%d rows (%s .. %s), last close %.0f, +%d new',
                   existing.size, existing.keys.min, last,
                   existing[last], added),
            'last_date' => last, 'last_close' => existing[last].round(2),
            'rows' => existing.size)
