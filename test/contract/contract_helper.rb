# frozen_string_literal: true
#
# contract_helper.rb -- shared plumbing for the --json / --tmux contract
# tests (M1-7..11). Contract tests run the REAL scripts as subprocesses
# against recorded fixtures via the test/support/fake_transport.rb shim
# (injected through RUBYOPT so aggregator child processes inherit it).
# Time is frozen to the fixtures' recording moment, read from the
# provenance README, so fixtures with real expiries never age out.
#
# Contracts pin FIELD SETS and types, not values (values change with
# every re-recording); exact key-set equality makes any field removal
# OR addition fail until the contract test is updated in the same
# commit (Golden Rule 5).

require_relative '../test_helper'
require 'open3'
require 'time'

module ContractHelpers
  ROOT    = File.expand_path('../..', __dir__)
  SUPPORT = File.join(ROOT, 'test', 'support')

  RECORDED_NOW = begin
    stamp = File.read(File.join(ROOT, 'test', 'fixtures', 'README.md'))[
      /Recorded (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) UTC/, 1]
    raise 'no recording stamp in test/fixtures/README.md' unless stamp

    Time.parse("#{stamp} UTC").iso8601
  end

  def run_script(script, *argv, env: {})
    base = { 'RUBYOPT' => "-I#{SUPPORT} -rfake_transport",
             'FAKE_NOW' => RECORDED_NOW }
    Open3.capture3(base.merge(env), RbConfig.ruby,
                   File.join(ROOT, script), *argv, chdir: ROOT)
  end

  # Run expecting success; parse stdout as one JSON document.
  def run_json(script, *argv, env: {})
    out, err, st = run_script(script, *argv, env: env)
    assert st.success?, "#{script} #{argv.join(' ')} exit #{st.exitstatus}: #{err}"
    JSON.parse(out)
  end

  # The frozen field-set pin: exact key equality, order-insensitive.
  def assert_contract_keys(expected, hash, label = 'object')
    assert_equal expected.sort, hash.keys.sort,
                 "#{label}: --json field set drifted (frozen contract)"
  end
end

Minitest::Test.include ContractHelpers
