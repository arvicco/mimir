# frozen_string_literal: true
#
# snapshot.rb -- one dated copy of the research data home per UTC day (M14-7).
#
# PURPOSE
#   The data home holds point-in-time ledgers that cannot be re-fetched.
#   This box has no working backup, so this script keeps a rolling set of
#   plain directory copies (owner ruling 2026-10-12). It rides the existing
#   bi-hourly publish tick (ops/run_publish.sh, just before the repair
#   step) -- no new launchd agent. The tick runs 12x/day; only the first
#   run of each UTC day copies anything, later runs skip quietly.
#
# USAGE
#   ruby ops/snapshot.rb      # normally invoked by run_publish.sh (env sourced)
#
#   Source:      $BTC_DATA_DIR when set, else the app data home
#                (~/Library/Application Support/mimir/data).
#   Destination: $MIMIR_BACKUP_DIR when set, else a `mimir-backups`
#                directory SIBLING to the source, i.e.
#                <data_home>/../mimir-backups/<YYYY-MM-DD>/  (UTC date).
#                Sibling, not inside, so wiping the data home cannot take
#                the backups with it.
#
# BEHAVIOR
#   - Idempotent per day: a non-empty <dest>/<today>/ means done -> skip.
#   - Copy: the whole data home (files + subdirs, symlinks kept as links,
#     modes/mtimes preserved). Nothing is excluded.
#   - Commit point: the copy is written to <dest>/.tmp-<today>-<pid> and
#     renamed to <dest>/<today> only after it completes. A crash leaves a
#     .tmp-* dir, which never counts as today's snapshot and is swept on
#     the next run.
#   - Rotation: after a successful copy, keep the newest 14 snapshots and
#     delete older ones. ONLY real directories directly under <dest> whose
#     name is exactly YYYY-MM-DD are ever deleted; anything else there is
#     left alone. A destination equal to or inside the source is refused.
#   - Output: one aligned status line on stdout, e.g.
#       snapshot: 2026-10-12 written, 14 kept
#       snapshot: 2026-10-12 present, skipped
#   - Fail-soft: any error -> one warn line (error class + short message),
#     exit 0. The backup layer must never break the publish tick.
#
# RESTORE (a HUMAN action; pause the launchd agents first)
#   D="$HOME/Library/Application Support/mimir"
#   mv "$D/data" "$D/data.broken-$(date -u +%Y%m%dT%H%M%SZ)"
#   mkdir "$D/data"
#   cp -Rp "$D/mimir-backups/2026-10-12/." "$D/data/"
#   (pick the dated dir to restore; the broken copy stays for inspection.)
#
# CAVEATS
#   - Restore granularity is one day: data written after the day's first
#     tick is only in the next day's snapshot.
#   - The copy is not atomic against concurrent writers: a producer
#     writing during the copy (another launchd agent) may be caught
#     mid-write -- e.g. a ledger missing its newest line, or a partial
#     last line from an append. Earlier lines are unaffected; the next
#     day's snapshot carries the finished file.
#   - Same disk as the data home: protects against deletion/corruption by
#     software, not against disk loss.
#   - ~14 days x full data home (about 14 MB today, of which source_cache/
#     is roughly half) -- plain copies, no compression, no dedup.
#
# Ruby >= 3.3, stdlib only.

require 'fileutils'
require 'time'
require_relative '../lib/btc/env'

module Ops
  module Snapshot
    KEEP     = 14
    DATE_RE  = /\A\d{4}-\d{2}-\d{2}\z/
    TMP_RE   = /\A\.tmp-\d{4}-\d{2}-\d{2}-\d+\z/
    DIR_NAME = 'mimir-backups'

    # Default copier: the contents of +src+ into the (new) dir +dst+.
    COPY = lambda do |src, dst|
      FileUtils.mkdir_p(dst)
      FileUtils.cp_r(File.join(src, '.'), dst, preserve: true)
    end

    module_function

    def source_dir(env = ENV)
      base = env['BTC_DATA_DIR']
      base && !base.empty? ? File.expand_path(base) : BTC::Env.data_home
    end

    def dest_dir(src, env = ENV)
      over = env['MIMIR_BACKUP_DIR']
      return File.expand_path(over) if over && !over.empty?

      File.join(File.dirname(File.expand_path(src)), DIR_NAME)
    end

    # Snapshot dir names under +dest+, oldest first (real dirs only).
    def snapshots(dest)
      return [] unless File.directory?(dest)

      Dir.children(dest).select { |n| n.match?(DATE_RE) && real_dir?(File.join(dest, n)) }.sort
    end

    def real_dir?(path)
      File.directory?(path) && !File.symlink?(path)
    end

    # Names to delete so that only the newest +keep+ remain.
    def to_prune(names, keep = KEEP)
      sorted = names.select { |n| n.match?(DATE_RE) }.sort
      sorted.size > keep ? sorted.first(sorted.size - keep) : []
    end

    # Returns :written, :skipped or :failed. Never raises.
    def run(now: Time.now, env: ENV, out: $stdout, err: $stderr, copy: COPY)
      day  = now.utc.strftime('%Y-%m-%d')
      src  = source_dir(env)
      dest = dest_dir(src, env)
      raise ArgumentError, 'data home not found' unless File.directory?(src)
      if dest == src || dest.start_with?(src + File::SEPARATOR)
        raise ArgumentError, 'backup dir is inside the data home'
      end

      final = File.join(dest, day)
      if real_dir?(final) && !Dir.empty?(final)
        out.puts format('snapshot: %-10s present, skipped', day)
        return :skipped
      end

      FileUtils.mkdir_p(dest)
      sweep_temps(dest)
      tmp = File.join(dest, format('.tmp-%s-%d', day, Process.pid))
      copy.call(src, tmp)
      Dir.rmdir(final) if real_dir?(final) # an empty leftover; rename needs it gone
      File.rename(tmp, final)

      to_prune(snapshots(dest)).each { |n| FileUtils.rm_rf(File.join(dest, n)) }
      out.puts format('snapshot: %-10s written, %d kept', day, snapshots(dest).size)
      :written
    rescue StandardError => e
      err.puts BTC::Env.redact(format('snapshot: FAILED (contained): %s: %s', e.class, e.message))
      :failed
    end

    # Remove .tmp-* dirs left by a crashed run (exact pattern only).
    def sweep_temps(dest)
      Dir.children(dest).each do |n|
        path = File.join(dest, n)
        FileUtils.rm_rf(path) if n.match?(TMP_RE) && real_dir?(path)
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  Ops::Snapshot.run
  exit 0
end
