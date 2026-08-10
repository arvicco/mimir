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

  # NB: /x free-spacing strips literal spaces -- inter-word gaps MUST be
  # \s+ or the phrase can never match (the C1 bug, SBI review 2026-07-31:
  # 6 of 10 phrases were silently dead and excerpts missed share-count,
  # preferred and notes sections).
  KEYRE = /bitcoin|\bbtc\b|shares?\s+of\s+(?:class\s+[ab]\s+)?common|
           issued\s+and\s+outstanding|convertible|preferred\s+stock|
           liquidation\s+preference|at-the-market|notes\s+due|
           aggregate\s+principal/xi

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
  # converts_add is deduped against the tranches ALREADY in the model:
  # every filing that mentions an existing note re-describes it (often
  # with slightly different label wording), and the append-only apply
  # semantics turned one XXI note into four tranches + a debt_face
  # mirror (2026-07-09 owner session). Identity = same face amount +
  # same due-year, or the same normalized label -- distinct real
  # tranches differ in at least one (e.g. MSTR 2030A/B differ in face).
  def diff_against(cur, ext)
    d = {}
    NUMKEYS.each do |k|
      v = ext[k]
      next if v.nil? || v.to_f == cur[k].to_f

      d[k] = { 'from' => cur[k], 'to' => v }
    end
    d['btc_as_of'] = { 'from' => cur['btc_as_of'], 'to' => ext['btc_as_of'] } if
      ext['btc_as_of'] && ext['btc_as_of'] != cur['btc_as_of']
    fresh = new_tranches(cur['converts'], ext['converts_add'])
    d['converts_add']    = fresh                  if fresh.any?
    d['converts_remove'] = ext['converts_remove'] if ext['converts_remove'].to_a.any?
    d
  end

  # Tranches in adds that are NOT already in the model (see diff_against).
  def new_tranches(existing, adds)
    have = (existing || []).map { |t| tranche_keys(t) }
    adds.to_a.reject do |t|
      k = tranche_keys(t)
      have.any? { |h| (h & k).any? }
    end
  end

  # Identity keys for one tranche: [face+due-year] (when both are
  # stated) and the normalized label.
  def tranche_keys(t)
    keys = []
    label = t['label'].to_s.downcase.gsub(/[^a-z0-9%. ]+/, ' ').squeeze(' ').strip
    keys << "label:#{label}" unless label.empty?
    year = t['label'].to_s[/due[^0-9]*(\d{4})/i, 1]
    face = t['face'].to_f
    keys << "face:#{face.to_i}-due:#{year}" if face.positive? && year
    keys
  end
end
