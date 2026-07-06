# frozen_string_literal: true
#
# publish_health.rb -- tmux status-right health line for the publish cron
# (M5-2, ARCHITECTURE.md section 6 Phase 5).
#
# Usage (add to ~/.tmux.conf):
#   set -g status-right '#(ruby /path/to/mimir/ops/publish_health.rb)'
#   set -g status-interval 30
#
# Optional ARGV[0] = path to the status file (default /tmp/publish.status).
# ENV MIMIR_PUBLISH_INTERVAL_MIN = expected publish cadence in minutes
#   (default 120, decision D5-a: bi-hourly cron, StartInterval 7200).
#
# Output contract (--tmux, FROZEN -- additive only; update
# test/unit/test_publish_health.rb in the same commit as any change):
#
#   Condition                               Output
#   -----------------------------------------------------------------
#   LIVE, age < 2*interval, n == m          #[fg=green]PUB n/m H:MM#[default]
#   LIVE, age < 2*interval, n <  m          #[fg=yellow]PUB n/m H:MM#[default]
#   LIVE, 2*interval <= age < 6*interval    #[fg=yellow]PUB n/m H:MM#[default]
#   LIVE, age >= 6*interval                 #[fg=red]PUB n/m H:MM#[default]
#   DRY mode, age < 6*interval              #[fg=yellow]PUB DRY n/m H:MM#[default]
#   DRY mode, age >= 6*interval             #[fg=red]PUB DRY n/m H:MM#[default]
#   File missing / unreadable / garbled     #[fg=red]PUB ?#[default]
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
    # to +now+ (Time), returns the tmux colour-tagged one-liner.
    # +interval_min+ is the expected publish cadence in minutes.
    # Never raises -- all IO errors collapse to the PUB ? fallback.
    def line(path:, now:, interval_min: DEFAULT_INTERVAL)
      mtime      = File.mtime(path)
      first_line = File.foreach(path).first.to_s.chomp
      parse_line(first_line, mtime, now, interval_min)
    rescue SystemCallError, IOError
      error_line
    end

    # Parse the first line of the status file and return the tmux string.
    def parse_line(first_line, mtime, now, interval_min)
      m = STATUS_RE.match(first_line)
      return error_line unless m

      mode    = m[1]
      n       = m[2].to_i
      total   = m[3].to_i
      age_s   = now - mtime
      age_min = age_s / 60.0
      age_str = format_age(age_s)
      color   = color_for(mode, n, total, age_min, interval_min)
      label   = if mode == 'LIVE'
                  format('PUB %d/%d %s', n, total, age_str)
                else
                  format('PUB %s %d/%d %s', mode, n, total, age_str)
                end
      format('#[fg=%s]%s#[default]', color, label)
    end

    # Pick the tmux colour based on mode, key completeness, and age.
    def color_for(mode, n, total, age_min, interval_min)
      stale = age_min >= 6 * interval_min
      return stale ? 'red' : 'yellow' if mode != 'LIVE'
      return 'red' if stale
      return 'yellow' if age_min >= 2 * interval_min
      n < total ? 'yellow' : 'green'
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
      '#[fg=red]PUB ?#[default]'
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  path         = ARGV[0] || Ops::PublishHealth::DEFAULT_PATH
  interval_min = (ENV['MIMIR_PUBLISH_INTERVAL_MIN'] || Ops::PublishHealth::DEFAULT_INTERVAL).to_i
  puts Ops::PublishHealth.line(path: path, now: Time.now, interval_min: interval_min)
  exit 0
end
