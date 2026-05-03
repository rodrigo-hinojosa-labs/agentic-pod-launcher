#!/bin/bash
# token-health.sh — verify that the secrets in /workspace/.env are still
# accepted by their respective upstreams. Boot-side and on-demand from
# `heartbeatctl doctor`.
#
# Image-baked at /opt/agent-admin/scripts/lib/token-health.sh. Loads
# safe-exec.sh for safe_curl. Each helper returns 0 on healthy, 1 on
# rejected/missing, and 2 on transient (network/5xx) — letting doctor
# distinguish "rotate this token" from "try again later".
#
# Pure functions, no state, no side effects beyond stdout. Reusable from
# any caller (doctor, scheduled cron, ad-hoc CLI).
#
# Why per-API helpers and not a generic "auth check": each API encodes
# its rejection differently (Telegram nests `ok` in the JSON body even
# on 200; GitHub uses 401 + Bad credentials text; Atlassian sometimes
# returns 200 with empty body for unauthorized) and the user-actionable
# error message differs ("rotate FORK_PAT in .env" vs "regenerate the
# Atlassian API token"). Composing a single generic checker would lose
# that texture.

# shellcheck source=/dev/null
[ -f "${TOKEN_HEALTH_LIB_DIR:-/opt/agent-admin/scripts/lib}/safe-exec.sh" ] \
  && source "${TOKEN_HEALTH_LIB_DIR:-/opt/agent-admin/scripts/lib}/safe-exec.sh"

# token_health_telegram TOKEN
#   exit 0  → bot accepted by Telegram (stdout = JSON {ok:true, bot_username})
#   exit 1  → token rejected (401 / 404)         (stdout = JSON {ok:false, error})
#   exit 2  → transient (network / 5xx)          (stdout = JSON {ok:false, error, transient:true})
# Endpoint: https://api.telegram.org/bot<TOKEN>/getMe
# Response shape: {"ok":true,"result":{"id":..., "username":"linus_bot"}}
token_health_telegram() {
  local token="$1"
  local api_base="${TELEGRAM_API_BASE:-https://api.telegram.org}"
  if [ -z "$token" ]; then
    printf '{"ok":false,"error":"missing token"}\n'
    return 1
  fi
  # safe_curl prints the HTTP code; the body lands on stderr (truncated
  # 512 bytes). We capture both.
  local body code
  body=$(safe_curl "${api_base}/bot${token}/getMe" 2>"$TOKEN_HEALTH_LAST_BODY") \
    || true
  code="$body"
  body=$(cat "$TOKEN_HEALTH_LAST_BODY" 2>/dev/null)
  case "$code" in
    200)
      # Telegram nests ok inside the body. A 401 token still hits 200
      # but with {"ok":false,"description":"Unauthorized"} — guard for it.
      local body_ok
      body_ok=$(printf '%s' "$body" | jq -r '.ok // false' 2>/dev/null)
      if [ "$body_ok" = "true" ]; then
        local username
        username=$(printf '%s' "$body" | jq -r '.result.username // ""' 2>/dev/null)
        printf '{"ok":true,"bot_username":"%s"}\n' "$username"
        return 0
      else
        local desc
        desc=$(printf '%s' "$body" | jq -r '.description // "rejected"' 2>/dev/null)
        printf '{"ok":false,"error":%s}\n' "$(printf '%s' "$desc" | jq -Rs '.')"
        return 1
      fi
      ;;
    401|403|404)
      printf '{"ok":false,"error":"HTTP %s — token rejected"}\n' "$code"
      return 1
      ;;
    000|5*)
      printf '{"ok":false,"error":"HTTP %s — transient","transient":true}\n' "$code"
      return 2
      ;;
    *)
      printf '{"ok":false,"error":"HTTP %s — unexpected"}\n' "$code"
      return 1
      ;;
  esac
}

