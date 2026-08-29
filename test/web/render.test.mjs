// M6-4: render.js tab-group machinery (node built-in runner, zero npm).
// The two GEX charts (chart:gex_btc [BTC], chart:gex_mstr [MSTR])
// share ONE dashboard card as tabs (owner ruling D7-c, 2026-07-06). This
// pins the render-layer contract with a minimal DOM + echarts stub -- no
// browser, no network. The full visual/interaction proof is the
// Playwright pass in DEV-LOOP 6b; this is the fast regression guard.
// Run: node --test test/web/   (rake web:test; part of the default gate)

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const RENDER_SRC = readFileSync(join(HERE, '..', '..', 'web', 'render.js'), 'utf8');

// ---- minimal DOM ---------------------------------------------------------
// Just the surface render.js touches: node identity + move-semantics
// appendChild (so bubble-content swaps terminate), class-token querying,
// data-* attributes, and inline style. Deliberately tiny.
function makeEl(tag) {
  const el = {
    tagName: String(tag).toUpperCase(),
    children: [], parentNode: null, nodeType: 1,
    style: {}, dataset: {}, _attrs: {}, _classes: new Set(),
    _text: '', _html: '', tabIndex: 0, _ev: {},
    _rect: { width: 0, height: 0, top: 0, bottom: 0 },
    appendChild(child) {
      if (child.parentNode) child.parentNode.removeChild(child);
      this.children.push(child); child.parentNode = this; return child;
    },
    removeChild(child) {
      const i = this.children.indexOf(child);
      if (i >= 0) this.children.splice(i, 1);
      child.parentNode = null; return child;
    },
    get firstChild() { return this.children[0] || null; },
    addEventListener(type, fn) { (this._ev[type] || (this._ev[type] = [])).push(fn); },
    click() { (this._ev.click || []).forEach((f) => f()); },
    setAttribute(k, v) { this._attrs[k] = String(v); },
    getAttribute(k) { return k in this._attrs ? this._attrs[k] : null; },
    getBoundingClientRect() { return this._rect; },
    get classList() {
      const c = this._classes;
      return {
        add: (x) => c.add(x), remove: (x) => c.delete(x),
        contains: (x) => c.has(x),
        toggle: (x, on) => { const v = on === undefined ? !c.has(x) : on; v ? c.add(x) : c.delete(x); return v; }
      };
    },
    get className() { return [...this._classes].join(' '); },
    set className(v) { this._classes = new Set(String(v).split(/\s+/).filter(Boolean)); },
    get textContent() { return this._text; },
    set textContent(v) { this._text = String(v); this.children = []; },
    get innerHTML() { return this._html; },
    set innerHTML(v) { this._html = String(v); this.children = []; },
    querySelector(sel) { return firstMatch(this, sel); },
    querySelectorAll(sel) { const out = []; collectMatches(this, sel, out); return out; }
  };
  return el;
}
function matchesSel(el, sel) {
  if (el.nodeType !== 1) return false;
  if (sel[0] === '.') return el._classes.has(sel.slice(1));
  const m = /^\[data-key="(.*)"\]$/.exec(sel);
  if (m) return el._attrs['data-key'] === m[1] || el.dataset.key === m[1];
  return el.tagName === sel.toUpperCase();
}
function collectMatches(root, sel, out) {
  root.children.forEach((c) => { if (matchesSel(c, sel)) out.push(c); collectMatches(c, sel, out); });
}
function firstMatch(root, sel) { const out = []; collectMatches(root, sel, out); return out[0] || null; }

function makeTextNode(t) {
  return { nodeType: 3, parentNode: null, textContent: String(t), children: [] };
}

// ---- echarts stub --------------------------------------------------------
function makeEcharts() {
  const instances = [];
  return {
    instances,
    init(div) {
      const inst = {
        div, _resizes: 0, _opts: [], _on: {},
        setOption(o) { this._opts.push(o); },   // M9-15: recorded so the
        resize() { this._resizes += 1; },        // legend/axis wiring is testable
        on(type, fn) { (this._on[type] || (this._on[type] = [])).push(fn); },
        dispatchAction() {}
      };
      instances.push(inst); return inst;
    },
    getInstanceByDom(div) { return instances.find((i) => i.div === div) || null; }
  };
}

