#!/usr/bin/env bats
# Feature 004 US2 — post-login plugin-install resilience.
#
# After the /login credential flip, the watchdog must keep retrying plugin
# install (non-blocking, tick-based) until every plugin carries its
# .installed-ok sentinel OR a ~120s budget elapses — instead of the single
# post-flip attempt that races the auth-ready moment and gives up.
#
# Pure shell, host-only (Principle III): source start_services.sh with
# START_SERVICES_NO_RUN=1 and drive the new helpers with stubbed tmux + the
# function-redefinition seam (same pattern as start-services-watchdog.bats).

load helper

setup() {
  setup_tmp_dir
  export START_SERVICES_NO_RUN=1
  export WORKDIR="$TMP_TEST_DIR"
  export HOME="$TMP_TEST_DIR/home"
  mkdir -p "$HOME"
  export PLUGIN_POSTLOGIN_BUDGET=120
  mkdir -p "$TMP_TEST_DIR/bin"
  # tmux stub records every invocation so we can count kill-session calls.
  cat > "$TMP_TEST_DIR/bin/tmux" <<STUB
#!/bin/bash
echo "\$@" >> "$TMP_TEST_DIR/tmux.log"
exit 0
STUB
  chmod +x "$TMP_TEST_DIR/bin/tmux"
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/start_services.sh"
}

teardown() { teardown_tmp_dir; }

@test "_check_auth_flip arms the post-login deadline on the absent->present flip" {
  export AUTH_MARKER_OVERRIDE="$TMP_TEST_DIR/creds.json"
  _prev_auth_present=-1
  _post_login_deadline=0
  # First tick establishes the baseline (credential absent) — must NOT arm.
  _check_auth_flip
  [ "$_post_login_deadline" -eq 0 ]
  # Credential now appears (operator completed /login).
  : > "$TMP_TEST_DIR/creds.json"
  local before; before=$(date +%s)
  _check_auth_flip
  # Deadline armed ~budget seconds out.
  [ "$_post_login_deadline" -ge "$(( before + PLUGIN_POSTLOGIN_BUDGET - 5 ))" ]
  [ "$_post_login_deadline" -le "$(( $(date +%s) + PLUGIN_POSTLOGIN_BUDGET + 5 ))" ]
}

@test "_post_login_plugin_retry retries install within budget without kicking" {
  _post_login_deadline=$(( $(date +%s) + PLUGIN_POSTLOGIN_BUDGET ))
  _all_plugins_installed() { return 1; }   # not all installed yet
  ensure_all_plugins_installed() { echo called >> "$TMP_TEST_DIR/install.log"; }
  _post_login_plugin_retry
  [ -f "$TMP_TEST_DIR/install.log" ]            # it retried the install
  [ "$_post_login_deadline" -ne 0 ]             # deadline still armed
  [ ! -f "$TMP_TEST_DIR/tmux.log" ]             # but did NOT kick yet
}

@test "_post_login_plugin_retry kicks once and clears the deadline when all plugins are installed" {
  _post_login_deadline=$(( $(date +%s) + PLUGIN_POSTLOGIN_BUDGET ))
  _all_plugins_installed() { return 0; }        # everything installed
  ensure_all_plugins_installed() { echo called >> "$TMP_TEST_DIR/install.log"; }
  _post_login_plugin_retry
  [ "$(grep -c 'kill-session' "$TMP_TEST_DIR/tmux.log")" -eq 1 ]   # kicked once
  [ "$_post_login_deadline" -eq 0 ]                                # deadline cleared
  [ ! -f "$TMP_TEST_DIR/install.log" ]                            # no needless retry
}

@test "_post_login_plugin_retry kicks exactly once across multiple ticks after completion" {
  _post_login_deadline=$(( $(date +%s) + PLUGIN_POSTLOGIN_BUDGET ))
  _all_plugins_installed() { return 0; }
  _post_login_plugin_retry   # tick 1: kick + clear
  _post_login_plugin_retry   # tick 2: deadline cleared → no-op
  _post_login_plugin_retry   # tick 3: no-op
  [ "$(grep -c 'kill-session' "$TMP_TEST_DIR/tmux.log")" -eq 1 ]
}

@test "_post_login_plugin_retry is a no-op when the deadline is not armed" {
  _post_login_deadline=0
  _all_plugins_installed() { echo checked >> "$TMP_TEST_DIR/check.log"; return 1; }
  ensure_all_plugins_installed() { echo called >> "$TMP_TEST_DIR/install.log"; }
  _post_login_plugin_retry
  [ ! -f "$TMP_TEST_DIR/tmux.log" ]
  [ ! -f "$TMP_TEST_DIR/install.log" ]
}

@test "_post_login_plugin_retry clears the deadline on budget exhaustion without re-kicking" {
  _post_login_deadline=$(( $(date +%s) - 1 ))   # already past the budget
  _all_plugins_installed() { return 1; }        # never finished installing
  ensure_all_plugins_installed() { echo called >> "$TMP_TEST_DIR/install.log"; }
  _post_login_plugin_retry
  [ "$_post_login_deadline" -eq 0 ]             # deadline cleared (terminates)
  [ ! -f "$TMP_TEST_DIR/tmux.log" ]             # no kick on timeout
  [ ! -f "$TMP_TEST_DIR/install.log" ]          # no further attempt after exhaustion
}

@test "_all_plugins_installed is true only when every catalog plugin has .installed-ok" {
  # No catalog lib loaded in host tests → falls back to the required channel
  # plugin's readiness (.installed-ok sentinel under HOME).
  local cache="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"
  mkdir -p "$cache"
  run _all_plugins_installed
  [ "$status" -ne 0 ]            # sentinel missing → not installed
  : > "$cache/.installed-ok"
  run _all_plugins_installed
  [ "$status" -eq 0 ]            # sentinel present → installed
}
