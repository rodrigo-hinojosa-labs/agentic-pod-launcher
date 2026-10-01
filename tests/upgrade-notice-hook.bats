#!/usr/bin/env bats
#
# 038 - the SessionStart upgrade-notice hook (modules/upgrade-notice.sh.tpl rendered to
# scripts/hooks/upgrade-notice.sh by --regenerate). At every interactive session start it
# tells the agent what knowledge an upgrade left behind: undeposited-integration schema
# deltas in the vault, and a workspace CLAUDE.md that fell behind the template. With
# nothing pending it prints NOTHING (0 bytes). It never writes, never fails (exit 0 on
# every path) and never emits a half-built notice.
# Contract: specs/038-schema-delta-boot-nudge/contracts/upgrade-notice-hook.md
#
# The workspace is rendered by the real `setup.sh --regenerate` so the baked values
# (language, toggle) come from agent.yml exactly as in production. The three state files
# (C/U/B) are then set BY HAND per test, so these tests do not depend on how regenerate
# manages them (that is claude-md-refresh.bats). The vault is a fixture reached through
# VAULT_ROOT_OVERRIDE, the same override vault_resolve_root honours: the baked docker path
# (/home/agent/.vault) does not exist on a host.

load helper

setup() {
  setup_tmp_dir
  command -v jq >/dev/null || skip "jq not installed"
  load_lib yaml
  yaml_require_yq >/dev/null
  EXTRA_DIRS=""
  STARTUP_JSON='{"hook_event_name":"SessionStart","source":"startup"}'
}

teardown() {
  local d
  for d in $EXTRA_DIRS; do rm -rf "$d"; done
  teardown_tmp_dir
}

# ---- fixtures ------------------------------------------------------------------------

# _make_ws [LANG] [ENABLED]: render a docker-mode workspace into $WS (default $TMP_TEST_DIR/ws).
_make_ws() {
  local lang="${1:-es}" enabled="${2:-true}"
  WS="${WS:-$TMP_TEST_DIR/ws}"
  mkdir -p "$WS"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$WS/"
  cp "$REPO_ROOT/setup.sh" "$WS/"
  cat > "$WS/agent.yml" <<YML
version: 1
agent:
  name: hook-bot
  display_name: "HookBot"
  role: "r"
  vibe: "v"
  use_default_principles: true
user:
  name: "A"
  nickname: "A"
  timezone: "UTC"
  email: "a@b.com"
  language: "$lang"
deployment:
  host: "h"
  workspace: "/tmp/hook-bot"
  install_service: false
docker:
  image_tag: "agent-admin:latest"
  uid: 1000
  gid: 1000
  base_image: "alpine:3.20"
notifications:
  channel: none
features:
  heartbeat:
    enabled: true
    interval: "30m"
    timeout: 300
    retries: 1
    default_prompt: "ok"
  upgrade_notice:
    enabled: $enabled
mcps:
  atlassian: []
  github:
    enabled: false
vault:
  enabled: true
  path: .state/.vault
  seed_skeleton: false
  mcp: {enabled: false}
  qmd: {enabled: false}
  wiki_graph: {enabled: false}
plugins:
  - claude-mem@thedotmack
YML
  # MODE=local renders the local-mode artifacts; VAULT_ON=true lets regenerate itself seed a real
  # vault (local mode only - docker seeds at container boot), as a fresh scaffold would.
  if [ "${MODE:-docker}" = "local" ]; then
    local stub
    stub=$(install_claude_stub)
    yq -i '.deployment.mode = "local"' "$WS/agent.yml"
    yq -i ".deployment.claude_cli = \"$stub\"" "$WS/agent.yml"
  fi
  if [ "${VAULT_ON:-false}" = "true" ]; then
    yq -i '.vault.enabled = true | .vault.path = ".state/.vault" | .vault.seed_skeleton = true | .vault.force_reseed = false | .vault.mcp.enabled = false | .vault.qmd.enabled = false' "$WS/agent.yml"
  fi
  ( cd "$WS" && echo 'n' | ./setup.sh --regenerate >/dev/null 2>&1 )
  HOOK="$WS/scripts/hooks/upgrade-notice.sh"
  if [ "${VAULT_ON:-false}" = "true" ]; then
    VAULT="$WS/.state/.vault"
  else
    VAULT="$WS/vault"
    mkdir -p "$VAULT/_templates"
    printf '# vault CLAUDE.md\n' > "$VAULT/CLAUDE.md"
  fi
  mkdir -p "$WS/.state/launcher"
}

# _rerender LANG ENABLED: change the baked values and re-render.
_rerender() {
  yq -i ".user.language = \"$1\" | .features.upgrade_notice.enabled = $2" "$WS/agent.yml"
  ( cd "$WS" && echo 'n' | ./setup.sh --regenerate >/dev/null 2>&1 )
}

