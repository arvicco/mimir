"use strict";
/*
  render.js -- the ONE shared mimir chart renderer (work packet M4-2).
  Extracted verbatim from preview.html so the Gate-3 offline preview and
  the production dashboard (web/index.html, M4-3) build cards from a single
  place: staleness math, hover-bubble builder, the renderer-hook registries,
  and the chart-card DOM builder all live here. Fetching stays in the page
  (each surface has its own transport -- local files vs. same-origin
  /api/v1/:key); this file is transport-agnostic.

  RENDERER HOOKS (see publish/chart_specs.rb header for the frozen contract):
  setOption(payload) is applied VERBATIM, with exactly three meta-declared
  exceptions the render layer owns --
    tooltip_formatter -- meta names a formatter in FORMATTERS; unknown names
      fall back to the payload's default tooltip.
    height            -- meta.height is a card pixel-height hint.
    legend_widget     -- meta names an HTML widget in WIDGETS that replaces
      the drawn legend (the spec ships legend.show=false but keeps
      legend.data, so ECharts still owns selection state and the widget
      drives it via legend actions); unknown names render no widget.
  Add a hook only with an owner ruling.

  Exposes ONE global: window.MimirRender. Plain classic script -- no ES
  modules, no build step. The CSS lives in each host page; this file assumes
  the .card/.bubble/.cp-legend classes preview.html and index.html share.
*/

// Staleness class from age vs ttl: <=ttl green, <=3x amber, else red.
function staleClass(generatedAt, ttlSec) {
  var age = (Date.now() - new Date(generatedAt).getTime()) / 1000;
  if (age <= ttlSec) return "green";
  if (age <= ttlSec * 3) return "amber";
  return "red";
}

// UTC HH:MM from an ISO instant, for the compact "key@HH:MM" strip chips.
function hhmm(iso) {
  var d = new Date(iso);
  if (isNaN(d.getTime())) return "?";
  function p(n) { return (n < 10 ? "0" : "") + n; }
  return p(d.getUTCHours()) + ":" + p(d.getUTCMinutes());
}

// Structured hover bubble from a chart envelope's meta: description
// paragraph, axis meanings, then UX help. Text-node built (no HTML
// injection from data); missing pieces are simply omitted.
function buildBubble(meta) {
  var b = document.createElement("div");
  b.className = "bubble";
  function para(label, text) {
    if (!text) return;
    var p = document.createElement("p");
    if (label) {
      var s = document.createElement("span");
      s.className = "lbl";
      s.textContent = label + " ";
      p.appendChild(s);
    }
    p.appendChild(document.createTextNode(text));
    b.appendChild(p);
  }
  para(null, meta.desc);
  var a = meta.axes || {};
  para("x —", a.x);
  para("y —", a.y);
  para("how —", meta.help);
  return b;
}

// ---- renderer formatter registry ---------------------------------------
// Sanctioned deviation from setOption(payload)-verbatim #1 (see
// publish/chart_specs.rb header): a chart's meta.tooltip_formatter names a
// function here; unknown names fall back to the default tooltip.
var FORMATTERS = {
  // gex_profile: header = level + cross-venue C/P totals, then one line
  // per venue -- calls green, puts red, zero-zero venues omitted.
  gex_levels: function (params) {
    if (!params || !params.length) return "";
    var G = "#2fbf8f", R = "#ef6b6b";
    function fm(v) { return (Math.round(v * 100) / 100) + "M"; }
    function span(c, t) { return '<span style="color:' + c + '">' + t + "</span>"; }
    var head = params[0].axisValueLabel || params[0].axisValue || "";
    var aggC = 0, aggP = 0, order = [], venues = {};
    params.forEach(function (p) {
      var v = Number(Array.isArray(p.value) ? p.value[1] : p.value) || 0;
      if (p.seriesName === "C") { aggC = v; return; }
      if (p.seriesName === "P") { aggP = v; return; }
      var m = /^(.*) ([CP])$/.exec(p.seriesName || "");
      if (!m) return;
      if (!venues[m[1]]) { venues[m[1]] = { C: 0, P: 0 }; order.push(m[1]); }
      venues[m[1]][m[2]] = v;
    });
    var out = ["<b>" + head + "</b>: " + span(G, fm(aggC)) + " " + span(R, fm(aggP))];
    order.forEach(function (n) {
      var v = venues[n];
      if (!v.C && !v.P) return; // nothing at this level for this venue
      out.push(n + ": " + span(G, fm(v.C)) + " " + span(R, fm(v.P)));
    });
    return out.join("<br>");
  }
};

