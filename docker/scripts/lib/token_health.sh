#!/usr/bin/env bash
# Library: helpers for the token-health primitive.
#
# Sourced by heartbeatctl, check_token_health.sh, and tests. Pure
# functions where possible; the curl + filesystem operations live here
# but the orchestration (transitions, warnings) lives in
# check_token_health.sh.
#
# Token-health probes free-tier endpoints to detect expired/revoked
# tokens BEFORE the user notices through a broken Claude tool call.
# Four probes today:
#   - probe_github_pat:    GET https://api.github.com/user
#   - probe_telegram_bot:  GET https://api.telegram.org/bot<TOKEN>/getMe
#   - probe_atlassian:     GET <JIRA_URL>/rest/api/3/myself  (basic auth)
#   - probe_claude_oauth:  file-local check of expiresAt in cred file
#                          (no network call — Anthropic does not expose
#                          a free /me endpoint for the OAuth flow).
#
# Probes return on stdout a single line:
#   STATUS HTTP_CODE LATENCY_MS [ERROR_MESSAGE]
# where STATUS ∈ {ok, auth_fail, network}. ok always implies HTTP 200/204.
# auth_fail covers 401/403 (expired/revoked token). network covers
# anything else (DNS, TLS, 5xx, timeout) — distinguished so we don't
# spam warnings when GitHub itself is down.

# Wall-clock helpers. _th_now_iso prints an ISO-8601 UTC timestamp;
# _th_now_epoch prints seconds since epoch.
_th_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
_th_now_epoch() { date -u +%s; }

# Convert ISO-8601 UTC to epoch seconds. Tries GNU date, falls back to
# BSD. Empty input → empty output.
_th_iso_to_epoch() {
  local ts="$1"
  [ -z "$ts" ] && return 0
  if date -d "$ts" +%s 2>/dev/null; then return 0; fi
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || true
}

# Run a curl probe and emit "STATUS HTTP_CODE LATENCY_MS [ERROR]".
# $1 = url, $2 (optional) = extra curl args (auth header, basic auth, …).
# Latency is wall-clock around the curl call. Curl is invoked with
# --max-time 10 so a hung endpoint can't stall the cron tick.
_th_run_probe() {
  local url="$1"; shift || true
  local start_ns end_ns http_code latency_ms exit_code
  start_ns=$(date +%s%N 2>/dev/null || date +%s000000000)
  http_code=$(curl -sS --max-time 10 -o /dev/null \
    -w '%{http_code}' "$@" "$url" 2>/dev/null || true)
  exit_code=$?
  end_ns=$(date +%s%N 2>/dev/null || date +%s000000000)
  latency_ms=$(( (end_ns - start_ns) / 1000000 ))
  [ -z "$http_code" ] && http_code="000"

  local status error=""
  case "$http_code" in
    2??)        status="ok" ;;
    401|403)    status="auth_fail"; error="HTTP $http_code" ;;
    000)        status="network";   error="curl exit $exit_code (DNS/TLS/timeout)" ;;
    *)          status="network";   error="HTTP $http_code" ;;
  esac
  printf '%s %s %s %s\n' "$status" "$http_code" "$latency_ms" "$error"
}

# probe_github_pat TOKEN → STATUS HTTP_CODE LATENCY_MS [ERROR]
# Empty token → status=skipped.
probe_github_pat() {
  local token="${1:-}"
  if [ -z "$token" ]; then
    printf 'skipped 000 0 empty token\n'
    return 0
  fi
  _th_run_probe "https://api.github.com/user" \
    -H "Authorization: token $token" \
    -H "User-Agent: agentic-pod-launcher token-health"
}

# probe_telegram_bot TOKEN → STATUS HTTP_CODE LATENCY_MS [ERROR]
# Empty token → status=skipped. The Telegram API base is overridable
# (TH_TELEGRAM_API_BASE) so tests can point at a stub.
probe_telegram_bot() {
  local token="${1:-}"
  if [ -z "$token" ]; then
    printf 'skipped 000 0 empty token\n'
    return 0
  fi
  local base="${TH_TELEGRAM_API_BASE:-https://api.telegram.org}"
  _th_run_probe "${base}/bot${token}/getMe"
}

