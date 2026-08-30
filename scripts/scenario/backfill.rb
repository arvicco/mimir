# frozen_string_literal: true
#
# backfill.rb -- staged sequential rebuild of the scenario history via
# the --as-of replay mode (M12-2, Q-20; the lppl M6-2 pattern).
#
#   rake scenario:backfill        # START -> yesterday into staging
#   rake scenario:backfill_diff   # staged-vs-live overlap report (read-only)
#
# Every write lands under STAGE_ROOT (data/scenario_backfill_staging/,
# via the BTC_DATA_DIR seam handed to each day-run subprocess): the
# staged history.jsonl grows day by day, and the replay fetch caches
# (SourceCache, 24h ttl) land in staging/source_cache -- so a chained
# run fetches each upstream once, and the LIVE data home is never
# touched. Resumable: staged days are skipped. Staged rows carry the
# organic row shape (ts/composite/regime/scores + degraded markers)
# plus 'replayed': true -- provenance is never ambiguous, and the
# backtester can filter on it.
#
# START (default 2026-04-01, override SCENARIO_BACKFILL_FROM): bounded
# by the shallowest replay source -- Binance funding serves ~500 8h
# rows (~5.5 months); earlier days would replay funding as fail-soft
# and the row would be marked degraded. The D12-b fidelity caveats
# apply to every staged row (complete-days windows; cb_premium proxy;
# revised FRED series).
#
# There is NO promote step: staged history is RESEARCH INPUT for the
# backtester (scripts/backtest.rb), never merged into the live
# evidence trail -- the live history stays purely organic.
#
# Ruby >= 3.3, stdlib only.

require 'json'
require 'time'
require 'set'
require 'fileutils'
require 'open3'
require_relative '../../lib/btc/env'

module ScenarioBackfill
  STAGE_ROOT    = File.expand_path('../../data/scenario_backfill_staging', __dir__)
  START_DEFAULT = '2026-04-01'

  module_function

  # 'YYYY-MM-DD' strings, from..upto inclusive, ascending.
  def dates(from:, upto:)
    a = Time.utc(*from.split('-').map(&:to_i))
    b = Time.utc(*upto.split('-').map(&:to_i))
    out = []
    while a <= b
      out << a.strftime('%Y-%m-%d')
      a += 86_400
    end
    out
  end

  def staged_history = File.join(STAGE_ROOT, 'scenario', 'history.jsonl')

  def done_dates(path = staged_history)
    return Set.new unless File.exist?(path)

    File.readlines(path).each_with_object(Set.new) do |ln, s|
      e = JSON.parse(ln) rescue nil
      s << e['ts'][0, 10] if e && e['ts']
    end
  end

  # One replayed aggregator run -> the staged row (organic shape +
  # replayed: true + the M8-8 degraded markers, mirrored from the
  # aggregator's own --history reduction).
  def row_from_json(j)
    mods = j['modules'] || []
    row = { 'ts' => j['ts'], 'composite' => j['composite'], 'regime' => j['regime'],
            'scores' => mods.to_h { |m| [m['mod'], m['score']] },
            'replayed' => true }
    down = mods.select { |m| m['unavailable'] }.map { |m| m['mod'] }
    weighted = mods.reject { |m| m['w'].to_i.zero? }
    if !down.empty? && !weighted.empty? && weighted.all? { |m| m['unavailable'] }
      row['blind'] = true
    elsif !down.empty?
      row['unavailable'] = down
    end
    row
  end

  # Default day-runner: the real aggregator as a subprocess, staging as
  # its data home (replay caches + nothing else land there; the replay
  # guard means scenario.rb itself writes no history).
  DEFAULT_RUNNER = lambda do |date|
    env = { 'BTC_DATA_DIR' => STAGE_ROOT }
    out, err, st = Open3.capture3(env, 'ruby', 'scripts/scenario/scenario.rb',
                                  '--json', '--as-of', date)
    raise "scenario --as-of #{date} failed: #{err.to_s[0, 200]}" unless st.success?

    JSON.parse(out)
  end

  def run(from: ENV['SCENARIO_BACKFILL_FROM'] || START_DEFAULT,
          upto: (Time.now.utc - 86_400).strftime('%Y-%m-%d'),
          runner: DEFAULT_RUNNER, io: $stdout)
    FileUtils.mkdir_p(File.dirname(staged_history))
    done = done_dates
    todo = dates(from: from, upto: upto).reject { |d| done.include?(d) }
    io.puts format('scenario backfill: %d days to replay (%s..%s, %d already staged)',
                   todo.size, from, upto, done.size)
    todo.each_with_index do |d, i|
      row = row_from_json(runner.call(d))
      File.open(staged_history, 'a') { |f| f.puts JSON.generate(row) }
      io.puts format('  %s  %+0.3f %-10s %s  (%d/%d)', d, row['composite'].to_f,
                     row['regime'], row['unavailable'] ? "down:#{row['unavailable'].join(',')}" : '',
                     i + 1, todo.size)
    end
    io.puts 'scenario backfill: done'
    true
  rescue StandardError => e
    io.puts "scenario backfill: ABORT #{e.message[0, 200]} (resumable -- rerun to continue)"
    false
  end

  # Read-only staged-vs-live overlap report: for every shared date,
  # compare composite/regime/per-module scores. Divergences are EXPECTED
  # in known classes (D12-b): complete-days windows vs a partial same-day
  # point, the cb_premium proxy, revised FRED series, self-healed organic
  # rows. The report exists so those classes are SEEN, not assumed.
  def diff(staged_path = staged_history, live_path = nil, io: $stdout)
    live_path ||= File.join(BTC::Env.data_dir('scenario', 'scripts/scenario/data'), 'history.jsonl')
    staged = index_by_date(staged_path)
    live   = index_by_date(live_path)
    shared = (staged.keys & live.keys).sort
    io.puts format('backfill diff: %d staged / %d live / %d shared dates',
                   staged.size, live.size, shared.size)
    mismatches = 0
    shared.each do |d|
      s, l = staged[d], live[d]
      fields = []
      fields << format('composite %+0.3f vs %+0.3f', s['composite'].to_f, l['composite'].to_f) if s['composite'] != l['composite']
      fields << format('regime %s vs %s', s['regime'], l['regime']) if s['regime'] != l['regime']
      (s['scores'] || {}).each do |m, v|
        lv = l.dig('scores', m)
        fields << format('%s %+d vs %s', m, v, lv.nil? ? 'absent' : format('%+d', lv)) if v != lv
      end
      next if fields.empty?

      mismatches += 1
      io.puts format('  %s  %s', d, fields.join(' · '))
    end
    io.puts format('backfill diff: %d/%d shared dates diverge (see the D12-b caveats ' \
                   'in docs/METHODOLOGY.md before reading anything into them)',
                   mismatches, shared.size)
    mismatches
  end

  def index_by_date(path)
    return {} unless File.exist?(path)

    File.readlines(path).each_with_object({}) do |ln, h|
      e = JSON.parse(ln) rescue nil
      h[e['ts'][0, 10]] = e if e && e['ts']
    end
  end
end
