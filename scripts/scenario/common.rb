# frozen_string_literal: true
#
# common.rb -- shared helpers for the scenario signal modules.
# Ruby >= 2.5, stdlib only.
#
# REPLAY (M12-1, Q-20): `--as-of YYYY-MM-DD` computes a module's score
# exactly as a live run on DATE would have, from dated-history sources
# truncated in memory (the lppl M6-1 mechanics: strict date validation,
# frozen clock via now_utc, nothing written). Per-module fidelity --
# which source serves the replay and with what caveat -- is the D12-b
# table in docs/METHODOLOGY.md; a module whose replay rides a PROXY
# source marks its headline. Without the flag every code path and
# timestamp is byte-identical to pre-M12.

require 'json'
require 'time'
require_relative '../../lib/btc/report'
require_relative '../../lib/btc/http'

module Scenario
  module_function

  AS_OF_RE = /\A\d{4}-\d{2}-\d{2}\z/

  # Parsed --as-of Time (UTC midnight), or nil live. Rejects malformed
  # and calendar-impossible dates (Time.utc rolls 2026-02-30 -> Mar-02;
  # a replay must never run against a day the caller did not name).
  def as_of
    return @as_of if defined?(@as_of)

    i = ARGV.index('--as-of')
    return @as_of = nil if i.nil?

    v = ARGV[i + 1]
    abort "scenario: bad --as-of #{v.inspect} (want YYYY-MM-DD)" unless v&.match?(AS_OF_RE)
    y, m, d = v.split('-').map(&:to_i)
    t = begin
      Time.utc(y, m, d)
    rescue ArgumentError
      abort "scenario: bad --as-of #{v.inspect}"
    end
    abort "scenario: bad --as-of #{v.inspect}" unless t.strftime('%Y-%m-%d') == v
    @as_of = t
  end

  def replay? = !as_of.nil?

  # The module clock: the replay day's UTC midnight under --as-of, else
  # the wall clock. Every ts and every "trailing N days" window derives
  # from this so a replayed row is dated like a live row would have been.
  def now_utc = as_of || Time.now.utc

  # Replay truncation for ms-epoch 'time' rows: COMPLETE DAYS ONLY --
  # strictly before the replay day's midnight. A live morning run on
  # DATE reliably had data through DATE-1; a same-day partial row is
  # not reconstructible, so replays never pretend to have had one
  # (backfill_diff surfaces the divergence class). Pass-through live.
  def truncate_ms(rows, field = 'time')
    return rows.to_a unless replay?

    cut = as_of.to_i * 1000
    rows.to_a.select { |r| r[field].to_i < cut }
  end

  def get(url, headers = {})
    BTC::Http.get(url, { 'User-Agent' => 'scenario.rb' }.merge(headers))
  end

  def get_json(url, headers = {})
    JSON.parse(get(url, headers))
  end

  # Every module reports through this. Score is -1/0/+1:
  #   +1 recovery/base-supportive, -1 flush-supportive, 0 neutral/unknown.
  # --json prints the machine form consumed by scenario.rb.
  def report(name, score, headline, detail = {})
    BTC::Report.report(name, score, headline, detail, name_w: 14, key_w: 18,
                       now: now_utc)
  end

  # Report score 0 with a reason and exit cleanly, so one dead data source
  # never breaks the aggregate.
  def fail_soft(name, err)
    BTC::Report.fail_soft(name, err, name_w: 14)
  end
end
