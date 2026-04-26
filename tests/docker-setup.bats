#!/usr/bin/env bats

load helper

setup() { setup_tmp_dir; }
teardown() { teardown_tmp_dir; }

@test "setup.sh --help exits successfully" {
  run "$REPO_ROOT/setup.sh" --help
  [ "$status" -eq 0 ]
}

# Helper: run wizard piping answers through stdin.
# The host-name is auto-detected from hostname (no prompt).
# The install_service prompt fires only on Linux.
run_docker_wizard() {
  local dest="$1"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$REPO_ROOT/docker" "$TMP_TEST_DIR/installer/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/installer/"
  cd "$TMP_TEST_DIR/installer"

  local answers=(
    dockbot
    DockBot
    r
    v
    Alice
    Alice
    UTC
    a@b.com
    en
  )
  # install_service prompt fires only on Linux.
  [ "$(uname -s)" = "Linux" ] && answers+=(n)
  answers+=(
    n        # fork enabled
    none     # notifications channel
    y        # heartbeat enabled
    30m      # heartbeat interval
    ok       # heartbeat prompt
    y        # use default principles
    n        # atlassian
    n        # github mcp
    proceed
  )

  printf '%s\n' "${answers[@]}" | ./setup.sh --destination "$dest"
}

@test "--docker wizard does not prompt for Telegram secrets" {
  mkdir -p "$TMP_TEST_DIR/installer"
  local dest="$TMP_TEST_DIR/docker-agent"
  run run_docker_wizard "$dest"
  [ "$status" -eq 0 ]
  # .env must NOT contain secrets — those are deferred to container wizard.
  [ -f "$dest/.env" ]
  ! grep -q "^TELEGRAM_BOT_TOKEN=" "$dest/.env"
  ! grep -q "^NOTIFY_BOT_TOKEN=.\+" "$dest/.env"
}

@test "wizard writes docker.* section in agent.yml" {
  mkdir -p "$TMP_TEST_DIR/installer"
  local dest="$TMP_TEST_DIR/docker-agent-yml"
  run run_docker_wizard "$dest"
  [ "$status" -eq 0 ]
  [ -f "$dest/agent.yml" ]
  [ "$(yq '.docker.uid' "$dest/agent.yml")" = "$(id -u)" ]
  [ "$(yq '.docker.gid' "$dest/agent.yml")" = "$(id -g)" ]
}

@test "--docker scaffold copies docker/ directory into destination" {
  mkdir -p "$TMP_TEST_DIR/installer"
  local dest="$TMP_TEST_DIR/docker-scaffold"
  run run_docker_wizard "$dest"
  [ "$status" -eq 0 ]
  [ -d "$dest/docker" ]
  [ -f "$dest/docker/Dockerfile" ]
  [ -f "$dest/docker/entrypoint.sh" ]
  [ -x "$dest/docker/entrypoint.sh" ]
  [ -f "$dest/docker/scripts/start_services.sh" ]
}

@test "--docker scaffold writes docker-compose.yml at workspace root" {
  mkdir -p "$TMP_TEST_DIR/installer"
  local dest="$TMP_TEST_DIR/docker-compose-out"
  run run_docker_wizard "$dest"
  [ "$status" -eq 0 ]
  [ -f "$dest/docker-compose.yml" ]
  grep -q "dockbot:" "$dest/docker-compose.yml"
  grep -q "./.state:/home/agent" "$dest/docker-compose.yml"
}

@test "--docker scaffold does NOT render agent-script-*.sh on host" {
  mkdir -p "$TMP_TEST_DIR/installer"
  local dest="$TMP_TEST_DIR/docker-no-host-launcher"
  run run_docker_wizard "$dest"
  [ "$status" -eq 0 ]
  # No user-level systemd unit in docker mode.
  [ ! -f "$HOME/.config/systemd/user/dockbot.service" ]
  [ ! -f "$HOME/Library/LaunchAgents/local.dockbot.plist" ]
  [ ! -f "$HOME/.local/bin/dockbot.sh" ]
}

@test "--uninstall in docker-mode workspace runs docker compose down (preserving .state)" {
  mkdir -p "$TMP_TEST_DIR/installer"
  local dest="$TMP_TEST_DIR/docker-uninstall"
  run run_docker_wizard "$dest"
  [ "$status" -eq 0 ]

  # Stub docker so the test does not need a daemon. Record invocations.
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/docker" <<'STUB'
#!/bin/bash
echo "$@" >> "$TMP_TEST_DIR/docker-calls.log"
exit 0
STUB
  chmod +x "$TMP_TEST_DIR/bin/docker"
  export PATH="$TMP_TEST_DIR/bin:$PATH"

  cd "$dest"
  run ./setup.sh --uninstall --yes
  [ "$status" -eq 0 ]
  # State now lives in workspace .state/ (bind-mount, not a named volume),
  # so plain `compose down` is sufficient — `-v` would be a no-op.
  grep -q "compose down" "$TMP_TEST_DIR/docker-calls.log"
  ! grep -q "compose down -v" "$TMP_TEST_DIR/docker-calls.log"
}

@test "--regenerate in docker-mode workspace re-renders docker-compose.yml" {
  mkdir -p "$TMP_TEST_DIR/installer"
  local dest="$TMP_TEST_DIR/docker-regen"
  run run_docker_wizard "$dest"
  [ "$status" -eq 0 ]
  rm "$dest/docker-compose.yml"
  [ ! -f "$dest/docker-compose.yml" ]

  cd "$dest"
  run ./setup.sh --regenerate
  [ "$status" -eq 0 ]
  [ -f "$dest/docker-compose.yml" ]
  grep -q "dockbot:" "$dest/docker-compose.yml"
}
