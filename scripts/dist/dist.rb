#!/usr/bin/env ruby
# frozen_string_literal: true
#
# dist.rb -- the market-implied BTC price distribution, published and
# scored (M13-5/M13-6, skuld S-A/S-B; plan-13, №R-12).
#
#   ruby scripts/dist/dist.rb                    # human summary
#   ruby scripts/dist/dist.rb --json             # one machine line (frozen)
#   ruby scripts/dist/dist.rb --tmux             # one line -> /tmp/dist.status
#   ruby scripts/dist/dist.rb --as-of 2026-09-01 # replay from that day's snapshot
#
# WHAT IT PUBLISHES (per UTC day, one publication-ledger row)
#   The option market's own implied density (Deribit book -> SVI slices
#   -> Breeden-Litzenberger, lib/btc/density.rb) at the 7/30/90-day
#   horizons, alongside two benchmark densities every component must
#   beat to matter:
#     rn      the smile-implied (risk-neutral) density
#     ln_atm  lognormal at the ATM implied vol (smile thrown away)
#     rw      random walk: lognormal at trailing realized vol, centered
#             on spot (the market-free null)
#   Each density is stored as the 21-level quantile grid plus digitals
#   P(S_T > K) on a spot-relative strike ladder -- exactly what
#   lib/btc/dist_scoring.rb scores when the horizon matures.
#
# CADENCE (owner ruling 2026-09-04): a SLOW module. One fresh compute
#   per UTC day; a same-day re-run re-emits the day's payload without
#   refetching (intra-day constancy is by design). Rides the publish
#   pipeline like any producer.
#
# LEDGER + SNAPSHOTS ($BTC_DATA_DIR/dist/, else scripts/dist/data/)
#   ledger.jsonl        append-only, one row per day: quantiles,
#                       digitals, provenance (snapshot sha256, input
#                       hash, known_at, schema version). Never rewritten.
#   scores.jsonl        resolution ledger (M13-6): each live run finds
#                       matured, not-yet-scored (date, horizon) pairs
#                       -- publication date + d days has a completed
#                       close in the price cache -- and appends one
#                       record scoring EVERY component (log/CRPS/PIT +
#                       mean Brier over the row's own ladder) against
#                       that close. Idempotent by construction: the
#                       (date, d) key set is re-read each run. The
#                       --json payload carries the additive 'scoring'
#                       summary: per horizon, mean CRPS per component
#                       and the log-score skill differential vs the rw
#                       benchmark with a Newey-West SE (lag d-1 -- the
#                       overlap of daily-published d-day horizons).
#                       Replays never score and report scoring: null.
#   snapshots/D.json.gz the RAW Deribit board that day (books cannot be
#                       backfilled -- the raw archive is the asset).
#   latest.json         the day's full payload (same-day re-emit cache).
#
# REPLAY (--as-of D): rebuilds D's densities from D's stored snapshot
#   and the price history strictly before D. Reads only, writes
#   nothing, emits the same payload shape with as_of set.
#
# DATA SOURCES
#   Deribit book_summary (kind=option) -- UNCACHED on purpose: a stale
#   board silently stamped fresh is worse than an honest gap, so a dead
#   Deribit is an unavailable day (fail-soft exit 0; the publish TTL
#   carries yesterday's key). Spot via the shared last-good
#   deribit_index cache. Daily closes read from the LPPL price cache
#   (lppl/prices.csv, maintained by the lppl agent) -- read-only reuse.
#
# SEMANTICS NOTES (research-decision territory, Golden Rule 4)
#   * Slices expiring within 36h are dropped (pin-risk noise, no term
#     information at the published horizons).
#   * Realized vol: trailing 90 daily log returns, annualized at 365.25
#     (the house Julian basis).
#   * The strike ladder is spot-relative (0.70..1.30 x spot, step 0.05,
#     rounded to $500) and stored per row, so scoring always reads the
#     ladder the row was published with.
#   * No VRP tilt yet in this packet -- rn IS the market's density;
#     the real-world tilt + edge ratio land in M13-8.
#
# CAVEATS: wing masses and integral_raw ride every rn record -- tail
#   numbers beyond the last liquid strike are wing-model numbers.
#   Horizons beyond the last liquid expiry are flagged extrapolated.

