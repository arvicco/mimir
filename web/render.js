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

// Staleness class from age vs ttl (owner ruling 2026-08-18): <=ttl green,
// <=2x amber (yellow), <=3x orange, else red. Publishing stamps every key
// bi-hourly with ttl_hint_s 3600, so the dot reads: green the first hour
// after a publish tick, yellow the second, orange the third, red past 3h.
function staleClass(generatedAt, ttlSec) {
  var age = (Date.now() - new Date(generatedAt).getTime()) / 1000;
  if (age <= ttlSec) return "green";
  if (age <= ttlSec * 2) return "amber";
  if (age <= ttlSec * 3) return "orange";
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
  },

  // lppl_shadow (M9-13; labels M11-6): the SHADOW tab's per-row hover. The
  // row's stat name (bold), then "ref <val> -> now <val>  <verdict>" (since
  // the 2026-08-29 rulings the columns mean reference -> operative), then the
  // owner-approved plain-language paragraph -- all carried IN the option
  // on the row's `stat`-column datum (renderer stays dumb; payload stays
  // JSON). Axis trigger hands us every series at the hovered row; we pull
  // the one datum that carries `explanation`. Wrapped so a long paragraph
  // never runs off the screen (the universal position callback then keeps
  // the whole block inside the viewport).
  lppl_shadow: function (params) {
    if (!params || !params.length) return "";
    var d = null;
    for (var i = 0; i < params.length; i += 1) {
      if (params[i].data && params[i].data.explanation) { d = params[i].data; break; }
    }
    if (!d) return "";
    function esc(s) {
      return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    var A = "#e6a23c", dim = "#9aa0a6";
    var line = '<span style="color:' + dim + '">ref</span> ' + esc(d.frozen) +
               ' <span style="color:' + A + '">&rarr;</span> ' +
               '<span style="color:' + dim + '">now</span> ' + esc(d.shadow) +
               '  <b>' + esc(d.verdict) + "</b>";
    return '<div style="max-width:320px;white-space:normal;line-height:1.5">' +
           "<b>" + esc(d.title) + "</b><br>" + line +
           '<div style="margin-top:6px;color:#c7ccd1">' + esc(d.explanation) + "</div></div>";
  },

  // scorecard_row (M10-7): the scorecard matrix's per-row hover. Axis trigger
  // hands us every column datum at the hovered row; the row-label datum carries
  // a `hover` block (title, kind, per-horizon cells, a plain-language note) --
  // the renderer only reads it, exactly like lppl_shadow. Renders the bold row
  // label, one line per horizon (mean teal up / red down, then hit rate + the
  // honest n_eff), and the sentence. Wrapped so a long note stays on screen.
  scorecard_row: function (params) {
    if (!params || !params.length) return "";
    var d = null;
    for (var i = 0; i < params.length; i += 1) {
      if (params[i].data && params[i].data.hover) { d = params[i].data.hover; break; }
    }
    if (!d) return "";
    function esc(s) {
      return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }
    var G = "#2fbf8f", R = "#ef6b6b", dim = "#8a93a0";
    function span(c, t) { return '<span style="color:' + c + '">' + t + "</span>"; }
    var lines = ["7", "30", "90"].map(function (h) {
      var c = (d.cells && d.cells[h]) || {};
      if (c.eligible) {
        var col = Number(c.mean_pct) < 0 ? R : G;
        var mean = (Number(c.mean_pct) >= 0 ? "+" : "") + c.mean_pct + "%";
        return h + "d: " + span(col, mean) + " · " + esc(c.pos_pct + "% up") +
               " · " + span(dim, "n" + c.n + " (n_eff " + c.n_eff + ")");
      }
      return h + "d: " + span(dim, "-- " + esc(c.reason || "ineligible") +
                                  (c.n != null ? " (n" + c.n + ")" : ""));
    });
    var head = "<b>" + esc(d.title) + "</b>" + (d.kind === "all" ? span(dim, " · ALL") : "");
    return '<div style="max-width:340px;white-space:normal;line-height:1.5">' +
           head + "<br>" + lines.join("<br>") +
           '<div style="margin-top:6px;color:#c7ccd1">' + esc(d.note) + "</div></div>";
  }
};

