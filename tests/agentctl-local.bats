#!/usr/bin/env bats
# 011-local-standalone-mode (US3): agentctl degrades honestly in local mode.
# Docker-only subcommands must fail with a systemctl hint and NEVER invoke
# docker; status/doctor must read systemd (stubbed) instead of the container.

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$TMP_TEST_DIR/"
  mkdir -p "$TMP_TEST_DIR/modules"
  cp -r "$REPO_ROOT/modules/mcps" "$TMP_TEST_DIR/modules/"
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
# is-active --quiet → active (0). is-failed --quiet → NOT failed (1) by default,
# unless SYSTEMCTL_WATCH_FAILED is set (a test simulating a failed watcher).
case "$*" in
  *is-active*) exit 0 ;;
  *is-failed*qmd-watch*) [ "${SYSTEMCTL_WATCH_FAILED:-0}" = 1 ] && exit 0 || exit 1 ;;
  *is-failed*) exit 1 ;;
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

@test "local status: reports vault/RAG units + index when qmd is present (012 FR-013)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local .state/.cache/qmd
  : > scripts/local/agent-qmd-reindex.sh
  : > scripts/local/agent-vault-backup.sh
  : > .state/.cache/qmd/index.sqlite
  run ./scripts/agentctl status
  [ "$status" -eq 0 ]
  [[ "$output" == *"vault/RAG"* ]]
  [[ "$output" == *"qmd reindex timer"* ]]
  [[ "$output" == *"qmd index"* ]]
  [[ "$output" == *"present"* ]]
  [[ "$output" == *"vault backup timer"* ]]
}

@test "local status: NO vault/RAG block when qmd/backup absent (FR-010/FR-013)" {
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl status
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"vault/RAG"* ]]
}

@test "local doctor: reports QMD index + last reindex + backup freshness from state files (FR-013)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local scripts/heartbeat .state/.cache/qmd
  : > scripts/local/agent-qmd-reindex.sh
  : > scripts/local/agent-vault-backup.sh
  : > .state/.cache/qmd/index.sqlite
  printf '{"last_run":"2026-07-04T10:00:00Z","last_status":"indexed"}\n' > scripts/heartbeat/qmd-index.json
  printf '{"last_push":"2026-07-04T09:00:00Z","last_commit":"abc123"}\n' > scripts/heartbeat/vault-backup.json
  run ./scripts/agentctl doctor
  [[ "$output" == *"QMD index present"* ]]
  [[ "$output" == *"QMD last reindex: 2026-07-04T10:00:00Z"* ]]
  # 013: backup is reported via the shared freshness check (label "Backup vault").
  [[ "$output" == *"Backup vault"* ]]
}

@test "local doctor: last_status=error degrades to warn with exit 1 (013 FR-009/SC-005)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local scripts/heartbeat .state/.cache/qmd
  : > scripts/local/agent-qmd-reindex.sh
  : > .state/.cache/qmd/index.sqlite
  printf '{"last_run":"2026-07-05T10:00:00Z","last_status":"error"}\n' > scripts/heartbeat/qmd-index.json
  run ./scripts/agentctl doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"errored"* ]]
  # must NOT report a false ✓ for the reindex
  ! [[ "$output" == *"QMD last reindex: 2026-07-05T10:00:00Z (error)"*"✓"* ]]
}

@test "local doctor: a failed qmd-watch unit warns with exit 1, never a false pass (013 FR-011/SC-005)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local .state/.cache/qmd
  : > scripts/local/agent-qmd-reindex.sh
  : > .state/.cache/qmd/index.sqlite
  SYSTEMCTL_WATCH_FAILED=1 run ./scripts/agentctl doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"watcher"* && "$output" == *"failed"* ]]
}

# --- 014: wiki-graph status/doctor/heartbeat ---------------------------------

@test "local status: reports the wiki-graph block (timer + counts) when present (014/T023)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local scripts/heartbeat
  : > scripts/local/agent-wiki-graph.sh
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"last_run":"%s","last_status":"ok","counts":{"nodes":7,"broken_links":0,"frontmatter_violations":0,"index_drift":0,"orphans":1,"alias_occurrences":1}}\n' "$now" > scripts/heartbeat/wiki-graph.json
  run ./scripts/agentctl status
  [ "$status" -eq 0 ]
  [[ "$output" == *"wiki-graph timer"* ]]
  [[ "$output" == *"wiki-graph counts"* ]]
}