// Load a FRESH copy of render.js (its GROUPS/charts module state is
// per-load) against fresh stubs, returning { R, echarts }.
function loadRender() {
  const window = { innerHeight: 1000, innerWidth: 1400 };
  const document = { createElement: makeEl, createTextNode: makeTextNode };
  const echarts = makeEcharts();
  const raf = (cb) => { cb(); return 1; }; // synchronous: resize-on-reveal is observable
  const factory = new Function(
    'window', 'document', 'echarts', 'requestAnimationFrame',
    `${RENDER_SRC}\n;return window.MimirRender;`
  );
  const R = factory(window, document, echarts, raf);
  return { R, echarts };
}

function env(key, gen, meta, series) {
  return { key, generated_at: gen, ttl_hint_s: 1800, meta,
           payload: { series: series || [] } };
}
const BTC = () => env('chart:gex_btc', '2026-07-06T16:00:00Z',
  { desc: 'BTC gex', axes: { x: 'x', y: 'y' }, help: 'h',
    tooltip_formatter: 'gex_levels', legend_widget: 'gex_cp',
    tab_group: 'gex', tab_label: 'BTC', tab_pos: 1 },
  [{ name: 'DERI C' }, { name: 'DERI P' }]);
const MSTR = () => env('chart:gex_mstr', '2026-07-06T15:00:00Z',
  { desc: 'MSTR gex', axes: { x: 'x', y: 'y' }, help: 'h',
    tab_group: 'gex', tab_label: 'MSTR', tab_pos: 2 },
  [{ name: 'net GEX' }]);

// ---- the tab-group contract ---------------------------------------------

test('both GEX members share ONE card, tabs ordered by tab_pos, BTC default', () => {
  const { R } = loadRender();
  // load MSTR first to prove tab_pos ordering wins regardless of load order
  const cardA = R.buildChartCard(MSTR(), 'chart:gex_mstr');
  const cardB = R.buildChartCard(BTC(), 'chart:gex_btc');
  assert.equal(cardA, cardB, 'the 2nd member returns the SAME card element');

  const tabs = cardA.querySelector('.tabbar').children;
  assert.equal(tabs.length, 2);
  assert.deepEqual(tabs.map((b) => b.textContent), ['BTC', 'MSTR'], 'tab_pos order');
  assert.ok(tabs[0].classList.contains('active'), 'BTC active by default');
  assert.ok(!tabs[1].classList.contains('active'));

  // title + badge reflect the active (BTC) tab
  assert.equal(cardA.querySelector('.key').textContent, 'gex_btc');
  assert.equal(cardA.querySelector('.badge').getAttribute('data-generated-at'),
               '2026-07-06T16:00:00Z');

  // exactly one of the two chart divs is visible
  const divs = cardA.querySelectorAll('.chart');
  assert.equal(divs.length, 2);
  assert.equal(divs.filter((d) => d.style.display !== 'none').length, 1);
});

test('the (p)/(c) legend widget hosts on the BTC chart div, so it hides with the tab', () => {
  const { R } = loadRender();
  R.buildChartCard(MSTR(), 'chart:gex_mstr');
  const card = R.buildChartCard(BTC(), 'chart:gex_btc');
  const legends = card.querySelectorAll('.cp-legend');
  assert.equal(legends.length, 1);
  assert.ok(legends[0].parentNode._classes.has('chart'),
            'widget parented to a chart div (not the card), so it hides with BTC');
});

