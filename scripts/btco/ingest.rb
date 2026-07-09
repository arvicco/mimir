#!/usr/bin/env ruby
# frozen_string_literal: true
#
# ingest.rb -- intelligent filing ingestion for the BTCo universe.
#
# Keeps a per-company capital-structure model (universe.json = current
# state) updated from NEW filings via an ingest -> propose -> review ->
# apply pipeline with a full audit ledger. Nothing ever mutates
# universe.json without an explicit --apply.
#
#   ruby ingest.rb                     # discover new EDGAR filings, analyse,
#                                      #   write proposals to capstruct/pending/
#   ruby ingest.rb --ticker MSTR       # limit discovery to one company
#   ruby ingest.rb --limit 3           # max filings analysed per run (def 5)
#   ruby ingest.rb --dry               # discovery only: list, no fetch/AI
#   ruby ingest.rb --dry --json        # discovery only, ONE JSON line:
#                                      #   {"new":n,"filings":[{ticker,form,date,
#                                      #   accession}...]} sorted (ticker,date) --
#                                      #   the daily discovery-alert feed (M7-2)
#   ruby ingest.rb --file f.txt --ticker 3350   # ingest a local document
#                                      #   (e.g. Metaplanet TDnet text/HTML)
#   ruby ingest.rb --tracker 3350      # proposal from StrategyTracker's feed
#                                      #   (btc/as-of/shares only; M7-14)
#   ruby ingest.rb --review            # show pending proposals with diffs
#   ruby ingest.rb --apply <acc|path>  # apply one proposal to universe.json
#   ruby ingest.rb --apply-all-high    # apply every high-confidence proposal
#   ruby ingest.rb --dismiss <acc>     # reject a proposal
#   ruby ingest.rb --dismiss-all       # reject every pending proposal
#                                      #   (--ticker X scopes to one company)
#   ruby ingest.rb --status            # per-company ingestion state
#
# Already-ingested tracking: discovery consults BOTH capstruct/state.json
# (seen accessions + per-ticker discovery floor, set once from btc_as_of)
# AND the applied ledger (capstruct/<TICKER>.jsonl), so state.json is
# disposable -- delete it and nothing already applied re-proposes. Manual
# --file ingestion is deduped by content hash. Failed analyses are NOT
# marked seen and retry on the next run; filings beyond --limit carry over.
#
# Analysis modes:
#   AI (default when ANTHROPIC_API_KEY is set): keyword-windowed filing
#   excerpts + the company's current cap structure go to the Claude API
#   with a strict-JSON extraction schema (model: BTCO_MODEL, default
#   claude-sonnet-4-6). The model reports only what the filing states;
#   unchanged fields come back null.
#   Heuristic (fallback): regex candidates for BTC counts and share
#   counts, always confidence=low.
#
# State layout (all under capstruct/):
#   state.json           accessions already seen per ticker
#   pending/*.json       proposals awaiting review
#   <TICKER>.jsonl       audit ledger of APPLIED changes
#   universe.json.bak-*  automatic backups on apply
#
# The --dry --json line is a FROZEN --json contract (Golden Rule 5):
# additive fields only, with a test/contract/test_ingest_contract.rb
# update in the same commit. Human --dry output is unchanged when --json
# is absent, and --dry never writes state.json (the alert job depends on
# that: no state mutation, no API spend).
#
# Env: EDGAR_UA='name email' (SEC courtesy), ANTHROPIC_API_KEY, BTCO_MODEL.
# Ruby >= 2.5, stdlib only.

require 'json'
require 'time'
require 'fileutils'
require 'digest'
require_relative '../../lib/btc/util'
require_relative '../../lib/btc/http'
require_relative '../../lib/btc/treasury_ref'
require_relative '../../lib/btc/coingecko_ref'
require_relative '../../lib/btc/sec_shares'
require_relative 'ingest_text'

