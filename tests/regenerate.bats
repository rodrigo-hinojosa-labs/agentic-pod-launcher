#!/usr/bin/env bats

load helper

setup() {
  setup_tmp_dir
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  cat > "$TMP_TEST_DIR/agent.yml" << 'EOF'
version: 1
agent:
  name: regen-bot
  display_name: "RegenBot"
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
  workspace: "/tmp/regen-bot"
  install_service: false
docker:
  image_tag: "agent-admin:latest"
  uid: 1000
  gid: 1000
  base_image: "alpine:3.20"
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
vault:
  enabled: true
  path: .state/.vault
  seed_skeleton: true
  mcp:
    enabled: true
    server: vault
plugins:
  - claude-mem@thedotmack
EOF
  touch "$TMP_TEST_DIR/.env"
  # 025: only the deployment.mode=local test below needs a resolvable
  # claude_cli (resolve_claude_bin only gates local mode); seed a
  # deterministic stub so that test doesn't depend on the host's claude/PATH.
  CLAUDE_STUB=$(install_claude_stub)
}

teardown() { teardown_tmp_dir; }

@test "--regenerate produces expected files" {
  cd "$TMP_TEST_DIR"
  # Pipe 'n' to the plugin prompt so we skip actual plugin install
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  [ -f CLAUDE.md ]
  [ -f .mcp.json ]
  [ -f .env.example ]
  [ -f scripts/heartbeat/heartbeat.conf ]
  grep -q "RegenBot" CLAUDE.md
  jq . .mcp.json > /dev/null
}

@test "--regenerate preserves existing CLAUDE.md" {
  cd "$TMP_TEST_DIR"
  echo 'n' | ./setup.sh --regenerate
  echo "USER EDIT" >> CLAUDE.md
  echo 'n' | ./setup.sh --regenerate
  grep -q "USER EDIT" CLAUDE.md
}

@test "--regenerate is idempotent" {
  cd "$TMP_TEST_DIR"
  echo 'n' | ./setup.sh --regenerate
  cp .mcp.json .mcp.json.first
  echo 'n' | ./setup.sh --regenerate
  diff .mcp.json .mcp.json.first
}

@test "--regenerate emits vault MCP and Vault row in CLAUDE.md when vault.enabled" {
  cd "$TMP_TEST_DIR"
  echo 'n' | ./setup.sh --regenerate
  [ -f .mcp.json ]
  [ -f CLAUDE.md ]
  jq -e '.mcpServers.vault' .mcp.json > /dev/null
  [ "$(jq -r '.mcpServers.vault.args[1]' .mcp.json)" = "@bitbonsai/mcpvault@0.12.0" ]
  grep -q "Vault" CLAUDE.md
  grep -q "Karpathy" CLAUDE.md
}

@test "--regenerate backfills vault.qmd.version and renders a valid qmd pin (pre-010 upgrade)" {
  cd "$TMP_TEST_DIR"
  # Simulate a pre-010 workspace that opted into QMD before the version pin
  # existed: enabled=true, no version key. The regenerate path must backfill
  # the floor into agent.yml — the single source the runtime wrapper reads the
  # pin from (contracts/agent-yml-schema.md; agent.yml as single source).
  # Post-016/T036 the pin no longer flows into .mcp.json args: the qmd entry
  # renders the per-mode wrapper (QMD_MCP_COMMAND) with EMPTY args, and the
  # wrapper resolves the version from agent.yml at runtime (qmd_pkg). This
  # seed workspace backfills deployment.mode=docker → docker wrapper path.
  # See specs/019-fix-qmd-test-drift/contracts/qmd-test-seam.md (anti-patterns).
  yq -i '.vault.qmd.enabled = true' agent.yml
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.vault.qmd.version' agent.yml)" = "2.5.3" ]
  [ "$(jq -r '.mcpServers.qmd.command' .mcp.json)" = "/opt/agent-admin/scripts/qmd-mcp" ]
  [ "$(jq '.mcpServers.qmd.args | length' .mcp.json)" = "0" ]
}

