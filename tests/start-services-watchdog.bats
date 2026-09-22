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

# ── 026-channel-watchdog-timeout: configurable channel verify timeout ──
# verify_channel_healthy's wait was hardcoded to 20s (start_services.sh:722),
# flapping the boot when bun server.ts takes longer under MCP contention.
# CHANNEL_HEALTH_TIMEOUT (from the workspace .env) makes it configurable;
# channel_health_timeout() resolves it with a 60s default + safe degradation.

@test "channel_health_timeout defaults to 60 when unset/empty/non-numeric/<=0" {
  unset CHANNEL_HEALTH_TIMEOUT
  run channel_health_timeout
  [ "$output" -eq 60 ]
  CHANNEL_HEALTH_TIMEOUT="" run channel_health_timeout
  [ "$output" -eq 60 ]
  CHANNEL_HEALTH_TIMEOUT="abc" run channel_health_timeout
  [ "$output" -eq 60 ]
  CHANNEL_HEALTH_TIMEOUT="1.5" run channel_health_timeout
  [ "$output" -eq 60 ]
  CHANNEL_HEALTH_TIMEOUT="-5" run channel_health_timeout
  [ "$output" -eq 60 ]
  CHANNEL_HEALTH_TIMEOUT="0" run channel_health_timeout
  [ "$output" -eq 60 ]
}

@test "channel_health_timeout echoes a valid positive integer verbatim" {
  CHANNEL_HEALTH_TIMEOUT="20" run channel_health_timeout
  [ "$output" -eq 20 ]
  CHANNEL_HEALTH_TIMEOUT="45" run channel_health_timeout
  [ "$output" -eq 45 ]
  CHANNEL_HEALTH_TIMEOUT="90" run channel_health_timeout
  [ "$output" -eq 90 ]
}

# Seam: a fake pgrep that "finds bun server.ts" only on its K-th call, plus a
# no-op sleep, both shadowing the real commands via PATH (same pattern as the
# channel_plugin_alive tests above). Drives verify_channel_healthy's loop to a
# chosen elapsed without burning wall-clock. pgrep runs at elapsed=2*(n-1), so
# K=12 lands at elapsed=22 — past the old 20s cap, inside the new 60s default.
_stub_pgrep_after() {
  local k="$1"
  mkdir -p "$TMP_TEST_DIR/bin"
  : > "$TMP_TEST_DIR/pgrep.count"
  cat > "$TMP_TEST_DIR/bin/pgrep" <<STUB
#!/bin/bash
c=\$(cat "$TMP_TEST_DIR/pgrep.count" 2>/dev/null || echo 0)
c=\$((c + 1))
echo "\$c" > "$TMP_TEST_DIR/pgrep.count"
[ "\$c" -ge $k ] && exit 0
exit 1
STUB
  printf '#!/bin/bash\nexit 0\n' > "$TMP_TEST_DIR/bin/sleep"
  chmod +x "$TMP_TEST_DIR/bin/pgrep" "$TMP_TEST_DIR/bin/sleep"
}

@test "verify_channel_healthy: channel at elapsed=22s passes with 60s default, fails when capped at 20" {
  _stub_pgrep_after 12
  unset CHANNEL_HEALTH_TIMEOUT
  PATH="$TMP_TEST_DIR/bin:$PATH" run verify_channel_healthy
  [ "$status" -eq 0 ]
  : > "$TMP_TEST_DIR/pgrep.count"
  CHANNEL_HEALTH_TIMEOUT=20 PATH="$TMP_TEST_DIR/bin:$PATH" run verify_channel_healthy
  [ "$status" -ne 0 ]
}

@test "verify_channel_healthy: returns 1 without sleeping the full timeout when bun never appears" {
  _stub_pgrep_after 9999
  local start end
  start=$(date +%s)
  CHANNEL_HEALTH_TIMEOUT=60 PATH="$TMP_TEST_DIR/bin:$PATH" run verify_channel_healthy
  end=$(date +%s)
  [ "$status" -ne 0 ]
  [ $((end - start)) -lt 3 ]
}

# Characterization of the crash-budget interaction (research (h)): a sustained
# channel-failure cycle costs ~T+5s. The 5th crash must land within WINDOW=300
# for the budget to fire and escalate to a container restart. This holds at the
# 60s default but breaks for overrides >=70s — which is why the WARN below
# exists. Uses the existing crash_budget_check with synthetic timestamps.
@test "crash budget: 5 failures fit the window at the 60s default (fires) but not at 90s (backstop lost)" {
  # T=60 → cadence 65 → 5 crashes at 0..260, all within 300 of now=260 → fires.
  run crash_budget_check 260 "0 65 130 195 260"
  [ "$status" -ne 0 ]
  # T=90 → cadence 95 → 5th crash at 380; oldest (0) is >300s back → only 4 in
  # window → budget does NOT fire (indefinite flap instead of a clean restart).
  run crash_budget_check 380 "0 95 190 285 380"
  [ "$status" -eq 0 ]
}

