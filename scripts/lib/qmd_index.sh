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

# 015 US3/US4: shared observability helpers (redact_secrets + scratch_dir).
# Image-first / repo-relative, same pattern as backup_vault.sh above.
# shellcheck source=/dev/null
if [ -f /opt/agent-admin/scripts/lib/rag_obs.sh ]; then
  source /opt/agent-admin/scripts/lib/rag_obs.sh
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/rag_obs.sh" ]; then
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/rag_obs.sh"
fi
command -v scratch_dir >/dev/null 2>&1 || scratch_dir() { printf '%s\n' "${TMPDIR:-/tmp}"; }

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

# 016: qmd is installed from a MANAGED bun prefix, not `bunx`. The prefix pins
# @tobilu/qmd and trusts ONLY the deps whose native build qmd actually needs, so
# tree-sitter-* stay unbuilt (qmd uses the web-tree-sitter WASM grammar) while
# node-llama-cpp / better-sqlite3 compile. This is the root-cause fix for BUG 4:
# `bunx PKG` let bun run EVERY dep's install-script → tree-sitter node-gyp aborted
# the whole install on Alpine musl (no glibc prebuild loads, no compiler).

# The bigstack LD_PRELOAD shim path (docker image only; overridable for tests).
QMD_BIGSTACK_SO="${QMD_BIGSTACK_SO:-/opt/agent-admin/bigstack.so}"

# The managed install prefix (holds package.json + node_modules/.bin/qmd).
_qmd_prefix() { printf '%s\n' "$(qmd_cache_root)/pkg"; }

# 017: the baked musl-compiled sqlite-vec extension (docker image only;
# overridable for tests). sqlite-vec ships a GLIBC prebuilt
# (node_modules/sqlite-vec-linux-arm64/vec0.so) that CANNOT dlopen under musl —
# it needs ld-linux-aarch64.so.1 and fortified GLIBC_2.17 symbols (__memcpy_chk /
# __fread_chk). The Dockerfile compiles a musl vec0.so at build time and bakes it
# here; the swap below replaces the glibc prebuilt in the prefix. On glibc (local
# mode) the artifact is absent and the prebuilt loads fine → no-op.
QMD_VEC0_MUSL_SO="${QMD_VEC0_MUSL_SO:-/opt/agent-admin/sqlite-vec/vec0.so}"

# 0 iff the running libc is musl. Overridable for host tests via QMD_MUSL_LOADER
# (point it at an existing file for musl, an absent one for glibc). Production:
# presence of a musl dynamic loader under /lib.
_qmd_on_musl() {
  if [ -n "${QMD_MUSL_LOADER+x}" ]; then [ -e "$QMD_MUSL_LOADER" ]; return; fi
  ls /lib/ld-musl-*.so.1 >/dev/null 2>&1
}

# _qmd_swap_sqlite_vec PREFIX — on musl, replace the glibc sqlite-vec prebuilt in
# the managed prefix with the baked musl build so `qmd embed`/`vsearch` can load
# the vec0 extension. Gated by (a) musl libc and (b) the baked artifact existing;
# on glibc the artifact is absent → no-op. Idempotent (cmp-skip). Fail-silent: on
# musl with the artifact absent (e.g. QMD_NATIVE_TOOLCHAIN=0) log + continue — the
# lexical index still works, only vector embed is unavailable (Principle IV).
_qmd_swap_sqlite_vec() {
  local prefix="$1"
  local target="$prefix/node_modules/sqlite-vec-linux-arm64/vec0.so"
  _qmd_on_musl || return 0                 # glibc: prebuilt already loads
  [ -e "$target" ] || return 0             # sqlite-vec package not present
  if [ ! -f "$QMD_VEC0_MUSL_SO" ]; then
    _qmd_log "sqlite-vec: musl build absent ($QMD_VEC0_MUSL_SO) — vector embed unavailable, lexical index intact"
    return 0
  fi
  cmp -s "$QMD_VEC0_MUSL_SO" "$target" 2>/dev/null && return 0   # already musl
  if cp -f "$QMD_VEC0_MUSL_SO" "$target" 2>/dev/null; then
    _qmd_log "sqlite-vec: swapped glibc prebuilt for musl build"
  else
    _qmd_log "sqlite-vec: swap failed (cp) — vector embed may be unavailable"
  fi
  return 0
}