# token_health_github PAT
#   exit 0/1/2 same convention as telegram
#   stdout JSON: {ok, error, login, scopes}
# Endpoint: https://api.github.com/user with Authorization: token <PAT>
# Scopes are returned in the X-OAuth-Scopes header — safe_curl reads only
# the body, so we skip scope reporting and let the user infer from the
# fact that /user succeeded (scope `repo` is the minimum that grants /user).
token_health_github() {
  local pat="$1"
  local api_base="${GITHUB_API_BASE:-https://api.github.com}"
  if [ -z "$pat" ]; then
    printf '{"ok":false,"error":"missing PAT"}\n'
    return 1
  fi
  local body code
  body=$(safe_curl "${api_base}/user" -H "Authorization: token $pat" -H "Accept: application/vnd.github+json" 2>"$TOKEN_HEALTH_LAST_BODY") || true
  code="$body"
  body=$(cat "$TOKEN_HEALTH_LAST_BODY" 2>/dev/null)
  case "$code" in
    200)
      local login
      login=$(printf '%s' "$body" | jq -r '.login // ""' 2>/dev/null)
      printf '{"ok":true,"login":"%s"}\n' "$login"
      return 0
      ;;
    401|403)
      printf '{"ok":false,"error":"HTTP %s — Bad credentials (rotate PAT)"}\n' "$code"
      return 1
      ;;
    000|5*)
      printf '{"ok":false,"error":"HTTP %s — transient","transient":true}\n' "$code"
      return 2
      ;;
    *)
      printf '{"ok":false,"error":"HTTP %s — unexpected"}\n' "$code"
      return 1
      ;;
  esac
}

# token_health_atlassian URL EMAIL TOKEN
#   exit 0/1/2 same convention
#   stdout JSON: {ok, error, account_id}
# Endpoint: <URL>/rest/api/3/myself with basic auth.
# URL example: https://yourco.atlassian.net (no trailing slash, no /wiki).
token_health_atlassian() {
  local url="$1" email="$2" token="$3"
  if [ -z "$url" ] || [ -z "$email" ] || [ -z "$token" ]; then
    printf '{"ok":false,"error":"missing URL, email, or token"}\n'
    return 1
  fi
  # Strip trailing slash for predictable concatenation.
  url="${url%/}"
  local body code
  body=$(safe_curl "${url}/rest/api/3/myself" -u "${email}:${token}" -H "Accept: application/json" 2>"$TOKEN_HEALTH_LAST_BODY") || true
  code="$body"
  body=$(cat "$TOKEN_HEALTH_LAST_BODY" 2>/dev/null)
  case "$code" in
    200)
      local aid
      aid=$(printf '%s' "$body" | jq -r '.accountId // ""' 2>/dev/null)
      printf '{"ok":true,"account_id":"%s"}\n' "$aid"
      return 0
      ;;
    401|403|404)
      printf '{"ok":false,"error":"HTTP %s — token or email rejected"}\n' "$code"
      return 1
      ;;
    000|5*)
      printf '{"ok":false,"error":"HTTP %s — transient","transient":true}\n' "$code"
      return 2
      ;;
    *)
      printf '{"ok":false,"error":"HTTP %s — unexpected"}\n' "$code"
      return 1
      ;;
  esac
}

