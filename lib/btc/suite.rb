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
    # failure -- callers degrade to their own score-0 shape. On timeout the
    # child is TERM-then-KILLed (C8: the block form of IO.popen otherwise
    # holds the exception in close-wait until the hung child exits by
    # itself, and the child lingers).
    def run_module(dir, name, timeout, extra = [])
      io = IO.popen(['ruby', File.join(dir, "#{name}.rb"), '--json'] + extra)
      out = nil
      begin
        Timeout.timeout(timeout) { out = io.read }
      rescue Timeout::Error
        begin
          Process.kill('TERM', io.pid)
          Timeout.timeout(2) { Process.wait(io.pid) }
        rescue Timeout::Error
          Process.kill('KILL', io.pid) rescue nil
          Process.wait(io.pid) rescue nil
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
        raise
      ensure
        io.close rescue nil
      end
      JSON.parse(out.to_s.lines.last.to_s)
    end
  end
end
