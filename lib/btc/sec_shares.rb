# frozen_string_literal: true
#
# sec_shares.rb -- structured cover-page share counts from SEC XBRL
# (M7-12). dei:EntityCommonStockSharesOutstanding via the companyconcept
# JSON API is, by spec (EDGAR XBRL Guide section 3.2.3), a point-in-time
# cover-page count with an as-of date -- EXACTLY the number our schema
# demands (shares OUTSTANDING, never income-statement weighted averages).
# It replaces AI extraction for this field wherever it exists.
#
# HARD LIMITATION (data-source research, docs/BTCO-DATA-SOURCES.md): the
# SEC aggregation APIs drop DIMENSIONAL facts. Multi-class filers (MSTR,
# ASST) tag cover counts per share class, so this endpoint 404s for them
# -- outstanding_for returns nil and their counts stay on the manual /
# filing-iXBRL path (M7-13). nil here means "not available structured",
# never "zero shares".
#
# Advisory contract mirrors TreasuryRef/CoingeckoRef: any error -> nil,
# never an exception into review. Caching: read-through per-CIK via
# BTC::SourceCache (name 'sec_shares_<cik>', shared 48h cap). Callers
# pass the EDGAR courtesy User-Agent headers (ENV['EDGAR_UA'] is owned by
# the caller; this module reads no ENV itself).
#
# stdlib only. Network only via BTC::Http (through SourceCache).

require 'time'
require_relative 'http'
require_relative 'source_cache'

module BTC
  module SecShares
    URL_FMT = 'https://data.sec.gov/api/xbrl/companyconcept/CIK%010d' \
              '/dei/EntityCommonStockSharesOutstanding.json'
    SOURCE  = 'sec-xbrl dei'

    module_function

    # cik -> { 'shares'=>Integer, 'as_of'=>'YYYY-MM-DD', 'form'=>str,
    # 'source'=>str, 'stale'=>bool } for the LATEST cover-page count on
    # file, else nil (multi-class filer / unknown CIK / source down with
    # no usable cache). Never raises for a data miss.
    def outstanding_for(cik, headers: {}, now: Time.now.utc)
      n = cik.to_i
      return nil unless n.positive?

      fetched = BTC::SourceCache.fetch_json("sec_shares_#{n}",
                                            format(URL_FMT, n), headers, now: now)
      facts = fetched.dig('data', 'units', 'shares')
      return nil unless facts.is_a?(Array) && !facts.empty?

      latest = facts.max_by { |u| u['end'].to_s }
      shares = latest['val'].to_i
      return nil unless shares.positive?

      { 'shares' => shares, 'as_of' => latest['end'], 'form' => latest['form'],
        'source' => SOURCE, 'stale' => fetched['stale'] }
    rescue StandardError
      nil
    end
  end
end
