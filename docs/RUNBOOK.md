# Operating mimir on novo

Owner-facing operations runbook for the compute box (novo): the two
launchd agents that keep the dashboard fresh, the tmux health line, and
the fix-it procedures for a 3am stale-everything call.

Every procedure below is self-contained: pick the numbered section for
your task, run the steps top to bottom, check each `EXPECT:` before
moving on. Copy-paste the commands verbatim. No command here ever prints
a secret value; keep it that way if you improvise.

**All of these are HUMAN actions** (CLAUDE.md Golden Rule 3): the loop
and CI cannot install agents, publish for real, deploy, or touch KV.
Background -- what runs when, the file map, why -- is quarantined in the
final section; you never need it to execute a procedure.

Set `REPO` once per shell before any section that uses it:

```
REPO="$HOME/Dev/mimir"          # wherever you cloned mimir
```

EXPECT: `ls "$REPO/ops/run_publish.sh"` prints that path, no error.

---

## 1. One-time setup on novo

Do this once on a fresh box, in order.

**1.1 Confirm the repo and ruby.**

```
ls "$REPO/publish/publish.rb"
ruby -v
```

EXPECT: the path prints; ruby is `3.3` or higher on `arm64-darwin`.

**1.2 Confirm the env file exists and is private.**

```
stat -f '%Sp %N' ~/.config/mimir/env
```

EXPECT: `-rw-------  /Users/<you>/.config/mimir/env` (mode `600`, owner
only). If the file is missing, create it now:

```
mkdir -p ~/.config/mimir
touch ~/.config/mimir/env
chmod 600 ~/.config/mimir/env
```

Then open it in an editor and fill in the values from `.env.example`
(names only listed there). **Open in an editor -- never echo values:**

```
"${EDITOR:-open -e}" ~/.config/mimir/env
```

Required keys: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`,
`CLOUDFLARE_KV_NAMESPACE_ID`, `FRED_API_KEY`. Optional: `BTC_DATA_DIR`
(archive + runtime data root), `MIMIR_RUBY` (interpreter path if `ruby`
is not first on launchd's PATH), `DEPLOY_NAME` (public hostname). To
create the Cloudflare token itself, follow **docs/DEPLOY.md section 1**
-- do not duplicate it here.

**1.3 Confirm the required keys are present (names only, no values).**

```
for k in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_KV_NAMESPACE_ID FRED_API_KEY; do
  printf '%-28s ' "$k"
  grep -qc "^$k=." ~/.config/mimir/env && echo present || echo MISSING
done
```

EXPECT: four `present` lines. (`grep -qc` reports only presence -- it
never prints the line, so no value leaks.) Any `MISSING` -> back to 1.2.

**1.4 Confirm the wrappers run and can read the env file.**

```
"$REPO/ops/run_gex_snapshot.sh"; echo "exit $?"
```

EXPECT: `exit 0` (or `exit 1` only if both GEX captures failed upstream
-- a network issue, not a setup issue). A `exit 78` with a
`run_gex_snapshot: env file not readable: ...` line means 1.2 is not
done. Setup complete.

---

## 2. Install the launchd agents

Installs both agents: `com.mimir.publish` (bi-hourly publisher) and
`com.mimir.gex-snapshot` (daily 08:15 snapshot). Requires section 1 done.

**2.1 Substitute the repo path into both plists and copy them in.** The
plists ship with a `__REPO__` placeholder; `sed` fills it with your
absolute repo path (the exact command is also in each plist's XML
comment):

```
mkdir -p ~/Library/LaunchAgents
sed "s#__REPO__#$REPO#g" "$REPO/ops/com.mimir.publish.plist" \
  > ~/Library/LaunchAgents/com.mimir.publish.plist
sed "s#__REPO__#$REPO#g" "$REPO/ops/com.mimir.gex-snapshot.plist" \
  > ~/Library/LaunchAgents/com.mimir.gex-snapshot.plist
