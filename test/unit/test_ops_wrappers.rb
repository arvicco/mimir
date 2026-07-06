# frozen_string_literal: true

# Offline tests for the ops/ launchd wrapper (M5-1). Shells the real
# ops/run_publish.sh with HOME pointed at a tmpdir and MIMIR_ENV_FILE /
# MIMIR_RUBY injected, so nothing touches the network or the owner's
# machine (Golden Rule 6). Two behaviours are pinned: the secret-free
# refusal when the env file is unreadable (exit 78), and the happy path
# -- env sourced, PUBLISH_DRY_RUN=0, cwd = repo root, publisher exit code
# passed through, and the marker line written to the log.

require_relative '../test_helper'
require 'open3'
require 'tmpdir'
require 'fileutils'

class TestOpsWrapper < Minitest::Test
  ROOT    = File.expand_path('../..', __dir__)
  WRAPPER = File.join(ROOT, 'ops', 'run_publish.sh')

  def run_wrapper(env)
    Open3.capture3(env, 'bash', WRAPPER)
  end

  def test_missing_env_file_refuses_with_exit_78_and_no_secrets
    Dir.mktmpdir do |home|
      missing = File.join(home, '.config', 'mimir', 'env')
      out, err, status = run_wrapper('HOME' => home, 'MIMIR_ENV_FILE' => missing)

      assert_equal 78, status.exitstatus, "expected EX config exit 78, got #{status.exitstatus} (stderr: #{err})"
      assert_empty out, 'nothing should reach stdout on the refusal path'
      assert_equal 1, err.lines.size, "refusal must be a single line, got: #{err.inspect}"
      assert_includes err, missing, 'the missing path must be named'
      assert_includes err, 'RUNBOOK', 'the operator must be pointed at the runbook'
    end
  end

  def test_happy_path_sources_env_sets_dry_run_off_and_passes_exit_through
    Dir.mktmpdir do |home|
      env_file  = File.join(home, 'env')
      dump_file = File.join(home, 'dump.txt')
      stub      = File.join(home, 'stub_ruby')

      # env file the wrapper must source (set -a auto-exports MARKER_VAR).
      File.write(env_file, "MARKER_VAR=sourced-marker-42\n")

      # Stand-in for `ruby`: dump the env the wrapper handed us, then exit
      # 3 so we can prove the publisher's code becomes the wrapper's code.
      File.write(stub, <<~SH)
        #!/bin/bash
        {
          echo "PUBLISH_DRY_RUN=${PUBLISH_DRY_RUN:-}"
          echo "MARKER_VAR=${MARKER_VAR:-}"
          echo "PWD=$(pwd)"
        } > "#{dump_file}"
        exit 3
      SH
      FileUtils.chmod(0o755, stub)

      _out, _err, status = run_wrapper(
        'HOME'           => home,
        'MIMIR_ENV_FILE' => env_file,
        'MIMIR_RUBY'     => stub
      )

      assert_equal 3, status.exitstatus, 'publisher exit code must pass through'

      dump = File.read(dump_file)
      assert_includes dump, 'PUBLISH_DRY_RUN=0', 'wrapper must force a LIVE publish'
      assert_includes dump, 'MARKER_VAR=sourced-marker-42', 'env file must be sourced'
      assert_includes dump, "PWD=#{ROOT}", 'publisher must run from the repo root'

      log = File.join(home, 'Library', 'Logs', 'mimir', 'publish.log')
      assert File.file?(log), 'the publish log must be created under HOME'
      assert_match(/^=== run_publish /, File.read(log), 'log must open with the run marker')
    end
  end
end