// ---- renderer legend-widget registry ------------------------------------
// Sanctioned deviation #2 (chart_specs.rb header, owner review round 4):
// meta.legend_widget names a builder here that replaces the chart's drawn
// legend (the spec ships legend.show=false but keeps legend.data, so
// ECharts still owns selection state and the widget drives it via legend
// actions). Unknown names simply render no widget.
var WIDGETS = {
  // gex_cp: one compact line per venue -- "(p) DERI (c)". Clicking (p) or
  // (c) toggles that side's series alone; clicking the venue name toggles
  // both together (both shown -> both hidden, anything else -> both shown).
  gex_cp: function (card, chart, option) {
    var venues = [], sides = {};
    (option.series || []).forEach(function (s) {
      var m = /^(.*) ([CP])$/.exec(s.name || "");
      if (!m) return;
      if (!sides[m[1]]) { sides[m[1]] = {}; venues.push(m[1]); }
      sides[m[1]][m[2]] = s.name;
    });
    if (!venues.length) return;

    var sel = {}; // series start selected; tracked via legendselectchanged
    venues.forEach(function (v) { sel[sides[v].C] = true; sel[sides[v].P] = true; });
    var rows = [];
    function paint() {
      rows.forEach(function (r) {
        r.p.classList.toggle("off", !sel[sides[r.v].P]);
        r.c.classList.toggle("off", !sel[sides[r.v].C]);
        r.name.classList.toggle("off", !sel[sides[r.v].P] && !sel[sides[r.v].C]);
      });
    }
    function setTo(names, target) {
      names.forEach(function (n) {
        if (!!sel[n] !== target) chart.dispatchAction({ type: "legendToggleSelect", name: n });
      });
    }
    chart.on("legendselectchanged", function (ev) { sel = ev.selected; paint(); });

    var box = document.createElement("div");
    box.className = "cp-legend";
    venues.forEach(function (v) {
      var row = document.createElement("div");
      row.className = "cp-row";
      function piece(txt, cls, onclick) {
        // Real <button> (reset via .cp CSS in both host pages) so the toggle
        // is keyboard-operable with a :focus-visible ring; behavior unchanged.
        var el = document.createElement("button");
        el.type = "button";
        el.className = "cp " + cls;
        el.textContent = txt;
        el.onclick = onclick;
        row.appendChild(el);
        return el;
      }
      var p = piece("(p)", "cp-p", function () { setTo([sides[v].P], !sel[sides[v].P]); });
      row.appendChild(document.createTextNode(" "));
      var name = piece(v, "cp-v", function () {
        setTo([sides[v].P, sides[v].C], !(sel[sides[v].P] && sel[sides[v].C]));
      });
      row.appendChild(document.createTextNode(" "));
      var c = piece("(c)", "cp-c", function () { setTo([sides[v].C], !sel[sides[v].C]); });
      rows.push({ v: v, p: p, c: c, name: name });
      box.appendChild(row);
    });
    card.appendChild(box);
  }
};

// ---- one chart card ---------------------------------------------------
var charts = []; // live echarts instances, for resize

