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

function errCard(key, msg) {
  var card = document.createElement("div");
  card.className = "card err";
  card.innerHTML = '<div class="card-head"><span class="key">' + key + '</span></div>' +
                   '<div class="msg"></div>';
  card.querySelector(".msg").textContent = msg;
  return card;
}

// Build a chart card from an already-fetched envelope. Returns the card
// element; the caller appends it to the document IN THE SAME TASK (the
// rAF below then sizes the chart once layout exists -- echarts.init ran
// while the card was detached, i.e. 0x0). The created echarts instance
// is pushed onto `charts` for window-resize handling. Throws on a bad
// payload -- the caller wraps this and shows errCard on failure.
function buildChartCard(env, key) {
  var card = document.createElement("div");
  card.className = "card";
  var badgeCls = staleClass(env.generated_at, env.ttl_hint_s);
  var meta = env.meta || null;
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
    info.tabIndex = 0; // keyboard-reachable: focus opens the bubble (card-head :focus-within)
    head.appendChild(info);
  }
  var badge = document.createElement("span");
  badge.className = "badge";
  badge.innerHTML = '<span class="dot ' + badgeCls + '"></span>' +
    badgeCls + ' &middot; ttl ' + env.ttl_hint_s + 's';
  head.appendChild(badge);

  var div = document.createElement("div");
  div.className = "chart";
  if (meta && meta.height) div.style.height = meta.height + "px";
  card.appendChild(head);
  if (meta) card.appendChild(buildBubble(meta));
  card.appendChild(div);

  // Built-in DARK THEME: professionally tuned text/legend/axis colors
  // for dark surfaces (bright active legend entries, dim inactive --
  // the light-theme defaults invert that on our background). Specs set
  // backgroundColor transparent so the card surface shows through.
  var chart = echarts.init(div, "dark");
  chart.setOption(env.payload); // verbatim -- payload IS the contract...
  // ...except the meta-declared renderer hooks (chart_specs.rb header)
  if (meta && meta.tooltip_formatter && FORMATTERS[meta.tooltip_formatter]) {
    chart.setOption({ tooltip: { formatter: FORMATTERS[meta.tooltip_formatter] } });
  }
  if (meta && meta.legend_widget && WIDGETS[meta.legend_widget]) {
    WIDGETS[meta.legend_widget](card, chart, env.payload);
  }
  charts.push(chart);
  requestAnimationFrame(function () { chart.resize(); });
  return card;
}

// ONE global -- shared by preview.html and the future index.html.
window.MimirRender = {
  staleClass: staleClass,
  hhmm: hhmm,
  buildBubble: buildBubble,
  errCard: errCard,
  buildChartCard: buildChartCard,
  charts: charts,
  FORMATTERS: FORMATTERS,
  WIDGETS: WIDGETS
};