# token_health_firecrawl KEY
#   exit 0/1/2 same convention
#   stdout JSON: {ok, error}
# Endpoint: https://api.firecrawl.dev/v1/scrape with Authorization: Bearer <KEY>.
# Body is a minimal scrape request that stays within free-tier limits if
# the key is valid; if the key is invalid, the API returns 401 immediately
# and never spawns the actual scrape — zero monetary cost on error path.
token_health_firecrawl() {
  local key="$1"
  local api_base="${FIRECRAWL_API_BASE:-https://api.firecrawl.dev}"
  if [ -z "$key" ]; then
    printf '{"ok":false,"error":"missing API key"}\n'
    return 1
  fi
  local body code
  # GET /v1/team — a cheap auth-only endpoint. Falls back to /v1/scrape
  # if the team endpoint moves; both reject 401 on bad keys.
  body=$(safe_curl "${api_base}/v1/team" -H "Authorization: Bearer $key" 2>"$TOKEN_HEALTH_LAST_BODY") || true
  code="$body"
  body=$(cat "$TOKEN_HEALTH_LAST_BODY" 2>/dev/null)
  case "$code" in
    200)
      printf '{"ok":true}\n'
      return 0
      ;;
    401|403|404)
      printf '{"ok":false,"error":"HTTP %s — API key rejected"}\n' "$code"
      return 1
      ;;
    429)
      # Rate limited but key is valid — treat as warn, not error.
      printf '{"ok":true,"warning":"rate-limited (key valid)"}\n'
      return 0
      ;;
    000|5*)
      printf '{"ok":false,"error":"HTTP %s — transient","transient":true}\n' "$code"
      return 2
      ;;
    *)
      printf '{"ok":false,"error":"HTTP %s — unexpected"}\n' "$code"
      return 1
      ;;
  esac
}