# The pinned manifest. trustedDependencies lists ONLY better-sqlite3 (store) and
# node-llama-cpp (embeddings) — tree-sitter-* are DELIBERATELY absent so bun's
# default-deny leaves them unbuilt. Keep this the single definition (tests assert
# its exact shape).
_qmd_manifest() {
  printf '{\n  "dependencies": { "@tobilu/qmd": "%s" },\n  "trustedDependencies": ["better-sqlite3", "node-llama-cpp"]\n}\n' "$1"
}

# Extract the version from a PKG spec (@tobilu/qmd@2.5.3 → 2.5.3); no explicit
# version → "latest".
_qmd_ver() {
  case "$1" in
    *@*@*) printf '%s\n' "${1##*@}" ;;
    *)     printf '%s\n' "latest" ;;
  esac
}

# Portable sha256 (Linux coreutils / macOS shasum) of stdin.
_qmd_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}';
  else shasum -a 256 2>/dev/null | awk '{print $1}'; fi
}

# _qmd_ensure_prefix PKG — idempotently install qmd into the managed prefix so
# tree-sitter-* stay unbuilt (WASM grammar) while node-llama-cpp/better-sqlite3
# compile. Shared by _qmd_run (batch, timeout) and qmd_mcp_exec (server, no
# timeout). Returns non-zero (and logs the REAL, redacted build error) when the
# native build failed and the prefix binary is absent — so callers surface BUG 4
# instead of a misleading "No such file or directory".
_qmd_ensure_prefix() {
  local pkg="$1"
  local _to_build="" _scratch prefix ver manifest want have ilog
  if command -v timeout >/dev/null 2>&1; then
    # The one-time from-source native build (node-llama-cpp/llama.cpp on musl
    # aarch64) can dwarf a recurrent update; give it its OWN, larger budget so a
    # legitimately long compile is not SIGTERM'd into a loop that never writes
    # .installed-hash (setup runs backgrounded, so a long build is safe).
    # QMD_INSTALL_TIMEOUT=0 => uncapped.
    _to_build="timeout ${QMD_INSTALL_TIMEOUT:-3600}"
    [ "${QMD_INSTALL_TIMEOUT:-3600}" = "0" ] && _to_build=""
  fi
  # 015 US3: keep the bun cache + every qmd/native-build temporary on host-backed
  # .state (under the qmd cache root), not the 100MB tmpfs /tmp it otherwise fills
  # → ENOSPC for qmd AND the wiki-graph runner. Also survives restarts.
  _scratch=$(scratch_dir "$(qmd_cache_root)")
  prefix="$(_qmd_prefix)"
  mkdir -p "$prefix" 2>/dev/null || true
  ver="$(_qmd_ver "$pkg")"
  manifest="$(_qmd_manifest "$ver")"
  want="$(printf '%s' "$manifest" | _qmd_sha)"
  have=""
  [ -f "$prefix/.installed-hash" ] && have="$(cat "$prefix/.installed-hash" 2>/dev/null)"
  # (Re)install only when the manifest changed OR the binary is missing — hash
  # guard, not mtime (Principle IV). node-llama-cpp's native build runs HERE under
  # portable-ARM cmake options so llama.cpp compiles on musl aarch64 without
  # -march=native (016 research Decision 1). GGML_* only affect the build step.
  if [ "$want" != "$have" ] || [ ! -x "$prefix/node_modules/.bin/qmd" ]; then
    printf '%s' "$manifest" > "$prefix/package.json"
    ilog="$_scratch/qmd-install.err"
    # shellcheck disable=SC2086  # $_to_build must word-split into `timeout N` (or empty)
    if ( cd "$prefix" && \
         NODE_LLAMA_CPP_CMAKE_OPTION_GGML_NATIVE=OFF \
         NODE_LLAMA_CPP_CMAKE_OPTION_GGML_CPU_ARM_ARCH=armv8-a \
         TMPDIR="$_scratch" TMP="$_scratch" TEMP="$_scratch" $_to_build bun install >"$ilog" 2>&1 ); then
      printf '%s' "$want" > "$prefix/.installed-hash"
    fi
    # 016/US4: if the native build (cmake/gcc/node-llama-cpp) failed, the prefix
    # binary is absent — surface the REAL, redacted compile error (BUG 4's root
    # cause) and stop, so the caller's exec can't overwrite the diagnosis with a
    # misleading "No such file or directory". This lands on fd2, which the reindex
    # caller captures into its rlog + tails redacted. If an OLD binary survived a
    # failed RE-install, return 0 and let the caller run it (degrade to the prior
    # version rather than losing indexing entirely — Principle IV).
    if [ ! -x "$prefix/node_modules/.bin/qmd" ]; then
      _qmd_log "install: bun install failed for $pkg: $(_qmd_tail_redacted "$ilog")"
      return 1
    fi
  fi
  # 017: ensure the vec0 extension can load under musl (idempotent; no-op on
  # glibc). Runs every ensure — a prefix restored from .state onto a fresh musl
  # container still needs the swap even when the install itself was skipped.
  _qmd_swap_sqlite_vec "$prefix"
  return 0
}

