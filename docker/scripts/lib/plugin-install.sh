#!/usr/bin/env bash
# Plugin install retry + failure tracking (Story C, 003-bootstrap-hardening).
# Sourced by start_services.sh (image path or repo-relative fallback) and by
# host bats tests directly. No side effects at load.

PLUGIN_INSTALL_MAX_ATTEMPTS="${PLUGIN_INSTALL_MAX_ATTEMPTS:-3}"
PLUGIN_INSTALL_BACKOFF_UNIT="${PLUGIN_INSTALL_BACKOFF_UNIT:-1}"   # seconds; set 0 in tests
PLUGIN_FAILURES_FILE="${PLUGIN_FAILURES_FILE:-/workspace/.state/plugin-install-failures.jsonl}"

# Prefer the supervisor's log() if present; otherwise emit to stderr.
_plog() {
  if command -v log >/dev/null 2>&1; then log "$@"; else echo "[plugin-install] $*" >&2; fi
}

# _plugin_sanitize_error TEXT — first line only, with token-like strings
# redacted, so a plugin error never lands a secret in .state (Principle V,
# FR-C4). BSD/GNU-sed safe (no case-insensitive `I` flag; env-var token names
# are matched uppercase).
_plugin_sanitize_error() {
  printf '%s' "$1" | head -n1 \
    | sed -E 's/(ghp_|gho_|ghs_|ghu_|ghr_|github_pat_|xox[abprs]-)[A-Za-z0-9_-]+/[REDACTED]/g' \
    | sed -E 's/([A-Z0-9_]*(TOKEN|SECRET|KEY|PASSWORD)[A-Z0-9_]*[=:])[^[:space:]]+/\1[REDACTED]/g'
}

# retry_plugin_install_bounded SPEC [MAX]
#   0 = installed · 2 = skipped (not authenticated, no retry) · 1 = failed.
# On failure (1) prints a sanitized one-line reason to stdout for the caller to
# record. Logs each outcome distinctly (no more ambiguous "not auth OR failed").
retry_plugin_install_bounded() {
  local spec="$1" max="${2:-$PLUGIN_INSTALL_MAX_ATTEMPTS}"
  local attempt=0 err
  while :; do
    attempt=$((attempt + 1))
    if err=$(CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR_VAL:-}" claude plugin install "$spec" 2>&1 >/dev/null); then
      _plog "plugin installed: $spec"
      return 0
    fi
    if printf '%s' "$err" | grep -qiE 'not authenticated|please run /login|unauthorized|http 401|authentication_error'; then
      _plog "plugin install skipped: not authenticated — $spec"
      return 2
    fi
    _plog "plugin install failed (attempt $attempt/$max): $spec"
    [ "$attempt" -ge "$max" ] && break
    sleep "$(( attempt * PLUGIN_INSTALL_BACKOFF_UNIT ))"
  done
  _plugin_sanitize_error "$err"
  return 1
}

# _plugin_clear_failure SPEC — drop any recorded failure for SPEC.
_plugin_clear_failure() {
  local spec="$1" file="$PLUGIN_FAILURES_FILE" tmp
  [ -f "$file" ] || return 0
  tmp=$(mktemp) || return 0
  grep -vF "\"spec\":\"$spec\"" "$file" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
}

# _plugin_record_failure SPEC REASON — record a de-duplicated residual failure.
# REASON is sanitized again defensively (never persist a secret to .state).
_plugin_record_failure() {
  local spec="$1" reason="$2" file="$PLUGIN_FAILURES_FILE"
  command -v jq >/dev/null 2>&1 || return 0
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  _plugin_clear_failure "$spec"
  local safe ts
  safe=$(_plugin_sanitize_error "$reason")
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  jq -cn --arg spec "$spec" --arg err "$safe" --arg ts "$ts" \
    '{spec:$spec, error:$err, ts:$ts}' >> "$file" 2>/dev/null || true
}

# _plugin_list_failures — print the recorded failed specs, one per line.
_plugin_list_failures() {
  local file="$PLUGIN_FAILURES_FILE"
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.spec' "$file" 2>/dev/null | sort -u
}