DIR      = File.expand_path(__dir__)
UNIVERSE = File.join(DIR, 'universe.json')
CAPDIR   = File.join(DIR, 'capstruct')
PENDING  = File.join(CAPDIR, 'pending')
STATE    = File.join(CAPDIR, 'state.json')
# 6-K/20-F: foreign private issuers (BLSH is Cayman-domiciled) never file
# 8-K/10-Q -- without these the filter silently blinds discovery to them.
FORMS    = %w[8-K 10-Q 10-K 424B5 6-K 20-F].freeze
NUMKEYS  = Btco::NUMKEYS # canonical list lives in ingest_text.rb

def arg(flag)
  BTC::Util.arg(flag)
end

def http(req_uri, post_body = nil, headers = {})
  if post_body
    BTC::Http.post(req_uri, post_body, headers)
  else
    BTC::Http.get(req_uri, headers, read_timeout: 120)
  end
rescue BTC::Http::StatusError => e
  # historical message shape: status + a body snippet for debugging
  raise "HTTP #{e.code}: #{e.body.to_s[0, 200]}"
end

UA = { 'User-Agent' => ENV['EDGAR_UA'] || 'btco-ingest (set EDGAR_UA=name email)' }.freeze

def load_json(path, default)
  File.exist?(path) ? JSON.parse(File.read(path)) : default
end

FileUtils.mkdir_p(PENDING)
universe = load_json(UNIVERSE, nil) or abort 'universe.json missing'
state    = load_json(STATE, {})

def company(universe, ticker)
  universe['companies'].find { |c| c['ticker'] == ticker }
end

# ---- text extraction: Btco.strip_html / Btco.excerpt (ingest_text.rb) ---------

# ---- analysis: AI -------------------------------------------------------------
SCHEMA_NOTE = <<~SCHEMA
  Respond with ONLY a JSON object (no markdown fences, no prose) with this
  exact schema. Use null for anything the document does not state. Numbers
  are absolute (not deltas), in units of coins / shares / USD face value.
  shares_basic/shares_diluted are shares OUTSTANDING as of the latest
  stated date (e.g. the 10-Q cover page count) -- NEVER weighted-average
  share counts from the income statement; if only weighted averages are
  stated, use null.
  {"no_material_change": bool,
   "btc": number|null, "btc_as_of": "YYYY-MM-DD"|null,
   "shares_basic": number|null, "shares_diluted": number|null,
   "debt_face": number|null, "pref_liq": number|null,
   "converts_add": [{"face": n, "conv_price": n, "label": "str"}],
   "converts_remove": ["label"],
   "atm_note": "str"|null,
   "confidence": "high"|"medium"|"low",
   "summary": "1-2 sentences on what changed"}
SCHEMA

def ai_extract(cur, text, meta)
  key = ENV['ANTHROPIC_API_KEY']
  return nil if key.nil? || key.empty?

  prompt = "You are extracting capital-structure changes for a Bitcoin " \
           "treasury company from a filing.\n\nCurrent model for " \
           "#{cur['ticker']} (#{cur['name']}):\n#{JSON.generate(
             cur.select { |k, _| (NUMKEYS + %w[btc_as_of converts]).include?(k) }
           )}\n\nFiling: #{meta[:form]} dated #{meta[:date]}.\n" \
           "Report ONLY facts stated in the document; if it does not " \
           "change the capital structure or BTC holdings, set " \
           "no_material_change true.\n\n#{SCHEMA_NOTE}\nDocument excerpts:" \
           "\n---\n#{text}\n---"

  body = JSON.generate(
    model: ENV['BTCO_MODEL'] || 'claude-sonnet-4-6',
    max_tokens: 1500,
    messages: [{ role: 'user', content: prompt }]
  )
  res = http('https://api.anthropic.com/v1/messages', body,
             'x-api-key' => key, 'anthropic-version' => '2023-06-01',
             'content-type' => 'application/json')
  txt = JSON.parse(res)['content'].to_a
              .select { |b| b['type'] == 'text' }
              .map { |b| b['text'] }.join
  JSON.parse(txt.gsub(/\A[^{]*/m, '').gsub(/[^}]*\z/m, ''))