@test "local doctor: wiki-graph integrity findings degrade to WARN exit 1 (014/Q5)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local scripts/heartbeat
  : > scripts/local/agent-wiki-graph.sh
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"last_run":"%s","last_status":"ok","counts":{"broken_links":2,"frontmatter_violations":0,"index_drift":1,"orphans":0}}\n' "$now" > scripts/heartbeat/wiki-graph.json
  run ./scripts/agentctl doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"wiki-graph integrity"* ]]
  [[ "$output" == *"broken_links=2"* ]]
}

@test "local doctor: wiki-graph last_status=error → WARN exit 1 (014/Q5)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local scripts/heartbeat
  : > scripts/local/agent-wiki-graph.sh
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"last_run":"%s","last_status":"error","counts":{"broken_links":0,"frontmatter_violations":0,"index_drift":0}}\n' "$now" > scripts/heartbeat/wiki-graph.json
  run ./scripts/agentctl doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"wiki-graph last run errored"* ]]
}

@test "local doctor: orphans/alias only inform — clean integrity does NOT degrade (014/Q5)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local scripts/heartbeat
  : > scripts/local/agent-wiki-graph.sh
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"last_run":"%s","last_status":"ok","counts":{"broken_links":0,"frontmatter_violations":0,"index_drift":0,"orphans":5,"alias_occurrences":3}}\n' "$now" > scripts/heartbeat/wiki-graph.json
  run ./scripts/agentctl doctor
  # orphans/alias are informational → no wiki-graph WARN from this block
  ! [[ "$output" == *"wiki-graph integrity"* ]]
  [[ "$output" == *"wiki-graph last run"* ]]
}

@test "local doctor: a dead wiki-graph runner (old last_run) → FAIL exit 2 (014/Q5)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local scripts/heartbeat
  : > scripts/local/agent-wiki-graph.sh
  # 2000-01-01 is far older than 2× the default 6h interval → dead runner
  printf '{"last_run":"2000-01-01T00:00:00Z","last_status":"ok","counts":{"broken_links":0,"frontmatter_violations":0,"index_drift":0}}\n' > scripts/heartbeat/wiki-graph.json
  run ./scripts/agentctl doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"wiki-graph runner appears dead"* ]]
}

@test "local heartbeat wiki-graph: missing entrypoint → exit 2 with a hint (014/T014)" {
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl heartbeat wiki-graph
  [ "$status" -eq 2 ]
  [[ "$output" == *"wiki-graph entrypoint not found"* ]]
}

@test "local doctor: stale vault backup (>25h) warns with exit 1 (013 FR-009)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local scripts/heartbeat
  : > scripts/local/agent-vault-backup.sh
  printf '{"last_push":"2026-06-01T00:00:00Z"}\n' > scripts/heartbeat/vault-backup.json
  run ./scripts/agentctl doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"Backup vault"* && "$output" == *"stale"* ]]
}

@test "local doctor: all-sane exits 0 (013 FR-009)" {
  cd "$TMP_TEST_DIR"
  # no qmd/backup artifacts → no vault/RAG checks; unit active + login present.
  # 021: a 0600 .env with no enabled secret-requiring MCP is also "sane" —
  # the doctor's new secrets check must not turn a clean agent red.
  printf 'CLAUDE_CODE_OAUTH_TOKEN=x\n' > .env
  chmod 600 .env
  run ./scripts/agentctl doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Local checks passed"* ]]
}

@test "local status: shows last_run freshness + schedule fallback marker (013 FR-013)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local scripts/heartbeat .state/.cache/qmd
  : > scripts/local/agent-qmd-reindex.sh
  : > .state/.cache/qmd/index.sqlite
  printf '{"last_run":"2026-07-05T12:00:00Z","last_status":"indexed"}\n' > scripts/heartbeat/qmd-index.json
  printf 'original=*/10 8-20 * * *\napplied=*-*-* *:0/5:00\n' > scripts/heartbeat/qmd-schedule.fallback
  run ./scripts/agentctl status
  [ "$status" -eq 0 ]
  [[ "$output" == *"qmd last reindex"* && "$output" == *"2026-07-05T12:00:00Z"* ]]
  [[ "$output" == *"fallback"* ]]
}

@test "local heartbeat qmd-reindex: runs the workspace entrypoint, not a Docker error (013 FR-010/T022)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local
  cat > scripts/local/agent-qmd-reindex.sh << 'SH'
