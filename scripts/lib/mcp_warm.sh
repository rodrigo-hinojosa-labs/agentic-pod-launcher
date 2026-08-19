#!/usr/bin/env bash
# scripts/lib/mcp_warm.sh — 030: warm cache for out-of-catalog MCPs.
#
# Single source of the "which packages does this agent need pre-installed"
# derivation, consumed by the docker boot warm (docker/scripts/start_services.sh,
# via the mirrored copy) and the local bootstrap (modules/local-bootstrap.sh.tpl).
#
# The derivation (mcp_warm_targets) is PURE — no network, no side effects — so it
# is unit-testable on the host. The warmer (mcp_warm_run) is fail-soft (never
# aborts the caller), idempotent (a warm package is a no-op), timeout-bounded, and
# reads NO secrets (installing a package is independent of the credentials its
# MCP needs to *start*).
#
# Why derive from .mcp.json instead of a hardcoded list: the effective .mcp.json
# already carries every MCP an agent runs, including overlay-injected ones merged
# by the external custom-apply tool. A `command=="uvx"`-only selector misses the
# wrapper shape (google-workspace = command=seed-creds.sh, args=[uvx, pkg]) — the
# exact MCP that caused the ferrari incident — so the derivation scans command+args.
# Contract: specs/030-mcp-warm-cache/contracts/{warm-derivation,boot-integration}.md
#
# This file is side-effect-free at source time: it only defines functions.

# _mcp_warm_log MESSAGE — trace to stderr (surfaces in claude.log / bootstrap out).
_mcp_warm_log() { printf 'mcp_warm: %s\n' "$*" >&2; }

# _mcp_warm_pick — filter: reads "<runtime>\t<tok>\t<tok>..." lines on stdin and
# emits "<runtime>\t<package>", picking the package token after the runtime token
# while skipping npx flags (-y/--yes, and -p/--package whose value is the package).
_mcp_warm_pick() {
  local line rt rest tok pkg take_next oldifs
  while IFS= read -r line; do
    rt="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    [ "$rest" = "$line" ] && rest=""
    pkg=""
    take_next=0
    oldifs="$IFS"
    IFS="$(printf '\t')"
    set -f
    for tok in $rest; do
      if [ "$take_next" = "1" ]; then pkg="$tok"; break; fi
      case "$tok" in
        -y|--yes)      continue ;;
        -p|--package)  take_next=1; continue ;;
        -*)            continue ;;
        *)             pkg="$tok"; break ;;
      esac
    done
    set +f
    IFS="$oldifs"
    [ -n "$pkg" ] && printf '%s\t%s\n' "$rt" "$pkg"
  done
}

# mcp_warm_targets <mcp_json_path>
# Pure. Emits deduped, sorted "<runtime>\t<package>" lines. Scans [command]+args
# for the first uvx/npx token (by basename) and derives the package. Servers with
# no uvx/npx token (baked binaries, remote servers, wrappers to baked binaries)
# emit nothing. Missing/unreadable/empty .mcp.json → zero lines, rc 0.
mcp_warm_targets() {
  local mcp_json="${1:-}"
  [ -f "$mcp_json" ] || return 0
  jq -r '
    (.mcpServers // {}) | to_entries[] | .value |
    ([.command] + (.args // [])) | map(select(type=="string")) as $toks |
    ([ range(0; ($toks | length))
       | . as $k
       | ($toks[$k] | sub(".*/"; "")) as $b
       | select($b == "uvx" or $b == "npx")
       | $k ] | first) as $i |
    if $i == null then empty
    else (($toks[$i] | sub(".*/"; "")) + "\t" + ($toks[($i + 1):] | join("\t")))
    end
  ' "$mcp_json" 2>/dev/null | _mcp_warm_pick | sort -u
}

# _mcp_warm_timeout SECONDS CMD... — run CMD with a timeout if one is available,
# else run it directly (fail-soft: absence of `timeout` must not skip the warm).
_mcp_warm_timeout() {
  local to="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$to" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$to" "$@"
  else
    "$@"
  fi
}

# _mcp_warm_one RUNTIME PACKAGE PY_FLAG TIMEOUT — warm a single package. rc 0 on
# success. Idempotent: a package already in the cache resolves without download.
_mcp_warm_one() {
  local rt="$1" pkg="$2" py_flag="$3" to="$4"
  case "$rt" in
    uvx)
      command -v uv >/dev/null 2>&1 || return 1
      # shellcheck disable=SC2086
      _mcp_warm_timeout "$to" uv tool install $py_flag "$pkg" >/dev/null 2>&1
      ;;
    npx)
      command -v npm >/dev/null 2>&1 || return 1
      _mcp_warm_timeout "$to" npm exec --prefer-offline -y --package="$pkg" -- true >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

# mcp_warm_run <mcp_json_path>
# Warm every derived package into the persistent caches (uvx → /opt/uv via
# UV_TOOL_DIR; npx → /opt/npm-cache via NPM_CONFIG_CACHE — both set in the image).
# Fail-soft: a failing warm logs a warning and continues; ALWAYS returns 0. Reads
# no secrets. Per-package timeout via MCP_WARM_TIMEOUT (default 300s).
mcp_warm_run() {
  local mcp_json="${1:-}"
  local rt pkg py_flag="" to tried=0 warmed=0 failed=0
  command -v python3 >/dev/null 2>&1 && py_flag="--python python3"
  to="${MCP_WARM_TIMEOUT:-300}"
  while IFS="$(printf '\t')" read -r rt pkg; do
    [ -n "$pkg" ] || continue
    tried=$((tried + 1))
    _mcp_warm_log "warming ${rt} ${pkg}"
    if _mcp_warm_one "$rt" "$pkg" "$py_flag" "$to"; then
      warmed=$((warmed + 1))
    else
      failed=$((failed + 1))
      _mcp_warm_log "warn: ${rt} ${pkg} failed (will resolve on first use)"
    fi
  done < <(mcp_warm_targets "$mcp_json")
  if [ "$tried" -gt 0 ]; then
    _mcp_warm_log "warm cache: ${warmed}/${tried} warm, ${failed} failed"
  fi
  return 0
}
