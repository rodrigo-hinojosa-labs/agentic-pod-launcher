#!/usr/bin/env bats
# 045-plugin-launcher-path: claude-mem 15.x invokes its launcher by name, without a
# shell, from /home/agent/.local/bin, and that directory was on no PATH in the
# container. The fix appends it to the END of the PATH of every claude session the
# product creates (start_session and the heartbeat tick)
# and of `agentctl mcp`, from one POSIX function (docker/scripts/lib/agent_path.sh).
# The session PATH is a prefix on the tmux client (`PATH=... tmux new-session`):
# tmux ignores `new-session -e PATH=` and gives the pane the client's PATH (M10).
# Root processes never get it (Principle II).
#
# Contracts: specs/045-plugin-launcher-path/contracts/{agent-path,host-oracle}.md.
# P1-P6 the function, S1-S2 the interactive session, H1-H2 the heartbeat tick,
# A1 agentctl mcp, G1-G2 structural guards.
#
# Assertion rule (039/040): no intermediate `[[ ]]` or `!`; use `[ ]`, `grep -q` or
# `if cmd; then false; fi`, and a `[[ ]]` only as the last line of a test.

load helper

bats_require_minimum_version 1.5.0

setup() {
  setup_tmp_dir
  # Never let a test see the operator's own ~/.local/bin.
  export HOME="$TMP_TEST_DIR/home"
  mkdir -p "$HOME"
  AGENT_PATH_LIB="$REPO_ROOT/docker/scripts/lib/agent_path.sh"
  UB="$HOME/.local/bin"
  TMUX_PREFIX="ub045-$$"
  # A private tmux server: the tests never touch the operator's own sessions.
  unset TMUX
  export TMUX_TMPDIR="$TMP_TEST_DIR/tmux"
  mkdir -p "$TMUX_TMPDIR"
  # tmux runs pane commands with $SHELL and may read $XDG_CONFIG_HOME/tmux/tmux.conf:
  # pin both, so the operator's zsh startup files or tmux config cannot touch PATH.
  export SHELL=/bin/sh
  export XDG_CONFIG_HOME="$TMP_TEST_DIR/xdg"
}

teardown() {
  tmux kill-server 2>/dev/null || true
  teardown_tmp_dir
}

# POSIX_SH: dash when the host has it (Ubuntu's /bin/sh, and /bin/dash on macOS),
# otherwise sh. macOS's /bin/sh is bash in POSIX mode and would accept `[[ ]]`.
POSIX_SH="${AGENT_PATH_SH:-$(command -v dash || echo sh)}"

# _compose ARGS... : run agent_path_compose under a POSIX sh (not bash), as
# agentctl's remote `sh -c` and BusyBox sh in the container do.
_compose() {
  run --separate-stderr "$POSIX_SH" -c '. "$1"; shift; agent_path_compose "$@"' _ "$AGENT_PATH_LIB" "$@"
}

# ── C1: agent_path_compose ───────────────────────────────────────────────────

@test "045 P1: appends \$HOME/.local/bin at the end, one line, rc 0, nothing on stderr" {
  _compose "/a:/b" "$HOME" 501
  [ "$status" -eq 0 ]
  [ "$output" = "/a:/b:$HOME/.local/bin" ]
  [ "${#lines[@]}" -eq 1 ]
  [ -z "$stderr" ]
}

@test "045 P2: idempotent when the directory is already at the start, middle or end" {
  _compose "$UB:/a" "$HOME" 501
  [ "$status" -eq 0 ]
  [ "$output" = "$UB:/a" ]
  _compose "/a:$UB:/b" "$HOME" 501
  [ "$status" -eq 0 ]
  [ "$output" = "/a:$UB:/b" ]
  _compose "/a:$UB" "$HOME" 501
  [ "$status" -eq 0 ]
  [ "$output" = "/a:$UB" ]
  # Near misses are other directories: the match is on whole PATH elements.
  _compose "/a:$UB-old" "$HOME" 501
  [ "$status" -eq 0 ]
  [ "$output" = "/a:$UB-old:$UB" ]
  _compose "/x$UB:/a" "$HOME" 501
  [ "$status" -eq 0 ]
  [ "$output" = "/x$UB:/a:$UB" ]
}

