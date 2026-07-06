# frozen_string_literal: true
#
# backfill.rb -- staged sequential rebuild of the LPPL evidence ledger
# via the --as-of replay mode (M6-2, decision D7-a: from the Oct-2025
# cycle peak; D7-b: no usable pre-handoff files, recompute is the
# blessed path).
#
#   rake lppl:backfill            # peak -> yesterday into the staging dir
#   rake lppl:backfill_diff       # staged-vs-live overlap report +
#                                 # promotion commands (owner runs those)
#
# Every write lands under STAGE_ROOT (data/lppl_backfill_staging/, via
# the BTC_DATA_DIR seam) -- the live suite data dir is read-only input:
# prices.csv and trend_scores.csv are copied in once (replay reads the
# score cache filtered and never appends -- see trend.rb), ledger and
# fit_history grow day by day in staging. Resumable: days already in
# the staged ledger are skipped, so an interrupted run continues where
# it stopped. One replay day is ~3 s; the full window is ~15 min.
#
# Promotion to the live ledger is a HUMAN action at Gate 6: diff prints
# the exact backup + merge commands (staged entries strictly before the
# first live day, then the organic live entries) and never runs them.
#
# Ruby >= 3.3, stdlib only.

require 'json'
require 'time'
require 'set'
require 'fileutils'
require_relative 'common'

module Lppl
  module Backfill
    STAGE_ROOT = File.expand_path('../../data/lppl_backfill_staging', __dir__)

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

    # Replay days already in the staged ledger (ts is frozen to the
    # as-of midnight, so the date prefix is the day).
    def done_dates(ledger_path)
      return Set.new unless File.exist?(ledger_path)

      File.readlines(ledger_path).each_with_object(Set.new) do |ln, s|
        e = JSON.parse(ln) rescue nil
        s << e['ts'][0, 10] if e && e['ts']
      end
    end

    # Stage the read-only inputs once; never overwrite what is already
    # staged (an interrupted backfill must resume against the exact
    # inputs it started with), never touch the source dir.
    def setup(stage_root, data_dir:, io: $stdout)
      dst = File.join(stage_root, 'lppl')
      FileUtils.mkdir_p(dst)
      %w[prices.csv trend_scores.csv].each do |f|
        src = File.join(data_dir, f)
        next if File.exist?(File.join(dst, f))
        raise "missing input #{src} -- run the live suite first" unless File.exist?(src)

        FileUtils.cp(src, File.join(dst, f))
        io.puts "staged #{f}"
      end
      dst
    end

    # The cycle peak day in the LIVE price cache (same detector the fit
    # modules use). Driver-side: computed before any staging.
    def peak_date
      p = Lppl.load_prices
      p[:dates][Lppl.detect_peak(p)].strftime('%Y-%m-%d')
    end

    def default_runner
      require 'open3'
      lambda do |date, env|
        out, err, st = Open3.capture3(env, RbConfig.ruby,
                                      File.expand_path('lppl.rb', __dir__),
                                      '--json', '--history', '--as-of', date)
        line = begin
          j = JSON.parse(out)
          format('%-13s %+.2f', j['verdict'], j['composite'])
        rescue StandardError
          err.lines.last.to_s.strip[0, 120]
        end
        [st.success?, line]
      end
    end

    # Sequential replay loop. Returns true when every day landed.
    def run(stage_root: STAGE_ROOT, data_dir: Lppl::DATA, from: nil,
            upto: nil, io: $stdout, runner: default_runner)
      from ||= peak_date
      upto ||= (Time.now.utc - 86_400).strftime('%Y-%m-%d')
      setup(stage_root, data_dir: data_dir, io: io)

      ledger = File.join(stage_root, 'lppl', 'ledger.jsonl')
      done   = done_dates(ledger)
      todo   = dates(from: from, upto: upto).reject { |d| done.include?(d) }
      io.puts format('backfill %s -> %s: %d days (%d already staged) -> %s',
                     from, upto, todo.size, done.size, stage_root)

      todo.each_with_index do |d, i|
        ok, line = runner.call(d, { 'BTC_DATA_DIR' => stage_root })
        io.puts format('[%d/%d] %s  %s', i + 1, todo.size, d, line)
        next if ok

        io.puts "FAILED #{d} -- #{line}"
        io.puts 'staging kept; rerun rake lppl:backfill to resume here.'
        return false
      end
      io.puts 'backfill complete. Next: rake lppl:backfill_diff'
      true
    end

    # Field-level overlap report, staged vs live, ts excluded (frozen
    # midnight vs organic intraday is the documented difference). Live
    # duplicate days collapse to their FIRST entry (later same-day runs
    # replayed identically -- see the recorded 07-05 pair). Returns the
    # mismatch tuples [date, field, staged, live]; prints the table and
    # the promotion commands for the owner.
    def diff(staged_path, live_path, io: $stdout)
      staged = index_by_day(staged_path)
      live   = index_by_day(live_path, count_dups: (dups = Hash.new(0)))
      dups.each { |d, n| io.puts "duplicate live entries on #{d}: #{n}" if n > 1 }

      mism = []
      live.keys.sort.each do |day|
        unless staged.key?(day)
          io.puts "#{day}: live only (not in staged range)"
          next
        end
        fields = (staged[day].keys | live[day].keys) - ['ts']
        bad = fields.reject { |f| staged[day][f] == live[day][f] }
        if bad.empty?
          io.puts "#{day}: match"
        else
          bad.each do |f|
            mism << [day, f, staged[day][f], live[day][f]]
            io.puts format('mismatch %s %-18s %-12s %-12s', day, f,
                           staged[day][f].inspect, live[day][f].inspect)
          end
        end
      end

      first_live = live.keys.min
      io.puts
      io.puts "promotion (OWNER action at Gate 6; first live day #{first_live} " \
              'and later stay organic):'
      bak = Time.now.utc.strftime('%Y%m%d')
      io.puts "  cp #{live_path} #{live_path}.bak-#{bak}"
      io.puts "  { sed -n '/^{\"ts\":\"#{first_live}/q;p' #{staged_path}; " \
              "cat #{live_path}.bak-#{bak}; } > #{live_path}"
      mism
    end

    def index_by_day(path, count_dups: nil)
      out = {}
      File.readlines(path).each do |ln|
        e = JSON.parse(ln) rescue next
        day = e['ts'].to_s[0, 10]
        count_dups[day] += 1 if count_dups
        out[day] ||= e # first entry wins on duplicate days
      end
      out
    end
  end
end
