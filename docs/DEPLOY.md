# DEPLOY.md -- deploying the mimir Cloudflare layer (Phase 4)

Deploys are **HUMAN actions** (CLAUDE.md Golden Rule 3). The loop
prepares `wrangler.toml`, the `rake deploy` task, and this document; the
**owner** runs the commands. `rake deploy` refuses to run under CI
(`ENV['CI']` set) and is deny-listed for the loop exactly like
`fixtures:record`.

There are two independent surfaces:

- **Worker + KV** (the API at `/api/v1/:key`, `/healthz`) -- deployed by
  `rake deploy` (section 3).
- **Pages** (the static dashboard: `web/index.html`, `web/render.js`, the
  pinned ECharts tag) -- a **separate owner step** (section 2). `rake
  deploy` does NOT touch it and prints a reminder.

Prerequisites: `wrangler` on PATH (`npm i -g wrangler`, or `npx
wrangler`), a Cloudflare account, and the KV namespace + scoped token
already created (the Gate 2 step -- the same namespace the publisher
writes to). Environment (from `~/.config/mimir/env`, never the repo):

```
CF_ACCOUNT_ID        Cloudflare account id
CF_KV_NAMESPACE_ID   the MIMIR KV namespace id
CF_API_TOKEN         token scoped to that namespace (publisher only; not
                     needed by rake deploy, which uses wrangler's own login)
DEPLOY_HOST          (optional) override the smoke-test host, e.g.
                     https://mimir.<subdomain>.workers.dev
```

`rake deploy` never prints any `CF_*` value: the pre-flight table says
`set` or `MISSING`, the generated config's id line is written but never
echoed, and the dry-run command shows `CLOUDFLARE_ACCOUNT_ID=<from
CF_ACCOUNT_ID>` as a placeholder.

---

## 1. First-time Cloudflare setup (once, console + wrangler)

All console/CLI work; done once by the owner.

1. **Authenticate wrangler**: `wrangler login` (OAuth) or export
   `CLOUDFLARE_API_TOKEN` with Workers-edit scope. Confirm with
   `wrangler whoami`.
2. **KV namespace** (if not already created at Gate 2):
   `wrangler kv namespace create MIMIR` -> note the id -> set it as
   `CF_KV_NAMESPACE_ID` in `~/.config/mimir/env`. The publisher and the
   Worker binding must point at the **same** namespace.
3. **Worker route / hostname**: the default is the free
   `mimir.<your-subdomain>.workers.dev` host (nothing to configure --
   `wrangler deploy` prints it). To serve on a custom domain instead, add
   a route in the dashboard (Workers & Pages -> your Worker -> Triggers ->
   Routes) or `[routes]` in `wrangler.toml`; keep the namespace-id
   placeholder untouched.
4. **Pages project** (for the dashboard): create a Pages project pointed
   at the repo's `web/` directory (dashboard -> Workers & Pages -> Create
   -> Pages -> Direct Upload, or connect the repo with build output
   `web/`).
   - **Name it unguessably.** Owner ruling D4-c: Gate 4 ships
     **public-read** (no bearer in the browser). The only front-line
     mitigations are `max-age=60`, an **unguessable project name**, and
     `noindex`. Do not use `mimir` as the Pages project name; pick a
     random slug (e.g. `mimir-a7f3k9`).
   - **noindex**: serve `X-Robots-Tag: noindex` (Pages -> Settings ->
     Headers, or a `web/_headers` file: `/*` then
     `X-Robots-Tag: noindex`) so the dashboard host never lands in a
     search index. The Worker responses are `no-store`/short-cache and
     carry no HTML, so this is a Pages concern.
   - Same-origin: the dashboard calls `/api/v1/...` relative, so the
     Pages host must route those paths to the Worker (custom domain with
     both, or a Worker route on the Pages domain). If you keep the Worker
     on `*.workers.dev` and Pages elsewhere, point the dashboard at the
     Worker host or add the route.

---

## 2. Pages publish (separate owner step -- NOT automated)

`rake deploy` deploys only the Worker. Publish the static dashboard by
hand whenever `web/` changes:

```
wrangler pages deploy web --project-name <your-unguessable-pages-name>
```

(or drag-drop `web/` in the dashboard). Then confirm the pinned ECharts
tag loads (SRI hash is checked offline by `rake health`; the browser
enforces it at load).

---

## 3. Routine deploy -- `rake deploy`

```
rake deploy                    # full: pre-flight -> generate -> deploy -> smoke
DEPLOY_DRY_RUN=1 rake deploy   # assemble + print the would-run command, deploy nothing
DEPLOY_SKIP_CHECKS=1 rake deploy   # skip tree-clean + rake-gate (fast re-runs)
```

### Pre-flight table (what each line means)

```
pre-flight:
  [ok  ] wrangler             4.106.0        wrangler is on PATH and runs
  [ok  ] CF_ACCOUNT_ID        set            CF_ACCOUNT_ID present (value hidden)
  [ok  ] CF_KV_NAMESPACE_ID   set            CF_KV_NAMESPACE_ID present (value hidden)
  [ok  ] working tree         clean          `git status --porcelain` empty
  [ok  ] rake gate            green          `rake` (compat+health+tests) passed
```