test('clicking MSTR reveals + resizes its chart and swaps title/badge; BTC restores', () => {
  const { R, echarts } = loadRender();
  const card = R.buildChartCard(MSTR(), 'chart:gex_mstr');
  R.buildChartCard(BTC(), 'chart:gex_btc');
  const tabs = card.querySelector('.tabbar').children; // [BTC, MSTR]

  const before = echarts.instances.reduce((s, i) => s + i._resizes, 0);
  tabs[1].click(); // -> MSTR
  const after = echarts.instances.reduce((s, i) => s + i._resizes, 0);
  assert.ok(after > before, 'resize() called on the revealed chart (hidden-init is 0x0)');

  assert.ok(tabs[1].classList.contains('active'));
  assert.ok(!tabs[0].classList.contains('active'));
  assert.equal(card.querySelector('.key').textContent, 'gex_mstr');
  assert.equal(card.querySelector('.badge').getAttribute('data-generated-at'),
               '2026-07-06T15:00:00Z');
  assert.equal(card.dataset.key, 'chart:gex_mstr');

  tabs[0].click(); // back to BTC
  assert.ok(tabs[0].classList.contains('active'));
  assert.equal(card.querySelector('.key').textContent, 'gex_btc');
  assert.equal(card.querySelector('.badge').getAttribute('data-generated-at'),
               '2026-07-06T16:00:00Z');
});

// ---- M8-17: stacked card with a tabbed section (shared tab_pos) ----------
// Owner ruling 2026-08-10: the vol card's SURFACE half is a [BTC][MSTR] tab
// pair -- members sharing a tab_pos collapse into ONE tabbed section; a
// unique tab_pos stays a plain section. vol_surface (pos 0, BTC) +
// vol_surface_mstr (pos 0, MSTR) tab together above vol_basis (pos 2).
function stackEnv(key, gen, tab_pos, tab_label) {
  return env(key, gen,
    { desc: key + ' d', axes: { x: 'x', y: 'y' }, help: 'h',
      tab_group: 'vol', group_style: 'stack', tab_pos: tab_pos,
      tab_label: tab_label, height: 235 }, []);
}
const VSURF = () => stackEnv('chart:vol_surface', '2026-08-10T16:00:00Z', 0, 'BTC');
const VMSTR = () => stackEnv('chart:vol_surface_mstr', '2026-08-10T15:00:00Z', 0, 'MSTR');
const VBASIS = () => stackEnv('chart:vol_basis', '2026-08-10T14:00:00Z', 2, null);

test('shared tab_pos collapses into ONE tabbed section; unique pos stays plain', () => {
  const { R } = loadRender();
  // index sorts alphabetically -> vol_basis, then vol_surface, then _mstr
  const c1 = R.buildChartCard(VBASIS(), 'chart:vol_basis');
  const c2 = R.buildChartCard(VSURF(), 'chart:vol_surface');
  const c3 = R.buildChartCard(VMSTR(), 'chart:vol_surface_mstr');
  assert.equal(c1, c2, 'all members share ONE stacked card');
  assert.equal(c2, c3);

  const secs = c1.querySelectorAll('.stacksec');
  assert.equal(secs.length, 2, 'two sections: the tabbed surface + plain basis');
  // section order = tab_pos: surface (pos 0) on top, basis (pos 2) below
  const bars = c1.querySelectorAll('.tabbar');
  assert.equal(bars.length, 1, 'exactly one section carries a tab bar');
  const tabs = bars[0].children;
  assert.deepEqual(tabs.map((b) => b.textContent), ['BTC', 'MSTR'], 'BTC leads by CARD_ORDER');
  assert.ok(tabs[0].classList.contains('active'), 'BTC active by default');
  // the surface section shows ONE chart; the basis section its own
  assert.equal(c1.querySelectorAll('.chart').length, 3);
  assert.equal(c1.querySelectorAll('.chart').filter((d) => d.style.display !== 'none').length,
               2, 'one visible surface chart + the always-visible basis chart');
});

