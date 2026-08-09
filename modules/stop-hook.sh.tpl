#!/usr/bin/env bash
# shellcheck shell=bash
# Rendered from modules/stop-hook.sh.tpl by ./setup.sh --regenerate (feature 028).
# DO NOT hand-edit — change modules/stop-hook.sh.tpl + agent.yml and re-render.
#
# Claude Code Stop hook: when a Telegram channel turn ends WITHOUT the reply tool
# having delivered the answer, re-inject ONCE so the agent resends via
# plugin:telegram:telegram. Origin is signalled by the plugin's pending-reply
# marker (written on inbound, deleted on the reply tool); this hook only fires
# while that marker exists.
#
# Contract: specs/028-channel-reply-guard/contracts/stop-hook-io.md
# Fail-silent (Principle IV): exits 0 on EVERY path, never crashes the session,
# never logs the message text or any secret (Principle V).
set +e

_ENABLED="{{FEATURES_REPLY_GUARD_ENABLED}}"
_MAX="{{FEATURES_REPLY_GUARD_MAX_ATTEMPTS}}"

# Disabled / unreadable config → no-op. Normalise a non-numeric or absent max to 1.
[ "$_ENABLED" = "true" ] || exit 0
case "$_MAX" in ''|*[!0-9]*) _MAX=1 ;; esac
[ "$_MAX" -ge 1 ] 2>/dev/null || _MAX=1

command -v jq >/dev/null 2>&1 || exit 0

# Drain the Stop payload from stdin first (so the writer never sees EPIPE).
_payload="$(cat 2>/dev/null)"

_state_dir="${REPLY_GUARD_STATE_DIR:-${HOME:-/home/agent}/.claude/channels/telegram}"
_marker="${REPLY_GUARD_MARKER:-${_state_dir}/pending-reply.json}"
_stderr_log="${REPLY_GUARD_STDERR_LOG:-/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log}"

# A channel turn is awaiting a reply IFF the marker exists (the plugin writes it on
# inbound and deletes it on the reply tool). Absent → console / already-replied /
# local relay → no-op. This is the origin + unreplied signal in one check.
[ -f "$_marker" ] || exit 0
[ -n "$_payload" ] || exit 0

_active="$(printf '%s' "$_payload" | jq -r '.stop_hook_active // false' 2>/dev/null)"
_answer="$(printf '%s' "$_payload" | jq -r '.last_assistant_message // ""' 2>/dev/null)"
_pid="$(printf '%s' "$_payload" | jq -r '.prompt_id // ""' 2>/dev/null)"

# No answer this turn → don't manufacture a spurious reply.
[ -n "$_answer" ] || exit 0

# --- bound the re-injection ---
if [ "$_MAX" -le 1 ]; then
  # Default: stop_hook_active alone is the loop guard. Already nudged → give up.
  [ "$_active" = "true" ] && exit 0
  _attempt=1
else
  # max_attempts > 1: a per-prompt_id counter survives the block→continue→Stop cycle.
  _cnt_dir="${_state_dir}/reply-guard-attempts"
  mkdir -p "$_cnt_dir" 2>/dev/null || exit 0
  _key="$(printf '%s' "${_pid:-unknown}" | tr -c 'A-Za-z0-9._-' '_')"
  _cnt_file="${_cnt_dir}/${_key}"
  _attempt="$(cat "$_cnt_file" 2>/dev/null)"
  case "$_attempt" in ''|*[!0-9]*) _attempt=0 ;; esac
  [ "$_attempt" -ge "$_MAX" ] && exit 0
  _attempt=$((_attempt + 1))
  printf '%s' "$_attempt" > "$_cnt_file" 2>/dev/null || true
fi

# Fire: one greppable stderr line (chat id + attempt; never the answer text) and a
# {decision:block} that continues the turn with a corrective instruction. The
# reason is fixed text — it does not echo the answer or any secret.
_chat="$(jq -r '.chat_id // ""' "$_marker" 2>/dev/null)"
printf 'reply-guard: re-injected reply-tool nudge (chat %s, attempt %s)\n' "${_chat:-?}" "$_attempt" >> "$_stderr_log" 2>/dev/null || true

_reason='You produced a reply but it was NOT delivered to the operator: this turn did not call the plugin:telegram:telegram tool, so nothing was sent to the Telegram chat. Resend your reply now by calling the plugin:telegram:telegram tool with your answer.'
jq -cn --arg r "$_reason" '{decision:"block", reason:$r}' 2>/dev/null \
  || printf '{"decision":"block","reason":"Your reply was not delivered — call the plugin:telegram:telegram tool now to resend it."}\n'
exit 0
