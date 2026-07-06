# frozen_string_literal: true

# Offline tests for the health framework: conventions scanners on
# synthetic content, registry integrity against the real repo (file
# reads only), env-gated probe skip. No network (Golden Rule 6).

require_relative '../test_helper'
require_relative '../../lib/btc/health'
require 'tmpdir'
require 'fileutils'

class TestHealthConventions < Minitest::Test
  CLEAN = <<~RB
    #!/usr/bin/env ruby
    # frozen_string_literal: true
    body = BTC::Http.get(url, { 'User-Agent' => 'x' })
    BTC::Report.status('x', line)
  RB

  def scan(content, path = 'scripts/x.rb')
    BTC::Health.scan_conventions(path => content)
  end

  def test_clean_file_passes
    assert_empty scan(CLEAN)
  end

  def test_flags_missing_frozen_pragma
    v = scan("#!/usr/bin/env ruby\nputs 1\n")
    assert v.any? { |m| m.include?('frozen_string_literal') }
  end

  def test_flags_seam_bypass
    v = scan(CLEAN + "res = Net::HTTP.start(h, p)\nuri = URI(url)\n")
    assert_equal 2, v.count { |m| m.include?('outside the seam') }
  end

  def test_flags_braceless_trailing_hash_f18
    v = scan(CLEAN + "BTC::Http.get(url, 'User-Agent' => 'x')\n")
    assert v.any? { |m| m.include?('F-18') }
    # braced form is fine (already in CLEAN)
    assert_empty scan(CLEAN)
  end

  def test_flags_raw_tmp_write
    v = scan(CLEAN + "File.write('/tmp/x.status', line)\n")
    assert v.any? { |m| m.include?('Report.status') }
  end

  def test_flags_unallowed_env_but_permits_allowlisted
    v = scan(CLEAN + "k = ENV['SOME_NEW_KEY']\n")
    assert v.any? { |m| m.include?("ENV['SOME_NEW_KEY']") }
    ok = BTC::Health.scan_conventions(
      'scripts/scenario/macro.rb' => CLEAN + "k = ENV['FRED_API_KEY']\n"
    )
    assert_empty ok
  end

  def test_comment_lines_are_ignored
    assert_empty scan(CLEAN + "# Net::HTTP is mentioned here in prose\n")
  end
end

class TestHealthSRI < Minitest::Test
  PIN = BTC::Health::ECHARTS_PIN
  VER  = PIN[:version]
  HASH = PIN[:sha384]

  GOOD_TAG = <<~HTML
    <script src="https://cdn.jsdelivr.net/npm/echarts@#{VER}/dist/echarts.min.js"
            integrity="sha384-#{HASH}"
            crossorigin="anonymous"></script>
  HTML

  def good_pages
    { 'web/preview.html' => GOOD_TAG, 'web/index.html' => GOOD_TAG }
  end

  def test_clean_pages_pass
    assert_empty BTC::Health.scan_sri(good_pages)
  end

  def test_real_files_pass
    root = File.expand_path('../..', __dir__)
    pages = {
      'web/preview.html' => File.read(File.join(root, 'web/preview.html')),
      'web/index.html'   => File.read(File.join(root, 'web/index.html'))
    }
    assert_empty BTC::Health.scan_sri(pages)
  end

  def test_flags_missing_integrity
    tag = <<~HTML
      <script src="https://cdn.jsdelivr.net/npm/echarts@#{VER}/dist/echarts.min.js"
              crossorigin="anonymous"></script>
    HTML
    bad = BTC::Health.scan_sri('web/preview.html' => tag, 'web/index.html' => GOOD_TAG)
    assert bad.any? { |m| m.include?('missing integrity') }
  end

  def test_flags_missing_crossorigin
    tag = <<~HTML
      <script src="https://cdn.jsdelivr.net/npm/echarts@#{VER}/dist/echarts.min.js"
              integrity="sha384-#{HASH}"></script>
    HTML
    bad = BTC::Health.scan_sri('web/preview.html' => tag, 'web/index.html' => GOOD_TAG)
    assert bad.any? { |m| m.include?('missing crossorigin') }
  end

  def test_flags_wrong_hash
    tag = <<~HTML
      <script src="https://cdn.jsdelivr.net/npm/echarts@#{VER}/dist/echarts.min.js"
              integrity="sha384-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
              crossorigin="anonymous"></script>
    HTML
    bad = BTC::Health.scan_sri('web/preview.html' => tag, 'web/index.html' => GOOD_TAG)
    assert bad.any? { |m| m.include?('integrity hash mismatch') || m.include?('disagree on echarts SRI hash') }
  end

  def test_flags_version_mismatch_between_pages
    old_tag = <<~HTML
      <script src="https://cdn.jsdelivr.net/npm/echarts@5.5.0/dist/echarts.min.js"
              integrity="sha384-#{HASH}"
              crossorigin="anonymous"></script>
    HTML
    bad = BTC::Health.scan_sri('web/preview.html' => old_tag, 'web/index.html' => GOOD_TAG)
    # should flag the wrong version on the old_tag page AND/OR cross-page disagreement
    assert bad.any? { |m| m.include?('5.5.0') || m.include?('disagree on echarts version') }
  end

  def test_flags_hash_disagreement_between_pages
    alt_tag = <<~HTML
      <script src="https://cdn.jsdelivr.net/npm/echarts@#{VER}/dist/echarts.min.js"
              integrity="sha384-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
              crossorigin="anonymous"></script>
    HTML
    bad = BTC::Health.scan_sri('web/preview.html' => alt_tag, 'web/index.html' => GOOD_TAG)
    assert bad.any? { |m| m.include?('disagree on echarts SRI hash') || m.include?('mismatch') }
  end

  def test_flags_missing_script_tag
    bad = BTC::Health.scan_sri('web/preview.html' => '<html></html>', 'web/index.html' => GOOD_TAG)
    assert bad.any? { |m| m.include?('echarts script tag not found') }
  end