@test "--non-interactive regenerate skips plugin prompt" {
  cd "$TMP_TEST_DIR"
  run ./setup.sh --non-interactive
  [ "$status" -eq 0 ]
  [ -f .mcp.json ]
}

@test "--regenerate backfills deployment.mode=docker when absent (legacy workspace)" {
  cd "$TMP_TEST_DIR"
  # The seed agent.yml has no deployment.mode (pre-011 workspace). regenerate
  # must write the explicit default so the mode is deterministic going forward
  # (mirror of the vault.qmd.version backfill; agent.yml as single source).
  [ "$(yq -r '.deployment.mode' agent.yml)" = "null" ]
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.deployment.mode' agent.yml)" = "docker" ]
}

@test "--regenerate preserves an existing deployment.mode" {
  cd "$TMP_TEST_DIR"
  yq -i '.deployment.mode = "local"' agent.yml
  # 025: local mode resolves claude_cli (resolve_claude_bin); without a
  # deterministic stub this test only passed by accident on hosts with a
  # real claude installed (or ~/.local/bin/claude present).
  yq -i ".deployment.claude_cli = \"$CLAUDE_STUB\"" agent.yml
  echo 'n' | ./setup.sh --regenerate
  [ "$(yq -r '.deployment.mode' agent.yml)" = "local" ]
}

@test "--regenerate injects the role_file persona into CLAUDE.md (survives, content re-read)" {
  cd "$TMP_TEST_DIR"
  mkdir -p personas
  printf 'PERSONA_REGEN_MARKER multi-paragraph persona.\n\nSecond paragraph.\n' > personas/regen-bot.md
  yq -i '.agent.role_file = "personas/regen-bot.md"' agent.yml
  echo 'n' | ./setup.sh --regenerate
  # role_file path persists in agent.yml (single source of truth)…
  grep -q 'role_file:' agent.yml
  # …and its content is re-read into the rendered CLAUDE.md (FR-I1/FR-X1).
  grep -q "PERSONA_REGEN_MARKER" CLAUDE.md
}

# ── 027 US1: the scaffolded agent gets its OWN CLAUDE.md, not the launcher's ──
# The declarative method clones the launcher as the workspace, so the workspace
# CLAUDE.md is the launcher's own dev doc (force-committed; it carries a stable
# sentinel the agent template never emits). A local non-interactive render must
# replace that inherited doc with the AGENT's — no TTY, no --force-claude-md, no
# manual rm. A genuine operator agent doc (no sentinel) stays preserved, and
# docker mode is untouched (the discriminator is local-gated, FR-012).

# The exact sentinel _is_launcher_own_claude_md keys on.
_LAUNCHER_SENTINEL='This is **the launcher**, not an agent'

