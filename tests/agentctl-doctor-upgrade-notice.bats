#!/usr/bin/env bats
#
# 038 - `agentctl doctor` shows the operator what an upgrade left behind, one line per
# layer, in BOTH modes:
#   vault      deltas deposited but not integrated (vault_pending_deltas)
#   workspace  CLAUDE.md fell behind the template (claude_md_state)
# A pending layer is a WARN with the exact remedy and it PERSISTS on every run until the
# state changes - there is no "already shown" marker (that belongs to the agent-facing hook's
# problem space, and the hook has none either). The detection never reads wiki-graph's cached
# findings (up to 6 h stale, 14 days of grace, and only knows 0.27.0): it reads the disk.
# Contract: specs/038-schema-delta-boot-nudge/contracts/upgrade-notice-hook.md section 6.

load helper

setup() {
  setup_tmp_dir
  export AGENTCTL_NO_RUN=1
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/agentctl"
  _doctor_fail_count=0
  _doctor_warn_count=0
  WS="$TMP_TEST_DIR/ws"
  V="$WS/vault"
  mkdir -p "$WS/scripts" "$V/_templates" "$WS/.state/launcher"
  cp -r "$REPO_ROOT/scripts/lib" "$WS/scripts/"
  printf '# vault CLAUDE.md\n' > "$V/CLAUDE.md"
  WC="$WS/CLAUDE.md"
  WU="$WS/.state/launcher/claude-md.upstream.md"
  WB="$WS/.state/launcher/claude-md.baseline.md"
}

teardown() { teardown_tmp_dir; }

# _deposit VERSION: marker + document, as the additive vault upgrade leaves them.
_deposit() {
  printf 'deposited: 2026-09-30\n' > "$V/_templates/.schema-updates-$1.applied"
  cp "$REPO_ROOT/modules/vault-deltas/schema-updates-$1.md" "$V/_templates/schema-updates-$1.md"
}

# _ws_state STATE: put C/U/B into one of the five states claude_md_state reports.
_ws_state() {
  rm -f "$WU" "$WB"
  case "$1" in
    in_sync)             printf 'template v2\n' > "$WU"; cp "$WU" "$WC"; cp "$WU" "$WB" ;;
    customized)          printf 'template v2\n' > "$WU"; printf 'template v2\nown paragraph\n' > "$WC"; cp "$WU" "$WB" ;;
    pending_template)    printf 'template v2\n' > "$WU"; printf 'template v1\n' > "$WC"; cp "$WC" "$WB" ;;
    pending_no_baseline) printf 'template v2\n' > "$WU"; printf 'template v1\n' > "$WC" ;;
    unknown)             printf 'template v1\n' > "$WC" ;;
  esac
}

# _doc VAULT_ROOT: run the function IN THE TEST SHELL (so the warn counter is observable) with
# its output captured to a file, then expose it as $out.
_doc() {
  _upgrade_notice_doctor "$WS" "$1" > "$TMP_TEST_DIR/doctor.out"
  out="$(cat "$TMP_TEST_DIR/doctor.out")"
}

# --- libraries missing: an old workspace --------------------------------------------

@test "038 doctor: a workspace without the 038 libraries gets one skip line and no warning" {
  rm -rf "$WS/scripts/lib"
  _doc "$V"
  [ "$_doctor_warn_count" -eq 0 ]
  [ "$_doctor_fail_count" -eq 0 ]
  [ "$out" = "  ⊝ Upgrade notice (skipped — workspace predates 038 (run ./setup.sh --regenerate))" ]
}

# --- vault layer -----------------------------------------------------------------------

@test "038 doctor vault: no vault root (vault disabled) is a skip, and the workspace layer still runs" {
  _ws_state in_sync
  _doc ""
  [ "$_doctor_warn_count" -eq 0 ]
  [[ "$out" == *"⊝ Vault schema deltas (skipped — vault disabled)"* ]]
  [[ "$out" == *"✓ Workspace CLAUDE.md: in sync with the current template"* ]]
}

@test "038 doctor vault: nothing pending is a PASS" {
  _ws_state in_sync
  _deposit 0.27.0
  printf '## Actionability (PARA)\n' >> "$V/CLAUDE.md"
  _doc "$V"
  [ "$_doctor_warn_count" -eq 0 ]
  [[ "$out" == *"✓ Vault schema deltas: all integrated"* ]]
}

@test "038 doctor vault: a pending 0.27.0 is a WARN naming the version, counted, with a hint" {
  _ws_state in_sync
  _deposit 0.27.0
  _doc "$V"
  [ "$_doctor_warn_count" -eq 1 ]
  [[ "$out" == *"⚠ Vault schema delta pending integration: 0.27.0"* ]]
  [[ "$out" == *"schema-updates-<version>.md"* ]]
}

