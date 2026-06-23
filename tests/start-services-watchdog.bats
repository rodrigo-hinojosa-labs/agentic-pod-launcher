#!/usr/bin/env bats
# Tests for crash_budget_check sliding-window logic in start_services.sh.
# We source the script with START_SERVICES_NO_RUN=1 so the runtime block
# (boot_side_effects + tmux launch + watchdog loop) is skipped — only
# the function definitions and config globals load.

load helper

setup() {
  setup_tmp_dir
  # Source the supervisor in test-only mode.
  export START_SERVICES_NO_RUN=1
  # Workspace and HOME so any function references resolve to tmp paths
  # rather than /workspace or /home/agent (image-bound paths).
  export WORKDIR="$TMP_TEST_DIR"
  export HOME="$TMP_TEST_DIR/home"
  mkdir -p "$HOME"
  # Isolate the token-aware boot tests from any CLAUDE_CODE_OAUTH_TOKEN in
  # the host env so absence-of-token cases stay deterministic.
  unset CLAUDE_CODE_OAUTH_TOKEN
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/start_services.sh"
}

teardown() { teardown_tmp_dir; }

@test "crash_budget_check accepts 4 crashes spread over 600s (sliding window)" {
  # Five crashes, but four are >300s old. crash_budget_check trims those
  # and reports just the recent one as in-window; budget should still
  # have room.
  local now=10000
  local times="9100 9200 9300 9400 9999"  # last is within 300s of now
  run crash_budget_check "$now" "$times"
  [ "$status" -eq 0 ]
  # Output is just the surviving timestamps.
  [[ "$output" == *"9999"* ]]
  [[ "$output" != *"9100"* ]]
}

@test "crash_budget_check exits when 5 crashes fit within trailing 300s" {
  local now=10000
  local times="9800 9850 9900 9950 9999"  # all within 300s
  run crash_budget_check "$now" "$times"
  [ "$status" -ne 0 ]
}

@test "crash_budget_check accepts 5 crashes spread over 1500s (none recent)" {
  # A crashy week ago doesn't poison today's budget.
  local now=10000
  local times="8500 8800 9000 9200 9500"  # all > 300s old
  run crash_budget_check "$now" "$times"
  [ "$status" -eq 0 ]
  # All entries should be dropped.
  [ -z "$(echo "$output" | tr -d ' ')" ]
}

@test "crash_budget_check is the strict-equality sliding boundary at exactly 300s" {
  # An entry exactly at now-WINDOW (the boundary) is dropped (kept ones
  # must be strictly NEWER than cutoff). 4 newer + 1 boundary = 4 in window.
  local now=10000
  local times="9700 9800 9850 9900 9950"  # 9700 == now - WINDOW
  run crash_budget_check "$now" "$times"
  [ "$status" -eq 0 ]
  [[ "$output" != *"9700"* ]]
  [[ "$output" == *"9800"* ]]
}

@test "crash_budget_check tolerates empty input" {
  local now=10000
  run crash_budget_check "$now" ""
  [ "$status" -eq 0 ]
  [ -z "$(echo "$output" | tr -d ' ')" ]
}

@test "channel_plugin_alive returns 0 when no marker file exists" {
  rm -f "$CHANNEL_MARKER"
  run channel_plugin_alive
  [ "$status" -eq 0 ]
}

@test "channel_plugin_alive returns 1 when marker present but bun absent" {
  mkdir -p "$WATCHDOG_RUNTIME_DIR"
  : > "$CHANNEL_MARKER"
  # Stub pgrep so a real bun server.ts on the developer's machine
  # (e.g. another agent's plugin) doesn't make this non-deterministic.
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/pgrep" <<'STUB'
#!/bin/bash
exit 1
STUB
  chmod +x "$TMP_TEST_DIR/bin/pgrep"
  PATH="$TMP_TEST_DIR/bin:$PATH" run channel_plugin_alive
  [ "$status" -ne 0 ]
}

@test "channel_plugin_alive returns 0 when marker present and bun running" {
  mkdir -p "$WATCHDOG_RUNTIME_DIR"
  : > "$CHANNEL_MARKER"
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/pgrep" <<'STUB'
#!/bin/bash
echo "12345"
exit 0
STUB
  chmod +x "$TMP_TEST_DIR/bin/pgrep"
  PATH="$TMP_TEST_DIR/bin:$PATH" run channel_plugin_alive
  [ "$status" -eq 0 ]
}

# Regression: in May 2026, _trigger_identity_backup ran heartbeatctl
# synchronously without GIT_TERMINAL_PROMPT=0. When the fork URL needed
# auth and .env had no PAT yet (fresh install pre-/login), git clone
# blocked on a stdin username prompt → the watchdog deadlocked → tmux
# never respawned → user couldn't /login. Fix: background + 90s
# timeout + pgrep guard.

