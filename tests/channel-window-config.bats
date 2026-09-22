#!/usr/bin/env bats
#
# 036 US2 — docker.channel_health_timeout_s: the channel-health window becomes a
# field of agent.yml (the single source of truth) instead of a key the operator
# hand-writes into the workspace .env.
#
# Why this is more than a convenience. Feature 026 made the window tunable via
# the CHANNEL_HEALTH_TIMEOUT env var, delivered through compose's `env_file:`.
# Rendering the same key into `environment:` makes the rendered value WIN, so a
# backfill that wrote a flat 60 would silently downgrade every agent that
# followed the documentation — `donna` runs at 120 — and would re-create the
# cold-cache + many-MCP + short-window combination behind the 25-minute outage
# this feature exists to prevent. Hence the backfill MIGRATES the live value
# instead of resetting it, and the migration oracle below is the load-bearing
# test of this story.
#
# Mould: tests/mcp-handshake-timeout.bats (029). Contract:
# specs/036-cold-start-boot-resilience/contracts/channel-window-config.md
#
# Every negative assertion goes through `run … ; [ "$output" = "0" ]` on a count,
# never a bare intermediate `grep -q`: bats runs each body under errexit, so an
# intermediate pipeline that returns 1 aborts the test instead of failing it
# (measured in 033, which repaired six such dead negatives).

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  touch "$TMP_TEST_DIR/.env"
  CLAUDE_STUB=$(install_claude_stub)
}

teardown() { teardown_tmp_dir; }

# CANON-C2, verbatim from data-model §1. Kept in one place so no oracle can
# paraphrase it (the failure mode this convention exists to prevent).
CANON_C2='NOTE: CHANNEL_HEALTH_TIMEOUT from the workspace .env was migrated into agent.yml (docker.channel_health_timeout_s); docker-compose.yml now renders it and the rendered value wins — you can remove the .env line'
CANON_C2_PREFIX='NOTE: CHANNEL_HEALTH_TIMEOUT from the workspace .env was migrated'

# Minimal schema-valid docker-mode agent.yml. $1 controls
# docker.channel_health_timeout_s: a value → emit it; OMIT → no field (the
# pre-036 workspace); NULL → present but empty.
_write_agent_yml() {
  local cht="$1"
  local docker_block='docker:
  image_tag: "agentic-pod:latest"
  uid: 1000
  gid: 1000
  base_image: "alpine:3.20"'
  case "$cht" in
    OMIT) : ;;
    NULL) docker_block="${docker_block}
  channel_health_timeout_s:" ;;
    *)    docker_block="${docker_block}
  channel_health_timeout_s: ${cht}" ;;
  esac
  cat > "$TMP_TEST_DIR/agent.yml" << EOF
version: 1
agent:
  name: cw-bot
  display_name: "CW"
  role: "r"
  vibe: "v"
  use_default_principles: true
user:
  name: "A"
  nickname: "A"
  timezone: "UTC"
  email: "a@b.com"
  language: "en"
deployment:
  host: "h"
  workspace: "/tmp/cw-bot"
  install_service: false
  mode: docker
${docker_block}
claude:
  config_dir: "/home/agent/.claude"
  profile_new: true
  mcp_timeout_ms: 120000
notifications:
  channel: none
features:
  heartbeat:
    enabled: true
    interval: "30m"
    timeout: 300
    retries: 1
    default_prompt: "ok"
mcps:
  atlassian: []
  github:
    enabled: false
plugins:
  - telegram@claude-plugins-official
EOF
}

# The workspace .env is a SECOND parameter of every US2 test, not scenery: the
# backfill reads it. OMIT → no key; EMPTY → key present with no value; else the
# value. A test that sets one axis without deciding the other is under-specified.
# Write literal lines, verbatim, for the shape-tolerance cases — _write_env
# builds a canonical `KEY=value`, which is the one shape that was never in
# doubt.
_write_env_raw() {
  : > "$TMP_TEST_DIR/.env"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$TMP_TEST_DIR/.env"; done
  chmod 0600 "$TMP_TEST_DIR/.env"
}

_write_env() {
  local v="${1:-OMIT}"
  : > "$TMP_TEST_DIR/.env"
  case "$v" in
    OMIT)  : ;;
    EMPTY) printf 'CHANNEL_HEALTH_TIMEOUT=\n' >> "$TMP_TEST_DIR/.env" ;;
    *)     printf 'CHANNEL_HEALTH_TIMEOUT=%s\n' "$v" >> "$TMP_TEST_DIR/.env" ;;
  esac
  chmod 0600 "$TMP_TEST_DIR/.env"
}

