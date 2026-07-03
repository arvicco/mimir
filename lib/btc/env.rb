# frozen_string_literal: true
#
# env.rb -- ENV access and data-dir resolution (ARCHITECTURE.md section 3).
# One rule for every suite: runtime artifacts live in
# $BTC_DATA_DIR/<suite>/ when BTC_DATA_DIR is set, else in the suite's
# in-tree data/ dir (the historical default). Status lines stay in /tmp
# (ephemeral, tmux-facing) and btco's capstruct/ is a committed audit
# trail, not runtime data -- both deliberate exceptions.

module BTC
  module Env
    module_function

    def data_dir(suite, default)
      base = ENV['BTC_DATA_DIR']
      base && !base.empty? ? File.join(base, suite) : default
    end
  end
end
