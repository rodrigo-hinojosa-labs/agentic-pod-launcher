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

export QMD_WATCH_AGENT_YML="${WORKSPACE}/agent.yml"
export QMD_REINDEX_CMD="${SCRIPT_DIR}/agent-qmd-reindex.sh"

exec bash "${WORKSPACE}/scripts/qmd_watch.sh"
