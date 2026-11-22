#!/usr/bin/env bats
# Docker e2e for 046-agent-backup-repo: in a real container built from this tree, the
# five backup units reach an associated repository served by the test git server on
# the host, a second cycle creates no commit, the boot creates the work clone, a wrong
# credential does not hurt the container, a sensitive agent leaks nothing, crond pushes
# with the credential, a restore on the host matches what was backed up, and
# backup-status never prints the credential.
#
# Contract: specs/046-agent-backup-repo/contracts/evidence.md (V4, TE1 to TE8). The
# host oracles are the six 046 suites; this is the confirmation in a container. Every
# `docker exec` uses `-u agent` (Principle II).
#
# Skipped by default (slow + requires Docker). Enable with DOCKER_E2E=1.

load helper
load helper-backup-repo

AGENT_NAME="br-e2e"
IMAGE="agent-admin:br046-e2e"

setup_file() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then skip "set DOCKER_E2E=1 to run"; fi
  br_require || return 1
  br_keys
  br_sentinels
  export GIT_TEST_BIND=0.0.0.0
  br_start_server
  br_server_token "$BR_TOKEN"
  TMPDIR=/tmp setup_tmp_dir
  export DEST="$TMP_TEST_DIR/agent-e2e"
  export E2E_REPO_URL="http://host.docker.internal:$BR_PORT/br-e2e.git"
  BATS_TEST_TMPDIR="$BATS_FILE_TMPDIR" br_new_repo br-e2e > /dev/null
  mkdir -p "$DEST"
  cat > "$DEST/agent.yml" << YML
version: 1
agent: {name: $AGENT_NAME, display_name: "br e2e", role: "test", vibe: "terse", role_file: personas/$AGENT_NAME.md}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$DEST", install_service: false, claude_cli: "claude"}
docker: {image_tag: "$IMAGE", uid: $(id -u), gid: $(id -g), state_volume: "${AGENT_NAME}-state", base_image: "alpine:3.24.1"}
claude: {config_dir: "/home/agent/.claude", profile_new: true}
notifications: {channel: none}
features:
  heartbeat: {enabled: false, interval: "30m", timeout: 30, retries: 0, default_prompt: "echo pong"}
  identity_backup: {enabled: true, schedule: "30 3 * * *"}
  memory_backup: {enabled: true, schedule: "40 3 * * *"}
  history_backup: {enabled: true, schedule: "50 3 * * *"}
backup:
  identity: {recipient: "$BR_KEY_A_PUB"}
  repo: {url: "$E2E_REPO_URL", allow_unverified: false}
  sensitive: false
  extra_paths: [".custom"]
vault: {enabled: true, path: .state/.vault}
mcps: {defaults: [], atlassian: [], github: {enabled: false, email: ""}}
plugins: []
YML
  mkdir -p "$DEST/personas"
  printf '# Persona\n\n%s\n' "$BR_SENT_PERSONA" > "$DEST/personas/$AGENT_NAME.md"
  cp -R "$REPO_ROOT/modules" "$REPO_ROOT/scripts" "$REPO_ROOT/docker" "$DEST/"
  cp "$REPO_ROOT/setup.sh" "$DEST/"
  chmod +x "$DEST/setup.sh"
  (cd "$DEST" && BACKUP_DEST_ALLOW_HTTP=1 ./setup.sh --regenerate --non-interactive) > "$TMP_TEST_DIR/regenerate.log" 2>&1 \
    || { tail -n 40 "$TMP_TEST_DIR/regenerate.log" >&2; return 1; }
  _e2e_seed "$DEST"
  _e2e_stub_and_override "$DEST"
  (cd "$DEST" && docker compose build) > "$TMP_TEST_DIR/build.log" 2>&1 \
    || { tail -n 40 "$TMP_TEST_DIR/build.log" >&2; return 1; }
  (cd "$DEST" && docker compose up -d) > "$TMP_TEST_DIR/up.log" 2>&1 \
    || { tail -n 40 "$TMP_TEST_DIR/up.log" >&2; return 1; }
  _e2e_wait_running 120
}

