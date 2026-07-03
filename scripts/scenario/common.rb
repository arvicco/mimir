# frozen_string_literal: true
#
# common.rb -- shared helpers for the scenario signal modules.
# Ruby >= 2.5, stdlib only.

require 'json'
require 'time'
require_relative '../../lib/btc/report'
require_relative '../../lib/btc/http'

module Common
  module_function

  def get(url, headers = {})
    BTC::Http.get(url, { 'User-Agent' => 'scenario.rb' }.merge(headers))
  end

  def get_json(url, headers = {})
    JSON.parse(get(url, headers))
  end

  # Every module reports through this. Score is -1/0/+1:
  #   +1 recovery/base-supportive, -1 flush-supportive, 0 neutral/unknown.
  # --json prints the machine form consumed by scenario.rb.
  def report(name, score, headline, detail = {})
    BTC::Report.report(name, score, headline, detail, name_w: 14, key_w: 18)
  end

  # Report score 0 with a reason and exit cleanly, so one dead data source
  # never breaks the aggregate.
  def fail_soft(name, err)
    BTC::Report.fail_soft(name, err, name_w: 14)
  end
end