rescue StandardError => e
  warn "  ai extraction failed: #{e.message}"
  nil
end

# ---- analysis: heuristic fallback ---------------------------------------------
def heuristic_extract(text)
  btc = text.scan(/(?:hold|held|holds|aggregate|total)[^.]{0,80}?([\d,]{4,})\s*bitcoin/i)
            .map { |m| m[0].delete(',').to_i }.max
  shs = text.scan(/([\d,]{7,})\s*shares? of (?:class a )?common stock[^.]{0,60}outstanding/i)
            .map { |m| m[0].delete(',').to_i }.max
  { 'no_material_change' => btc.nil? && shs.nil?,
    'btc' => btc, 'shares_basic' => shs,
    'confidence' => 'low',
    'summary' => 'heuristic regex candidates only -- verify against document' }
end

# ---- proposal machinery (diff: Btco.diff_against, ingest_text.rb) --------------
def write_proposal(ticker, meta, ext, diff, mode)
  path = File.join(PENDING, "#{ticker}_#{meta[:acc].to_s.delete('-')}.json")
  File.write(path, JSON.pretty_generate(
                     ticker: ticker, accession: meta[:acc], form: meta[:form],
                     filing_date: meta[:date], url: meta[:url], mode: mode,
                     analysed_at: Time.now.utc.iso8601,
                     extraction: ext, diff: diff
                   ))
  path
end

# Strip a btc/btc_as_of pair that is OLDER than what the model already
# holds (owner ruling, 2026-07-07 session: a stale count is not material
# for us and must not even reach review -- catch-up runs walk newest-first
# so older filings' counts are superseded before they are analysed).
# Returns the possibly-reduced diff.
def drop_stale_btc(cur, ext, meta, diff)
  return diff unless diff.key?('btc') || diff.key?('btc_as_of')

  prop_asof = ext['btc_as_of'] || meta[:date]
  return diff unless cur['btc_as_of'] && prop_asof &&
                     prop_asof.to_s <= cur['btc_as_of'].to_s

  diff.reject { |k, _| %w[btc btc_as_of].include?(k) }
end

def analyse_one(cur, raw, meta)
  text = Btco.excerpt(Btco.strip_html(raw))
  ext  = ai_extract(cur, text, meta)
  mode = ext ? 'ai' : 'heuristic'
  ext ||= heuristic_extract(text)
  diff = Btco.diff_against(cur, ext)
  stripped = drop_stale_btc(cur, ext, meta, diff)
  if stripped.size < diff.size && stripped.empty?
    # caller marks the accession seen on any non-raise return, so this
    # filing will not re-analyse next run (same path as no-material-change)
    puts format('  %-6s %s %s: btc older than model (%s) -- no proposal', cur['ticker'],
                meta[:form], meta[:date], mode)
    return nil
  end
  diff = stripped
  if ext['no_material_change'] && diff.empty?
    puts format('  %-6s %s %s: no material change (%s)', cur['ticker'],
                meta[:form], meta[:date], mode)
    return nil
  end
  path = write_proposal(cur['ticker'], meta, ext, diff, mode)
  puts format('  %-6s %s %s -> proposal %s [%s/%s]', cur['ticker'], meta[:form],
              meta[:date], File.basename(path), mode, ext['confidence'])
  path
end

# ---- apply / review / dismiss ---------------------------------------------------
def pending_files
  Dir.glob(File.join(PENDING, '*.json')).sort
end

def ledger_accessions(ticker)
  path = File.join(CAPDIR, "#{ticker}.jsonl")
  return [] unless File.exist?(path)

  File.readlines(path).map { |l|
    begin
      JSON.parse(l)['accession']
    rescue StandardError
      nil
    end
  }.compact
