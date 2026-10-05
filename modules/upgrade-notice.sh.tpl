#!/usr/bin/env bash
# shellcheck shell=bash
# Rendered from modules/upgrade-notice.sh.tpl by ./setup.sh --regenerate (feature 038).
# DO NOT hand-edit - change modules/upgrade-notice.sh.tpl + agent.yml and re-render.
#
# Claude Code SessionStart hook. At the start of every INTERACTIVE session (startup, resume,
# clear, compact) it tells the agent what knowledge an upgrade left behind:
#   - vault layer:     a schema delta was deposited (_templates/.schema-updates-<v>.applied)
#                      but its checkpoint line is not in the vault's own CLAUDE.md yet;
#   - workspace layer: this workspace's CLAUDE.md fell behind the template that renders it
#                      (state pending_template / pending_no_baseline, see scripts/lib/claude_md.sh).
# With nothing pending it prints NOTHING (0 bytes). The agent integrates; nothing here writes.
#
# Heartbeat ticks never receive it: heartbeat.sh drops .hooks.SessionStart from its isolated
# settings.json. Contract: specs/038-schema-delta-boot-nudge/contracts/upgrade-notice-hook.md
#
# Fail-silent (Principle IV): exits 0 on EVERY path, never writes a file, and never prints a
# half-built notice - every guard exits BEFORE anything is printed. External tools used:
# cat, dirname, cmp, grep, jq (tests pin this set). The notice text is ASCII only (the byte-safety
# rule of the 033/034/037 prompts) and is assembled by interpolation, never by pattern replace
# (a path holding an ampersand would be corrupted by bash 5.2+ replace semantics, see 023).
set +e

# Baked at render time from agent.yml (single source of truth). The vault root differs by mode
# (docker /home/agent/.vault, local <workspace>/<vault.path>); VAULT_ROOT_OVERRIDE is the same
# override vault_resolve_root honours, and is what lets a host test aim this at a fixture.
_enabled="{{FEATURES_UPGRADE_NOTICE_ENABLED}}"
_lang="{{USER_LANGUAGE}}"
_vault_default="{{VAULT_MCP_PATH}}"
# The vault layer only applies while the vault is enabled: a vault the operator turned off but left
# on disk must not make the agent integrate schema into a vault it no longer uses (spec edge case;
# `agentctl doctor` skips the same layer). Spelled as a conditional because the engine treats an
# unset variable differently from "false", and an agent.yml without a vault block is common.
_vault_enabled="false"
{{#if VAULT_ENABLED}}
_vault_enabled="true"
{{/if}}

# Claude Code writes a JSON payload to stdin; this hook does not use it. Drain it so the writer
# never takes EPIPE - but never from a terminal, where `cat` would hang a manual run.
[ -t 0 ] || cat >/dev/null 2>&1

[ "$_enabled" = "true" ] || exit 0

# The workspace is two levels above this script (scripts/hooks/ -> <workspace>): /workspace in
# the container, the operator's workspace in local mode. Nothing about it is baked.
_ws="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)" || exit 0
[ -n "$_ws" ] || exit 0

# A workspace that was only partly upgraded may lack a library: say nothing rather than guess.
# shellcheck source=/dev/null
. "$_ws/scripts/lib/vault.sh" 2>/dev/null || exit 0
# shellcheck source=/dev/null
. "$_ws/scripts/lib/claude_md.sh" 2>/dev/null || exit 0
command -v vault_pending_deltas >/dev/null 2>&1 || exit 0
command -v claude_md_state >/dev/null 2>&1 || exit 0

_vault="${VAULT_ROOT_OVERRIDE:-$_vault_default}"
_c="$_ws/CLAUDE.md"
_u="$_ws/.state/launcher/claude-md.upstream.md"
_b="$_ws/.state/launcher/claude-md.baseline.md"

_pending=""
if [ "$_vault_enabled" = "true" ]; then
  _pending="$(vault_pending_deltas "$_vault" 2>/dev/null)"
fi
_cstate="$(claude_md_state "$_c" "$_u" "$_b" 2>/dev/null)"
case "$_cstate" in
  pending_template|pending_no_baseline) _wpend=1 ;;
  *) _wpend=0 ;;
esac