# _qmd_run PKG ARGS... — run a BATCH qmd command from the managed prefix, bounded
# by timeout(1) when present (degrade to a direct call where absent, e.g. macOS
# dev), so a wedged download/build can never hang the boot before the watchdog
# (Principle IV). NOT for the long-running MCP server — see qmd_mcp_exec.
_qmd_run() {
  local pkg="$1"; shift
  local _to="" _scratch prefix ld=""
  if command -v timeout >/dev/null 2>&1; then _to="timeout ${QMD_CMD_TIMEOUT:-900}"; fi
  _qmd_ensure_prefix "$pkg" || return 1
  _scratch=$(scratch_dir "$(qmd_cache_root)")
  prefix="$(_qmd_prefix)"
  # Runtime std::regex/stack mitigation (musl's 128KB pthread stack SIGSEGVs on the
  # tokenizer/grammar recursion): preload the 8MB-stack shim ONLY for `embed`, and
  # only when it exists (docker image; absent on glibc local where it isn't needed).
  # Scoped, never global → bun/tmux/other procs unaffected.
  if [ "${1:-}" = "embed" ] && [ -f "$QMD_BIGSTACK_SO" ]; then ld="$QMD_BIGSTACK_SO"; fi
  # shellcheck disable=SC2086  # $_to must word-split into `timeout N` (or empty)
  LD_PRELOAD="$ld" TMPDIR="$_scratch" TMP="$_scratch" TEMP="$_scratch" \
    $_to "$prefix/node_modules/.bin/qmd" "$@"
}

# qmd_mcp_exec [PKG] — exec the long-running qmd MCP stdio server from the SAME
# managed prefix (T036: the MCP path must NOT use `bunx`, which recompiles
# tree-sitter and aborts on Alpine musl — BUG 4). No timeout (it runs for the
# life of the Claude session); LD_PRELOAD=bigstack when present because the MCP
# server embeds queries at runtime (same node-llama-cpp/musl std::regex hazard as
# `embed`). Called by the image-baked/workspace `qmd-mcp` wrapper.
qmd_mcp_exec() {
  local pkg="${1:-$(qmd_pkg)}"
  local _scratch prefix ld=""
  _qmd_ensure_prefix "$pkg" || return 1
  _scratch=$(scratch_dir "$(qmd_cache_root)")
  prefix="$(_qmd_prefix)"
  [ -f "$QMD_BIGSTACK_SO" ] && ld="$QMD_BIGSTACK_SO"
  exec env LD_PRELOAD="$ld" TMPDIR="$_scratch" TMP="$_scratch" TEMP="$_scratch" \
    "$prefix/node_modules/.bin/qmd" mcp
}

# Read the last indexed hash from the state file (empty if absent).
qmd_last_hash() {
  local state_file="$1"
  [ -f "$state_file" ] || { echo ""; return; }
  jq -r '.hash // ""' "$state_file" 2>/dev/null
}