# _deposit VERSION: what the additive vault upgrade leaves behind (marker + delta document).
_deposit() {
  printf 'deposited: 2026-09-30\n' > "$VAULT/_templates/.schema-updates-$1.applied"
  cp "$REPO_ROOT/modules/vault-deltas/schema-updates-$1.md" "$VAULT/_templates/schema-updates-$1.md"
}

# _ws_state STATE: force C/U/B into one of the five states claude_md_state knows.
_ws_state() {
  local c="$WS/CLAUDE.md" u="$WS/.state/launcher/claude-md.upstream.md" b="$WS/.state/launcher/claude-md.baseline.md"
  mkdir -p "$WS/.state/launcher"
  rm -f "$u" "$b"
  case "$1" in
    in_sync)             printf 'template v2\n' > "$u"; cp "$u" "$c"; cp "$u" "$b" ;;
    customized)          printf 'template v2\n' > "$u"; printf 'template v2\nown paragraph\n' > "$c"; cp "$u" "$b" ;;
    pending_template)    printf 'template v2\n' > "$u"; printf 'template v1\n' > "$c"; cp "$c" "$b" ;;
    pending_no_baseline) printf 'template v2\n' > "$u"; printf 'template v1\n' > "$c" ;;
    unknown)             printf 'template v1\n' > "$c" ;;
    *) echo "bad state $1" >&2; return 1 ;;
  esac
}

# _run_hook: the hook exactly as Claude Code invokes it (payload on stdin, env untouched).
_run_hook() {
  run env VAULT_ROOT_OVERRIDE="$VAULT" "$HOOK" <<< "$STARTUP_JSON"
}

# _ctx: the additionalContext string of the hook output (no trailing newline).
_ctx() { printf '%s' "$output" | jq -j '.hookSpecificOutput.additionalContext'; }

# ---- independent oracle: the CANON texts, copied from the contract ---------------------

_canon() {
  case "$1" in
    N1-es) printf '%s' 'Aviso del launcher al iniciar sesion: tienes conocimiento pendiente de actualizar.' ;;
    N2-es) printf '%s' '- Vault, delta de schema {V}: lee {DOC} e integra sus secciones en {VAULT}/CLAUDE.md. Queda integrado cuando ese archivo contiene la linea literal: {CP}' ;;
    N3-es) printf '%s' '- Tu CLAUDE.md del workspace no coincide con la plantilla vigente del launcher. La version vigente esta en {U}; hasta que se actualice, tratala como autoritativa para todo lo que describe sobre la maquinaria del launcher (vault, wiki-graph, qmd, heartbeat, backups). Compara con: diff {C} {U}. Si las diferencias vienen solo de la plantilla, pidele al operador que corra ./setup.sh --regenerate --force-claude-md. Si tienes contenido propio, integra lo nuevo de la plantilla y confirma con: cp {U} {B}' ;;
    N4-es) printf '%s' '- La plantilla del launcher cambio desde la ultima version que integraste en tu CLAUDE.md del workspace. Cambios exactos: diff {B} {U}. Integralos en {C} y confirma con: cp {U} {B}' ;;
    N5-es) printf '%s' 'No bloquees la peticion del operador por esto: responde primero, salvo que dependa de tu base de conocimiento. Mencionale estos pendientes una vez en esta sesion.' ;;
    N1-en) printf '%s' 'Launcher notice at session start: you have knowledge pending an update.' ;;
    N2-en) printf '%s' '- Vault schema delta {V}: read {DOC} and integrate its sections into {VAULT}/CLAUDE.md. It counts as integrated once that file contains the literal line: {CP}' ;;
    N3-en) printf '%s' '- Your workspace CLAUDE.md does not match the current launcher template. The current version is at {U}; until it is updated, treat it as authoritative for everything it says about the launcher machinery (vault, wiki-graph, qmd, heartbeat, backups). Compare with: diff {C} {U}. If the differences come only from the template, ask the operator to run ./setup.sh --regenerate --force-claude-md. If you have content of your own, integrate what is new in the template and confirm with: cp {U} {B}' ;;
    N4-en) printf '%s' '- The launcher template changed since the last version you integrated into your workspace CLAUDE.md. Exact changes: diff {B} {U}. Integrate them into {C} and confirm with: cp {U} {B}' ;;
    N5-en) printf '%s' 'Do not block the operator'\''s request for this: answer first, unless it depends on your knowledge base. Mention these pending items to the operator once in this session.' ;;
    *) echo "unknown canon $1" >&2; return 1 ;;
  esac
}

# _fill TEXT: substitute the {V} {DOC} {VAULT} {CP} {U} {C} {B} placeholders from $F_*.
_fill() {
  local t="$1"
  t="${t//\{V\}/$F_V}"; t="${t//\{DOC\}/$F_DOC}"; t="${t//\{VAULT\}/$F_VAULT}"; t="${t//\{CP\}/$F_CP}"
  t="${t//\{U\}/$F_U}"; t="${t//\{C\}/$F_C}"; t="${t//\{B\}/$F_B}"
  printf '%s' "$t"
}

