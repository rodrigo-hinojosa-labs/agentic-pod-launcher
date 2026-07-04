# shellcheck shell=bash
# Library: self-managing QMD (@tobilu/qmd) index for the agent vault.
#
# Two responsibilities, both opt-in on vault.qmd.enabled:
#   - qmd_setup_if_needed: first-boot model download + initial index (idempotent).
#   - qmd_reindex:        keep the index fresh (flock-guarded, hash-debounced).
#
# Invoked from start_services.sh (setup, backgrounded) and from
# `heartbeatctl qmd-reindex` (reindex, via cron + the inotify watcher).
#
# Mirrors backup_vault.sh in shape (pure helpers + a hashed state file) and
# REUSES its vault_resolve_root + vault_hash so the index-freshness criterion
# matches the backup criterion. Pure function definitions only — no
# side-effecting code at source-time (CLAUDE.md: BASH_SOURCE-safe).
#
# QMD CLI (@tobilu/qmd >=2.5.x, verified against the package README):
#   qmd collection add <path> --name <n> [--mask '**/*.md']   # index a folder
#   qmd update                                                 # re-index all
#   qmd embed                                                  # (re)compute vectors; downloads ~300MB model on first run
#   qmd mcp                                                    # stdio MCP server (used by .mcp.json, not here)
# Storage defaults to ~/.cache/qmd/{index.sqlite,models/} → under the .state
# bind-mount, so it persists with no extra wiring.

# Reuse the vault resolver + hash. Image path first; repo-relative fallback so
# host bats tests that source this file get vault_resolve_root/vault_hash too.
# shellcheck source=/dev/null
if [ -f /opt/agent-admin/scripts/lib/backup_vault.sh ]; then
  source /opt/agent-admin/scripts/lib/backup_vault.sh
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/backup_vault.sh" ]; then
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/backup_vault.sh"
fi

_qmd_log() { echo "[qmd] $*" >&2; }

# The pinned package spec, single-sourced from agent.yml vault.qmd.version.
# Default 2.5.3 covers a pre-010 agent.yml regenerated without the key.
qmd_pkg() {
  local agent_yml="${1:-/workspace/agent.yml}"
  local ver=""
  if [ -f "$agent_yml" ] && command -v yq >/dev/null 2>&1; then
    ver=$(yq -r '.vault.qmd.version // ""' "$agent_yml" 2>/dev/null)
    [ "$ver" = "null" ] && ver=""
  fi
  [ -z "$ver" ] && ver="2.5.3"
  printf '@tobilu/qmd@%s\n' "$ver"
}

# QMD cache dir (index.sqlite, models/, sentinel, lock). Production: QMD's own
# default ~/.cache/qmd, which lands under .state. Test-overridable.
qmd_cache_root() { printf '%s\n' "${QMD_CACHE_HOME:-$HOME/.cache/qmd}"; }

# Atomic reindex state file. Test-overridable.
qmd_state_file() { printf '%s\n' "${QMD_INDEX_STATE_FILE:-/workspace/scripts/heartbeat/qmd-index.json}"; }

# Resolve the vault dir to index. Tests override via $QMD_VAULT_DIR; production
# reuses backup_vault.sh::vault_resolve_root (reads vault.path from agent.yml).
qmd_vault_dir() {
  local agent_yml="${1:-/workspace/agent.yml}"
  if [ -n "${QMD_VAULT_DIR:-}" ]; then printf '%s\n' "$QMD_VAULT_DIR"; return 0; fi
  command -v vault_resolve_root >/dev/null 2>&1 || return 0
  vault_resolve_root "$agent_yml"
}

