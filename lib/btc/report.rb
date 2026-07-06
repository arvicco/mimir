# frozen_string_literal: true
#
# report.rb -- uniform module reporting for the signal suites
# (scenario, lppl, btco). One JSON line in --json mode, aligned human
# lines otherwise; fail_soft implements the house convention: a dead
# data source reports score 0 and exits 0, never crashing an aggregate.
# Extracted from the per-suite copies (TOOL-REVIEW.md F-15); name_w /
# key_w preserve each suite's historical column widths.

require 'json'
require 'time'
require_relative 'env'

module BTC
  module Report
    module_function

    # score is -1/0/+1. detail keys are consumed by the aggregators. +now+
    # is the wall clock stamped into the --json `ts` field; it defaults to
    # the real now (unchanged behavior) and is overridden only by replay
    # callers that freeze time to a past as-of day.
    # All string output passes through BTC::Env.redact, so a secret in an
    # exception message or URL can never reach stdout (F-6).
    def report(name, score, headline, detail = {}, name_w: 14, key_w: 18,
               json: ARGV.include?('--json'), now: Time.now.utc)
      headline = BTC::Env.redact(headline)
      detail = detail.reject { |_, v| v.nil? }
      detail = Hash[detail.map { |k, v| [k, v.is_a?(String) ? BTC::Env.redact(v) : v] }]
      if json
        puts JSON.generate({ name: name, score: score, headline: headline,
                             ts: now.iso8601 }.merge(detail))
      else
        puts format("%-#{name_w}s [%+d]  %s", name, score, headline)
        detail.each { |k, v| puts format("  %-#{key_w}s %s", k, v) }
      end
    end

    # Write the one-line tmux status artifact. The /tmp/<basename>.status
    # paths are frozen (--tmux contract); this just centralizes them.
    # +dir+ is injectable so TESTS never touch the real /tmp artifacts
    # (a test run used to clobber /tmp/publish.status and poison the
    # tmux health line on any box that is both dev and staging).
    def status(basename, line, dir: '/tmp')
      File.write(File.join(dir, "#{basename}.status"), line + "\n")
    end

    # The JSON form carries an additive 'unavailable': true marker so
    # consumers can distinguish "healthy 0" from "data source down"
    # without parsing headlines (F-12). Human output is unchanged.
    def fail_soft(name, err, name_w: 14, json: ARGV.include?('--json'))
      detail = json ? { 'unavailable' => true } : {}
      report(name, 0, "unavailable (#{err})", detail, name_w: name_w, json: json)
      exit 0
    end
  end
end