// Universal viewport-aware tooltip position (ruling: overlays never clip
// at the viewport). confine:true only pins the tooltip inside the CHART
// CONTAINER -- a bottom-row container extends below the fold, so a
// confined tooltip still clips (owner review round 5). JSON payloads
// cannot carry functions, so the render layer owns this policy for
// every chart: right/below the pointer by default, flipping left/above
// when the viewport edge is near.
function tooltipPosition(container) {
  return function (point, params, dom, rect, size) {
    var margin = 16;
    var view = size.viewSize, tip = size.contentSize;
    var x = point[0] + margin;
    if (x + tip[0] > view[0]) x = Math.max(0, point[0] - tip[0] - margin);
    var y = point[1] + margin;
    var top = container.getBoundingClientRect().top;
    if (top + y + tip[1] > window.innerHeight) {
      y = point[1] - tip[1] - margin; // flip above the pointer
      // pathological case (huge tooltip near the fold): clamp on-screen
      if (top + y < 0) y = Math.max(-top, window.innerHeight - top - tip[1] - 2);
    }
    return [x, y];
  };
}

function errCard(key, msg) {
  var card = document.createElement("div");
  card.className = "card err";
  // Node-built, not innerHTML: `key` is a KV-sourced string (M8-12 / SBI
  // C4). Same DOM as before -- .card-head > .key, then .msg.
  var head = document.createElement("div");
  head.className = "card-head";
  var keySpan = document.createElement("span");
  keySpan.className = "key";
  keySpan.textContent = key;
  head.appendChild(keySpan);
  card.appendChild(head);
  var msgEl = document.createElement("div");
  msgEl.className = "msg";
  msgEl.textContent = msg;
  card.appendChild(msgEl);
  return card;
}

// Static "<dot> cls · ttl Ns" badge content, built as nodes rather than
// innerHTML because ttl_hint_s is a KV value (M8-12 / SBI C4). Clears
// first so it is safe to re-fill (preview.html's tab swap re-runs it).
// The dot span carries the staleness class; the text is one text node,
// with a literal middot -- byte-identical to the old '&middot;' markup.
function fillStaticBadge(badge, cls, ttlSec) {
  while (badge.firstChild) badge.removeChild(badge.firstChild);
  var dot = document.createElement("span");
  dot.className = "dot " + cls;
  badge.appendChild(dot);
  badge.appendChild(document.createTextNode(cls + " · ttl " + ttlSec + "s"));
}

// Instantiate ONE chart div+echarts from an envelope, applying the
// meta-declared renderer hooks and the universal never-clip tooltip.
// The div is NOT appended here (the caller places it); echarts.init runs
// on the detached div, so the caller must chart.resize() once it is in
// layout. legendHost is where a legend_widget attaches its HTML: the card
// for a solo chart, or (default, when null) the chart div itself for a
// tabbed member, so the floating widget hides with its tab. Pushes onto
// `charts` for window-resize. Returns { div, chart }.
function buildChartInstance(env, key, meta, legendHost) {
  var div = document.createElement("div");
  div.className = "chart";
  if (meta && meta.height) div.style.height = meta.height + "px";
  var host = legendHost || div; // grouped members host the widget on their div

  // Built-in DARK THEME: professionally tuned text/legend/axis colors
  // for dark surfaces (bright active legend entries, dim inactive --
  // the light-theme defaults invert that on our background). Specs set
  // backgroundColor transparent so the card surface shows through.
  var chart = echarts.init(div, "dark");
  chart.setOption(env.payload); // verbatim -- payload IS the contract...
  // ...except the meta-declared renderer hooks (chart_specs.rb header)
  // and the universal never-clip tooltip policy above (render-layer
  // behavior, like the dark theme -- not a per-chart option).
  // confine:false is REQUIRED here: ECharts applies confine AFTER the
  // position callback and would clamp a flipped tooltip back into the
  // (below-the-fold) container -- the callback owns containment now.
  chart.setOption({ tooltip: { position: tooltipPosition(div), confine: false } });
  if (meta && meta.tooltip_formatter && FORMATTERS[meta.tooltip_formatter]) {
    chart.setOption({ tooltip: { formatter: FORMATTERS[meta.tooltip_formatter] } });
  }
  if (meta && meta.legend_widget && WIDGETS[meta.legend_widget]) {
    WIDGETS[meta.legend_widget](host, chart, env.payload);
  }
  charts.push(chart);
  return { div: div, chart: chart };
}