# Run --regenerate capturing stdout+stderr into a file, because `run` clobbers
# $output on the next call and several oracles need to grep the same capture
# twice (C10's shape).
_regen_capture() {
  run env bash -c "echo n | ./setup.sh --regenerate 2>&1"
  printf '%s\n' "$output" > "$TMP_TEST_DIR/regen-out.txt"
}

# ══ C5 — rendered delivery ═══════════════════════════════════════════════════

@test "036 US2: a valid channel_health_timeout_s renders CANON-C1 into compose environment" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml 120
  _write_env
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*CHANNEL_HEALTH_TIMEOUT: "120"$' docker-compose.yml
}

@test "036 US2: the compose template uses the placeholder and never a literal default" {
  run bash -c "LC_ALL=C grep -cF 'CHANNEL_HEALTH_TIMEOUT: \"{{DOCKER_CHANNEL_HEALTH_TIMEOUT_S}}\"' '$REPO_ROOT/modules/docker-compose.yml.tpl'"
  [ "$output" = "1" ]
  # The 60 default lives in exactly two places by design — the host sanitiser and
  # the container reader — and the template is neither.
  run bash -c "LC_ALL=C grep -cF 'CHANNEL_HEALTH_TIMEOUT: \"60\"' '$REPO_ROOT/modules/docker-compose.yml.tpl'"
  [ "$output" = "0" ]
}

# ══ C3a — the sanitisation matrix ════════════════════════════════════════════
#
# The sanitiser degrades the ARTIFACT, never the source of truth: each of these
# also asserts agent.yml still holds what the operator typed.

@test "036 US2: non-numeric channel_health_timeout_s degrades to 60 in the artifact" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml '"abc"'
  _write_env
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*CHANNEL_HEALTH_TIMEOUT: "60"$' docker-compose.yml
  [ "$(yq -r '.docker.channel_health_timeout_s' agent.yml)" = "abc" ]
}

@test "036 US2: channel_health_timeout_s=0 degrades to 60 in the artifact (never <=0)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml 0
  _write_env
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*CHANNEL_HEALTH_TIMEOUT: "60"$' docker-compose.yml
  [ "$(yq -r '.docker.channel_health_timeout_s' agent.yml)" = "0" ]
}

@test "036 US2: a negative channel_health_timeout_s degrades to 60" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml -5
  _write_env
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*CHANNEL_HEALTH_TIMEOUT: "60"$' docker-compose.yml
}

@test "036 US2: an empty channel_health_timeout_s degrades to 60 and stays empty in agent.yml" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml NULL
  _write_env
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*CHANNEL_HEALTH_TIMEOUT: "60"$' docker-compose.yml
  # has(), not `//`: a present-but-empty value is the operator's, and the
  # backfill must leave it alone even though the render degrades it.
  [ "$(yq -r '.docker | has("channel_health_timeout_s")' agent.yml)" = "true" ]
  # Asserted by TAG, not by the printed value. `yq -r` on an explicit YAML null
  # prints the empty string, not the word "null" — verified in both versions CI
  # actually runs (4.44.3 on ubuntu, 4.52.5 on macOS), which is the check that
  # matters here: a value-formatting oracle is exactly the version-dependent
  # shape that turned the suite red on 2026-09-21. The tag agrees across both.
  [ "$(yq -r '.docker.channel_health_timeout_s | tag' agent.yml)" = "!!null" ]
}

@test "036 US2: a fractional channel_health_timeout_s degrades to 60" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml 1.5
  _write_env
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*CHANNEL_HEALTH_TIMEOUT: "60"$' docker-compose.yml
}

@test "036 US2: 999999 is accepted (6-digit boundary) but 1234567 degrades to 60" {
  cd "$TMP_TEST_DIR"
  # The bound is 6 digits, NARROWER than the 029 mould's 7, so that the host
  # sanitiser and the in-container reader (start_services.sh) agree on what
  # "implausibly large" means. This is the one row where 036 inverts 029.
  _write_agent_yml 999999
  _write_env
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*CHANNEL_HEALTH_TIMEOUT: "999999"$' docker-compose.yml

  _write_agent_yml 1234567
  echo 'n' | ./setup.sh --regenerate
  grep -qE '^[[:space:]]*CHANNEL_HEALTH_TIMEOUT: "60"$' docker-compose.yml
}

# ══ C6 — the backfill, which MIGRATES rather than resets ═════════════════════

@test "036 US2: a pre-036 workspace with no .env key is backfilled to 60" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml OMIT
  _write_env
  [ "$(yq -r '.docker | has("channel_health_timeout_s")' agent.yml)" = "false" ]
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.docker.channel_health_timeout_s' agent.yml)" = "60" ]
  grep -qE '^[[:space:]]*CHANNEL_HEALTH_TIMEOUT: "60"$' docker-compose.yml
}