end

if ARGV.include?('--status')
  universe['companies'].each do |c|
    st   = state[c['ticker']] || {}
    led  = ledger_accessions(c['ticker'])
    pend = pending_files.count { |f| File.basename(f).start_with?("#{c['ticker']}_") }
    puts format('%-6s cik %-10s floor %-10s seen %-4d pending %-3d applied %-3d%s',
                c['ticker'], c['cik'] || '--',
                st['floor'] || c['btc_as_of'] || '--',
                (st['seen'] || []).size, pend, led.size,
                led.empty? ? '' : "  last #{led.last}")
  end
  exit
end

# M7-9/M7-11/M7-12: independent third-party sanity lines for --review.
# Cross-checks a proposal's figures against sources mimir does not
# control, so the owner can catch an extraction error at review time.
# ADVISORY ONLY -- an unknown company, a dead/absent reference, or ANY
# error prints NOTHING and never blocks review. Returns an array of
# lines (possibly empty).
#
# BTC refs (M7-9 bitcointreasuries + M7-11 coingecko): two aggregators
# that disagree with each other are themselves a signal worth seeing.
# Shares ref (M7-12): SEC XBRL dei cover-page count with its as-of date
# -- the structured version of the exact number the schema demands;
# absent for multi-class filers (see lib/btc/sec_shares.rb), so no line
# prints for them.
def ref_lines(pr, cur)
  lines = []
  prop = pr.dig('diff', 'btc', 'to') || pr.dig('extraction', 'btc')
  if prop.is_a?(Numeric)
    [BTC::TreasuryRef, BTC::CoingeckoRef].each do |mod|
      ref = begin
        mod.btc_for(pr['ticker'])
      rescue StandardError
        nil
      end
      rb = ref ? ref['btc'].to_f : 0.0
      next unless rb.positive?

      lines << format('  ref:     %s BTC (%s, as-of %s) -- %s',
                      commafy(ref['btc']), ref['source'],
                      ref['as_of'].to_s[0, 10], verdict_vs(prop, rb))
    end
  end

  sh_prop = pr.dig('diff', 'shares_basic', 'to')
  if sh_prop.is_a?(Numeric) && cur && cur['cik'].to_i.positive?
    ref = BTC::SecShares.outstanding_for(cur['cik'], headers: UA)
    if ref
      lines << format('  shares:  %s (%s, as-of %s, %s) -- %s',
                      commafy(ref['shares']), ref['source'], ref['as_of'],
                      ref['form'], verdict_vs(sh_prop, ref['shares'].to_f))
    end
  end
  lines
rescue StandardError
  []
end

# proposal-vs-reference verdict string shared by every ref line.
def verdict_vs(prop, ref)
  if ((prop - ref).abs / ref) > 0.02
    format("⚠ proposal diverges %.1f%%", (prop - ref).abs / ref * 100)
  else
    'proposal matches'
  end
end

# 843775 -> "843,775" (thousands separators for the human ref line).
def commafy(num)
  num.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
end

def show_review(universe)
  files = pending_files
  puts(files.empty? ? 'no pending proposals' : "#{files.size} pending:")
  files.each do |f|
    pr = JSON.parse(File.read(f))
    puts format("\n%s  %s %s %s  [%s/%s]", File.basename(f), pr['ticker'],
                pr['form'], pr['filing_date'], pr['mode'],
                pr['extraction']['confidence'])
    puts "  #{pr['extraction']['summary']}"
    pr['diff'].each { |k, v| puts format('  %-16s %s', k, v.inspect) }
    ref_lines(pr, company(universe, pr['ticker'])).each { |rl| puts rl }
    puts "  #{pr['url']}" if pr['url']
    # exact, paste-ready commands -- never make the reviewer assemble
    # them from a placeholder (owner feedback, 2026-07-07 session)
    puts format('  apply:   ruby scripts/btco/ingest.rb --apply %s', pr['accession'])
    puts format('  dismiss: ruby scripts/btco/ingest.rb --dismiss %s', pr['accession'])
  end