// Point a badge at an envelope's staleness, compatible with BOTH host
// pages (M6-4 tab swap): index.html rewrites the badge to a ticking
// dot+age keyed off data-generated-at/data-ttl, preview.html keeps the
// static "green · ttl Ns" text. Detect which shape is present: if a
// .age span exists (index's ticker structure) only refresh the dot +
// data attributes (the page's 1 s ticker owns the age text); otherwise
// rewrite the static text. Always sets the data attributes so the
// ticker follows whichever tab is visible.
function setBadge(badge, env) {
  var cls = staleClass(env.generated_at, env.ttl_hint_s);
  badge.setAttribute("data-generated-at", env.generated_at);
  badge.setAttribute("data-ttl", env.ttl_hint_s);
  var age = badge.querySelector(".age");
  if (age) {
    var dot = badge.querySelector(".dot");
    if (dot) dot.className = "dot " + cls; // instant; age caught up by the ticker
  } else {
    fillStaticBadge(badge, cls, env.ttl_hint_s);
  }
}

// Live tab-groups, keyed by meta.tab_group (M6-4). One entry per shared
// card: its head chrome (title/badge/bubble), the tab bar, and every
// member { pos, label, key, env, meta, div, chart, btn }. Fresh per page
// load (module-scope, like `charts`).
var GROUPS = {};

// Show one member of a tab group: reveal its chart div (and RESIZE it --
// a div init'd while display:none renders 0x0 until told its real size),
// hide the rest, light its tab button, and swap the shared card's title,
// hover bubble and staleness badge to that member's envelope. Called on
// every attach (lowest tab_pos wins the default) and on every tab click.
function activateGroup(g, member) {
  g.active = member;
  g.members.forEach(function (m) {
    var on = m === member;
    m.div.style.display = on ? "" : "none";
    m.btn.classList.toggle("active", on);
    m.btn.setAttribute("aria-selected", on ? "true" : "false");
    // every tab stays naturally focusable (the .sortbtn convention);
    // roving tabindex would need arrow-key handlers this page doesn't
    // have, leaving the inactive tab keyboard-unreachable
  });
  g.card.dataset.key = member.key;   // reflect the visible key
  g.keySpan.textContent = member.key; // owner always sees which key this is
  var nb = buildBubble(member.meta);  // swap the hover help to this tab
  while (g.bubble.firstChild) g.bubble.removeChild(g.bubble.firstChild);
  while (nb.firstChild) g.bubble.appendChild(nb.firstChild);
  setBadge(g.badge, member.env);      // staleness follows the visible tab
  requestAnimationFrame(function () { member.chart.resize(); });
}

