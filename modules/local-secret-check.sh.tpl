#!/usr/bin/env bash
# 021-local-secret-delivery (US3): boot-time secret warning. Never blocks
# startup — the ExecStartPre= directive that invokes this carries its own
# '-' prefix (ignore-if-failed), and this script ALSO always exits 0
# (belt and braces). Prints WARN lines to stderr, visible via
# `journalctl -u agent-<name>`. Same detection logic as `agentctl doctor`'s
# _local_secrets_doctor (scripts/agentctl), sharing scripts/lib/env_file.sh
# and scripts/lib/mcp-catalog.sh.
# Rendered from modules/local-secret-check.sh.tpl — do not hand-edit.

AGENT_NAME="{{AGENT_NAME}}"
WORKSPACE="{{DEPLOYMENT_WORKSPACE}}"
ENV_FILE="${WORKSPACE}/.env"

_warn() { echo "agent-${AGENT_NAME} secret-check: WARN: $1" >&2; }

# shellcheck source=/dev/null
. "${WORKSPACE}/scripts/lib/env_file.sh" 2>/dev/null
# shellcheck source=/dev/null
. "${WORKSPACE}/scripts/lib/mcp-catalog.sh" 2>/dev/null
export MCP_CATALOG_DIR="${WORKSPACE}/modules/mcps"

if [ ! -f "$ENV_FILE" ]; then
  _warn ".env not found at ${ENV_FILE}"
  exit 0
fi

if command -v env_file_lint >/dev/null 2>&1; then
  lint_out=$(env_file_lint "$ENV_FILE" 2>/dev/null)
  if [ -n "$lint_out" ]; then
    while IFS= read -r lline; do
      [ -n "$lline" ] && _warn ".env: $lline"
    done <<< "$lint_out"
  fi
fi

if command -v mcp_catalog_get >/dev/null 2>&1 && [ -f "${WORKSPACE}/agent.yml" ] && command -v yq >/dev/null 2>&1; then
  mcp_id=""
  while IFS= read -r mcp_id; do
    [ -z "$mcp_id" ] && continue
    [ "$mcp_id" = "google-calendar" ] && continue
    [ "$(mcp_catalog_get "$mcp_id" requires_secret 2>/dev/null)" = "true" ] || continue
    secret_var=$(mcp_catalog_get "$mcp_id" secret_env_var 2>/dev/null)
    [ -n "$secret_var" ] || continue
    val=$(env_file_get "$secret_var" "$ENV_FILE")
    [ -z "$val" ] && _warn "${secret_var} missing or empty in ${ENV_FILE}"
  done < <(yq -r '.mcps.defaults[]?' "${WORKSPACE}/agent.yml" 2>/dev/null)

  a_name=""
  while IFS= read -r a_name; do
    [ -z "$a_name" ] && continue
    a_upper=$(printf '%s' "$a_name" | tr '[:lower:]' '[:upper:]')
    for suffix in CONFLUENCE_URL CONFLUENCE_USERNAME TOKEN JIRA_URL JIRA_USERNAME; do
      var="ATLASSIAN_${a_upper}_${suffix}"
      val=$(env_file_get "$var" "$ENV_FILE")
      [ -z "$val" ] && _warn "${var} missing or empty in ${ENV_FILE}"
    done
  done < <(yq -r '.mcps.atlassian[]?.name' "${WORKSPACE}/agent.yml" 2>/dev/null)

  if [ "$(yq -r '.mcps.github.enabled // false' "${WORKSPACE}/agent.yml" 2>/dev/null)" = "true" ]; then
    val=$(env_file_get GITHUB_PAT "$ENV_FILE")
    [ -z "$val" ] && _warn "GITHUB_PAT missing or empty in ${ENV_FILE}"
  fi
fi

exit 0
