#!/usr/bin/env bats
# 012-local-vault-rag (US1, FR-001): in local mode, scaffold/regenerate seeds the
# vault skeleton host-side under <ws>/<vault.path> (NO /home/agent rebase) via the
# existing vault.sh lib, honoring seed_skeleton + force_reseed. Closes the 011
# FR-004 spec-vs-code gap. Host-runnable, no systemd.

load helper

setup() {
  setup_tmp_dir
  load_lib yaml
  yaml_require_yq >/dev/null
  command -v jq >/dev/null || skip "jq not installed"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/VERSION" "$TMP_TEST_DIR/" 2>/dev/null || true
  touch "$TMP_TEST_DIR/.env"
  mkdir -p "$TMP_TEST_DIR/.state"
}

teardown() { teardown_tmp_dir; }

# Seed a minimal local-mode agent.yml. Args: vault_enabled seed_skeleton [path] [force_reseed]
_seed() {
  local enabled="$1" seed="$2" path="${3:-.state/.vault}" force="${4:-false}"
  cat > "$TMP_TEST_DIR/agent.yml" << YML
version: 1
agent: {name: locbot, display_name: "L", role: "r", vibe: "v"}
user: {name: A, nickname: A, timezone: UTC, email: a@b.com, language: en}
deployment: {host: rpi5, workspace: "$TMP_TEST_DIR", install_service: false, claude_cli: claude, mode: local}
docker: {image_tag: "x:latest", uid: 1000, gid: 1000, base_image: "alpine:3.20"}
notifications: {channel: none}
features: {heartbeat: {enabled: false, interval: "30m", timeout: 300, retries: 1, default_prompt: "ok"}}
vault:
  enabled: $enabled
  seed_skeleton: $seed
  path: $path
  force_reseed: $force
YML
}

_regen() { ( cd "$TMP_TEST_DIR" && echo 'n' | ./setup.sh --regenerate ); }

@test "local regenerate seeds the skeleton under <ws>/.state/.vault (no /home/agent)" {
  _seed true true
  run _regen
  [ "$status" -eq 0 ]
  [ -f "$TMP_TEST_DIR/.state/.vault/CLAUDE.md" ]
  [ -f "$TMP_TEST_DIR/.state/.vault/index.md" ]
  [ -d "$TMP_TEST_DIR/.state/.vault/wiki/concepts" ]
  [ -f "$TMP_TEST_DIR/.state/.vault/_templates/summary.md" ]
  # never rebased under /home/agent on the host
  [ ! -d "/home/agent/.vault" ] || true
}

@test "local seed is idempotent — a populated vault is left untouched" {
  _seed true true
  _regen
  echo "USER EDIT" > "$TMP_TEST_DIR/.state/.vault/index.md"
  run _regen
  [ "$status" -eq 0 ]
  grep -q 'USER EDIT' "$TMP_TEST_DIR/.state/.vault/index.md"
}

@test "vault.enabled=false seeds nothing (no vault dir created)" {
  _seed false true
  run _regen
  [ "$status" -eq 0 ]
  [ ! -d "$TMP_TEST_DIR/.state/.vault" ]
}

@test "custom vault.path is resolved under the workspace, not rebased" {
  _seed true true ".state/notes/wiki"
  run _regen
  [ "$status" -eq 0 ]
  [ -f "$TMP_TEST_DIR/.state/notes/wiki/CLAUDE.md" ]
}

@test "regenerate renders the qmd entrypoint+wrapper and re-renders on a 2nd pass (FR-011/G1)" {
  cat > "$TMP_TEST_DIR/agent.yml" << YML
version: 1
agent: {name: locbot, display_name: "L", role: "r", vibe: "v"}
user: {name: A, nickname: A, timezone: UTC, email: a@b.com, language: en}
deployment: {host: rpi5, workspace: "$TMP_TEST_DIR", install_service: false, claude_cli: claude, mode: local}
docker: {image_tag: "x:latest", uid: 1000, gid: 1000, base_image: "alpine:3.20"}
notifications: {channel: none}
features: {heartbeat: {enabled: false, interval: "30m", timeout: 300, retries: 1, default_prompt: "ok"}}
vault:
  enabled: true
  seed_skeleton: true
  path: .state/.vault
  qmd: {enabled: true, version: "2.5.3", schedule: "*/5 * * * *"}
YML
  _regen
  [ -x "$TMP_TEST_DIR/scripts/local/agent-qmd-reindex.sh" ]
  [ -x "$TMP_TEST_DIR/scripts/local/agent-qmd-watch.sh" ]
  # the entrypoint bakes the workspace-durable cache path
  grep -q "QMD_CACHE_HOME=\"\${WORKSPACE}/.state/.cache/qmd\"" "$TMP_TEST_DIR/scripts/local/agent-qmd-reindex.sh"
  # survives regenerate: remove it, regen again, it comes back (FR-011)
  rm -f "$TMP_TEST_DIR/scripts/local/agent-qmd-reindex.sh"
  _regen
  [ -x "$TMP_TEST_DIR/scripts/local/agent-qmd-reindex.sh" ]
}

@test "regenerate with qmd disabled renders NO qmd entrypoint (cero costo cruzado, FR-010)" {
  _seed true true      # vault on, qmd absent → disabled
  _regen
  [ ! -f "$TMP_TEST_DIR/scripts/local/agent-qmd-reindex.sh" ]
  [ ! -f "$TMP_TEST_DIR/scripts/local/agent-qmd-watch.sh" ]
}

@test "force_reseed backs up the old vault, re-seeds, and resets the flag" {
  _seed true true         # seed once (force_reseed=false)
  _regen
  echo "OLD" > "$TMP_TEST_DIR/.state/.vault/index.md"
  # flip force_reseed ON, then regen a POPULATED vault → backup + reseed + reset
  yq -i '.vault.force_reseed = true' "$TMP_TEST_DIR/agent.yml"
  run _regen
  [ "$status" -eq 0 ]
  # fresh skeleton (the OLD content moved aside, not in the live vault)
  ! grep -q '^OLD$' "$TMP_TEST_DIR/.state/.vault/index.md"
  # a backup dir exists
  ls -d "$TMP_TEST_DIR"/.state/.vault.backup-* >/dev/null 2>&1
  # flag auto-reset to false in agent.yml
  [ "$(yq -r '.vault.force_reseed' "$TMP_TEST_DIR/agent.yml")" = "false" ]
}