# _n2 LANG VERSION: the vault line for one delta, with its real document path.
_n2() {
  F_V="$2"; F_VAULT="$VAULT"; F_DOC="$VAULT/_templates/schema-updates-$2.md"
  case "$2" in 0.8.0) F_CP='wiki/normalization/' ;; 0.27.0) F_CP='## Actionability (PARA)' ;; esac
  _fill "$(_canon "N2-$1")"
}

# _ws_line LANG N3|N4: the workspace line with absolute paths.
_ws_line() {
  F_C="$WS/CLAUDE.md"; F_U="$WS/.state/launcher/claude-md.upstream.md"; F_B="$WS/.state/launcher/claude-md.baseline.md"
  _fill "$(_canon "$2-$1")"
}

# ---- nothing pending ------------------------------------------------------------------

@test "038 hook: nothing pending in either layer prints nothing and exits 0" {
  _make_ws
  _deposit 0.27.0
  printf '## Actionability (PARA)\n' >> "$VAULT/CLAUDE.md"
  _ws_state in_sync
  _run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 hook: no vault at all and an in-sync workspace prints nothing (vault disabled agent)" {
  _make_ws
  rm -rf "$VAULT"
  _ws_state in_sync
  _run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 hook: vault.enabled=false silences the VAULT layer even with a deposited, unintegrated delta on disk" {
  # The spec's edge case: a vault the operator turned off but left on disk must not make the agent
  # integrate schema into a vault it no longer uses. The workspace layer is independent of the switch.
  _make_ws es
  yq -i '.vault.enabled = false' "$WS/agent.yml"
  ( cd "$WS" && echo 'n' | ./setup.sh --regenerate >/dev/null 2>&1 )
  grep -q '^_vault_enabled="false"$' "$HOOK"
  _deposit 0.27.0
  _ws_state in_sync
  _run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  _ws_state pending_no_baseline
  _run_hook
  [ "$status" -eq 0 ]
  [ "$(_ctx)" = "$(_canon N1-es)"$'\n'"$(_ws_line es N3)"$'\n'"$(_canon N5-es)" ]
}

@test "038 hook: control - the same disk state with vault.enabled=true does report the delta" {
  _make_ws es
  grep -q '^_vault_enabled="true"$' "$HOOK"
  _deposit 0.27.0
  _ws_state in_sync
  _run_hook
  [ "$status" -eq 0 ]
  [[ "$(_ctx)" == *"delta de schema 0.27.0"* ]]
}

@test "038 hook: an agent.yml with no vault block at all bakes the vault layer off (older agents)" {
  _make_ws es
  yq -i 'del(.vault)' "$WS/agent.yml"
  ( cd "$WS" && echo 'n' | ./setup.sh --regenerate >/dev/null 2>&1 )
  grep -q '^_vault_enabled="false"$' "$HOOK"
  [ "$(grep -c '{{' "$HOOK")" = "0" ]
  _deposit 0.27.0
  _ws_state in_sync
  _run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 hook: workspace 'customized' (own edits, template unchanged) and 'unknown' print nothing" {
  _make_ws
  _ws_state customized
  _run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  _ws_state unknown
  _run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- one pending delta ----------------------------------------------------------------

@test "038 hook: a pending 0.27.0 delta yields valid SessionStart JSON with the exact CANON text (es)" {
  _make_ws es
  _deposit 0.27.0
  _ws_state in_sync
  _run_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "SessionStart" ]
  local expected
  expected="$(_canon N1-es)"$'\n'"$(_n2 es 0.27.0)"$'\n'"$(_canon N5-es)"
  [ "$(_ctx)" = "$expected" ]
}

@test "038 hook: only the two documented keys are emitted (no stray top-level or nested fields)" {
  _make_ws
  _deposit 0.27.0
  _ws_state in_sync
  _run_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c 'keys')" = '["hookSpecificOutput"]' ]
  [ "$(printf '%s' "$output" | jq -c '.hookSpecificOutput | keys')" = '["additionalContext","hookEventName"]' ]
}

@test "038 hook: two pending deltas produce two vault lines, ascending by version" {
  _make_ws es
  _deposit 0.8.0
  _deposit 0.27.0
  _ws_state in_sync
  _run_hook
  [ "$status" -eq 0 ]
  local expected
  expected="$(_canon N1-es)"$'\n'"$(_n2 es 0.8.0)"$'\n'"$(_n2 es 0.27.0)"$'\n'"$(_canon N5-es)"
  [ "$(_ctx)" = "$expected" ]
}

@test "038 hook: a delta document the agent already deleted points at the launcher's copy" {
  _make_ws es
  _deposit 0.27.0
  rm -f "$VAULT/_templates/schema-updates-0.27.0.md"
  _ws_state in_sync
  _run_hook
  [ "$status" -eq 0 ]
  local fallback="$WS/modules/vault-deltas/schema-updates-0.27.0.md"
  [ -f "$fallback" ]
  [[ "$(_ctx)" == *"lee $fallback e integra"* ]]
  [[ "$(_ctx)" != *"$VAULT/_templates/schema-updates-0.27.0.md"* ]]
}

