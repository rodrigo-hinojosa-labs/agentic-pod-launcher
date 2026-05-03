#!/usr/bin/env bats
# Tests that auxiliary subsystem failures cannot starve the watchdog.
# Each test stubs the external command (claude / python3) to a known
# behavior and confirms the migrated function bounds its time and
# routes failure to the right place.

load helper

setup() {
  setup_tmp_dir
  export START_SERVICES_NO_RUN=1
  export WORKDIR="$TMP_TEST_DIR"
  export HOME="$TMP_TEST_DIR/home"
  mkdir -p "$HOME"
  # PATH stub directory; per-test we drop fake binaries here and
  # prepend it so start_services.sh sees our stubs first.
  export STUB_BIN="$TMP_TEST_DIR/stub-bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
  # safe-exec env so log_aux_fail writes inside TMP_TEST_DIR.
  export SAFE_EXEC_AUX_LOG="$TMP_TEST_DIR/aux.jsonl"
  export SAFE_EXEC_LOCK_DIR="$TMP_TEST_DIR/locks"
  # Source safe-exec first so log_aux_fail is in scope when we source
  # start_services (the live runtime path also goes through the same
  # source order — entrypoint.sh sources libs before starting services).
  source "$REPO_ROOT/docker/scripts/lib/safe-exec.sh"
  source "$REPO_ROOT/docker/scripts/start_services.sh"
}
teardown() { teardown_tmp_dir; }

# ── ensure_plugin_installed_one: timeout coverage ─────────────────────

@test "ensure_plugin_installed_one returns within ~62s when claude hangs" {
  if ! command -v timeout >/dev/null 2>&1; then
    skip "timeout binary not available — install coreutils to run"
  fi
  # Stub claude that sleeps long enough to exceed the 60s ceiling.
  cat > "$STUB_BIN/claude" <<'SH'
#!/usr/bin/env bash
sleep 999
SH
  chmod +x "$STUB_BIN/claude"

  # We can't actually run the 60s test in CI without burning that much
  # wall time. Instead, lower the ceiling for the test by overriding
  # the function's `timeout 60` to `timeout 2`. We do this by shadowing
  # the timeout binary itself via PATH — let `timeout` (the real one)
  # get a 2s arg by intercepting the install command.
  cat > "$STUB_BIN/timeout" <<'SH'
#!/usr/bin/env bash
# Strip the first arg (the requested seconds) and replace with 2.
shift
exec /usr/bin/timeout 2 "$@" 2>/dev/null || /opt/homebrew/bin/timeout 2 "$@" 2>/dev/null || command timeout 2 "$@"
SH
  chmod +x "$STUB_BIN/timeout"

  # Skip this test if even the real timeout isn't on a known path.
  if [ ! -x /usr/bin/timeout ] && [ ! -x /opt/homebrew/bin/timeout ] && ! command -v gtimeout >/dev/null 2>&1; then
    skip "no real timeout binary at known paths"
  fi

  local start_s=$(date +%s)
  ensure_plugin_installed_one "fakeplugin@nowhere" || true
  local end_s=$(date +%s)
  local elapsed=$((end_s - start_s))
  # Allow generous slack for slow CI; assert it didn't run for the full 999s.
  [ "$elapsed" -lt 10 ]
}

@test "ensure_plugin_installed_one logs aux.jsonl entry when timeout fires" {
  if ! command -v timeout >/dev/null 2>&1; then
    skip "timeout binary not available"
  fi
  if [ ! -x /usr/bin/timeout ] && [ ! -x /opt/homebrew/bin/timeout ] && ! command -v gtimeout >/dev/null 2>&1; then
    skip "no real timeout binary at known paths"
  fi
  cat > "$STUB_BIN/claude" <<'SH'
#!/usr/bin/env bash
sleep 999
SH
  chmod +x "$STUB_BIN/claude"
  cat > "$STUB_BIN/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec /usr/bin/timeout 2 "$@" 2>/dev/null || /opt/homebrew/bin/timeout 2 "$@" 2>/dev/null || command timeout 2 "$@"
SH
  chmod +x "$STUB_BIN/timeout"

  ensure_plugin_installed_one "fakeplugin@nowhere" || true
  [ -s "$SAFE_EXEC_AUX_LOG" ]
  run jq -r '.subsystem' "$SAFE_EXEC_AUX_LOG"
  [ "$output" = "plugin-install" ]
  run jq -r '.reason' "$SAFE_EXEC_AUX_LOG"
  [[ "$output" == *"timeout"* ]]
}

# ── ensure_plugin_installed_one: fast-fail path ───────────────────────

@test "ensure_plugin_installed_one returns 1 quickly when claude exits non-zero" {
  cat > "$STUB_BIN/claude" <<'SH'
#!/usr/bin/env bash
echo "auth failed" >&2
exit 1
SH
  chmod +x "$STUB_BIN/claude"

  local start_s=$(date +%s)
  run ensure_plugin_installed_one "fakeplugin@nowhere"
  local end_s=$(date +%s)
  local elapsed=$((end_s - start_s))
  [ "$status" -eq 1 ]
  [ "$elapsed" -lt 5 ]   # No timeout overhead on the fast-fail path.
}

@test "ensure_plugin_installed_one returns 0 when cache + sentinel exist (skips claude)" {
  # Build a fake cache that already has the sentinel — function should
  # short-circuit before invoking `claude` at all. Confirms the
  # idempotency guarantee.
  cat > "$STUB_BIN/claude" <<'SH'
#!/usr/bin/env bash
echo "this should never be invoked" >&2
exit 99
SH
  chmod +x "$STUB_BIN/claude"

  local cache="$HOME/.claude/plugins/cache/marketplace/myplugin"
  mkdir -p "$cache"
  : > "$cache/.installed-ok"

  run ensure_plugin_installed_one "myplugin@marketplace"
  [ "$status" -eq 0 ]
}

# ── core/aux distinction documented ───────────────────────────────────

@test "start_services.sh top-of-file documents core vs auxiliary" {
  # The doc comment establishes the contract every aux subsystem must
  # follow. If someone deletes it, this test fails — forcing them to
  # update the docs/architecture.md cross-reference too.
  run grep -E "^# +CORE +— |^# +AUX +— " "$REPO_ROOT/docker/scripts/start_services.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CORE"* ]]
  [[ "$output" == *"AUX"* ]]
}
