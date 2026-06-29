#!/usr/bin/env bats
# 011-local-standalone-mode (US3): agentctl degrades honestly in local mode.
# Docker-only subcommands must fail with a systemctl hint and NEVER invoke
# docker; status/doctor must read systemd (stubbed) instead of the container.

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$TMP_TEST_DIR/"
  cat > "$TMP_TEST_DIR/agent.yml" << 'YML'
version: 1
agent:
  name: locbot
user: {timezone: UTC, email: a@b.com}
deployment:
  workspace: "."
  mode: local
docker: {uid: 1000, gid: 1000, image_tag: "x:latest", base_image: "alpine:3.20"}
notifications: {channel: none}
features: {heartbeat: {enabled: true, interval: "30m", timeout: 300, retries: 1, default_prompt: "ok"}}
YML
  # Stub bin: docker writes a marker if ever called (it must NOT be in local mode).
  mkdir -p "$TMP_TEST_DIR/bin"
  export DOCKER_MARKER="$TMP_TEST_DIR/docker-was-called"
  cat > "$TMP_TEST_DIR/bin/docker" << 'SH'
#!/usr/bin/env bash
echo "called: $*" >> "$DOCKER_MARKER"
exit 0
SH
  cat > "$TMP_TEST_DIR/bin/systemctl" << 'SH'
#!/usr/bin/env bash
# is-active --quiet → active (exit 0)
case "$*" in
  *is-active*) exit 0 ;;
  *) exit 0 ;;
esac
SH
  cat > "$TMP_TEST_DIR/bin/journalctl" << 'SH'
#!/usr/bin/env bash
echo "session url: https://claude.ai/code/abc connected"
exit 0
SH
  cat > "$TMP_TEST_DIR/bin/claude" << 'SH'
#!/usr/bin/env bash
case "$*" in
  *--version*) echo "2.1.99 (Claude Code)" ;;
esac
exit 0
SH
  chmod +x "$TMP_TEST_DIR/bin/"*
  export PATH="$TMP_TEST_DIR/bin:$PATH"
  # A present login so status/doctor see it.
  mkdir -p "$TMP_TEST_DIR/.state/.claude"
  printf '{"expiresAt":99999999999999}\n' > "$TMP_TEST_DIR/.state/.claude/.credentials.json"
  chmod 600 "$TMP_TEST_DIR/.state/.claude/.credentials.json"
}

teardown() { teardown_tmp_dir; }

@test "local mode: 'up' errors with a systemctl hint and never calls docker" {
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl up
  [ "$status" -ne 0 ]
  [[ "$output" == *"systemctl"* ]]
  [[ "$output" == *"local"* ]]
  [ ! -f "$DOCKER_MARKER" ]
}

@test "local mode: 'attach' and 'logs' also degrade without docker" {
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl attach
  [ "$status" -ne 0 ]
  [[ "$output" == *"journalctl"* || "$output" == *"systemctl"* ]]
  run ./scripts/agentctl logs -f
  [ "$status" -ne 0 ]
  [ ! -f "$DOCKER_MARKER" ]
}

@test "local mode: 'status' reads systemd (stub), not docker" {
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl status
  [ "$status" -eq 0 ]
  [[ "$output" == *"active"* ]]
  [ ! -f "$DOCKER_MARKER" ]
}

@test "local mode: 'doctor' uses systemctl + login checks, not docker" {
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [[ "$output" == *"local mode"* ]]
  [[ "$output" == *"active"* ]]
  [ ! -f "$DOCKER_MARKER" ]
}
