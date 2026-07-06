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

**1.3 That is all the manual setup.** The old by-hand checks (env-file
mode, required-keys grep, wrapper smoke test, wrappers/plists present,
`launchctl` on PATH) are now the pre-flight table `rake ops:install`
prints and gates on in section 2 -- run it and read the rows instead of
grepping here. The pre-flight reports each key `present`/`MISSING` by
name only (line-anchored `^(export +)?KEY=.`, both `KEY=value` and
`export KEY=value` forms) and never prints a value. NOTE: `echo $KEY`
in your shell does NOT prove the env file is right -- launchd never sees
your shell; the wrappers read ONLY this file, which is exactly what the
pre-flight inspects.

---

## 2. Install the launchd agents

Installs both agents -- `com.mimir.publish` (bi-hourly publisher) and
`com.mimir.gex-snapshot` (daily 08:15 snapshot) -- with one interactive
command. Requires section 1 done. `rake ops:install` does the pre-flight,
renders each plist's `__REPO__` into `~/Library/LaunchAgents`, boots each
agent (bootout-then-bootstrap if already loaded), verifies the program
line, and -- per agent -- offers to kickstart the first run and POLLS its
log for the completion marker + summary (no `sleep`, no eyeballing). The
manual `sed`/`launchctl`/`sleep` sequence it replaces is kept in the
Background section ("Manual fallback") for reference only.

**2.1 Run the installer and answer the prompts.**

```
cd "$REPO"
rake ops:install
```

Answer `y` to both `kickstart <label> now? [y/N]` prompts on a fresh
install (say `y` to force the first publish and the first snapshot now;
`N` if you would rather wait for the scheduled run).

EXPECT: a `pre-flight:` table of `[ok ]` rows (env file mode 0600, four
keys `present`, ruby, both wrappers + plists, `ops/ audit` clean,
`launchctl`), then a `verification:` table where every row is `[PASS]`:

- `com.mimir.publish: plist` / `bootstrap` -> installed + `program = .../run_publish.sh`
- `com.mimir.publish: run` -> `publish LIVE: 11 written, 0 skipped -> KV`
- `com.mimir.publish: status file` -> `PUB LIVE 11/11 keys HH:MM UTC (age 0m)`
- `com.mimir.gex-snapshot: run` -> `written: .../<today>.json` (or `skipped
  (today's file exists)` / `partial` -- both PASS)
- `com.mimir.gex-snapshot: snapshot file` -> `present .../<today>.json`

Any `[FAIL]` row: fix it and re-run (`rake ops:install` is idempotent --
it bootouts and reinstalls a loaded agent). A pre-flight `[FAIL]` aborts
before any install; the row names the fix (missing key, wrong env-file
mode, `launchctl` not on PATH). A `run` row `TIMEOUT` means the run did
not complete within the poll window (publish 240s / snapshot 90s) --
read `~/Library/Logs/mimir/publish.log` and see section 8. A run row
carrying `ABORT`/`exit 78` means the wrapper could not read the env file
(re-check section 1.2) or a producer bailed.

**2.2 Verify the dashboard header advanced.** Open your dashboard URL in
a browser and look at the header.

EXPECT: `pub HH:MMZ · 11/11 fresh`, where `HH:MMZ` is the UTC minute the
publish `run` row reported. If the time is old, the publish did not reach
KV -- section 8.

Both agents are now live. They will run on their own schedule
(publisher every 2h, snapshot daily 08:15 local) from here on. Re-check
any time with `rake ops:status` (section 8, step 1).

---

## 3. Add the tmux health line

Puts a one-glance publisher-health indicator in the tmux status bar,
driven by `ops/publish_health.rb` reading `/tmp/publish.status`.

**3.1 Add three lines to `~/.tmux.conf`** (adjust the path to your
repo). The token goes on a SECOND status line -- the first one is
yours; this does not touch it:

```
set -g status 2
set -g status-format[1] '#[align=right]#(ruby /Users/<you>/Dev/mimir/ops/publish_health.rb)'
set -g status-interval 30
```

**3.2 Reload tmux config.**

```
tmux source-file ~/.tmux.conf
```

EXPECT: no error; a second status line appears with a `PUB ...` token
at its right edge within 30 seconds.

**3.3 Read the flag.** The token is `PUB <n>/<m> H:MM` (age is
hours:minutes since the last publish); no colours -- `!` after PUB is
the one attention flag, and the payload says why:

- `PUB 11/11 0:37` -- working: last publish LIVE, all 11 keys, age
  under 4h (2x the 2h cadence). Nothing to do.
- `PUB! 11/11 5:12` -- stale: age past 4h. The bigger the age, the
  worse -- if it keeps growing, section 8.
- `PUB! 10/11 0:20` -- a key is missing (`n < 11`). Glance at the
  dashboard for the red card; if it persists, section 8.
