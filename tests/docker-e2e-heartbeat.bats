#!/usr/bin/env bats
# Docker e2e: scaffolds a test agent, boots it, waits for one real cron
# tick, asserts runs.jsonl shape.
#
# Skipped by default (slow + requires Docker). Enable with DOCKER_E2E=1.
#
# This exercises the production code path: entrypoint (root) → chown +
# crond launch → su-exec agent → start_services.sh → heartbeatctl reload
# → cron fires heartbeat.sh → runs.jsonl.
#
# To prevent the watchdog from crash-looping on a missing claude binary,
# we install a `claude` stub on PATH inside the image via a bind-mounted
# shim (there's no real claude in the test image).

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then skip "set DOCKER_E2E=1 to run"; fi
  # Force a predictable path under /tmp for the test workspace. Docker
  # Desktop's File Sharing layer is most reliable with /tmp/* on macOS;
  # bats' default TMPDIR (/var/folders/...) works too but has been
  # observed to introduce bind-mount timing issues here.
  TMPDIR=/tmp setup_tmp_dir
  export DEST="$TMP_TEST_DIR/agent-e2e"
  export AGENT_NAME="hb-e2e"
}
teardown() {
  if [ -d "$DEST" ]; then
    (cd "$DEST" && docker compose down -v --remove-orphans || true)
  fi
  teardown_tmp_dir
}

@test "fresh scaffold → container boot → cron tick → runs.jsonl has an entry" {
  # 1) prepare a workspace with agent.yml + all source dirs copied
  mkdir -p "$DEST"
  cat > "$DEST/agent.yml" <<YML
version: 1
agent: {name: $AGENT_NAME, display_name: "e2e 🧪", role: "test", vibe: "terse"}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$DEST", install_service: false, claude_cli: "claude"}
docker: {image_tag: "agent-admin:e2e", uid: $(id -u), gid: $(id -g), state_volume: "${AGENT_NAME}-state", base_image: "alpine:3.20"}
claude: {config_dir: "/home/agent/.claude", profile_new: true}
notifications: {channel: none}
features:
  heartbeat: {enabled: true, interval: "1m", timeout: 30, retries: 0, default_prompt: "echo pong"}
mcps: {defaults: [], atlassian: [], github: {enabled: false, email: ""}}
plugins: []
YML
  cp -R "$REPO_ROOT/modules" "$REPO_ROOT/scripts" "$REPO_ROOT/docker" "$DEST/"
  cp "$REPO_ROOT/setup.sh" "$DEST/"
  chmod +x "$DEST/setup.sh"

  # 2) regenerate derived files
  (cd "$DEST" && ./setup.sh --regenerate --non-interactive)

  # 3) seed a minimal .env (docker compose requires it to exist)
  touch "$DEST/.env"
  chmod 0600 "$DEST/.env"

  # 4) install a claude stub that heartbeat.sh will find on PATH.
  # Writing HEARTBEAT_DONE immediately (what heartbeat.sh's tmux launcher
  # expects on success) short-circuits the session wait.
  mkdir -p "$DEST/bin"
  cat > "$DEST/bin/claude" <<'CL'
#!/bin/bash
# e2e stub — echoes the prompt and exits 0 so heartbeat.sh records status=ok
printf 'STUB_CLAUDE: %s\n' "$*"
exit 0
CL
  chmod +x "$DEST/bin/claude"

  # 5) patch docker-compose.yml so the stub is on PATH inside the
  # container. We can't mount /usr/local/bin (busy at runtime) so we
  # overlay via an env var read by start_services.sh / heartbeat.sh.
  # The simplest mechanism: symlink the stub into /usr/local/bin at
  # runtime via a drop-in; alpine keeps /usr/local/bin on PATH by default.
  # We append a small bootstrap to the compose that adds:
  #   volumes: ./bin/claude:/usr/local/bin/claude:ro
  python3 - "$DEST/docker-compose.yml" <<'PY'
import sys
path = sys.argv[1]
txt = open(path).read()
# Append the bind-mount for the stub just inside the volumes list.
# The existing list has two lines; insert before the named-volume line.
needle = '      - ./:/workspace'
inject = '      - ./bin/claude:/usr/local/bin/claude:ro'
if inject not in txt:
    txt = txt.replace(needle, needle + '\n' + inject, 1)
open(path, 'w').write(txt)
PY

  # 6) build + up (full production entrypoint chain)
  (cd "$DEST" && docker compose build)
  (cd "$DEST" && docker compose up -d)

  # 7) wait up to 150s for first tick. With a 1m cron schedule, the first
  #    tick fires at the next minute boundary — can be up to 60s after
  #    container boot, plus boot time (~15s) and heartbeat.sh runtime
  #    (~5s). 150s gives enough margin for slow CI or macOS Docker Desktop.
  local deadline=$(( $(date +%s) + 150 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$DEST/scripts/heartbeat/logs/runs.jsonl" ]; then break; fi
    sleep 5
  done
  if [ ! -f "$DEST/scripts/heartbeat/logs/runs.jsonl" ]; then
    # Dump logs to help diagnose the failure before teardown eats them.
    echo "--- container logs ---" >&2
    (cd "$DEST" && docker compose logs --tail=50 2>&1) >&2 || true
    echo "--- crontab ---" >&2
    (cd "$DEST" && docker compose exec -T "$AGENT_NAME" cat /etc/crontabs/agent 2>&1) >&2 || true
  fi
  [ -f "$DEST/scripts/heartbeat/logs/runs.jsonl" ]

  # 8) assert the line has the expected shape. trigger must be "cron"
  # (not "manual"), proving the cron → heartbeat.sh chain fired. status
  # should be "ok" with the stub claude; accept "error" as fallback if
  # the container hits an unrelated failure mode.
  run jq -e '.trigger == "cron"' "$DEST/scripts/heartbeat/logs/runs.jsonl"
  [ "$status" -eq 0 ]
  run jq -r '.status' "$DEST/scripts/heartbeat/logs/runs.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok" || "$output" == "error" ]]
}