test('clicking MSTR swaps the surface section key/badge and resizes; basis untouched', () => {
  const { R, echarts } = loadRender();
  const card = R.buildChartCard(VBASIS(), 'chart:vol_basis');
  R.buildChartCard(VSURF(), 'chart:vol_surface');
  R.buildChartCard(VMSTR(), 'chart:vol_surface_mstr');
  const tabbar = card.querySelector('.tabbar');
  const tabs = tabbar.children; // [BTC, MSTR]
  // the surface section head reflects the active (BTC) member
  const surfHead = tabbar.parentNode;         // .card-head
  const surfSec = surfHead.parentNode;        // .stacksec
  assert.equal(surfSec.querySelector('.key').textContent, 'vol_surface');
  assert.equal(surfSec.querySelector('.badge').getAttribute('data-generated-at'),
               '2026-08-10T16:00:00Z');

  const before = echarts.instances.reduce((s, i) => s + i._resizes, 0);
  tabs[1].click(); // -> MSTR
  const after = echarts.instances.reduce((s, i) => s + i._resizes, 0);
  assert.ok(after > before, 'revealed MSTR chart is resized (hidden-init is 0x0)');
  assert.ok(tabs[1].classList.contains('active'));
  assert.equal(surfSec.querySelector('.key').textContent, 'vol_surface_mstr');
  assert.equal(surfSec.querySelector('.badge').getAttribute('data-generated-at'),
               '2026-08-10T15:00:00Z');
  // the basis section is a separate .stacksec, unaffected by the tab click
  const basisSec = card.querySelectorAll('.stacksec').filter((s) => s !== surfSec)[0];
  assert.equal(basisSec.querySelector('.key').textContent, 'vol_basis');
});

// ---- linked stacked tabs (owner ruling 2026-08-29, the GEX card) ---------
// A stacked card whose tabbed sections carry IDENTICAL label sequences
// gets ONE switcher: only the top linked section renders a tab bar, and a
// click flips every linked section to the same label (profile + trend
// move together). Differing label sets (the vol card) keep per-section
// bars -- covered by the M8-17 tests above.
function gexEnv(key, gen, tab_pos, tab_label) {
  return env(key, gen,
    { desc: key + ' d', axes: { x: 'x', y: 'y' }, help: 'h',
      tab_group: 'gex', group_style: 'stack', tab_pos: tab_pos,
      tab_label: tab_label, height: tab_pos === 0 ? 260 : 210 }, []);
}
const GBTC = () => gexEnv('chart:gex_btc', '2026-08-29T16:00:00Z', 0, 'BTC');
const GMSTR = () => gexEnv('chart:gex_mstr', '2026-08-29T15:00:00Z', 0, 'MSTR');
const GBTREND = () => gexEnv('chart:gex_btc_trend', '2026-08-29T14:00:00Z', 1, 'BTC');
const GMTREND = () => gexEnv('chart:gex_mstr_trend', '2026-08-29T13:00:00Z', 1, 'MSTR');

test('identical label sets link stacked sections under ONE tab bar', () => {
  const { R } = loadRender();
  const card = R.buildChartCard(GBTC(), 'chart:gex_btc');
  R.buildChartCard(GMSTR(), 'chart:gex_mstr');
  R.buildChartCard(GBTREND(), 'chart:gex_btc_trend');
  R.buildChartCard(GMTREND(), 'chart:gex_mstr_trend');

  const secs = card.querySelectorAll('.stacksec');
  assert.equal(secs.length, 2, 'profile section over trend section');
  const bars = card.querySelectorAll('.tabbar');
  assert.equal(bars.length, 1, 'linked sections share ONE tab bar (the leader)');
  assert.deepEqual(bars[0].children.map((b) => b.textContent), ['BTC', 'MSTR']);
  // default: both sections show their BTC member
  assert.equal(secs[0].querySelector('.key').textContent, 'gex_btc');
  assert.equal(secs[1].querySelector('.key').textContent, 'gex_btc_trend');
});