- `PUB! DRY 11/11 ...` -- the last run was a DRY-RUN publish, not
  LIVE. From the agent that should never happen; someone ran
  `PUBLISH_DRY_RUN=1` by hand. The dashboard is not being refreshed ->
  run a real publish (section 8, step 5).
- `PUB! ?` -- no status file, or unreadable/garbled. The publisher has
  never run on this box, or `/tmp` was cleared -> re-run
  `rake ops:install` (section 2) and answer `y` to the publish
  kickstart, then recheck.

---

## 4. Pause / resume / uninstall the agents

**4.1 Uninstall permanently** (bootout both agents, delete the
LaunchAgents copies so nothing reloads on next login):

```
cd "$REPO"
rake ops:uninstall
```

Answer `y` to the `bootout + remove installed plists? [y/N]` prompt.

EXPECT: an `uninstall:` table with a `booted out; installed plist removed`
row per label. A not-loaded agent shows `was not loaded` and is not an
error. Confirm: `ls ~/Library/LaunchAgents/com.mimir.*.plist` prints
`No such file or directory`. The repo's `ops/*.plist` templates are
untouched -- reinstall any time via section 2.

**4.2 Pause / resume one agent by hand** (temporary; a bootout-ed agent
reloads on next login, so this is not a permanent stop -- use 4.1 for
that). Pause:

```
launchctl bootout gui/$(id -u)/com.mimir.publish
```

Resume (re-bootstrap the installed plist):

```
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mimir.publish.plist
```

EXPECT: pause prints nothing and `launchctl print gui/$(id -u)/com.mimir.publish`
then reports `Could not find service`; resume restores `state = not running`.

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
grep -Eq '^(export +)?CLOUDFLARE_API_TOKEN=.' ~/.config/mimir/env && echo present
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

**Step 1 -- the one-command overview.**

```
cd "$REPO"
rake ops:status
```

EXPECT: an `ops status:` table. Per agent a `loaded; state=not running;
last exit=0` row (`not loaded` is a row, not a crash) plus a `... log`
row with the last `=== run_*` marker and summary; then a `status file`
row `PUB LIVE 11/11 keys HH:MM UTC (age Nm)` and a `newest gex snapshot`
row naming today's `<date>.json`.
FAILURE: `not loaded` -> the agent was never installed / got booted out,
re-run section 2 (`rake ops:install`). A nonzero `last exit` or a large
`status file` age -> a run failed; continue to Step 3 to see why. `status
file` `missing` or a `PUB ?`-worthy line -> the publisher never completed
on this box -> Step 3.

**Step 2 -- tmux line and dashboard age.**

```
ruby "$REPO/ops/publish_health.rb"
```

EXPECT: an unflagged `PUB 11/11 H:MM` with a small H:MM.
Cross-check the dashboard header `pub HH:MMZ · n/11 fresh`.
FAILURE: any `PUB! ...` (stale, partial, DRY, or `?` -- go to Step 3),
or the dashboard reads a many-hours age. If unflagged and fresh, the
pipeline is healthy -- your problem is elsewhere (browser cache?
refresh hard).

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

**Manual fallback (what `rake ops:install` does).** The installer wraps
the sequence below; run these by hand only if the task is unavailable or
you are debugging it. Per agent it renders the plist, (re)bootstraps, and
verifies -- the same steps, minus the polled PASS/FAIL table.

```
mkdir -p ~/Library/LaunchAgents
sed "s#__REPO__#$REPO#g" "$REPO/ops/com.mimir.publish.plist" \
  > ~/Library/LaunchAgents/com.mimir.publish.plist
sed "s#__REPO__#$REPO#g" "$REPO/ops/com.mimir.gex-snapshot.plist" \
  > ~/Library/LaunchAgents/com.mimir.gex-snapshot.plist
launchctl bootout gui/$(id -u)/com.mimir.publish 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mimir.publish.plist
launchctl bootout gui/$(id -u)/com.mimir.gex-snapshot 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mimir.gex-snapshot.plist
launchctl print gui/$(id -u)/com.mimir.publish | grep -E 'state|program'
```

The two `bootout ... 2>/dev/null` lines make a reinstall idempotent (they
no-op when nothing is loaded). Kickstart a first run + eyeball it with:

```
launchctl kickstart -k gui/$(id -u)/com.mimir.publish
sleep 120
tail -n 25 ~/Library/Logs/mimir/publish.log
launchctl kickstart -k gui/$(id -u)/com.mimir.gex-snapshot
sleep 60
tail -n 5 ~/Library/Logs/mimir/gex_snapshot.log
```

EXPECT (what the installer verifies for you): a `=== run_publish ...Z`
marker then `publish LIVE: 11 written, 0 skipped -> KV`; a
`=== run_gex_snapshot ...Z` marker then `written: .../<date>.json`.
Uninstall by hand = the two `bootout` lines plus
`rm -f ~/Library/LaunchAgents/com.mimir.*.plist`.

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
