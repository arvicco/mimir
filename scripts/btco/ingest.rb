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
#   ruby ingest.rb --file f.txt --ticker 3350   # ingest a local document
#                                      #   (e.g. Metaplanet TDnet text/HTML)
#   ruby ingest.rb --review            # show pending proposals with diffs
#   ruby ingest.rb --apply <acc|path>  # apply one proposal to universe.json
#   ruby ingest.rb --apply-all-high    # apply every high-confidence proposal
#   ruby ingest.rb --dismiss <acc>     # reject a proposal
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
# Env: EDGAR_UA='name email' (SEC courtesy), ANTHROPIC_API_KEY, BTCO_MODEL.
# Ruby >= 2.5, stdlib only.

require 'net/http'
require 'json'
require 'time'
require 'fileutils'
require 'digest'
require_relative '../../lib/btc/util'

DIR      = File.expand_path(__dir__)
UNIVERSE = File.join(DIR, 'universe.json')
CAPDIR   = File.join(DIR, 'capstruct')
PENDING  = File.join(CAPDIR, 'pending')
STATE    = File.join(CAPDIR, 'state.json')
FORMS    = %w[8-K 10-Q 10-K 424B5].freeze
NUMKEYS  = %w[btc shares_basic shares_diluted debt_face pref_liq].freeze

def arg(flag)
  BTC::Util.arg(flag)
end

def http(req_uri, post_body = nil, headers = {})
  uri = URI(req_uri)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                  open_timeout: 5, read_timeout: 120) do |h|
    req = if post_body
            r = Net::HTTP::Post.new(uri.request_uri, headers)
            r.body = post_body
            r
          else
            Net::HTTP::Get.new(uri.request_uri, headers)
          end
    res = h.request(req)
    raise "HTTP #{res.code}: #{res.body.to_s[0, 200]}" unless res.code.to_i == 200

    res.body
  end
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

# ---- text extraction ----------------------------------------------------------
KEYRE = /bitcoin|\bbtc\b|shares? of (?:class [ab] )?common|issued and outstanding|
         convertible|preferred stock|liquidation preference|at-the-market|
         notes due|aggregate principal/xi

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

# ---- analysis: AI -------------------------------------------------------------
SCHEMA_NOTE = <<~SCHEMA
  Respond with ONLY a JSON object (no markdown fences, no prose) with this
  exact schema. Use null for anything the document does not state. Numbers
  are absolute (not deltas), in units of coins / shares / USD face value.
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

# ---- proposal machinery --------------------------------------------------------
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

def analyse_one(cur, raw, meta)
  text = excerpt(strip_html(raw))
  ext  = ai_extract(cur, text, meta)
  mode = ext ? 'ai' : 'heuristic'
  ext ||= heuristic_extract(text)
  diff = diff_against(cur, ext)
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

def show_review
  files = pending_files
  puts(files.empty? ? 'no pending proposals' : "#{files.size} pending:")
  files.each do |f|
    pr = JSON.parse(File.read(f))
    puts format("\n%s  %s %s %s  [%s/%s]", File.basename(f), pr['ticker'],
                pr['form'], pr['filing_date'], pr['mode'],
                pr['extraction']['confidence'])
    puts "  #{pr['extraction']['summary']}"
    pr['diff'].each { |k, v| puts format('  %-16s %s', k, v.inspect) }
    puts "  #{pr['url']}" if pr['url']
  end
end

def apply_proposal(universe, file)
  pr  = JSON.parse(File.read(file))
  cur = company(universe, pr['ticker']) or abort "unknown ticker #{pr['ticker']}"

  bak = "#{UNIVERSE}.bak-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}"
  FileUtils.cp(UNIVERSE, bak)

  pr['diff'].each do |k, v|
    case k
    when 'converts_add'
      cur['converts'] = cur['converts'].to_a + v
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
  show_review
  exit
end
if (t = arg('--dismiss'))
  f = pending_files.find { |x| x.include?(t.delete('-')) } or abort 'no such proposal'
  FileUtils.rm(f)
  puts "dismissed #{File.basename(f)}"
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
  if ledger_accessions(tk).include?(acc) || pending_files.any? { |f| f.include?(acc) }
    abort "already ingested (#{acc}) -- see --status / --review"
  end

  meta = { acc: acc, form: 'MANUAL',
           date: Time.now.utc.strftime('%Y-%m-%d'),
           url: File.expand_path(path) }
  analyse_one(cur, raw, meta)
  exit
end

# ---- EDGAR discovery + ingestion -----------------------------------------------
limit  = (arg('--limit') || 5).to_i
only   = arg('--ticker')
budget = limit

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

  puts format('%-6s %d new filing(s)', c['ticker'], idx.size)
  idx.reverse.each do |i| # oldest first
    break if budget <= 0

    acc  = r['accessionNumber'][i]
    meta = { acc: acc, form: r['form'][i], date: r['filingDate'][i],
             url: format('https://www.sec.gov/Archives/edgar/data/%d/%s/%s',
                         c['cik'].to_i, acc.delete('-'), r['primaryDocument'][i]) }
    if ARGV.include?('--dry')
      puts format('  %-6s %s %s %s', c['ticker'], meta[:form], meta[:date], meta[:url])
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

File.write(STATE, JSON.pretty_generate(state)) unless ARGV.include?('--dry')
puts "\n#{pending_files.size} proposal(s) pending -- review with: ruby ingest.rb --review"
