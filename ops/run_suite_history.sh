#!/bin/bash
#
# run_suite_history.sh -- launchd wrapper for the daily mimir evidence-trail
# advance (the retired --history cron's successor; M7-5).
#
# PURPOSE
#   Source the owner's env file (which supplies BTC_DATA_DIR so the ledger /
#   history land in the same data directory the analytics suites use, plus
#   FRED_API_KEY for scenario's rates module), then exec ops/suite_history.rb
#   from the repo root. Exit code passes through: suite_history.rb exits 1 if
#   EITHER suite's --history run failed, so launchd alarms on a stalled
#   evidence trail and is silent when both trails advanced.
#
# USAGE
#   ops/run_suite_history.sh                      # normally invoked by launchd
#   MIMIR_ENV_FILE=/path ops/run_suite_history.sh # override the env-file path
#
# ENV CONTRACT
#   MIMIR_ENV_FILE  file to source (default: $HOME/.config/mimir/env).
#                   Must be readable; supplies FRED_API_KEY, may prepend to
#                   PATH and may set BTC_DATA_DIR. NEVER echoed by this wrapper.
#   BTC_DATA_DIR    runtime data root (default: the app-managed data home
#                   $HOME/Library/Application Support/mimir/data, M9-12). An
#                   explicit value (env file or environment) is honored.
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
#   - No log rotation here: $HOME/Library/Logs/mimir/suite_history.log grows
#     until rotated by hand.

set -eu

ENV_FILE="${MIMIR_ENV_FILE:-$HOME/.config/mimir/env}"
if [ ! -r "$ENV_FILE" ]; then
  echo "run_suite_history: env file not readable: $ENV_FILE -- see docs/RUNBOOK.md" >&2
  exit 78
fi

# Repo root resolved from this script's own location -- no hardcoded paths.
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

LOG_DIR="$HOME/Library/Logs/mimir"
mkdir -p "$LOG_DIR"
exec >>"$LOG_DIR/suite_history.log" 2>&1
echo "=== run_suite_history $(date -u +%Y-%m-%dT%H:%M:%SZ)"

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
exec "${MIMIR_RUBY:-ruby}" ops/suite_history.rb