# 0 iff BOTH vault.enabled and vault.qmd.enabled are true in agent.yml.
# QMD indexes the vault, so it is meaningless without the vault itself — and
# gating on qmd.enabled alone lets a contradictory config (qmd on, vault off)
# start a watcher that resolves no vault dir and dies, churning a respawn every
# 2s. Requiring both matches the setup contract (contracts/qmd-cli.md) and is
# the single gate shared by setup, reindex, the watcher and the cron line.
_qmd_enabled() {
  local agent_yml="${1:-/workspace/agent.yml}"
  [ -f "$agent_yml" ] || return 1
  command -v yq >/dev/null 2>&1 || return 1
  local vault_en qmd_en
  vault_en=$(yq -r '.vault.enabled // false' "$agent_yml" 2>/dev/null)
  qmd_en=$(yq -r '.vault.qmd.enabled // false' "$agent_yml" 2>/dev/null)
  [ "$vault_en" = "true" ] && [ "$qmd_en" = "true" ]
}

# _qmd_run PKG ARGS... — `bunx PKG ARGS`, bounded by timeout(1) when present
# (degrade to a direct call where it is absent, e.g. macOS dev), so a wedged
# download can never hang the boot before the watchdog (Principle IV).
_qmd_run() {
  local _to=""
  if command -v timeout >/dev/null 2>&1; then _to="timeout ${QMD_CMD_TIMEOUT:-900}"; fi
  # shellcheck disable=SC2086  # $_to must word-split into `timeout N` (or empty)
  $_to bunx "$@"
}

# Read the last indexed hash from the state file (empty if absent).
qmd_last_hash() {
  local state_file="$1"
  [ -f "$state_file" ] || { echo ""; return; }
  jq -r '.hash // ""' "$state_file" 2>/dev/null
}

# Atomic write of qmd-index.json: {hash, last_run, last_status, runs}.
# runs increments from the prior file. Mirrors vault_write_state's tmp+mv.
qmd_write_state() {
  local state_file="$1" hash="$2" status="$3"
  local dir tmp runs now
  dir=$(dirname "$state_file")
  mkdir -p "$dir" 2>/dev/null || true
  runs=0
  if [ -f "$state_file" ]; then
    runs=$(jq -r '.runs // 0' "$state_file" 2>/dev/null || echo 0)
  fi
  case "$runs" in *[!0-9]*) runs=0 ;; esac
  runs=$((runs + 1))
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  tmp=$(mktemp "$dir/.qmd-index.json.XXXXXX") || return 0
  if jq -n --arg hash "$hash" --arg status "$status" --arg run "$now" --argjson runs "$runs" \
      '{hash:$hash, last_run:$run, last_status:$status, runs:$runs}' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$state_file" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# First-boot setup: download model + build the initial index. Idempotent
# (sentinel + index.sqlite), fail-silent (always return 0; no sentinel on
# failure so the next boot retries). The CALLER backgrounds this so the
# ~300MB model download never blocks the watchdog.
qmd_setup_if_needed() {
  local agent_yml="${1:-/workspace/agent.yml}"
  _qmd_enabled "$agent_yml" || return 0
  local cache_root vault_dir sentinel pkg coll
  cache_root=$(qmd_cache_root)
  vault_dir=$(qmd_vault_dir "$agent_yml")
  [ -n "$vault_dir" ] || { _qmd_log "setup: vault not resolvable — skip"; return 0; }
  sentinel="$cache_root/.qmd-setup-ok"
  if [ -f "$sentinel" ] && [ -f "$cache_root/index.sqlite" ]; then
    _qmd_log "setup: already done — skip"
    return 0
  fi
  command -v bunx >/dev/null 2>&1 || { _qmd_log "setup: bunx unavailable — skip"; return 0; }
  mkdir -p "$cache_root" 2>/dev/null || true
  pkg=$(qmd_pkg "$agent_yml")
  coll="${QMD_COLLECTION_NAME:-vault}"
  # Only `collection add` when there's no index yet. If a prior run was
  # interrupted between `collection add` and the sentinel write, the collection
  # already exists and re-adding it would error — so when index.sqlite is
  # present we skip straight to `embed` (which is idempotent / re-embeds).
  if [ ! -f "$cache_root/index.sqlite" ]; then
    _qmd_log "setup: collection add via $pkg (vault=$vault_dir)"
    if ! _qmd_run "$pkg" collection add "$vault_dir" --name "$coll" --mask '**/*.md' >/dev/null 2>&1; then
      _qmd_log "setup: 'collection add' failed/timed out — retry next boot"
      return 0
    fi
  else
    _qmd_log "setup: index present, sentinel absent — refreshing only"
  fi
  # Contract (contracts/qmd-cli.md): add → update → embed. `update` re-scans the
  # collection so the re-entrant branch (index present, sentinel absent after an
  # interrupted run) also picks up any vault changes before embedding.
  if ! _qmd_run "$pkg" update >/dev/null 2>&1; then
    _qmd_log "setup: 'update' failed/timed out — retry next boot"
    return 0
  fi
  if ! _qmd_run "$pkg" embed >/dev/null 2>&1; then
    _qmd_log "setup: 'embed' failed/timed out — retry next boot"
    return 0
  fi
  : > "$sentinel" 2>/dev/null || true
  _qmd_log "setup: complete"
  return 0
}

