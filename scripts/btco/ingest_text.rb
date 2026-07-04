# frozen_string_literal: true
#
# ingest_text.rb -- pure text-processing and proposal-diff functions for
# the filing-ingestion pipeline, extracted verbatim from ingest.rb so
# they are unit-testable without network or API keys (M0-8). No IO, no
# ENV. NOTE: KEYRE and the excerpt windowing parameters shape what the
# extraction model sees -- changes here are contract changes
# (Golden Rule 5).

module Btco
  NUMKEYS = %w[btc shares_basic shares_diluted debt_face pref_liq].freeze

  KEYRE = /bitcoin|\bbtc\b|shares? of (?:class [ab] )?common|issued and outstanding|
           convertible|preferred stock|liquidation preference|at-the-market|
           notes due|aggregate principal/xi

  module_function

  def strip_html(html)
    html.gsub(%r{<(script|style)[^>]*>.*?</\1>}mi, ' ')
        .gsub(/<[^>]+>/, ' ')
        .gsub(/&nbsp;|&#160;/, ' ').gsub(/&amp;/, '&')
        .gsub(/[ \t]+/, ' ').gsub(/\n{2,}/, "\n")
  end

  # keyword-window excerpting: +-1500 chars around every keyword hit,
  # merged, capped -- keeps 10-Q sized documents inside a sane prompt.
  def excerpt(text, cap = 40_000)
    spans = []
    text.scan(KEYRE) do
      i = Regexp.last_match.begin(0)
      spans << [[i - 1500, 0].max, [i + 1500, text.size].min]
    end
    return text[0, cap] if spans.empty?

    spans.sort!
    merged = [spans.first.dup]
    spans.drop(1).each do |s, e|
      if s <= merged.last[1] + 200
        merged.last[1] = [merged.last[1], e].max
      else
        merged << [s, e]
      end
    end
    out = merged.map { |s, e| text[s...e] }.join("\n[...]\n")
    out[0, cap]
  end

  # Field-level diff of an extraction against the current company model.
  def diff_against(cur, ext)
    d = {}
    NUMKEYS.each do |k|
      v = ext[k]
      next if v.nil? || v.to_f == cur[k].to_f

      d[k] = { 'from' => cur[k], 'to' => v }
    end
    d['btc_as_of'] = { 'from' => cur['btc_as_of'], 'to' => ext['btc_as_of'] } if
      ext['btc_as_of'] && ext['btc_as_of'] != cur['btc_as_of']
    d['converts_add']    = ext['converts_add']    if ext['converts_add'].to_a.any?
    d['converts_remove'] = ext['converts_remove'] if ext['converts_remove'].to_a.any?
    d
  end
end
