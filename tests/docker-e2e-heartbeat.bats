#!/usr/bin/env bats
# Docker e2e: scaffolds a test agent, boots it, waits for one real cron
# tick, asserts runs.jsonl shape.
#
# Skipped by default (slow + requires Docker). Enable with DOCKER_E2E=1.

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then skip "set DOCKER_E2E=1 to run"; fi
  setup_tmp_dir
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

  # 3b) patch docker-compose.yml: override the entrypoint so the container
  # stays alive without needing a real claude binary. The default
  # start_services.sh crash-loops in <60s when claude is absent, which
  # prevents the 1m cron from ever firing. Instead we inject an
  # `entrypoint:` that: (a) chowns volumes as root, (b) writes the
  # correct crontab as root (heartbeatctl reload must run as root to
  # write /etc/crontabs/agent — the agent user is denied by cap_drop),
  # (c) starts crond as root, (d) sleeps forever to keep the container
  # alive through the first 60-second cron tick.
  python3 - "$DEST/docker-compose.yml" <<'PY'
import sys, re
path = sys.argv[1]
txt = open(path).read()
# Inject an `entrypoint:` override before the `volumes:` block.
# Running heartbeatctl as root so it can write /etc/crontabs/agent
# (the agent user is blocked by cap_drop: ALL + no-new-privileges).
override = (
    '    entrypoint:\n'
    '      - /bin/sh\n'
    '      - -c\n'
    '      - |\n'
    '          chown -R agent:agent /home/agent 2>/dev/null || true\n'
    '          [ -d /workspace/scripts/heartbeat ] && chown -R agent:agent /workspace/scripts/heartbeat 2>/dev/null || true\n'
    '          heartbeatctl reload 2>&1 || true\n'
    '          crond -b -L /workspace/scripts/heartbeat/logs/cron.log\n'
    '          while true; do sleep 30; done\n'
)
txt = re.sub(r'(\n    volumes:)', r'\n' + override + r'\1', txt, count=1)
open(path, 'w').write(txt)
PY

  # 4) build + up
  (cd "$DEST" && docker compose build)
  (cd "$DEST" && docker compose up -d)

  # 5) wait up to 90s for first tick
  local deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$DEST/scripts/heartbeat/logs/runs.jsonl" ]; then break; fi
    sleep 5
  done
  [ -f "$DEST/scripts/heartbeat/logs/runs.jsonl" ]

  # 6) assert the line is valid JSON with the expected shape
  run jq -e '.trigger == "cron"' "$DEST/scripts/heartbeat/logs/runs.jsonl"
  [ "$status" -eq 0 ]
  # claude is not installed in the minimal test image, so status may be
  # "error" (claude_exit_code=-2) — that's acceptable. The critical check
  # is that the cron chain fired and produced a line at all.
  run jq -r '.status' "$DEST/scripts/heartbeat/logs/runs.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok" || "$output" == "error" ]]
}
