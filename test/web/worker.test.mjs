// M4-1: Worker API contract (node built-in test runner, zero npm).
// Pins the full routing/header/auth matrix of web/worker.mjs with an
// injected fake KV and a frozen clock -- no network, no wrangler.
// Run: node --test test/web/   (rake web:test; part of the default gate)

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handle } from '../../web/worker.mjs';

const GENERATED_AT = '2026-07-05T12:00:00Z';
const NOW_MS = Date.parse(GENERATED_AT) + 90_000; // envelope is 90s old

const ENVELOPE = JSON.stringify({
  v: 1, key: 'gex:combined', generated_at: GENERATED_AT,
  ttl_hint_s: 1800, source: 'novo', payload: { spot: 62_700 }
});

// Fake KV binding: records every requested key so tests can assert
// that invalid keys never reach KV at all.
function fakeEnv(values = {}, extra = {}) {
  const asked = [];
  return {
    asked,
    MIMIR: { get: async (k) => { asked.push(k); return values[k] ?? null; } },
    ...extra
  };
}

const get = (path, headers = {}) =>
  new Request(`https://mimir.example${path}`, { headers });

// ---- /healthz ----------------------------------------------------------

test('healthz answers ok with a worker timestamp, never cached', async () => {
  const res = await handle(get('/healthz'), fakeEnv(), NOW_MS);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('Cache-Control'), 'no-store');
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.equal(body.worker_ts, new Date(NOW_MS).toISOString());
});

// ---- /api/v1/:key happy path -------------------------------------------

test('known key returns the KV envelope verbatim with cache+age headers', async () => {
  const env = fakeEnv({ 'v1:gex:combined': ENVELOPE });
  const res = await handle(get('/api/v1/gex:combined'), env, NOW_MS);
  assert.equal(res.status, 200);
  assert.equal(await res.text(), ENVELOPE); // verbatim, not re-serialized
  assert.equal(res.headers.get('Content-Type'), 'application/json; charset=utf-8');
  assert.equal(res.headers.get('Cache-Control'), 'public, max-age=60');
  // A shared cache keyed on the Authorization header (M8-12 / SBI C4):
  // once AUTH_TOKEN is enabled it must never hand a token-authorized
  // response to an anonymous client.
  assert.equal(res.headers.get('Vary'), 'Authorization');
  assert.equal(res.headers.get('X-Generated-At'), GENERATED_AT);
  assert.equal(res.headers.get('X-Data-Age-Seconds'), '90');
  assert.deepEqual(env.asked, ['v1:gex:combined']);
});

test('Vary: Authorization rides the cacheable 200, not the no-store paths', async () => {
  const env = fakeEnv({ 'v1:index': ENVELOPE });
  const ok = await handle(get('/api/v1/index'), env, NOW_MS);
  assert.equal(ok.headers.get('Cache-Control'), 'public, max-age=60');
  assert.equal(ok.headers.get('Vary'), 'Authorization');
  // no-store responses are never shared-cached, so they carry no Vary
  const miss = await handle(get('/api/v1/nope:missing'), fakeEnv(), NOW_MS);
  assert.equal(miss.headers.get('Cache-Control'), 'no-store');
  assert.equal(miss.headers.get('Vary'), null);
});

test('chart and index key shapes are accepted', async () => {
  const env = fakeEnv({ 'v1:chart:gex_profile': ENVELOPE, 'v1:index': ENVELOPE });
  assert.equal((await handle(get('/api/v1/chart:gex_profile'), env, NOW_MS)).status, 200);
  assert.equal((await handle(get('/api/v1/index'), env, NOW_MS)).status, 200);
});

test('unparsable KV value still serves verbatim, without age headers', async () => {
  const env = fakeEnv({ 'v1:gex:combined': 'not json' });
  const res = await handle(get('/api/v1/gex:combined'), env, NOW_MS);
  assert.equal(res.status, 200);
  assert.equal(await res.text(), 'not json');
  assert.equal(res.headers.get('X-Generated-At'), null);
  assert.equal(res.headers.get('X-Data-Age-Seconds'), null);
});

// ---- error paths ---------------------------------------------------------

test('unknown key is a JSON 404 naming the key, uncached', async () => {
  const res = await handle(get('/api/v1/nope:missing'), fakeEnv(), NOW_MS);
  assert.equal(res.status, 404);
  assert.equal(res.headers.get('Cache-Control'), 'no-store');
  const body = await res.json();
  assert.equal(body.error, 'unknown key');
  assert.equal(body.key, 'nope:missing');
});

test('malformed keys are rejected before KV is consulted', async () => {
  const env = fakeEnv({ 'v1:gex:combined': ENVELOPE });
  for (const bad of ['GEX:combined', 'a%2Fb', 'a b',
                     ':leading', 'trailing:', 'a::b', 'x'.repeat(65)]) {
    const res = await handle(get(`/api/v1/${bad}`), env, NOW_MS);
    assert.equal(res.status, 404, bad);
  }
  assert.deepEqual(env.asked, []); // KV never touched
});

test('path traversal is normalized by URL into a plain (absent) key', async () => {
  // new URL() resolves /api/v1/a/../b -> /api/v1/b before the worker
  // runs; the resulting clean key is looked up normally and 404s.
  const env = fakeEnv({ 'v1:gex:combined': ENVELOPE });
  const res = await handle(get('/api/v1/a/../b'), env, NOW_MS);
  assert.equal(res.status, 404);
  assert.deepEqual(env.asked, ['v1:b']);
});

test('unknown paths 404, non-GET 405 with Allow', async () => {
  assert.equal((await handle(get('/'), fakeEnv(), NOW_MS)).status, 404);
  assert.equal((await handle(get('/api/v2/index'), fakeEnv(), NOW_MS)).status, 404);
  const res = await handle(
    new Request('https://mimir.example/api/v1/index', { method: 'POST' }),
    fakeEnv(), NOW_MS);
  assert.equal(res.status, 405);
  assert.equal(res.headers.get('Allow'), 'GET');
});

// ---- auth: dormant by default (owner ruling D4-c), bearer when set -------

test('without AUTH_TOKEN the API is public-read', async () => {
  const env = fakeEnv({ 'v1:index': ENVELOPE });
  assert.equal((await handle(get('/api/v1/index'), env, NOW_MS)).status, 200);
});

test('with AUTH_TOKEN set, missing or wrong bearer is 401, right one 200', async () => {
  const values = { 'v1:index': ENVELOPE };
  const env = fakeEnv(values, { AUTH_TOKEN: 'sekrit-token' });
  assert.equal((await handle(get('/api/v1/index'), env, NOW_MS)).status, 401);
  assert.equal((await handle(
    get('/api/v1/index', { Authorization: 'Bearer wrong' }), env, NOW_MS)).status, 401);
  const ok = await handle(
    get('/api/v1/index', { Authorization: 'Bearer sekrit-token' }), env, NOW_MS);
  assert.equal(ok.status, 200);
});

test('401 body never echoes the token', async () => {
  const env = fakeEnv({}, { AUTH_TOKEN: 'sekrit-token' });
  const res = await handle(
    get('/api/v1/index', { Authorization: 'Bearer sekrit-typo' }), env, NOW_MS);
  const text = await res.text();
  assert.ok(!text.includes('sekrit'), text);
});

test('healthz stays public even with AUTH_TOKEN set', async () => {
  const env = fakeEnv({}, { AUTH_TOKEN: 'sekrit-token' });
  assert.equal((await handle(get('/healthz'), env, NOW_MS)).status, 200);
});
