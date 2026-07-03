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

module BTC
  module Report
    module_function

    # score is -1/0/+1. detail keys are consumed by the aggregators.
    def report(name, score, headline, detail = {}, name_w: 14, key_w: 18,
               json: ARGV.include?('--json'))
      detail = detail.reject { |_, v| v.nil? }
      if json
        puts JSON.generate({ name: name, score: score, headline: headline,
                             ts: Time.now.utc.iso8601 }.merge(detail))
      else
        puts format("%-#{name_w}s [%+d]  %s", name, score, headline)
        detail.each { |k, v| puts format("  %-#{key_w}s %s", k, v) }
      end
    end

    def fail_soft(name, err, name_w: 14, json: ARGV.include?('--json'))
      report(name, 0, "unavailable (#{err})", {}, name_w: name_w, json: json)
      exit 0
    end
  end
end
