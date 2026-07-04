#!/usr/bin/env bash
# Local-mode QMD reindex entrypoint. Rendered from modules/local-qmd-reindex.sh.tpl
# — do not hand-edit (use ./setup.sh --regenerate). Runs the shared qmd_index.sh
# against the workspace vault + a workspace-durable cache.
#
# Two roles (self-healing double hook, FR-004):
#   --setup-only : first-run setup, dispatched in the background by --login.
#   (no arg)     : the reindex timer path — always runs setup-if-needed first
#                  (sentinel = instant no-op) THEN reindex (flock + hash-debounce),
#                  so a skipped/failed login still gets an index on the first tick.
#
# Always exits 0 (Principle IV, fail-silent): detail goes to the systemd journal
# and the machine-readable state file. Gated by the lib's own _qmd_enabled.
set -uo pipefail

WORKSPACE="{{DEPLOYMENT_WORKSPACE}}"
AGENT_YML="${WORKSPACE}/agent.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Workspace-durable storage: index + models travel with the workspace (parity
# with docker's ~/.cache/qmd ↔ .state bind, without a bind-mount). Vault dir and
# state file resolve under the workspace — never /home/agent.
export QMD_CACHE_HOME="${WORKSPACE}/.state/.cache/qmd"
export QMD_VAULT_DIR="{{LOCAL_VAULT_DIR}}"
export QMD_INDEX_STATE_FILE="${WORKSPACE}/scripts/heartbeat/qmd-index.json"
export VAULT_ROOT_OVERRIDE="{{LOCAL_VAULT_DIR}}"

mkdir -p "$QMD_CACHE_HOME" "$(dirname "$QMD_INDEX_STATE_FILE")" 2>/dev/null || true

# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../lib/qmd_index.sh"

qmd_setup_if_needed "$AGENT_YML" || true
if [ "${1:-}" = "--setup-only" ]; then
  exit 0
fi
qmd_reindex "$AGENT_YML" || true
exit 0
