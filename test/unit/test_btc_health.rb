# frozen_string_literal: true

# Offline tests for the health framework: conventions scanners on
# synthetic content, registry integrity against the real repo (file
# reads only), env-gated probe skip. No network (Golden Rule 6).

require_relative '../test_helper'
require_relative '../../lib/btc/health'

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