@test "036 US2: MIGRATION — a hand-set .env value moves into agent.yml and keeps taking effect" {
  cd "$TMP_TEST_DIR"
  # THE load-bearing test of US2. Before this feature the operator's only knob
  # was the .env, and the docs said so. Once CANON-C1 renders into
  # `environment:`, which outranks `env_file:`, a flat-60 backfill would cut
  # donna's window from 120 to 60 without a word.
  _write_agent_yml OMIT
  _write_env 120
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.docker.channel_health_timeout_s' agent.yml)" = "120" ]
  grep -qE '^[[:space:]]*CHANNEL_HEALTH_TIMEOUT: "120"$' docker-compose.yml
}

@test "036 US2: a junk .env value is not migrated — the seed goes through the same sanitiser" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml OMIT
  _write_env abc
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.docker.channel_health_timeout_s' agent.yml)" = "60" ]
}

@test "036 US2: a 7-digit .env value is not migrated (the container already degraded it)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml OMIT
  _write_env 1234567
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.docker.channel_health_timeout_s' agent.yml)" = "60" ]
}

@test "036 US2: the backfill never overwrites an operator's 0 (has(), not //)" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml 0
  _write_env 120
  echo 'n' | ./setup.sh --regenerate
  # The field is present, so the backfill must not run at all — not even to
  # migrate. `//` instead of has() would collapse the 0 and adopt the .env value.
  [ "$(yq -r '.docker.channel_health_timeout_s' agent.yml)" = "0" ]
}

# ══ C7 — idempotency ═════════════════════════════════════════════════════════

@test "036 US2: two --regenerate passes are byte-stable for the field and the artifact" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml OMIT
  _write_env 120
  echo 'n' | ./setup.sh --regenerate
  yq 'del(.meta.regenerated_at)' agent.yml > pass1.yml
  cp docker-compose.yml pass1-compose.yml
  echo 'n' | ./setup.sh --regenerate
  yq 'del(.meta.regenerated_at)' agent.yml > pass2.yml
  diff -q pass1.yml pass2.yml
  diff -q pass1-compose.yml docker-compose.yml
}

# ══ C9/C10 — the migration notice, and it never leaks the value ══════════════

@test "036 US2: CANON-C2 prints exactly once on migration, and the value never appears" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml OMIT
  _write_env 987654          # 6 digits: a value the migration accepts
  _regen_capture
  [ "$status" -eq 0 ]

  run bash -c "grep -cF '$CANON_C2_PREFIX' '$TMP_TEST_DIR/regen-out.txt'"
  [ "$output" = "1" ]

  # The notice names the key and nothing else. After migration the digits
  # legitimately appear in agent.yml and docker-compose.yml — that is the
  # feature working — so the check is scoped to the process output.
  run bash -c "grep -cF '987654' '$TMP_TEST_DIR/regen-out.txt'"
  [ "$output" = "0" ]
}

@test "036 US2: the notice is CANON-C2 verbatim, not a paraphrase" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml OMIT
  _write_env 120
  _regen_capture
  CANON_C2="$CANON_C2" run bash -c 'grep -cFx "$CANON_C2" "$1"' _ "$TMP_TEST_DIR/regen-out.txt"
  [ "$output" = "1" ]
}

@test "036 US2: the notice still fires when agent.yml already wins over a .env line" {
  cd "$TMP_TEST_DIR"
  # Named residual of C9: no migration happens in this run (the field is
  # present), but the .env line is still the leftover the operator should
  # delete, and the rendered value is what takes effect.
  _write_agent_yml 60
  _write_env 120
  _regen_capture
  grep -qE '^[[:space:]]*CHANNEL_HEALTH_TIMEOUT: "60"$' docker-compose.yml
  run bash -c "grep -cF '$CANON_C2_PREFIX' '$TMP_TEST_DIR/regen-out.txt'"
  [ "$output" = "1" ]
}

# ══ The shapes an operator actually wrote, because the docs told them to ═════
#
# MEASURED against real Compose (value echoed from inside a container fed by
# `env_file:`): all six below hand the container `120` today. The strict
# `env_file_get` — correct for its own job, which is delivering secrets —
# rejects or misreads four of them, so using it for the MIGRATION would cut a
# live agent from 120 to 60. Worse, for the indented and `export` shapes the
# NOTICE keys off the same read, so it would not fire either: a silent
# downgrade, which is precisely what the migration exists to prevent. Read the
# key the way the thing that consumed it reads it.