// Build (or extend) a tab-group card (M6-4, owner ruling D7-c). The
// FIRST group member seen builds the shared card -- head with title, ⓘ,
// a [BTC][MSTR] tab bar and the badge, plus the hover bubble; every
// member (including the first) attaches its own hidden chart div and a
// tab button inserted at its tab_pos. Returns the SAME card element for
// every member of the group -- the caller MUST NOT re-append it once it
// is connected (that would MOVE the card and break the 2x2 grid order).
function buildGroupedCard(env, key, meta, groupId) {
  var g = GROUPS[groupId];
  if (!g) {
    var card = document.createElement("div");
    card.className = "card";
    var head = document.createElement("div");
    head.className = "card-head";
    var keySpan = document.createElement("span");
    keySpan.className = "key hover"; // group members always carry meta
    head.appendChild(keySpan);
    var info = document.createElement("span");
    info.className = "info hover";
    info.textContent = "ⓘ";
    info.tabIndex = 0; // keyboard-reachable: focus opens the bubble
    head.appendChild(info);
    var tabbar = document.createElement("span");
    tabbar.className = "tabbar";
    tabbar.setAttribute("role", "tablist");
    tabbar.setAttribute("aria-label", "chart variant");
    head.appendChild(tabbar);
    var badge = document.createElement("span");
    badge.className = "badge";
    head.appendChild(badge);
    card.appendChild(head);
    var bubble = document.createElement("div");
    bubble.className = "bubble";
    card.appendChild(bubble);
    // Flip the bubble upward when its default position would clip at the
    // viewport bottom (owner review round 5). Identical to the solo card.
    function orient() {
      requestAnimationFrame(function () {
        if (!bubble.getBoundingClientRect().height) return;
        bubble.classList.remove("up");
        if (bubble.getBoundingClientRect().bottom > window.innerHeight) {
          bubble.classList.add("up");
        }
      });
    }
    head.addEventListener("mouseover", orient);
    head.addEventListener("focusin", orient);
    g = GROUPS[groupId] = { card: card, keySpan: keySpan, tabbar: tabbar,
                            badge: badge, bubble: bubble, members: [], active: null };
  }

  // Each member owns its chart div (hidden until its tab is active) and a
  // legend widget attached to that div, so a floating widget hides with
  // its tab (a solo chart attaches the widget to the whole card).
  var inst = buildChartInstance(env, key, meta, null);
  inst.div.style.display = "none";
  g.card.appendChild(inst.div);
  var member = { pos: meta.tab_pos == null ? 99 : meta.tab_pos,
                 label: meta.tab_label || (env.key || key),
                 key: env.key || key, env: env, meta: meta,
                 div: inst.div, chart: inst.chart };
  var btn = document.createElement("button");
  btn.type = "button";
  btn.className = "tabbtn";
  btn.setAttribute("role", "tab");
  btn.textContent = member.label;
  btn.addEventListener("click", function () { activateGroup(g, member); });
  member.btn = btn;
  g.members.push(member);

  // Re-order the tab bar by tab_pos (buttons arrive in load order, which
  // the alphabetical index makes MSTR-before-BTC) and default the visible
  // tab to the lowest tab_pos -- BTC leads (owner ruling D7-c).
  g.members.sort(function (a, b) { return a.pos - b.pos; });
  while (g.tabbar.firstChild) g.tabbar.removeChild(g.tabbar.firstChild);
  g.members.forEach(function (m) { g.tabbar.appendChild(m.btn); });
  activateGroup(g, g.members[0]);
  return g.card;
}