#!/usr/bin/env bash
echo "REINDEX_RAN args=$*" >> "$TMP_TEST_DIR/reindex.log"
SH
  chmod +x scripts/local/agent-qmd-reindex.sh
  export TMP_TEST_DIR
  run ./scripts/agentctl heartbeat qmd-reindex
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"Docker-mode command"* ]]
  grep -q "REINDEX_RAN" "$TMP_TEST_DIR/reindex.log"
}

@test "local heartbeat qmd-reindex --dry-run: refused, never runs a real reindex (013 D8/T022)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local
  cat > scripts/local/agent-qmd-reindex.sh << 'SH'
#!/usr/bin/env bash
echo "REINDEX_RAN" >> "$TMP_TEST_DIR/reindex.log"
SH
  chmod +x scripts/local/agent-qmd-reindex.sh
  export TMP_TEST_DIR
  run ./scripts/agentctl heartbeat qmd-reindex --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not support --dry-run"* ]]
  [ ! -f "$TMP_TEST_DIR/reindex.log" ]
}

@test "local heartbeat backup-vault --dry-run: runs the entrypoint with the flag (013 FR-010/T022)" {
  cd "$TMP_TEST_DIR"
  mkdir -p scripts/local
  cat > scripts/local/agent-vault-backup.sh << 'SH'
#!/usr/bin/env bash
echo "BACKUP_RAN args=$*" >> "$TMP_TEST_DIR/backup.log"
SH
  chmod +x scripts/local/agent-vault-backup.sh
  export TMP_TEST_DIR
  run ./scripts/agentctl heartbeat backup-vault --dry-run
  [ "$status" -eq 0 ]
  grep -q "BACKUP_RAN args=--dry-run" "$TMP_TEST_DIR/backup.log"
}

@test "local heartbeat kick-channel (no local equivalent): still degrades as Docker-only (013 FR-010)" {
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl heartbeat kick-channel
  [ "$status" -ne 0 ]
  [[ "$output" == *"Docker-mode command"* || "$output" == *"systemctl"* ]]
  [ ! -f "$DOCKER_MARKER" ]
}

# ─── 021-local-secret-delivery (US3): _local_secrets_doctor ─────────────────
# contracts/secret-delivery.md D1-D4 + the exclusion table (data-model.md).

_write_agent_yml_with_mcps() {  # _write_agent_yml_with_mcps EXTRA_MCPS_YAML
  cat > "$TMP_TEST_DIR/agent.yml" << YML
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
mcps:
$1
YML
}

@test "021 D1: .env missing → WARN" {
  _write_agent_yml_with_mcps "  defaults: []
  atlassian: []
  github: {enabled: false}"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *".env"* ]]
}

@test "021 D1: .env present with loose permissions (644) → WARN naming chmod 600" {
  _write_agent_yml_with_mcps "  defaults: []
  atlassian: []
  github: {enabled: false}"
  printf 'NOTIFY_BOT_TOKEN=x\n' > "$TMP_TEST_DIR/.env"
  chmod 644 "$TMP_TEST_DIR/.env"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *".env"* && "$output" == *"600"* ]]
}

@test "021 D1: .env present at 0600 → no permissions warning" {
  _write_agent_yml_with_mcps "  defaults: []
  atlassian: []
  github: {enabled: false}"
  printf 'NOTIFY_BOT_TOKEN=x\n' > "$TMP_TEST_DIR/.env"
  chmod 600 "$TMP_TEST_DIR/.env"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -eq 0 ]
}

@test "021 D1: .env 0600 under GNU-stat semantics → no false warning (mclaren gate regression)" {
  # The doctor runs on the agent's OWN host, which in local mode is Linux. There
  # `stat -f` means --file-system and prints a statvfs block to stdout (NOT the
  # mode), so a macOS-first stat order silently mis-read a perfectly-0600 .env as
  # a warning and leaked the statvfs. This stub reproduces GNU coreutils stat:
  #   -c '%a' FILE  → the octal mode (what we want)
  #   -f '%Lp' FILE → -f is --file-system; the '%Lp' is a bogus path, so it
  #                   prints a statvfs block and fails (exit 1).
  cat > "$TMP_TEST_DIR/bin/stat" << 'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then echo "600"; exit 0; fi
if [ "$1" = "-f" ]; then echo "  File: statvfs Namelen: 255 Type: ext2/ext3"; exit 1; fi
exit 1
SH
  chmod +x "$TMP_TEST_DIR/bin/stat"
  _write_agent_yml_with_mcps "  defaults: []
  atlassian: []
  github: {enabled: false}"
  printf 'NOTIFY_BOT_TOKEN=x\n' > "$TMP_TEST_DIR/.env"
  chmod 600 "$TMP_TEST_DIR/.env"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -eq 0 ]
  # No statvfs contamination leaked into any message.
  run grep -q "Namelen" <<< "$output"
  [ "$status" -ne 0 ]
}

