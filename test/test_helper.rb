# frozen_string_literal: true

# test_helper.rb -- minitest bootstrap. stdlib/bundled gems only: minitest
# ships with Ruby. No network is permitted anywhere under test/.

require 'minitest/autorun'
require 'json'

module TestHelpers
  FIXTURES = File.expand_path(File.join(__dir__, 'fixtures'))

  def fixture(name)
    File.read(File.join(FIXTURES, name))
  end

  def json_fixture(name)
    JSON.parse(fixture(name))
  end

  def assert_close(expected, actual, tol = 1e-9, msg = nil)
    assert (expected - actual).abs <= tol,
           msg || "expected #{expected} within #{tol}, got #{actual}"
  end
end

Minitest::Test.include TestHelpers
