#!/usr/bin/env bash
# shellcheck shell=bash
# Rendered from modules/askq-guard-install.sh.tpl by ./setup.sh --regenerate (031).
# DO NOT hand-edit — change the template + re-render.
#
# Register the AskUserQuestion guard PreToolUse hook in a Claude Code
# settings.json, additively and idempotently, BEFORE the session starts.
# Called from docker boot (start_services.sh) and local login
# (modules/local-login.sh.tpl). Touches ONLY .hooks.PreToolUse (keyed to the
# AskUserQuestion matcher), so it never clobbers permissions /
# skipDangerousModePermissionPrompt / extraKnownMarketplaces / enabledPlugins /
# .hooks.Stop, and preserves any pre-existing PreToolUse entry for a different
# matcher or tool. Same jq-merge shape as modules/stop-hook-install.sh.tpl (028),
# a sibling rather than a generalization so 028's well-exercised installer stays
# untouched.
#
# Usage: install-askq-guard-hook.sh <settings.json path> <absolute hook command>
# Fail-silent (Principle IV): exits 0 on every path.
set +e

_settings="${1:-}"
_cmd="${2:-}"
[ -n "$_settings" ] || exit 0
[ -n "$_cmd" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Start from an empty object if the file is absent, so the merge always has a base.
if [ ! -f "$_settings" ]; then
  printf '{}\n' > "$_settings" 2>/dev/null || exit 0
fi

_tmp="$(mktemp 2>/dev/null)" || exit 0
if jq --arg cmd "$_cmd" '
      .hooks = (.hooks // {})
    | .hooks.PreToolUse = (.hooks.PreToolUse // [])
    | if ([.hooks.PreToolUse[]?.hooks[]?.command] | index($cmd)) then .
      else .hooks.PreToolUse += [{ matcher: "AskUserQuestion", hooks: [ { type: "command", command: $cmd } ] }] end
   ' "$_settings" > "$_tmp" 2>/dev/null; then
  if mv "$_tmp" "$_settings" 2>/dev/null; then
    chmod 0644 "$_settings" 2>/dev/null || true
  else
    rm -f "$_tmp" 2>/dev/null
  fi
else
  rm -f "$_tmp" 2>/dev/null
fi
exit 0
