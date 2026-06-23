#!/usr/bin/env bats
# US2 (008-fix-postlogin-plugin-install): ensure_official_marketplace must not
# hang the boot when `claude` is wedged on `plugin marketplace list/add`. It
# bounds each claude call with `timeout` (degrading to a direct call if timeout
# is absent) and stays fail-silent (returns 0). The original bug: an unbounded
# `claude plugin marketplace list | grep` in the boot path hung the supervisor
# before tmux/watchdog ever started. Host-side, no Docker.
#
# Portability: the runtime image (Alpine/busybox) ships `timeout`, but the dev
# host (macOS) may not. The bounded test installs a small `timeout` shim on PATH
# so it is deterministic everywhere; on Linux CI the real `timeout` would also
# satisfy `command -v timeout`.

load helper

setup() {
  setup_tmp_dir
  export START_SERVICES_NO_RUN=1
  export WORKDIR="$TMP_TEST_DIR"
  export HOME="$TMP_TEST_DIR/home"
  mkdir -p "$HOME" "$TMP_TEST_DIR/bin"
  unset CLAUDE_CODE_OAUTH_TOKEN
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/start_services.sh"
}

teardown() { teardown_tmp_dir; }

# A `claude` stub that wedges as a SINGLE process (`exec sleep`) so a SIGTERM
# from timeout actually kills it and closes the marketplace-list pipe.
_install_hanging_claude() {
  cat > "$TMP_TEST_DIR/bin/claude" <<'EOF'
#!/bin/sh
exec sleep 6
EOF
  chmod +x "$TMP_TEST_DIR/bin/claude"
}

# A minimal enforcing `timeout SECS CMD...` shim: runs CMD, kills it after SECS,
# exits 124 on kill. Deterministic stand-in for environments without `timeout`.
_install_timeout_shim() {
  cat > "$TMP_TEST_DIR/bin/timeout" <<'EOF'
#!/bin/sh
secs="$1"; shift
"$@" &
pid=$!
( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 1; kill -KILL "$pid" 2>/dev/null ) &
killer=$!
wait "$pid" 2>/dev/null; st=$?
kill -TERM "$killer" 2>/dev/null
exit "$st"
EOF
  chmod +x "$TMP_TEST_DIR/bin/timeout"
}

@test "ensure_official_marketplace returns bounded (does not hang) when claude hangs" {
  _install_hanging_claude
  _install_timeout_shim
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  export MARKETPLACE_CMD_TIMEOUT=1
  local start end elapsed
  start=$(date +%s)
  run ensure_official_marketplace
  end=$(date +%s)
  elapsed=$(( end - start ))
  # Fail-silent → always exit 0.
  [ "$status" -eq 0 ]
  # Bounded: with a 1s per-call timeout (list + add) it returns in ~2-3s; the
  # unbounded original blocked ~6s on the marketplace-list call alone.
  [ "$elapsed" -lt 5 ]
}

@test "ensure_official_marketplace degrades to a direct call when timeout is absent" {
  # No timeout shim, fast non-hanging claude → command -v timeout is false, the
  # function calls claude directly and still returns 0 (no regression on hosts
  # without timeout).
  cat > "$TMP_TEST_DIR/bin/claude" <<'EOF'
#!/bin/sh
# marketplace list prints nothing (not registered); add succeeds.
exit 0
EOF
  chmod +x "$TMP_TEST_DIR/bin/claude"
  # PATH with our bin (claude) but WITHOUT a timeout shim. Strip any real
  # timeout so the degraded branch is exercised deterministically.
  export PATH="$TMP_TEST_DIR/bin:/usr/bin:/bin"
  run ensure_official_marketplace
  [ "$status" -eq 0 ]
}

@test "ensure_official_marketplace stays a no-op (exit 0) when claude is absent" {
  mkdir -p "$TMP_TEST_DIR/empty-bin"
  PATH="$TMP_TEST_DIR/empty-bin" run ensure_official_marketplace
  [ "$status" -eq 0 ]
}
