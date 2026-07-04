# frozen_string_literal: true
#
# deribit.rb -- Deribit public-API venue helper over the http seam.
# Owns the base URL and the {"result": ...} envelope unwrap that five
# scripts previously spelled out on their own (TOOL-REVIEW.md R-1/R-8).

require 'json'
require_relative 'http'

module BTC
  module Deribit
    BASE = 'https://www.deribit.com/api/v2/public'

    module_function

    # GET <BASE>/<path>, unwrap the result envelope (KeyError if absent).
    def result(path, headers = {})
      JSON.parse(Http.get("#{BASE}/#{path}", headers)).fetch('result')
    end

    # Index price as a Float, e.g. index_price('btc_usd').
    def index_price(index_name)
      result("get_index_price?index_name=#{index_name}")
        .fetch('index_price').to_f
    end

    # Whole-board summary rows, e.g. book_summary('BTC', 'option').
    def book_summary(currency, kind)
      result("get_book_summary_by_currency?currency=#{currency}&kind=#{kind}")
    end
  end
end
