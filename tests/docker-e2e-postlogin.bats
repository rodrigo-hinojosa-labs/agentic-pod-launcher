#!/usr/bin/env bats
# Feature 004 US2 (DOCKER_E2E) — after the /login credential flip, the
# supervisor keeps retrying plugin install (bounded budget) until the profile
# is operative, with NO manual `plugin install`. We boot a container, let it
# settle unauthenticated (plugins must NOT install), then simulate the flip by
# dropping a mocked .credentials.json and assert the channel plugin reaches its
# .installed-ok sentinel within the budget.
#
# Skipped by default (slow + requires Docker). Enable with DOCKER_E2E=1.
# The supervisor's retry LOGIC is unit-covered host-side in
# tests/start-services-postlogin-retry.bats; this is the integration proof.

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then skip "set DOCKER_E2E=1 to run"; fi
  TMPDIR=/tmp setup_tmp_dir
  export DEST="$TMP_TEST_DIR/agent-postlogin-e2e"
  export AGENT_NAME="postlogin-e2e"
}

teardown() {
  if [ -d "$DEST" ]; then
    (cd "$DEST" && docker compose down -v --remove-orphans || true)
  fi
  teardown_tmp_dir
}

@test "post-login: channel plugin auto-installs after the credential flip, none before" {
  mkdir -p "$DEST"
  cat > "$DEST/agent.yml" <<YML
version: 1
agent: {name: $AGENT_NAME, display_name: "postlogin e2e 🔑", role: "test", vibe: "terse"}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$DEST", install_service: false, claude_cli: "claude"}
docker: {image_tag: "agent-admin:postlogin-e2e", uid: $(id -u), gid: $(id -g), state_volume: "${AGENT_NAME}-state", base_image: "alpine:3.24.1"}
claude: {config_dir: "/home/agent/.claude", profile_new: true}
notifications: {channel: none}
features:
  heartbeat: {enabled: true, interval: "30m", timeout: 30, retries: 0, default_prompt: "echo pong"}
mcps: {defaults: [], atlassian: [], github: {enabled: false, email: ""}}
vault: {enabled: false}
plugins: ["telegram@claude-plugins-official"]
YML
  cp -R "$REPO_ROOT/modules" "$REPO_ROOT/scripts" "$REPO_ROOT/docker" "$DEST/"
  cp "$REPO_ROOT/setup.sh" "$DEST/"
  chmod +x "$DEST/setup.sh"
  (cd "$DEST" && ./setup.sh --regenerate --non-interactive)
  touch "$DEST/.env"; chmod 0600 "$DEST/.env"

  # Shrink the budget so the test completes quickly.
  python3 - "$DEST/docker-compose.yml" <<'PY'
import sys
path = sys.argv[1]
txt = open(path).read()
needle = '      - ./:/workspace'
inject = '      - ./bin/claude:/usr/local/bin/claude:ro'
if inject not in txt:
    txt = txt.replace(needle, needle + '\n' + inject, 1)
# inject a short post-login budget via environment
if 'PLUGIN_POSTLOGIN_BUDGET' not in txt:
    txt = txt.replace('    environment:', '    environment:\n      PLUGIN_POSTLOGIN_BUDGET: "60"', 1)
open(path, 'w').write(txt)
PY

  # claude stub: `plugin install <spec>` succeeds ONLY once the (mocked)
  # credential file exists — modeling the auth-ready lag. Bare `claude` sleeps
  # so the watchdog sees a live tmux session.
  mkdir -p "$DEST/bin"
  cat > "$DEST/bin/claude" <<'CL'
#!/bin/bash
CREDS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
if [ "$1" = "plugin" ] && [ "$2" = "install" ]; then
  spec="$3"
  if [ ! -f "$CREDS" ]; then
    echo "Error: Not authenticated. Please run /login" >&2; exit 1
  fi
  name="${spec%@*}"; mkt="${spec#*@}"
  cache="$HOME/.claude/plugins/cache/$mkt/$name"
  mkdir -p "$cache"; : > "$cache/.installed-ok"
  exit 0
fi
exec sleep 86400
CL
  chmod +x "$DEST/bin/claude"

  (cd "$DEST" && docker compose build)
  (cd "$DEST" && docker compose up -d)

  in_container() { (cd "$DEST" && docker compose exec -T -u agent "$AGENT_NAME" "$@"); }
  local cache="/home/agent/.claude/plugins/cache/claude-plugins-official/telegram"

  # 1) settle unauthenticated for ~15s — the sentinel must NOT appear yet.
  sleep 15
  run in_container test -f "$cache/.installed-ok"
  [ "$status" -ne 0 ]

  # 2) simulate the /login credential flip (the parent dir may not exist yet).
  in_container sh -c 'mkdir -p /home/agent/.claude && touch /home/agent/.claude/.credentials.json'

  # 3) within the budget, the watchdog's post-login retry must install it.
  local deadline=$(( $(date +%s) + 90 )) installed=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if in_container test -f "$cache/.installed-ok" 2>/dev/null; then installed=1; break; fi
    sleep 3
  done
  if [ "$installed" -ne 1 ]; then
    (cd "$DEST" && docker compose logs --tail=80 2>&1) >&2 || true
  fi
  [ "$installed" -eq 1 ]
}