test('clicking MSTR on the linked bar flips BOTH sections', () => {
  const { R } = loadRender();
  const card = R.buildChartCard(GBTC(), 'chart:gex_btc');
  R.buildChartCard(GMSTR(), 'chart:gex_mstr');
  R.buildChartCard(GBTREND(), 'chart:gex_btc_trend');
  R.buildChartCard(GMTREND(), 'chart:gex_mstr_trend');

  const tabs = card.querySelector('.tabbar').children;
  tabs[1].click(); // -> MSTR
  const secs = card.querySelectorAll('.stacksec');
  assert.equal(secs[0].querySelector('.key').textContent, 'gex_mstr');
  assert.equal(secs[1].querySelector('.key').textContent, 'gex_mstr_trend',
               'the trend section followed the linked switch');
  assert.equal(secs[1].querySelector('.badge').getAttribute('data-generated-at'),
               '2026-08-29T13:00:00Z', 'follower badge tracks its own member');
  // each section shows exactly one chart
  const visible = card.querySelectorAll('.chart').filter((d) => d.style.display !== 'none');
  assert.equal(visible.length, 2);
  tabs[0].click(); // back to BTC
  assert.equal(secs[1].querySelector('.key').textContent, 'gex_btc_trend');
});

// ---- staleness bands (owner ruling 2026-08-18) ---------------------------
// green <= ttl, amber <= 2x, orange <= 3x, red beyond. With the uniform
// 3600s ttl that is: green 1h after a publish, yellow the next hour,
// orange the third, red past 3h.

test('staleClass walks green/amber/orange/red at 1x/2x/3x ttl', () => {
  const { R } = loadRender();
  const at = (ageSec) => new Date(Date.now() - ageSec * 1000).toISOString();
  assert.equal(R.staleClass(at(0), 3600), 'green', 'fresh is green');
  assert.equal(R.staleClass(at(3600), 3600), 'green', 'exactly ttl is still green');
  assert.equal(R.staleClass(at(3601), 3600), 'amber', 'past ttl turns amber');
  assert.equal(R.staleClass(at(7200), 3600), 'amber', 'exactly 2x ttl is still amber');
  assert.equal(R.staleClass(at(7201), 3600), 'orange', 'past 2x ttl turns orange');
  assert.equal(R.staleClass(at(10800), 3600), 'orange', 'exactly 3x ttl is still orange');
  assert.equal(R.staleClass(at(10801), 3600), 'red', 'past 3x ttl is red');
});

// ---- M8-13: re-fetch cadence clamp --------------------------------------

test('nextDelay honours ttl_hint_s but never polls faster than the 60s floor', () => {
  const { R } = loadRender();
  assert.equal(R.nextDelay(1800), 1800 * 1000, 'a 30-min ttl re-fetches every 30 min');
  assert.equal(R.nextDelay(60), 60 * 1000, '60s is the floor itself');
  assert.equal(R.nextDelay(59), 60 * 1000, 'below the floor clamps up to 60s');
  assert.equal(R.nextDelay(0), 60 * 1000, 'zero clamps to 60s (no storm)');
  assert.equal(R.nextDelay(-5), 60 * 1000, 'negative clamps to 60s');
  assert.equal(R.nextDelay(undefined), 60 * 1000, 'missing ttl clamps to 60s');
  assert.equal(R.nextDelay('90'), 90 * 1000, 'numeric string is coerced');
  assert.equal(R.nextDelay('nope'), 60 * 1000, 'garbage clamps to 60s');
});

// ---- M8-12: KV strings render as text nodes, never innerHTML ------------

test('errCard builds the key/message as text nodes (no innerHTML from data)', () => {
  const { R } = loadRender();
  const evil = 'chart:<img src=x onerror=alert(1)>';
  const card = R.errCard(evil, 'boom <script>');
  assert.equal(card.className, 'card err');
  assert.equal(card.innerHTML, '', 'no innerHTML string was assigned');
  // dispKey strips the internal chart: prefix for display (owner ruling
  // 2026-08-10); the payload remains raw TEXT either way -- the security
  // property under test is unchanged.
  assert.equal(card.querySelector('.key').textContent,
               '<img src=x onerror=alert(1)>', 'key is raw text, not parsed HTML');
  assert.equal(card.querySelector('.msg').textContent, 'boom <script>');
});

