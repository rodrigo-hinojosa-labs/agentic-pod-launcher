#!/usr/bin/env bats
# Docker e2e for 045-plugin-launcher-path: in a real container built from this tree,
# every claude the product starts gets /home/agent/.local/bin at the END of its PATH,
# an executable seeded there resolves by name, a decoy named like an image binary
# does not win, and the environment Docker hands the container (inherited by tini,
# the entrypoint, the crontab sync loop, crond and a default `docker exec -u root`)
# does not carry the directory.
#
# This is the confirmation in a real container. The test-first oracle is the host one
# (tests/agent-user-bin-path.bats). The token wizard needs a logged-in session and is
# not run here; the host test S1 covers it (same `tmux new-session` line). No test
# here uses `docker exec -u root` (Principle II): the root-side check reads
# `docker inspect`. Contract: specs/045-plugin-launcher-path/contracts/e2e-and-gate.md.
#
# Skipped by default (slow + requires Docker). Enable with DOCKER_E2E=1.

load helper

IMAGE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
UB="/home/agent/.local/bin"

setup_file() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then skip "set DOCKER_E2E=1 to run"; fi
  TMPDIR=/tmp setup_tmp_dir
  export DEST="$TMP_TEST_DIR/agent-e2e"
  export AGENT_NAME="ub-e2e"
  export STUB_LOG="$DEST/scripts/heartbeat/logs/stub-claude.jsonl"
  mkdir -p "$DEST"
  cat > "$DEST/agent.yml" <<YML
version: 1
agent: {name: $AGENT_NAME, display_name: "ub e2e", role: "test", vibe: "terse"}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$DEST", install_service: false, claude_cli: "claude"}
docker: {image_tag: "agent-admin:ub045-e2e", uid: $(id -u), gid: $(id -g), state_volume: "${AGENT_NAME}-state", base_image: "alpine:3.24.1"}
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
  (cd "$DEST" && ./setup.sh --regenerate --non-interactive) > "$TMP_TEST_DIR/regenerate.log" 2>&1 \
    || { tail -n 40 "$TMP_TEST_DIR/regenerate.log" >&2; return 1; }
  touch "$DEST/.env"
  chmod 0600 "$DEST/.env"

  # Seed the user bin directory BEFORE boot (.state is /home/agent).
  mkdir -p "$DEST/.state/.local/bin" "$DEST/scripts/heartbeat/logs"
  printf '#!/bin/sh\necho probe045-ran\n' > "$DEST/.state/.local/bin/probe045"
  printf '#!/bin/sh\necho DECOY\n' > "$DEST/.state/.local/bin/node"
  chmod +x "$DEST/.state/.local/bin/probe045" "$DEST/.state/.local/bin/node"

  # The claude stub records, per invocation, its mode, argv, tmux pane, PATH and how
  # two names resolve. The supervisor itself calls `claude plugin ...` outside tmux
  # before every session (ensure_official_marketplace): those calls are mode
  # "supervisor" and fail at once, so they neither pass for the session nor wait out
  # their 12 s timeout.
  mkdir -p "$DEST/bin"
  cat > "$DEST/bin/claude" <<'CL'
#!/bin/bash
log=/workspace/scripts/heartbeat/logs/stub-claude.jsonl
mode=session
case " $* " in
  *" --print "*) mode=print ;;
  *" mcp "*) mode=mcp ;;
  *) [ -n "${TMUX_PANE-}" ] || mode=supervisor ;;
esac
probe=$(command -v probe045 || echo missing)
probe_out=$(probe045 2>&1 || echo failed)
node_at=$(command -v node || echo missing)
jq -cn --arg mode "$mode" --arg args "$*" --arg pane "${TMUX_PANE-}" --arg path "$PATH" \
  --arg probe "$probe" --arg out "$probe_out" --arg node "$node_at" --arg pid "$$" --arg ts "$(date +%s)" \
  '{mode:$mode, args:$args, pane:$pane, path:$path, probe:$probe, probe_out:$out, node:$node, pid:$pid, ts:$ts}' >> "$log"
case "$mode" in
  print) echo "STUB_CLAUDE ok"; exit 0 ;;
  mcp) exit 0 ;;
  supervisor) exit 1 ;;
  *) exec sleep 86400 ;;
esac
CL
  chmod +x "$DEST/bin/claude"
  python3 - "$DEST/docker-compose.yml" <<'PY'
import sys
path = sys.argv[1]
txt = open(path).read()
needle = '      - ./:/workspace'
inject = '      - ./bin/claude:/usr/local/bin/claude:ro'
if inject not in txt:
    assert txt.count(needle) == 1, "workspace mount anchor not found"
    txt = txt.replace(needle, needle + '\n' + inject, 1)
