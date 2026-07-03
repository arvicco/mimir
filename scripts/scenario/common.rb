# frozen_string_literal: true
#
# common.rb -- shared helpers for the scenario signal modules.
# Ruby >= 2.5, stdlib only.

require 'net/http'
require 'json'
require 'time'
require_relative '../../lib/btc/report'

module Common
  module_function

  def get(url, headers = {})
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                    open_timeout: 5, read_timeout: 20) do |http|
      req = Net::HTTP::Get.new(uri.request_uri,
                               { 'User-Agent' => 'scenario.rb' }.merge(headers))
      res = http.request(req)
      raise "HTTP #{res.code}" unless res.code.to_i == 200

      res.body
    end
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
