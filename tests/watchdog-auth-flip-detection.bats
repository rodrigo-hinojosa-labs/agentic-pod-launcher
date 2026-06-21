#!/usr/bin/env bats
# Story A (003-bootstrap-hardening): after /login, the watchdog detects the
# auth-credential flip (absent->present) and actively kicks the tmux session,
# so the next respawn installs plugins + attaches channels — even if the
# operator never /exits. File-existence only; NO tmux-pane scraping (CLAUDE.md).
#
# Sourced with START_SERVICES_NO_RUN=1 so only function defs load. We call
# _check_auth_flip directly (not via `run`) so its _prev_auth_present global
# persists across the simulated watchdog ticks within one test.

load helper

setup() {
  setup_tmp_dir
  export START_SERVICES_NO_RUN=1
  export WORKDIR="$TMP_TEST_DIR"
  export HOME="$TMP_TEST_DIR/home"
  mkdir -p "$HOME"
  # The Claude OAuth credential marker, redirected to a tmp path we toggle.
  export AUTH_MARKER_OVERRIDE="$TMP_TEST_DIR/credentials.json"
  # Stub tmux to record invocations instead of touching a real server.
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/tmux" <<STUB
#!/bin/bash
echo "\$*" >> "$TMP_TEST_DIR/tmux-calls.log"
exit 0
STUB
  chmod +x "$TMP_TEST_DIR/bin/tmux"
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/start_services.sh"
}

teardown() { teardown_tmp_dir; }

_kick_count() {
  [ -f "$TMP_TEST_DIR/tmux-calls.log" ] || { echo 0; return; }
  grep -c "kill-session -t $SESSION" "$TMP_TEST_DIR/tmux-calls.log"
}

@test "_check_auth_flip does not kick while the credential marker stays absent" {
  rm -f "$AUTH_MARKER_OVERRIDE"
  _check_auth_flip   # baseline tick (absent)
  _check_auth_flip   # still absent
  [ "$(_kick_count)" -eq 0 ]
}

@test "_check_auth_flip kicks the session on the absent->present flip (post /login)" {
  rm -f "$AUTH_MARKER_OVERRIDE"
  _check_auth_flip            # baseline: unauthenticated
  [ "$(_kick_count)" -eq 0 ]  # no kick yet
  : > "$AUTH_MARKER_OVERRIDE"  # operator completes /login
  _check_auth_flip            # flip -> kick
  [ "$(_kick_count)" -eq 1 ]
}

@test "_check_auth_flip does not kick when already authenticated at baseline" {
  : > "$AUTH_MARKER_OVERRIDE"  # booted already logged-in
  _check_auth_flip            # baseline: present
  _check_auth_flip            # still present
  [ "$(_kick_count)" -eq 0 ]
}

@test "_check_auth_flip kicks only once across repeated present ticks" {
  rm -f "$AUTH_MARKER_OVERRIDE"
  _check_auth_flip            # baseline absent
  : > "$AUTH_MARKER_OVERRIDE"
  _check_auth_flip            # flip -> kick #1
  _check_auth_flip            # present->present -> no kick
  _check_auth_flip
  [ "$(_kick_count)" -eq 1 ]
}