@test "045 P3: UID 0, an empty UID or a non-decimal UID never gets the directory (fail closed)" {
  _compose "/a:/b" "$HOME" 0
  [ "$status" -eq 0 ]
  [ "$output" = "/a:/b" ]
  _compose "/a:/b" "$HOME" 00
  [ "$status" -eq 0 ]
  [ "$output" = "/a:/b" ]
  _compose "/a:/b" "$HOME" ""
  [ "$status" -eq 0 ]
  [ "$output" = "/a:/b" ]
  _compose "/a:/b" "$HOME" "5x"
  [ "$status" -eq 0 ]
  [ "$output" = "/a:/b" ]
  _compose "/a:/b" "$HOME" 1000
  [ "$status" -eq 0 ]
  [ "$output" = "/a:/b:$HOME/.local/bin" ]
}

@test "045 P4: an empty, root, relative, trailing-slash, ':' or newline HOME, and an empty PATH, leave the input unchanged" {
  _compose "/a:/b" "" 501
  [ "$status" -eq 0 ]
  [ "$output" = "/a:/b" ]
  _compose "/a:/b" "/" 501
  [ "$status" -eq 0 ]
  [ "$output" = "/a:/b" ]
  _compose "/a:/b" "/x:y" 501
  [ "$status" -eq 0 ]
  [ "$output" = "/a:/b" ]
  _compose "/a:/b" "$(printf '/x\ny')" 501
  [ "$status" -eq 0 ]
  [ "$output" = "/a:/b" ]
  _compose "/a:/b" "home/agent" 501
  [ "$status" -eq 0 ]
  [ "$output" = "/a:/b" ]
  _compose "/a:/b" "$HOME/" 501
  [ "$status" -eq 0 ]
  [ "$output" = "/a:/b" ]
  _compose "" "$HOME" 501
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "045 P5: sourcing under sh defines no variable and leaves PATH alone; calling it does not export" {
  # Variable NAMES only (values such as LINENO change on their own). The script's
  # own variables and the shell-maintained PIPESTATUS/_ are left out of both lists.
  run --separate-stderr "$POSIX_SH" -c '
    names() {
      set | sed -n "s/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p" \
        | grep -vxE "p0|before|after|r|PIPESTATUS|_" | sort -u
    }
    p0="$PATH"
    before=$(names)
    . "$1" || exit 10
    after=$(names)
    [ "$PATH" = "$p0" ] || exit 11
    [ "$before" = "$after" ] || exit 12
    r=$(agent_path_compose "$PATH" "$2" 501) || exit 13
    [ -n "$r" ] || exit 14
    [ "$PATH" = "$p0" ] || exit 15
    exit 0
  ' _ "$AGENT_PATH_LIB" "$HOME"
  [ -z "$stderr" ]
  [ "$status" -eq 0 ]
}

@test "045 P6: appends the directory even when it does not exist (no filesystem check)" {
  local nohome="$TMP_TEST_DIR/no-such-home"
  _compose "/a:/b" "$nohome" 501
  [ "$status" -eq 0 ]
  [ ! -e "$nohome" ]
  [ "$output" = "/a:/b:$nohome/.local/bin" ]
}

# ── C2: start_session (docker/scripts/start_services.sh) ─────────────────────

# _load_supervisor: source start_services.sh in test mode and stub everything
# start_session touches, so only its PATH handling is exercised.
_load_supervisor() {
  export START_SERVICES_NO_RUN=1
  export WORKDIR="$TMP_TEST_DIR"
  unset CLAUDE_CODE_OAUTH_TOKEN
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/start_services.sh"
  WATCHDOG_RUNTIME_DIR="$TMP_TEST_DIR/wd"
  CHANNEL_MARKER="$WATCHDOG_RUNTIME_DIR/session.channels-mode"
  pre_accept_bypass_permissions() { :; }
  pre_seed_onboarding() { :; }
  pre_install_stop_hook() { :; }
  pre_install_askq_hook() { :; }
  pre_install_upgrade_notice_hook() { :; }
  pre_warm_mcps() { :; }
  sleep() { :; }
  next_tmux_cmd() { echo "CLAUDE_CONFIG_DIR=/x claude"; }
  tmux() {
    printf 'ENV_PATH=%s\n' "$PATH" >> "$TMP_TEST_DIR/tmux.rec"
    printf '%s\n' "$@" >> "$TMP_TEST_DIR/tmux.rec"
    printf '%s\n' '--' >> "$TMP_TEST_DIR/tmux.rec"
    return 0
  }
  log() { printf '%s\n' "$*" >> "$TMP_TEST_DIR/log.rec"; }
}

# _new_session_block: the recorded call of `tmux new-session`: the PATH the client
# ran with (ENV_PATH=..., recorded first) and its argv.
_new_session_block() {
  awk '/^ENV_PATH=/ { env = $0; next } $0 == "new-session" { on = 1; print env } on && $0 == "--" { exit } on { print }' "$TMP_TEST_DIR/tmux.rec"
}

@test "045 S1: start_session runs tmux new-session with PATH=<PATH>:\$HOME/.local/bin, command and supervisor PATH unchanged" {
  _load_supervisor
  local p0="$PATH"
  start_session
  _new_session_block > "$TMP_TEST_DIR/ns.rec"
  [ "$(sed -n '1p' "$TMP_TEST_DIR/ns.rec")" = "ENV_PATH=$p0:$HOME/.local/bin" ]
  # tmux ignores `new-session -e PATH=` (research M10): it must not be relied on.
  if grep -qx -- '-e' "$TMP_TEST_DIR/ns.rec"; then false; fi
  [ "$(tail -n 1 "$TMP_TEST_DIR/ns.rec")" = "CLAUDE_CONFIG_DIR=/x claude" ]
  [ "$PATH" = "$p0" ]
}

@test "045 S2: without agent_path_compose, start_session still creates the session with the plain PATH and logs it once" {
  _load_supervisor
  unset -f agent_path_compose
  local p0="$PATH"
  start_session
  _new_session_block > "$TMP_TEST_DIR/ns.rec"
  [ "$(sed -n '1p' "$TMP_TEST_DIR/ns.rec")" = "ENV_PATH=$p0" ]
  [ "$(sed -n '2p' "$TMP_TEST_DIR/ns.rec")" = "new-session" ]
  [ "$(grep -c 'not on the session PATH' "$TMP_TEST_DIR/log.rec")" -eq 1 ]
  start_session
  [ "$(grep -c 'not on the session PATH' "$TMP_TEST_DIR/log.rec")" -eq 1 ]
}

@test "045 S3: start_session passes the real UID: as UID 0 the session keeps the plain PATH" {
  _load_supervisor
  id() { echo 0; }
  local p0="$PATH"
  start_session
  _new_session_block > "$TMP_TEST_DIR/ns.rec"
  [ "$(sed -n '1p' "$TMP_TEST_DIR/ns.rec")" = "ENV_PATH=$p0" ]
  if grep -q 'appended' "$TMP_TEST_DIR/log.rec" 2>/dev/null; then false; fi
}

# ── C3: the heartbeat tick (scripts/heartbeat/heartbeat.sh) ──────────────────

# _heartbeat_workspace: a workspace named like the agent, the heartbeat copied in,
# and a claude stub that records the PATH it was started with.
_heartbeat_workspace() {
  WORKSPACE="$TMP_TEST_DIR/$TMUX_PREFIX-hb"
  mkdir -p "$WORKSPACE/scripts" "$HOME/.claude"
  cp -R "$REPO_ROOT/scripts/heartbeat" "$WORKSPACE/scripts/"
  cat > "$WORKSPACE/scripts/heartbeat/heartbeat.conf" <<CONF
HEARTBEAT_INTERVAL="2m"
HEARTBEAT_CRON="*/2 * * * *"
HEARTBEAT_TIMEOUT="5"
HEARTBEAT_RETRIES="0"
HEARTBEAT_PROMPT="echo ok"
HEARTBEAT_ENABLED="true"
NOTIFY_CHANNEL="none"
NOTIFY_SUCCESS_EVERY="1"
CONF
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/claude" <<STUB
#!/bin/bash
printf '%s\n' "\$PATH" > "$TMP_TEST_DIR/claude.path"
echo ok
exit 0
STUB
  chmod +x "$TMP_TEST_DIR/bin/claude"
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  export HEARTBEAT_STATE_LIB="$REPO_ROOT/docker/scripts/lib/state.sh"
}

@test "045 H1: a heartbeat tick runs claude with PATH = <tick PATH>:\$HOME/.local/bin" {
  _heartbeat_workspace
  export HEARTBEAT_AGENT_PATH_LIB="$AGENT_PATH_LIB"
  local tick_path="$PATH"
  # Start the private tmux server first, from a client with a DIFFERENT PATH, so the
  # server's global environment differs from the tick's: only the client's PATH can
  # make this test pass (the M4 lesson: distinct values for the two sources).
  PATH=/usr/bin:/bin "$(command -v tmux)" new-session -d -s "$TMUX_PREFIX-pre" "sleep 60"
  run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  run jq -r '.status' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl"
  [ "$output" = "ok" ]
  [ -f "$TMP_TEST_DIR/claude.path" ]
  [ "$(cat "$TMP_TEST_DIR/claude.path")" = "$tick_path:$HOME/.local/bin" ]
}

@test "045 H2: without the lib the tick still runs (status ok, no error on stderr) with the plain PATH" {
  _heartbeat_workspace
  export HEARTBEAT_AGENT_PATH_LIB="$TMP_TEST_DIR/no-such-lib.sh"
  local tick_path="$PATH"
  run --separate-stderr bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  if printf '%s' "$stderr" | grep -qiE 'agent_path|no such file'; then false; fi
  run jq -r '.status' "$WORKSPACE/scripts/heartbeat/logs/runs.jsonl"
  [ "$output" = "ok" ]
  [ -f "$TMP_TEST_DIR/claude.path" ]
  [ "$(cat "$TMP_TEST_DIR/claude.path")" = "$tick_path" ]
}

@test "045 H3: the tick passes the real UID: with an id that says 0 the tick keeps the plain PATH" {
  _heartbeat_workspace
  export HEARTBEAT_AGENT_PATH_LIB="$AGENT_PATH_LIB"
  printf '#!/bin/sh\necho 0\n' > "$TMP_TEST_DIR/bin/id"
  chmod +x "$TMP_TEST_DIR/bin/id"
  local tick_path="$PATH"
  run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"
  [ "$status" -eq 0 ]
  [ -f "$TMP_TEST_DIR/claude.path" ]
  [ "$(cat "$TMP_TEST_DIR/claude.path")" = "$tick_path" ]
}

# ── C4: agentctl mcp (scripts/agentctl) ──────────────────────────────────────

AGENTCTL="$REPO_ROOT/scripts/agentctl"

_docker_recorder() {
  cat > "$TMP_TEST_DIR/docker" <<REC
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TMP_TEST_DIR/recorded"
REC
  chmod +x "$TMP_TEST_DIR/docker"
  export PATH="$TMP_TEST_DIR:$PATH"
}

@test "045 A1: agentctl mcp runs claude mcp inside sh -c that loads the lib only if present; shell --root untouched" {
  _docker_recorder
  cd "$TMP_TEST_DIR"
  AGENT_NAME=test run "$AGENTCTL" mcp
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$TMP_TEST_DIR/recorded")" = "exec" ]
  [ "$(sed -n '2p' "$TMP_TEST_DIR/recorded")" = "-u" ]
  [ "$(sed -n '3p' "$TMP_TEST_DIR/recorded")" = "agent" ]
  [ "$(sed -n '4p' "$TMP_TEST_DIR/recorded")" = "test" ]
  [ "$(sed -n '5p' "$TMP_TEST_DIR/recorded")" = "sh" ]
  [ "$(sed -n '6p' "$TMP_TEST_DIR/recorded")" = "-c" ]
  local script
  script=$(sed -n '7p' "$TMP_TEST_DIR/recorded")
  case "$script" in
    *"/opt/agent-admin/scripts/lib/agent_path.sh"*) ;;
    *) false ;;
  esac
  case "$script" in
    *'exec claude mcp "$@"') ;;
    *) false ;;
  esac
  [ "$(sed -n '8p' "$TMP_TEST_DIR/recorded")" = "agentctl-mcp" ]
  [ "$(sed -n '9p' "$TMP_TEST_DIR/recorded")" = "list" ]
  [ "$(wc -l < "$TMP_TEST_DIR/recorded" | tr -d ' ')" -eq 9 ]
  AGENT_NAME=test run "$AGENTCTL" shell --root
  [ "$status" -eq 0 ]
  if grep -q 'agent_path' "$TMP_TEST_DIR/recorded"; then false; fi
  if grep -qx -- '-u' "$TMP_TEST_DIR/recorded"; then false; fi
  grep -qx 'bash' "$TMP_TEST_DIR/recorded"
}

