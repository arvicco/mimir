# frozen_string_literal: true

# test_gex_snapshot.rb -- unit tests for Ops::GexSnapshot (M5-5).
#
# Uses a fake runner (records argv calls, returns canned JSON strings or
# raises) with Dir.mktmpdir and a fixed injected Time so behaviour is
# deterministic and no network or real subprocesses are involved.
#
# Pins: file name + full parsed shape on success; date-guard skip;
# partial failure (one raises "boom secret=xyz" -- that key null,
# error redacted, other key intact); both-fail (file NOT written);
# no *.tmp left behind; runner receives exactly the two expected argvs.

require_relative '../test_helper'
require_relative '../../ops/gex_snapshot'
require 'tmpdir'
require 'json'

class TestGexSnapshot < Minitest::Test
  NOW = Time.utc(2026, 7, 6, 8, 15, 0).freeze

  BTC_DATA = { 'venues' => [{ 'name' => 'DERI', 'gex' => 1.5 }],
               'combined' => { 'flip' => 55_000 } }.freeze
  US_DATA  = [{ 'ticker' => 'IBIT', 'score' => 2 },
              { 'ticker' => 'MSTR', 'score' => -1 }].freeze

  BTC_JSON = JSON.generate(BTC_DATA)
  US_JSON  = JSON.generate(US_DATA)

  # Build a fake runner that records argv arrays and returns responses[i]
  # (or raises it if it is an Exception) in call order.
  def fake_runner(responses)
    calls  = []
    runner = lambda do |argv, _timeout_s|
      calls << argv.dup
      r = responses[calls.size - 1]
      raise r if r.is_a?(Exception)
      r
    end
    [runner, calls]
  end

  # 1. Both captures succeed: file written with both keys verbatim, errors {}.
  def test_success_writes_file_with_both_keys_verbatim_and_empty_errors
    Dir.mktmpdir do |dir|
      runner, _calls = fake_runner([BTC_JSON, US_JSON])
      result = Ops::GexSnapshot.capture(dir: dir, now: NOW, runner: runner)

      assert_equal :written, result[:status]
      expected_path = File.join(dir, '2026-07-06.json')
      assert_equal expected_path, result[:path]
      assert File.file?(expected_path), 'dated file must exist after successful capture'

      parsed = JSON.parse(File.read(expected_path))
      assert_equal '2026-07-06', parsed['date']
      assert_equal NOW.iso8601,  parsed['captured_at']
      assert_equal BTC_DATA,     parsed['btc_combined'], 'btc_combined must be verbatim'
      assert_equal US_DATA,      parsed['us'],           'us must be verbatim'
      assert_equal({},           parsed['errors'])
    end
  end

  # 2. Date-guard: today's file already exists -- return :skipped, leave
  #    file completely untouched, never invoke the runner.
  def test_date_guard_skips_when_file_exists_and_leaves_file_untouched
    Dir.mktmpdir do |dir|
      target = File.join(dir, '2026-07-06.json')
      File.write(target, 'sentinel-content')

      called = false
      runner = lambda { |_a, _t| called = true; '{}' }
      result = Ops::GexSnapshot.capture(dir: dir, now: NOW, runner: runner)

      assert_equal :skipped, result[:status]
      assert_equal target,   result[:path]
      assert_equal 'sentinel-content', File.read(target), 'file must be byte-identical'
      refute called, 'runner must not be invoked when date-guard fires'
    end
  end

  # 3. Partial failure: btc_combined runner raises "boom secret=xyz".
  #    That key must be null; the error entry must be present and the
  #    secret value redacted; the us key must be the verbatim parse.
  def test_partial_failure_records_redacted_error_and_writes_file
    Dir.mktmpdir do |dir|
      runner, _calls = fake_runner([RuntimeError.new('boom secret=xyz'), US_JSON])
      result = Ops::GexSnapshot.capture(dir: dir, now: NOW, runner: runner)

      assert_equal :partial, result[:status]
      assert File.file?(result[:path]), 'file must still be written on partial failure'

      parsed = JSON.parse(File.read(result[:path]))
      assert_nil  parsed['btc_combined'],  'failed capture key must be null'
      assert_equal US_DATA, parsed['us'],  'successful capture key must be verbatim'

      assert parsed['errors'].key?('btc_combined'),
             'errors must contain the failed capture key'
      refute_includes parsed['errors']['btc_combined'], 'xyz',
                      'the raw secret-bearing value must not appear in the stored error'
      assert_includes parsed['errors']['btc_combined'], '[REDACTED]',
                      'redaction marker must be present in the stored error'
    end
  end

  # 4. Both captures fail: file must NOT be written; result is :failed with
  #    two error entries (one per capture).
  def test_both_fail_does_not_write_file
    Dir.mktmpdir do |dir|
      runner, _calls = fake_runner([RuntimeError.new('err1'), RuntimeError.new('err2')])
      result = Ops::GexSnapshot.capture(dir: dir, now: NOW, runner: runner)

      assert_equal :failed, result[:status]
      refute File.file?(result[:path]),
             'no file must be written when both captures fail'
      assert_equal 2, result[:errors].size,
                   'errors must contain one entry per failed capture'
    end
  end

  # 5. No *.tmp files remain after a successful write.
  def test_no_tmp_file_left_after_successful_write
    Dir.mktmpdir do |dir|
      runner, _ = fake_runner([BTC_JSON, US_JSON])
      Ops::GexSnapshot.capture(dir: dir, now: NOW, runner: runner)

      tmps = Dir.glob(File.join(dir, '*.tmp'))
      assert_empty tmps, "unexpected .tmp files after write: #{tmps.inspect}"
    end
  end

  # 6. Runner receives exactly the two expected argv arrays, in order.
  def test_runner_receives_expected_argvs_in_order
    Dir.mktmpdir do |dir|
      runner, calls = fake_runner([BTC_JSON, US_JSON])
      Ops::GexSnapshot.capture(dir: dir, now: NOW, runner: runner)

      assert_equal 2, calls.size
      assert_equal ['ruby', 'scripts/gex_btc_combined.rb', '--json'],
                   calls[0], 'first call must be gex_btc_combined.rb --json'
      assert_equal ['ruby', 'scripts/gex_us.rb', 'IBIT', 'MSTR', '--json'],
                   calls[1], 'second call must be gex_us.rb IBIT MSTR --json'
    end
  end
end
