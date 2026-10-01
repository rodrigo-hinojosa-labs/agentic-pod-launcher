#!/usr/bin/env bats
#
# 038 DOCKER_E2E - the SessionStart upgrade-notice hook inside a REAL container boot.
#
# The host suite proves the pieces (the detection libraries, the rendered hook, the installer,
# the boot function against a stub) but cannot prove the one thing that is image-baked: that
# start_services.sh, running as `agent` under the capability-reduced container, registers the
# hook in the agent's REAL ~/.claude/settings.json on every boot, and that the rendered hook runs
# on the image's own toolchain (busybox cmp/dirname/cat, Alpine jq). It also cannot see the boot's
# own additive vault upgrade produce the pending state the hook then reports: here the vault is
# pre-seeded as an already-populated PRE-0.27.0 vault, so the real boot deposits the 0.27.0 delta
# (the 037 lesson: seed BEFORE `up`, never overlay after - the boot's own seed would race it).
#
# What this does NOT prove: that Claude Code injects the hook's text into the model. The harness
# has no OAuth and a `claude` stub that only sleeps. That is gate G1 on a real agent (tasks T044).
#
# Skipped by default (slow + needs a Docker daemon). Enable with DOCKER_E2E=1.
# Contract: specs/038-schema-delta-boot-nudge/quickstart.md section 5 (E1-E4).

load helper

setup() {
  if [ "${DOCKER_E2E:-0}" != "1" ]; then skip "set DOCKER_E2E=1 to run (requires a docker daemon)"; fi
  command -v docker >/dev/null 2>&1 || skip "docker not on PATH"
  docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
  TMPDIR=/tmp setup_tmp_dir
  export DEST="$TMP_TEST_DIR/agent-notice-e2e"
  export AGENT_NAME="notice-e2e"
}

teardown() {
  if [ -n "${DEST:-}" ] && [ -d "$DEST" ]; then
    (cd "$DEST" && docker compose down -v --remove-orphans 2>/dev/null || true)
  fi
  teardown_tmp_dir
}

# in_container CMD...: run as the agent user (every docker exec must pass -u agent: root inside the
# container cannot write agent-owned files, there is no CAP_FOWNER).
in_container() {
  (cd "$DEST" && docker compose exec -T -u agent "$AGENT_NAME" "$@")
}

# _scaffold: a workspace with agent.yml and every source dir, rendered, with a claude stub
# bind-mounted so the watchdog keeps a long-running tmux session. Nothing is started yet.
_scaffold() {
  mkdir -p "$DEST"
  cat > "$DEST/agent.yml" <<YML
version: 1
agent: {name: $AGENT_NAME, display_name: "notice e2e", role: "test", vibe: "terse"}
user: {name: "Tester", nickname: "Tester", timezone: "UTC", email: "t@e.x", language: "en"}
deployment: {host: "test", workspace: "$DEST", install_service: false, claude_cli: "claude"}
docker: {image_tag: "agent-admin:notice-e2e", uid: $(id -u), gid: $(id -g), state_volume: "${AGENT_NAME}-state", base_image: "alpine:3.20"}
claude: {config_dir: "/home/agent/.claude", profile_new: true}
notifications: {channel: none}
features:
  heartbeat: {enabled: true, interval: "30m", timeout: 30, retries: 0, default_prompt: "echo pong"}
  upgrade_notice: {enabled: true}
mcps: {defaults: [], atlassian: [], github: {enabled: false, email: ""}}
vault:
  enabled: true
  path: .state/.vault
  seed_skeleton: true
  initial_sources: []
  mcp: {enabled: false, server: vault}
  qmd: {enabled: false}
  wiki_graph: {enabled: false}
  schema:
    frontmatter_required: true
    log_format: "## [{date}] {op} | {title}"
plugins: []
YML
  cp -R "$REPO_ROOT/modules" "$REPO_ROOT/scripts" "$REPO_ROOT/docker" "$DEST/"
  cp "$REPO_ROOT/setup.sh" "$DEST/"
  chmod +x "$DEST/setup.sh"
  (cd "$DEST" && ./setup.sh --regenerate --non-interactive)

  # compose requires the workspace env file to exist; it stays empty (nothing here needs a secret)
  touch "$DEST/.env"
  chmod 0600 "$DEST/.env"

  mkdir -p "$DEST/bin"
  cat > "$DEST/bin/claude" <<'CL'
#!/bin/bash
# notice e2e stub: sleep forever so the watchdog stops respawning
exec sleep 86400
CL
  chmod +x "$DEST/bin/claude"
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
}

# _seed_vault INTEGRATED(true|false): an already-populated vault from BEFORE 0.27.0. The boot's
# additive upgrade (vault_seed_missing) deposits the 0.27.0 delta into it - exactly what happened
# to donna and linus. With INTEGRATED=true the vault's own CLAUDE.md already carries the
# checkpoint, as if the agent had integrated the delta.
_seed_vault() {
  local integrated="$1" v="$DEST/.state/.vault"
  mkdir -p "$v/wiki/entities" "$v/wiki/normalization" "$v/_templates" "$v/raw_sources"
  {
    printf '# Vault schema (owned by the agent)\n\n'
    printf '## Normalization rules (`wiki/normalization/`)\n\nWriting rules live there.\n'
    if [ "$integrated" = "true" ]; then
      printf '\n## Actionability (PARA)\n\nIntegrated by the agent.\n'
    fi
  } > "$v/CLAUDE.md"
  printf -- '---\ntype: entity\ncreated: 2026-01-01\nupdated: 2026-01-01\nstatus: active\n---\n# Existing page\n' > "$v/wiki/entities/existing.md"
  printf '# log\n' > "$v/log.md"
  printf '# index\n' > "$v/index.md"
}