end

def apply_proposal(universe, file)
  pr  = JSON.parse(File.read(file))
  cur = company(universe, pr['ticker']) or abort "unknown ticker #{pr['ticker']}"

  # uniquify on same-second collision: a multi-apply batch must keep
  # EVERY backup, not just the last one written that second (M7-1 B)
  stamp = Time.now.utc.strftime('%Y%m%d%H%M%S')
  bak = "#{UNIVERSE}.bak-#{stamp}"
  n = 1
  bak = "#{UNIVERSE}.bak-#{stamp}-#{n += 1}" while File.exist?(bak)
  FileUtils.cp(UNIVERSE, bak)

  # As-of guard (owner catch, 2026-07-07 session): an older filing's BTC
  # count must never regress a newer one already in the model. The btc /
  # btc_as_of pair is skipped (with a note) when the proposal's as-of
  # (extracted btc_as_of, else filing_date) is not newer than the model's.
  # Other fields carry no per-field date until the M7-10 provenance work,
  # so review order still matters for them -- apply newest last.
  prop_asof = pr.dig('extraction', 'btc_as_of') || pr['filing_date']
  keep_btc  = cur['btc_as_of'] && prop_asof && prop_asof.to_s <= cur['btc_as_of'].to_s &&
              pr['diff'].key?('btc')
  puts format('  btc/btc_as_of SKIPPED: model already newer (%s > %s) -- kept %s BTC',
              cur['btc_as_of'], prop_asof, cur['btc']) if keep_btc

  pr['diff'].each do |k, v|
    next if keep_btc && %w[btc btc_as_of].include?(k)

    case k
    when 'converts_add'
      # duplicate-instrument guard (2026-07-09 XXI session): a proposal
      # written before the model gained the tranche must not re-add it
      fresh = Btco.new_tranches(cur['converts'], v)
      if (skipped = v.size - fresh.size).positive?
        puts format('  converts_add: %d duplicate tranche(s) skipped (already in model)',
                    skipped)
      end
      cur['converts'] = cur['converts'].to_a + fresh
    when 'converts_remove'
      cur['converts'] = cur['converts'].to_a.reject { |t| v.include?(t['label']) }
    else
      cur[k] = v['to']
    end
  end
  cur['placeholder'] = false
  File.write(UNIVERSE, JSON.pretty_generate(universe))

  File.open(File.join(CAPDIR, "#{pr['ticker']}.jsonl"), 'a') do |f|
    f.puts JSON.generate(ts: Time.now.utc.iso8601, accession: pr['accession'],
                         form: pr['form'], filing_date: pr['filing_date'],
                         url: pr['url'], mode: pr['mode'],
                         confidence: pr['extraction']['confidence'],
                         summary: pr['extraction']['summary'],
                         diff: pr['diff'])
  end
  FileUtils.rm(file)
  puts "applied #{File.basename(file)} (backup #{File.basename(bak)})"
end

if ARGV.include?('--review')
  show_review(universe)
  exit
end
if (t = arg('--dismiss'))
  f = pending_files.find { |x| x.include?(t.delete('-')) } or abort 'no such proposal'
  FileUtils.rm(f)
  puts "dismissed #{File.basename(f)}"
  exit
end
if ARGV.include?('--dismiss-all')
  files = pending_files
  if (tk = arg('--ticker'))
    files = files.select { |f| File.basename(f).start_with?("#{tk}_") }
  end
  abort 'no pending proposals' if files.empty?
  files.each do |f|
    FileUtils.rm(f)
    puts "dismissed #{File.basename(f)}"
  end
  exit
end
if (t = arg('--apply'))
  f = File.exist?(t) ? t : pending_files.find { |x| x.include?(t.delete('-')) }
  abort 'no such proposal' unless f
  apply_proposal(universe, f)
  exit