@test "warn_if_channel_timeout_risky: silent for the 60s default, warns for an override past the threshold" {
  unset CHANNEL_HEALTH_TIMEOUT
  run warn_if_channel_timeout_risky
  [ -z "$output" ]
  export CHANNEL_HEALTH_TIMEOUT=90
  run warn_if_channel_timeout_risky
  [ -n "$output" ]
  [[ "$output" == *"crash"* ]]
}

# US2 acceptance: a freshly-deployed agent with no CHANNEL_HEALTH_TIMEOUT set
# must NOT flap — the default is 60, not the old 20, so the ~22s contention
# peak is tolerated; an invalid override degrades to the same 60.
@test "US2: default (unset) tolerates the 22s contention peak; invalid override degrades to 60" {
  _stub_pgrep_after 12
  unset CHANNEL_HEALTH_TIMEOUT
  PATH="$TMP_TEST_DIR/bin:$PATH" run verify_channel_healthy
  [ "$status" -eq 0 ]
  : > "$TMP_TEST_DIR/pgrep.count"
  CHANNEL_HEALTH_TIMEOUT=notanum PATH="$TMP_TEST_DIR/bin:$PATH" run verify_channel_healthy
  [ "$status" -eq 0 ]
}

# ══ 036 US3: the initial boot retries instead of killing the container ═══════
#
# A first boot that loses the channel-health race today exits the container, and
# `unless-stopped` turns that into a restart loop — the shape of the 25-minute
# outage this feature exists to end. The retry lives in a NAMED function,
# start_initial_session, precisely so it can be driven from here; a loop inlined
# in main() would have no host oracle at all.

_us3_setup() {
  export WATCHDOG_RUNTIME_DIR="$TMP_TEST_DIR/rt"
  BOOT_MARKER="$WATCHDOG_RUNTIME_DIR/boot-attempt"
  LOG_FILE="$TMP_TEST_DIR/boot.log"
  : > "$LOG_FILE"
  log() { printf '%s\n' "$*" >> "$LOG_FILE"; }
}

@test "036 US3: a session healthy on the second attempt does not exit" {
  _us3_setup
  local n="$TMP_TEST_DIR/n"; echo 0 > "$n"
  start_session() {
    local c; c=$(cat "$n"); c=$((c + 1)); echo "$c" > "$n"
    [ "$c" -ge 2 ]
  }
  run start_initial_session
  [ "$status" -eq 0 ]
  [ "$(cat "$n")" = "2" ]
}

@test "036 US3: a session that never comes up exits non-zero after exactly 3 attempts" {
  _us3_setup
  local n="$TMP_TEST_DIR/n"; echo 0 > "$n"
  start_session() { local c; c=$(cat "$n"); echo $((c + 1)) > "$n"; return 1; }
  run start_initial_session
  [ "$status" -ne 0 ]
  [ "$(cat "$n")" = "3" ]
}

@test "036 US3: CANON-B1 is logged once per attempt" {
  _us3_setup
  start_session() { return 1; }
  run start_initial_session
  run bash -c "grep -cF 'initial session attempt 1/3' '$LOG_FILE'"
  [ "$output" = "1" ]
  run bash -c "grep -cF 'initial session attempt 2/3' '$LOG_FILE'"
  [ "$output" = "1" ]
  run bash -c "grep -cF 'initial session attempt 3/3' '$LOG_FILE'"
  [ "$output" = "1" ]
}

@test "036 US3: CANON-B2 keeps today's line as a substring so old log scraping still matches" {
  _us3_setup
  start_session() { return 1; }
  run start_initial_session
  run bash -c "grep -cF 'ERROR: initial tmux session failed to start after 3 attempts' '$LOG_FILE'"
  [ "$output" = "1" ]
  # The pre-036 wording is a prefix of the new one, deliberately.
  run bash -c "grep -cF 'ERROR: initial tmux session failed to start' '$LOG_FILE'"
  [ "$output" = "1" ]
}

@test "036 US3: there is no sleep between attempts" {
  _us3_setup
  # A delay would push a failing cycle toward the crash budget's window and
  # slow every healthy boot for nothing: the attempt itself already blocks for
  # as long as the channel-health wait takes.
  local slept="$TMP_TEST_DIR/slept"; : > "$slept"
  sleep() { echo "$*" >> "$slept"; }
  start_session() { return 1; }
  run start_initial_session
  [ ! -s "$slept" ]
}

