# frozen_string_literal: true
#
# treasury_ref.rb -- independent third-party BTC-holdings reference for
# ingest proposals (M7-9). At --review time each proposal is cross-checked
# against an OUTSIDE aggregator's BTC count for the same company, so the
# owner can catch an AI-extraction error against a source mimir does not
# control (outcome-first verification applied to ingest). Advisory only:
# it never blocks review and never mutates -- an unknown company or a dead
# aggregator degrades to silence, never to an exception the caller sees.
#
# Source decision (M7-9 probe, 2026-07-07): Coinglass v4 (key provisioned)
# was probed FIRST per the packet ordering. Its API index
# (docs.coinglass.com/llms.txt) exposes only ETF and Grayscale holdings --
# there is NO per-company corporate-treasury endpoint on the provisioned
# tier -- so we fall back to bitcointreasuries.net. Its home page
# server-renders a GLOBAL ranked table (per-entity ticker symbol +
# btc_balance) inside its Next.js RSC stream; we fetch that page ONCE per
# run, parse the table defensively, and look up per ticker.
#
# Caching: the parsed table is stored through BTC::SourceCache (name
# 'treasury_ref') so a momentary aggregator outage still serves the
# last-good table (marked stale) within the shared 48h cap. Past the cap,
# or with no cache at all, btc_for returns nil -- advisory data fails to
# silence, never raising into review.
#
# Matching: by exact ticker symbol first, then a small alias map for the
# companies the aggregator lists under a name/symbol that differs from the
# universe ticker (e.g. universe 3350 -> "Metaplanet", whose aggregator
# symbol is MPJPY). Unknown company -> nil, never a guess.
#
# stdlib only; no ENV, no secrets. Network only via BTC::Http (the seam),
# so tests inject a fake transport and run fully offline.

require 'time'
require_relative 'http'
require_relative 'source_cache'

module BTC
  module TreasuryRef
    URL    = 'https://bitcointreasuries.net/'
    SOURCE = 'bitcointreasuries.net'
    CACHE  = 'treasury_ref'
    # Courtesy UA (no ENV/secret): identifies mimir's research fetch.
    UA     = 'mimir-btco treasury-ref (research; contact via repo)'

    # Universe ticker -> the aggregator's ENTITY NAME, for companies the
    # aggregator does NOT list under the universe ticker. Matched by
    # normalized-name prefix. Symbol matches need no alias; these cover the
    # known name/symbol-mismatch cases (only 3350 truly needs it today --
    # aggregator symbol MPJPY -- the rest match by symbol but are pinned
    # here so a future symbol change still resolves).
    ALIAS = {
      'MSTR' => 'Strategy', '3350' => 'Metaplanet', 'XXI' => 'Twenty One',
      'ASST' => 'Strive', 'BLSH' => 'Bullish', 'ABTC' => 'American Bitcoin',
      'DJT' => 'Trump Media', 'NAKA' => 'Nakamoto'
    }.freeze

    # Entity object shape in the RSC stream:
    #   ...is_pure_play:BOOL,name:"NAME",slug:"SLUG"...
    #   ticker:{symbol:"SYM"...}...btc_balance:NUMBER...
    ENTITY_RE = /is_pure_play:(?:true|false),name:"([^"]{1,120})",slug:"[^"]{0,120}"/
    SYM_RE    = /ticker:\{symbol:"([^"]{1,15})"/
    BAL_RE    = /btc_balance:([0-9]+(?:\.[0-9]+)?)/
    TAIL_CAP  = 2000 # bound the last entity's window (no next-entity anchor)

    module_function

    # Public entry point. ticker_or_name -> { 'btc'=>Integer, 'source'=>str,
    # 'as_of'=>iso8601 } for a matched company, else nil (unknown company,
    # or source down with no usable cache). Never raises for a data miss.
    def btc_for(query, now: Time.now.utc)
      q = query.to_s.strip
      return nil if q.empty?

      fetched = fetch_table(now: now)
      return nil unless fetched

      row = lookup(fetched['table'], q)
      row ? { 'btc' => row['btc'], 'source' => SOURCE, 'as_of' => fetched['as_of'] } : nil
    end

    # Resolve a query to one row: exact ticker-symbol match first, then the
    # alias map (universe ticker -> aggregator name, matched by normalized
    # name prefix). No fuzzy fallback -> unknown returns nil.
    def lookup(table, query)
      up = query.upcase
      sym_hit = table.find { |r| r['ticker'].to_s.upcase == up }
      return sym_hit if sym_hit

      key = norm(ALIAS[up] || query)
      return nil if key.empty?

      table.find { |r| norm(r['name']).start_with?(key) }
    end

    # Fold to a comparable form: lowercase alphanumerics, single-spaced.
    def norm(str)
      str.to_s.downcase.gsub(/[^a-z0-9]+/, ' ').strip
    end

    # Read-through table fetch mirroring SourceCache.fetch_json but for the
    # HTML page (fetch_json JSON-parses; this parses the RSC table): a live
    # fetch parses + caches the table; ANY failure serves the last-good
    # cached table (stale) within the cap, else nil. Returns
    # { 'table'=>[rows], 'as_of'=>iso8601, 'stale'=>bool } or nil.
    def fetch_table(now: Time.now.utc, max_stale_s: BTC::SourceCache::MAX_STALE_S)
      # Net::HTTP hands back an ASCII-8BIT (BINARY) body; the page is UTF-8
      # (company names carry accents/emoji). Tag + scrub it before parse so
      # the cached table serializes cleanly (a BINARY string with UTF-8
      # bytes warns today and raises under json 3.0).
      html  = BTC::Http.get(URL, { 'User-Agent' => UA }, read_timeout: 20)
                       .to_s.dup.force_encoding(Encoding::UTF_8).scrub
      table = parse_table(html)
      raise 'empty treasury table' if table.empty?

      BTC::SourceCache.write(CACHE, URL, table, now)
      { 'table' => table, 'as_of' => now.iso8601, 'stale' => false }
    rescue StandardError
      cached = BTC::SourceCache.read(CACHE)
      return nil unless cached && (now - cached[:fetched_at]) <= max_stale_s

      { 'table' => cached[:data], 'as_of' => cached[:fetched_at].iso8601, 'stale' => true }
    end

    # Defensive parse of the bitcointreasuries.net RSC stream into
    # [{ 'ticker'=>sym|nil, 'name'=>str, 'btc'=>Integer }, ...]. Anchor on
    # each entity name, then read the FIRST ticker symbol and btc_balance in
    # the window up to the NEXT entity (so an entity with no reported figure
    # never borrows its neighbour's). Rows without a btc_balance drop out.
    # Tolerant of missing fields and of markup changes elsewhere on the page
    # -- a shape change yields fewer rows, never an exception.
    def parse_table(html)
      s = html.to_s
      ents = []
      pos = 0
      while (m = ENTITY_RE.match(s, pos))
        ents << { name: m[1], beg: m.begin(0), fin: m.end(0) }
        pos = m.end(0)
      end

      rows = []
      ents.each_with_index do |ent, i|
        stop = i + 1 < ents.size ? ents[i + 1][:beg] : [ent[:fin] + TAIL_CAP, s.length].min
        win  = s[ent[:fin]...stop]
        bal  = win[BAL_RE, 1]
        next unless bal

        rows << { 'ticker' => win[SYM_RE, 1], 'name' => ent[:name], 'btc' => bal.to_f.round }
      end
      rows
    end
  end
end