# ---- workspace layer ------------------------------------------------------------------

@test "038 hook: workspace 'pending_no_baseline' yields the N3 line with absolute C/U/B paths" {
  _make_ws es
  _ws_state pending_no_baseline
  _run_hook
  [ "$status" -eq 0 ]
  local expected
  expected="$(_canon N1-es)"$'\n'"$(_ws_line es N3)"$'\n'"$(_canon N5-es)"
  [ "$(_ctx)" = "$expected" ]
}

@test "038 hook: workspace 'pending_template' yields the N4 line (diff base is the baseline)" {
  _make_ws es
  _ws_state pending_template
  _run_hook
  [ "$status" -eq 0 ]
  local expected
  expected="$(_canon N1-es)"$'\n'"$(_ws_line es N4)"$'\n'"$(_canon N5-es)"
  [ "$(_ctx)" = "$expected" ]
}

@test "038 hook: both layers pending in ONE notice: header, deltas ascending, workspace, closing, under 2 KB" {
  WS=$(mktemp -d /tmp/unh.XXXXXX)        # a short path: this test bounds the TEXT, not the host's TMPDIR
  EXTRA_DIRS="$WS"
  _make_ws es
  _deposit 0.8.0
  _deposit 0.27.0
  _ws_state pending_no_baseline
  _run_hook
  [ "$status" -eq 0 ]
  local expected
  expected="$(_canon N1-es)"$'\n'"$(_n2 es 0.8.0)"$'\n'"$(_n2 es 0.27.0)"$'\n'"$(_ws_line es N3)"$'\n'"$(_canon N5-es)"
  [ "$(_ctx)" = "$expected" ]
  [ "$(printf '%s' "$(_ctx)" | wc -c | tr -d ' ')" -lt 2048 ]
}

# ---- language -------------------------------------------------------------------------

@test "038 hook: user.language en renders the English CANON texts" {
  _make_ws en
  _deposit 0.27.0
  _ws_state pending_no_baseline
  _run_hook
  [ "$status" -eq 0 ]
  local expected
  expected="$(_canon N1-en)"$'\n'"$(_n2 en 0.27.0)"$'\n'"$(_ws_line en N3)"$'\n'"$(_canon N5-en)"
  [ "$(_ctx)" = "$expected" ]
}

@test "038 hook: user.language mixed (and any other value) falls back to Spanish" {
  _make_ws mixed
  _deposit 0.27.0
  _ws_state in_sync
  _run_hook
  [ "$status" -eq 0 ]
  [ "$(_ctx)" = "$(_canon N1-es)"$'\n'"$(_n2 es 0.27.0)"$'\n'"$(_canon N5-es)" ]
  _rerender fr true
  _run_hook
  [ "$(_ctx)" = "$(_canon N1-es)"$'\n'"$(_n2 es 0.27.0)"$'\n'"$(_canon N5-es)" ]
}

@test "038 hook: the notice is ASCII only (byte-safety rule shared with 033/034/037 prompts)" {
  _make_ws es
  _deposit 0.8.0
  _deposit 0.27.0
  _ws_state pending_template
  _run_hook
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run bash -c 'printf "%s" "$1" | LC_ALL=C grep -c "[^ -~]"' _ "$output"
  [ "$output" = "0" ]
}

# ---- the switch -----------------------------------------------------------------------

@test "038 hook: features.upgrade_notice.enabled=false silences it even with everything pending" {
  _make_ws es false
  _deposit 0.27.0
  _ws_state pending_no_baseline
  _run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # control: the same state with the switch on does speak (the silence above is the switch)
  _rerender es true
  _run_hook
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "038 hook: independent of features.heartbeat.review.enabled (FR-012): same notice either way" {
  _make_ws es
  _deposit 0.27.0
  _ws_state in_sync
  yq -i '.features.heartbeat.review.enabled = false' "$WS/agent.yml"
  ( cd "$WS" && echo 'n' | ./setup.sh --regenerate >/dev/null 2>&1 )
  _ws_state in_sync
  _run_hook
  [ "$status" -eq 0 ]
  local off="$output"
  [ -n "$off" ]
  yq -i '.features.heartbeat.review.enabled = true' "$WS/agent.yml"
  ( cd "$WS" && echo 'n' | ./setup.sh --regenerate >/dev/null 2>&1 )
  _ws_state in_sync
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "$off" ]
}

# ---- failures never break the session (FR-010) -----------------------------------------