@test "021 D2: a lint-dirty .env (trailing backslash) → WARN naming line+key, value never printed" {
  _write_agent_yml_with_mcps "  defaults: []
  atlassian: []
  github: {enabled: false}"
  printf 'GITHUB_PAT=ghp_supersecrettoken12345\\\n' > "$TMP_TEST_DIR/.env"
  chmod 600 "$TMP_TEST_DIR/.env"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"GITHUB_PAT"* ]]
  # Load-bearing negative — last, per the suite's bats hazard.
  if printf '%s' "$output" | grep -q 'ghp_supersecrettoken12345'; then false; fi
}

@test "021 D4: an enabled catalog MCP with an empty required secret → WARN naming the variable" {
  _write_agent_yml_with_mcps "  defaults: [fetch, git, filesystem, firecrawl]
  atlassian: []
  github: {enabled: false}"
  printf 'FIRECRAWL_API_KEY=\n' > "$TMP_TEST_DIR/.env"
  chmod 600 "$TMP_TEST_DIR/.env"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"FIRECRAWL_API_KEY"* ]]
}

@test "021 D4: the same MCP with the secret populated → no warning for it" {
  _write_agent_yml_with_mcps "  defaults: [fetch, git, filesystem, firecrawl]
  atlassian: []
  github: {enabled: false}"
  printf 'FIRECRAWL_API_KEY=fc-real-value\n' > "$TMP_TEST_DIR/.env"
  chmod 600 "$TMP_TEST_DIR/.env"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -eq 0 ]
  if printf '%s' "$output" | grep -q 'FIRECRAWL_API_KEY'; then false; fi
}

@test "021: no-cry-wolf — an MCP that does not require a secret is never warned about" {
  _write_agent_yml_with_mcps "  defaults: [fetch, git, filesystem, aws]
  atlassian: []
  github: {enabled: false}"
  printf 'NOTIFY_BOT_TOKEN=x\n' > "$TMP_TEST_DIR/.env"
  chmod 600 "$TMP_TEST_DIR/.env"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -eq 0 ]
  if printf '%s' "$output" | grep -qE 'AWS_PROFILE|AWS_REGION'; then false; fi
}

@test "021: an empty CLAUDE_CODE_OAUTH_TOKEN is INFO, never a WARN (normal /login state)" {
  _write_agent_yml_with_mcps "  defaults: []
  atlassian: []
  github: {enabled: false}"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=\n' > "$TMP_TEST_DIR/.env"
  chmod 600 "$TMP_TEST_DIR/.env"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -eq 0 ]
}

@test "021: GITHUB_FORK_PAT is excluded — an empty value never warns" {
  _write_agent_yml_with_mcps "  defaults: []
  atlassian: []
  github: {enabled: false}"
  printf 'GITHUB_FORK_PAT=\n' > "$TMP_TEST_DIR/.env"
  chmod 600 "$TMP_TEST_DIR/.env"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -eq 0 ]
}

@test "021 D4: an enabled atlassian instance with an empty token → WARN naming the variable" {
  _write_agent_yml_with_mcps "  defaults: []
  atlassian:
    - name: work
      url: \"https://work.atlassian.net\"
      email: \"a@work.com\"
  github: {enabled: false}"
  cat > "$TMP_TEST_DIR/.env" << 'EOF'
ATLASSIAN_WORK_CONFLUENCE_URL=https://work.atlassian.net/wiki
ATLASSIAN_WORK_CONFLUENCE_USERNAME=a@work.com
ATLASSIAN_WORK_JIRA_URL=https://work.atlassian.net
ATLASSIAN_WORK_JIRA_USERNAME=a@work.com
ATLASSIAN_WORK_TOKEN=
EOF
  chmod 600 "$TMP_TEST_DIR/.env"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"ATLASSIAN_WORK_TOKEN"* ]]
}