@test "038 doctor vault: two pending deltas are listed ascending on one line" {
  _ws_state in_sync
  _deposit 0.8.0
  _deposit 0.27.0
  _doc "$V"
  [ "$_doctor_warn_count" -eq 1 ]
  [[ "$out" == *"⚠ Vault schema delta pending integration: 0.8.0 0.27.0"* ]]
}

# --- workspace layer -------------------------------------------------------------------

@test "038 doctor workspace: in_sync is a PASS" {
  _ws_state in_sync
  _doc ""
  [ "$_doctor_warn_count" -eq 0 ]
  [[ "$out" == *"✓ Workspace CLAUDE.md: in sync with the current template"* ]]
}

@test "038 doctor workspace: customized (own edits, template unchanged) is a PASS, not a warning" {
  _ws_state customized
  _doc ""
  [ "$_doctor_warn_count" -eq 0 ]
  [[ "$out" == *"✓ Workspace CLAUDE.md: local edits on the current template"* ]]
}

@test "038 doctor workspace: unknown (no upstream render yet) is a skip pointing at --regenerate" {
  _ws_state unknown
  _doc ""
  [ "$_doctor_warn_count" -eq 0 ]
  [[ "$out" == *"⊝ Workspace CLAUDE.md (skipped — run ./setup.sh --regenerate to render the current template)"* ]]
}

@test "038 doctor workspace: pending_template is a WARN with the diff and the confirm command" {
  _ws_state pending_template
  _doc ""
  [ "$_doctor_warn_count" -eq 1 ]
  [[ "$out" == *"⚠ Workspace CLAUDE.md: the template changed since the last integration"* ]]
  [[ "$out" == *"diff .state/launcher/claude-md.baseline.md .state/launcher/claude-md.upstream.md"* ]]
  [[ "$out" == *"cp .state/launcher/claude-md.upstream.md .state/launcher/claude-md.baseline.md"* ]]
}

@test "038 doctor workspace: pending_no_baseline is a WARN with both remedies (force, or merge then confirm)" {
  _ws_state pending_no_baseline
  _doc ""
  [ "$_doctor_warn_count" -eq 1 ]
  [[ "$out" == *"⚠ Workspace CLAUDE.md differs from the current template (no baseline)"* ]]
  [[ "$out" == *"./setup.sh --regenerate --force-claude-md"* ]]
  [[ "$out" == *"cp .state/launcher/claude-md.upstream.md .state/launcher/claude-md.baseline.md"* ]]
}

@test "038 doctor: both layers pending is two warnings, not one" {
  _ws_state pending_no_baseline
  _deposit 0.27.0
  _doc "$V"
  [ "$_doctor_warn_count" -eq 2 ]
  [ "$_doctor_fail_count" -eq 0 ]
}

# --- persistence: no auto-silencing ----------------------------------------------------

@test "038 doctor: a pending layer is reported identically on every run (it does not silence itself)" {
  _ws_state pending_template
  _deposit 0.27.0
  _doc "$V"
  local first="$out"
  _doc "$V"
  _doc "$V"
  [ "$out" = "$first" ]
  [ "$_doctor_warn_count" -eq 6 ]     # 3 runs x 2 warnings, none suppressed
}

@test "038 doctor: resolving a layer flips its line to PASS on the very next run" {
  _ws_state pending_no_baseline
  _deposit 0.27.0
  _doc "$V"
  [ "$_doctor_warn_count" -eq 2 ]
  # the agent integrates the delta
  printf '## Actionability (PARA)\n' >> "$V/CLAUDE.md"
  _doctor_warn_count=0
  _doc "$V"
  [ "$_doctor_warn_count" -eq 1 ]
  [[ "$out" == *"✓ Vault schema deltas: all integrated"* ]]
  # the agent merges CLAUDE.md and confirms the baseline
  cp "$WU" "$WB"
  _doctor_warn_count=0
  _doc "$V"
  [ "$_doctor_warn_count" -eq 0 ]
  [[ "$out" == *"✓ Workspace CLAUDE.md: local edits on the current template"* ]]
}

@test "038 doctor: it never fails the doctor itself - the function always returns 0" {
  _ws_state pending_no_baseline
  _deposit 0.27.0
  _upgrade_notice_doctor "$WS" "$V" > /dev/null
  [ "$?" -eq 0 ]
  _upgrade_notice_doctor "$WS" "" > /dev/null
  [ "$?" -eq 0 ]
  _upgrade_notice_doctor "$TMP_TEST_DIR/no-such-workspace" "" > /dev/null
  [ "$?" -eq 0 ]
}