# Atomic write of qmd-index.json: {hash, last_run, last_status, runs[, pending]}.
# runs increments from the prior file. Mirrors vault_write_state's tmp+mv.
#
# 018: optional 4th arg PENDING (documents still needing an embedding — see
# contracts/reindex-state.md). When given (a non-negative integer), it is
# written verbatim. When omitted (legacy 3-arg callers), the PRIOR file's
# `pending` is carried over unchanged — including its absence: a state file
# that has never recorded a pending count stays without one, which
# `_qmd_reindex_locked` reads as "unknown" and treats as "must resume", never
# as "0 pending" (that distinction is the FR-003 resume guarantee).
qmd_write_state() {
  local state_file="$1" hash="$2" status="$3" pending="${4:-}"
  local dir tmp runs now prev_pending_json pending_json
  dir=$(dirname "$state_file")
  mkdir -p "$dir" 2>/dev/null || true
  runs=0
  prev_pending_json="null"
  if [ -f "$state_file" ]; then
    runs=$(jq -r '.runs // 0' "$state_file" 2>/dev/null || echo 0)
    prev_pending_json=$(jq -c '.pending // null' "$state_file" 2>/dev/null || echo null)
  fi
  case "$runs" in *[!0-9]*) runs=0 ;; esac
  runs=$((runs + 1))
  case "$pending" in
    ''|*[!0-9]*) pending_json="$prev_pending_json" ;;
    *) pending_json="$pending" ;;
  esac
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  tmp=$(mktemp "$dir/.qmd-index.json.XXXXXX") || return 0
  if jq -n --arg hash "$hash" --arg status "$status" --arg run "$now" --argjson runs "$runs" \
      --argjson pending "$pending_json" \
      '{hash:$hash, last_run:$run, last_status:$status, runs:$runs} + (if $pending == null then {} else {pending:$pending} end)' \
      > "$tmp" 2>/dev/null; then
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
  local cache_root vault_dir sentinel lock
  cache_root=$(qmd_cache_root)
  vault_dir=$(qmd_vault_dir "$agent_yml")
  [ -n "$vault_dir" ] || { _qmd_log "setup: vault not resolvable — skip"; return 0; }
  sentinel="$cache_root/.qmd-setup-ok"
  # Fast path: sentinel-hit is an instant no-op that must NOT take the lock (so a
  # steady-state boot never contends with a running reindex).
  if [ -f "$sentinel" ] && [ -f "$cache_root/index.sqlite" ]; then
    _qmd_log "setup: already done — skip"
    return 0
  fi
  mkdir -p "$cache_root" 2>/dev/null || true
  lock="$cache_root/.reindex.lock"

  # 013 FR-015: serialize setup under the SAME lock as reindex, so the --login
  # background dispatch and the first timer tick can't both download the ~300MB
  # model or race `collection add`. The loser skips (exit 91); the next tick's
  # guard covers the retry. Mirrors qmd_reindex's flock structure exactly.
  if command -v flock >/dev/null 2>&1; then
    local rc=0
    (
      if ! flock -n 9; then _qmd_log "setup: already running — skip"; exit 91; fi
      _qmd_setup_locked "$agent_yml" "$cache_root" "$vault_dir" "$sentinel"
    ) 9>"$lock" || rc=$?
    [ "$rc" -eq 91 ] && return 0
    return 0
  fi
  # flock absent (macOS dev host): run unlocked; the sentinel + boot cadence keep
  # the worst case to a redundant embed.
  _qmd_log "setup: flock unavailable — running unlocked (dev degrade)"
  _qmd_setup_locked "$agent_yml" "$cache_root" "$vault_dir" "$sentinel"
  return 0
}