@test "021 D4: enabled github MCP with an empty GITHUB_PAT → WARN naming the variable" {
  _write_agent_yml_with_mcps "  defaults: []
  atlassian: []
  github: {enabled: true}"
  printf 'GITHUB_PAT=\n' > "$TMP_TEST_DIR/.env"
  chmod 600 "$TMP_TEST_DIR/.env"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"GITHUB_PAT"* ]]
}

@test "021 D3: the installed unit does not carry the .env EnvironmentFile → WARN" {
  _write_agent_yml_with_mcps "  defaults: []
  atlassian: []
  github: {enabled: false}"
  printf 'NOTIFY_BOT_TOKEN=x\n' > "$TMP_TEST_DIR/.env"
  chmod 600 "$TMP_TEST_DIR/.env"
  cat > "$TMP_TEST_DIR/bin/systemctl" << 'SH'
#!/usr/bin/env bash
case "$*" in
  *is-active*) exit 0 ;;
  *is-failed*) exit 1 ;;
  *show*EnvironmentFiles*)
    echo "/home/op/wk/.state/remote-control.env (ignore_errors=no)"
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$TMP_TEST_DIR/bin/systemctl"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"installed"* ]]
}

@test "021 D3: uses systemctl show, not cat — detects a stale unit even when 'cat' is unreadable (mclaren gate)" {
  # On the agent's own Linux host the installed unit file can be root-only, so
  # 'systemctl cat' fails with 'Permission denied' for the operator. D3 must NOT
  # depend on cat (that silently skipped the whole check on mclaren). 'systemctl
  # show' works unprivileged and reflects what systemd actually loaded.
  _write_agent_yml_with_mcps "  defaults: []
  atlassian: []
  github: {enabled: false}"
  printf 'NOTIFY_BOT_TOKEN=x\n' > "$TMP_TEST_DIR/.env"
  chmod 600 "$TMP_TEST_DIR/.env"
  cat > "$TMP_TEST_DIR/bin/systemctl" << 'SH'
#!/usr/bin/env bash
case "$*" in
  *is-active*) exit 0 ;;
  *is-failed*) exit 1 ;;
  *cat*) echo "Failed to cat: Permission denied" >&2; exit 1 ;;
  *show*EnvironmentFiles*)
    echo "/home/op/wk/.state/remote-control.env (ignore_errors=no)"
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$TMP_TEST_DIR/bin/systemctl"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"installed"* ]]
}

@test "021 D3: the installed unit DOES carry the .env EnvironmentFile → no warning" {
  _write_agent_yml_with_mcps "  defaults: []
  atlassian: []
  github: {enabled: false}"
  printf 'NOTIFY_BOT_TOKEN=x\n' > "$TMP_TEST_DIR/.env"
  chmod 600 "$TMP_TEST_DIR/.env"
  cat > "$TMP_TEST_DIR/bin/systemctl" << 'SH'
#!/usr/bin/env bash
case "$*" in
  *is-active*) exit 0 ;;
  *is-failed*) exit 1 ;;
  *show*EnvironmentFiles*)
    echo "/home/op/wk/.env (ignore_errors=yes) /home/op/wk/.state/remote-control.env (ignore_errors=no)"
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$TMP_TEST_DIR/bin/systemctl"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -eq 0 ]
}

@test "021: an all-clean secrets configuration produces zero secrets output (no crying wolf)" {
  _write_agent_yml_with_mcps "  defaults: [fetch, git, filesystem, firecrawl]
  atlassian: []
  github: {enabled: true}"
  cat > "$TMP_TEST_DIR/.env" << 'EOF'
FIRECRAWL_API_KEY=fc-real
GITHUB_PAT=ghp_real
EOF
  chmod 600 "$TMP_TEST_DIR/.env"
  cat > "$TMP_TEST_DIR/bin/systemctl" << 'SH'
#!/usr/bin/env bash
case "$*" in
  *is-active*) exit 0 ;;
  *is-failed*) exit 1 ;;
  *show*EnvironmentFiles*)
    echo "/home/op/wk/.env (ignore_errors=yes) /home/op/wk/.state/remote-control.env (ignore_errors=no)"
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$TMP_TEST_DIR/bin/systemctl"
  cd "$TMP_TEST_DIR"
  run ./scripts/agentctl doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Local checks passed"* ]]
}
