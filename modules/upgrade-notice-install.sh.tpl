#!/usr/bin/env bash
# shellcheck shell=bash
# Rendered from modules/upgrade-notice-install.sh.tpl by ./setup.sh --regenerate (038).
# DO NOT hand-edit - change the template + re-render.
#
# Register the upgrade-notice SessionStart hook in a Claude Code settings.json, additively and
# idempotently, BEFORE the session starts (a hook is read once, into the startup snapshot). Called
# from the docker boot (start_services.sh, on every start and every watchdog respawn) and from the
# local login / regenerate. Touches ONLY .hooks.SessionStart, so it never clobbers permissions,
# enabledPlugins, extraKnownMarketplaces or the Stop/PreToolUse guards of 028/031, and it preserves
# any SessionStart hook that is already there. Same mould as install-stop-hook.sh (028).
#
# The entry has NO `matcher`: with one, the hook would stop firing on some session starts
# (resume, clear, compact) and the notice would vanish exactly when the agent most needs it.
#
# Usage: install-upgrade-notice-hook.sh <settings.json path> <absolute hook command>
# Fail-silent (Principle IV): exits 0 on every path.
set +e

_settings="${1:-}"
_cmd="${2:-}"
[ -n "$_settings" ] || exit 0
[ -n "$_cmd" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Start from an empty object if the file is absent, so the merge always has a base. The braces keep
# a redirection failure (unwritable or missing directory) off stderr.
if [ ! -f "$_settings" ]; then
  { printf '{}\n' > "$_settings"; } 2>/dev/null || exit 0
fi

_tmp="$(mktemp 2>/dev/null)" || exit 0
if jq --arg cmd "$_cmd" '
      .hooks = (.hooks // {})
    | .hooks.SessionStart = (.hooks.SessionStart // [])
    | if ([.hooks.SessionStart[]?.hooks[]?.command] | index($cmd)) then .
      else .hooks.SessionStart += [{ hooks: [ { type: "command", command: $cmd, timeout: 10 } ] }] end
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