@test "045 A2: the agentctl mcp script, run under a POSIX sh, keeps the PATH without the lib and extends it with the lib" {
  _docker_recorder
  cd "$TMP_TEST_DIR"
  AGENT_NAME=test run "$AGENTCTL" mcp
  [ "$status" -eq 0 ]
  local script name0 arg1
  script=$(sed -n '7p' "$TMP_TEST_DIR/recorded")
  name0=$(sed -n '8p' "$TMP_TEST_DIR/recorded")
  arg1=$(sed -n '9p' "$TMP_TEST_DIR/recorded")
  [ -n "$script" ]
  mkdir -p "$TMP_TEST_DIR/cbin"
  cat > "$TMP_TEST_DIR/cbin/claude" <<STUB
#!/bin/sh
printf '%s\n' "\$PATH" > "$TMP_TEST_DIR/mcp.path"
printf '%s\n' "\$*" > "$TMP_TEST_DIR/mcp.args"
STUB
  chmod +x "$TMP_TEST_DIR/cbin/claude"
  local p0="$TMP_TEST_DIR/cbin:/usr/bin:/bin"
  # The host has no /opt/agent-admin, so this is the older-image branch: no lib.
  [ ! -e /opt/agent-admin/scripts/lib/agent_path.sh ]
  run env PATH="$p0" HOME="$HOME" "$POSIX_SH" -c "$script" "$name0" "$arg1"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP_TEST_DIR/mcp.args")" = "mcp list" ]
  [ "$(cat "$TMP_TEST_DIR/mcp.path")" = "$p0" ]
  # The same script pointed at the repo's lib: the PATH gains the directory.
  # sed, not ${v//pat/repl}: bash 5.2 gives `&` a meaning in the replacement (023).
  local with_lib
  with_lib=$(printf '%s' "$script" | sed "s#/opt/agent-admin/scripts/lib/agent_path.sh#$AGENT_PATH_LIB#")
  [ "$with_lib" != "$script" ]
  run env PATH="$p0" HOME="$HOME" "$POSIX_SH" -c "$with_lib" "$name0" "$arg1"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP_TEST_DIR/mcp.args")" = "mcp list" ]
  [ "$(cat "$TMP_TEST_DIR/mcp.path")" = "$p0:$HOME/.local/bin" ]
}