@test "038 doctor: it reads the DISK, not wiki-graph's cached finding (a stale cache must not decide)" {
  _ws_state in_sync
  _deposit 0.27.0
  mkdir -p "$WS/scripts/heartbeat"
  # a cache that claims there is NOTHING pending, while the disk says otherwise
  printf '{"counts":{"schema_delta_pending":0}}\n' > "$WS/scripts/heartbeat/wiki-graph.json"
  _doc "$V"
  [ "$_doctor_warn_count" -eq 1 ]
  [[ "$out" == *"Vault schema delta pending integration: 0.27.0"* ]]
}

# --- where the vault root comes from -----------------------------------------------------

@test "038 doctor root: vault.enabled false (or no agent.yml) yields no root" {
  [ "$(type -t _upgrade_notice_vault_root)" = "function" ]   # an absent function would read as "empty"
  printf 'vault:\n  enabled: false\n  path: .state/.vault\n' > "$WS/agent.yml"
  [ -z "$(_upgrade_notice_vault_root "$WS" "$WS/agent.yml")" ]
  [ -z "$(_upgrade_notice_vault_root "$WS" "$WS/nonexistent.yml")" ]
  # control: the same file with the vault on does yield a root
  printf 'vault:\n  enabled: true\n  path: .state/.vault\n' > "$WS/agent.yml"
  [ -n "$(_upgrade_notice_vault_root "$WS" "$WS/agent.yml")" ]
}

@test "038 doctor root: a relative vault.path resolves under the workspace, the default is .state/.vault" {
  printf 'vault:\n  enabled: true\n  path: notes/kb\n' > "$WS/agent.yml"
  [ "$(_upgrade_notice_vault_root "$WS" "$WS/agent.yml")" = "$WS/notes/kb" ]
  printf 'vault:\n  enabled: true\n' > "$WS/agent.yml"
  [ "$(_upgrade_notice_vault_root "$WS" "$WS/agent.yml")" = "$WS/.state/.vault" ]
}

@test "038 doctor root: an absolute vault.path is used as is" {
  printf 'vault:\n  enabled: true\n  path: /srv/vault\n' > "$WS/agent.yml"
  [ "$(_upgrade_notice_vault_root "$WS" "$WS/agent.yml")" = "/srv/vault" ]
}

# --- wiring: both doctors call it, in the right place ----------------------------------

@test "038 doctor wiring: the docker doctor calls it right after the vault section" {
  local body l_vault l_notice l_next
  body=$(awk '/^cmd_doctor\(\) \{$/,/^\}$/' "$REPO_ROOT/scripts/agentctl")
  [ -n "$body" ]
  l_vault=$(printf '%s\n' "$body" | grep -n '# 11\. Vault skeleton seeded' | head -1 | cut -d: -f1)
  l_notice=$(printf '%s\n' "$body" | grep -n '_upgrade_notice_doctor' | head -1 | cut -d: -f1)
  l_next=$(printf '%s\n' "$body" | grep -n '# 12\. Telegram plugin patched' | head -1 | cut -d: -f1)
  [ -n "$l_vault" ]
  [ -n "$l_notice" ]
  [ -n "$l_next" ]
  [ "$l_vault" -lt "$l_notice" ]
  [ "$l_notice" -lt "$l_next" ]
}

@test "038 doctor wiring: the local doctor calls it after the vault/qmd section" {
  local body l_qmd l_notice
  body=$(awk '/^cmd_local_doctor\(\) \{$/,/^\}$/' "$REPO_ROOT/scripts/agentctl")
  [ -n "$body" ]
  l_qmd=$(printf '%s\n' "$body" | grep -n '_local_vault_qmd_doctor' | head -1 | cut -d: -f1)
  l_notice=$(printf '%s\n' "$body" | grep -n '_upgrade_notice_doctor' | head -1 | cut -d: -f1)
  [ -n "$l_qmd" ]
  [ -n "$l_notice" ]
  [ "$l_qmd" -lt "$l_notice" ]
}

# --- end to end through the real doctors (stubs for docker / systemctl / claude) ---------

# _stub_bin: a bin dir where docker reports a healthy running container, systemctl says every
# unit is active, and claude has a version - enough for both doctors to reach the new lines.
_stub_bin() {
  local bin="$TMP_TEST_DIR/bin"
  mkdir -p "$bin"
  cat > "$bin/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  info)    exit 0 ;;
  ps)      echo "abc123def456"; exit 0 ;;
  inspect) echo "running"; exit 0 ;;
  exec)    exit 0 ;;
  *)       exit 0 ;;
esac
SH
  cat > "$bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *is-failed*) exit 1 ;;
  *) exit 0 ;;
esac
SH
  cat > "$bin/journalctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$bin/claude" <<'SH'
