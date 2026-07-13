#!/usr/bin/env bash
# Pure input validators for wizard fields. Each function takes a value,
# returns 0 if it's acceptable, prints a one-line hint to stderr and
# returns 1 otherwise. Sourced by wizard.sh + wizard-gum.sh + setup.sh
# and tested in isolation by tests/wizard-validators.bats.
#
# The contract is intentionally narrow: validators do not mutate or
# normalize the input — that's a separate step (e.g. lowercasing the
# agent name happens in setup.sh after validation passes). They also
# don't accept empty input — required-vs-optional is the caller's
# concern; pass empty values through `ask_required` first.

# validate_email VAL → 0 if looks like an email
validate_email() {
  local v="$1"
  if [[ "$v" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    return 0
  fi
  echo "  ✗ '$v' is not a valid email (expected user@example.com)" >&2
  return 1
}

# validate_telegram_token VAL → 0 if matches Telegram bot token format.
# BotFather emits tokens like `123456789:ABCdef...` — at least 30 chars
# after the colon are typical. We accept 25+ to leave headroom.
validate_telegram_token() {
  local v="$1"
  if [[ "$v" =~ ^[0-9]+:[A-Za-z0-9_-]{25,}$ ]]; then
    return 0
  fi
  echo "  ✗ Telegram token must look like 123456789:AAA...   (digits, colon, base64-like body)" >&2
  return 1
}

# validate_timezone VAL → 0 if value names an IANA tz that Linux can resolve.
# On hosts without /usr/share/zoneinfo (rare; some CI containers strip it)
# we fall back to a structural check ("Region/City" with capitalized parts).
validate_timezone() {
  local v="$1"
  if [ -d /usr/share/zoneinfo ]; then
    if [ -f "/usr/share/zoneinfo/$v" ]; then
      return 0
    fi
    echo "  ✗ '$v' is not in /usr/share/zoneinfo. Use 'America/Santiago', 'Europe/Madrid', 'UTC', etc." >&2
    return 1
  fi
  if [[ "$v" = "UTC" ]] || [[ "$v" =~ ^[A-Z][a-z]+(/[A-Z][A-Za-z_]+)+$ ]]; then
    return 0
  fi
  echo "  ✗ '$v' does not look like an IANA timezone (e.g. America/Santiago)" >&2
  return 1
}

# validate_cron_or_interval VAL → 0 if matches either the heartbeat short
# form (Nm/Nh) or a 5-field cron expression. We don't run the value through
# `crontab -` (that would require the binary at validation time and bind
# us to a specific cron flavor); the regex below admits the common
# operators: digits, *, comma, dash, slash. Catches typos like
# "30 minutes" or "every hour" before they reach heartbeatctl.
validate_cron_or_interval() {
  local v="$1"
  if [[ "$v" =~ ^[0-9]+[mh]$ ]]; then
    return 0
  fi
  if [[ "$v" =~ ^[0-9*,/-]+\ +[0-9*,/-]+\ +[0-9*,/-]+\ +[0-9*,/-]+\ +[0-9*,/-]+$ ]]; then
    return 0
  fi
  echo "  ✗ '$v' is not a valid interval. Use '30m', '2h', or a 5-field cron expression like '0 * * * *'" >&2
  return 1
}

# validate_agent_name VAL → 0 if usable as a Docker container name + git
# branch fragment + filesystem dir. Lowercase ASCII, digits, hyphens. No
# leading/trailing hyphen (Docker rejects), no double-hyphen (typo
# heuristic — RFC 1123 allows it but it's almost always a mistake).
# Length 1..63 to fit DNS labels.
validate_agent_name() {
  local v="$1"
  if [ "${#v}" -gt 63 ] || [ "${#v}" -lt 1 ]; then
    echo "  ✗ Agent name must be 1..63 characters (got ${#v})" >&2
    return 1
  fi
  if [[ ! "$v" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] && [[ ! "$v" =~ ^[a-z0-9]$ ]]; then
    echo "  ✗ Agent name must be lowercase letters/digits/hyphens, no leading/trailing hyphen" >&2
    return 1
  fi
  if [[ "$v" =~ -- ]]; then
    echo "  ✗ Agent name should not contain double hyphens (got '$v' — typo?)" >&2
    return 1
  fi
  return 0
}

# normalize_agent_name VAL → echo VAL mapped toward a valid DNS label:
# lowercased, spaces turned into hyphens, runs of hyphens collapsed to one,
# and leading/trailing hyphens trimmed ("Rodri Cenco Admin" → "rodri-cenco-
# admin"). Pure transform, always returns 0; the result is still gated by
# validate_agent_name (which rejects any remaining invalid character) so the
# caller surfaces a clear error instead of failing later in docker build.
normalize_agent_name() {
  local v="$1"
  v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
  v="${v// /-}"                       # spaces → hyphens
  v=$(printf '%s' "$v" | tr -s '-')   # collapse runs of hyphens
  v="${v#-}"                          # trim a leading hyphen
  v="${v%-}"                          # trim a trailing hyphen
  printf '%s\n' "$v"
}

# validate_url VAL → 0 if value parses as an http(s) URL. We allow http://
# for localhost / private development; production agents will use https.
# Rejects schemes other than http/https, bare hosts without scheme, and
# URLs with whitespace.
validate_url() {
  local v="$1"
  if [[ "$v" =~ [[:space:]] ]]; then
    echo "  ✗ URL contains whitespace" >&2
    return 1
  fi
  if [[ "$v" =~ ^https?://[A-Za-z0-9._~:/?#@!$\&\'\(\)\*\+,\;=%-]+$ ]]; then
    return 0
  fi
  echo "  ✗ '$v' is not a valid http(s) URL (must start with http:// or https://)" >&2
  return 1
}

# validate_atlassian_alias VAL → 0 if the alias is safe to become a
# systemd/env-var-name segment. It is uppercased and interpolated into
# ATLASSIAN_<ALIAS>_TOKEN etc (modules/mcp-json.tpl, render.sh's {{NAME}}
# substitution) and, since 021, delivered to the local session via a
# systemd EnvironmentFile. A dash or space produces an INVALID systemd
# variable name: systemd drops the whole assignment AND logs the raw
# KEY=VALUE at ERROR to the journal (a credential leak) — docker compose
# accepts the same dashed key fine, so this was invisible until local mode
# actually loaded the workspace .env.
validate_atlassian_alias() {
  local v="$1"
  if [[ "$v" =~ ^[A-Za-z0-9_]+$ ]]; then
    return 0
  fi
  echo "  ✗ Alias must be letters, digits, or underscore only (no dashes/spaces) — it becomes ATLASSIAN_<ALIAS>_TOKEN etc." >&2
  return 1
}

# validate_uid_gid VAL → 0 if numeric and >= 0. UID 0 is rare for agents
# but reserved for root explicitly; we accept it (callers can override
# if they want stricter "must be >0").
validate_uid_gid() {
  local v="$1"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  echo "  ✗ '$v' is not a non-negative integer (UID/GID must be numeric)" >&2
  return 1
}

# validate_workspace_path VAL → 0 if absolute path, doesn't traverse '..',
# and the parent directory exists & is writable. Empty path rejected
# (callers should run ask_required first if they want the field required).
validate_workspace_path() {
  local v="$1"
  if [[ "$v" != /* ]]; then
    echo "  ✗ Workspace path must be absolute (got '$v')" >&2
    return 1
  fi
  if [[ "$v" == *".."* ]]; then
    echo "  ✗ Workspace path should not contain '..'" >&2
    return 1
  fi
  local parent
  parent=$(dirname "$v")
  if [ ! -d "$parent" ]; then
    echo "  ✗ Parent directory '$parent' does not exist" >&2
    return 1
  fi
  if [ ! -w "$parent" ]; then
    echo "  ✗ Parent directory '$parent' is not writable" >&2
    return 1
  fi
  return 0
}

# normalize_destination_path VAL → echo VAL with a leading ~ expanded to
# $HOME (a bare ~ becomes $HOME; ~/x becomes $HOME/x). A ~ anywhere else is
# left untouched so validate_destination_path can reject it. Pure transform,
# always returns 0 — validation is validate_destination_path's job. The "~/"
# pattern is quoted in the ${#} word to suppress tilde expansion (an
# unquoted ~/ there would expand to $HOME/ before the strip).
normalize_destination_path() {
  local v="$1" rest
  case "$v" in
    "~")   printf '%s\n' "$HOME" ;;
    "~/"*) rest="${v#"~/"}"; printf '%s\n' "$HOME/$rest" ;;
    *)     printf '%s\n' "$v" ;;
  esac
}

# validate_destination_path VAL → 0 if VAL is an absolute path with no
# embedded '~' or '..'. Unlike validate_workspace_path it does NOT require the
# parent to exist: the destination is created by the scaffold and may be
# several levels deep (e.g. the default <installer>/agents/<name> whose
# 'agents/' parent need not exist yet). On macOS a /home/... path is accepted
# but warns that the home directory lives under /Users/. Run the value through
# normalize_destination_path first to expand a leading ~.
validate_destination_path() {
  local v="$1"
  if [[ "$v" != /* ]]; then
    echo "  ✗ Destination must be an absolute path (got '$v')" >&2
    return 1
  fi
  if [[ "$v" == *"~"* ]]; then
    echo "  ✗ Destination may not contain '~' except as a leading shortcut (got '$v')" >&2
    return 1
  fi
  if [[ "$v" == *".."* ]]; then
    echo "  ✗ Destination should not contain '..'" >&2
    return 1
  fi
  if [ "$(uname -s)" = "Darwin" ] && [[ "$v" == /home/* ]]; then
    echo "  ⚠ On macOS the home directory is under /Users/, not /home/ — did you mean a path under /Users/?" >&2
  fi
  return 0
}
