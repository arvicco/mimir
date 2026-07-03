# frozen_string_literal: true
#
# suite.rb -- aggregator machinery shared by scenario.rb and lppl.rb
# (TOOL-REVIEW.md R-4). A module runs as a subprocess so a crash or hang
# in one signal can never take down the composite; only the LAST stdout
# line is parsed (module stdout discipline: exactly one JSON line in
# --json mode).

require 'json'
require 'timeout'

module BTC
  module Suite
    module_function

    # Run <dir>/<name>.rb --json [extra...] under a timeout; return the
    # parsed hash. Raises (Timeout::Error, JSON::ParserError, ...) on any
    # failure -- callers degrade to their own score-0 shape.
    def run_module(dir, name, timeout, extra = [])
      out = nil
      Timeout.timeout(timeout) do
        out = IO.popen(['ruby', File.join(dir, "#{name}.rb"), '--json'] + extra,
                       &:read)
      end
      JSON.parse(out.to_s.lines.last.to_s)
    end
  end
end