// Build a chart card from an already-fetched envelope. Returns the card
// element; the caller appends it to the document IN THE SAME TASK (the
// rAF below then sizes the chart once layout exists -- echarts.init ran
// while the card was detached, i.e. 0x0). The created echarts instance
// is pushed onto `charts` for window-resize handling. Throws on a bad
// payload -- the caller wraps this and shows errCard on failure.
// A chart whose meta declares a tab_group (M6-4) shares ONE card with
// its group siblings; buildGroupedCard returns the SAME (possibly
// already-connected) card for each member -- the caller guards its
// append accordingly.
function buildChartCard(env, key) {
  var meta = env.meta || null;
  if (meta && meta.tab_group) return buildGroupedCard(env, key, meta, meta.tab_group);

  var card = document.createElement("div");
  card.className = "card";
  card.dataset.key = env.key || key; // pages locate specific cards by key
  var badgeCls = staleClass(env.generated_at, env.ttl_hint_s);
  var head = document.createElement("div");
  head.className = "card-head";

  // title + ⓘ both trigger the instant structured bubble (built from
  // meta); no meta means no bubble and no hover affordance.
  var keySpan = document.createElement("span");
  keySpan.className = "key" + (meta ? " hover" : "");
  keySpan.textContent = env.key || key;
  head.appendChild(keySpan);
  if (meta) {
    var info = document.createElement("span");
    info.className = "info hover";
    info.textContent = "ⓘ"; // ⓘ
    info.tabIndex = 0; // keyboard-reachable: focus opens the bubble (.hover:focus rule)
    head.appendChild(info);
  }
  var badge = document.createElement("span");
  badge.className = "badge";
  fillStaticBadge(badge, badgeCls, env.ttl_hint_s);
  head.appendChild(badge);

  card.appendChild(head);
  if (meta) {
    var bubble = buildBubble(meta);
    card.appendChild(bubble);
    // Flip the bubble upward when its default below-the-head position
    // would clip at the viewport bottom (owner review round 5: bottom-
    // row bubbles were cut). CSS owns show/hide; this only picks the
    // side once the bubble is measurable.
    function orient() {
      requestAnimationFrame(function () {
        if (!bubble.getBoundingClientRect().height) return; // not shown
        bubble.classList.remove("up");
        if (bubble.getBoundingClientRect().bottom > window.innerHeight) {
          bubble.classList.add("up");
        }
      });
    }
    // mouseover (not mouseenter): the CSS trigger is hover on the .hover
    // CHILDREN, and mouseover re-fires when the pointer moves onto them
    head.addEventListener("mouseover", orient);
    head.addEventListener("focusin", orient);
  }
  var inst = buildChartInstance(env, key, meta, card);
  card.appendChild(inst.div);
  requestAnimationFrame(function () { inst.chart.resize(); });
  return card;
}

// ---- shared one-line header (owner ruling 2026-07-06: unified view) ----
// Title left, dot-only liveness cluster right-aligned, pub/fresh slot.
// Dots are real buttons; the key@HH:MM text lives in the shared bubble
// element (hover OR keyboard focus -- a11y floor), which the page anchors
// to the header's right edge so it can never clip at the viewport.
// Lives HERE so index.html and preview.html cannot drift apart.
// o = { chipsEl, bubbleEl, pubEl, idx (index envelope) }.
// Returns the chart keys in index order.
function liveHeader(o) {
  var rows = (o.idx.payload && o.idx.payload.keys) || [];
  var idxTtl = o.idx.ttl_hint_s;
  var green = 0, newestMs = 0;
  function tally(gen) {
    if (staleClass(gen, idxTtl) === "green") green += 1;
    var t = new Date(gen).getTime();
    if (t > newestMs) newestMs = t;
  }
  function show(text) { o.bubbleEl.textContent = text; o.bubbleEl.style.display = "block"; }
  function hide() { o.bubbleEl.style.display = "none"; }
  rows.forEach(function (row) {
    tally(row.generated_at);
    var label = row.key + "@" + hhmm(row.generated_at);
    var dot = document.createElement("button");
    dot.type = "button";
    dot.className = "ldot " + staleClass(row.generated_at, idxTtl);
    dot.setAttribute("aria-label", label);
    dot.addEventListener("mouseenter", function () { show(label); });
    dot.addEventListener("mouseleave", hide);
    dot.addEventListener("focus", function () { show(label); });
    dot.addEventListener("blur", hide);
    o.chipsEl.appendChild(dot);
  });
  tally(o.idx.generated_at); // the index envelope itself is the last key
  var when = newestMs ? hhmm(new Date(newestMs).toISOString()) : "--:--";
  o.pubEl.textContent = "pub " + when + "Z · " + green + "/" + (rows.length + 1) + " fresh";
  var keys = rows.filter(function (r) { return r.key.indexOf("chart:") === 0; })
                 .map(function (r) { return r.key; });
  return keys.slice().sort(function (a, b) { return cardRank(a) - cardRank(b); });
}

