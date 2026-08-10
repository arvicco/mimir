// M8-12 (SBI review finding C4): the dashboard's Content-Security-Policy.
// The dashboard HTML is served by Workers static assets (wrangler.toml
// [assets]), so its headers live in web/_headers, not worker.mjs. These
// tests pin that the shipped CSP (a) is derived from the ACTUAL pinned
// ECharts CDN tag in the HTML, (b) carries NO 'unsafe-inline' for scripts,
// and (c) stays in sync with each page's inline <script> via its sha256 --
// so an edit to a boot script that forgets to refresh the hash fails here
// rather than silently breaking the page under CSP in production.
// Run: node --test test/web/   (rake web:test; part of the default gate)

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const WEB = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'web');
const HEADERS = readFileSync(join(WEB, '_headers'), 'utf8');

// The one Content-Security-Policy line in _headers (comments stripped).
function cspValue() {
  const line = HEADERS.split('\n')
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#'))
    .find((l) => l.startsWith('Content-Security-Policy:'));
  assert.ok(line, 'a Content-Security-Policy header is present in web/_headers');
  return line.slice('Content-Security-Policy:'.length).trim();
}

// name -> array of source tokens, from a CSP string.
function directives(csp) {
  const out = {};
  csp.split(';').map((d) => d.trim()).filter(Boolean).forEach((d) => {
    const parts = d.split(/\s+/);
    out[parts[0]] = parts.slice(1);
  });
  return out;
}

// Origin of the <script src="https://..."> in a page (the pinned CDN).
function cdnOrigin(file) {
  const html = readFileSync(join(WEB, file), 'utf8');
  const m = html.match(/<script\s+src="(https:\/\/[^/"]+)/);
  assert.ok(m, `${file} has a pinned https script tag`);
  return m[1];
}

// sha256-<base64> of a page's single inline <script> block (the bytes the
// browser hashes: everything between the tags).
function inlineHash(file) {
  const html = readFileSync(join(WEB, file), 'utf8');
  const m = html.match(/<script>([\s\S]*?)<\/script>/);
  assert.ok(m, `${file} has an inline <script> block`);
  return 'sha256-' + createHash('sha256').update(m[1], 'utf8').digest('base64');
}

test('CSP script-src is self + the pinned ECharts CDN, and nothing wilder', () => {
  const dir = directives(cspValue());
  const script = dir['script-src'];
  assert.ok(script, 'script-src is declared');
  assert.ok(script.includes("'self'"), "script-src allows 'self'");
  // derived from the real tag in the HTML, not a hard-coded literal
  const cdn = cdnOrigin('index.html');
  assert.equal(cdn, 'https://cdn.jsdelivr.net');
  assert.ok(script.includes(cdn), `script-src allows the pinned CDN ${cdn}`);
  assert.equal(cdnOrigin('preview.html'), cdn, 'both pages pin the SAME CDN');
  // the whole point of C4: injected inline handlers/scripts cannot run
  assert.ok(!script.includes("'unsafe-inline'"), "script-src has NO 'unsafe-inline'");
  assert.ok(!script.includes("'unsafe-eval'"), "script-src has NO 'unsafe-eval'");
});

test('CSP script-src carries the sha256 of each page inline boot script', () => {
  const script = directives(cspValue())['script-src'];
  for (const page of ['index.html', 'preview.html']) {
    const h = inlineHash(page);
    assert.ok(script.includes(`'${h}'`),
      `_headers CSP must list ${page}'s inline-script hash ${h} ` +
      '(recompute it in _headers whenever that inline <script> changes)');
  }
});

test('CSP keeps style inline (the pages have a <style> block + runtime .style)', () => {
  const dir = directives(cspValue());
  assert.ok((dir['style-src'] || []).includes("'unsafe-inline'"),
    "style-src allows 'unsafe-inline'");
});

test('CSP locks down the classic injection vectors', () => {
  const dir = directives(cspValue());
  assert.deepEqual(dir['object-src'], ["'none'"], "object-src 'none'");
  assert.deepEqual(dir['base-uri'], ["'none'"], "base-uri 'none'");
  assert.deepEqual(dir['frame-ancestors'], ["'none'"], "frame-ancestors 'none'");
});
