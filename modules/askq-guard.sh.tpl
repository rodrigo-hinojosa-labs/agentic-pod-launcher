#!/usr/bin/env bash
# shellcheck shell=bash
# Rendered from modules/askq-guard.sh.tpl by ./setup.sh --regenerate (feature 031).
# DO NOT hand-edit — change modules/askq-guard.sh.tpl + agent.yml and re-render.
#
# Claude Code PreToolUse hook (matcher: AskUserQuestion): when a Telegram channel
# turn calls the interactive-prompt tool, deny it and redirect the agent to ask
# via plugin:telegram:telegram instead — a console-only menu is invisible to a
# channel operator and would hang the turn (measured feasibility gate, D0).
# Origin is signalled by 028's pending-reply marker (written on inbound, deleted
# on the reply tool); this hook only fires while that marker exists. Bounded by
# a per-prompt_id redirection counter; at the cap the hook switches from
# "redirect" to a TERMINAL deny (still blocks the prompt — never falls through
# to it) and writes a give-up marker for the plugin to deliver one honest
# message.
#
# Contract: specs/031-channel-askuserquestion-guard/contracts/pretooluse-guard-io.md
# Fail-silent (Principle IV): exits 0 on EVERY path, never crashes the session,
# never logs the question text or any secret (Principle V).
set +e

_ENABLED="{{FEATURES_ASKUSERQUESTION_GUARD_ENABLED}}"
_MAX="{{FEATURES_ASKUSERQUESTION_GUARD_MAX_ATTEMPTS}}"

# C1: disabled / unreadable config → no-op. Normalise a non-numeric or absent
# max to 1.
[ "$_ENABLED" = "true" ] || exit 0
case "$_MAX" in ''|*[!0-9]*) _MAX=1 ;; esac
[ "$_MAX" -ge 1 ] 2>/dev/null || _MAX=1

command -v jq >/dev/null 2>&1 || exit 0

# Drain the PreToolUse payload from stdin first (so the writer never sees EPIPE).
_payload="$(cat 2>/dev/null)"
[ -n "$_payload" ] || exit 0

_tool="$(printf '%s' "$_payload" | jq -r '.tool_name // ""' 2>/dev/null)"
# C2/C3: not JSON, or a tool other than AskUserQuestion → allow (do nothing).
[ -n "$_tool" ] || exit 0
[ "$_tool" = "AskUserQuestion" ] || exit 0

_state_dir="${REPLY_GUARD_STATE_DIR:-${HOME:-/home/agent}/.claude/channels/telegram}"
_marker="${REPLY_GUARD_MARKER:-${_state_dir}/pending-reply.json}"
_stderr_log="${REPLY_GUARD_STDERR_LOG:-/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log}"

# C4: a channel turn is awaiting a reply IFF the marker exists (the 028 plugin
# patch writes it on inbound, deletes it on the reply tool). Absent → console /
# local relay / already-replied → FAIL OPEN (allow). This is the OPPOSITE
# fail-safe direction from the 028 Stop hook, by design (spec FR-004): a false
# block would break a legitimate console AskUserQuestion, which is worse than
# leaving a channel turn to the (still-covered-by-the-typing-warning) hang.
[ -f "$_marker" ] || exit 0

_pid="$(printf '%s' "$_payload" | jq -r '.prompt_id // .session_id // "unknown"' 2>/dev/null)"
[ -n "$_pid" ] || _pid="unknown"

_cnt_dir="${_state_dir}/askq-guard-attempts"
mkdir -p "$_cnt_dir" 2>/dev/null || exit 0
_key="$(printf '%s' "$_pid" | tr -c 'A-Za-z0-9._-' '_')"
_cnt_file="${_cnt_dir}/${_key}"
_attempt="$(cat "$_cnt_file" 2>/dev/null)"
case "$_attempt" in ''|*[!0-9]*) _attempt=0 ;; esac

_chat="$(jq -r '.chat_id // ""' "$_marker" 2>/dev/null)"

if [ "$_attempt" -lt "$_MAX" ]; then
  # C5: under the redirection cap — deny + redirect, increment the counter.
  _attempt=$((_attempt + 1))
  printf '%s' "$_attempt" > "$_cnt_file" 2>/dev/null || true
  printf 'askq-guard: redirected AskUserQuestion (chat %s, attempt %s)\n' "${_chat:-?}" "$_attempt" >> "$_stderr_log" 2>/dev/null || true

  _reason='You are answering a Telegram channel turn. AskUserQuestion opens a console-only menu the operator cannot see or answer. Ask your question(s) as ordinary text by calling the plugin:telegram:telegram tool now, with the options spelled out.'
  jq -cn --arg r "$_reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null \
    || printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"AskUserQuestion opens a console-only menu the operator cannot see. Ask your question(s) as ordinary text via plugin:telegram:telegram now."}}\n'
else
  # C6: at/over the cap — TERMINAL deny (never allow-through: the console-only
  # prompt must never open on a confirmed channel turn, or the exact hang this
  # feature exists to prevent reappears). Write the give-up marker once (only
  # if absent) so the plugin delivers exactly one honest give-up message,
  # independent of whether the model complies with the terminal reason.
  printf 'askq-guard: gave up after %s (chat %s) — interactive prompt not answerable in channel\n' "$_attempt" "${_chat:-?}" >> "$_stderr_log" 2>/dev/null || true

  _giveup="${_state_dir}/askq-guard-giveup.json"
  if [ ! -f "$_giveup" ]; then
    _ts="$(date +%s 2>/dev/null || echo 0)"
    jq -cn --arg c "${_chat:-}" --arg p "$_pid" --argjson t "$_ts" '{chat_id:$c, prompt_id:$p, ts:$t}' > "$_giveup" 2>/dev/null \
      || printf '{"chat_id":"","prompt_id":"","ts":0}\n' > "$_giveup" 2>/dev/null || true
  fi

  _reason='AskUserQuestion cannot be answered from a Telegram channel, and you have already been redirected the maximum number of times this turn. Do not call this tool again. Answer the operator in plain text via the plugin:telegram:telegram tool, or end your turn. The operator is being told separately that an unsupported interactive prompt was attempted.'
  jq -cn --arg r "$_reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null \
    || printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"AskUserQuestion is unavailable on this channel turn. Do not call it again — answer in plain text via plugin:telegram:telegram or end your turn."}}\n'
fi
exit 0
