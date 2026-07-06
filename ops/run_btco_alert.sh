#!/bin/bash
#
# run_btco_alert.sh -- launchd wrapper for the daily BTCo discovery alert.
#
# PURPOSE
#   Source the owner's env file (for EDGAR_UA -- the SEC courtesy
#   User-Agent -- and any PATH additions), then exec ops/btco_alert.rb from
#   the repo root. The alert runs `ingest.rb --dry --json`: a list-and-count
#   discovery only -- NO document fetch, NO AI, NO state mutation, NO API
#   spend (decision D6-a). btco_alert.rb ALWAYS exits 0 (the `ING ?` status
#   token, not the exit code, is how a broken discovery becomes visible), so
#   launchd never alarms on this job.
#
# USAGE
#   ops/run_btco_alert.sh                      # normally invoked by launchd
#   MIMIR_ENV_FILE=/path ops/run_btco_alert.sh # override the env-file path
#
# ENV CONTRACT
#   MIMIR_ENV_FILE  file to source (default: $HOME/.config/mimir/env).
#                   Must be readable; supplies EDGAR_UA (and any other
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
#   - No log rotation here: $HOME/Library/Logs/mimir/btco_alert.log grows
#     until rotated by hand.

set -eu

ENV_FILE="${MIMIR_ENV_FILE:-$HOME/.config/mimir/env}"
if [ ! -r "$ENV_FILE" ]; then
  echo "run_btco_alert: env file not readable: $ENV_FILE -- see docs/RUNBOOK.md" >&2
  exit 78
fi

# Repo root resolved from this script's own location -- no hardcoded paths.
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

LOG_DIR="$HOME/Library/Logs/mimir"
mkdir -p "$LOG_DIR"
exec >>"$LOG_DIR/btco_alert.log" 2>&1
echo "=== run_btco_alert $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# launchd's PATH is minimal; put Homebrew first so `ruby` resolves, then
# let the env file extend PATH further if it wants to.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
set -a
. "$ENV_FILE"
set +a

cd "$REPO_DIR"
exec "${MIMIR_RUBY:-ruby}" ops/btco_alert.rb