require 'json'
require 'time'
require 'digest'
require 'zlib'
require 'fileutils'
require 'set'
require_relative '../../lib/btc/env'
require_relative '../../lib/btc/deribit'
require_relative '../../lib/btc/source_cache'
require_relative '../../lib/btc/density'
require_relative '../../lib/btc/dist_scoring'
require_relative '../../lib/btc/stats'
require_relative '../../lib/btc/options'
require_relative '../../lib/btc/report'
require_relative '../../lib/btc/util'

module Dist
  HORIZONS_D = [7, 30, 90].freeze
  RW_WINDOW  = 90            # trailing daily returns for realized vol
  MIN_T_D    = 1.5           # drop slices expiring within 36h
  LADDER     = (0.70..1.301).step(0.05).map { |m| m.round(2) }.freeze
  SCHEMA     = 1

  IBIT_URL = 'https://cdn.cboe.com/api/global/delayed_quotes/options/IBIT.json'

  DATA    = BTC::Env.data_dir('dist', File.join(File.expand_path(__dir__), 'data'))
  LEDGER  = File.join(DATA, 'ledger.jsonl')
  SCORES  = File.join(DATA, 'scores.jsonl')
  SNAPDIR = File.join(DATA, 'snapshots')
  LATEST  = File.join(DATA, 'latest.json')

  LPPL_PRICES = File.join(
    BTC::Env.data_dir('lppl', File.join(File.expand_path('../lppl', __dir__), 'data')),
    'prices.csv'
  )

  module_function

  # ---- pure builders ---------------------------------------------------------

  # Raw book_summary rows -> the gex.rb row shape (shared with Vol/Density).
  def parse_book(rows, now, spot)
    rows.filter_map do |r|
      oi = r['open_interest'].to_f
      next if oi <= 0

      _, exp, strike, cp = r['instrument_name'].split('-')
      ex = BTC::Options.deribit_expiry(exp) or next
      t = (ex - now) / BTC::Options::YEAR_S
      next if t * 365.25 < MIN_T_D

      iv = r['mark_iv'].to_f / 100.0
      next if iv <= 0

      { k: strike.to_f, cp: cp, t: t, iv: iv, oi: oi,
        u: (r['underlying_price'] || spot).to_f }
    end
  end

  # CBOE IBIT chain body -> density-ready book rows on the BTC price
  # axis (M13-7): strikes divided by the live ETF/BTC ratio, exactly the
  # gex_btc_combined.rb conversion. u = btc_spot on every row (no
  # per-expiry ETF forward is published -- v1 carry-free limitation,
  # documented). nil when the chain is empty/degenerate.
  def parse_ibit(data, btc_spot, now)
    spot = (data['current_price'] || data['close']).to_f
    return nil if spot <= 0

    ratio = spot / btc_spot
    rows = (data['options'] || []).filter_map do |o|
      oi = o['open_interest'].to_f
      next if oi <= 0

      expiry, cp, k = BTC::Options.parse_osi(o['option'])
      next unless expiry

      t = (expiry - now) / BTC::Options::YEAR_S
      next if t * 365.25 < MIN_T_D

      iv = o['iv'].to_f
      next if iv <= 0

      { k: k / ratio, cp: cp, t: t, iv: iv, oi: oi, u: btc_spot }
    end
    rows.empty? ? nil : rows
  end

  # Cross-venue divergence: KL(Deribit || IBIT) per horizon, both
  # densities built by the same SVI/BL path. nil KLs (no overlap) pass
  # through honestly.
  def divergence(deribit_slices, ibit_book, stale, as_of)
    ibit_slices = BTC::Density.slices(ibit_book)
    horizons = HORIZONS_D.map do |d|
      t = d / 365.25
      p = BTC::Density.horizon_density(deribit_slices, t)
      q = BTC::Density.horizon_density(ibit_slices, t)
      kl = BTC::Density.kl(p, q)
      { 'd' => d, 'kl' => kl&.round(4) }
    end
    { 'stale' => !!stale, 'as_of' => as_of,
      'n_ibit_slices' => ibit_slices.size,
      'n_ibit_degraded' => ibit_slices.count { |s| s[:degraded] },
      'horizons' => horizons }
  end

  # Trailing annualized realized vol from a close series (oldest-first).
  # nil below 2 usable returns.
  def realized_sigma(closes, window: RW_WINDOW)
    px = closes.last(window + 1)
    return nil if px.size < 3

    rets = px.each_cons(2).map { |a, b| Math.log(b / a) }
    mu = rets.sum / rets.size
    var = rets.sum { |r| (r - mu)**2 } / (rets.size - 1)
    Math.sqrt(var * 365.25)
  end

  # Spot-relative strike ladder, rounded to $500.
  def ladder(spot)
    LADDER.map { |m| ((spot * m) / 500.0).round * 500.0 }.uniq
  end

  # Analytic lognormal quantile grid: center * exp(-w/2 + sqrt(w)*z_tau).
  def lognormal_quantiles(center, w)
    sq = Math.sqrt(w)
    BTC::Density::TAUS.map do |tau|
      [tau, center * Math.exp(-0.5 * w + sq * BTC::Stats.norm_ppf(tau))]
    end
  end

  # Analytic lognormal digital P(S > strike).
  def lognormal_digital(center, w, strike)
    BTC::Stats.norm_cdf((Math.log(center / strike) - 0.5 * w) / Math.sqrt(w))
  end

  # One horizon's ledger record: rn from the fitted surface, ln_atm and
  # rw analytic. Returns nil when the surface has no slices.
  def horizon_record(slices, d_days, spot, sigma_rw)
    t = d_days / 365.25
    h = BTC::Density.horizon(slices, t)
    den = BTC::Density.density_from_w(h[:forward], h[:w_fn], h[:k_lo], h[:k_hi])
    lad = ladder(spot)
    w_atm = h[:w_fn].call(0.0)
    rec = {
      'd' => d_days, 't' => t.round(6), 'forward' => h[:forward].round(1),
      'extrapolated' => h[:extrapolated], 'degraded' => h[:degraded],
      'ladder' => lad,
      'components' => {
        'rn' => {
          'quantiles' => round_q(den[:quantiles]),
          'digitals' => lad.map { |k| BTC::Density.digital(den, k).round(4) },
          'wing_mass_l' => den[:wing_mass][:left].round(4),
          'wing_mass_r' => den[:wing_mass][:right].round(4),
          'integral_raw' => den[:integral_raw].round(4)
        },
        'ln_atm' => {
          'sigma' => Math.sqrt(w_atm / t).round(4),
          'quantiles' => round_q(lognormal_quantiles(h[:forward], w_atm)),
          'digitals' => lad.map { |k| lognormal_digital(h[:forward], w_atm, k).round(4) }
        }
      }
    }
    if sigma_rw
      w_rw = sigma_rw * sigma_rw * t
      rec['components']['rw'] = {
        'sigma' => sigma_rw.round(4), 'center' => spot.round(1),
        'quantiles' => round_q(lognormal_quantiles(spot, w_rw)),
        'digitals' => lad.map { |k| lognormal_digital(spot, w_rw, k).round(4) }
      }
    end
    rec['touch_rn'] = lad.map { |k| BTC::Density.touch(den, k).round(4) }
    rec
  end

  def round_q(quantiles)
    quantiles.map { |tau, q| [tau, q.round(1)] }
  end

  # The whole day, pure: raw rows + spot + closes + stamps in,
  # { 'row' =>, 'payload' => } out (both JSON-shaped). +ibit+ is the
  # optional second venue ({'data'=>chain body,'as_of'=>,'stale'=>});
  # nil or an unparseable chain degrades to divergence: null.
  def build_day(raw_rows, spot, closes, date, known_at, as_of: nil, ibit: nil)
    now = Time.parse("#{date}T00:00:00Z") + 43_200 # mid-day anchor for t
    book = parse_book(raw_rows, now, spot)
    raise 'no live instruments parsed' if book.empty?

    slices = BTC::Density.slices(book)
    violations = BTC::Density.calendar_violations(slices)
    sigma_rw = realized_sigma(closes)
    horizons = HORIZONS_D.map { |d| horizon_record(slices, d, spot, sigma_rw) }

    div = nil
    if ibit && (ib_book = parse_ibit(ibit['data'] || {}, spot, now))
      div = divergence(slices, ib_book, ibit['stale'], ibit['as_of'])
    end

    row = {
      'date' => date, 'known_at' => known_at, 'spot' => spot.round(1),
      'schema' => SCHEMA,
      'n_slices' => slices.size,
      'n_degraded' => slices.count { |s| s[:degraded] },
      'calendar_violations' => violations.size,
      'input_hash' => Digest::SHA256.hexdigest(JSON.generate(book.map(&:to_a))),
      'horizons' => horizons
    }
    { 'row' => row, 'payload' => payload(row, as_of: as_of, divergence: div) }
  end

  # The --json face, derived from a ledger row (frozen field set).
  # +scoring+ is the resolution summary (live runs only; replays and
  # the pure builder report null -- a past day must not carry scores
  # that resolved after it).
  def payload(row, as_of: nil, scoring: nil, divergence: nil)
    h30 = row['horizons'].find { |h| h['d'] == 30 } || row['horizons'].first
    med = quantile_at(h30, 0.5)
    p05 = quantile_at(h30, 0.05)
    p95 = quantile_at(h30, 0.95)
    dgr = row['n_degraded'].positive? ? format(' (%d dgr)', row['n_degraded']) : ''
    headline = format('med30 %s [%s..%s] | %d slices%s | cal viol %d',
                      short_usd(med), short_usd(p05), short_usd(p95),
                      row['n_slices'], dgr, row['calendar_violations'])
    {
      'name' => 'dist', 'ts' => Time.now.utc.iso8601, 'headline' => headline,
      'date' => row['date'], 'as_of' => as_of, 'scoring' => scoring,
      'divergence' => divergence, 'spot' => row['spot'],
      'n_slices' => row['n_slices'], 'n_degraded' => row['n_degraded'],
      'calendar_violations' => row['calendar_violations'],
      'horizons' => row['horizons'].map do |h|
        {
          'd' => h['d'], 'forward' => h['forward'],
          'median' => quantile_at(h, 0.5), 'p05' => quantile_at(h, 0.05),
          'p95' => quantile_at(h, 0.95),
          'sigma_atm' => h.dig('components', 'ln_atm', 'sigma'),
          'sigma_rw' => h.dig('components', 'rw', 'sigma'),
          'extrapolated' => h['extrapolated'], 'degraded' => h['degraded']
        }
      end
    }
  end

  def quantile_at(horizon_rec, tau)
    q = horizon_rec.dig('components', 'rn', 'quantiles')
    pair = q.find { |t, _| (t - tau).abs < 1e-9 }
    pair && pair[1]
  end

  def short_usd(v)
    return '?' unless v

    v >= 1000 ? format('%.1fk', v / 1000.0) : format('%.0f', v)
  end

  # ---- resolution + scoring (M13-6) ------------------------------------------

  # date string + n days -> date string (UTC calendar arithmetic).
  def date_add(date, days)
    (Time.parse("#{date}T00:00:00Z") + days * 86_400).strftime('%Y-%m-%d')
  end

  # Score one component record against realized close y.
  def score_component(comp, ladder, y)
    q = comp['quantiles']
    ls = BTC::DistScoring.log_score(q, y)
    briers = ladder.zip(comp['digitals']).map do |strike, p|
      BTC::DistScoring.brier(p, y > strike)
    end
    { 'log' => ls&.round(4),
      'crps' => BTC::DistScoring.crps(q, y).round(2),
      'pit' => BTC::DistScoring.pit(q, y).round(4),
      'brier_mean' => (briers.sum / briers.size).round(4) }
  end

  # Pure resolution pass: ledger rows + already-scored keys + the
  # date->close map -> the NEW score records (oldest first).
  def resolve(ledger_rows, scored, closes_map)
    out = []
    ledger_rows.each do |row|
      row['horizons'].each do |h|
        key = "#{row['date']}:#{h['d']}"
        next if scored.include?(key)

        matured = date_add(row['date'], h['d'])
        y = closes_map[matured] or next

        out << {
          'date' => row['date'], 'd' => h['d'], 'matured' => matured,
          'y' => y.round(1),
          'scores' => h['components'].transform_values do |comp|
            score_component(comp, h['ladder'], y)
          end
        }
      end
    end
    out
  end

  def read_jsonl(path)
    return [] unless File.exist?(path)

    File.foreach(path).map { |ln| JSON.parse(ln) }
  end

  def scored_keys(path = SCORES)
    read_jsonl(path).map { |r| "#{r['date']}:#{r['d']}" }.to_set
  end

  def append_scores(records, path = SCORES)
    return if records.empty?

    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, 'a') { |f| records.each { |r| f.puts(JSON.generate(r)) } }
  end

  # Full date->close map from the LPPL price cache (completed days only).
  def load_closes_map(path = LPPL_PRICES)
    return {} unless File.exist?(path)

    out = {}
    File.foreach(path) do |ln|
      d, c = ln.strip.split(',')
      next if d.nil? || d == 'date'

      v = c.to_f
      out[d] = v if v > 0.05
    end
    out
  end

  # Aggregate the scoring ledger for the payload: per horizon, n, mean
  # CRPS per component, and each component's log-score skill vs the rw
  # benchmark (mean differential + Newey-West SE at lag d-1). nil-safe:
  # off-grid log scores drop from the differential, not from n.
  def scoring_summary(scores)
    horizons = HORIZONS_D.map do |d|
      recs = scores.select { |r| r['d'] == d }
      next { 'd' => d, 'n' => 0, 'crps' => {}, 'skill_log_vs_rw' => {} } if recs.empty?

      comps = recs.flat_map { |r| r['scores'].keys }.uniq.sort
      crps = comps.to_h do |c|
        vals = recs.filter_map { |r| r.dig('scores', c, 'crps') }
        [c, vals.empty? ? nil : (vals.sum / vals.size).round(2)]
      end
      skill = (comps - ['rw']).to_h do |c|
        diffs = recs.filter_map do |r|
          a = r.dig('scores', c, 'log')
          b = r.dig('scores', 'rw', 'log')
          a && b && (a - b)
        end
        if diffs.empty?
          [c, nil]
        else
          se = BTC::Stats.newey_west_se(diffs, lag: d - 1)
          [c, { 'mean' => (diffs.sum / diffs.size).round(4),
                'se' => se&.round(4), 'n' => diffs.size }]
        end
      end
      { 'd' => d, 'n' => recs.size, 'crps' => crps, 'skill_log_vs_rw' => skill }
    end
    { 'n_resolved' => scores.size, 'horizons' => horizons }
  end

  # ---- ledger / snapshot IO --------------------------------------------------

  def last_ledger_date(path = LEDGER)
    return nil unless File.exist?(path)

    last = nil
    File.foreach(path) { |ln| last = ln }
    last && JSON.parse(last)['date']
  end

  # Appends unless the date is already the tail row. Returns true if added.
  def append_ledger(row, path = LEDGER)
    return false if last_ledger_date(path) == row['date']

    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, 'a') { |f| f.puts(JSON.generate(row)) }
    true
  end

  def snapshot_path(date, dir: SNAPDIR)
    File.join(dir, "#{date}.json.gz")
  end

  # Writes the raw board snapshot (both venues); returns the sha256 of
  # the UNCOMPRESSED JSON (stable across gzip metadata).
  def write_snapshot(date, known_at, spot, raw_rows, ibit: nil, dir: SNAPDIR)
    FileUtils.mkdir_p(dir)
    body = JSON.generate({ 'date' => date, 'known_at' => known_at,
                           'spot' => spot, 'rows' => raw_rows,
                           'ibit' => ibit })
    sha = Digest::SHA256.hexdigest(body)
    Zlib::GzipWriter.open(snapshot_path(date, dir: dir)) { |gz| gz.write(body) }
    sha
  end

  def read_snapshot(date, dir: SNAPDIR)
    path = snapshot_path(date, dir: dir)
    return nil unless File.exist?(path)

    body = Zlib::GzipReader.open(path, &:read)
    JSON.parse(body).merge('sha256' => Digest::SHA256.hexdigest(body))
  end

  # Daily closes from the LPPL price cache, strictly before +cutoff_date+
  # (a live run on D sees closes through D-1, same as a replay on D).
  def load_closes(cutoff_date, path = LPPL_PRICES)
    return [] unless File.exist?(path)

    out = []
    File.foreach(path) do |ln|
      d, c = ln.strip.split(',')
      next if d.nil? || d == 'date' || d >= cutoff_date

      v = c.to_f
      out << v if v > 0.05
    end
    out
  end

  # ---- run modes -------------------------------------------------------------

  def emit(payload)
    if ARGV.include?('--json')
      puts JSON.generate(payload)
    elsif ARGV.include?('--tmux')
      line = format('dist %s %s', payload['date'], payload['headline'])
      BTC::Report.status('dist', line)
      puts line
    else
      puts payload['headline']
      payload['horizons'].each do |h|
        puts format('  %3dd  med %-9s [%s .. %s]  atm %.2f  rw %s%s',
                    h['d'], short_usd(h['median']), short_usd(h['p05']),
                    short_usd(h['p95']), h['sigma_atm'] || 0.0,
                    h['sigma_rw'] ? format('%.2f', h['sigma_rw']) : '--',
                    h['extrapolated'] ? '  EXTRAP' : '')
      end
    end
  end

  def unavailable(reason)
    out = { 'name' => 'dist', 'ts' => Time.now.utc.iso8601,
            'headline' => "unavailable (#{BTC::Env.redact(reason.to_s)})",
            'unavailable' => true }
    if ARGV.include?('--json')
      puts JSON.generate(out)
    else
      puts out['headline']
    end
    exit 0
  end

  def run_replay(date)
    snap = read_snapshot(date) or unavailable("no snapshot for #{date}")
    closes = load_closes(date)
    built = build_day(snap['rows'], snap['spot'].to_f, closes, date,
                      snap['known_at'], as_of: date, ibit: snap['ibit'])
    emit(built['payload'])
  rescue StandardError => e
    unavailable("#{e.class}: #{e.message}")
  end

  def run_live
    today = Time.now.utc.strftime('%Y-%m-%d')
    if File.exist?(LATEST)
      cached = JSON.parse(File.read(LATEST))
      return emit(cached) if cached['date'] == today
    end

    known_at = Time.now.utc.iso8601
    spot = BTC::Deribit.index('btc_usd')[:price]
    raw = BTC::Deribit.book_summary('BTC', 'option')
    ibit = begin
      r = BTC::SourceCache.fetch_json('cboe_ibit', IBIT_URL,
                                      { 'User-Agent' => 'dist.rb' })
      { 'data' => r['data']['data'], 'as_of' => r['as_of'], 'stale' => r['stale'] }
    rescue StandardError
      nil # second venue is optional; Deribit-only day, divergence null
    end
    sha = write_snapshot(today, known_at, spot, raw, ibit: ibit)
    built = build_day(raw, spot, load_closes(today), today, known_at, ibit: ibit)
    built['row']['snapshot_sha256'] = sha
    append_ledger(built['row'])

    prior = read_jsonl(SCORES)
    fresh = resolve(read_jsonl(LEDGER), scored_keys, load_closes_map)
    append_scores(fresh)
    built['payload']['scoring'] = scoring_summary(prior + fresh)

    FileUtils.mkdir_p(DATA)
    File.write(LATEST, JSON.generate(built['payload']))
    emit(built['payload'])
  rescue StandardError => e
    unavailable("#{e.class}: #{e.message}")
  end

  def run
    as_of = BTC::Util.arg('--as-of')
    as_of ? run_replay(as_of) : run_live
  end
end

Dist.run if __FILE__ == $PROGRAM_NAME