# ── C5: structural guards ────────────────────────────────────────────────────

@test "045 G1: no root-side path gets the directory: Dockerfile, compose environment, entrypoint, no exported PATH" {
  # Every ENV instruction is read whole (continuation lines joined), so a PATH=...
  # continuation line inside a multi-line ENV cannot slip past (mutation M18).
  local env_hits
  env_hits=$(awk '{ line = line $0 } /\\$/ { sub(/\\$/, "", line); next } { print line; line = "" }' \
    "$REPO_ROOT/docker/Dockerfile" | grep -E '^[[:space:]]*ENV[[:space:]]' | grep -c '\.local/bin' || true)
  [ "$env_hits" -eq 0 ]
  # No non-comment Dockerfile line names the directory at all: a baked
  # `RUN ln -s /home/agent/.local/bin/... /usr/local/bin/...` (the shape of cbum's
  # manual patch) would put an agent-writable target on root's PATH (M19).
  local df_hits
  df_hits=$(grep -vE '^[[:space:]]*#' "$REPO_ROOT/docker/Dockerfile" | grep -c '\.local/bin' || true)
  [ "$df_hits" -eq 0 ]
  # compose's environment: reaches tini, the entrypoint and crond (M20).
  if grep -qE '^[[:space:]]+(-[[:space:]]*)?PATH[[:space:]]*[:=]' "$REPO_ROOT/modules/docker-compose.yml.tpl"; then false; fi
  if grep -qE 'agent_path|\.local/bin' "$REPO_ROOT/docker/entrypoint.sh"; then false; fi
  local f
  for f in "$REPO_ROOT/docker/scripts/start_services.sh" "$REPO_ROOT/scripts/heartbeat/heartbeat.sh"; do
    if grep -qE '^[[:space:]]*export[[:space:]]+PATH' "$f"; then false; fi
    if grep -qE '^[[:space:]]*PATH=[^[:space:]]*[[:space:]]*$' "$f"; then false; fi
  done
  awk '/^cmd_shell\(\) \{/ { on = 1 } on { print } on && /^}/ { exit }' "$REPO_ROOT/scripts/agentctl" > "$TMP_TEST_DIR/cmd_shell.body"
  [ -s "$TMP_TEST_DIR/cmd_shell.body" ]
  if grep -q 'agent_path' "$TMP_TEST_DIR/cmd_shell.body"; then false; fi
}

@test "045 G2: the Dockerfile copies agent_path.sh to the image path the three callers name" {
  grep -qE '^COPY scripts/lib/agent_path\.sh +/opt/agent-admin/scripts/lib/agent_path\.sh$' "$REPO_ROOT/docker/Dockerfile"
  grep -qF '/opt/agent-admin/scripts/lib/agent_path.sh' "$REPO_ROOT/docker/scripts/start_services.sh"
  grep -qF '/opt/agent-admin/scripts/lib/agent_path.sh' "$REPO_ROOT/scripts/heartbeat/heartbeat.sh"
  grep -qF '/opt/agent-admin/scripts/lib/agent_path.sh' "$REPO_ROOT/scripts/agentctl"
  [ -f "$REPO_ROOT/docker/scripts/lib/agent_path.sh" ]
}