@test "_trigger_identity_backup returns immediately when heartbeatctl is slow" {
  # Stub heartbeatctl that sleeps forever and pgrep that always says
  # "no prior backup running". _trigger_identity_backup must detach
  # via & and return within a fraction of a second.
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/heartbeatctl" <<'STUB'
#!/bin/bash
sleep 30
STUB
  chmod +x "$TMP_TEST_DIR/bin/heartbeatctl"
  cat > "$TMP_TEST_DIR/bin/pgrep" <<'STUB'
#!/bin/bash
exit 1
STUB
  chmod +x "$TMP_TEST_DIR/bin/pgrep"

  local start end
  start=$(date +%s)
  PATH="$TMP_TEST_DIR/bin:$PATH" _trigger_identity_backup "test-reason"
  end=$(date +%s)
  # Must complete in under 3s; the actual backup is detached.
  [ $((end - start)) -lt 3 ]
}

@test "_trigger_identity_backup is reentrancy-guarded by pgrep" {
  # When pgrep says "a previous heartbeatctl backup-identity is still
  # running", the trigger must short-circuit (no new spawn).
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/heartbeatctl" <<'STUB'
#!/bin/bash
echo "should not be called" > "$BATS_TEST_TMPDIR/called"
STUB
  chmod +x "$TMP_TEST_DIR/bin/heartbeatctl"
  cat > "$TMP_TEST_DIR/bin/pgrep" <<'STUB'
#!/bin/bash
echo "999"
exit 0
STUB
  chmod +x "$TMP_TEST_DIR/bin/pgrep"

  PATH="$TMP_TEST_DIR/bin:$PATH" _trigger_identity_backup "test-reentry"
  # Give the would-be-detached subshell time to (not) run.
  sleep 1
  [ ! -f "$BATS_TEST_TMPDIR/called" ]
}

# ── Story G: fork-less agents must not run the identity-backup check ──

@test "_identity_backup_fork_configured is false for a fork-less agent.yml" {
  cat > "$TMP_TEST_DIR/agent.yml" <<'YML'
scaffold:
  fork:
    url: ""
YML
  export IDENTITY_BACKUP_AGENT_YML_OVERRIDE="$TMP_TEST_DIR/agent.yml"
  run _identity_backup_fork_configured
  [ "$status" -eq 1 ]
}

@test "_identity_backup_fork_configured is true when agent.yml carries a fork url" {
  cat > "$TMP_TEST_DIR/agent.yml" <<'YML'
scaffold:
  fork:
    url: "https://github.com/me/my-agent.git"
YML
  export IDENTITY_BACKUP_AGENT_YML_OVERRIDE="$TMP_TEST_DIR/agent.yml"
  run _identity_backup_fork_configured
  [ "$status" -eq 0 ]
}

@test "_check_identity_backup skips the trigger and stays silent for a fork-less agent" {
  cat > "$TMP_TEST_DIR/agent.yml" <<'YML'
scaffold:
  fork:
    url: ""
YML
  export IDENTITY_BACKUP_AGENT_YML_OVERRIDE="$TMP_TEST_DIR/agent.yml"
  # Stub the trigger (bash function in the same file → redefine it).
  _trigger_identity_backup() { echo called >> "$BATS_TEST_TMPDIR/trigger_called"; }
  _last_backup_check=0
  run _check_identity_backup
  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/trigger_called" ]
  [[ "$output" != *"identity backup"* ]]
}

# ── 006-headless-bootstrap US1: token-aware boot decision ──
# CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`) authenticates claude via
# the environment, so the supervisor must NOT fall back to the bare-claude
# /login path when a token is present.

@test "has_oauth_token is true with CLAUDE_CODE_OAUTH_TOKEN set, false when unset/empty" {
  export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-deadbeef"
  run has_oauth_token
  [ "$status" -eq 0 ]
  export CLAUDE_CODE_OAUTH_TOKEN=""
  run has_oauth_token
  [ "$status" -ne 0 ]
  unset CLAUDE_CODE_OAUTH_TOKEN
  run has_oauth_token
  [ "$status" -ne 0 ]
}

@test "next_tmux_cmd: with OAuth token and channel NOT ready, does NOT emit bare-claude /login" {
  # Stub boot deps so only the Case-A guard is exercised.
  pre_accept_extra_marketplaces() { :; }
  ensure_official_marketplace() { :; }
  ensure_all_plugins_installed() { :; }
  _channel_plugin_ready() { return 1; }   # plugin not installed yet
  has_telegram_token() { return 1; }       # would route to Case B (wizard) past Case A
  log() { :; }
  export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-deadbeef"
  run next_tmux_cmd
  [ "$status" -eq 0 ]
  # Must NOT be the bare-claude /login fallback (Case A).
  [ "$output" != "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR_VAL claude" ]
  # Routed past Case A → Case B wizard (no telegram token present).
  [[ "$output" == *"wizard-container.sh"* ]]
}