Any `FAIL` row aborts before deploying. `MISSING` means the env var is
unset. `dirty (N files)` means uncommitted changes -- commit or stash, or
use `DEPLOY_SKIP_CHECKS=1` to skip the tree + gate checks on a re-run
after a failed smoke. In **dry run** the table is informational and never
blocks (a dev box without wrangler still proves the pipeline).

### What it does

1. Generates `data/wrangler.generated.toml` from the committed
   `wrangler.toml` template, substituting the namespace id from
   `CF_KV_NAMESPACE_ID`. `data/` is gitignored, so the filled config is
   never committable.
2. Runs `wrangler deploy -c data/wrangler.generated.toml`, exporting
   `CLOUDFLARE_ACCOUNT_ID` from `CF_ACCOUNT_ID` for the child process
   only.
3. Smoke-probes the deployed host (`DEPLOY_HOST`, else the `*.workers.dev`
   URL parsed from wrangler's output):

```
post-deploy smoke:
  [PASS] GET /healthz                      200 {ok:true}
  [PASS] GET /api/v1/index                 200 envelope, age 0.3h
  [PASS] GET /api/v1/definitely:missing    404 as expected
```

Any `FAIL` -> nonzero exit. `/api/v1/index` fails if the envelope does
not parse or its `generated_at` is in the future or older than 7 days
(publish first, then re-deploy or re-run the smoke).

---

## 4. Gate 4 smoke checklist (against the live host)

Beyond the automated three probes, walk the full surface once by hand.
Substitute your host for `$H` (e.g.
`H=https://mimir.<subdomain>.workers.dev`).

**All published keys 200 with sane ages** (the eleven keys of a full
publish -- `index`, four `chart:*`, and the six data keys):

```
for k in index gex:combined scenario:latest scenario:history \
         lppl:latest lppl:ledger btco:latest \
         chart:gex_profile chart:scenario_strip chart:lppl_regime chart:btco_table; do
  printf '%-24s ' "$k"
  curl -s -o /dev/null -w '%{http_code}  ' "$H/api/v1/$k"
  curl -sI "$H/api/v1/$k" | grep -i x-data-age-seconds
done
```

Each should print `200` and an `X-Data-Age-Seconds` within its cadence
(gex minutes, btco ~an hour, lppl up to a day). Confirm
`Cache-Control: public, max-age=60` on a data key:
`curl -sI "$H/api/v1/index" | grep -i cache-control`.

**404 path**:

```
curl -s -o /dev/null -w '%{http_code}\n' "$H/api/v1/definitely:missing"   # 404
curl -s -o /dev/null -w '%{http_code}\n' "$H/api/v1/BAD..key"             # 404 (rejected pre-KV)
```

**Health**: `curl -s "$H/healthz"` -> `{"ok":true,"worker_ts":...}`.

**Badge behaviour with a stale key**: the dashboard colours each card
from the envelope's `generated_at`/`ttl_hint_s` (green <= ttl, amber <=
3x, red beyond) and ticks the age live. Verify against a genuinely old
key -- e.g. open the dashboard when `lppl:latest` is >1 day old (daily
cadence) and confirm the card badge is amber/red and the age ticker
counts up. To force it, temporarily point the dashboard at a key whose
`generated_at` you know is old, or inspect the age header:

```
curl -sI "$H/api/v1/lppl:latest" | grep -i x-data-age-seconds
```

The dashboard must stay **correct-and-honest when the Macs sleep**
(ARCHITECTURE principle 3): stale, never down.

---

## 5. Rollback

`wrangler` keeps prior Worker versions:

```
wrangler deployments list                 # find the last-good version id
wrangler rollback [--version-id <id>]     # instant revert to it
```

Or re-deploy a known-good commit: `git checkout <good-sha> -- wrangler.toml
web/worker.mjs` (or check out the commit), then `rake deploy` again. For
the dashboard, re-run the Pages publish (section 2) from the good commit,
or use the Pages "Rollback to this deployment" button in the dashboard.

KV values are the publisher's responsibility, not the Worker's -- a bad
key is fixed by re-publishing (see the publish pipeline), not by a Worker
rollback.

---

## 6. AUTH_TOKEN activation (queue-tail, no code change)

Gate 4 ships public-read (D4-c). The Worker already carries a **dormant**
bearer branch: it enforces a `Bearer` token **iff** the `AUTH_TOKEN`
secret exists. Activating it needs no deploy of code, just the secret:

```
wrangler secret put AUTH_TOKEN            # paste the token; wrangler stores it encrypted
```

From then on `/api/v1/*` requires `Authorization: Bearer <token>` (401
otherwise; `/healthz` stays public). Remove it with
`wrangler secret delete AUTH_TOKEN` to return to public-read. The
stronger lock -- Cloudflare Access (email OTP / service tokens) in front
of Pages+Worker -- is console-only work at the queue tail and likewise
needs no code change.