# _up: build, start, and wait until the boot is done (the vault symlink is boot_side_effects' last
# step) AND the hook is registered. Dumps the container log if it never gets there.
_up() {
  (cd "$DEST" && docker compose build)
  (cd "$DEST" && docker compose up -d)
  _wait_boot 120 || { _dump; return 1; }
}

_wait_boot() {
  local deadline=$(( $(date +%s) + ${1:-120} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if in_container sh -c '[ -L /home/agent/vault ] && jq -e ".hooks.SessionStart[0].hooks[0].command" /home/agent/.claude/settings.json >/dev/null 2>&1' 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

_dump() {
  echo "--- container logs ---" >&2
  (cd "$DEST" && docker compose logs --tail=120 2>&1) >&2 || true
  echo "--- settings.json inside the container ---" >&2
  in_container cat /home/agent/.claude/settings.json >&2 || true
}

# ---- E1: the real boot registers the hook, and it reports the delta the boot just deposited -------

@test "E2E 038 E1: the boot registers the SessionStart hook and the hook reports the delta the boot deposited" {
  _scaffold
  _seed_vault false
  _up

  # registered exactly once, at the workspace path the container sees
  run in_container jq -r '.hooks.SessionStart | length' /home/agent/.claude/settings.json
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run in_container jq -r '.hooks.SessionStart[0].hooks[0].command' /home/agent/.claude/settings.json
  [ "$output" = "/workspace/scripts/hooks/upgrade-notice.sh" ]
  run in_container jq -r '.hooks.SessionStart[0].hooks[0].timeout' /home/agent/.claude/settings.json
  [ "$output" = "10" ]
  run in_container jq '.hooks.SessionStart[0] | has("matcher")' /home/agent/.claude/settings.json
  [ "$output" = "false" ]

  # the libraries the hook sources are present in the workspace the container mounts
  in_container test -f /workspace/scripts/lib/vault.sh
  in_container test -f /workspace/scripts/lib/claude_md.sh

  # the boot's own additive upgrade produced the pending state (marker deposited, checkpoint absent)
  in_container test -f /home/agent/.vault/_templates/.schema-updates-0.27.0.applied

  # the hook, run as the agent on the image's own toolchain, tells it so
  run in_container sh -c '/workspace/scripts/hooks/upgrade-notice.sh < /dev/null'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "SessionStart" ]
  local ctx
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"Vault schema delta 0.27.0: read /home/agent/.vault/_templates/schema-updates-0.27.0.md"* ]]
  [[ "$ctx" == *"## Actionability (PARA)"* ]]
  # 0.8.0 is integrated in this vault (its checkpoint is in CLAUDE.md), so it must NOT be listed
  [[ "$ctx" != *"Vault schema delta 0.8.0"* ]]
  # the workspace layer is in sync (regenerate rendered CLAUDE.md and its baseline on the host)
  [[ "$ctx" != *"workspace CLAUDE.md"* ]]
}

# ---- E2: every boot re-registers it (self-healing) and never duplicates --------------------------

@test "E2E 038 E2: after a restart the hook is registered again, once (the boot re-installs it)" {
  _scaffold
  _seed_vault false
  _up

  # remove the entry: if it reappears, the BOOT put it back (it is not a leftover of the first run)
  in_container sh -c 'jq "del(.hooks.SessionStart)" /home/agent/.claude/settings.json > /tmp/s.json && cp /tmp/s.json /home/agent/.claude/settings.json'
  run in_container jq '(.hooks.SessionStart // []) | length' /home/agent/.claude/settings.json
  [ "$output" = "0" ]

  (cd "$DEST" && docker compose restart)
  _wait_boot 120 || { _dump; false; }

  run in_container jq '.hooks.SessionStart | length' /home/agent/.claude/settings.json
  [ "$output" = "1" ]
  run in_container jq -r '.hooks.SessionStart[0].hooks[0].command' /home/agent/.claude/settings.json
  [ "$output" = "/workspace/scripts/hooks/upgrade-notice.sh" ]

  # a second restart, this time WITH the entry in place, must not duplicate it
  (cd "$DEST" && docker compose restart)
  _wait_boot 120 || { _dump; false; }
  run in_container jq '.hooks.SessionStart | length' /home/agent/.claude/settings.json
  [ "$output" = "1" ]
}

# ---- E3: nothing pending means zero bytes --------------------------------------------------------

@test "E2E 038 E3: with the delta already integrated and CLAUDE.md in sync, the hook prints nothing" {
  _scaffold
  _seed_vault true
  _up

  in_container test -f /home/agent/.vault/_templates/.schema-updates-0.27.0.applied   # deposited, but integrated
  run in_container sh -c '/workspace/scripts/hooks/upgrade-notice.sh < /dev/null; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [ "$output" = "rc=0" ]            # no bytes before the rc line: nothing was printed
}

# ---- E4: heartbeat ticks never get it ------------------------------------------------------------

@test "E2E 038 E4: the heartbeat's isolated settings.json (built from the real one) has no SessionStart hook" {
  _scaffold
  _seed_vault false
  _up

  # the interactive config HAS it (E1) ...
  run in_container jq '.hooks | has("SessionStart")' /home/agent/.claude/settings.json
  [ "$output" = "true" ]
  # ... and the function heartbeat.sh uses to build the cron tick's config drops it, in the container
  run in_container bash -c 'awk "/^ensure_heartbeat_config_dir\(\) \{\$/,/^\}\$/" /workspace/scripts/heartbeat/heartbeat.sh > /tmp/fn.sh && . /tmp/fn.sh && ensure_heartbeat_config_dir'
  [ "$status" -eq 0 ]
  local iso="$output"
  [ -n "$iso" ]
  run in_container jq '(.hooks // {}) | has("SessionStart")' "$iso/settings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}
