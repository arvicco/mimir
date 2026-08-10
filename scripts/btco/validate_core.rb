# frozen_string_literal: true
#
# validate_core.rb -- pure reconciliation math for the BTCo validation
# tool (M7-15), extracted for offline unit testing (metrics.rb pattern).
# No IO, no ENV, no network.
#
# The owner's ask (2026-07-09): "we need some kind of objective source
# of truth -- our universe filling process seems not grounded in
# reality." The objective part is DECOMPOSITION: our published mNAV and
# an external researcher's mNAV are both px*shares/(btc*btc_px), so the
# ratio between them factors EXACTLY into four input ratios. Whichever
# factor is furthest from 1 names the input that drives the divergence
# -- no judgment involved. A residual far from 1 after all four factors
# means the DEFINITIONS differ (e.g. diluted vs basic mcap), which is
# its own finding.

module Btco
  module Validate
    # tolerance for "inputs agree" verdicts (matches the ingest ref lines)
    TOL = 0.02

    module_function

    # Our published view of one company: the row the dashboard serves
    # (payload = the v1:btco:latest envelope's payload) joined with the
    # universe entry that produced it (shares live only there). nil when
    # the company has no row (e.g. its price source returned nothing).
    def our_view(payload, uni_co)
      row = (payload['companies'] || []).find { |c| c['ticker'] == uni_co['ticker'] }
      return nil unless row

      { 'px' => row['px'].to_f, 'btc' => row['btc'].to_f,
        'mnav' => row['mnav'], 'btc_px' => payload['btc_spot'].to_f,
        'shares' => uni_co['shares_basic'],
        'btc_as_of' => row['btc_as_of'], 'stale' => row['stale'],
        'placeholder' => row['placeholder'] }
    end

    # StrategyTracker's external view for one universe ticker. companies
    # is the feed's 'companies' hash; tracker keys are exchange-qualified.
    def tracker_view(companies, ticker)
      key = ["#{ticker}.T", "#{ticker}.US", ticker].find { |k| (companies || {}).key?(k) }
      return nil unless key

      pm = companies.dig(key, 'processedMetrics')
      return nil unless pm

      tt = (pm['treasury_table'] || []).last || {}
      { 'key' => key, 'px' => pm['stockPrice'], 'btc_px' => pm['btcPrice'],
        'mnav_basic' => pm['navPremiumBasic'], 'mnav_diluted' => pm['navPremiumDiluted'],
        'shares' => tt['Total Outstanding Shares'], 'shares_as_of' => tt['Date'],
        'btc' => tt['BTC Balance'] }
    end

    # Factor decomposition of our_mnav / tracker_mnav_basic. Both are
    # px*shares/(btc*btc_px), so:
    #   ours/theirs = (px_o/px_t) * (sh_o/sh_t) * (btc_t/btc_o) * (btcpx_t/btcpx_o)
    # Returns factors (nil where an input is missing), the actual ratio,
    # the product of known factors, the residual (actual/explained --
    # near 1 means the four inputs fully explain the gap, i.e. the
    # DEFINITIONS agree), and the dominant factor's name.
    def reconcile(ours, ext)
      return nil unless ours && ext
      return nil unless ours['mnav'].to_f.positive? && ext['mnav_basic'].to_f.positive?

      f = {
        'px'     => ratio(ours['px'], ext['px']),
        'shares' => ratio(ours['shares'], ext['shares']),
        'btc'    => ratio(ext['btc'], ours['btc']),
        'btc_px' => ratio(ext['btc_px'], ours['btc_px'])
      }
      known = f.values.compact.reduce(1.0, :*)
      actual = ours['mnav'].to_f / ext['mnav_basic'].to_f
      dominant = f.reject { |_, v| v.nil? }.max_by { |_, v| Math.log(v).abs }&.first
      { 'factors' => f, 'actual_ratio' => actual, 'explained_ratio' => known,
        'residual' => known.positive? ? actual / known : nil,
        'dominant' => dominant }
    end

    def ratio(a, b)
      a = a.to_f
      b = b.to_f
      a.positive? && b.positive? ? a / b : nil
    end

    def pct(ratio_val)
      format('%+.1f%%', (ratio_val - 1.0) * 100)
    end

    # Plain-words per-company to-do lines -- the answer to "wtf is even
    # needed?". uni_co = universe entry; ours = our_view (may be nil);
    # btc_refs = { 'source name' => count, ... } (independent BTC counts);
    # tracker = tracker_view (may be nil). Every line names the problem
    # AND the action. Empty array = nothing needed, inputs agree.
    def needs(uni_co, ours, btc_refs, tracker)
      t = uni_co['ticker']
      out = []
      unless ours
        out << "NOT ON THE DASHBOARD: no price from the quote source " \
               "(#{uni_co['stooq'] || 'none configured'}) -- fix the price " \
               'source or set manual_px (decision item)'
      end
      if uni_co['placeholder']
        out << 'placeholder flag set: seed data never confirmed by a filing ' \
               '-- if the btc refs below concur, clear it via a deliberate ' \
               'reviewed edit; if not, ingest the latest filing first'
      end
      if uni_co['shares_basic'].nil?
        out << 'shares unknown -> mNAV cannot be computed: needs a cover-page ' \
               "count (ruby scripts/btco/ingest.rb --ticker #{t} --limit 2, " \
               'or a manual cover read)'
      end
      divergent = btc_refs.select do |_, n|
        n.to_f.positive? && ((uni_co['btc'].to_f - n.to_f).abs / n.to_f) > TOL
      end
      if !divergent.empty? && divergent.size == btc_refs.size && btc_refs.size >= 2
        out << format('BTC count off vs EVERY ref (ours %s vs %s) -- a newer ' \
                      'filing exists: ruby scripts/btco/ingest.rb --ticker %s --limit 2',
                      commafy(uni_co['btc']),
                      btc_refs.map { |s, n| "#{commafy(n)} @#{s}" }.join(', '), t)
      end
      if tracker && tracker['shares'] && uni_co['shares_basic'] &&
         (r = ratio(uni_co['shares_basic'], tracker['shares'])) && (r - 1.0).abs > TOL
        out << format('share count stale: ours %s vs tracker %s @%s (ATM growth ' \
                      'outruns quarterly covers) -- refresh from the newest filing',
                      commafy(uni_co['shares_basic']), commafy(tracker['shares']),
                      tracker['shares_as_of'])
      end
      if ours && ours['stale']
        out << "btc as-of #{ours['btc_as_of']} is older than 120d -- row is " \
               'flagged STALE on the dashboard'
      end
      out
    end

    def commafy(num)
      i = num.to_i
      s = i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      num.to_f == i ? s : "#{s}#{format('%.2f', num.to_f % 1)[1..]}"
    end
  end
end