end
if ARGV.include?('--apply-all-high')
  pending_files.each do |f|
    pr = JSON.parse(File.read(f))
    next unless pr['extraction']['confidence'] == 'high' && pr['mode'] == 'ai'

    apply_proposal(universe, f)
    universe = load_json(UNIVERSE, nil) # reload after each write
  end
  exit
end

# ---- local-file ingestion (non-EDGAR sources, e.g. TDnet) ----------------------
if (path = arg('--file'))
  tk  = arg('--ticker') or abort '--file requires --ticker'
  cur = company(universe, tk) or abort "unknown ticker #{tk}"
  raw = File.read(path)
  acc = "manual-#{Digest::SHA1.hexdigest(raw)[0, 12]}"
  # pending filenames strip dashes (write_proposal), so match the
  # stripped form -- the dashed accession never matched and re-ingesting
  # a doc with a pending proposal silently re-wrote it (M7-1 finding A)
  if ledger_accessions(tk).include?(acc) || pending_files.any? { |f| f.include?(acc.delete('-')) }
    abort "already ingested (#{acc}) -- see --status / --review"
  end

  meta = { acc: acc, form: 'MANUAL',
           date: Time.now.utc.strftime('%Y-%m-%d'),
           url: File.expand_path(path) }
  analyse_one(cur, raw, meta)
  exit
end

# ---- tracker ingestion (M7-14: StrategyTracker feed) ---------------------------
# For companies the EDGAR path cannot serve (3350/Metaplanet files via
# TDnet), StrategyTracker's open feed -- the engine behind Metaplanet's
# OFFICIAL analytics page -- carries dated treasury rows with links to
# the underlying disclosure PDFs (docs/BTCO-DATA-SOURCES.md). This mode
# turns the LATEST row into a normal reviewed proposal: same pending/
# review/apply pipeline, same ledger, nothing bypasses --apply. Only
# btc/btc_as_of/shares_basic are proposed: the feed's diluted counts are
# tracker-COMPUTED (not filing cover numbers) and its debt figure is
# currency-ambiguous, so both stay out per the schema's honesty rule.
# Interactive owner command -> fails hard with a message, no fail-soft.
ST_LATEST = 'https://data.strategytracker.com/latest.json'
if (tk = arg('--tracker'))
  cur = company(universe, tk) or abort "unknown ticker #{tk}"
  ptr  = JSON.parse(http(ST_LATEST))
  full = ptr.dig('files', 'full') or abort 'tracker pointer has no full file'
  # the full feed nests deeply enough to trip the default parser cap
  data = JSON.parse(http("https://data.strategytracker.com/#{full}"),
                    max_nesting: false)
  key = ["#{tk}.T", "#{tk}.US", tk].find { |k| data['companies']&.key?(k) } or
    abort "tracker does not list #{tk} (tried #{tk}.T/#{tk}.US/#{tk})"
  row = data.dig('companies', key, 'processedMetrics', 'treasury_table')&.last or
    abort "tracker has no treasury_table for #{key}"

  acc = "tracker-#{Digest::SHA1.hexdigest(JSON.generate(row))[0, 12]}"
  if ledger_accessions(tk).include?(acc) || pending_files.any? { |f| f.include?(acc.delete('-')) }
    abort "already ingested (#{acc}) -- see --status / --review"
  end

  shares = row['Total Outstanding Shares']
  ext = { 'no_material_change' => false,
          'btc' => row['BTC Balance'], 'btc_as_of' => row['Date'],
          'shares_basic' => (shares.to_i if shares), 'shares_diluted' => nil,
          'debt_face' => nil, 'pref_liq' => nil,
          'converts_add' => [], 'converts_remove' => [], 'atm_note' => nil,
          'confidence' => 'medium',
          'summary' => format('StrategyTracker %s treasury row %s: %s BTC, ' \
                              '%s shares outstanding. Diluted/debt omitted ' \
                              '(tracker-computed / currency-ambiguous) -- ' \
                              'confirm against the linked disclosure.',
                              key, row['Date'], row['BTC Balance'], shares || 'n/a') }
  meta = { acc: acc, form: 'TRACKER', date: row['Date'],
           url: row['Purchase Statement URL'] }
  diff = drop_stale_btc(cur, ext, meta, Btco.diff_against(cur, ext))
  abort "tracker row adds nothing newer than the model (btc as-of #{cur['btc_as_of']})" if diff.empty?

  ppath = write_proposal(tk, meta, ext, diff, 'tracker')
  puts format('%-6s TRACKER %s -> proposal %s [tracker/medium]',
              tk, row['Date'], File.basename(ppath))
  puts '  review with: ruby scripts/btco/ingest.rb --review'
  exit