test('a solo card badge is a bare dot + a hover/focus bubble (M8-18 R6)', () => {
  const { R } = loadRender();
  const solo = env('chart:lppl_regime', '2026-07-06T12:00:00Z',
    { desc: 'd', axes: { x: 'x', y: 'y' }, help: 'h' }, []);
  const badge = R.buildChartCard(solo, 'chart:lppl_regime').querySelector('.badge');
  assert.equal(badge.innerHTML, '', 'no innerHTML string was assigned');
  assert.ok(badge.querySelector('.dot'), 'a .dot span child');
  assert.ok(badge.querySelector('.badge-bubble'), 'a .badge-bubble child');
  // dot-only: no text node lives directly on the badge anymore
  assert.equal(badge.children.filter((c) => c.nodeType === 3).length, 0);
  // data attrs stamped so the ticker + the bubble can read freshness
  assert.equal(badge.getAttribute('data-generated-at'), '2026-07-06T12:00:00Z');
  assert.equal(badge.getAttribute('data-ttl'), '1800');
  assert.equal(badge.getAttribute('tabindex'), '0', 'focusable like the header dots');
  // the bubble text is built ON OPEN from the data attrs: "age .. · ttl .. · HH:MMZ"
  badge._ev.mouseenter.forEach((f) => f());
  assert.match(badge.querySelector('.badge-bubble').textContent, /^age .+ · ttl 1800s · 12:00Z$/);
});

test('refreshBadge repaints the dot from the data attrs (the page ticker)', () => {
  const { R } = loadRender();
  const solo = env('chart:lppl_regime', '2026-07-06T12:00:00Z',
    { desc: 'd', axes: { x: 'x', y: 'y' }, help: 'h' }, []);
  const badge = R.buildChartCard(solo, 'chart:lppl_regime').querySelector('.badge');
  // stale it far in the past, tick, and the dot goes red (age >> 3x ttl)
  badge.setAttribute('data-generated-at', '2000-01-01T00:00:00Z');
  R.refreshBadge(badge);
  assert.ok(badge.querySelector('.dot').classList.contains('red'));
});

test('a non-grouped chart still builds a fresh, tab-less card', () => {
  const { R } = loadRender();
  const solo = env('chart:lppl_regime', '2026-07-06T12:00:00Z',
    { desc: 'd', axes: { x: 'x', y: 'y' }, help: 'h' }, []);
  const c1 = R.buildChartCard(solo, 'chart:lppl_regime');
  const c2 = R.buildChartCard(solo, 'chart:lppl_regime');
  assert.notEqual(c1, c2, 'solo charts are independent cards');
  assert.equal(c1.querySelectorAll('.tabbar').length, 0);
  assert.equal(c1.dataset.key, 'chart:lppl_regime');
  assert.equal(c1.querySelectorAll('.chart').length, 1);
});

// ---- M9-15: the glossary 'terms' hook (owner ruling 2026-08-11) ----------
// meta.terms gives abbreviations / module names a hover explanation on three
// surfaces. The visual proof is the Playwright pass; these pin the render-
// layer wiring (payload/goldens are untouched -- an additive meta channel).

test('termsBlock renders the styled block (bold term + wrapped text) and escapes HTML', () => {
  const { R } = loadRender();
  const html = R.termsBlock('CW', 'call <wall> & support');
  assert.match(html, /<b>CW<\/b>/);
  assert.match(html, /call &lt;wall&gt; &amp; support/, 'text is escaped, not raw HTML');
});

test('gex_cp venue cells carry a glossary CSS bubble; a stale label resolves to its base term', () => {
  const { R } = loadRender();
  const btc = env('chart:gex_btc', '2026-07-06T16:00:00Z',
    { desc: 'BTC gex', axes: { x: 'x', y: 'y' }, help: 'h',
      tooltip_formatter: 'gex_levels', legend_widget: 'gex_cp',
      tab_group: 'gex', tab_label: 'BTC', tab_pos: 1,
      terms: { DERI: 'Deribit desc', IBIT: 'iShares desc' } },
    [{ name: 'DERI C' }, { name: 'DERI P' }, { name: 'IBIT! C' }, { name: 'IBIT! P' }]);
  const card = R.buildChartCard(btc, 'chart:gex_btc');
  const bubs = card.querySelectorAll('.cp-bub');
  assert.equal(bubs.length, 2, 'one bubble per present venue that has a term');
  assert.deepEqual(bubs.map((b) => b.textContent).sort(),
                   ['Deribit desc', 'iShares desc'], 'DERI + stale IBIT! both resolve');
});