grep ProgramArguments -A2 ~/Library/LaunchAgents/com.mimir.publish.plist
```

EXPECT: the `<string>` line shows your real path, e.g.
`<string>/Users/<you>/Dev/mimir/ops/run_publish.sh</string>` -- no
literal `__REPO__` remaining.

**2.2 Bootstrap both agents into your GUI session.**

```
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mimir.publish.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mimir.gex-snapshot.plist
```

EXPECT: no output, exit 0. `Bootstrap failed: 5: Input/output error`
usually means it is already loaded -- run the bootout in section 4.3
first, then retry.

**2.3 Verify both are registered.**

```
launchctl print gui/$(id -u)/com.mimir.publish | grep -E 'state|path'
launchctl print gui/$(id -u)/com.mimir.gex-snapshot | grep -E 'state|path'
```

EXPECT: each prints `state = waiting` (idle between runs; `running` if it
happens to be mid-run) and a `path = .../run_*.sh` pointing at your repo.
`Could not find service` means 2.2 did not take -- re-run it.

**2.4 Force one publish now and verify the log marker.**

```
launchctl kickstart -k gui/$(id -u)/com.mimir.publish
sleep 120   # the suites fetch live data; give the run ~2 minutes
tail -n 25 ~/Library/Logs/mimir/publish.log
```

EXPECT: the tail opens with a `=== run_publish 2026-...Z` UTC marker and
ends with the summary `publish LIVE: 11 written, 0 skipped -> KV`
(all eleven keys). A `10 written, 1 skipped` or a producer error means a
suite failed -- see section 8. `exit 78` in the log means the env file
was unreadable to launchd -- re-check 1.2.

**2.5 Verify the dashboard header advanced.** Open your dashboard URL in
a browser and look at the header.

EXPECT: `pub HH:MMZ · 11/11 fresh`, where `HH:MMZ` is the UTC minute you
just ran 2.4. If the time is old, the publish did not reach KV -- section 8.

**2.6 Force one snapshot now and verify the file landed.**

```
launchctl kickstart -k gui/$(id -u)/com.mimir.gex-snapshot
sleep 60    # two live options-chain fetches
ls -la "${BTC_DATA_DIR:-$REPO/data}/gex_history/"
tail -n 5 ~/Library/Logs/mimir/gex_snapshot.log
```

EXPECT: a `$(date -u +%F).json` file (today's date) in the listing, and
a log tail with a `=== run_gex_snapshot ...Z` marker followed by
`written: .../<date>.json` (or `partial ...` if one venue failed -- still
a valid file). `failed (both captures failed)` writes no file and is the
only case that alarms launchd.

Both agents are now live. They will run on their own schedule
(publisher every 2h, snapshot daily 08:15 local) from here on.

---

## 3. Add the tmux health line

Puts a one-glance publisher-health indicator in the tmux status bar,
driven by `ops/publish_health.rb` reading `/tmp/publish.status`.

**3.1 Add two lines to `~/.tmux.conf`** (adjust the path to your repo):

```
set -g status-right '#(ruby /Users/<you>/Dev/mimir/ops/publish_health.rb)'
set -g status-interval 30
```

**3.2 Reload tmux config.**

```
tmux source-file ~/.tmux.conf
```

EXPECT: no error; a `PUB ...` token appears at the right of the status
bar within 30 seconds.

**3.3 Read the colour.** The token is `PUB <n>/<m> H:MM` (age is
hours:minutes since the last publish). Meaning:

- **green** `PUB 11/11 0:37` -- healthy: last publish LIVE, all 11 keys,
  age under 4h (2x the 2h cadence). Nothing to do.
- **yellow** `PUB 11/11 5:12` or `PUB 10/11 0:20` -- attention: either the
  publish is stale (age 4h-12h) OR a key is missing (`n < 11`). Glance at
  the dashboard; if it persists, section 8.
- **red** `PUB 11/11 13:40` -- stale: age >= 12h (6x cadence). The
  publisher has not completed a full run in a long time -> section 8.
- **yellow/red** `PUB DRY 11/11 ...` -- the last run was a DRY-RUN
  publish, not LIVE. On novo that should not happen from the agent; it
  means someone ran `PUBLISH_DRY_RUN=1` by hand. The dashboard is not
  being refreshed -> run a real publish (section 8, step 5).
- **red** `PUB ?` -- no status file, or it is unreadable/garbled. The
  publisher has never run on this box, or `/tmp` was cleared -> kickstart
  it (section 2.4) and recheck.

---

## 4. Pause / resume / uninstall the agents

**4.1 Pause one agent** (survives until you resume; does NOT survive a
reboot -- a bootout-ed agent reloads on login, so use uninstall for
permanent):

```
launchctl bootout gui/$(id -u)/com.mimir.publish
```

EXPECT: no output, exit 0. `launchctl print gui/$(id -u)/com.mimir.publish`
now prints `Could not find service`.

**4.2 Resume it** (re-bootstrap the installed plist):

```
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mimir.publish.plist
```

EXPECT: no output; `launchctl print` shows `state = waiting` again.

**4.3 Uninstall permanently** (bootout, then delete the LaunchAgents
copy so it does not reload on next login). Repeat per label:

```
launchctl bootout gui/$(id -u)/com.mimir.publish 2>/dev/null
launchctl bootout gui/$(id -u)/com.mimir.gex-snapshot 2>/dev/null
rm -f ~/Library/LaunchAgents/com.mimir.publish.plist
rm -f ~/Library/LaunchAgents/com.mimir.gex-snapshot.plist
```

EXPECT: `ls ~/Library/LaunchAgents/com.mimir.*.plist` prints
`No such file or directory`. The repo's `ops/*.plist` templates are
untouched -- reinstall any time via section 2.

---

## 5. Rotate CLOUDFLARE_API_TOKEN

Replace the single Cloudflare token without downtime. The token carries
BOTH scopes (Workers KV Storage write + Workers Scripts edit); create the
new one with the same two, per docs/DEPLOY.md.

**5.1 Create the replacement token.** In the Cloudflare console, create a
new API token with the SAME two scopes the current one has (Account ->
Workers KV Storage -> Edit, and Account -> Workers Scripts -> Edit; see
docs/DEPLOY.md section 1). Copy the new secret value to your clipboard.
Do NOT revoke the old one yet.

**5.2 Paste the new value into the env file -- in an editor, never
echoed:**

```
"${EDITOR:-open -e}" ~/.config/mimir/env
```

Replace the `CLOUDFLARE_API_TOKEN=` value with the new one, save, close.

EXPECT (presence check, no value printed):

```
grep -qc '^CLOUDFLARE_API_TOKEN=.' ~/.config/mimir/env && echo present
```

prints `present`.

**5.3 Verify the new token works for BOTH scopes.** A manual real publish
exercises KV-write; a code-only deploy exercises Workers-Scripts-edit:

```
cd "$REPO"
source ~/.config/mimir/env
PUBLISH_DRY_RUN=0 ruby publish/publish.rb
DEPLOY_SKIP_PUBLISH=1 rake deploy
```

EXPECT: the publish ends with `publish LIVE: 11 written, 0 skipped -> KV`;
`rake deploy` ends
with `deployed host: https://...` and four `[PASS]` smoke rows. An
`authorization`/`403` error means the new token is missing a scope ->
fix it in the console (5.1) and re-run 5.2-5.3. Do NOT proceed to 5.4
until both are green.

**5.4 Revoke the old token** in the Cloudflare console (API Tokens ->
the old token -> Delete/Roll). Rotation complete.

---

## 6. Re-create the KV namespace

Use when the KV namespace is lost, corrupted, or being migrated. The new
namespace starts empty; a full deploy re-publishes every key.

**6.1 Create a new namespace** in the Cloudflare console (Workers &
Pages -> KV -> Create namespace). Copy its **namespace ID**.

**6.2 Update the ID in the env file -- in an editor:**

```
"${EDITOR:-open -e}" ~/.config/mimir/env
```

Set `CLOUDFLARE_KV_NAMESPACE_ID=` to the new ID, save, close.

**6.3 Full deploy** (code AND a fresh publish, so the new namespace is
populated and the Worker is bound to it):

```
cd "$REPO"
source ~/.config/mimir/env
rake deploy
```

EXPECT: pre-flight all `[ok]`, `deployed host: https://...`, a
`publish LIVE: 11 written ...` line, and four `[PASS]` smoke rows
including `GET /api/v1/index ... 11 keys incl. charts`.

**6.4 Verify the dashboard.** Open your dashboard URL.

EXPECT: all four charts render and the header reads
`pub HH:MMZ · 11/11 fresh` with the current minute. Namespace migration
complete.

---

## 7. Purge a single KV key

Remove one stale/bad key. The next bi-hourly publish rewrites it, so this
is only for forcing an immediate correction.

**7.1 Regenerate the live wrangler config** (holds the namespace binding;
gitignored, so it may not exist yet):

```
cd "$REPO"
source ~/.config/mimir/env
DEPLOY_DRY_RUN=1 rake deploy >/dev/null
ls wrangler.generated.toml
```

EXPECT: `wrangler.generated.toml` listed (a dry-run deploy writes it
without deploying).

**7.2 Delete the key** (example: `v1:scenario:latest` -- use the real
prefixed key name):

```
npx wrangler kv key delete --binding MIMIR --remote -c wrangler.generated.toml "v1:scenario:latest"
```

EXPECT: `Deleting the key "v1:scenario:latest" ...` then a success line.
A `key not found`/no-op is fine -- the key is already gone.

(Console path instead: Workers & Pages -> KV -> your namespace -> find
the key -> Delete.)

**7.3 Restore immediately** rather than waiting up to 2h for the next
tick:

```
PUBLISH_DRY_RUN=0 ruby publish/publish.rb
```

EXPECT: `publish LIVE: 11 written, 0 skipped -> KV` -- the deleted key
is rewritten. Reload the
dashboard to confirm the affected card is fresh.

---

## 8. Recover from stale-everything

Dashboard is old / a card is red / the tmux line is red. Diagnose IN
THIS ORDER -- stop at the first step that fails and follow where it
sends you. Do not skip ahead.

**Step 1 -- tmux line and dashboard age.**

```
ruby "$REPO/ops/publish_health.rb"
```

EXPECT: a `#[fg=green]PUB 11/11 H:MM#[default]` string with a small H:MM.
Cross-check the dashboard header `pub HH:MMZ · n/11 fresh`.
FAILURE: `PUB ?` (no status file -> the agent never ran, go to Step 2),
yellow/red (stale or partial -> Step 2), or dashboard reads a many-hours
age. If green and fresh, the pipeline is healthy -- your problem is
elsewhere (browser cache? refresh hard).

**Step 2 -- agent state.**

```
launchctl print gui/$(id -u)/com.mimir.publish | grep -E 'state|last exit code'
```

EXPECT: `state = waiting` and `last exit code = 0`.
FAILURE: `Could not find service` -> the agent is not loaded, re-run
section 2.2. A nonzero `last exit code` -> a run failed; continue to
Step 3 to see why.

**Step 3 -- read the publish log.**

```
tail -n 40 ~/Library/Logs/mimir/publish.log
```

EXPECT: a recent `=== run_publish ...Z` marker followed by
`publish LIVE: 11 written, 0 skipped -> KV`.
FAILURE: `exit 78` / `env file not readable` -> the env file moved or
lost its `600`/ownership, re-check section 1.2. A producer traceback or
`... written, ... skipped` with skips -> one suite is failing; note which and continue to Step 4.

**Step 4 -- probe the upstream data sources** (read-only network):

```
cd "$REPO"
source ~/.config/mimir/env
rake health:sources
```

EXPECT: every source row `OK`.
FAILURE: a `DOWN`/`DEGRADED` row identifies the dead upstream. A
fail-soft suite publishes its honest `unavailable` state and keeps the
other keys fresh -- so a single dead source is expected to leave the
dashboard mostly live. If a source is down, that is upstream; wait it
out or accept the degraded card.

**Step 5 -- run a real publish by hand and watch it.**

```
PUBLISH_DRY_RUN=0 ruby publish/publish.rb
```

EXPECT: each key prints `written`, then
`publish LIVE: 11 written, 0 skipped -> KV`; reload the dashboard -> header advances to the current minute.
FAILURE: the exact error prints here (a crashing producer, a KV auth
error). A KV `403`/authorization error -> the token is bad or lost a
scope, rotate it (section 5). A single crashing producer -> its output is
in the traceback; that is a code/data bug to file, not an ops fix, and
keep-last-good means the other ten keys still published.

---

## 9. Weekly checks during the soak

Run these once a week while the ops layer is on probation.

**9.1 KV writes vs the budget.** In the Cloudflare console: Workers &
Pages -> KV -> your namespace -> Metrics, read the last 24h write count.

EXPECT: roughly **132 writes/day** (11 keys x 12 runs/day). Comfortably
under the 1,000/day free-tier write limit. Much higher -> something is
publishing more often than bi-hourly (a stray manual loop? a second
agent?); much lower -> the publisher is skipping runs, see section 8.

**9.2 Log sizes** (there is NO rotation -- see Background):

```
ls -lh ~/Library/Logs/mimir/publish.log ~/Library/Logs/mimir/gex_snapshot.log
```

EXPECT: both in the low MBs. If either reaches tens of MB, truncate it by
hand between runs:

```
: > ~/Library/Logs/mimir/publish.log
```

**9.3 Snapshot archive accumulating one file per day:**

```
ls -1 "${BTC_DATA_DIR:-$REPO/data}/gex_history/" | tail -n 8
```

EXPECT: one `YYYY-MM-DD.json` per calendar day, no gaps in the recent
tail. A missing day = the machine was asleep at 08:15 AND never woke to
catch up, or both captures failed that day (check gex_snapshot.log for a
`failed` line on that date).

---

## Background

*You never need this section to run a procedure. It explains what the
moving parts are.*

**What runs when.**
- `com.mimir.publish` -> `ops/run_publish.sh` -> `publish/publish.rb`
  LIVE, every **7200s (2h)**, decision D5-a. Runs the four analytics
  suites as subprocesses and writes all 11 KV keys in one pass. launchd
  starts no second instance while one is in flight (no `KeepAlive`), so a
  long publish just defers the next tick.
- `com.mimir.gex-snapshot` -> `ops/run_gex_snapshot.sh` ->
  `ops/gex_snapshot.rb`, once daily at **08:15 local**
  (`StartCalendarInterval`). Captures the two GEX `--json` outputs
  (`gex_btc_combined`, `gex_us IBIT MSTR`) into a dated local archive
  file. The exact hour is uncritical: a date-guard makes re-runs
  idempotent (today's file already there -> exit 0, untouched). It exits
  1 (alarms launchd) ONLY when BOTH captures fail, in which case no file
  is written; a partial (one venue) still writes and exits 0.

**File map.**
- Env file: `~/.config/mimir/env` (override `MIMIR_ENV_FILE`), mode
  `600`, holds `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` /
  `CLOUDFLARE_KV_NAMESPACE_ID` / `FRED_API_KEY`, optionally
  `BTC_DATA_DIR` / `MIMIR_RUBY` / `DEPLOY_NAME`. Sourced by both
  wrappers; **never printed** by any of them. If unreadable, a wrapper
  emits one path-naming line and exits **78** (`EX_CONFIG`) before
  sourcing anything -- nothing sensitive.
- Plists (templates): `ops/com.mimir.publish.plist`,
  `ops/com.mimir.gex-snapshot.plist`, each with a `__REPO__` placeholder
  substituted at install via `sed` (command in each plist's XML comment).
  Installed copies live in `~/Library/LaunchAgents/`.
- Wrappers: `ops/run_publish.sh`, `ops/run_gex_snapshot.sh` -- source the
  env file, prepend Homebrew to launchd's minimal PATH, `cd` to the repo,
  `exec` the ruby job so its exit code becomes the wrapper's (launchd
  alarms on real failure). Each run appends a `=== run_<name> <UTC>`
  marker to its log.
- Logs: `~/Library/Logs/mimir/publish.log` and `gex_snapshot.log`.
- Status file: `/tmp/publish.status`, frozen line
  `PUB LIVE|DRY <n>/<m> keys HH:MM UTC`, written by the pipeline and read
  by `ops/publish_health.rb` for the tmux bar (a parse failure collapses
  to the safe `PUB ?`, never crashes the bar).
- Snapshot archive: `$BTC_DATA_DIR/gex_history/YYYY-MM-DD.json` (or
  in-tree `data/gex_history/` when `BTC_DATA_DIR` is unset). Gitignored;
  never published to KV, never committed. Phase 9 (`expiry_low`) will
  consume it.

**No log rotation.** Neither wrapper rotates its log; both grow until you
truncate them by hand (section 9.2). This is deliberate -- the volume is
tiny and rotation is one more thing to break.

**KV budget.** 11 keys x 12 runs/day = 132 writes/day against the
1,000/day free-tier write limit -- ~13% utilisation, ample headroom.

**Why installs are HUMAN actions.** Installing/bootstrapping agents,
publishing for real, deploying, and mutating KV are all owner-only
(CLAUDE.md Golden Rule 3): the automation loop and CI are locked out of
anything that touches the network or production state. The tools here
prepare and print; you pull the trigger.