# Reindex if the vault changed. flock-guarded (concurrency-safe across the
# cron backstop + the inotify watcher), hash-debounced (skips embed when
# unchanged). Always returns 0 (a cron tick / watcher must never crash).
qmd_reindex() {
  local agent_yml="${1:-/workspace/agent.yml}"
  _qmd_enabled "$agent_yml" || { _qmd_log "reindex: qmd disabled — skip"; return 0; }
  local cache_root vault_dir lock
  cache_root=$(qmd_cache_root)
  vault_dir=$(qmd_vault_dir "$agent_yml")
  [ -n "$vault_dir" ] || { _qmd_log "reindex: vault not resolvable — skip"; return 0; }
  [ -d "$vault_dir" ] || { _qmd_log "reindex: vault dir $vault_dir missing — skip"; return 0; }
  mkdir -p "$cache_root" 2>/dev/null || true
  lock="$cache_root/.reindex.lock"

  if command -v flock >/dev/null 2>&1; then
    local rc=0
    # `|| rc=$?` neutralises set -e in any caller: the subshell exiting 91 (lock
    # held by a concurrent run) — or any non-zero — must never abort a caller
    # running under set -euo pipefail (e.g. start_services.sh). Principle IV.
    (
      if ! flock -n 9; then _qmd_log "reindex: already running — skip"; exit 91; fi
      _qmd_reindex_locked "$agent_yml" "$vault_dir"
    ) 9>"$lock" || rc=$?
    [ "$rc" -eq 91 ] && return 0
    return 0
  fi
  # flock absent (macOS dev host): run without the lock; the cron backstop +
  # hash-debounce keep the damage to at worst a redundant embed.
  _qmd_log "reindex: flock unavailable — running unlocked (dev degrade)"
  _qmd_reindex_locked "$agent_yml" "$vault_dir"
  return 0
}

# Critical section of qmd_reindex (runs under flock when available).
_qmd_reindex_locked() {
  local agent_yml="$1" vault_dir="$2"
  local state_file current last pkg
  state_file=$(qmd_state_file)
  current=$(vault_hash "$vault_dir" 2>/dev/null || echo "")
  last=$(qmd_last_hash "$state_file")
  if [ -n "$current" ] && [ "$current" = "$last" ]; then
    _qmd_log "reindex: vault unchanged ($current) — skip embed"
    qmd_write_state "$state_file" "$current" "skipped"
    return 0
  fi
  command -v bunx >/dev/null 2>&1 || { _qmd_log "reindex: bunx unavailable — skip"; return 0; }
  pkg=$(qmd_pkg "$agent_yml")
  _qmd_log "reindex: update + embed via $pkg"
  if ! _qmd_run "$pkg" update >/dev/null 2>&1; then
    _qmd_log "reindex: 'update' failed/timed out"
    qmd_write_state "$state_file" "$last" "error"
    return 0
  fi
  if ! _qmd_run "$pkg" embed >/dev/null 2>&1; then
    _qmd_log "reindex: 'embed' failed/timed out"
    qmd_write_state "$state_file" "$last" "error"
    return 0
  fi
  qmd_write_state "$state_file" "$current" "indexed"
  _qmd_log "reindex: done ($current)"
  return 0
}
