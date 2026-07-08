#!/usr/bin/env bash
# Local-mode wiki-graph entrypoint. Rendered from modules/local-wiki-graph.sh.tpl
# — do not hand-edit (use ./setup.sh --regenerate). Runs the shared wiki_graph.sh
# against the workspace vault, deriving <vault>/.graph/{graph,backlinks,findings}
# .json + the wiki-graph.json state file. Never edits the wiki.
#
# Always exits 0 (Principle IV, fail-silent): detail goes to the systemd journal
# and the machine-readable state file. Gated by the lib's own wiki_graph_enabled.
set -uo pipefail

WORKSPACE="{{DEPLOYMENT_WORKSPACE}}"
AGENT_YML="${WORKSPACE}/agent.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# PATH (013 RC2 lesson, applied day-1): systemd's minimal default PATH for a
# system service excludes the vendored yq under scripts/vendor/bin and the
# operator's ~/.local/bin. Without this, `command -v yq` fails (exit 0,
# fail-silent) and the graph is NEVER refreshed while systemctl shows the timer
# healthy. Set here — not on the unit — so the timer AND the manual action
# (agentctl heartbeat wiki-graph) both get it.
export PATH="{{OPERATOR_HOME}}/.local/bin:${WORKSPACE}/scripts/vendor/bin:$PATH"

# Vault env: resolve the REAL workspace vault, not the container /home/agent
# default (which does not exist on the host). VAULT_ROOT_OVERRIDE wins in
# vault_resolve_root; WIKI_GRAPH_VAULT_DIR is the direct override the lib reads
# first. State file + lock live under the workspace heartbeat dir, NEVER inside
# the vault (Syncthing must not sync the lock/state).
export VAULT_ROOT_OVERRIDE="{{LOCAL_VAULT_DIR}}"
export WIKI_GRAPH_VAULT_DIR="{{LOCAL_VAULT_DIR}}"
export WIKI_GRAPH_STATE_FILE="${WORKSPACE}/scripts/heartbeat/wiki-graph.json"
export WIKI_GRAPH_LOCK="${WORKSPACE}/scripts/heartbeat/.wiki-graph.lock"

mkdir -p "$(dirname "$WIKI_GRAPH_STATE_FILE")" 2>/dev/null || true

# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../lib/wiki_graph.sh"

wiki_graph_run "$AGENT_YML" || true
exit 0