@test "038 hook: a missing claude_md.sh library means silence and exit 0, never a half notice" {
  _make_ws es
  _deposit 0.27.0
  _ws_state pending_no_baseline
  rm -f "$WS/scripts/lib/claude_md.sh"
  _run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 hook: a missing vault.sh library means silence and exit 0" {
  _make_ws es
  _deposit 0.27.0
  _ws_state pending_no_baseline
  rm -f "$WS/scripts/lib/vault.sh"
  _run_hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 hook: without jq on PATH it is silent and exit 0 (and WITH jq, same tools, it speaks: the control)" {
  _make_ws es
  _deposit 0.27.0
  _ws_state in_sync
  local bin="$TMP_TEST_DIR/bin" t
  mkdir -p "$bin"
  # exactly the external tools the hook may use: this also pins its dependency set
  for t in cat dirname cmp grep jq; do ln -s "$(command -v $t)" "$bin/$t"; done
  run env PATH="$bin" VAULT_ROOT_OVERRIDE="$VAULT" "$BASH" "$HOOK" <<< "$STARTUP_JSON"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  rm -f "$bin/jq"
  run env PATH="$bin" VAULT_ROOT_OVERRIDE="$VAULT" "$BASH" "$HOOK" <<< "$STARTUP_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 hook: an unreadable vault CLAUDE.md contributes nothing (and with a clean workspace, silence)" {
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  _make_ws es
  _deposit 0.27.0
  _ws_state in_sync
  chmod 000 "$VAULT/CLAUDE.md"
  _run_hook
  chmod 644 "$VAULT/CLAUDE.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 hook: stdin is drained, not required: empty stdin and a 200 KiB payload both work" {
  _make_ws es
  _deposit 0.27.0
  _ws_state in_sync
  run env VAULT_ROOT_OVERRIDE="$VAULT" "$HOOK" < /dev/null
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  yes 'x' | head -c 204800 > "$TMP_TEST_DIR/payload"
  run env VAULT_ROOT_OVERRIDE="$VAULT" "$HOOK" < "$TMP_TEST_DIR/payload"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ---- it never writes (FR-013) ----------------------------------------------------------

@test "038 hook: read-only (FR-013): vault CLAUDE.md, C, U, B and every file in the workspace stay byte-identical" {
  _make_ws es
  _deposit 0.8.0
  _deposit 0.27.0
  _ws_state pending_no_baseline
  local before after
  before=$(cd "$WS" && find . | sort | while read -r p; do if [ -f "$p" ]; then cksum < "$p"; fi; echo "$p"; done | cksum)
  _run_hook
  [ "$status" -eq 0 ]
  [ -n "$output" ]    # it really ran and spoke
  after=$(cd "$WS" && find . | sort | while read -r p; do if [ -f "$p" ]; then cksum < "$p"; fi; echo "$p"; done | cksum)
  [ "$before" = "$after" ]
}

# ---- speed (SC-002) --------------------------------------------------------------------

@test "038 hook: every check, with or without a notice, finishes in under one second" {
  command -v perl >/dev/null || skip "perl not installed"
  _make_ws es
  _deposit 0.27.0
  local i ms max=0
  # exits 3 if the timed command fails, so a missing/crashing hook can never read as "fast"
  _ms() { perl -MTime::HiRes=time -e '$t=time; $r=system(@ARGV); printf "%d\n", (time-$t)*1000; exit($r ? 3 : 0)' "$@"; }
  _ws_state in_sync
  _run_hook                      # with a notice to give: it must really speak
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ms=$(_ms env VAULT_ROOT_OVERRIDE="$VAULT" "$HOOK" < /dev/null)
    [ "$ms" -gt "$max" ] && max="$ms"
  done
  printf '## Actionability (PARA)\n' >> "$VAULT/CLAUDE.md"
  _ws_state in_sync
  _run_hook                      # nothing left to say: it must run clean and stay silent
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ms=$(_ms env VAULT_ROOT_OVERRIDE="$VAULT" "$HOOK" < /dev/null)
    [ "$ms" -gt "$max" ] && max="$ms"
  done
  echo "# slowest of 20 runs: ${max} ms" >&3
  [ "$max" -lt 1000 ]
}

# ---- shape of the rendered artifact ----------------------------------------------------

@test "038 hook: regenerate renders it executable, with no template placeholder left and valid bash" {
  _make_ws es
  [ -x "$HOOK" ]
  run grep -c '{{' "$HOOK"
  [ "$output" = "0" ]
  bash -n "$HOOK"
  # the three baked values are real, not the literal placeholder names
  grep -q '^_enabled="true"$' "$HOOK"
  grep -q '^_lang="es"$' "$HOOK"
  grep -q '^_vault_default="/home/agent/.vault"$' "$HOOK"
  grep -q '^_vault_enabled="true"$' "$HOOK"
}

@test "038 hook: two --regenerate runs render the hook byte-identical" {
  _make_ws es
  cp "$HOOK" "$TMP_TEST_DIR/hook.first"
  ( cd "$WS" && echo 'n' | ./setup.sh --regenerate >/dev/null 2>&1 )
  cmp -s "$HOOK" "$TMP_TEST_DIR/hook.first"
}

# ---- the contract and this test share one set of texts ---------------------------------

@test "038 hook: every CANON literal in this test appears verbatim in the contract (no silent drift)" {
  local contract="$REPO_ROOT/specs/038-schema-delta-boot-nudge/contracts/upgrade-notice-hook.md"
  [ -f "$contract" ] || skip "feature artifacts not present"
  local k
  for k in N1-es N2-es N3-es N4-es N5-es N1-en N2-en N3-en N4-en N5-en; do
    grep -F -q -- "$(_canon "$k")" "$contract" || { echo "CANON-$k differs from the contract"; return 1; }
  done
}

# ============================================================================
# The settings.json installer: scripts/hooks/install-upgrade-notice-hook.sh
# Same mould as the 028 Stop-hook installer: additive jq merge, dedupe by command,
# touches ONLY .hooks.SessionStart, exit 0 on every path.
# ============================================================================

# _installer: path of the rendered installer in the current $WS.
_installer() { printf '%s' "$WS/scripts/hooks/install-upgrade-notice-hook.sh"; }

@test "038 installer: creates settings.json with exactly one SessionStart entry and no matcher key" {
  _make_ws
  local s="$TMP_TEST_DIR/settings.json" cmd="/workspace/scripts/hooks/upgrade-notice.sh"
  [ ! -e "$s" ]
  run "$(_installer)" "$s" "$cmd"
  [ "$status" -eq 0 ]
  [ -f "$s" ]
  [ "$(jq -S -c '.hooks.SessionStart' "$s")" = '[{"hooks":[{"command":"/workspace/scripts/hooks/upgrade-notice.sh","timeout":10,"type":"command"}]}]' ]
  # no matcher at the group level: a matcher would stop it firing on some session starts
  [ "$(jq '.hooks.SessionStart[0] | has("matcher")' "$s")" = "false" ]
}

@test "038 installer: leaves every other key alone (permissions, plugins, marketplaces, Stop and PreToolUse hooks)" {
  _make_ws
  local s="$TMP_TEST_DIR/settings.json" cmd="/workspace/scripts/hooks/upgrade-notice.sh"
  cat > "$s" <<'JSON'
{
  "permissions": { "defaultMode": "auto" },
  "enabledPlugins": { "telegram@claude-plugins-official": true },
  "extraKnownMarketplaces": { "thedotmack": { "source": { "source": "github", "repo": "thedotmack/claude-mem" } } },
  "skipDangerousModePermissionPrompt": true,
  "hooks": {
    "Stop": [ { "hooks": [ { "type": "command", "command": "/workspace/scripts/hooks/stop-redeliver.sh" } ] } ],
    "PreToolUse": [ { "matcher": "AskUserQuestion", "hooks": [ { "type": "command", "command": "/workspace/scripts/hooks/askq-guard.sh" } ] } ]
  }
}
JSON
  jq -S 'del(.hooks.SessionStart)' "$s" > "$TMP_TEST_DIR/before.json"
  run "$(_installer)" "$s" "$cmd"
  [ "$status" -eq 0 ]
  jq -S 'del(.hooks.SessionStart)' "$s" > "$TMP_TEST_DIR/after.json"
  cmp -s "$TMP_TEST_DIR/before.json" "$TMP_TEST_DIR/after.json"
  [ "$(jq '.hooks.SessionStart | length' "$s")" = "1" ]
}

@test "038 installer: three runs leave exactly one entry for that command (idempotent, self-healing)" {
  _make_ws
  local s="$TMP_TEST_DIR/settings.json" cmd="/workspace/scripts/hooks/upgrade-notice.sh"
  "$(_installer)" "$s" "$cmd"
  "$(_installer)" "$s" "$cmd"
  run "$(_installer)" "$s" "$cmd"
  [ "$status" -eq 0 ]
  [ "$(jq --arg c "$cmd" '[.hooks.SessionStart[].hooks[] | select(.command == $c)] | length' "$s")" = "1" ]
  [ "$(jq '.hooks.SessionStart | length' "$s")" = "1" ]
}

@test "038 installer: a SessionStart hook that is already there (another command) is preserved, ours is added" {
  _make_ws
  local s="$TMP_TEST_DIR/settings.json" cmd="/workspace/scripts/hooks/upgrade-notice.sh"
  printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/opt/other/hook.sh"}]}]}}' > "$s"
  run "$(_installer)" "$s" "$cmd"
  [ "$status" -eq 0 ]
  [ "$(jq '.hooks.SessionStart | length' "$s")" = "2" ]
  [ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$s")" = "/opt/other/hook.sh" ]
  [ "$(jq -r '.hooks.SessionStart[1].hooks[0].command' "$s")" = "$cmd" ]
}

@test "038 installer: settings.json ends up mode 0644" {
  _make_ws
  local s="$TMP_TEST_DIR/settings.json" perm
  "$(_installer)" "$s" "/workspace/scripts/hooks/upgrade-notice.sh"
  perm=$(stat -c %a "$s" 2>/dev/null || stat -f %Lp "$s")
  [ "$perm" = "644" ]
}

@test "038 installer: missing arguments exit 0 and touch nothing" {
  _make_ws
  local s="$TMP_TEST_DIR/settings.json"
  printf '{"theme":"dark"}\n' > "$s"
  cp "$s" "$TMP_TEST_DIR/s.before"
  run "$(_installer)"
  [ "$status" -eq 0 ]
  run "$(_installer)" "$s"
  [ "$status" -eq 0 ]
  cmp -s "$s" "$TMP_TEST_DIR/s.before"
}

@test "038 installer: an unwritable location exits 0 without a stack trace" {
  _make_ws
  run "$(_installer)" "$TMP_TEST_DIR/no/such/dir/settings.json" "/workspace/scripts/hooks/upgrade-notice.sh"
  [ "$status" -eq 0 ]
}

@test "038 installer: invalid JSON in settings.json exits 0 and leaves the file untouched" {
  _make_ws
  local s="$TMP_TEST_DIR/settings.json"
  printf '{ this is not json' > "$s"
  cp "$s" "$TMP_TEST_DIR/s.before"
  run "$(_installer)" "$s" "/workspace/scripts/hooks/upgrade-notice.sh"
  [ "$status" -eq 0 ]
  cmp -s "$s" "$TMP_TEST_DIR/s.before"
  # and it did not leave a stray temp file next to it
  [ "$(ls "$TMP_TEST_DIR" | grep -c 'settings.json.')" = "0" ]
}

@test "038 installer: without jq it exits 0 and touches nothing (and with jq, same tools, it installs: the control)" {
  _make_ws
  local s="$TMP_TEST_DIR/settings.json" bin="$TMP_TEST_DIR/ibin" t
  mkdir -p "$bin"
  for t in mktemp mv chmod rm jq; do ln -s "$(command -v $t)" "$bin/$t"; done
  printf '{"theme":"dark"}\n' > "$s"
  run env PATH="$bin" "$BASH" "$(_installer)" "$s" "/workspace/scripts/hooks/upgrade-notice.sh"
  [ "$status" -eq 0 ]
  [ "$(jq '.hooks.SessionStart | length' "$s")" = "1" ]
  printf '{"theme":"dark"}\n' > "$s"
  rm -f "$bin/jq"
  run env PATH="$bin" "$BASH" "$(_installer)" "$s" "/workspace/scripts/hooks/upgrade-notice.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$s")" = '{"theme":"dark"}' ]
}

@test "038 installer: regenerate renders it executable and valid bash" {
  _make_ws
  [ -x "$(_installer)" ]
  bash -n "$(_installer)"
  run grep -c '{{' "$(_installer)"
  [ "$output" = "0" ]
}

# ============================================================================
# Composition: the pieces only work TOGETHER (boot function -> installer -> settings.json
# -> hook). Each was green alone in 022 and the product was broken; test the seam.
# ============================================================================

@test "038 composition: the boot function registers the RENDERED hook, and the registered command really runs" {
  _make_ws es
  _deposit 0.27.0
  _ws_state in_sync
  local h="$TMP_TEST_DIR/home"
  mkdir -p "$h/.claude"
  run env HOME="$h" START_SERVICES_NO_RUN=1 WS="$WS" bash -c 'source "$1/docker/scripts/start_services.sh"; WORKDIR="$WS"; pre_install_upgrade_notice_hook' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  local cmd
  cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$h/.claude/settings.json")
  [ "$cmd" = "$WS/scripts/hooks/upgrade-notice.sh" ]
  [ -x "$cmd" ]
  [ "$(jq '.hooks.SessionStart | length' "$h/.claude/settings.json")" = "1" ]
  run env VAULT_ROOT_OVERRIDE="$VAULT" "$cmd" <<< "$STARTUP_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0.27.0"* ]]
}