end

class TestHealthRegistry < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def test_registry_markers_match_the_codebase
    assert_empty BTC::Health.registry_integrity(ROOT)
  end

  def test_env_gated_probe_skips_without_key
    entry = BTC::Health::SOURCES.find { |s| s[:env] == 'FRED_API_KEY' }
    old = ENV.delete('FRED_API_KEY')
    status, = BTC::Health.probe(entry)
    assert_equal :skip, status # never touches the network
  ensure
    ENV['FRED_API_KEY'] = old if old
  end

  def test_every_entry_is_fully_formed
    BTC::Health::SOURCES.each do |s|
      %i[name src marker url check].each do |k|
        assert s[k], "#{s[:name] || s.inspect} missing #{k}"
      end
    end
  end
end

# Offline scan of ops/ (M5-1): bash -n syntax, PUBLISH_DRY_RUN=0 in the
# publish wrapper, the --apply ban, and plist well-formedness/required
# keys via rexml (no plutil -- not on the ubuntu CI). Green on the real
# repo; red on a synthetic dir with a bad plist and an --apply shell.
class TestHealthOps < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  GOOD_PLIST = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>com.mimir.test</string>
        <key>ProgramArguments</key>
        <array>
          <string>/tmp/x/ops/run_publish.sh</string>
        </array>
        <key>RunAtLoad</key>
        <false/>
      </dict>
    </plist>
  XML

  def test_real_ops_dir_passes
    assert_empty BTC::Health.scan_ops(File.join(ROOT, 'ops'))
  end

  def test_missing_ops_dir_fails
    Dir.mktmpdir do |dir|
      bad = BTC::Health.scan_ops(File.join(dir, 'nope'))
      refute_empty bad
      assert bad.any? { |m| m.include?('missing') }
    end
  end

  def test_empty_ops_dir_fails
    Dir.mktmpdir do |dir|
      ops = File.join(dir, 'ops')
      FileUtils.mkdir_p(ops)
      refute_empty BTC::Health.scan_ops(ops)
    end
  end

  def test_flags_bad_plist_and_apply_shell
    Dir.mktmpdir do |dir|
      ops = File.join(dir, 'ops')
      FileUtils.mkdir_p(ops)
      # A shell that reaches for --apply (universe.json protection) and
      # omits PUBLISH_DRY_RUN=0 despite being the publish wrapper.
      File.write(File.join(ops, 'run_publish.sh'),
                 "#!/bin/bash\nset -eu\nruby scripts/btco/ingest.rb --apply\n")
      # A plist that would let launchd respawn (RunAtLoad true).
      File.write(File.join(ops, 'com.mimir.publish.plist'),
                 GOOD_PLIST.sub('<false/>', '<true/>'))

      bad = BTC::Health.scan_ops(ops)
      assert bad.any? { |m| m.include?('--apply') }, "expected --apply flag, got #{bad.inspect}"
      assert bad.any? { |m| m.include?('PUBLISH_DRY_RUN=0') }, 'expected missing-dry-run flag'
      assert bad.any? { |m| m.include?('RunAtLoad') }, 'expected RunAtLoad-true flag'
    end
  end

  def test_flags_malformed_plist
    Dir.mktmpdir do |dir|
      ops = File.join(dir, 'ops')
      FileUtils.mkdir_p(ops)
      File.write(File.join(ops, 'run_publish.sh'), "#!/bin/bash\nexport PUBLISH_DRY_RUN=0\n")
      File.write(File.join(ops, 'x.plist'), "<plist><dict><key>Label</key></dict>\n") # unclosed
      bad = BTC::Health.scan_ops(ops)
      assert bad.any? { |m| m.include?('well-formed') || m.include?('XML') }, "got #{bad.inspect}"
    end
  end

  def test_flags_shell_syntax_error
    Dir.mktmpdir do |dir|
      ops = File.join(dir, 'ops')
      FileUtils.mkdir_p(ops)
      File.write(File.join(ops, 'run_publish.sh'),
                 "#!/bin/bash\nexport PUBLISH_DRY_RUN=0\nif true; then\n") # unterminated if
      File.write(File.join(ops, 'com.mimir.publish.plist'), GOOD_PLIST)
      bad = BTC::Health.scan_ops(ops)
      assert bad.any? { |m| m.include?('syntax') }, "got #{bad.inspect}"
    end
  end

  def test_flags_apply_inside_a_plist
    Dir.mktmpdir do |dir|
      ops = File.join(dir, 'ops')
      FileUtils.mkdir_p(ops)
      # A plist could schedule --apply directly in ProgramArguments; the
      # ban covers every ops file, not just the shell wrappers.
      File.write(File.join(ops, 'com.mimir.evil.plist'),
                 GOOD_PLIST.sub('/tmp/x/ops/run_publish.sh',
                                '/tmp/x/scripts/btco/ingest.rb --apply x'))
      bad = BTC::Health.scan_ops(ops)
      assert bad.any? { |m| m.include?('--apply') }, "got #{bad.inspect}"
    end
  end
end