# probe_atlassian URL EMAIL TOKEN → STATUS HTTP_CODE LATENCY_MS [ERROR]
# URL should be the Jira base (without /wiki) — Cloud's /rest/api/3/myself
# returns 200 for any authenticated user, with no scope requirement.
# Empty inputs → status=skipped.
probe_atlassian() {
  local url="${1:-}" email="${2:-}" token="${3:-}"
  if [ -z "$url" ] || [ -z "$email" ] || [ -z "$token" ]; then
    printf 'skipped 000 0 missing url/email/token\n'
    return 0
  fi
  url="${url%/}"
  _th_run_probe "${url}/rest/api/3/myself" \
    -u "${email}:${token}"
}

# probe_claude_oauth [CRED_FILE] → STATUS HTTP_CODE LATENCY_MS [ERROR]
# File-local probe: reads ~/.claude/.credentials.json (or arg override),
# extracts claudeAiOauth.expiresAt (epoch milliseconds), compares against
# now. NOT a network call — Anthropic does not expose a free identity
# endpoint for the Claude Code OAuth flow that we could probe without
# burning rate limit. The cred file IS the source of truth: claude
# itself updates it on /login (and, when the CLI eventually implements
# auto-refresh, on refresh too).
#
# Status mapping:
#   - missing file              → skipped 000 0 missing cred file
#   - malformed / no expiresAt  → skipped 000 0 malformed expiresAt
#   - expiresAt < now           → auth_fail 000 0 expired Ns ago
#   - expiresAt - now < 30 min  → auth_fail 000 0 expires in Nm  (early warn)
#   - else                      → ok 000 0
# We use auth_fail (instead of a hypothetical "expiring") for the
# <30min margin so the existing token_health_decide_action + dedup logic
# treats it identically — surface a warning early enough to give the
# user time to /login before the heartbeat actually breaks.
probe_claude_oauth() {
  local cred_file="${1:-$HOME/.claude/.credentials.json}"
  if [ ! -f "$cred_file" ]; then
    printf 'skipped 000 0 missing cred file\n'
    return 0
  fi
  local expires_ms expires_s now_s
  expires_ms=$(jq -r '.claudeAiOauth.expiresAt // empty' "$cred_file" 2>/dev/null)
  if [ -z "$expires_ms" ] || ! [[ "$expires_ms" =~ ^[0-9]+$ ]]; then
    printf 'skipped 000 0 malformed expiresAt\n'
    return 0
  fi
  expires_s=$(( expires_ms / 1000 ))
  now_s=$(_th_now_epoch)
  local margin_s=1800   # 30 min
  if [ "$expires_s" -le "$now_s" ]; then
    printf 'auth_fail 000 0 expired %ds ago\n' "$(( now_s - expires_s ))"
  elif [ "$(( expires_s - now_s ))" -lt "$margin_s" ]; then
    printf 'auth_fail 000 0 expires in %dm\n' "$(( (expires_s - now_s) / 60 ))"
  else
    printf 'ok 000 0\n'
  fi
}

# Enumerate Atlassian workspaces from the environment. For each
# ATLASSIAN_<NAME>_TOKEN found, looks up the matching JIRA_URL +
# JIRA_USERNAME (the canonical pair set by env-example.tpl). Emits one
# line per workspace:
#   <name>|<jira_url>|<email>|<token>
# <name> is lower-cased so it matches the agent.yml schema. Workspaces
# whose token is empty are still emitted — the probe will mark them
# skipped, which surfaces "you configured this but didn't fill .env".
discover_atlassian_workspaces() {
  local var name token url email
  while IFS= read -r var; do
    # var looks like ATLASSIAN_WORK_TOKEN — strip prefix + suffix.
    name="${var#ATLASSIAN_}"
    name="${name%_TOKEN}"
    [ -z "$name" ] && continue
    eval "token=\${${var}:-}"
    eval "url=\${ATLASSIAN_${name}_JIRA_URL:-}"
    eval "email=\${ATLASSIAN_${name}_JIRA_USERNAME:-}"
    # Pipe-safe: tokens are opaque strings without |, but defensively
    # reject any with literal pipes so we don't confuse downstream
    # parsing.
    case "$token" in *\|*) continue ;; esac
    printf '%s|%s|%s|%s\n' \
      "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" \
      "$url" "$email" "$token"
  done < <(env | grep -oE '^ATLASSIAN_[A-Z0-9_]+_TOKEN' | sort -u)
}