@test "038 composition: running the boot function twice (a watchdog respawn) still leaves one entry" {
  _make_ws es
  local h="$TMP_TEST_DIR/home"
  mkdir -p "$h/.claude"
  run env HOME="$h" START_SERVICES_NO_RUN=1 WS="$WS" bash -c 'source "$1/docker/scripts/start_services.sh"; WORKDIR="$WS"; pre_install_upgrade_notice_hook; pre_install_upgrade_notice_hook' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$(jq '.hooks.SessionStart | length' "$h/.claude/settings.json")" = "1" ]
}

# ============================================================================
# Local mode: the hook is registered by --regenerate (existing agents never log in again)
# and the notice is the same one a docker agent gets (SC-006). A fresh scaffold has nothing
# pending in either layer (SC-007).
# ============================================================================

@test "038 local: --regenerate registers the hook in .state/.claude/settings.json when that dir exists (post-login)" {
  MODE=local _make_ws es
  mkdir -p "$WS/.state/.claude"
  _rerender es true
  local s="$WS/.state/.claude/settings.json"
  [ -f "$s" ]
  [ "$(jq '.hooks.SessionStart | length' "$s")" = "1" ]
  [ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$s")" = "$WS/scripts/hooks/upgrade-notice.sh" ]
  # and running it again does not duplicate (every regenerate re-applies it)
  _rerender es true
  [ "$(jq '.hooks.SessionStart | length' "$s")" = "1" ]
}