# token_health_summary AGENT_YML ENV_FILE
#
# Iterate every token declared in agent.yml, read the secret from
# ENV_FILE, run the corresponding checker, and print a doctor-friendly
# table. Non-fatal: every check runs to completion; one rejected token
# does not stop the others. Returns the worst exit code observed
# (0=all ok, 1=at least one rejected, 2=at least one transient — but
# never 1 if there's also a 0 success in another subsystem; doctor
# already reports per-line status).
#
# Stdout format (one line per token, fixed-width left column for align):
#   ✓ telegram         bot @linus_bot
#   ✗ github           HTTP 401 — Bad credentials (rotate PAT)
#   ⊝ atlassian        no token configured (skipped)
#   ⚠ firecrawl        HTTP 503 — transient
#
# Tokens checked depend on what's declared in agent.yml + present in
# .env. We deliberately do NOT probe a service whose secret is empty —
# that's the wizard's job to surface, not doctor's.
token_health_summary() {
  local agent_yml="$1" env_file="$2"
  local worst=0

  if [ ! -f "$env_file" ]; then
    printf '  ⊝ Token health: .env missing (skipped)\n'
    return 0
  fi

  # Source .env into a subshell so we don't pollute caller's env (the
  # secrets stay scoped to this function call).
  local notify_token notify_chat
  notify_token=$(grep '^NOTIFY_BOT_TOKEN=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//')
  notify_chat=$(grep '^NOTIFY_CHAT_ID=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//')

  local channel
  channel=$(yq -r '.notifications.channel // "none"' "$agent_yml" 2>/dev/null || echo "none")

  # Telegram (heartbeat notifier).
  if [ "$channel" = "telegram" ]; then
    if [ -z "$notify_token" ]; then
      printf '  ⊝ telegram         NOTIFY_BOT_TOKEN missing in .env (skipped)\n'
    else
      local result rc
      result=$(token_health_telegram "$notify_token") || rc=$?
      rc=${rc:-0}
      _token_health_emit_line "telegram" "$result" "$rc"
      [ "$rc" -gt "$worst" ] && worst=$rc
    fi
  fi

  # GitHub (MCP). We probe FORK_PAT first (the workspace's main credential),
  # then GITHUB_PAT if declared separately for the MCP server. Both use the
  # same upstream check — only the .env key differs.
  local fork_pat github_pat
  fork_pat=$(grep '^FORK_PAT=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//')
  github_pat=$(grep '^GITHUB_PAT=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//')
  if [ -n "$fork_pat" ]; then
    local result rc
    result=$(token_health_github "$fork_pat") || rc=$?
    rc=${rc:-0}
    _token_health_emit_line "fork PAT" "$result" "$rc"
    [ "$rc" -gt "$worst" ] && worst=$rc
  fi
  if [ -n "$github_pat" ] && [ "$github_pat" != "$fork_pat" ]; then
    local result rc
    result=$(token_health_github "$github_pat") || rc=$?
    rc=${rc:-0}
    _token_health_emit_line "github MCP PAT" "$result" "$rc"
    [ "$rc" -gt "$worst" ] && worst=$rc
  fi

  # Atlassian — one entry per workspace declared in agent.yml.mcps.atlassian[].
  local ws_count
  ws_count=$(yq '.mcps.atlassian | length' "$agent_yml" 2>/dev/null || echo "0")
  if [ "$ws_count" != "0" ] && [ -n "$ws_count" ]; then
    local i=0
    while [ "$i" -lt "$ws_count" ]; do
      local name url email upper token
      name=$(yq -r ".mcps.atlassian[$i].name" "$agent_yml" 2>/dev/null)
      url=$(yq -r ".mcps.atlassian[$i].url" "$agent_yml" 2>/dev/null)
      email=$(yq -r ".mcps.atlassian[$i].email" "$agent_yml" 2>/dev/null)
      upper=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
      token=$(grep "^ATLASSIAN_${upper}_TOKEN=" "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//')
      if [ -z "$token" ]; then
        printf '  ⊝ atlassian/%-7s ATLASSIAN_%s_TOKEN missing in .env (skipped)\n' "$name" "$upper"
      else
        local result rc
        result=$(token_health_atlassian "$url" "$email" "$token") || rc=$?
        rc=${rc:-0}
        _token_health_emit_line "atlassian/$name" "$result" "$rc"
        [ "$rc" -gt "$worst" ] && worst=$rc
      fi
      i=$((i + 1))
    done
  fi

  # Firecrawl.
  local firecrawl_key firecrawl_enabled
  firecrawl_enabled=$(yq -r '.mcps.optional.firecrawl // false' "$agent_yml" 2>/dev/null || echo "false")
  firecrawl_key=$(grep '^FIRECRAWL_API_KEY=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//')
  if [ "$firecrawl_enabled" = "true" ]; then
    if [ -z "$firecrawl_key" ]; then
      printf '  ⊝ firecrawl        FIRECRAWL_API_KEY missing in .env (skipped)\n'
    else
      local result rc
      result=$(token_health_firecrawl "$firecrawl_key") || rc=$?
      rc=${rc:-0}
      _token_health_emit_line "firecrawl" "$result" "$rc"
      [ "$rc" -gt "$worst" ] && worst=$rc
    fi
  fi

  return "$worst"
}

# _token_health_emit_line LABEL JSON_RESULT EXIT_CODE
# Internal: render one row of the doctor table from a checker's output.
_token_health_emit_line() {
  local label="$1" result="$2" rc="$3"
  local icon detail
  case "$rc" in
    0) icon="✓"
       # Pull a friendly extra detail out of the JSON when present
       # (e.g. bot_username, login, account_id). Falls back to a bare ok.
       detail=$(printf '%s' "$result" | jq -r '
         if .bot_username then "bot @" + .bot_username
         elif .login then "user " + .login
         elif .account_id then "account " + .account_id
         elif .warning then .warning
         else "ok"
         end' 2>/dev/null)
       ;;
    2) icon="⚠"
       detail=$(printf '%s' "$result" | jq -r '.error' 2>/dev/null)
       ;;
    *) icon="✗"
       detail=$(printf '%s' "$result" | jq -r '.error' 2>/dev/null)
       ;;
  esac
  printf '  %s %-18s %s\n' "$icon" "$label" "${detail:-(no detail)}"
}

# Initialize the per-call body capture path. Tests can override with
# TOKEN_HEALTH_LAST_BODY=/tmp/test-body.txt to inspect the body directly.
TOKEN_HEALTH_LAST_BODY="${TOKEN_HEALTH_LAST_BODY:-/tmp/.token-health-last-body.$$}"

# Tests source this with TOKEN_HEALTH_NO_RUN=1 set; reserved for symmetry
# with safe-exec.sh (no side effects at source time today).
if [ "${TOKEN_HEALTH_NO_RUN:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi
