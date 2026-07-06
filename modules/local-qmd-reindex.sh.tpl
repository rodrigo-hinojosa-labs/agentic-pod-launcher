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

# PATH (013 RC2/FR-005): systemd's minimal default PATH for a system service
# excludes the operator's ~/.local/bin (where agent-bootstrap.sh installs bunx)
# and the vendored yq under scripts/vendor/bin. Without this, `command -v bunx`
# and yq silently fail (exit 0, fail-silent) and the index is NEVER refreshed.
# Set here — not on the unit — so the timer, the watcher's reindex dispatch, and
# the --login background setup all get it.
export PATH="{{OPERATOR_HOME}}/.local/bin:${WORKSPACE}/scripts/vendor/bin:$PATH"

# Workspace-durable storage: index + models travel with the workspace (parity
# with docker's ~/.cache/qmd ↔ .state bind, without a bind-mount). Vault dir and
# state file resolve under the workspace — never /home/agent.
#
# Storage env contract (013 RC1/FR-001/002): the qmd BINARY honors XDG_CACHE_HOME
# (index+models) and QMD_CONFIG_DIR (collections config) — NOT QMD_CACHE_HOME,
# which only the bash lib reads for its bookkeeping. Exporting XDG_CACHE_HOME=
# <ws>/.state/.cache makes the CLI write index.sqlite to <ws>/.state/.cache/qmd,
# exactly where QMD_CACHE_HOME points → lib and binary converge. QMD_CONFIG_DIR
# isolates the collection registry per workspace (no clash with a second agent or
# the operator's personal qmd). The MCP reader gets the same pair via .mcp.json.
export XDG_CACHE_HOME="${WORKSPACE}/.state/.cache"
export QMD_CONFIG_DIR="${WORKSPACE}/.state/.config/qmd"
export QMD_CACHE_HOME="${WORKSPACE}/.state/.cache/qmd"
export QMD_VAULT_DIR="{{LOCAL_VAULT_DIR}}"
export QMD_INDEX_STATE_FILE="${WORKSPACE}/scripts/heartbeat/qmd-index.json"
export VAULT_ROOT_OVERRIDE="{{LOCAL_VAULT_DIR}}"

mkdir -p "$QMD_CACHE_HOME" "$QMD_CONFIG_DIR" "$(dirname "$QMD_INDEX_STATE_FILE")" 2>/dev/null || true

# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../lib/qmd_index.sh"

qmd_setup_if_needed "$AGENT_YML" || true
if [ "${1:-}" = "--setup-only" ]; then
  exit 0
fi
qmd_reindex "$AGENT_YML" || true
exit 0