# Every test leaves the shared agent as setup_file left it, also when it fails: TE4
# rotates the server token, TE5 marks the agent sensitive on another repository, and
# TE6 schedules memory every minute (a cron that would race TE7 for the lock).
teardown() {
  [ "${DOCKER_E2E:-0}" = "1" ] || return 0
  [ -n "${DEST:-}" ] && [ -f "$DEST/agent.yml" ] || return 0
  br_server_token "$BR_TOKEN"
  if [ "$(yq -r '.backup.sensitive' "$DEST/agent.yml")" != "false" ] \
     || [ "$(yq -r '.backup.repo.url' "$DEST/agent.yml")" != "$E2E_REPO_URL" ]; then
    yq -i ".backup.sensitive = false | .backup.repo.url = \"$E2E_REPO_URL\"" "$DEST/agent.yml"
  fi
  if [ "$(yq -r '.features.memory_backup.schedule' "$DEST/agent.yml")" != "40 3 * * *" ]; then
    yq -i '.features.memory_backup.schedule = "40 3 * * *"' "$DEST/agent.yml"
    _e2e_exec heartbeatctl reload > /dev/null 2>&1 || true
  fi
}

teardown_file() {
  if [ -n "${DEST:-}" ] && [ -d "$DEST" ]; then
    (cd "$DEST" && docker compose down -v --remove-orphans) > /dev/null 2>&1 || true
    docker image rm "$IMAGE" > /dev/null 2>&1 || true
  fi
  br_stop_server
  teardown_tmp_dir
}

# The state a real agent has, seeded BEFORE boot (.state is /home/agent). The secrets
# file lives at the workspace root, never in .state.
_e2e_seed() {
  local d="$1"
  BR_SECRETS_FILE="$d/.env"
  printf 'GITHUB_PAT=%s\nBACKUP_DEST_ALLOW_HTTP=1\nAGENT_SECRET=%s\n' "$BR_TOKEN" "$BR_SENT_SECRETS" > "$BR_SECRETS_FILE"
  chmod 0600 "$BR_SECRETS_FILE"
  mkdir -p "$d/.state/.claude/channels/telegram" "$d/.state/.vault/wiki/concepts" \
           "$d/.state/.claude/projects/-workspace/memory" "$d/.state/.claude-mem" "$d/.custom" \
           "$d/scripts/heartbeat/logs"
  printf '{"identity":"%s"}\n' "$BR_SENT_IDENTITY" > "$d/.state/.claude.json"
  printf '# Concept\n\n%s\n' "$BR_SENT_VAULT" > "$d/.state/.vault/wiki/concepts/page.md"
  printf '%s\n' "$BR_SENT_AUTOMEM" > "$d/.state/.claude/projects/-workspace/memory/MEMORY.md"
  printf '{"type":"user","text":"%s"}\n{"partial":' "$BR_SENT_HISTORY" \
    > "$d/.state/.claude/projects/-workspace/0000-session.jsonl"
  printf '%s\n' "$BR_SENT_EXTRA" > "$d/.custom/data.txt"
  python3 - "$d/.state/.claude-mem/claude-mem.db" "$BR_SENT_CLAUDEMEM" << 'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("create table obs (id integer primary key, text text)")
c.execute("insert into obs (text) values (?)", (sys.argv[2],))
c.commit()
PY
}

# A claude stub that keeps the session alive, and the override that lets the container
# reach the host test server.
_e2e_stub_and_override() {
  local d="$1"
  mkdir -p "$d/bin"
  cat > "$d/bin/claude" << 'CL'
#!/bin/bash
case " $* " in
  *" --print "*) echo "STUB_CLAUDE ok"; exit 0 ;;
  *" mcp "*) exit 0 ;;
esac
[ -n "${TMUX_PANE-}" ] || exit 1
exec sleep 86400
CL
  chmod +x "$d/bin/claude"
  cat > "$d/docker-compose.override.yml" << OVR
services:
  $AGENT_NAME:
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./bin/claude:/usr/local/bin/claude:ro
OVR
  # Only Docker Desktop needs this cache workaround (T072). On native Linux an
  # unseeded nested volume is root-owned while the bind-mounted home already has
  # the agent UID, so the entrypoint correctly leaves the home alone. Keep Linux
  # on the product's actual state bind mount instead of introducing that volume.
  if [ "$(uname -s)" = "Darwin" ]; then
    cat >> "$d/docker-compose.override.yml" << 'OVR'
      - br046-cache:/home/agent/.cache
volumes:
  br046-cache: {}
OVR
  fi
}