@test "038 local: --regenerate never creates .state/.claude on its own (no fake login state)" {
  MODE=local _make_ws es
  [ ! -e "$WS/.state/.claude" ]
  [ ! -e "$WS/.state/.claude/settings.json" ]
}

@test "038 local: an existing settings.json keeps its other keys when the hook is added" {
  MODE=local _make_ws es
  mkdir -p "$WS/.state/.claude"
  printf '%s\n' '{"permissions":{"defaultMode":"auto"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/stop.sh"}]}]}}' > "$WS/.state/.claude/settings.json"
  _rerender es true
  local s="$WS/.state/.claude/settings.json"
  [ "$(jq -r '.permissions.defaultMode' "$s")" = "auto" ]
  [ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" = "/x/stop.sh" ]
  [ "$(jq '.hooks.SessionStart | length' "$s")" = "1" ]
}

@test "038 local: a docker-mode regenerate never touches .state/.claude/settings.json (that is the agent's own home)" {
  MODE=docker _make_ws es
  mkdir -p "$WS/.state/.claude"
  printf '{"theme":"dark"}\n' > "$WS/.state/.claude/settings.json"
  cp "$WS/.state/.claude/settings.json" "$TMP_TEST_DIR/settings.before"
  _rerender es true
  cmp -s "$WS/.state/.claude/settings.json" "$TMP_TEST_DIR/settings.before"
}

@test "038 local: parity (SC-006) - the same pending state yields the same notice in docker and local mode, apart from paths" {
  local ctx_d ctx_l vd wd vl wl
  # WS is assigned on its own line: a prefix assignment before a function call is temporary and
  # would be reverted when _make_ws returns, leaving the helpers below pointing at nothing.
  WS="$TMP_TEST_DIR/wsd"
  MODE=docker _make_ws es
  wd="$WS"; vd="$VAULT"
  _deposit 0.8.0; _deposit 0.27.0; _ws_state pending_no_baseline
  _run_hook
  [ "$status" -eq 0 ]
  ctx_d="$(_ctx)"
  [ -n "$ctx_d" ]
  ctx_d="${ctx_d//$vd/@VAULT@}"; ctx_d="${ctx_d//$wd/@WS@}"

  WS="$TMP_TEST_DIR/wsl"
  MODE=local _make_ws es
  wl="$WS"; vl="$VAULT"
  _deposit 0.8.0; _deposit 0.27.0; _ws_state pending_no_baseline
  _run_hook
  [ "$status" -eq 0 ]
  ctx_l="$(_ctx)"
  ctx_l="${ctx_l//$vl/@VAULT@}"; ctx_l="${ctx_l//$wl/@WS@}"

  [ "$ctx_d" = "$ctx_l" ]
  [[ "$ctx_d" == *"@VAULT@/_templates/schema-updates-0.27.0.md"* ]]   # the normalisation really happened
}

@test "038 local: SC-007 - a fresh scaffold (vault seeded by regenerate itself) has nothing pending in either layer" {
  MODE=local VAULT_ON=true _make_ws es
  [ -f "$VAULT/_templates/.schema-updates-0.27.0.applied" ]     # the seed really happened
  [ -f "$VAULT/CLAUDE.md" ]
  source "$REPO_ROOT/scripts/lib/vault.sh"
  source "$REPO_ROOT/scripts/lib/claude_md.sh"
  [ -z "$(vault_pending_deltas "$VAULT")" ]
  [ "$(claude_md_state "$WS/CLAUDE.md" "$WS/.state/launcher/claude-md.upstream.md" "$WS/.state/launcher/claude-md.baseline.md")" = "in_sync" ]
  # the hook itself, with NO override: it reads the vault path baked for local mode
  grep -q '^_vault_default=".*/\.state/\.vault"$' "$HOOK"
  run env "$HOOK" <<< "$STARTUP_JSON"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "038 local: the baked local vault path works with no override - an un-integrated seeded vault is reported" {
  MODE=local VAULT_ON=true _make_ws es
  # un-integrate the seeded vault: drop the checkpoint heading from its own CLAUDE.md
  grep -v '^## Actionability (PARA)$' "$VAULT/CLAUDE.md" > "$TMP_TEST_DIR/vault-claude.md"
  mv "$TMP_TEST_DIR/vault-claude.md" "$VAULT/CLAUDE.md"
  run env "$HOOK" <<< "$STARTUP_JSON"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')" == *"delta de schema 0.27.0"* ]]
}
