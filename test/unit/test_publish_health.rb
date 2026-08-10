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
      path = write_status(dir, "PUB LIVE 13/13 keys 12:00 UTC\n", 37 * 60)
      assert_equal 'PUB 13/13 0:37',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  def test_stale_age_5h_is_flagged
    # 5*60 = 300 min >= 2*120=240 -> !
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB LIVE 13/13 keys 07:00 UTC\n", 5 * 3600)
      assert_equal 'PUB! 13/13 5:00',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  def test_very_stale_age_13h_same_flag
    # No amber/red tiers any more: severity reads from the age itself
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB LIVE 13/13 keys 23:00 UTC\n", 13 * 3600)
      assert_equal 'PUB! 13/13 13:00',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  # ---- DRY mode -----------------------------------------------------------

  def test_dry_is_always_flagged
    # A DRY run on the prod box is a misconfiguration whatever its age
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB DRY 13/13 keys 12:00 UTC\n", 37 * 60)
      assert_equal 'PUB! DRY 13/13 0:37',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  def test_dry_stale_same_flag
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB DRY 13/13 keys 23:00 UTC\n", 13 * 3600)
      assert_equal 'PUB! DRY 13/13 13:00',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  # ---- Incomplete publish (n < m) ----------------------------------------

  def test_incomplete_fresh_publish_is_flagged
    # Fresh LIVE but 12/13 keys -> a key is missing, flag it
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB LIVE 12/13 keys 12:00 UTC\n", 37 * 60)
      assert_equal 'PUB! 12/13 0:37',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  # ---- OLD content-recency marker (additive M7-5) ------------------------

  # A fresh, complete LIVE line WITHOUT the marker is byte-identical to the
  # pre-M7-5 output -- proving the change is additive (fresh cases unchanged).
  def test_fresh_complete_without_marker_is_byte_identical
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB LIVE 13/13 keys 12:00 UTC\n", 37 * 60)
      assert_equal 'PUB 13/13 0:37',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  # A fresh, complete LIVE line that carries ` OLD:...` earns the `!` flag
  # AND the bare `OLD` marker, even though age and n/m are healthy.
  def test_old_marker_flags_and_surfaces_on_otherwise_healthy_line
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB LIVE 13/13 keys 12:00 UTC OLD:lppl:ledger\n", 37 * 60)
      assert_equal 'PUB! 13/13 0:37 OLD',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  # Multiple stale keys still collapse to one bare `OLD` marker in the token.
  def test_old_marker_with_multiple_keys_shows_single_old
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB LIVE 13/13 keys 12:00 UTC OLD:scenario:history,lppl:ledger\n", 37 * 60)
      assert_equal 'PUB! 13/13 0:37 OLD',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  # OLD composes with the other attention conditions (DRY here).
  def test_old_marker_composes_with_dry
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB DRY 13/13 keys 07:00 UTC OLD:lppl:ledger\n", 5 * 3600)
      assert_equal 'PUB! DRY 13/13 5:00 OLD',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  # ---- BLIND data-integrity marker (additive M8-10) ----------------------

  # A fresh, complete LIVE line carrying ` BLIND:...` earns `!` AND the bare
  # `BLIND` marker, even though age and n/m are healthy.
  def test_blind_marker_flags_and_surfaces_on_otherwise_healthy_line
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB LIVE 13/13 keys 12:00 UTC BLIND:scenario\n", 37 * 60)
      assert_equal 'PUB! 13/13 0:37 BLIND',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  # Multiple blind suites still collapse to one bare `BLIND` token.
  def test_blind_marker_with_multiple_suites_shows_single_blind
    Dir.mktmpdir do |dir|
      path = write_status(dir, "PUB LIVE 13/13 keys 12:00 UTC BLIND:scenario,lppl\n", 37 * 60)
      assert_equal 'PUB! 13/13 0:37 BLIND',
                   Ops::PublishHealth.line(path: path, now: NOW, interval_min: INTERVAL)
    end
  end

  # OLD and BLIND compose, in that order (both markers present).
  def test_old_and_blind_compose
    Dir.mktmpdir do |dir|
      path = write_status(dir,
                          "PUB LIVE 13/13 keys 12:00 UTC OLD:lppl:ledger BLIND:scenario\n", 37 * 60)
      assert_equal 'PUB! 13/13 0:37 OLD BLIND',
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