test('applyTerms wires a legend tooltip: known items render the block, unknown blank out', () => {
  const { R, echarts } = loadRender();
  const e = env('chart:vs', '2026-08-10T16:00:00Z',
    { desc: 'd', axes: { x: 'x', y: 'y' }, help: 'h', terms: { RR25: 'risk reversal text' } },
    [{ name: 'RR25' }]);
  e.payload.legend = { data: ['RR25'] }; // the option SHOWS a legend
  R.buildChartCard(e, 'chart:vs');
  const inst = echarts.instances[echarts.instances.length - 1];
  const legOpt = inst._opts.find((o) => o.legend && o.legend.tooltip);
  assert.ok(legOpt, 'a legend.tooltip setOption was recorded');
  assert.equal(legOpt.legend.tooltip.show, true);
  const fmt = legOpt.legend.tooltip.formatter;
  assert.match(fmt({ name: 'RR25' }), /<b>RR25<\/b>/);
  assert.match(fmt({ name: 'RR25' }), /risk reversal text/);
  assert.equal(fmt({ name: 'nope' }), '', 'unknown legend item -> no tooltip content');
});

test('a term-carrying category axis gets triggerEvent + a viewport popover (scenario scoreboard)', () => {
  const { R, echarts } = loadRender();
  const scn = {
    key: 'chart:scenario_strip', generated_at: '2026-08-10T16:00:00Z', ttl_hint_s: 1800,
    meta: { desc: 'd', axes: { x: 'x', y: 'y' }, help: 'h',
            terms: { macro: 'Macro liquidity text', stables: 'Stablecoin text' } },
    payload: { yAxis: [{ type: 'value' }, { type: 'category', data: ['macro', 'stables'] }],
               series: [] }
  };
  const card = R.buildChartCard(scn, 'chart:scenario_strip');
  const inst = echarts.instances[echarts.instances.length - 1];
  const axOpt = inst._opts.find((o) => o.yAxis && o.yAxis[1] && o.yAxis[1].triggerEvent);
  assert.ok(axOpt, 'triggerEvent enabled on the module (term-carrying) axis');
  const pop = card.querySelector('.terms-pop');
  assert.ok(pop, 'a popover element exists');
  assert.equal(pop.style.display, 'none', 'hidden until a label is hovered');

  // hover the 'macro' module label
  inst._on.mouseover.forEach((f) => f(
    { componentType: 'yAxis', value: 'macro', event: { event: { clientX: 20, clientY: 30 } } }));
  assert.equal(pop.style.display, 'block');
  assert.match(pop.innerHTML, /<b>macro<\/b>/);
  assert.match(pop.innerHTML, /Macro liquidity text/);

  // a non-term value on the same axis does not open it
  pop.style.display = 'none';
  inst._on.mouseover.forEach((f) => f(
    { componentType: 'yAxis', value: 'composite', event: { event: { clientX: 1, clientY: 1 } } }));
  assert.equal(pop.style.display, 'none', 'a non-term axis label is ignored');

  // leaving the label hides it
  inst._on.mouseover.forEach((f) => f(
    { componentType: 'yAxis', value: 'stables', event: { event: { clientX: 5, clientY: 5 } } }));
  assert.equal(pop.style.display, 'block');
  inst._on.mouseout.forEach((f) => f({ componentType: 'yAxis' }));
  assert.equal(pop.style.display, 'none');
});