_e2e_wait_running() {
  local deadline=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # Running precedes the supervisor's settings and hook writes. The first real
    # session is created only after those writes, so it is the readiness signal.
    if [ "$(docker inspect -f '{{.State.Running}}' "$AGENT_NAME" 2> /dev/null)" = "true" ] \
       && _e2e_exec tmux has-session -t agent 2> /dev/null; then return 0; fi
    sleep 2
  done
  docker logs "$AGENT_NAME" 2>&1 | tail -n 40 >&2
  return 1
}

_e2e_exec() { docker exec -u agent "$AGENT_NAME" "$@"; }

_e2e_unit() { _e2e_exec heartbeatctl "backup-$1"; }

_e2e_dump() {
  echo "--- identity cache ownership (metadata only)" >&2
  _e2e_exec sh -c 'id; for p in "$HOME" "$HOME/.cache" "$HOME/.cache/identity-backup" "$HOME/.cache/identity-backup/identity-repo" "$HOME/.cache/identity-backup/identity-repo/.git"; do
    if [ -e "$p" ]; then stat -c "%u:%g %a %n" "$p"; fi
  done' >&2 || true
  echo "--- cron staging, active file and process metadata" >&2
  _e2e_exec sh -c 'date -u; pgrep -x crond; for p in /workspace/scripts/heartbeat /workspace/scripts/heartbeat/logs /workspace/scripts/heartbeat/.crontab.staging /etc/crontabs /etc/crontabs/agent; do
    if [ -e "$p" ]; then stat -c "%u:%g %a %Y %n" "$p"; fi
  done
  grep -F backup-memory /workspace/scripts/heartbeat/.crontab.staging /etc/crontabs/agent || true
  ps -o pid,ppid,user,comm
  if [ -f /workspace/claude.cron.log ]; then cat /workspace/claude.cron.log; fi' 2>&1 | (
    source "$REPO_ROOT/scripts/lib/rag_obs.sh"
    redact_secrets | tail -n 60
  ) >&2 || true
  echo "--- docker logs" >&2
  docker logs "$AGENT_NAME" 2>&1 | tail -n 30 >&2
  echo "--- server log" >&2
  tail -n 30 "$BR_SRV_LOG" >&2
}

@test "TE1: a forced cycle leaves the five units (048: .agent-backup/ of main) with their mark, and identity carries the encrypted secrets" {
  local u
  for u in identity vault config memory history; do
    run _e2e_unit "$u"
    [ "$status" -eq 0 ] || { echo "$u: $output" >&2; _e2e_dump; false; }
    grep -qE "^backup-$u: [0-9a-f]{8} pushed" <<< "$output"
    [ "$(jq -r '.unit' <<< "$(br_branch_show br-e2e "backup/$u" .agentic-pod-backup.json)")" = "$u" ]
  done
  br_branch_files br-e2e backup/identity | grep -qxF '.env.age'
  if br_branch_has br-e2e backup/identity "$BR_SENT_SECRETS"; then false; fi
}

@test "TE2: a second cycle creates no commit" {
  local u before after
  for u in identity vault config memory history; do
    before=$(br_branch_commits br-e2e "backup/$u")
    run _e2e_unit "$u"
    [ "$status" -eq 0 ]
    after=$(br_branch_commits br-e2e "backup/$u")
    [ "$after" = "$before" ] || { echo "$u: $before -> $after ($output)" >&2; false; }
  done
}

@test "TE3: the boot creates the work clone, the agent pushes a work branch, and backups never move the work heads" {
  local i
  for i in $(seq 1 60); do
    _e2e_exec test -d /workspace/agent-repo/.git && break
    sleep 2
  done
  _e2e_exec test -d /workspace/agent-repo/.git || { _e2e_dump; false; }
  _e2e_exec git -C /workspace/agent-repo config --get-all remote.origin.fetch | grep -qxF '^refs/heads/backup/*'
  _e2e_exec sh -c 'cd /workspace/agent-repo && git checkout -q -b e2e-work && echo w > w.txt && git add w.txt && git -c user.name=e -c user.email=e@e commit -q -m w && GIT_TERMINAL_PROMPT=0 git push -q origin e2e-work'
  local heads
  heads=$(br_work_heads br-e2e)
  grep -qF 'refs/heads/e2e-work' <<< "$heads"
  printf 'changed\n' >> "$DEST/.state/.vault/wiki/concepts/page.md"
  _e2e_unit vault > /dev/null
  # 048: main receives the backup commits, so only the other work heads stay put; the
  # old main stays an ancestor.
  local ref sha
  while read -r ref sha; do
    if [ "$ref" = "refs/heads/main" ]; then
      br_is_ancestor br-e2e "$sha"
    else
      [ "$(_br_git -C "$(br_bare br-e2e)" rev-parse "$ref")" = "$sha" ]
    fi
  done <<< "$heads"
  # The work clone leaves .agent-backup/ out of its tree and has the launcher's hook.
  _e2e_exec sh -c 'cd /workspace/agent-repo && git pull -q --ff-only origin main 2>/dev/null || git fetch -q origin'
  if _e2e_exec test -e /workspace/agent-repo/.agent-backup; then false; fi
  _e2e_exec grep -qF '# agentic-pod-launcher: agent-backup guard' /workspace/agent-repo/.git/hooks/pre-commit
}