#!/usr/bin/env bash
case "$*" in *--version*) echo "2.1.99 (Claude Code)" ;; esac
exit 0
SH
  chmod +x "$bin"/*
  PATH="$bin:$PATH"
}

@test "038 doctor e2e docker: the real 'agentctl doctor' prints the vault and workspace lines" {
  _stub_bin
  mkdir -p "$TMP_TEST_DIR/e2e/scripts" "$TMP_TEST_DIR/e2e/.state/.vault/_templates" "$TMP_TEST_DIR/e2e/.state/launcher"
  cp -r "$REPO_ROOT/scripts/lib" "$REPO_ROOT/scripts/agentctl" "$TMP_TEST_DIR/e2e/scripts/"
  local e="$TMP_TEST_DIR/e2e"
  cat > "$e/agent.yml" <<'YML'
agent:
  name: testagent
notifications:
  channel: none
vault:
  enabled: true
  path: .state/.vault
YML
  printf '# vault\n' > "$e/.state/.vault/CLAUDE.md"
  printf 'deposited: 2026-09-30\n' > "$e/.state/.vault/_templates/.schema-updates-0.27.0.applied"
  printf 'template v2\n' > "$e/.state/launcher/claude-md.upstream.md"
  printf 'template v1\n' > "$e/CLAUDE.md"
  cd "$e"
  # setup() exports AGENTCTL_NO_RUN=1 for the unit tests above; the child must actually run main
  run env -u AGENTCTL_NO_RUN ./scripts/agentctl doctor
  [[ "$output" == *"Vault schema delta pending integration: 0.27.0"* ]]
  [[ "$output" == *"Workspace CLAUDE.md differs from the current template (no baseline)"* ]]
}

@test "038 doctor e2e docker: with everything integrated the real doctor prints both PASS lines" {
  _stub_bin
  mkdir -p "$TMP_TEST_DIR/e2e/scripts" "$TMP_TEST_DIR/e2e/.state/.vault/_templates" "$TMP_TEST_DIR/e2e/.state/launcher"
  cp -r "$REPO_ROOT/scripts/lib" "$REPO_ROOT/scripts/agentctl" "$TMP_TEST_DIR/e2e/scripts/"
  local e="$TMP_TEST_DIR/e2e"
  cat > "$e/agent.yml" <<'YML'
agent:
  name: testagent
notifications:
  channel: none
vault:
  enabled: true
  path: .state/.vault
YML
  printf '# vault\n## Actionability (PARA)\n' > "$e/.state/.vault/CLAUDE.md"
  printf 'deposited: 2026-09-30\n' > "$e/.state/.vault/_templates/.schema-updates-0.27.0.applied"
  printf 'template v2\n' > "$e/.state/launcher/claude-md.upstream.md"
  cp "$e/.state/launcher/claude-md.upstream.md" "$e/CLAUDE.md"
  cd "$e"
  # setup() exports AGENTCTL_NO_RUN=1 for the unit tests above; the child must actually run main
  run env -u AGENTCTL_NO_RUN ./scripts/agentctl doctor
  [[ "$output" == *"✓ Vault schema deltas: all integrated"* ]]
  [[ "$output" == *"✓ Workspace CLAUDE.md: in sync with the current template"* ]]
}

@test "038 doctor e2e local: the real local doctor prints the same two lines" {
  _stub_bin
  local e="$TMP_TEST_DIR/e2e"
  mkdir -p "$e/scripts" "$e/modules" "$e/.state/.vault/_templates" "$e/.state/launcher" "$e/.state/.claude"
  cp -r "$REPO_ROOT/scripts/lib" "$REPO_ROOT/scripts/agentctl" "$e/scripts/"
  cp -r "$REPO_ROOT/modules/mcps" "$e/modules/"
  cat > "$e/agent.yml" <<'YML'
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
vault:
  enabled: true
  path: .state/.vault
YML
  printf '{"expiresAt":99999999999999}\n' > "$e/.state/.claude/.credentials.json"
  chmod 600 "$e/.state/.claude/.credentials.json"
  printf '# vault\n' > "$e/.state/.vault/CLAUDE.md"
  printf 'deposited: 2026-09-30\n' > "$e/.state/.vault/_templates/.schema-updates-0.27.0.applied"
  printf 'template v2\n' > "$e/.state/launcher/claude-md.upstream.md"
  printf 'template v1\n' > "$e/CLAUDE.md"
  cd "$e"
  # setup() exports AGENTCTL_NO_RUN=1 for the unit tests above; the child must actually run main
  run env -u AGENTCTL_NO_RUN ./scripts/agentctl doctor
  [[ "$output" == *"Vault schema delta pending integration: 0.27.0"* ]]
  [[ "$output" == *"Workspace CLAUDE.md differs from the current template (no baseline)"* ]]
}