# Minimal faithful launcher-own CLAUDE.md fixture (framing + the sentinel).
_write_launcher_claude_md() {
  cat > "$TMP_TEST_DIR/CLAUDE.md" <<EOF
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

${_LAUNCHER_SENTINEL}. \`./setup.sh\` is a bash wizard that scaffolds a separate agent workspace.
EOF
}

@test "027 US1: local non-interactive render replaces the launcher's own CLAUDE.md with the agent's" {
  cd "$TMP_TEST_DIR"
  yq -i '.deployment.mode = "local"' agent.yml
  yq -i ".deployment.claude_cli = \"$CLAUDE_STUB\"" agent.yml
  _write_launcher_claude_md
  run ./setup.sh --non-interactive
  [ "$status" -eq 0 ]
  # the agent's own identity is now in CLAUDE.md …
  grep -q '## Identity' CLAUDE.md
  grep -q 'RegenBot' CLAUDE.md
  # … and the launcher sentinel is gone — with no prompt, no manual delete.
  ! grep -qF "$_LAUNCHER_SENTINEL" CLAUDE.md
}

@test "027 US1: a genuine operator CLAUDE.md (no sentinel) is preserved byte-for-byte (local --regenerate)" {
  cd "$TMP_TEST_DIR"
  yq -i '.deployment.mode = "local"' agent.yml
  yq -i ".deployment.claude_cli = \"$CLAUDE_STUB\"" agent.yml
  printf '# CLAUDE.md\n\n## Identity\nName: HandWritten\n\nOPERATOR_ONLY_MARKER\n' > CLAUDE.md
  cp CLAUDE.md CLAUDE.md.before
  echo 'n' | ./setup.sh --regenerate
  grep -q 'OPERATOR_ONLY_MARKER' CLAUDE.md
  cmp -s CLAUDE.md CLAUDE.md.before
}

@test "027 US1: docker mode preserves an inherited launcher CLAUDE.md (local gate, FR-012)" {
  cd "$TMP_TEST_DIR"
  # the seed agent.yml is docker mode; the discriminator must NOT fire here.
  _write_launcher_claude_md
  echo 'n' | ./setup.sh --regenerate
  grep -qF "$_LAUNCHER_SENTINEL" CLAUDE.md
}

# ── 027 US4: the declarative operator gets NEXT_STEPS guidance ────────────────
# NEXT_STEPS.md is produced only inside the interactive wizard today, so a
# non-interactive/declarative scaffold got none. regenerate() must render it as
# a derived file in local mode (docker regenerate stays byte-identical, FR-012),
# reusing the existing next-steps template + PLUGINS_BLOCK.

@test "027 US4: local --non-interactive renders NEXT_STEPS.md with the login + unit-install guidance" {
  cd "$TMP_TEST_DIR"
  yq -i '.deployment.mode = "local"' agent.yml
  yq -i ".deployment.claude_cli = \"$CLAUDE_STUB\"" agent.yml
  run ./setup.sh --non-interactive
  [ "$status" -eq 0 ]
  [ -f NEXT_STEPS.md ]
  grep -q './setup.sh --login' NEXT_STEPS.md
  grep -q 'agent-regen-bot.service' NEXT_STEPS.md
}

@test "027 US4: NEXT_STEPS.md is idempotent across a second --regenerate (local)" {
  cd "$TMP_TEST_DIR"
  yq -i '.deployment.mode = "local"' agent.yml
  yq -i ".deployment.claude_cli = \"$CLAUDE_STUB\"" agent.yml
  ./setup.sh --non-interactive
  cp NEXT_STEPS.md NEXT_STEPS.md.first
  echo 'n' | ./setup.sh --regenerate
  cmp -s NEXT_STEPS.md NEXT_STEPS.md.first
}

@test "027 US4: docker --regenerate does NOT create NEXT_STEPS.md (local gate, FR-012)" {
  cd "$TMP_TEST_DIR"
  # seed is docker mode; regenerate must not add NEXT_STEPS in docker.
  echo 'n' | ./setup.sh --regenerate
  [ ! -f NEXT_STEPS.md ]
}

@test "027 FR-012: docker --regenerate renders its files, no local bootstrap, .mcp.json byte-stable" {
  cd "$TMP_TEST_DIR"
  # docker-mode regenerate is untouched: it still renders CLAUDE.md/.mcp.json,
  # never the local provisioner (US2/US3 only touch local-bootstrap.sh.tpl), and
  # re-renders identically (US1/US4 are local-gated).
  echo 'n' | ./setup.sh --regenerate
  [ -f CLAUDE.md ]
  [ -f .mcp.json ]
  [ ! -f scripts/local/agent-bootstrap.sh ]
  [ ! -f NEXT_STEPS.md ]
  cp .mcp.json .mcp.json.first
  echo 'n' | ./setup.sh --regenerate
  cmp -s .mcp.json .mcp.json.first
}
