#!/usr/bin/env bats
# Opt-in: DOCKER_E2E=1 bats tests/docker-e2e-backup-identity.bats
#
# Validates the identity-backup harness end-to-end. Two tests share the
# same scaffold + container boot:
#
#   1. Direct `heartbeatctl backup-identity` push to a host-mounted bare
#      git repo (smoke test for the primitive itself).
#   2. Watchdog-triggered backup after a whitelist file mutation
#      (the original placeholder from this file's stub).
#
# Mock fork: a bare git repo on the host filesystem, bind-mounted into
# the container as /host-fork.git. The agent.yml's scaffold.fork.url is
# patched to point at that path, so heartbeatctl pushes via plain
# `file:///host-fork.git`. No SSH key / encryption needed — recipient
# stays empty, partial-mode push is fine for the test contract.

load 'helper'

setup() {
  [ "${DOCKER_E2E:-0}" = "1" ] || skip "set DOCKER_E2E=1 to run"
  command -v docker >/dev/null 2>&1 || skip "docker not on PATH"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
  TMPDIR=/tmp setup_tmp_dir
  export DEST="$TMP_TEST_DIR/agent-bie2e"
  export AGENT_NAME="bie2e"
  export FORK_DIR="$TMP_TEST_DIR/mock-fork.git"
}

teardown() {
  if [ -n "${DEST:-}" ] && [ -d "$DEST" ]; then
    (cd "$DEST" && docker compose down -v 2>/dev/null || true)
  fi
  teardown_tmp_dir
}

# Scaffold a fresh agent workspace + bare mock fork repo, patch
# agent.yml/docker-compose.yml so the container can push to the fork
# via a bind-mount, and pre-seed the identity whitelist files so the
# first backup has actual content to commit.
_scaffold_with_mock_fork() {
  mkdir -p "$FORK_DIR"
  git init --bare --initial-branch=main "$FORK_DIR" >/dev/null

  mkdir -p "$TMP_TEST_DIR/installer"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$REPO_ROOT/docker" \
        "$TMP_TEST_DIR/installer/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/VERSION" ] && cp "$REPO_ROOT/VERSION" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/.gitignore" ] && cp "$REPO_ROOT/.gitignore" "$TMP_TEST_DIR/installer/"
  [ -f "$REPO_ROOT/LICENSE" ] && cp "$REPO_ROOT/LICENSE" "$TMP_TEST_DIR/installer/"

  cd "$TMP_TEST_DIR/installer"
  wizard_answers name="$AGENT_NAME" display=BIE2E | ./setup.sh --destination "$DEST"

  # Wire up backup-identity:
  #  - fork.enabled=true with the in-container path of the bind-mount
  #  - features.identity_backup.enabled=true so the watchdog hash check
  #    actually fires (default is opt-in)
  #  - recipient stays unset → partial mode (no encryption, no .env push)
  yq -i '.scaffold.fork.enabled = true' "$DEST/agent.yml"
  yq -i '.scaffold.fork.url = "/host-fork.git"' "$DEST/agent.yml"
  yq -i '.features.identity_backup.enabled = true' "$DEST/agent.yml"

  # Inject the bind-mount for the bare fork repo into docker-compose.yml.
  # The compose template emits the agent name as the service key, so we
  # query and append by that key.
  yq -i ".services.\"$AGENT_NAME\".volumes += [\"$FORK_DIR:/host-fork.git\"]" \
    "$DEST/docker-compose.yml"

  # Pre-seed .env so start_services.sh doesn't drop into the in-container
  # token wizard before the test gets to run heartbeatctl.
  cat > "$DEST/.env" <<ENV
TELEGRAM_BOT_TOKEN=00000:fake
TELEGRAM_CHAT_ID=0
ENV
  chmod 0600 "$DEST/.env"

  # Pre-seed the whitelisted files so identity_hash returns a non-empty
  # hash on the first backup attempt. Without these, _bi_run logs "no
  # identity files yet, skipping" and the test asserts on a no-op.
  mkdir -p "$DEST/.state/.claude/channels/telegram"
  mkdir -p "$DEST/.state/.claude/plugins/config"
  printf '{"version":1,"chats":{},"pending":{}}\n' \
    > "$DEST/.state/.claude/channels/telegram/access.json"
  printf '{}\n' > "$DEST/.state/.claude.json"
  printf '{}\n' > "$DEST/.state/.claude/settings.json"
}

# Build + up the container, wait for the tmux session to come up
# (start_services.sh's first concrete signal that boot finished). Bails
# after 60s.
_boot_and_wait() {
  cd "$DEST"
  docker compose build
  docker compose up -d

  local i=0
  while [ $i -lt 60 ]; do
    if docker exec -u agent "$AGENT_NAME" pgrep -f "tmux .*-s agent" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i+1))
  done
  echo "tmux session never came up within 60s" >&2
  docker compose logs --tail=80 >&2 || true
  return 1
}

_fork_commit_count() {
  git --git-dir="$FORK_DIR" rev-list --count refs/heads/backup/identity 2>/dev/null || echo 0
}

@test "harness: heartbeatctl backup-identity pushes initial commit to mock fork" {
  _scaffold_with_mock_fork
  _boot_and_wait

  # Run the primitive directly (sidesteps the 60s watchdog throttle).
  run docker exec -u agent "$AGENT_NAME" heartbeatctl backup-identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"pushed"* ]] || [[ "$output" == *"no changes"* ]]

  # Bare repo grew by at least one commit on backup/identity.
  [ "$(_fork_commit_count)" -ge 1 ]

  # State file persisted with a parseable last_push timestamp.
  [ -f "$DEST/scripts/heartbeat/identity-backup.json" ]
  local last_push
  last_push=$(jq -r '.last_push' "$DEST/scripts/heartbeat/identity-backup.json")
  [[ "$last_push" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "watchdog fires identity backup within 90s of an access.json mutation" {
  _scaffold_with_mock_fork
  _boot_and_wait

  # Establish baseline by running the primitive once before the
  # mutation. Without this, the test races between "watchdog fires the
  # initial backup" and "watchdog fires after our mutation" and we'd
  # need extra disambiguation to tell them apart.
  docker exec -u agent "$AGENT_NAME" heartbeatctl backup-identity >/dev/null
  local baseline
  baseline=$(_fork_commit_count)
  [ "$baseline" -ge 1 ]

  # Mutate the access.json — anything in identity_whitelist would do;
  # access.json is the most realistic (the Telegram channel's pairing
  # state mutates on real conversations).
  docker exec -u agent "$AGENT_NAME" sh -c \
    'jq ".pending.test_mark = \"e2e\"" /home/agent/.claude/channels/telegram/access.json \
       > /tmp/access.new && mv /tmp/access.new /home/agent/.claude/channels/telegram/access.json'

  # Watchdog runs _check_identity_backup every 60s (throttled). Allow
  # 90s for the throttle to expire, the hash recompute, and the push.
  local i=0 latest="$baseline"
  while [ $i -lt 90 ]; do
    sleep 5
    latest=$(_fork_commit_count)
    [ "$latest" -gt "$baseline" ] && break
    i=$((i+5))
  done

  if [ "$latest" -le "$baseline" ]; then
    echo "watchdog did not push within 90s; baseline=$baseline latest=$latest" >&2
    docker exec -u agent "$AGENT_NAME" tail -50 /workspace/scripts/heartbeat/logs/backup-identity.log >&2 || true
  fi
  [ "$latest" -gt "$baseline" ]
}
