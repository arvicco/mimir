// M6-4: render.js tab-group machinery (node built-in runner, zero npm).
// The two GEX charts (chart:gex_profile [BTC], chart:gex_mstr [MSTR])
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
        div, _resizes: 0,
        setOption() {}, resize() { this._resizes += 1; },
        on() {}, dispatchAction() {}
      };
      instances.push(inst); return inst;
    },
    getInstanceByDom(div) { return instances.find((i) => i.div === div) || null; }
  };
}

// Load a FRESH copy of render.js (its GROUPS/charts module state is
// per-load) against fresh stubs, returning { R, echarts }.
function loadRender() {
  const window = { innerHeight: 1000 };
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
const BTC = () => env('chart:gex_profile', '2026-07-06T16:00:00Z',
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
  // index sorts alphabetically -> gex_mstr loads FIRST, gex_profile second
  const cardA = R.buildChartCard(MSTR(), 'chart:gex_mstr');
  const cardB = R.buildChartCard(BTC(), 'chart:gex_profile');
  assert.equal(cardA, cardB, 'the 2nd member returns the SAME card element');

  const tabs = cardA.querySelector('.tabbar').children;
  assert.equal(tabs.length, 2);
  assert.deepEqual(tabs.map((b) => b.textContent), ['BTC', 'MSTR'], 'tab_pos order');
  assert.ok(tabs[0].classList.contains('active'), 'BTC active by default');
  assert.ok(!tabs[1].classList.contains('active'));

  // title + badge reflect the active (BTC) tab
  assert.equal(cardA.querySelector('.key').textContent, 'chart:gex_profile');
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
  const card = R.buildChartCard(BTC(), 'chart:gex_profile');
  const legends = card.querySelectorAll('.cp-legend');
  assert.equal(legends.length, 1);
  assert.ok(legends[0].parentNode._classes.has('chart'),
            'widget parented to a chart div (not the card), so it hides with BTC');
});

test('clicking MSTR reveals + resizes its chart and swaps title/badge; BTC restores', () => {
  const { R, echarts } = loadRender();
  const card = R.buildChartCard(MSTR(), 'chart:gex_mstr');
  R.buildChartCard(BTC(), 'chart:gex_profile');
  const tabs = card.querySelector('.tabbar').children; // [BTC, MSTR]

  const before = echarts.instances.reduce((s, i) => s + i._resizes, 0);
  tabs[1].click(); // -> MSTR
  const after = echarts.instances.reduce((s, i) => s + i._resizes, 0);
  assert.ok(after > before, 'resize() called on the revealed chart (hidden-init is 0x0)');

  assert.ok(tabs[1].classList.contains('active'));
  assert.ok(!tabs[0].classList.contains('active'));
  assert.equal(card.querySelector('.key').textContent, 'chart:gex_mstr');
  assert.equal(card.querySelector('.badge').getAttribute('data-generated-at'),
               '2026-07-06T15:00:00Z');
  assert.equal(card.dataset.key, 'chart:gex_mstr');

  tabs[0].click(); // back to BTC
  assert.ok(tabs[0].classList.contains('active'));
  assert.equal(card.querySelector('.key').textContent, 'chart:gex_profile');
  assert.equal(card.querySelector('.badge').getAttribute('data-generated-at'),
               '2026-07-06T16:00:00Z');
});

// ---- M8-12: KV strings render as text nodes, never innerHTML ------------

test('errCard builds the key/message as text nodes (no innerHTML from data)', () => {
  const { R } = loadRender();
  const evil = 'chart:<img src=x onerror=alert(1)>';
  const card = R.errCard(evil, 'boom <script>');
  assert.equal(card.className, 'card err');
  assert.equal(card.innerHTML, '', 'no innerHTML string was assigned');
  assert.equal(card.querySelector('.key').textContent, evil, 'key is raw text, not parsed HTML');
  assert.equal(card.querySelector('.msg').textContent, 'boom <script>');
});

test('a solo card badge is a dot span + a text node (no innerHTML from ttl)', () => {
  const { R } = loadRender();
  const solo = env('chart:lppl_regime', '2026-07-06T12:00:00Z',
    { desc: 'd', axes: { x: 'x', y: 'y' }, help: 'h' }, []);
  const badge = R.buildChartCard(solo, 'chart:lppl_regime').querySelector('.badge');
  assert.equal(badge.innerHTML, '', 'no innerHTML string was assigned');
  assert.ok(badge.querySelector('.dot'), 'a .dot span child');
  // dot + one text node "<cls> · ttl 1800s"
  const text = badge.children.filter((c) => c.nodeType === 3).map((c) => c.textContent).join('');
  assert.match(text, /· ttl 1800s$/);
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