// ---- renderer legend-widget registry ------------------------------------
// Sanctioned deviation #2 (chart_specs.rb header, owner review round 4):
// meta.legend_widget names a builder here that replaces the chart's drawn
// legend (the spec ships legend.show=false but keeps legend.data, so
// ECharts still owns selection state and the widget drives it via legend
// actions). Unknown names simply render no widget.
var WIDGETS = {
  // gex_cp: one compact toggle per venue -- "(p) DERI (c)". Clicking (p) or
  // (c) toggles that side's series alone; clicking the venue name toggles
  // both together (both shown -> both hidden, anything else -> both shown).
  //
  // M8-18 R3 (owner ruling 2026-08-10): the widget sits at the TOP-RIGHT of
  // the BTC GEX chart (an owner-ruled EXCEPTION to "side panels go right"),
  // laid out as a FIXED 2x3 grid -- row 1 IBIT FBTC BITB, row 2 DERI ARKB GBTC.
  // A venue absent from the payload (filtered as insignificant) leaves its
  // slot collapsed; rows stay in order. The venue universe is exactly these
  // six (Deribit + the five US spot-ETF chains), so nothing is ever dropped.
  gex_cp: function (card, chart, option, meta) {
    var ORDER = [["IBIT", "FBTC", "BITB"], ["DERI", "ARKB", "GBTC"]];
    var terms = (meta && meta.terms) || {}; // M9-15: per-venue CSS bubbles
    var sides = {}; // venue LABEL (may carry a stale '!') -> {C, P} series names
    (option.series || []).forEach(function (s) {
      var m = /^(.*) ([CP])$/.exec(s.name || "");
      if (!m) return;
      if (!sides[m[1]]) sides[m[1]] = {};
      sides[m[1]][m[2]] = s.name;
    });
    var labels = Object.keys(sides);
    if (!labels.length) return;
    // resolve a fixed slot to the actual present label -- a stale 'DERI!'
    // still fills the DERI slot (base match); absent venues resolve to null.
    function resolve(slot) {
      if (sides[slot]) return slot;
      for (var i = 0; i < labels.length; i += 1) {
        if (labels[i].replace(/!$/, "") === slot) return labels[i];
      }
      return null;
    }

    var sel = {}; // series start selected; tracked via legendselectchanged
    labels.forEach(function (v) { sel[sides[v].C] = true; sel[sides[v].P] = true; });
    var cells = [];
    function paint() {
      cells.forEach(function (r) {
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
    ORDER.forEach(function (row) {
      var rowEl = document.createElement("div");
      rowEl.className = "cp-row";
      row.forEach(function (slot) {
        var v = resolve(slot);
        if (!v) return; // absent venue -- slot collapses, row keeps its order
        var cell = document.createElement("span");
        cell.className = "cp-cell";
        function piece(txt, cls, onclick) {
          // Real <button> (reset via .cp CSS in both host pages) so the toggle
          // is keyboard-operable with a :focus-visible ring; behavior unchanged.
          var el = document.createElement("button");
          el.type = "button";
          el.className = "cp " + cls;
          el.textContent = txt;
          el.onclick = onclick;
          cell.appendChild(el);
          return el;
        }
        // compact '(p)IBIT(c)' cells (owner round 2026-08-30: the venue
        // toggles must fit ONE row even at 3-column card widths)
        var p = piece("(p)", "cp-p", function () { setTo([sides[v].P], !sel[sides[v].P]); });
        var name = piece(v, "cp-v", function () {
          setTo([sides[v].P, sides[v].C], !(sel[sides[v].P] && sel[sides[v].C]));
        });
        var c = piece("(c)", "cp-c", function () { setTo([sides[v].C], !sel[sides[v].C]); });
        // M9-15 (owner ruling 2026-08-11): the venue label gets an instant CSS
        // bubble (the house hover pattern, never native title=) explaining what
        // the chain is. Keyed by the BASE venue (a stale 'DERI!' still resolves
        // to the DERI text). Text node -- no HTML injection from meta.
        var term = terms[v.replace(/!$/, "")];
        if (term) {
          var bub = document.createElement("span");
          bub.className = "cp-bub";
          bub.textContent = term;
          cell.appendChild(bub);
        }
        cells.push({ v: v, p: p, c: c, name: name });
        rowEl.appendChild(cell);
      });
      box.appendChild(rowEl);
    });
    card.appendChild(box);
  }
};

// ---- glossary terms hook (M9-15, owner ruling 2026-08-11) ---------------
// Sanctioned deviation #6 (chart_specs.rb header): meta.terms = { TERM ->
// explanation } gives hover explanations to abbreviations / module names,
// the SAME styled block as the lppl_shadow tooltip. Render-layer only -- it
// mutates the built option copy (like tooltipPosition / the dark theme); the
// JSON payload and the goldens never change. Surfaces:
//   1. drawn ECharts legends -> legend.tooltip (native), our styled formatter;
//   2. category-axis tick labels that ARE terms (the scenario module
//      scoreboard, canvas) -> triggerEvent on that axis + a viewport-fixed
//      styled popover. ECharts has no native tooltip for a lone axis label,
//      and its axis-trigger tooltip cannot render one label's own text, so the
//      renderer shows the house instant bubble (never a native title=).
//   3. the gex_cp venue widget (HTML) -> a CSS bubble, built in the widget.
// An unknown name gets no tooltip.
function escTerm(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
function termsBlock(term, text) {
  return '<div style="max-width:320px;white-space:normal;line-height:1.5">' +
         "<b>" + escTerm(term) + "</b>" +
         '<div style="margin-top:6px;color:#c7ccd1">' + escTerm(text) + "</div></div>";
}
function termsFormatter(terms) {
  return function (p) {
    var name = p && p.name;
    return (name && terms[name]) ? termsBlock(name, terms[name]) : "";
  };
}

// Attach meta.terms to a built chart. `host` is the chart div (the popover's
// parent). No-op unless meta.terms is present.
function applyTerms(chart, option, meta, host) {
  if (!meta || !meta.terms || !option) return;
  var terms = meta.terms;
  // (1) drawn legend items -- ECharts' own legend.tooltip, our styled block.
  // ONLY when the option already SHOWS a legend: merging a legend object
  // into a legend-less chart CREATES one (default show:true) -- observed
  // 2026-08-11 as a phantom "composite/modules" legend colliding with the
  // scenario title (owner report).
  if (option.legend && option.legend.show !== false) chart.setOption({ legend: { tooltip: {
    show: true, confine: true,
    backgroundColor: "#232933", borderColor: "#3a424e", borderWidth: 1,
    textStyle: { color: "#ccd3dc", fontSize: 12 },
    extraCssText: "border-radius:8px;padding:10px 14px;box-shadow:0 6px 24px rgba(0,0,0,.45);",
    formatter: termsFormatter(terms)
  } } });
  // (2) a category axis whose EVERY tick label is itself a term (the scenario
  // module scoreboard). Nothing else matches -- date/price/tenor axes carry
  // no term labels -- so this fires only where intended.
  ["xAxis", "yAxis"].forEach(function (dim) {
    var axes = option[dim];
    if (!axes) return;
    if (!Array.isArray(axes)) axes = [axes];
    axes.forEach(function (ax, ai) {
      var data = ax && ax.data;
      if (!data || !data.length) return;
      if (!data.every(function (v) { return terms[v]; })) return;
      wireAxisTerms(chart, dim, ai, data, terms, host);
    });
  });
}

// Enable label events on the term-carrying axis (render-time triggerEvent,
// index-matched partial merge so the rest of the axis is untouched) and show
// a viewport-fixed styled popover on a label hover. position:fixed + the
// event's clientX/Y keeps the never-clip math in viewport space; the popover
// is pointer-events:none so it never steals the hover.
function wireAxisTerms(chart, dim, axisIndex, data, terms, host) {
  var patch = [];
  for (var i = 0; i <= axisIndex; i += 1) patch.push({});
  patch[axisIndex] = { triggerEvent: true };
  var opt = {}; opt[dim] = patch;
  chart.setOption(opt);

  var pop = document.createElement("div");
  pop.className = "terms-pop";
  pop.style.display = "none";
  host.appendChild(pop);

  chart.on("mouseover", function (ev) {
    if (!ev || ev.componentType !== dim) return;
    var name = ev.value;
    if (!terms[name] || data.indexOf(name) < 0) return;
    var oe = ev.event && ev.event.event; // zrender event -> raw DOM event
    var cx = oe ? oe.clientX : 0, cy = oe ? oe.clientY : 0;
    pop.innerHTML = termsBlock(name, terms[name]); // owner-authored, escaped
    pop.style.left = (cx + 14) + "px";
    pop.style.top = (cy + 14) + "px";
    pop.style.display = "block";
    requestAnimationFrame(function () {
      var r = pop.getBoundingClientRect();
      var vw = window.innerWidth || Infinity, vh = window.innerHeight || Infinity;
      if (r.width && r.right > vw) pop.style.left = Math.max(4, cx - r.width - 14) + "px";
      if (r.height && r.bottom > vh) pop.style.top = Math.max(4, cy - r.height - 14) + "px";
    });
  });
  function hide(ev) {
    if (ev && ev.componentType && ev.componentType !== dim) return;
    pop.style.display = "none";
  }
  chart.on("mouseout", hide);
  chart.on("globalout", function () { pop.style.display = "none"; });
}

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

// Display rule (owner ruling 2026-08-10): the chart: prefix is internal
// namespacing -- every user-visible key label drops it.
function dispKey(key) { return String(key).replace(/^chart:/, ""); }

function errCard(key, msg) {
  var card = document.createElement("div");
  card.className = "card err";
  // Node-built, not innerHTML: `key` is a KV-sourced string (M8-12 / SBI
  // C4). Same DOM as before -- .card-head > .key, then .msg.
  var head = document.createElement("div");
  head.className = "card-head";
  var keySpan = document.createElement("span");
  keySpan.className = "key";
  keySpan.textContent = dispKey(key);
  head.appendChild(keySpan);
  card.appendChild(head);
  var msgEl = document.createElement("div");
  msgEl.className = "msg";
  msgEl.textContent = msg;
  card.appendChild(msgEl);
  return card;
}

// M8-18 R6 (owner ruling 2026-08-10): a card badge is now JUST a staleness
// dot -- the '● green · ttl 1800s' text (and the ticking 'age' on index.html)
// was too much. Everything moved to an instant hover/focus bubble (the header
// ldot pattern: dot-only + bubble, owner ruling 2026-07-06). The badge is a
// focusable element carrying data-generated-at/data-ttl; its bubble text is
// built from those attrs ON OPEN so it is always current, right-anchored and
// flip-up so it never clips at the viewport.
//
// makeBadge builds the DOM + wires the on-open text fill ONCE; setBadge points
// it at an envelope (dot class + data attrs); refreshBadge re-evaluates the dot
// from the data attrs alone (the page ticker, which has no envelope).
function makeBadge() {
  var badge = document.createElement("span");
  badge.className = "badge";
  badge.setAttribute("tabindex", "0");      // focusable like the header ldots
  badge.setAttribute("role", "img");
  var dot = document.createElement("span");
  dot.className = "dot";
  badge.appendChild(dot);
  var bubble = document.createElement("span");
  bubble.className = "badge-bubble";
  badge.appendChild(bubble);
  function fill() {
    bubble.textContent = badgeBubbleText(badge); // current at open time
    // flip up when the default below-the-badge position would clip at the
    // viewport bottom (bottom-row cards) -- the orient() pattern.
    requestAnimationFrame(function () {
      bubble.classList.remove("up");
      var r = bubble.getBoundingClientRect();
      if (r.height && r.bottom > window.innerHeight) bubble.classList.add("up");
    });
  }
  badge.addEventListener("mouseenter", fill);
  badge.addEventListener("focus", fill);
  return badge;
}

// "age 3m12s · ttl 1800s · 14:18Z" from a badge's data attrs (built on open).
function badgeBubbleText(badge) {
  var gen = badge.getAttribute("data-generated-at");
  var ttl = Number(badge.getAttribute("data-ttl"));
  var age = (Date.now() - new Date(gen).getTime()) / 1000;
  return "age " + fmtBadgeAge(age) + " · ttl " + ttl + "s · " + hhmm(gen) + "Z";
}

// Compact age: "3m12s" under an hour, "2h 05m" under a day, else "1d 03h".
function fmtBadgeAge(sec) {
  var s = Math.floor(sec < 0 ? 0 : sec);
  function p2(n) { return (n < 10 ? "0" : "") + n; }
  if (s < 3600)  return Math.floor(s / 60) + "m" + p2(s % 60) + "s";
  if (s < 86400) return Math.floor(s / 3600) + "h " + p2(Math.floor((s % 3600) / 60)) + "m";
  return Math.floor(s / 86400) + "d " + p2(Math.floor((s % 86400) / 3600)) + "h";
}

// Re-evaluate a badge's dot class + aria from its own data attrs, and refresh
// an already-populated bubble's text (the page ticker calls this each second;
// it has no envelope). No-op on a badge the renderer has not stamped yet.
function refreshBadge(badge) {
  var gen = badge.getAttribute("data-generated-at");
  if (!gen) return;
  var cls = staleClass(gen, Number(badge.getAttribute("data-ttl")));
  var dot = badge.querySelector(".dot");
  if (dot) dot.className = "dot " + cls;
  badge.setAttribute("aria-label", "data freshness " + cls);
  var bubble = badge.querySelector(".badge-bubble");
  if (bubble && bubble.textContent) bubble.textContent = badgeBubbleText(badge);
}

// Instantiate ONE chart div+echarts from an envelope, applying the
// meta-declared renderer hooks and the universal never-clip tooltip.
// The div is NOT appended here (the caller places it); echarts.init runs
// on the detached div, so the caller must chart.resize() once it is in
// layout. legendHost is where a legend_widget attaches its HTML: the card
// for a solo chart, or (default, when null) the chart div itself for a
// tabbed member, so the floating widget hides with its tab. Pushes onto
// `charts` for window-resize. Returns { div, chart }.
// The option's HEADLINE: the first title entry's text (spec convention --
// entry 0 is the load-bearing one-liner; positional later entries are
// in-canvas notes). 2026-08-30 owner design ruling: this text renders on
// the card/section HEAD LINE, not in the canvas.
function headlineOf(option) {
  var t = option && option.title;
  if (Array.isArray(t)) t = t[0];
  return (t && t.text) || "";
}

function makeHeadline() {
  var el = document.createElement("span");
  el.className = "headline";
  return el;
}

// Fill a headline span, wrapping every meta.terms key found in the text
// as a hover term (owner ruling 2026-08-30: hovering 'flip dist', 'MP \u0394',
// 'ATM 30d'... explains what the number means). Longest keys win ties, the
// leftmost match wins position; matching is text-node based (no HTML
// injection from payload text or term keys). The explanation shows in a
// VIEWPORT-FIXED .terms-pop (the M9-15 axis-popover pattern -- the
// headline is overflow:hidden for ellipsis, so a CSS-child bubble would
// clip); keyboard reaches it via focus, and it is pointer-events:none so
// it never steals the hover.
function fillHeadline(el, text, terms) {
  while (el.firstChild) el.removeChild(el.firstChild);
  var keys = Object.keys(terms || {}).sort(function (a, b) { return b.length - a.length; });
  var rest = String(text || "");
  var pop = null;
  function popover() {
    if (pop) return pop;
    pop = document.createElement("div");
    pop.className = "terms-pop";
    pop.style.display = "none";
    document.body.appendChild(pop);
    return pop;
  }
  function show(term) {
    var r = term.getBoundingClientRect();
    var pp = popover();
    pp.innerHTML = termsBlock(term.dataset.term, terms[term.dataset.term]);
    pp.style.left = r.left + "px";
    pp.style.top = (r.bottom + 6) + "px";
    pp.style.display = "block";
    requestAnimationFrame(function () {
      var pr = pp.getBoundingClientRect();
      var vw = window.innerWidth || Infinity, vh = window.innerHeight || Infinity;
      if (pr.width && pr.right > vw) pp.style.left = Math.max(4, vw - pr.width - 8) + "px";
      if (pr.height && pr.bottom > vh) pp.style.top = Math.max(4, r.top - pr.height - 6) + "px";
    });
  }
  function hide() { if (pop) pop.style.display = "none"; }
  while (rest.length) {
    var best = null, at = -1;
    for (var i = 0; i < keys.length; i += 1) {
      var p = rest.indexOf(keys[i]);
      if (p !== -1 && (at === -1 || p < at)) { at = p; best = keys[i]; }
    }
    if (!best) break;
    if (at > 0) el.appendChild(document.createTextNode(rest.slice(0, at)));
    var t = document.createElement("span");
    t.className = "hl-term";
    t.tabIndex = 0;
    t.dataset.term = best;
    t.appendChild(document.createTextNode(best));
    t.addEventListener("mouseenter", function (ev) { show(ev.currentTarget); });
    t.addEventListener("mouseleave", hide);
    t.addEventListener("focus", function (ev) {
      if (ev.currentTarget.matches(":focus-visible")) show(ev.currentTarget);
    });
    t.addEventListener("blur", hide);
    el.appendChild(t);
    rest = rest.slice(at + best.length);
  }
  if (rest.length) el.appendChild(document.createTextNode(rest));
}

// Collect every named value axis from the option, strip the names from
// the RENDERED chart (index-matched partial merge; the payload is
// untouched), enable label events on those axes, and hover the tick
// numbers to a viewport-fixed house bubble: bold axis name (+ units as
// written in the spec's name) and optional context from
// meta.axis_terms[name]. Same popover mechanics as the scenario
// scoreboard glossary (wireAxisTerms).
function hoistAxisNames(chart, option, meta, host) {
  var axisTerms = (meta && meta.axis_terms) || {};
  var pop = null;
  function popover() {
    if (pop) return pop;
    pop = document.createElement("div");
    pop.className = "terms-pop";
    pop.style.display = "none";
    host.appendChild(pop);
    return pop;
  }
  ["xAxis", "yAxis"].forEach(function (dim) {
    var axes = option[dim];
    if (!axes) return;
    var list = Array.isArray(axes) ? axes : [axes];
    var names = list.map(function (a) { return (a && a.name) || null; });
    if (!names.some(Boolean)) return;
    var patch = list.map(function (a, i) {
      return names[i] ? { name: "", triggerEvent: true } : { triggerEvent: true };
    });
    var opt = {}; opt[dim] = Array.isArray(axes) ? patch : patch[0];
    chart.setOption(opt);
    chart.on("mouseover", function (ev) {
      if (!ev || ev.componentType !== dim || ev.targetType !== "axisLabel") return;
      var name = names[ev.componentIndex || 0];
      if (!name) return;
      var oe = ev.event && ev.event.event;
      var cx = oe ? oe.clientX : 0, cy = oe ? oe.clientY : 0;
      var pp = popover();
      pp.innerHTML = termsBlock(name, axisTerms[name] || "This axis's unit/scale.");
      pp.style.left = (cx + 12) + "px";
      pp.style.top = (cy + 12) + "px";
      pp.style.display = "block";
      requestAnimationFrame(function () {
        var r = pp.getBoundingClientRect();
        var vw = window.innerWidth || Infinity, vh = window.innerHeight || Infinity;
        if (r.width && r.right > vw) pp.style.left = Math.max(4, cx - r.width - 12) + "px";
        if (r.height && r.bottom > vh) pp.style.top = Math.max(4, cy - r.height - 12) + "px";
      });
    });
    chart.on("mouseout", function (ev) {
      if (ev && ev.componentType === dim && pop) pop.style.display = "none";
    });
    chart.on("globalout", function () { if (pop) pop.style.display = "none"; });
  });
}

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
  // 2026-08-30 owner design ruling: the headline lives on the head line;
  // hide the canvas copy (render-layer only -- the payload keeps its
  // title for any consumer of the raw option). Entry 0 only; secondary
  // positional titles (notes/subtitles) stay drawn.
  if (headlineOf(env.payload)) chart.setOption({ title: [{ show: false }] });
  // 2026-08-30 owner round 2: AXIS NAMES leave the canvas too -- the
  // payload keeps them (raw consumers see labelled axes), the renderer
  // strips them and instead shows a hover bubble over the axis NUMBERS:
  // bold axis name + optional context from meta.axis_terms[name].
  hoistAxisNames(chart, env.payload, meta, div);
  if (meta && meta.tooltip_formatter && FORMATTERS[meta.tooltip_formatter]) {
    var fmtTip = { formatter: FORMATTERS[meta.tooltip_formatter] };
    if (meta.tooltip_formatter === "lppl_shadow" ||
        meta.tooltip_formatter === "scorecard_row") {
      // these formatters' blocks are written light-on-dark (house bubble
      // colors); ECharts' default white tooltip made them unreadable
      // (owner report 2026-08-11) -- give them the house dark chrome
      fmtTip.backgroundColor = "#232933";
      fmtTip.borderColor = "#3a424e";
      fmtTip.borderWidth = 1;
      fmtTip.textStyle = { color: "#ccd3dc", fontSize: 12 };
      fmtTip.extraCssText = "border-radius:8px;padding:10px 14px;" +
                            "box-shadow:0 6px 24px rgba(0,0,0,.45);max-width:340px;white-space:normal;";
    }
    chart.setOption({ tooltip: fmtTip });
  }
  if (meta && meta.legend_widget && WIDGETS[meta.legend_widget]) {
    WIDGETS[meta.legend_widget](host, chart, env.payload, meta);
  }
  applyTerms(chart, env.payload, meta, div); // M9-15 glossary hover hook
  charts.push(chart);
  return { div: div, chart: chart };
}

// Point a badge (from makeBadge) at an envelope's staleness -- stamps
// data-generated-at/data-ttl (so the page ticker and the on-open bubble read
// them) and repaints the dot. Shared by BOTH host pages and every tab/stack
// swap; refreshes an already-open bubble so a swap under the pointer stays
// current. Dot-only since M8-18 R6.
function setBadge(badge, env) {
  badge.setAttribute("data-generated-at", env.generated_at);
  badge.setAttribute("data-ttl", env.ttl_hint_s);
  refreshBadge(badge);
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
  g.keySpan.textContent = dispKey(member.key); // owner always sees which key this is
  if (g.headline) fillHeadline(g.headline, headlineOf(member.env.payload), member.meta && member.meta.terms);
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
    var hl = makeHeadline();
    head.appendChild(hl);
    var badge = makeBadge();
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
                            headline: hl, badge: badge, bubble: bubble,
                            members: [], active: null };
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

// Build (or extend) a STACKED group card (owner ruling 2026-08-10:
// vol_surface + vol_basis are "one card, two half-card charts", not
// tabs). Same GROUPS registry and grouping meta as the tab style, but
// members are stacked vertically by tab_pos, each a section with its own
// head (key + ⓘ + badge) above its half-height chart, its own hover
// bubble, and its own envelope's freshness (setBadge stamps
// data-generated-at, so the page ticker drives every section).
//
// M8-17 (owner ruling 2026-08-10): members that SHARE a tab_pos collapse
// into ONE tabbed section -- the vol card's SURFACE half is a [BTC][MSTR]
// tab pair on top, BASIS a plain section below. Each member owns a stable
// chart div + instance; the section chrome around them is rebuilt on every
// add (buildGroupedCard's rebuild idiom), so a late-loading sibling can
// re-form the tab bar. The whole card is rebuilt from all member envelopes
// on refresh (index.html groupUnit + forgetGroup).
function buildStackedCard(env, key, meta, groupId) {
  var g = GROUPS[groupId];
  if (!g) {
    var card = document.createElement("div");
    card.className = "card";
    g = GROUPS[groupId] = { card: card, members: [], active: null, stacked: true };
  }

  var inst = buildChartInstance(env, key, meta, null);
  g.members.push({ pos: meta.tab_pos == null ? 99 : meta.tab_pos,
                   key: env.key || key, env: env, meta: meta,
                   chartDiv: inst.div, chart: inst.chart });
  rebuildStack(g);
  return g.card;
}

// (Re)build a stacked card's sections from its members: bucket by tab_pos
// (ascending vertical order), each bucket becoming ONE section. A bucket
// with a single member is a plain section; a bucket with several (a shared
// tab_pos, M8-17) is a tabbed section, its members ordered by CARD_ORDER
// rank so BTC (lower rank) leads. Chart divs/instances are reused (moved,
// not recreated) so echarts survives; a rAF resize re-fits them once placed.
//
// LINKED TABS (owner ruling 2026-08-29, the GEX card): when SEVERAL
// tabbed sections carry IDENTICAL label sequences ([BTC][MSTR] over
// [BTC][MSTR]), one switcher drives them all -- only the TOP linked
// section renders the tab bar, and a click activates the same label in
// every linked section (profile + its trend flip together). Sections
// whose labels differ keep their own bars, so the vol card's lone
// tabbed section is untouched.
function rebuildStack(g) {
  var byPos = {}, order = [];
  g.members.forEach(function (m) {
    if (!byPos[m.pos]) { byPos[m.pos] = []; order.push(m.pos); }
    byPos[m.pos].push(m);
  });
  order.sort(function (a, b) { return a - b; });

  var rank = function (a, b) { return cardRank(a.key) - cardRank(b.key); };
  var sig = function (pos) {
    return byPos[pos].slice().sort(rank)
      .map(function (m) { return m.meta.tab_label || m.key; }).join("|");
  };
  var tabbedPos = order.filter(function (pos) { return byPos[pos].length > 1; });
  var link = null;
  if (tabbedPos.length > 1 &&
      tabbedPos.every(function (pos) { return sig(pos) === sig(tabbedPos[0]); })) {
    var fns = [];
    link = { leaderPos: tabbedPos[0],
             register: function (f) { fns.push(f); },
             activateAll: function (i) { fns.forEach(function (f) { f(i); }); } };
  }

  while (g.card.firstChild) g.card.removeChild(g.card.firstChild);
  var firstKey = null;
  order.forEach(function (pos, i) {
    var ms = byPos[pos].slice().sort(rank);
    if (i === 0) firstKey = ms[0].key;
    var lk = link && ms.length > 1 ?
      { leader: pos === link.leaderPos, register: link.register,
        activateAll: link.activateAll } : null;
    g.card.appendChild(ms.length > 1 ? tabbedStackSection(ms, lk) : plainStackSection(ms[0]));
  });
  g.card.dataset.key = firstKey;
  g.members.forEach(function (m) { requestAnimationFrame(function () { m.chart.resize(); }); });
}

// One stacked-section shell: a head (key.hover + ⓘ [+ tab bar] + badge)
// over a hover bubble, with the viewport-flip orient wiring. The caller
// fills the key/bubble/badge and appends the chart div(s).
function stackShell(withTabbar) {
  var section = document.createElement("div");
  section.className = "stacksec";
  var head = document.createElement("div");
  head.className = "card-head";
  var keySpan = document.createElement("span");
  keySpan.className = "key hover";
  head.appendChild(keySpan);
  var info = document.createElement("span");
  info.className = "info hover";
  info.textContent = "ⓘ";
  info.tabIndex = 0;
  head.appendChild(info);
  var tabbar = null;
  if (withTabbar) {
    tabbar = document.createElement("span");
    tabbar.className = "tabbar";
    tabbar.setAttribute("role", "tablist");
    tabbar.setAttribute("aria-label", "surface underlying");
    head.appendChild(tabbar);
  }
  var hl = makeHeadline();
  head.appendChild(hl);
  var badge = makeBadge();
  head.appendChild(badge);
  section.appendChild(head);
  var bubble = document.createElement("div");
  bubble.className = "bubble";
  section.appendChild(bubble);
  function orient() {
    requestAnimationFrame(function () {
      if (!bubble.getBoundingClientRect().height) return;
      bubble.classList.remove("up");
      if (bubble.getBoundingClientRect().bottom > window.innerHeight) bubble.classList.add("up");
    });
  }
  head.addEventListener("mouseover", orient);
  head.addEventListener("focusin", orient);
  return { section: section, keySpan: keySpan, tabbar: tabbar, headline: hl,
           badge: badge, bubble: bubble };
}

// Replace a bubble element's contents with the structured help for `meta`.
function fillBubble(target, meta) {
  var nb = buildBubble(meta);
  while (target.firstChild) target.removeChild(target.firstChild);
  while (nb.firstChild) target.appendChild(nb.firstChild);
}

// A single-member stacked section: exactly the pre-M8-17 layout.
function plainStackSection(m) {
  var s = stackShell(false);
  s.keySpan.textContent = dispKey(m.key);
  fillHeadline(s.headline, headlineOf(m.env.payload), m.meta && m.meta.terms);
  fillBubble(s.bubble, m.meta);
  setBadge(s.badge, m.env);
  m.chartDiv.style.display = "";
  s.section.appendChild(m.chartDiv);
  return s.section;
}

// A tabbed stacked section (M8-17): one head with a mini [BTC][MSTR] tab
// bar, ONE chart visible at a time. Clicking a tab swaps the visible chart
// (resizing it -- a display:none div renders 0x0), and the section's key
// text, hover bubble and staleness badge to that member's envelope (the
// activateGroup idiom, scoped to this section). Default = ms[0] (lowest
// CARD_ORDER rank, i.e. BTC).
//
// `link` (2026-08-29, linked stacked tabs): non-null when this section is
// one of several with identical label sets. Only the LEADER renders the
// tab bar; its clicks go through link.activateAll so every linked section
// flips to the same label index. Follower sections keep their own head
// (key/ⓘ/badge swap with activation) but draw no bar.
function tabbedStackSection(ms, link) {
  var s = stackShell(!link || link.leader);
  function activate(i) {
    var m = ms[i];
    ms.forEach(function (x, j) {
      var on = j === i;
      x.chartDiv.style.display = on ? "" : "none";
      if (x.btn) {
        x.btn.classList.toggle("active", on);
        x.btn.setAttribute("aria-selected", on ? "true" : "false");
      }
    });
    s.keySpan.textContent = dispKey(m.key);
    fillHeadline(s.headline, headlineOf(m.env.payload), m.meta && m.meta.terms);
    fillBubble(s.bubble, m.meta);
    setBadge(s.badge, m.env);
    requestAnimationFrame(function () { m.chart.resize(); });
  }
  ms.forEach(function (m, i) {
    if (s.tabbar) {
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "tabbtn";
      btn.setAttribute("role", "tab");
      btn.textContent = m.meta.tab_label || m.key;
      btn.addEventListener("click", function () {
        if (link) { link.activateAll(i); } else { activate(i); }
      });
      m.btn = btn;
      s.tabbar.appendChild(btn);
    }
    s.section.appendChild(m.chartDiv);
  });
  if (link) link.register(activate);
  activate(0);
  return s.section;
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
  if (meta && meta.tab_group) {
    return meta.group_style === "stack" ?
      buildStackedCard(env, key, meta, meta.tab_group) :
      buildGroupedCard(env, key, meta, meta.tab_group);
  }

  var card = document.createElement("div");
  card.className = "card";
  card.dataset.key = env.key || key; // pages locate specific cards by key
  var head = document.createElement("div");
  head.className = "card-head";

  // title + ⓘ both trigger the instant structured bubble (built from
  // meta); no meta means no bubble and no hover affordance.
  var keySpan = document.createElement("span");
  keySpan.className = "key" + (meta ? " hover" : "");
  keySpan.textContent = dispKey(env.key || key);
  head.appendChild(keySpan);
  if (meta) {
    var info = document.createElement("span");
    info.className = "info hover";
    info.textContent = "ⓘ"; // ⓘ
    info.tabIndex = 0; // keyboard-reachable: focus opens the bubble (.hover:focus rule)
    head.appendChild(info);
  }
  var hl = makeHeadline();
  fillHeadline(hl, headlineOf(env.payload), meta && meta.terms);
  head.appendChild(hl);
  var badge = makeBadge();
  setBadge(badge, env);
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
    var label = dispKey(row.key) + "@" + hhmm(row.generated_at);
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
var CARD_ORDER = ["chart:gex_btc", "chart:gex_mstr", "chart:gex_btc_trend",
                  "chart:gex_mstr_trend",
                  "chart:vol_surface", "chart:vol_surface_mstr", "chart:vol_basis",
                  "chart:vol_spread", "chart:vol_spread_trend",
                  "chart:scenario_strip", "chart:scorecard",
                  "chart:positioning",
                  "chart:dist_fan", "chart:dist_edge", "chart:dist_pit",
                  "chart:lppl_regime", "chart:lppl_shadow",
                  "chart:btco_table"];
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
  rev: "m10-4-positioning",
  staleClass: staleClass,
  hhmm: hhmm,
  liveHeader: liveHeader,
  buildBtcoTable: buildBtcoTable,
  attachBtcoTable: attachBtcoTable,
  buildBubble: buildBubble,
  errCard: errCard,
  buildChartCard: buildChartCard,
  makeBadge: makeBadge,
  setBadge: setBadge,
  refreshBadge: refreshBadge,
  nextDelay: nextDelay,
  releaseCard: releaseCard,
  forgetGroup: forgetGroup,
  charts: charts,
  FORMATTERS: FORMATTERS,
  WIDGETS: WIDGETS,
  termsBlock: termsBlock,
  applyTerms: applyTerms
};
