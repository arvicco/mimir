# frozen_string_literal: true
#
# metrics.rb -- pure metrics math for the BTCo analyser, extracted from
# btco.rb so it is unit-testable without network. No IO, no ENV.

require 'time'

module Btco
  STALE_D = 120 # days after btc_as_of before an entry is flagged STALE

  module_function

  # Split convert tranches into [itm_shares, otm_face_usd].
  # Convention (universe.json): face is USD; conv_price is listing ccy.
  # px is the share price in listing ccy; rate is listing-ccy units per USD
  # (1.0 for USD listings). ITM test: px > conv_price, both in listing ccy.
  def convert_split(converts, px, rate)
    itm_sh = 0.0
    otm_fc = 0.0
    (converts || []).each do |t|
      cp = t['conv_price'].to_f / rate # conv price in USD
      if cp > 0 && px > cp * rate
        itm_sh += t['face'].to_f / cp # shares = face_usd / conv_usd
      else
        otm_fc += t['face'].to_f
      end
    end
    [itm_sh, otm_fc]
  end

  # Full per-company metrics row (extracted verbatim from btco.rb's
  # main loop, M0-7). c is a universe.json company entry; px in listing
  # ccy; rate = listing-ccy units per USD; btc_px = BTC spot USD.
  # Semantics documented in btco.rb's header: mcap uses BASIC shares,
  # per-share entitlement metrics use diluted counts.
  def company_row(c, px, rate, btc_px, now)
    px_usd = px / rate
    btc    = c['btc'].to_f
    shs_b  = c['shares_basic'].to_f
    shs_d  = [c['shares_diluted'].to_f, shs_b].max

    itm_sh, otm_fc = convert_split(c['converts'], px, rate)
    senior = otm_fc + c['debt_face'].to_f + c['pref_liq'].to_f
    shs_a  = shs_d + itm_sh

    nav     = btc * btc_px
    mcap    = px_usd * shs_b
    net_nav = nav - senior
    sats_d  = btc * 1e8 / shs_d
    cebe    = [net_nav, 0.0].max / btc_px * 1e8 / shs_a
    mnav    = nav.zero? ? nil : mcap / nav
    netm    = net_nav > 0 ? mcap / net_nav : nil
    ev_btc  = btc.zero? ? nil : (mcap + senior) / btc
    lev     = nav.zero? ? 0.0 : senior / nav
    stale   = c['btc_as_of'] &&
              (now - Time.parse(c['btc_as_of'] + ' 00:00:00 UTC')) / 86_400 > STALE_D

    { t: c['ticker'], px: px, ccy: (c['ccy'] || 'USD').upcase, btc: btc,
      sats_d: sats_d, cebe: cebe, mnav: mnav, netm: netm, ev: ev_btc,
      lev: lev, mcap: mcap, nav: nav, stale: stale, as_of: c['btc_as_of'],
      ph: c['placeholder'] }
  end
end