@test "036 US3: the marker holds '<attempt> <epoch>' and is removed on success" {
  _us3_setup
  local n="$TMP_TEST_DIR/n"; echo 0 > "$n"
  local seen="$TMP_TEST_DIR/seen"
  start_session() {
    cat "$BOOT_MARKER" >> "$seen" 2>/dev/null || true
    local c; c=$(cat "$n"); c=$((c + 1)); echo "$c" > "$n"
    [ "$c" -ge 2 ]
  }
  run start_initial_session
  [ "$status" -eq 0 ]
  # Two attempts ran, so two marker generations were observed, numbered 1 then 2.
  run bash -c "grep -cE '^1 [0-9]+\$' '$seen'"
  [ "$output" = "1" ]
  run bash -c "grep -cE '^2 [0-9]+\$' '$seen'"
  [ "$output" = "1" ]
  # A stale marker must not outlive the boot.
  [ ! -f "$BOOT_MARKER" ]
}

@test "036 US3: the marker is removed on exhaustion too" {
  _us3_setup
  start_session() { return 1; }
  run start_initial_session
  [ "$status" -ne 0 ]
  [ ! -f "$BOOT_MARKER" ]
}

# ── (m1) the mkdir -p. Catches mutation M-B1 ─────────────────────────────────

@test "036 US3: the marker is written even though its directory does not exist yet" {
  # THE critical finding of the adversarial review. WATCHDOG_RUNTIME_DIR lives
  # under /tmp, a tmpfs emptied on every container start, and the only mkdir -p
  # in the file sits INSIDE start_session (:840) — i.e. after the first marker
  # write. Without a mkdir of its own, attempt 1 writes into a directory that
  # does not exist.
  _us3_setup
  [ ! -d "$WATCHDOG_RUNTIME_DIR" ]
  local seen="$TMP_TEST_DIR/seen"
  start_session() { cat "$BOOT_MARKER" >> "$seen" 2>/dev/null || true; return 0; }
  run start_initial_session
  [ "$status" -eq 0 ]
  run bash -c "grep -cE '^1 [0-9]+\$' '$seen'"
  [ "$output" = "1" ]
}

# ── (m2) the || true. Catches mutation M-B2 ──────────────────────────────────

@test "036 US3: an unwritable marker path does not abort the boot (errexit re-established)" {
  # This oracle CANNOT use `run start_initial_session`. Measured on this host
  # (bats 1.13.0): bats' `run` strips errexit — `$-` is `ehuBET` in the test
  # body but `huB` inside `run` — so a sourced function whose unguarded
  # redirect fails still runs to completion, and the guarded and mutant
  # versions produce byte-identical results. The subshell below puts errexit
  # back, which is the only condition under which the mutation is observable.
  #
  # The status is 1 either way (exhaustion), so the DISCRIMINATOR is the count
  # of attempt lines: guarded → 3, unguarded → 1, because the failed redirect
  # kills the shell on the first attempt.
  local rt="$TMP_TEST_DIR/blocked"
  # A regular file where the directory should be: mkdir -p fails, and so does
  # every write beneath it.
  printf 'not a directory\n' > "$rt"
  # Invoked BARE, with no `|| true` and no `if`. Measured: a function call that
  # is the left operand of `||` has errexit suspended for its entire dynamic
  # extent, so `start_initial_session || true` would make the unguarded write
  # survive and the mutation would go undetected — this oracle was written that
  # way first and did NOT catch M-B2. (It is the same bash rule that makes
  # start_services.sh:431 safe despite a genuine SIGPIPE, per the 2026-09-21
  # pipeline audit.) Bare, the guarded version still prints all three attempt
  # lines before returning 1; the mutant dies on the first failed redirect.
  run bash -c "set -euo pipefail
    START_SERVICES_NO_RUN=1 source '$REPO_ROOT/docker/scripts/start_services.sh'
    WATCHDOG_RUNTIME_DIR='$rt/rt'
    log() { printf '%s\n' \"\$*\"; }
    start_session() { return 1; }
    start_initial_session"
  local n
  n=$(printf '%s\n' "$output" | grep -cF 'initial session attempt') || true
  [ "$n" -eq 3 ]
}

# ── (m3) FR-013: the watchdog stays frozen ───────────────────────────────────

@test "036 US3: _run_watchdog is byte-identical to its pre-036 shape (FR-013)" {
  # No test in this repo exercises _run_watchdog — measured: `grep -rn
  # _run_watchdog tests/` returns nothing else. US3 edits this very file, so
  # this hash is the only thing standing between a well-meant refactor and a
  # silent re-run of the ebf5f regression, where automated stuck-channel
  # detection killed healthy sessions every ~2 minutes (commit ebfe35f).
  run bash -c "sed -n '/^_run_watchdog() {/,/^}/p' '$REPO_ROOT/docker/scripts/start_services.sh' | shasum -a 256 | cut -d' ' -f1"
  [ "$output" = "745a1a70f53eee28e9f87acbc406580b2e7a4ce44cb1fada19651beef94b32c4" ]
}
