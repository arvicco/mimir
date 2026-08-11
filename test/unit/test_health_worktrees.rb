# frozen_string_literal: true

# Worktree discipline checks (owner rulings 2026-08-11): no worktree
# outside the main checkout, no stale worktree after its phase merged.
# check_worktrees is pure; git gathering lives in scan_worktrees.

require_relative '../test_helper'
require_relative '../../lib/btc/health'

class TestHealthWorktrees < Minitest::Test
  ROOT = '/Users/x/Dev/mimir'

  def porcelain(entries)
    entries.map { |p, b| "worktree #{p}\nHEAD abc\nbranch refs/heads/#{b}\n" }
           .join("\n") + "\n"
  end

  def test_contained_active_worktree_is_clean
    out = porcelain([[ROOT, 'main'], ["#{ROOT}/.worktrees/phase-9", 'phase-9']])
    assert_empty BTC::Health.check_worktrees(out, [])
  end

  def test_sibling_worktree_is_flagged
    out = porcelain([[ROOT, 'main'], ['/Users/x/Dev/mimir-phase9', 'phase-9']])
    bad = BTC::Health.check_worktrees(out, [])
    assert_equal 1, bad.size
    assert_match(/outside the repo/, bad.first)
  end

  def test_prefix_sibling_is_not_mistaken_for_contained
    # /Users/x/Dev/mimir-phase9 shares the /Users/x/Dev/mimir PREFIX but is
    # NOT inside it -- the separator-suffixed comparison must catch this.
    out = porcelain([[ROOT, 'main'], ["#{ROOT}-phase9", 'phase-9']])
    refute_empty BTC::Health.check_worktrees(out, [])
  end

  def test_stale_merged_worktree_is_flagged_even_inside
    out = porcelain([[ROOT, 'main'], ["#{ROOT}/.worktrees/phase-8", 'phase-8']])
    bad = BTC::Health.check_worktrees(out, ['phase-8'])
    assert_equal 1, bad.size
    assert_match(/STALE/, bad.first)
  end

  def test_main_checkout_itself_is_never_stale
    out = porcelain([[ROOT, 'main']])
    assert_empty BTC::Health.check_worktrees(out, ['phase-8'])
  end

  def test_outside_and_stale_stack
    out = porcelain([[ROOT, 'main'], ['/Users/x/Dev/mimir-phase8', 'phase-8']])
    bad = BTC::Health.check_worktrees(out, ['phase-8'])
    assert_equal 2, bad.size
  end
end