// Card placement (owner ruling 2026-08-10): 3x2 grid, row 1 GEX ·
// Volatility · Vol-Spread (top-right, by the GEX profile), row 2
// Scenario · LPPL · BTCo. A tab-group's card is created by its FIRST
// key in iteration order, so every group member ranks with its group.
// Unknown keys keep index order after the known ones (fail-open for
// future charts).
var CARD_ORDER = ["chart:gex_profile", "chart:gex_mstr", "chart:gex_trend",
                  "chart:vol_surface", "chart:vol_basis",
                  "chart:vol_spread",
                  "chart:scenario_strip", "chart:lppl_regime", "chart:btco_table"];
function cardRank(key) {
  var i = CARD_ORDER.indexOf(key);
  return i === -1 ? CARD_ORDER.length : i;
}

// ---- BTCo universe table (M4-7; shared 2026-07-06, unified view) ------
// The literal sortable table, rendered from the v1:btco:latest suite
// envelope (raw payload, not a chart spec). Vanilla column sort; numbers
// stay in the payload's own units. Lives HERE so index.html and
// preview.html render the identical table.
function fmtInt(v) { return v == null ? null : Number(v).toLocaleString("en-US"); }
function fmt2(v)   { return v == null ? null : Number(v).toFixed(2); }
function fmtStr(v) { return (v == null || v === "") ? null : String(v); }

// key: payload field; type: sort/align kind; fmt: cell text (null -> dim --).
var BTCO_COLS = [
  { key: "ticker",    label: "ticker",   type: "str", fmt: fmtStr },
  { key: "btc",       label: "BTC held", type: "num", fmt: fmtInt },
  { key: "mnav",      label: "mNAV",     type: "num", fmt: fmt2 },
  { key: "net_mnav",  label: "netNAV",   type: "num", fmt: fmt2 },
  { key: "leverage",  label: "leverage", type: "num", fmt: fmt2 },
  { key: "btc_as_of", label: "as of",    type: "str", fmt: fmtStr }
];

// Ticker cell: symbol + carried flags (STALE red, placeholder * amber),
// in btco.rb's order (STALE then *); flag glyphs are their own spans so
// only the flag text takes the colour, the symbol stays normal.
function fillTicker(td, r) {
  td.appendChild(document.createTextNode(r.ticker || "--"));
  if (r.stale)       { var s = document.createElement("span"); s.className = "fl-st"; s.textContent = " STALE"; td.appendChild(s); }
  if (r.placeholder) { var p = document.createElement("span"); p.className = "fl-ph"; p.textContent = " *";    td.appendChild(p); }
}