open(path, 'w').write(txt)
PY
  (cd "$DEST" && docker compose build) > "$TMP_TEST_DIR/build.log" 2>&1 \
    || { tail -n 40 "$TMP_TEST_DIR/build.log" >&2; return 1; }
  (cd "$DEST" && docker compose up -d) > "$TMP_TEST_DIR/up.log" 2>&1 \
    || { tail -n 40 "$TMP_TEST_DIR/up.log" >&2; return 1; }
}

teardown_file() {
  if [ -n "${DEST:-}" ] && [ -d "$DEST" ]; then
    (cd "$DEST" && docker compose down -v --remove-orphans) >/dev/null 2>&1 || true
    docker image rm agent-admin:ub045-e2e >/dev/null 2>&1 || true
  fi
  teardown_tmp_dir
}

# _wait_record JQ_FILTER SECONDS: wait until the stub log has a line matching the
# filter; prints the last matching line.
_wait_record() {
  local filter="$1" secs="$2" deadline line
  deadline=$(( $(date +%s) + secs ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -f "$STUB_LOG" ]; then
      line=$(jq -c "select($filter)" "$STUB_LOG" 2>/dev/null | tail -n 1)
      if [ -n "$line" ]; then printf '%s\n' "$line"; return 0; fi
    fi
    sleep 3
  done
  return 1
}

_dump() {
  echo "--- stub-claude.jsonl ---" >&2
  cat "$STUB_LOG" >&2 2>/dev/null || true
  echo "--- container logs ---" >&2
  (cd "$DEST" && docker compose logs --tail=80 2>&1) >&2 || true
}

# _assert_contract RECORD: the PATH ends with the user bin dir and starts with the
# image PATH; probe045 resolves there and runs; node resolves to the image's.
_assert_contract() {
  local rec="$1"
  [ "$(printf '%s' "$rec" | jq -r .path)" = "$IMAGE_PATH:$UB" ]
  [ "$(printf '%s' "$rec" | jq -r .probe)" = "$UB/probe045" ]
  [ "$(printf '%s' "$rec" | jq -r .probe_out)" = "probe045-ran" ]
  [ "$(printf '%s' "$rec" | jq -r .node)" = "/usr/bin/node" ]
}

@test "045 E1: the main session's claude gets <image PATH>:/home/agent/.local/bin; the supervisor keeps the image PATH" {
  local rec sup
  rec=$(_wait_record '.mode == "session" and .pane != ""' 120) || { _dump; false; }
  _assert_contract "$rec"
  # The supervisor's own `claude plugin ...` calls run outside tmux with its own,
  # unchanged PATH (contract C2: only the session gets the directory).
  sup=$(_wait_record '.mode == "supervisor"' 30) || { _dump; false; }
  [ "$(printf '%s' "$sup" | jq -r .path)" = "$IMAGE_PATH" ]
}

@test "045 E2: after the watchdog respawns the session, the new claude gets the same PATH" {
  local first rec
  first=$(_wait_record '.mode == "session" and .pane != ""' 120) || { _dump; false; }
  local pid0
  pid0=$(printf '%s' "$first" | jq -r .pid)
  docker exec -u agent "$AGENT_NAME" tmux kill-session -t agent
  rec=$(_wait_record ".mode == \"session\" and .pane != \"\" and .pid != \"$pid0\"" 90) || { _dump; false; }
  _assert_contract "$rec"
}

@test "045 E3: a real cron heartbeat tick runs claude --print with the same PATH" {
  local rec
  rec=$(_wait_record '.mode == "print"' 180) || { _dump; false; }
  _assert_contract "$rec"
  # The stub records when the tick STARTS claude; heartbeat.sh writes runs.jsonl
  # after the session ends, so wait for it (bounded) instead of racing it.
  local deadline=$(( $(date +%s) + 60 ))
  while [ ! -s "$DEST/scripts/heartbeat/logs/runs.jsonl" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 2; done
  [ -s "$DEST/scripts/heartbeat/logs/runs.jsonl" ] || { _dump; false; }
  [ "$(jq -r '.trigger' "$DEST/scripts/heartbeat/logs/runs.jsonl" | head -n 1)" = "cron" ]
}

@test "045 E4: agentctl mcp, run from the host, starts claude mcp with the same PATH" {
  (cd "$DEST" && ./scripts/agentctl mcp)
  local rec
  rec=$(_wait_record '.mode == "mcp"' 30) || { _dump; false; }
  _assert_contract "$rec"
}

@test "045 E5: the environment Docker hands the container has exactly the image PATH (no root exec)" {
  local env_path
  env_path=$(docker inspect --format '{{json .Config.Env}}' "$AGENT_NAME" \
    | jq -r '.[] | select(startswith("PATH=")) | sub("^PATH="; "")')
  [ "$env_path" = "$IMAGE_PATH" ]
}
