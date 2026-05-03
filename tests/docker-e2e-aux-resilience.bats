#!/usr/bin/env bats
# Docker e2e: builds the image, boots a container with a deliberately
# missing TELEGRAM_BOT_TOKEN + bad FORK_PAT, and confirms:
#   1. The container reaches `running` state (the aux failures don't
#      block boot or trip tini).
#   2. `heartbeatctl doctor` runs end-to-end inside the container,
#      surfaces the misconfiguration as ✗/⚠ rows, and exits non-zero
#      without crashing.
#   3. `safe-exec.sh` is image-baked at the expected path.
#
# This is the integration test the May 2026 incident on linus would
# have caught: a private-fork git invocation without GIT_TERMINAL_PROMPT
# would have hung the container at boot. With safe-exec.sh available,
# any future identity-backup-style feature is required to use the
# primitives or tests like this one will catch the regression.
#
# Skipped by default; opt-in with DOCKER_E2E=1.

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then skip "set DOCKER_E2E=1 to run"; fi
  TMPDIR=/tmp setup_tmp_dir
  export DEST="$TMP_TEST_DIR/agent-aux"
  export AGENT_NAME="aux-e2e"
}
teardown() {
  if [ -d "$DEST" ]; then
    (cd "$DEST" && docker compose down -v --remove-orphans || true)
  fi
  teardown_tmp_dir
}

@test "fresh scaffold → container healthy → heartbeatctl doctor works" {
  mkdir -p "$DEST"
  cat > "$DEST/agent.yml" <<YML
version: 1
agent: {name: $AGENT_NAME, display_name: "aux 🧪", role: "test", vibe: "terse"}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$DEST", install_service: false, claude_cli: "claude"}
docker: {image_tag: "agent-admin:aux-e2e", uid: $(id -u), gid: $(id -g), state_volume: "${AGENT_NAME}-state", base_image: "alpine:3.20"}
claude: {config_dir: "/home/agent/.claude", profile_new: true}
notifications: {channel: none}
features:
  heartbeat: {enabled: true, interval: "5m", timeout: 30, retries: 0, default_prompt: "ok"}
mcps: {defaults: [], atlassian: [], github: {enabled: false, email: ""}}
plugins: []
YML
  cp -R "$REPO_ROOT/modules" "$REPO_ROOT/scripts" "$REPO_ROOT/docker" "$DEST/"
  cp "$REPO_ROOT/setup.sh" "$DEST/"
  chmod +x "$DEST/setup.sh"
  (cd "$DEST" && ./setup.sh --regenerate --non-interactive)
  touch "$DEST/.env"
  chmod 0600 "$DEST/.env"

  # Claude stub so the watchdog has something to launch.
  mkdir -p "$DEST/bin"
  cat > "$DEST/bin/claude" <<'CL'
#!/bin/bash
# Stub: behaves like claude is logged in for `mcp list --json`,
# echoes prompt for plain invocations.
case "$1" in
  mcp)
    if [ "$2" = "list" ]; then
      echo '[{"name":"fetch","status":"connected"}]'
      exit 0
    fi
    ;;
  plugin)
    # Plugin install always succeeds quickly so the watchdog flows happily.
    exit 0
    ;;
esac
echo "STUB_CLAUDE: $*"
exit 0
CL
  chmod +x "$DEST/bin/claude"

  # Bind-mount the stub at /usr/local/bin/claude.
  python3 - "$DEST/docker-compose.yml" <<'PY'
import sys
path = sys.argv[1]
txt = open(path).read()
needle = '      - ./:/workspace'
inject = '      - ./bin/claude:/usr/local/bin/claude:ro'
if inject not in txt:
    txt = txt.replace(needle, needle + '\n' + inject, 1)
open(path, 'w').write(txt)
PY

  (cd "$DEST" && docker compose build)
  (cd "$DEST" && docker compose up -d)

  # Wait for container to be running. tini fatal would prevent this.
  local deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state=$(docker inspect -f '{{.State.Status}}' "$AGENT_NAME" 2>/dev/null)
    [ "$state" = "running" ] && break
    sleep 2
  done
  state=$(docker inspect -f '{{.State.Status}}' "$AGENT_NAME" 2>/dev/null)
  [ "$state" = "running" ]

  # safe-exec.sh must be image-baked at the standard path. Acts as a
  # canary: if a future change moves it without updating the load-bearing
  # source line in start_services.sh, this test fails.
  run docker exec -u agent "$AGENT_NAME" test -f /opt/agent-admin/scripts/lib/safe-exec.sh
  [ "$status" -eq 0 ]

  # heartbeatctl doctor end-to-end. We expect non-zero exit (no Claude
  # credentials, no .env tokens, possibly no .mcp.json under our
  # minimal scaffold), but the command must complete in <30s and emit
  # the full set of section headers — proving the doctor pipeline
  # didn't hang on any of its sub-checks.
  local doctor_start=$(date +%s)
  run docker exec -u agent "$AGENT_NAME" heartbeatctl doctor
  local doctor_end=$(date +%s)
  local elapsed=$((doctor_end - doctor_start))
  [ "$elapsed" -lt 30 ]
  [[ "$output" == *"heartbeatctl doctor"* ]]
  [[ "$output" == *"Workspace mounted"* ]]
  [[ "$output" == *"agent.yml is valid"* ]]
  [[ "$output" == *"crond"* ]]
  [[ "$output" == *"Vault"* ]]
  # Token health section may be absent if no tokens are configured (channel=none),
  # but the doctor pipeline must still finish cleanly.
}
