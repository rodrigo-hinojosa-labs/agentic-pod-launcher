#!/usr/bin/env bash
# Local-mode QMD watcher wrapper. Rendered from modules/local-qmd-watch.sh.tpl —
# do not hand-edit (use ./setup.sh --regenerate). Runs the shared qmd_watch.sh
# with the reindex command pointed at the local entrypoint.
#
# Degradation without inotify-tools is handled by the systemd unit's
# ExecCondition (command -v inotifywait) — a failed condition leaves the unit
# inactive with NO restart-loop; the reindex timer is the backstop. This wrapper
# just wires the env and execs the shared watcher.
set -uo pipefail

WORKSPACE="{{DEPLOYMENT_WORKSPACE}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# PATH (013 RC2/FR-005): so qmd_watch.sh finds yq (it reads agent.yml) and its
# reindex dispatch finds bunx. systemd's minimal service PATH excludes both.
export PATH="{{OPERATOR_HOME}}/.local/bin:${WORKSPACE}/scripts/vendor/bin:$PATH"

export QMD_WATCH_AGENT_YML="${WORKSPACE}/agent.yml"
export QMD_REINDEX_CMD="${SCRIPT_DIR}/agent-qmd-reindex.sh"
# 013 RC3/FR-006: give the watcher the REAL workspace vault. Without these,
# qmd_watch.sh resolves the vault via vault_resolve_root → /home/agent/.vault
# (the container default), which doesn't exist on the host → the watcher exits
# immediately at startup. Same override pattern as the reindex/backup wrappers.
export QMD_VAULT_DIR="{{LOCAL_VAULT_DIR}}"
export VAULT_ROOT_OVERRIDE="{{LOCAL_VAULT_DIR}}"

# Supervised loop (013 FR-007/D5): replaces `exec` so a transient exit of
# qmd_watch.sh (vault briefly moved by Syncthing, inotify hiccup) is retried
# in-process instead of exiting the unit. With Restart=always + StartLimitBurst=5,
# a bare exec that exits repeatedly would hit the start-limit and leave the unit
# `failed` permanently in <35s; here the unit stays `active` and `failed` now
# means a real anomaly (feeds the healthcheck WARN, FR-011). The unit's
# ExecCondition still gates inotify-tools absence BEFORE this loop ever starts, so
# there's no busy-loop when inotifywait is missing.
while :; do
  bash "${WORKSPACE}/scripts/qmd_watch.sh"
  sleep 30
done