end

# ---- EDGAR discovery + ingestion -----------------------------------------------
limit  = (arg('--limit') || 5).to_i
only   = arg('--ticker')
budget = limit
dry    = ARGV.include?('--dry')
# --dry --json: emit ONE machine-readable discovery line (the M7-2 alert
# feed) and suppress every human line. State is never written under --dry.
dry_json = dry && ARGV.include?('--json')
found    = [] # {ticker, form, date, accession} rows for the --dry --json line

universe['companies'].each do |c|
  next if only && c['ticker'] != only
  next if c['cik'].nil? || c['cik'].to_s.empty?
  break if budget <= 0

  st = (state[c['ticker']] ||= { 'seen' => [] })
  st['floor'] ||= (c['btc_as_of'] || '2025-01-01')
  known = st['seen'] | ledger_accessions(c['ticker'])
  begin
    sub = JSON.parse(http(format('https://data.sec.gov/submissions/CIK%010d.json',
                                 c['cik'].to_i), nil, UA))
  rescue StandardError => e
    warn "#{c['ticker']}: EDGAR failed (#{e.message})"
    next
  end
  r = sub['filings']['recent']
  idx = []
  r['form'].each_index do |i|
    next unless FORMS.include?(r['form'][i])
    next unless r['filingDate'][i] > st['floor']
    next if known.include?(r['accessionNumber'][i])

    idx << i
  end
  next if idx.empty?

  puts format('%-6s %d new filing(s)', c['ticker'], idx.size) unless dry_json
  # NEWEST first (EDGAR's recent arrays are reverse-chronological, so plain
  # order): the extraction schema reports ABSOLUTE numbers, so the latest
  # filing supersedes everything older -- oldest-first + --limit made a
  # year-long catch-up apply stale data (owner session, 2026-07-07).
  idx.each do |i|
    break if budget <= 0

    acc  = r['accessionNumber'][i]
    meta = { acc: acc, form: r['form'][i], date: r['filingDate'][i],
             url: format('https://www.sec.gov/Archives/edgar/data/%d/%s/%s',
                         c['cik'].to_i, acc.delete('-'), r['primaryDocument'][i]) }
    if dry
      found << { 'ticker' => c['ticker'], 'form' => meta[:form],
                 'date' => meta[:date], 'accession' => acc }
      puts format('  %-6s %s %s %s', c['ticker'], meta[:form], meta[:date], meta[:url]) unless dry_json
      next
    end
    begin
      raw = http(meta[:url], nil, UA)
      analyse_one(c, raw, meta)
      st['seen'] << acc
      st['seen'].shift while st['seen'].size > 500
      budget -= 1
      sleep 0.3
    rescue StandardError => e
      warn "  #{c['ticker']} #{acc}: #{e.message}"
    end
  end
end

File.write(STATE, JSON.pretty_generate(state)) unless dry
if dry_json
  found.sort_by! { |f| [f['ticker'], f['date']] }
  puts JSON.generate('new' => found.size, 'filings' => found)
else
  puts "\n#{pending_files.size} proposal(s) pending -- review with: ruby ingest.rb --review"
end