// The whole table: header buttons flip/choose the sort, render() rebuilds
// tbody from the kept `data` array. Nulls always sort last (both dirs);
// default is BTC held descending, matching the chart.
function buildBtcoTable(companies) {
  var data = companies.slice();
  var sortKey = "btc", sortDir = -1;             // default: BTC held desc
  var table = document.createElement("table");
  table.className = "btco";
  var htr = document.createElement("tr");
  BTCO_COLS.forEach(function (col) {
    var th = document.createElement("th");
    th.className = col.key === "ticker" ? "tick" : "num";
    var btn = document.createElement("button");
    btn.type = "button"; btn.className = "sortbtn"; btn.textContent = col.label;
    btn.onclick = function () {
      if (sortKey === col.key) sortDir = -sortDir;
      else { sortKey = col.key; sortDir = col.type === "num" ? -1 : 1; }
      render();
    };
    col._th = th; col._btn = btn;
    th.appendChild(btn); htr.appendChild(th);
  });
  var thead = document.createElement("thead"); thead.appendChild(htr);
  var tbody = document.createElement("tbody");
  table.appendChild(thead); table.appendChild(tbody);

  function render() {
    var col = BTCO_COLS.filter(function (c) { return c.key === sortKey; })[0];
    var sorted = data.slice().sort(function (a, b) {
      var av = a[sortKey], bv = b[sortKey];
      var an = (av == null || av === ""), bn = (bv == null || bv === "");
      if (an && bn) return 0;
      if (an) return 1;                          // nulls last, either dir
      if (bn) return -1;
      var c = col.type === "num" ? (av - bv)
            : (String(av) < String(bv) ? -1 : String(av) > String(bv) ? 1 : 0);
      return c * sortDir;
    });
    BTCO_COLS.forEach(function (c) {
      var active = c.key === sortKey;
      c._btn.className = "sortbtn" + (active ? " active" : "");
      c._th.setAttribute("aria-sort", active ? (sortDir < 0 ? "descending" : "ascending") : "none");
    });
    tbody.innerHTML = "";
    sorted.forEach(function (r) {
      var tr = document.createElement("tr");
      BTCO_COLS.forEach(function (c) {
        var td = document.createElement("td");
        td.className = c.key === "ticker" ? "tick" : "num";
        if (c.key === "ticker") { fillTicker(td, r); }
        else {
          var f = c.fmt(r[c.key]);
          if (f == null) td.innerHTML = '<span class="dim">--</span>';
          else td.textContent = f;
        }
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });
  }
  render();
  return table;
}

// In-quadrant attach (owner ruling, round 5): the table lives INSIDE the
// chart:btco_table card -- shrink that card's chart to 290px and append
// the table below it. Returns true if the card was found (else the
// caller renders its own fallback).
function attachBtcoTable(gridEl, env) {
  var host = gridEl.querySelector('[data-key="chart:btco_table"]');
  if (!host) return false;
  var div = host.querySelector(".chart");
  div.style.height = "290px";
  var inst = echarts.getInstanceByDom(div);
  if (inst) inst.resize();
  host.appendChild(buildBtcoTable((env.payload && env.payload.companies) || []));
  return true;
}

// ---- M8-13 auto-refresh seams -------------------------------------------
// Re-fetch cadence for a key: the payload's own ttl_hint_s, clamped to a
// hard 60s floor so no key can ever storm the Worker. A missing/NaN/short
// ttl also floors to 60s. Returns MILLISECONDS for setTimeout. Pure -- the
// only unit-tested piece of the refresh loop (page.html owns the DOM timer,
// exercised in preview).
function nextDelay(ttlSec) {
  var t = Number(ttlSec);
  if (!isFinite(t) || t < 60) t = 60;
  return t * 1000;
}

// Dispose every echarts instance rendered inside `card` and drop it from
// the resize registry (mutated in place so MimirRender.charts stays the
// same array). Called before a refresh swaps a card out, so stale
// instances neither leak nor keep answering window-resize.
function releaseCard(card) {
  for (var i = charts.length - 1; i >= 0; i -= 1) {
    var dom = charts[i].getDom && charts[i].getDom();
    if (dom && card.contains(dom)) { charts[i].dispose(); charts.splice(i, 1); }
  }
}

// Forget a tab-group so its shared card can be rebuilt from scratch on
// refresh (GROUPS state is otherwise per-page-load and would accrue
// duplicate members). Pair with releaseCard on the old card element.
function forgetGroup(groupId) {
  if (GROUPS[groupId]) delete GROUPS[groupId];
}

// ONE global -- shared by preview.html and index.html.
// rev: bump on EVERY render.js change; `MimirRender.rev` in the console
// answers "which renderer is this tab actually running?" after deploys.
window.MimirRender = {
  rev: "m8-13-autorefresh",
  staleClass: staleClass,
  hhmm: hhmm,
  liveHeader: liveHeader,
  buildBtcoTable: buildBtcoTable,
  attachBtcoTable: attachBtcoTable,
  buildBubble: buildBubble,
  errCard: errCard,
  buildChartCard: buildChartCard,
  nextDelay: nextDelay,
  releaseCard: releaseCard,
  forgetGroup: forgetGroup,
  charts: charts,
  FORMATTERS: FORMATTERS,
  WIDGETS: WIDGETS
};