# Read a token-health state file. Echoes its JSON content or {} when
# missing. Caller pipes through jq.
token_health_read_state() {
  local file="$1"
  if [ -f "$file" ]; then
    cat "$file"
  else
    echo "{}"
  fi
}

# Write a token-health state file atomically.
# $1 = path, $2 = JSON content.
token_health_write_state() {
  local file="$1" content="$2"
  local dir tmp
  dir=$(dirname "$file")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.$(basename "$file").XXXXXX")
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$file"
}

# Decide what to do given an old vs new probe outcome.
# Inputs: prev_status new_status last_warned_at(epoch|empty) now_epoch dedup_secs
# Output (stdout): one of "warn", "recover", "silent".
#
# Rules:
#   - first probe (prev empty) AND new_status != ok  → warn
#   - prev=ok AND new=auth_fail                       → warn
#   - prev=auth_fail AND new=ok                       → recover
#   - prev=auth_fail AND new=auth_fail AND dedup expired → warn
#   - everything else                                  → silent
# network status is treated as "transient" — never warn alone, but if
# it persists past dedup window, we surface it (could be a permanent
# DNS/network problem on the host).
token_health_decide_action() {
  local prev="$1" new="$2" last_warn="$3" now="$4" dedup="$5"
  case "$prev|$new" in
    ""|"|"*)
      # First-ever probe: warn only if not ok/skipped.
      case "$new" in
        ok|skipped) echo "silent" ;;
        *)          echo "warn" ;;
      esac
      ;;
    "ok|auth_fail"|"network|auth_fail"|"skipped|auth_fail") echo "warn" ;;
    "auth_fail|ok"|"network|ok") echo "recover" ;;
    "ok|network"|"skipped|network")
      # Transient network blip — don't warn yet; defer to dedup logic
      # below so persistent network failures eventually surface.
      echo "silent"
      ;;
    *)
      # Same status as before — re-warn only if (a) status is bad and
      # (b) dedup window elapsed.
      if [ "$new" = "auth_fail" ] || [ "$new" = "network" ]; then
        if [ -z "$last_warn" ]; then
          echo "warn"
        elif [ $((now - last_warn)) -gt "$dedup" ]; then
          echo "warn"
        else
          echo "silent"
        fi
      else
        echo "silent"
      fi
      ;;
  esac
}

# Format a warning message for a token-health failure. Caller pipes to
# the configured notifier.
# $1 = id, $2 = kind (github_pat|telegram_bot|atlassian|claude_oauth), $3 = error.
token_health_format_warning() {
  local id="$1" kind="$2" error="$3"
  local hint=""
  case "$kind" in
    github_pat)
      hint="Regenerate at https://github.com/settings/tokens, then update GITHUB_PAT in .env." ;;
    telegram_bot)
      hint="Talk to @BotFather → /token to revoke + reissue. Update NOTIFY_BOT_TOKEN in .env." ;;
    atlassian)
      hint="Regenerate at https://id.atlassian.com/manage-profile/security/api-tokens. Update ATLASSIAN_<WORKSPACE>_TOKEN in .env." ;;
    claude_oauth)
      hint="OAuth de Claude Code expirado o por expirar. Conéctate a la sesión: agentctl attach → /login → completa el flow OAuth en el browser. Si sigue fallando tras /login, considera el feature flag features.claude_oauth_refresh.enabled (experimental, requiere validación previa)."
      printf '[token-health] %s (%s): %s\n%s\n' \
        "$id" "$kind" "$error" "$hint"
      return 0
      ;;
  esac
  printf '[token-health] %s (%s): %s\n%s\nThen run ./setup.sh --regenerate to refresh derived files.\n' \
    "$id" "$kind" "$error" "$hint"
}

# Format a recovery message.
token_health_format_recovery() {
  local id="$1" kind="$2"
  printf '[token-health] %s (%s): recovered — last probe is back to ok.\n' "$id" "$kind"
}
