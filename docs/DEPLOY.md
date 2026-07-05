# Deploying mimir to Cloudflare

**One deploy, one host.** `rake deploy` ships the Worker (the API) AND
the dashboard (the static files in `web/`) together to a single
`https://<name>.<your-subdomain>.workers.dev` host. There is no Pages
project, no routing setup, no second step.

You run everything below yourself (CLAUDE.md Golden Rule 3 -- the loop
and CI cannot deploy). Sections 1-3 are the instructions, in order.
Section 4 is what to do when a step fails. Section 5 is background --
you never need it to deploy.

---

## 1. One-time setup (~10 minutes)

**1.1 Install wrangler and log in:**

```
npm install -g wrangler
wrangler login                          # opens the browser for OAuth; approve it
env -u CF_API_TOKEN wrangler whoami     # EXPECT: your email + account name/id
```

The `env -u` matters: wrangler treats `CF_API_TOKEN` (the *publisher's*
KV-scoped token from `~/.config/mimir/env`) as a legacy auth alias and
prefers env tokens over your OAuth login. If `whoami` says
`logged in with an User API Token` / `Unable to retrieve email`, that's
this -- the publisher token hijacked auth. `rake deploy` strips it
automatically; only manual wrangler commands need the `env -u` prefix.

**1.2 Add two lines to `~/.config/mimir/env`** (alongside the existing
`CF_API_TOKEN`, which stays publisher-only):

```
export CF_ACCOUNT_ID=...        # shown by `wrangler whoami`
export CF_KV_NAMESPACE_ID=...   # the Gate 2 namespace: `wrangler kv namespace list`
```

**1.3 Pick the public hostname** (recommended): the worker's *name* is
its hostname, and the Gate 4 ruling is public-read behind an
unguessable name. Add one more line:

```
export DEPLOY_NAME=mimir-<random>     # e.g. mimir-a7f3k9 -- lowercase/digits/hyphens
```

Without `DEPLOY_NAME` the host is `mimir.<subdomain>.workers.dev` --
guessable; fine for a first test, not for staying up.

Done. You never repeat this section.

---

## 2. Deploy

**2.1 Load the env and dry-run first:**

```
source ~/.config/mimir/env
DEPLOY_DRY_RUN=1 rake deploy
```

EXPECT: a pre-flight table of five `[ok]` rows, then
`would run: ... wrangler deploy -c data/wrangler.generated.toml`.
Nothing has been deployed. If a row says `MISSING`, see section 4.

**2.2 Make sure KV has data** (first deploy, or after long sleep):

```
ruby publish/publish.rb        # real publish -- expects PUB LIVE 11/11
```

**2.3 Deploy for real:**

```
rake deploy
```

EXPECT, in order: the pre-flight table (all `[ok]`), the generated-
config line, `deploying: wrangler deploy ...`, `deployed host:
https://<name>.<subdomain>.workers.dev`, and four smoke probes:

```
post-deploy smoke:
  [PASS] GET /healthz                      200 {ok:true}
  [PASS] GET /api/v1/index                 200 envelope, age 0.3h
  [PASS] GET /api/v1/definitely:missing    404 as expected
  [PASS] GET / (dashboard)                 200 dashboard html
```

**2.4 Open the printed host in a browser.** That's the dashboard, live.

That's the whole routine -- every future deploy is 2.1 + 2.3.

---

## 3. Gate 4 acceptance checklist (once, against the live host)

Set `H` to your deployed host first: `H=https://<name>.<subdomain>.workers.dev`

**3.1 In the browser** (open `$H`):
- [ ] all four charts render; the BTCo table strip sorts when you click headers
- [ ] header chips + `pub HH:MMZ · n/11 fresh` present; age badges tick up live
- [ ] hover a chart title -> the description bubble appears instantly

**3.2 All eleven keys answer 200 with sane ages:**

```
for k in index gex:combined scenario:latest scenario:history \
         lppl:latest lppl:ledger btco:latest \
         chart:gex_profile chart:scenario_strip chart:lppl_regime chart:btco_table; do
  printf '%-24s ' "$k"
  curl -s -o /dev/null -w '%{http_code}  ' "$H/api/v1/$k"
  curl -sI "$H/api/v1/$k" | tr -d '\r' | grep -i x-data-age-seconds
done
```

Sane age = within the key's cadence: gex/scenario minutes-to-an-hour,
btco ~an hour, lppl up to a day.

**3.3 Error paths and headers:**