test('applyTerms never creates a legend on a legend-less chart (phantom-legend regression)', () => {
  // 2026-08-11 owner report: the scenario chart (no legend in its option)
  // grew a phantom "composite/modules" legend colliding with the title,
  // because merging {legend:{tooltip}} CREATES a default-shown legend.
  const { R, echarts } = loadRender();
  const e = env('chart:scn', '2026-08-10T16:00:00Z',
    { desc: 'd', axes: { x: 'x', y: 'y' }, help: 'h', terms: { macro: 'macro text' } },
    [{ name: 'composite' }]);
  R.buildChartCard(e, 'chart:scn'); // payload has NO legend key
  const inst = echarts.instances[echarts.instances.length - 1];
  assert.ok(!inst._opts.some((o) => o.legend),
            'no legend setOption may be recorded for a legend-less option');
});

test('the lppl_shadow formatter tooltip carries dark house chrome (contrast regression)', () => {
  const { R, echarts } = loadRender();
  const e = env('chart:lppl_shadow', '2026-08-10T16:00:00Z',
    { desc: 'd', axes: { x: 'x', y: 'y' }, help: 'h', tooltip_formatter: 'lppl_shadow' },
    [{ name: 'rows' }]);
  R.buildChartCard(e, 'chart:lppl_shadow');
  const inst = echarts.instances[echarts.instances.length - 1];
  const tip = inst._opts.map((o) => o.tooltip).filter(Boolean).pop();
  assert.equal(tip.backgroundColor, '#232933', 'dark bubble background');
  assert.equal(tip.textStyle.color, '#ccd3dc', 'light text on dark');
});

// ---- M10-7: the scorecard_row per-row hover formatter --------------------
// Axis trigger hands every column datum at the hovered row; the row-label
// datum carries a `hover` block and the formatter renders it. It also earns
// the same dark house chrome as lppl_shadow (its block is light-on-dark).

test('scorecard_row renders per-horizon lines, colours by sign, keeps ineligible honest', () => {
  const { R } = loadRender();
  const fmt = R.FORMATTERS.scorecard_row;
  const hover = { title: 'scenario_regime', kind: 'band', band: 'BASE',
    note: 'plain <language> note',
    cells: {
      7: { eligible: true, n: 12, n_eff: 1.7, mean_pct: 1.2, pos_pct: 75.0 },
      30: { eligible: true, n: 40, n_eff: 1.3, mean_pct: -5.95, pos_pct: 43.4 },
      90: { eligible: false, reason: 'n too small', n: 0 }
    } };
  const html = fmt([{ data: { label: {} } }, { data: { hover: hover } }]);
  assert.match(html, /<b>scenario_regime<\/b>/);
  assert.match(html, /7d: <span style="color:#2fbf8f">\+1\.2%<\/span>/, 'positive mean is teal, signed');
  assert.match(html, /30d: <span style="color:#ef6b6b">-5\.95%<\/span>/, 'negative mean is red');
  assert.match(html, /90d: <span style="color:#8a93a0">-- n too small \(n0\)<\/span>/, 'ineligible reads honest');
  assert.match(html, /n_eff 1\.7/, 'the honest overlap-adjusted count rides the hover');
  assert.match(html, /plain &lt;language&gt; note/, 'the note is escaped, not raw HTML');
  assert.equal(fmt([{ data: {} }]), '', 'no hover datum -> empty (e.g. the header row)');
});

test('the scorecard_row formatter tooltip carries dark house chrome (contrast regression)', () => {
  const { R, echarts } = loadRender();
  const e = env('chart:scorecard', '2026-08-12T12:00:00Z',
    { desc: 'd', axes: { x: 'x', y: 'y' }, help: 'h', tooltip_formatter: 'scorecard_row' },
    [{ name: 'label' }]);
  R.buildChartCard(e, 'chart:scorecard');
  const inst = echarts.instances[echarts.instances.length - 1];
  const tip = inst._opts.map((o) => o.tooltip).filter(Boolean).pop();
  assert.equal(tip.backgroundColor, '#232933', 'dark bubble background');
  assert.equal(tip.textStyle.color, '#ccd3dc', 'light text on dark');
});
