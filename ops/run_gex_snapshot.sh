#!/bin/bash
#
# run_gex_snapshot.sh -- launchd wrapper for the daily mimir GEX snapshot.
#
# PURPOSE
#   Source the owner's env file (which supplies BTC_DATA_DIR so snapshots
#   land in the same data directory the analytics suites use), then exec
#   ops/gex_snapshot.rb from the repo root. Exit code passes through:
#   gex_snapshot.rb exits 1 only when BOTH captures fail, so launchd alarms
#   on a true both-fail and is silent on a partial or a date-guard skip.
#
# USAGE
#   ops/run_gex_snapshot.sh                      # normally invoked by launchd
#   MIMIR_ENV_FILE=/path ops/run_gex_snapshot.sh # override the env-file path
#
# ENV CONTRACT
#   MIMIR_ENV_FILE  file to source (default: $HOME/.config/mimir/env).
#                   Must be readable; supplies BTC_DATA_DIR (and any other
#                   vars) and may prepend to PATH. NEVER echoed by this wrapper.
#   MIMIR_RUBY      ruby interpreter to exec (default: `ruby` on PATH).
#                   Set when the target ruby is not first on launchd's PATH.
#   HOME            locates the default env file and the log directory.
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
#   - No log rotation here: $HOME/Library/Logs/mimir/gex_snapshot.log grows
#     until rotated by hand.

set -eu

ENV_FILE="${MIMIR_ENV_FILE:-$HOME/.config/mimir/env}"
if [ ! -r "$ENV_FILE" ]; then
  echo "run_gex_snapshot: env file not readable: $ENV_FILE -- see docs/RUNBOOK.md" >&2
  exit 78
fi

# Repo root resolved from this script's own location -- no hardcoded paths.
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

LOG_DIR="$HOME/Library/Logs/mimir"
mkdir -p "$LOG_DIR"
exec >>"$LOG_DIR/gex_snapshot.log" 2>&1
echo "=== run_gex_snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# launchd's PATH is minimal; put Homebrew first so `ruby` resolves, then
# let the env file extend PATH further if it wants to.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
set -a
. "$ENV_FILE"
set +a

cd "$REPO_DIR"
exec "${MIMIR_RUBY:-ruby}" ops/gex_snapshot.rb