# Critical section of qmd_setup_if_needed (runs under flock when available).
_qmd_setup_locked() {
  local agent_yml="$1" cache_root="$2" vault_dir="$3" sentinel="$4"
  local pkg coll slog
  # 016/US4: capture the setup run (which is where the native build FIRST runs on
  # a fresh boot) so a failing compile is diagnosable here, not just on the next
  # reindex tick. Redacted tail only — never the raw stream (Principle V).
  slog="$(scratch_dir "$cache_root")/qmd-setup.err"
  # Double-checked locking: a concurrent winner may have finished between our
  # pre-lock sentinel check and acquiring the lock — re-check inside the lock.
  if [ -f "$sentinel" ] && [ -f "$cache_root/index.sqlite" ]; then
    _qmd_log "setup: completed by a concurrent run — skip"
    return 0
  fi
  command -v bun >/dev/null 2>&1 || { _qmd_log "setup: bun unavailable — skip"; return 0; }
  pkg=$(qmd_pkg "$agent_yml")
  coll="${QMD_COLLECTION_NAME:-vault}"
  # Only `collection add` when there's no index yet. If a prior run was
  # interrupted between `collection add` and the sentinel write, the collection
  # already exists and re-adding it would error — so when index.sqlite is
  # present we skip straight to `embed` (which is idempotent / re-embeds).
  if [ ! -f "$cache_root/index.sqlite" ]; then
    _qmd_log "setup: collection add via $pkg (vault=$vault_dir)"
    if ! _qmd_run "$pkg" collection add "$vault_dir" --name "$coll" --mask '**/*.md' >"$slog" 2>&1; then
      _qmd_log "setup: 'collection add' failed/timed out: $(_qmd_tail_redacted "$slog") — retry next boot"
      return 0
    fi
  else
    _qmd_log "setup: index present, sentinel absent — refreshing only"
  fi
  # Contract (contracts/qmd-cli.md): add → update → embed. `update` re-scans the
  # collection so the re-entrant branch (index present, sentinel absent after an
  # interrupted run) also picks up any vault changes before embedding.
  if ! _qmd_run "$pkg" update >"$slog" 2>&1; then
    _qmd_log "setup: 'update' failed/timed out: $(_qmd_tail_redacted "$slog") — retry next boot"
    return 0
  fi
  if ! _qmd_run "$pkg" embed >"$slog" 2>&1; then
    _qmd_log "setup: 'embed' failed/timed out: $(_qmd_tail_redacted "$slog") — retry next boot"
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

# 015 US4: one-line, redacted tail of a captured qmd stderr — for the reindex log
# + the diagnostic. NEVER prints in the clear if redaction is unavailable (a
# missing mirror must not turn observability into a secret leak — Principle V).
_qmd_tail_redacted() {
  local f="$1"
  command -v redact_secrets >/dev/null 2>&1 || { printf 'redaction-unavailable\n'; return 0; }
  [ -f "$f" ] || { printf 'unknown\n'; return 0; }
  # Redact the WHOLE stream FIRST, then truncate — truncating first could chop a
  # secret's anchor (sk-ant-/<digits>:/KEY=) off at the 500-byte boundary and leak
  # the bare value past the anchor-dependent rules (Principle V).
  redact_secrets < "$f" 2>/dev/null | tr '\n' ' ' | tail -c 500
}

# 015 US4: log the effective reindex env once (redacted) so a docker reindex
# failure is diagnosable against the manual invocation that works (BUG 4). Only
# when redaction is available — never dump env otherwise.
_qmd_log_reindex_env() {
  local pkg="$1"
  command -v redact_secrets >/dev/null 2>&1 || return 0
  printf 'pkg=%s coll=%s cache_root=%s QMD_CONFIG_DIR=%s XDG_CACHE_HOME=%s TMPDIR=%s\n' \
    "$pkg" "${QMD_COLLECTION_NAME:-vault}" "$(qmd_cache_root)" "${QMD_CONFIG_DIR:-}" \
    "${XDG_CACHE_HOME:-}" "$(scratch_dir "$(qmd_cache_root)")" \
    | redact_secrets | while IFS= read -r _l; do _qmd_log "reindex env: $_l"; done
}

# 018: fixed anti-runaway backstop on the embed-completion loop (see
# contracts/embed-completion.md). NOT an agent.yml field (Clarifications
# 2026-07-10) — env-overridable for tests only.
QMD_EMBED_MAX_PASSES="${QMD_EMBED_MAX_PASSES:-12}"

# _qmd_pending_count PKG — how many active documents still need an embedding,
# per qmd's own `status` line ("Pending: N need embedding"). Echoes a bare
# non-negative integer on success; echoes nothing and returns non-zero when
# `status` fails or the count can't be parsed — callers MUST treat that as
# UNKNOWN, never as zero (018 data-model.md).
_qmd_pending_count() {
  local pkg="$1" out n
  out=$(_qmd_run "$pkg" status 2>/dev/null) || { printf ''; return 1; }
  n=$(printf '%s\n' "$out" | grep -oE 'Pending:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -n1)
  if [ -z "$n" ]; then printf ''; return 1; fi
  printf '%s\n' "$n"
}

# _qmd_embed_until_complete PKG STATE_FILE HASH LAST_HASH — 018: run
# successive `qmd embed` passes (each a fresh, engine-capped session — see
# research.md R1) until qmd reports full coverage, a pass makes no forward
# progress (permanently-failing documents), or QMD_EMBED_MAX_PASSES is hit.
# Never patches/modifies the qmd engine (loop-around, not a patch — R2).
# Always returns 0 (fail-silent; a cron tick/watcher must never crash).
_qmd_embed_until_complete() {
  local pkg="$1" state_file="$2" hash="$3" last_hash="$4"
  local scratch rlog pass=1 prev_pending="" out rc pending
  scratch=$(scratch_dir "$(qmd_cache_root)")
  rlog="$scratch/embed-pass.err"
  while [ "$pass" -le "$QMD_EMBED_MAX_PASSES" ]; do
    out=$(_qmd_run "$pkg" embed 2>&1)
    rc=$?
    printf '%s\n' "$out" > "$rlog"
    if [ "$rc" -ne 0 ]; then
      _qmd_log "reindex: embed pass $pass failed/timed out: $(_qmd_tail_redacted "$rlog")"
      qmd_write_state "$state_file" "$last_hash" "error"
      return 0
    fi
    if printf '%s\n' "$out" | grep -q "All content hashes already have embeddings"; then
      _qmd_log "reindex: embed complete after $pass pass(es)"
      qmd_write_state "$state_file" "$hash" "indexed" 0
      return 0
    fi
    pending=$(_qmd_pending_count "$pkg")
    if [ -n "$pending" ] && [ "$pending" -eq 0 ] 2>/dev/null; then
      _qmd_log "reindex: embed complete after $pass pass(es) (pending=0)"
      qmd_write_state "$state_file" "$hash" "indexed" 0
      return 0
    fi
    if [ -n "$pending" ] && [ -n "$prev_pending" ] && [ "$pending" -ge "$prev_pending" ] 2>/dev/null; then
      _qmd_log "reindex: embed stalled after $pass pass(es), pending=$pending"
      qmd_write_state "$state_file" "$hash" "stalled" "$pending"
      return 0
    fi
    _qmd_log "reindex: embed pass $pass done, pending=${pending:-unknown}"
    [ -n "$pending" ] && prev_pending="$pending"
    pass=$((pass + 1))
  done
  _qmd_log "reindex: embed pass cap ($QMD_EMBED_MAX_PASSES) reached, pending=${pending:-unknown}"
  qmd_write_state "$state_file" "$hash" "partial" "${pending:-0}"
  return 0
}

# Critical section of qmd_reindex (runs under flock when available).
#
# 018: the unchanged-vault guard now also checks the PERSISTED pending count
# (FR-003/FR-004) — an unchanged vault only skips embedding when it is ALSO
# fully embedded (pending==0). Otherwise (pending>0, or unknown/pre-018 state)
# it resumes embedding without re-running `update` (no vault re-scan needed).
_qmd_reindex_locked() {
  local agent_yml="$1" vault_dir="$2"
  local state_file current last pkg scratch rlog pending
  state_file=$(qmd_state_file)
  current=$(vault_hash "$vault_dir" 2>/dev/null || echo "")
  last=$(qmd_last_hash "$state_file")
  pending=""
  [ -f "$state_file" ] && pending=$(jq -r '.pending // ""' "$state_file" 2>/dev/null)

  if [ -n "$current" ] && [ "$current" = "$last" ] && [ "$pending" = "0" ]; then
    _qmd_log "reindex: vault unchanged ($current), fully embedded — skip"
    qmd_write_state "$state_file" "$current" "skipped" 0
    return 0
  fi

  command -v bun >/dev/null 2>&1 || { _qmd_log "reindex: bun unavailable — skip"; return 0; }
  pkg=$(qmd_pkg "$agent_yml")
  # 015 US4: surface the effective env + the REAL qmd stderr (redacted) instead of
  # swallowing it with >/dev/null 2>&1. The old silent path hid the docker-only
  # wrapper failure (BUG 4); the root-cause fix is the confirmatory ferrari gate.
  _qmd_log_reindex_env "$pkg"
  scratch=$(scratch_dir "$(qmd_cache_root)")
  rlog="$scratch/reindex.err"

  if [ -n "$current" ] && [ "$current" = "$last" ]; then
    _qmd_log "reindex: vault unchanged ($current), embeddings pending — resuming"
  else
    _qmd_log "reindex: update via $pkg"
    if ! _qmd_run "$pkg" update >"$rlog" 2>&1; then
      _qmd_log "reindex: 'update' failed/timed out: $(_qmd_tail_redacted "$rlog")"
      qmd_write_state "$state_file" "$last" "error"
      return 0
    fi
  fi

  _qmd_embed_until_complete "$pkg" "$state_file" "$current" "$last"
  return 0
}
