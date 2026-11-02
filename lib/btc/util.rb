# frozen_string_literal: true
#
# util.rb -- tiny shared CLI helpers. Extracted from the five per-script
# copies (a Phase-0 tool-review finding).

module BTC
  module Util
    module_function

    # '--flag VALUE' -> 'VALUE' (nil if the flag or value is absent).
    def arg(flag, argv = ARGV)
      i = argv.index(flag)
      i && argv[i + 1]
    end
  end
end
