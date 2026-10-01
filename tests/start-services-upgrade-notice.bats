#!/usr/bin/env bats
#
# 038 - docker boot installs the SessionStart upgrade-notice hook into the agent's
# settings.json BEFORE claude starts (so it lands in Claude's startup hook snapshot),
# on the boot and on every watchdog respawn. Same shape as pre_install_stop_hook (028) and
# pre_install_askq_hook (031): the jq merge lives in the rendered workspace installer; this
# function only invokes it, guarded and fail-silent. A pre-038 workspace (no installer) is a
# no-op. Unlike its two siblings it resolves the workspace through $WORKDIR instead of the
# literal /workspace, so a host test can aim it at a tmpdir (precedent: pre_warm_mcps).
# Contract: specs/038-schema-delta-boot-nudge/contracts/upgrade-notice-hook.md section 4

load helper

setup() {
  setup_tmp_dir
  export START_SERVICES_NO_RUN=1
  export HOME="$TMP_TEST_DIR/home"
  mkdir -p "$HOME/.claude"
  unset CLAUDE_CODE_OAUTH_TOKEN
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/start_services.sh"
  # start_services.sh sets WORKDIR=/workspace unconditionally at load; override AFTER sourcing.
  export WORKDIR="$TMP_TEST_DIR/ws"
  mkdir -p "$WORKDIR/scripts/hooks"
}

teardown() { teardown_tmp_dir; }

# _stub_installer RC: an installer stub that records its argv and exits RC.
_stub_installer() {
  cat > "$WORKDIR/scripts/hooks/install-upgrade-notice-hook.sh" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$TMP_TEST_DIR/installer.calls"
exit ${1:-0}
STUB
  chmod +x "$WORKDIR/scripts/hooks/install-upgrade-notice-hook.sh"
}

@test "038 boot: pre_install_upgrade_notice_hook is defined by start_services.sh" {
  run type -t pre_install_upgrade_notice_hook
  [ "$status" -eq 0 ]
  [ "$output" = "function" ]
}

@test "038 boot: a pre-038 workspace (no installer) is a no-op: rc 0 and no settings.json written" {
  [ ! -e "$WORKDIR/scripts/hooks/install-upgrade-notice-hook.sh" ]
  run pre_install_upgrade_notice_hook
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/settings.json" ]
}

@test "038 boot: the installer is called with the user settings.json and the workspace hook path" {
  _stub_installer 0
  run pre_install_upgrade_notice_hook
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP_TEST_DIR/installer.calls")" = "$HOME/.claude/settings.json $WORKDIR/scripts/hooks/upgrade-notice.sh" ]
}

@test "038 boot: an installer that fails never fails the boot (rc 0)" {
  _stub_installer 1
  run pre_install_upgrade_notice_hook
  [ "$status" -eq 0 ]
  [ -f "$TMP_TEST_DIR/installer.calls" ]    # it WAS invoked; the failure was swallowed
}

@test "038 boot: an installer that is present but not executable is skipped, rc 0" {
  _stub_installer 0
  chmod -x "$WORKDIR/scripts/hooks/install-upgrade-notice-hook.sh"
  run pre_install_upgrade_notice_hook
  [ "$status" -eq 0 ]
  [ ! -e "$TMP_TEST_DIR/installer.calls" ]
}

@test "038 boot: start_session installs it after the askq guard and before warming the MCPs" {
  local body
  body=$(awk '/^start_session\(\) \{$/,/^\}$/' "$REPO_ROOT/docker/scripts/start_services.sh")
  [ -n "$body" ]
  local l_askq l_notice l_warm
  l_askq=$(printf '%s\n' "$body" | grep -n '^  pre_install_askq_hook$' | head -1 | cut -d: -f1)
  l_notice=$(printf '%s\n' "$body" | grep -n '^  pre_install_upgrade_notice_hook$' | head -1 | cut -d: -f1)
  l_warm=$(printf '%s\n' "$body" | grep -n '^  pre_warm_mcps$' | head -1 | cut -d: -f1)
  [ -n "$l_askq" ]
  [ -n "$l_notice" ]
  [ -n "$l_warm" ]
  [ "$l_askq" -lt "$l_notice" ]
  [ "$l_notice" -lt "$l_warm" ]
}

@test "038 boot: the install call is one more guarded step: the function never aborts under set -e" {
  _stub_installer 7
  run bash -c 'set -euo pipefail; export START_SERVICES_NO_RUN=1; source "$1/docker/scripts/start_services.sh"; WORKDIR="$2"; pre_install_upgrade_notice_hook; echo AFTER' _ "$REPO_ROOT" "$WORKDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "AFTER" ]
}

@test "038 boot: _run_watchdog stays untouched (its sha oracle is the frozen contract of 036)" {
  # the oracle itself lives in start-services-watchdog.bats; here we only prove 038 did not
  # smuggle the install into the watchdog loop: it is invoked from start_session, nowhere else.
  run grep -c 'pre_install_upgrade_notice_hook' "$REPO_ROOT/docker/scripts/start_services.sh"
  [ "$output" = "2" ]    # the definition and the single call in start_session
  local watchdog
  watchdog=$(awk '/^_run_watchdog\(\) \{$/,/^\}$/' "$REPO_ROOT/docker/scripts/start_services.sh")
  [ -n "$watchdog" ]
  run bash -c 'printf "%s" "$1" | grep -c upgrade_notice' _ "$watchdog"
  [ "$output" = "0" ]
}
