# frozen_string_literal: true

# test_publish_health.rb -- byte-exact contract tests for ops/publish_health.rb
# (M5-2). Every output branch is pinned with an injected clock and injected
# path; NO Time.now, NO sleeping. File mtimes are set via File.utime against
# a fixed NOW constant so the tests are entirely deterministic.

require_relative '../test_helper'
require_relative '../../ops/publish_health'
require 'tmpdir'

class TestPublishHealth < Minitest::Test
  # Fixed reference point for all age calculations.
  NOW      = Time.utc(2026, 7, 6, 12, 0, 0)
  INTERVAL = 120 # minutes (default; matches D5-a)

  # Write +content+ to a file in +dir+ and set its mtime to NOW - age_seconds.
  # Returns the file path.
  def write_status(dir, content, age_seconds)
    path  = File.join(dir, 'publish.status')
    File.write(path, content)
    mtime = NOW - age_seconds
    File.utime(mtime, mtime, path)
    path
  end

  # ---- LIVE mode: attention flag (colour codes retired, owner ruling
  # ---- 2026-07-06: plain token, `!` = attention) ---------------------------

  def test_fresh_complete_is_unflagged
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB LIVE 11/11 keys 12:00 UTC\n", 37 * 60)
      assert_equal 'PUB 11/11 0:37',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  def test_stale_age_5h_is_flagged
    # 5*60 = 300 min >= 2*120=240 -> !
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB LIVE 11/11 keys 07:00 UTC\n", 5 * 3600)
      assert_equal 'PUB! 11/11 5:00',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  def test_very_stale_age_13h_same_flag
    # No amber/red tiers any more: severity reads from the age itself
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB LIVE 11/11 keys 23:00 UTC\n", 13 * 3600)
      assert_equal 'PUB! 11/11 13:00',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  # ---- DRY mode -----------------------------------------------------------

  def test_dry_is_always_flagged
    # A DRY run on the prod box is a misconfiguration whatever its age
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB DRY 11/11 keys 12:00 UTC\n", 37 * 60)
      assert_equal 'PUB! DRY 11/11 0:37',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  def test_dry_stale_same_flag
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB DRY 11/11 keys 23:00 UTC\n", 13 * 3600)
      assert_equal 'PUB! DRY 11/11 13:00',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  # ---- Incomplete publish (n < m) ----------------------------------------

  def test_incomplete_fresh_publish_is_flagged
    # Fresh LIVE but 10/11 keys -> a key is missing, flag it
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB LIVE 10/11 keys 12:00 UTC\n", 37 * 60)
      assert_equal 'PUB! 10/11 0:37',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  # ---- Error paths --------------------------------------------------------

  def test_missing_file_returns_error_line
    assert_equal 'PUB! ?',
                 Ops::PublishHealth.line(
                   path: '/tmp/mimir_test_nonexistent_xyzzy_publish.status',
                   now: NOW, interval_min: INTERVAL
                 )
  end

  def test_garbled_first_line_returns_error_line
    Dir.mktmpdir do |dir|
      path = write_status(dir, "SOMETHING COMPLETELY WRONG\n", 37 * 60)
      assert_equal 'PUB! ?',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  # ---- H:MM formatting edges ----------------------------------------------

  def test_format_age_zero_seconds
    assert_equal '0:00', Ops::PublishHealth.format_age(0)
  end

  def test_format_age_sub_minute
    # 59 seconds still floors to 0 whole minutes
    assert_equal '0:00', Ops::PublishHealth.format_age(59)
  end

  def test_format_age_1h05m
    assert_equal '1:05', Ops::PublishHealth.format_age(65 * 60)
  end

  def test_format_age_26h03m
    assert_equal '26:03', Ops::PublishHealth.format_age((26 * 60 + 3) * 60)
  end
end