@test "next_tmux_cmd: WITHOUT OAuth token and channel NOT ready, keeps bare-claude (Case A regression guard)" {
  pre_accept_extra_marketplaces() { :; }
  ensure_official_marketplace() { :; }
  ensure_all_plugins_installed() { :; }
  _channel_plugin_ready() { return 1; }
  has_telegram_token() { return 1; }
  log() { :; }
  unset CLAUDE_CODE_OAUTH_TOKEN
  run next_tmux_cmd
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR_VAL claude" ]
}

# ── 006-headless-bootstrap US2: official marketplace registration ──
# Under headless token auth there is no interactive onboarding to seed the
# official marketplace, so the supervisor must register it idempotently before
# installing @claude-plugins-official plugins.

_stub_claude_marketplace() {
  # $1 = what `marketplace list` prints (e.g. the official name or "none")
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/claude" <<STUB
#!/bin/bash
case "\$*" in
  *"marketplace list"*) printf '%s\n' "$1" ;;
  *"marketplace add"*)  echo "\$*" >> "$TMP_TEST_DIR/mkt-add.log"; ${2:-exit 0} ;;
esac
exit 0
STUB
  chmod +x "$TMP_TEST_DIR/bin/claude"
}

@test "ensure_official_marketplace registers the official marketplace when absent" {
  _stub_claude_marketplace "No marketplaces configured"
  PATH="$TMP_TEST_DIR/bin:$PATH" ensure_official_marketplace
  grep -q "marketplace add anthropics/claude-plugins-official --scope user" \
    "$TMP_TEST_DIR/mkt-add.log"
}

@test "ensure_official_marketplace is a no-op when already registered (idempotent)" {
  _stub_claude_marketplace "  claude-plugins-official"
  PATH="$TMP_TEST_DIR/bin:$PATH" ensure_official_marketplace
  [ ! -f "$TMP_TEST_DIR/mkt-add.log" ]
}

@test "ensure_official_marketplace is fail-silent when the add fails (clone error)" {
  _stub_claude_marketplace "" "echo 'clone failed' >&2; exit 1"
  PATH="$TMP_TEST_DIR/bin:$PATH" run ensure_official_marketplace
  [ "$status" -eq 0 ]
}

# ── 006-headless-bootstrap US3: onboarding pre-seed (headless TUI not blocked) ──
# Onboarding state (theme + per-project trust) lives in ~/.claude/.claude.json
# (NOT settings.json). Pre-seeding it stops the first-run theme picker / trust
# dialog from blocking the headless tmux session.

@test "pre_seed_onboarding creates .claude.json with onboarding keys when absent" {
  export CLAUDE_CONFIG_DIR_VAL="$TMP_TEST_DIR/.claude"
  export WORKDIR="/workspace"
  pre_seed_onboarding
  [ "$(jq -r '.hasCompletedOnboarding' "$CLAUDE_CONFIG_DIR_VAL/.claude.json")" = "true" ]
  [ "$(jq -r '.theme' "$CLAUDE_CONFIG_DIR_VAL/.claude.json")" = "dark" ]
  [ "$(jq -r '.projects["/workspace"].hasTrustDialogAccepted' "$CLAUDE_CONFIG_DIR_VAL/.claude.json")" = "true" ]
}

@test "pre_seed_onboarding is idempotent and preserves existing theme + keys" {
  export CLAUDE_CONFIG_DIR_VAL="$TMP_TEST_DIR/.claude"
  export WORKDIR="/workspace"
  mkdir -p "$CLAUDE_CONFIG_DIR_VAL"
  echo '{"theme":"light","userID":"abc"}' > "$CLAUDE_CONFIG_DIR_VAL/.claude.json"
  pre_seed_onboarding
  pre_seed_onboarding   # second run = no-op
  [ "$(jq -r '.userID' "$CLAUDE_CONFIG_DIR_VAL/.claude.json")" = "abc" ]
  [ "$(jq -r '.theme' "$CLAUDE_CONFIG_DIR_VAL/.claude.json")" = "light" ]
  [ "$(jq -r '.hasCompletedOnboarding' "$CLAUDE_CONFIG_DIR_VAL/.claude.json")" = "true" ]
}

@test "pre_accept_bypass_permissions creates settings.json with headless defaults when absent" {
  rm -f "$HOME/.claude/settings.json"
  pre_accept_bypass_permissions
  [ "$(jq -r '.skipDangerousModePermissionPrompt' "$HOME/.claude/settings.json")" = "true" ]
  [ "$(jq -r '.permissions.defaultMode' "$HOME/.claude/settings.json")" = "auto" ]
}