@test "EM01 (048): in the container the five units and the README live in .agent-backup/ of main, and no backup/* branch exists" {
  [ "$(_br_git -C "$(br_bare br-e2e)" ls-tree --name-only refs/heads/main:.agent-backup | tr '\n' ' ')" = "README.md config history identity memory vault " ]
  [ -z "$(br_backup_refs br-e2e)" ]
  [ "$(br_force_count br-e2e)" -eq 0 ]
}

@test "EM03 (048): a marked legacy branch is deleted by the container's unit after main holds its tree" {
  br_seed_branch br-e2e backup/vault '{"schema":1,"agent":"br-e2e","unit":"vault"}' legacy.md "old"
  printf 'changed again\n' >> "$DEST/.state/.vault/wiki/concepts/page.md"
  run _e2e_unit vault
  [ "$status" -eq 0 ] || { echo "$output" >&2; _e2e_dump; false; }
  grep -qF 'legacy branch backup/vault deleted (its backup is in main)' <<< "$output"
  if _br_git -C "$(br_bare br-e2e)" rev-parse --verify -q refs/heads/backup/vault > /dev/null; then false; fi
}

@test "TE4: with a wrong credential the units end within their limit and the container stays healthy, without restarts" {
  local restarts u t0
  restarts=$(docker inspect -f '{{.RestartCount}}' "$AGENT_NAME")
  br_server_token "rotated-$BR_TOKEN"
  printf 'touch %s\n' "$RANDOM" >> "$DEST/.state/.claude/projects/-workspace/memory/MEMORY.md"
  for u in identity memory; do
    t0=$(date +%s)
    run _e2e_unit "$u"
    [ $(( $(date +%s) - t0 )) -lt 150 ]
    grep -qF "backup-$u: repository unreachable" <<< "$output" || { echo "$output" >&2; false; }
  done
  [ "$(docker inspect -f '{{.State.Running}}' "$AGENT_NAME")" = "true" ]
  [ "$(docker inspect -f '{{.RestartCount}}' "$AGENT_NAME")" = "$restarts" ]
}

@test "TE5: in a sensitive agent no object of the backup branches holds the vault, memory, history or persona sentinels" {
  br_new_repo br-e2e-s > /dev/null
  yq -i ".backup.sensitive = true | .backup.repo.url = \"http://host.docker.internal:$BR_PORT/br-e2e-s.git\"" "$DEST/agent.yml"
  local u s
  for u in identity vault config memory history; do
    run _e2e_unit "$u"
    [ "$status" -eq 0 ] || { echo "$u: $output" >&2; _e2e_dump; false; }
  done
  for u in vault config memory history; do
    for s in "$BR_SENT_VAULT" "$BR_SENT_AUTOMEM" "$BR_SENT_HISTORY" "$BR_SENT_PERSONA" "$BR_SENT_CLAUDEMEM"; do
      if br_branch_has br-e2e-s "backup/$u" "$s"; then echo "found a sentinel in backup/$u" >&2; false; fi
    done
  done
}

@test "TE6: a unit launched by crond pushes: the job receives the credential" {
  yq -i '.features.memory_backup.schedule = "* * * * *"' "$DEST/agent.yml"
  _e2e_exec heartbeatctl reload > /dev/null
  printf 'cron %s\n' "$RANDOM" >> "$DEST/.state/.claude/projects/-workspace/memory/MEMORY.md"
  local before i
  before=$(br_branch_head br-e2e backup/memory)
  for i in $(seq 1 75); do
    [ "$(br_branch_head br-e2e backup/memory)" != "$before" ] && break
    sleep 2
  done
  [ "$(br_branch_head br-e2e backup/memory)" != "$before" ] || {
    _e2e_exec tail -n 20 /workspace/scripts/heartbeat/logs/backup-memory.log >&2 || true; _e2e_dump; false; }
}

