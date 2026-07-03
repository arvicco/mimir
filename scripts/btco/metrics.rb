# frozen_string_literal: true
#
# metrics.rb -- pure metrics math for the BTCo analyser, extracted from
# btco.rb so it is unit-testable without network. No IO, no ENV.

module BtcoMetrics
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
end