```
curl -s -o /dev/null -w '%{http_code}\n' "$H/api/v1/definitely:missing"  # EXPECT 404
curl -s -o /dev/null -w '%{http_code}\n' "$H/api/v1/BAD..key"            # EXPECT 404
curl -sI "$H/api/v1/index" | tr -d '\r' | grep -i cache-control          # EXPECT public, max-age=60
curl -sI "$H/" | tr -d '\r' | grep -i x-robots-tag                       # EXPECT noindex
```

**3.4 Staleness honesty**: the dashboard must read *stale, never down*
when the Macs sleep. `lppl:latest` is daily, so it goes amber first --
check its card badge turns amber/red once
`curl -sI "$H/api/v1/lppl:latest" | grep -i x-data-age-seconds` exceeds
its ttl (86400) / 3x ttl.

All boxes checked -> Gate 4 accepted.

---

## 4. When something fails

| symptom | cause | fix |
|---|---|---|
| pre-flight `CF_... MISSING` | env not loaded in this shell | `source ~/.config/mimir/env`, re-run |
| pre-flight `wrangler MISSING` | not installed / not on PATH | `npm install -g wrangler` |
| pre-flight `working tree dirty` | uncommitted changes | commit/stash; or `DEPLOY_SKIP_CHECKS=1 rake deploy` if intentional |
| pre-flight `rake gate FAILED` | tests/health red | fix first -- do not deploy over a red gate |
| `wrangler deploy failed` | login expired / wrong account | `wrangler login`, `env -u CF_API_TOKEN wrangler whoami`, re-run |
| wrangler warns `Using "CF_API_TOKEN" ... deprecated` / auth or permission errors on manual commands | the publisher's KV-scoped token hijacked wrangler auth (env token beats OAuth) | prefix manual commands with `env -u CF_API_TOKEN`; `rake deploy` strips it itself |
| smoke `index` FAIL (404 or stale) | KV empty or old | `ruby publish/publish.rb`, then `DEPLOY_SKIP_CHECKS=1 rake deploy` |
| smoke `dashboard` FAIL | assets missing from the deploy | check `wrangler.toml` has the `[assets]` block; re-run |
| deployed the wrong thing | -- | `wrangler deployments list`, then `wrangler rollback --version-id <last-good>` (assets roll back with the worker -- one rollback reverts everything) |

A bad KV *value* is a publisher problem, not a deploy problem: fix by
re-publishing, never by rollback.

---

## 5. Background (not needed to deploy)

**What `rake deploy` actually does**: (1) pre-flight -- wrangler
present, `CF_*` env set (printed as `set`/`MISSING`, values never
echoed), tree clean, `rake` gate green; (2) writes
`data/wrangler.generated.toml` from the committed `wrangler.toml`
template, filling the KV namespace id from env and the worker name
from `DEPLOY_NAME` (the generated file lives in gitignored `data/`, so
real ids are never committable); (3) runs `wrangler deploy -c` that
file, passing `CLOUDFLARE_ACCOUNT_ID` to the child process only;
(4) probes the deployed host. It refuses under CI and is deny-listed
for the loop.

**Env reference**: `CF_ACCOUNT_ID`, `CF_KV_NAMESPACE_ID` (both
required; never printed), `DEPLOY_NAME` (optional hostname),
`DEPLOY_HOST` (optional -- overrides the smoke-probe host if wrangler's
output can't be parsed), `DEPLOY_DRY_RUN=1`, `DEPLOY_SKIP_CHECKS=1`.
`CF_API_TOKEN` is the *publisher's* credential; `rake deploy`
explicitly UNSETS it for the wrangler child (wrangler would otherwise
adopt it as a legacy auth alias and fail to deploy -- found live at
Gate 4). A deliberately exported `CLOUDFLARE_API_TOKEN` (deploy-scoped)
is honored if you prefer token auth over `wrangler login`.

**Architecture**: the Worker answers `/api/v1/:key` (KV envelope,
verbatim, `max-age=60`, age headers) and `/healthz`; every other path
is served from the `web/` static assets bundled in the same deploy
(`[assets]` in `wrangler.toml`) -- so the dashboard and its API are
same-origin by construction. `web/_headers` adds `X-Robots-Tag:
noindex` (public-read mitigation, with the unguessable name and the
short cache). This replaces the ARCHITECTURE Phase 4 "Pages publish"
step -- amended at Gate 4 (owner feedback, 2026-07-05). `web/preview.html`
also ships in the bundle; it is the offline review page and shows
error cards on a live host (its data paths don't exist there) --
harmless.

**Security posture**: public-read by owner ruling D4-c. To lock the
API later without any code change: `wrangler secret put AUTH_TOKEN`
(the Worker's dormant bearer branch activates; `/healthz` stays
public; `wrangler secret delete AUTH_TOKEN` reverts). The fuller lock,
Cloudflare Access in front of the host, is console-only work at the
queue tail.
