# frozen_string_literal: true
#
# test_snapshot.rb -- unit tests for Ops::Snapshot (M14-7).
#
# Every test runs in a tmpdir: a fake data home `data/` with a nested
# ledger, the backups landing in its sibling `mimir-backups/`. The clock
# is injected (now:) and ENV is an injected hash, so nothing touches the
# real data home or the network.

require_relative '../test_helper'
require_relative '../../ops/snapshot'
require 'tmpdir'
require 'fileutils'
require 'stringio'

class TestSnapshot < Minitest::Test
  NOW = Time.utc(2026, 10, 12, 1, 30, 0).freeze

  def with_home
    Dir.mktmpdir do |root|
      data = File.join(root, 'data')
      FileUtils.mkdir_p(File.join(data, 'lppl'))
      File.write(File.join(data, 'lppl', 'ledger.jsonl'), "{\"ts\":\"2026-10-12\"}\n")
      File.write(File.join(data, 'top.json'), '{}')
      yield root, data, File.join(root, 'mimir-backups')
    end
  end

  def run_snap(data, now: NOW, env: {}, copy: Ops::Snapshot::COPY)
    out = StringIO.new
    err = StringIO.new
    res = Ops::Snapshot.run(now: now, env: { 'BTC_DATA_DIR' => data }.merge(env),
                            out: out, err: err, copy: copy)
    [res, out.string, err.string]
  end

  def test_creates_dated_dir_with_the_data_copied
    with_home do |_root, data, dest|
      res, out, = run_snap(data)
      assert_equal :written, res
      snap = File.join(dest, '2026-10-12')
      assert_equal "{\"ts\":\"2026-10-12\"}\n", File.read(File.join(snap, 'lppl', 'ledger.jsonl'))
      assert_equal '{}', File.read(File.join(snap, 'top.json'))
      assert_equal "snapshot: 2026-10-12 written, 1 kept\n", out
    end
  end

  def test_same_day_second_run_skips
    with_home do |_root, data, dest|
      run_snap(data)
      File.write(File.join(data, 'top.json'), '{"changed":true}')
      res, out, = run_snap(data, now: NOW + 3600 * 20)
      assert_equal :skipped, res
      assert_equal "snapshot: 2026-10-12 present, skipped\n", out
      assert_equal '{}', File.read(File.join(dest, '2026-10-12', 'top.json'))
    end
  end

  def test_rotation_keeps_14_and_deletes_only_date_dirs
    with_home do |_root, data, dest|
      FileUtils.mkdir_p(dest)
      16.times { |i| FileUtils.mkdir_p(File.join(dest, format('2026-09-%02d', i + 1))) }
      decoy = File.join(dest, 'keep-me')
      FileUtils.mkdir_p(decoy)
      File.write(File.join(dest, '2026-01-01'), 'a plain file with a date name')

      res, out, = run_snap(data)
      assert_equal :written, res
      kept = Ops::Snapshot.snapshots(dest)
      assert_equal 14, kept.size
      assert_equal '2026-09-04', kept.first
      assert_equal '2026-10-12', kept.last
      assert File.directory?(decoy), 'non-date dir must survive rotation'
      assert File.file?(File.join(dest, '2026-01-01')), 'non-directory must survive rotation'
      assert File.directory?(data), 'the data home must be untouched'
      assert_equal "snapshot: 2026-10-12 written, 14 kept\n", out
    end
  end

  def test_crashed_copy_does_not_block_the_retry
    with_home do |_root, data, dest|
      crash = lambda do |src, dst|
        FileUtils.mkdir_p(dst)
        File.write(File.join(dst, 'top.json'), File.read(File.join(src, 'top.json')))
        raise IOError, 'disk hiccup'
      end
      res, _out, err = run_snap(data, copy: crash)
      assert_equal :failed, res
      assert_match(/snapshot: FAILED \(contained\): IOError: disk hiccup/, err)
      refute File.exist?(File.join(dest, '2026-10-12')), 'a crashed copy must not commit'

      res2, = run_snap(data)
      assert_equal :written, res2
      assert File.file?(File.join(dest, '2026-10-12', 'lppl', 'ledger.jsonl'))
      assert_empty Dir.children(dest).grep(/\A\.tmp-/), 'stale temp dirs are swept'
    end
  end

  def test_missing_source_fails_soft
    Dir.mktmpdir do |root|
      res, out, err = run_snap(File.join(root, 'nope'))
      assert_equal :failed, res
      assert_empty out
      assert_match(/snapshot: FAILED \(contained\): ArgumentError/, err)
      refute File.exist?(File.join(root, 'mimir-backups'))
    end
  end

  def test_clock_injection_controls_the_date
    with_home do |_root, data, dest|
      run_snap(data, now: Time.new(2026, 10, 13, 1, 0, 0, '+05:00')) # 2026-10-12T20:00Z
      run_snap(data, now: Time.utc(2026, 10, 14, 0, 0, 1))
      assert_equal %w[2026-10-12 2026-10-14], Ops::Snapshot.snapshots(dest)
    end
  end

  def test_destination_override_is_respected
    with_home do |root, data, dest|
      other = File.join(root, 'elsewhere')
      res, = run_snap(data, env: { 'MIMIR_BACKUP_DIR' => other })
      assert_equal :written, res
      assert File.file?(File.join(other, '2026-10-12', 'top.json'))
      refute File.exist?(dest)
    end
  end

  def test_destination_inside_the_data_home_is_refused
    with_home do |_root, data, _dest|
      res, _out, err = run_snap(data, env: { 'MIMIR_BACKUP_DIR' => File.join(data, 'bk') })
      assert_equal :failed, res
      assert_match(/inside the data home/, err)
      refute File.exist?(File.join(data, 'bk'))
    end
  end
end
