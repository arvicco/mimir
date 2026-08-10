# frozen_string_literal: true
#
# publish_health.rb -- tmux health line for the publish cron
# (M5-2, ARCHITECTURE.md section 6 Phase 5).
#
# Usage (add to ~/.tmux.conf -- second status line, owner ruling
# 2026-07-06: the first line is packed and already brightly coloured,
# so this output carries NO colour codes; `!` is the one-letter
# attention flag):
#   set -g status 2
#   set -g status-format[1] '#[align=right]#(ruby /path/to/mimir/ops/publish_health.rb)'
#   set -g status-interval 30
#
# Optional ARGV[0] = path to the status file (default /tmp/publish.status).
# ENV MIMIR_PUBLISH_INTERVAL_MIN = expected publish cadence in minutes
#   (default 120, decision D5-a: bi-hourly cron, StartInterval 7200).
#
# Output contract (--tmux, FROZEN -- additive only; update
# test/unit/test_publish_health.rb in the same commit as any change;
# colour-code form retired by owner ruling 2026-07-06, same-day as it
# shipped):
#
#   Condition                               Output
#   -----------------------------------------------------------------
#   LIVE, age < 2*interval, n == m          PUB n/m H:MM      (working)
#   LIVE, n < m                             PUB! n/m H:MM
#   LIVE, age >= 2*interval                 PUB! n/m H:MM
#   DRY mode (misconfig on the prod box)    PUB! DRY n/m H:MM
#   status line carries ` OLD:<key>...`     PUB! n/m H:MM OLD (additive M7-5)
#   File missing / unreadable / garbled     PUB! ?
#
#   `!` = attention; the payload says why (n<m keys missing, age past
#   2x cadence, DRY, `OLD` = a published evidence tail stopped moving, or
#   ? no readable status). Severity reads from the age itself -- no separate
#   amber/red tiers. `OLD` (M7-5, 2026-07-07 frozen-evidence incident) is
#   ADDITIVE: the pipeline appends ` OLD:<key>[,...]` to the status line
#   when a published tail's newest entry is older than 30h; this reader
#   surfaces the bare `OLD` marker and forces `!`. It composes with the
#   others (e.g. `PUB! DRY 13/13 5:00 OLD`).
#
# H:MM: hours unpadded, minutes zero-padded to 2 digits, age floored to
# whole minutes.  Examples: 37 min -> 0:37; 65 min -> 1:05; 1563 min -> 26:03.
#
# The status file is written by publish/pipeline.rb (frozen format):
#   PUB LIVE|DRY <n>/<m> keys HH:MM UTC
# This reader is intentionally decoupled from pipeline.rb -- a parse failure
# triggers the safe PUB ? fallback rather than crashing the bar.

require 'time'

module Ops
  module PublishHealth
    DEFAULT_PATH     = '/tmp/publish.status'
    DEFAULT_INTERVAL = 120 # minutes, decision D5-a

    STATUS_RE = /\APUB (\w+) (\d+)\/(\d+) keys/

    module_function

    # Pure function: reads the status file at +path+, computes age relative
    # to +now+ (Time), returns the plain health token (no colour codes).
    # +interval_min+ is the expected publish cadence in minutes.
    # Never raises -- all IO errors collapse to the PUB! ? fallback.
    def line(path:, now:, interval_min: DEFAULT_INTERVAL)
      mtime      = File.mtime(path)
      first_line = File.foreach(path).first.to_s.chomp
      parse_line(first_line, mtime, now, interval_min)
    rescue SystemCallError, IOError
      error_line
    end

    # Parse the first line of the status file and return the health token.
    def parse_line(first_line, mtime, now, interval_min)
      m = STATUS_RE.match(first_line)
      return error_line unless m

      mode    = m[1]
      n       = m[2].to_i
      total   = m[3].to_i
      # ADDITIVE (M7-5): the pipeline appends ` OLD:<key>[,...]` when a
      # published evidence tail has stopped moving (2026-07-07 incident).
      # OLD earns the attention flag AND surfaces the `OLD` marker.
      old     = first_line.include?(' OLD:')
      suffix  = old ? ' OLD' : ''
      age_s   = now - mtime
      age_min = age_s / 60.0
      age_str = format_age(age_s)
      if mode == 'LIVE'
        flag = old || attention?(n, total, age_min, interval_min) ? '!' : ''
        format('PUB%s %d/%d %s%s', flag, n, total, age_str, suffix)
      else
        format('PUB! %s %d/%d %s%s', mode, n, total, age_str, suffix)
      end
    end

    # One-letter attention flag: anything not (complete + fresh) earns
    # the `!`; severity reads from the displayed age, not from tiers.
    def attention?(n, total, age_min, interval_min)
      n < total || age_min >= 2 * interval_min
    end

    # Render age_s (Float or Integer seconds) as "H:MM" -- hours unpadded,
    # minutes 2-digit, floored to whole minutes.
    def format_age(age_s)
      total_min = (age_s / 60.0).floor
      hours = total_min / 60
      mins  = total_min % 60
      format('%d:%02d', hours, mins)
    end

    def error_line
      'PUB! ?'
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  path         = ARGV[0] || Ops::PublishHealth::DEFAULT_PATH
  interval_min = (ENV['MIMIR_PUBLISH_INTERVAL_MIN'] || Ops::PublishHealth::DEFAULT_INTERVAL).to_i
  puts Ops::PublishHealth.line(path: path, now: Time.now, interval_min: interval_min)
  exit 0
end
