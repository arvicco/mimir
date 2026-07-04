#!/usr/bin/env ruby
# frozen_string_literal: true
#
# hash_ribbons.rb -- miner capitulation via mempool.space hashrate history.
# Times the END of a flush: the recovery cross is the classic hash-ribbons
# buy signal.
#
#   score -1  30d SMA < 60d SMA (miner capitulation in progress)
#   score +1  30d SMA crossed back above 60d within the last 14 days
#   score  0  otherwise
#
# Last difficulty adjustments are printed as context (two consecutive
# negative adjustments = deep capitulation).

require_relative 'common'

NAME = 'hash_ribbons'

begin
  data = Scenario.get_json('https://mempool.space/api/v1/mining/hashrate/6m')
rescue StandardError => e
  Scenario.fail_soft(NAME, e.message)
end

hs = (data['hashrates'] || []).map { |h| h['avgHashrate'].to_f }
Scenario.fail_soft(NAME, 'not enough hashrate history') if hs.size < 75

sma = lambda do |arr, n, at|
  seg = arr[(at - n + 1)..at]
  seg.inject(:+) / seg.size
end

last       = hs.size - 1
below_now  = sma.(hs, 30, last) < sma.(hs, 60, last)
crossed_up = false
unless below_now
  (1..14).each do |d|
    at = last - d
    break if at < 60

    if sma.(hs, 30, at) < sma.(hs, 60, at)
      crossed_up = true
      break
    end
  end
end

diffs = (data['difficulty'] || []).map { |d| d['difficulty'].to_f }.last(3)
adj   = diffs.each_cons(2).map { |a, b| (b / a - 1.0) * 100 }

score = below_now ? -1 : (crossed_up ? 1 : 0)

Scenario.report(NAME, score,
              format('30d SMA %s 60d SMA%s; recent diff adj: %s',
                     below_now ? '<' : '>',
                     crossed_up ? ' (recovery cross <14d ago)' : '',
                     adj.empty? ? 'n/a' : adj.map { |a| format('%+.1f%%', a) }.join(', ')))
