// worker.mjs -- mimir Worker API (M4-1, ARCHITECTURE section 4.3).
//
//   GET /api/v1/:key  -> the KV envelope stored at "v1:<key>", VERBATIM.
//                        200: Cache-Control public max-age=60,
//                             Vary: Authorization (a shared cache must
//                             never serve a token-authorized response to
//                             an anonymous client once AUTH_TOKEN is set),
//                             X-Generated-At, X-Data-Age-Seconds
//                        404: {"error":"unknown key","key":...} (also for
//                             malformed keys -- rejected before KV)
//                        401: only when the AUTH_TOKEN secret exists and
//                             the bearer mismatches. DORMANT by default:
//                             owner ruling D4-c (2026-07-05) ships Gate 4
//                             public-read; Cloudflare Access sits at the
//                             queue tail as console-only work.
//   GET /healthz      -> {"ok":true,"worker_ts":...}, no-store, no auth.
//
// Anything else 404; non-GET 405. No cookies, no CORS headers (the
// dashboard is same-origin behind the Worker route). Error paths never
// echo the token, the Authorization header, or KV internals.
//
// Deploy is OWNER-run via rake deploy (M4-5); wrangler.toml is a
// template whose namespace id is filled from ENV at deploy time.

// Published keys after the "v1:" prefix: lowercase colon-separated
// segments (gex:combined, chart:gex_btc, index). Anything else is
// rejected before KV is consulted.
const KEY_RE = /^[a-z0-9_]+(?::[a-z0-9_]+)*$/;
const KEY_MAX = 64;

const JSON_HEADERS = { 'Content-Type': 'application/json; charset=utf-8' };

function jsonResponse(status, obj, headers = {}) {
  return new Response(JSON.stringify(obj),
                      { status, headers: { ...JSON_HEADERS, 'Cache-Control': 'no-store', ...headers } });
}

// Constant-time string compare so a bearer mismatch leaks no prefix
// timing. Length differences return early -- length is not a secret.
function tokenMatches(given, expected) {
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a[i] ^ b[i];
  return diff === 0;
}

export async function handle(request, env, nowMs = Date.now()) {
  const url = new URL(request.url);

  if (request.method !== 'GET') {
    return jsonResponse(405, { error: 'method not allowed' }, { Allow: 'GET' });
  }

  if (url.pathname === '/healthz') {
    return jsonResponse(200, { ok: true, worker_ts: new Date(nowMs).toISOString() });
  }

  const m = url.pathname.match(/^\/api\/v1\/(.+)$/);
  if (!m) return jsonResponse(404, { error: 'not found' });
  const key = m[1];

  if (env.AUTH_TOKEN) {
    const auth = request.headers.get('Authorization') || '';
    const bearer = auth.startsWith('Bearer ') ? auth.slice(7) : '';
    if (!tokenMatches(bearer, env.AUTH_TOKEN)) {
      return jsonResponse(401, { error: 'unauthorized' });
    }
  }

  if (key.length > KEY_MAX || !KEY_RE.test(key)) {
    return jsonResponse(404, { error: 'unknown key', key });
  }

  const value = await env.MIMIR.get(`v1:${key}`);
  if (value === null) return jsonResponse(404, { error: 'unknown key', key });

  // Envelope verbatim -- the publisher's bytes are the contract. Age
  // headers come from a best-effort parse; a malformed value (should
  // never happen) still serves, just without them.
  const headers = { ...JSON_HEADERS, 'Cache-Control': 'public, max-age=60',
                    'Vary': 'Authorization' };
  try {
    const generatedAt = JSON.parse(value).generated_at;
    const ageS = Math.floor((nowMs - Date.parse(generatedAt)) / 1000);
    if (Number.isFinite(ageS)) {
      headers['X-Generated-At'] = generatedAt;
      headers['X-Data-Age-Seconds'] = String(ageS);
    }
  } catch { /* serve without age headers */ }
  return new Response(value, { status: 200, headers });
}

export default { fetch: (request, env) => handle(request, env) };
