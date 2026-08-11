#!/bin/bash
#
# run_publish.sh -- launchd/cron wrapper for the mimir bi-hourly publisher.
#
# PURPOSE
#   Source the owner's env file, then run the publish pipeline LIVE
#   (PUBLISH_DRY_RUN=0) from the repo root, appending all output to a
#   log. This is the single scheduled publisher job (decision D5-a,
#   bi-hourly). publish/publish.rb runs the four analytics suites as
#   subprocesses and writes the KV keys in one pass; ITS exit code is
#   THIS script's exit code (exec), so launchd/cron alarm on a real
#   publish failure.
#
# USAGE
#   ops/run_publish.sh                     # normally invoked by launchd
#   MIMIR_ENV_FILE=/path ops/run_publish.sh  # override the env-file path
#
# ENV CONTRACT
#   MIMIR_ENV_FILE  file to source (default: $HOME/.config/mimir/env).
#                   Must be readable; supplies CLOUDFLARE_* / FRED_API_KEY
#                   and may prepend to PATH. NEVER echoed by this wrapper.
#   MIMIR_RUBY      ruby interpreter to exec (default: `ruby` on PATH).
#                   Set when the target ruby is not first on launchd's PATH.
#   BTC_DATA_DIR    runtime data root (default: the app-managed data home
#                   $HOME/Library/Application Support/mimir/data, M9-12). An
#                   explicit value (env file or environment) is honored.
#   HOME            locates the default env file, the data home, and the logs.
#
# CAVEATS
#   - Secrets live ONLY in the env file. This wrapper never prints env
#     values or file contents. An unreadable env file yields ONE path-
#     naming line on stderr and exit 78 (sysexits EX_CONFIG) -- nothing
#     sensitive, since we abort before sourcing anything.
#   - launchd's default PATH lacks Homebrew, so we prepend the usual
#     Homebrew bin dirs before sourcing (the env file may extend PATH).
#   - Installing the launchd agent is a HUMAN action (Golden Rule 3);
#     see docs/RUNBOOK.md.
#   - No log rotation here: $HOME/Library/Logs/mimir/publish.log grows
#     until rotated by hand.

set -eu

ENV_FILE="${MIMIR_ENV_FILE:-$HOME/.config/mimir/env}"
if [ ! -r "$ENV_FILE" ]; then
  echo "run_publish: env file not readable: $ENV_FILE -- see docs/RUNBOOK.md" >&2
  exit 78
fi

# Repo root resolved from this script's own location -- no hardcoded paths.
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

LOG_DIR="$HOME/Library/Logs/mimir"
mkdir -p "$LOG_DIR"
exec >>"$LOG_DIR/publish.log" 2>&1
echo "=== run_publish $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# launchd's PATH is minimal; put Homebrew first so `ruby` resolves, then
# let the env file extend PATH further if it wants to.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
set -a
. "$ENV_FILE"
set +a

# M9-12: production agents run from the app-managed live clone with a
# stable data home, so the dev checkout is stateless. Default BTC_DATA_DIR
# to that data home; an explicit value (env file or environment) wins.
export BTC_DATA_DIR="${BTC_DATA_DIR:-$HOME/Library/Application Support/mimir/data}"

cd "$REPO_DIR"

# M8-9: try to heal today's data-integrity gaps (blind scenario row, stale
# lppl ledger, errored/missing GEX-or-vol snapshot) BEFORE publishing so a
# repair lands in this very tick. Fail-soft: repair.rb exits 0 by design, but
# `|| ...` guards even a fatal crash so it can NEVER block the publish.
"${MIMIR_RUBY:-ruby}" ops/repair.rb || echo "run_publish: repair step failed (continuing to publish)" >&2

export PUBLISH_DRY_RUN=0
exec "${MIMIR_RUBY:-ruby}" publish/publish.rb