@test "036 US2: migration accepts every .env shape Compose accepts" {
  cd "$TMP_TEST_DIR"
  local shape
  for shape in 'CHANNEL_HEALTH_TIMEOUT=120' \
               'CHANNEL_HEALTH_TIMEOUT=120 ' \
               '  CHANNEL_HEALTH_TIMEOUT=120' \
               'export CHANNEL_HEALTH_TIMEOUT=120' \
               'CHANNEL_HEALTH_TIMEOUT=120 # slow host' \
               'CHANNEL_HEALTH_TIMEOUT="120"'; do
    _write_agent_yml OMIT
    _write_env_raw "$shape"
    echo 'n' | ./setup.sh --regenerate >/dev/null 2>&1
    [ "$(yq -r '.docker.channel_health_timeout_s' agent.yml)" = "120" ] \
      || { echo "shape not migrated: [$shape]" >&2; false; }
    grep -qE '^[[:space:]]*CHANNEL_HEALTH_TIMEOUT: "120"$' docker-compose.yml \
      || { echo "shape not rendered: [$shape]" >&2; false; }
  done
}

@test "036 US2: a foreign key is still not mistaken for the window" {
  cd "$TMP_TEST_DIR"
  # The tolerant reader must not become a loose one: an unrelated key, and one
  # that merely ends in the right name, are both non-matches.
  _write_agent_yml OMIT
  _write_env_raw 'SOMETHING_ELSE=120' 'MY_CHANNEL_HEALTH_TIMEOUT=999'
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.docker.channel_health_timeout_s' agent.yml)" = "60" ]
}

# ══ C11 — the cases that must stay silent ════════════════════════════════════

@test "036 US2: no notice when the .env has no CHANNEL_HEALTH_TIMEOUT key" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml OMIT
  _write_env
  _regen_capture
  run bash -c "grep -cF '$CANON_C2_PREFIX' '$TMP_TEST_DIR/regen-out.txt'"
  [ "$output" = "0" ]
}

@test "036 US2: no notice when there is no .env at all" {
  cd "$TMP_TEST_DIR"
  _write_agent_yml OMIT
  rm -f "$TMP_TEST_DIR/.env"
  _regen_capture
  run bash -c "grep -cF '$CANON_C2_PREFIX' '$TMP_TEST_DIR/regen-out.txt'"
  [ "$output" = "0" ]
}

@test "036 US2: no notice when the key is present but empty" {
  cd "$TMP_TEST_DIR"
  # Documented limitation, not an oversight: env_file_get returns the same empty
  # string for "absent" and "present but empty" (021 FR-005). Silence is right
  # anyway — an empty value already degrades to 60 inside the container, which
  # is exactly what the backfill seeds, so nothing about the agent changes.
  _write_agent_yml OMIT
  _write_env EMPTY
  _regen_capture
  run bash -c "grep -cF '$CANON_C2_PREFIX' '$TMP_TEST_DIR/regen-out.txt'"
  [ "$output" = "0" ]
  [ "$(yq -r '.docker.channel_health_timeout_s' agent.yml)" = "60" ]
}

# ══ C1 — no wizard prompt was added ══════════════════════════════════════════

@test "036 US2: no wizard prompt is added for the field" {
  run bash -c "LC_ALL=C grep -lF 'channel_health_timeout' '$REPO_ROOT/scripts/lib/wizard.sh' '$REPO_ROOT/scripts/lib/wizard-gum.sh' 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

# ══ C2 — new scaffolds carry the field, at the right nesting level ═══════════

@test "036 US2: the agent.yml heredoc places the field outside toolchain_channels" {
  # Placement is load-bearing: $docker_yaml ends with the nested
  # toolchain_channels mapping, so a line appended at the end would be parsed as
  # its child. This oracle reads the heredoc's own text, because the wizard path
  # that emits it is not exercised here.
  run bash -c "LC_ALL=C grep -cE '^  channel_health_timeout_s: 60$' '$REPO_ROOT/setup.sh'"
  [ "$output" = "1" ]
  # And it comes BEFORE the nested block, not after.
  run bash -c "cht=\$(grep -nE '^  channel_health_timeout_s: 60\$' '$REPO_ROOT/setup.sh' | head -1 | cut -d: -f1); tc=\$(grep -nE '^  toolchain_channels:\$' '$REPO_ROOT/setup.sh' | head -1 | cut -d: -f1); [ -n \"\$cht\" ] && [ -n \"\$tc\" ] && [ \"\$cht\" -lt \"\$tc\" ] && echo before || echo after"
  [ "$output" = "before" ]
}

# ══ C17 — the docs stop pointing at the losing channel ═══════════════════════

@test "036 US2: README and architecture.md name the agent.yml field" {
  run bash -c "LC_ALL=C grep -lF 'channel_health_timeout_s' '$REPO_ROOT/README.md' '$REPO_ROOT/docs/architecture.md' 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "2" ]
}

@test "036 US2: neither doc still presents the workspace .env as the place to set it" {
  run bash -c "LC_ALL=C grep -lF '(seconds) in the workspace' '$REPO_ROOT/README.md' '$REPO_ROOT/docs/architecture.md' 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}