@test "TE7: a restore on the host from the repository the container filled matches the two lists of R7" {
  local u
  for u in identity vault config memory history; do _e2e_unit "$u" > /dev/null || true; done
  local dest="$TMP_TEST_DIR/restored" home="$TMP_TEST_DIR/restore-home"
  mkdir -p "$home"
  run env HOME="$home" GIT_TERMINAL_PROMPT=0 bash -c 'source "$1/setup.sh" > /dev/null 2>&1 || true
    RESTORE_IDENTITY_KEY="$2"
    restore_from_fork "$3" "$4"' _ "$REPO_ROOT" "$BR_KEY_A" "$(br_bare br-e2e)" "$dest"
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  # Lo que viaja tal cual: el mismo SHA-256.
  local pair src dst
  for pair in "agent.yml|agent.yml" "personas/$AGENT_NAME.md|personas/$AGENT_NAME.md" \
              ".state/.claude.json|.state/.claude.json" \
              ".state/.vault/wiki/concepts/page.md|.state/.vault/wiki/concepts/page.md" \
              ".state/.claude/projects/-workspace/memory/MEMORY.md|.state/.claude/projects/-workspace/memory/MEMORY.md" \
              ".custom/data.txt|.custom/data.txt" ".env|.env"; do
    src="$DEST/${pair%%|*}"
    dst="$dest/${pair#*|}"
    [ "$(br_sha256 "$src")" = "$(br_sha256 "$dst")" ] || { echo "differs: ${pair%%|*}" >&2; false; }
  done
  # Lo capturado: contra digest --list del origen.
  # Capture at the origin: different SQLite versions can emit different database
  # bytes for the same rows. The oracle must use the producer's Python/SQLite.
  _e2e_exec python3 -c 'from pathlib import Path
p=Path("/workspace/scripts/heartbeat/tmp/r7.map")
p.parent.mkdir(parents=True, exist_ok=True)
p.write_bytes(b"claude-mem/claude-mem.db\0/workspace/.state/.claude-mem/claude-mem.db\0"
              b"projects/-workspace/0000-session.jsonl\0/workspace/.state/.claude/projects/-workspace/0000-session.jsonl\0")'
  local list path size sha f
  list=$(_e2e_exec python3 /opt/agent-admin/scripts/backup_store.py digest \
           --map /workspace/scripts/heartbeat/tmp/r7.map \
           --snapshot-dir /workspace/scripts/heartbeat/tmp/r7.snap --list)
  while IFS=$'\t' read -r path size sha; do
    case "$path" in
      claude-mem/*) f="$dest/.state/.claude-mem/${path#claude-mem/}" ;;
      projects/*) f="$dest/.state/.claude/projects/${path#projects/}" ;;
    esac
    [ "$(wc -c < "$f" | tr -d ' ')" = "$size" ]
    local received
    received=$(br_sha256 "$f")
    [ "$received" = "$sha" ] || {
      printf 'capture mismatch: path=%s bytes=%s expected=%s received=%s\n' "$path" "$size" "$sha" "$received" >&2
      python3 -c 'import sqlite3,sys; print("host",sys.version.split()[0],"sqlite",sqlite3.sqlite_version)' >&2
      _e2e_exec python3 -c 'import sqlite3,sys; print("container",sys.version.split()[0],"sqlite",sqlite3.sqlite_version)' >&2
      false
    }
  done <<< "$list"
  rm -rf "$dest"
}

@test "TE8: backup-status --json inside the container never shows the credential, nor do the logs" {
  run _e2e_exec heartbeatctl backup-status --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.credential' <<< "$output")" = "present" ]
  [ "$(jq -r '.destination.kind' <<< "$output")" = "repo" ]
  if grep -qF -- "$BR_TOKEN" <<< "$output"; then false; fi
  if grep -rqF -- "$BR_TOKEN" "$DEST/scripts/heartbeat/logs" "$DEST/scripts/heartbeat/backup-dest.json"; then false; fi
}