# Nothing to say: 0 bytes (SC-002).
[ -n "$_pending" ] || [ "$_wpend" = 1 ] || exit 0
# Something to say but no way to say it properly: silence (doctor still reports).
command -v jq >/dev/null 2>&1 || exit 0

# CANON-N2: the vault line for one delta, pointing at the document in the vault if the agent
# still has it, else at the launcher's own copy (the agent may delete it after integrating).
_line_vault() {
  local _v="$1" _doc _cp
  _doc="$_vault/_templates/schema-updates-${_v}.md"
  [ -f "$_doc" ] || _doc="$_ws/modules/vault-deltas/schema-updates-${_v}.md"
  _cp="$(vault_delta_checkpoint "$_v")"
  case "$_lang" in
    en) printf '%s' "- Vault schema delta ${_v}: read ${_doc} and integrate its sections into ${_vault}/CLAUDE.md. It counts as integrated once that file contains the literal line: ${_cp}" ;;
    *)  printf '%s' "- Vault, delta de schema ${_v}: lee ${_doc} e integra sus secciones en ${_vault}/CLAUDE.md. Queda integrado cuando ese archivo contiene la linea literal: ${_cp}" ;;
  esac
}

# CANON-N3 (no baseline: provenance unknown) / CANON-N4 (the template moved since the last
# render this CLAUDE.md incorporates: `diff B U` is exactly what changed).
_line_ws() {
  case "$1" in
    pending_template)
      case "$_lang" in
        en) printf '%s' "- The launcher template changed since the last version you integrated into your workspace CLAUDE.md. Exact changes: diff ${_b} ${_u}. Integrate them into ${_c} and confirm with: cp ${_u} ${_b}" ;;
        *)  printf '%s' "- La plantilla del launcher cambio desde la ultima version que integraste en tu CLAUDE.md del workspace. Cambios exactos: diff ${_b} ${_u}. Integralos en ${_c} y confirma con: cp ${_u} ${_b}" ;;
      esac
      ;;
    *)
      case "$_lang" in
        en) printf '%s' "- Your workspace CLAUDE.md does not match the current launcher template. The current version is at ${_u}; until it is updated, treat it as authoritative for everything it says about the launcher machinery (vault, wiki-graph, qmd, heartbeat, backups). Compare with: diff ${_c} ${_u}. If the differences come only from the template, ask the operator to run ./setup.sh --regenerate --force-claude-md. If you have content of your own, integrate what is new in the template and confirm with: cp ${_u} ${_b}" ;;
        *)  printf '%s' "- Tu CLAUDE.md del workspace no coincide con la plantilla vigente del launcher. La version vigente esta en ${_u}; hasta que se actualice, tratala como autoritativa para todo lo que describe sobre la maquinaria del launcher (vault, wiki-graph, qmd, heartbeat, backups). Compara con: diff ${_c} ${_u}. Si las diferencias vienen solo de la plantilla, pidele al operador que corra ./setup.sh --regenerate --force-claude-md. Si tienes contenido propio, integra lo nuevo de la plantilla y confirma con: cp ${_u} ${_b}" ;;
      esac
      ;;
  esac
}

# CANON-N1 / CANON-N5. Anything but `en` (es, mixed, an unknown value) falls back to Spanish.
case "$_lang" in
  en)
    _head="Launcher notice at session start: you have knowledge pending an update."
    _tail="Do not block the operator's request for this: answer first, unless it depends on your knowledge base. Mention these pending items to the operator once in this session."
    ;;
  *)
    _head="Aviso del launcher al iniciar sesion: tienes conocimiento pendiente de actualizar."
    _tail="No bloquees la peticion del operador por esto: responde primero, salvo que dependa de tu base de conocimiento. Mencionale estos pendientes una vez en esta sesion."
    ;;
esac

# Header, one line per pending delta (ascending), at most one workspace line, closing.
_text="$_head"
for _pv in $_pending; do
  _text="${_text}"$'\n'"$(_line_vault "$_pv")"
done
if [ "$_wpend" = 1 ]; then
  _text="${_text}"$'\n'"$(_line_ws "$_cstate")"
fi
_text="${_text}"$'\n'"$_tail"

# Build the whole object first; print only if it is complete.
_out="$(jq -cn --arg ctx "$_text" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}' 2>/dev/null)" || exit 0
[ -n "$_out" ] || exit 0
printf '%s\n' "$_out"
exit 0
