#!/usr/bin/env bats
# 021-local-secret-delivery: install_service (setup.sh) had ZERO test coverage
# before this — every path under it hardcoded /etc/systemd/system. The
# SETUP_SYSTEMD_DIR seam (mirroring LOGIN_SYSTEMD_DIR in local-login.sh.tpl)
# lets us prove "the INSTALLED unit carries the right content" without ever
# writing to the real /etc — which matters for T004's own guard as much as
# for the doctor's D3 check (021) that inspects the installed unit later.
#
# Host-runnable: no real systemd/sudo. `claude`/`sudo`/`systemctl` stubbed.

load helper

setup() {
  setup_tmp_dir
  command -v jq >/dev/null || skip "jq not installed"
  cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/modules" "$TMP_TEST_DIR/"
  cp "$REPO_ROOT/setup.sh" "$REPO_ROOT/VERSION" "$TMP_TEST_DIR/"

  # 022/T044: the fixture's `deployment.session_name` is MANDATORY, not cosmetic.
  # The byte-for-byte diff test below renders `expected.unit` BEFORE running
  # --regenerate; without the field, setup.sh would backfill it during that run
  # and the two units would differ — `expected` with `--name ""` (render.sh
  # substitutes an undefined {{VAR}} with the empty string, not the literal)
  # against an installed unit carrying the resolved value. The 022 tests that
  # exercise the backfill delete the key first, on purpose.
  cat > "$TMP_TEST_DIR/agent.yml" << 'YML'
version: 1
agent:
  name: locbot
  display_name: "LocBot"
  role: "r"
  vibe: "v"
user:
  name: "A"
  nickname: "A"
  timezone: "UTC"
  email: "a@b.com"
  language: "en"
deployment:
  host: "rpi5"
  workspace: "WORKSPACE_PLACEHOLDER"
  install_service: true
  claude_cli: "claude"
  mode: local
  session_name: "rpi5-locbot"
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
  defaults: [fetch, git, filesystem]
vault:
  enabled: false
YML
  sed -i.bak "s#WORKSPACE_PLACEHOLDER#$TMP_TEST_DIR#" "$TMP_TEST_DIR/agent.yml"
  rm -f "$TMP_TEST_DIR/agent.yml.bak"

  BIN="$TMP_TEST_DIR/bin"; mkdir -p "$BIN"
  cat > "$BIN/claude" << 'SH'
#!/usr/bin/env bash
case "$1" in
  --version) echo "2.1.181 (Claude Code)" ;;
  *) : ;;
esac
SH
  # sudo stub: drop the "sudo" prefix (and its own -n flag, which "exec" would
  # otherwise try to parse as ITS flag) and exec the rest — lets install_service
  # take its "sudo -n true succeeded" branch without any real privilege.
  cat > "$BIN/sudo" << 'SH'
#!/usr/bin/env bash
[ "$1" = "-n" ] && shift
exec "$@"
SH
  cat > "$BIN/systemctl" << SH
#!/usr/bin/env bash
echo "systemctl \$*" >> "$TMP_TEST_DIR/systemctl.log"
exit 0
SH
  chmod +x "$BIN/claude" "$BIN/sudo" "$BIN/systemctl"
  export PATH="$BIN:$PATH"

  export SETUP_SYSTEMD_DIR="$TMP_TEST_DIR/fake-systemd"
  mkdir -p "$SETUP_SYSTEMD_DIR"
}

teardown() { teardown_tmp_dir; }

@test "install_service: SETUP_SYSTEMD_DIR redirects the installed session unit" {
  cd "$TMP_TEST_DIR"
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  [ -f "$SETUP_SYSTEMD_DIR/agent-locbot.service" ]
  grep -q '^ExecStart=' "$SETUP_SYSTEMD_DIR/agent-locbot.service"
}

@test "install_service: SETUP_SYSTEMD_DIR redirects the healthcheck timer too" {
  cd "$TMP_TEST_DIR"
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  [ -f "$SETUP_SYSTEMD_DIR/agent-locbot-healthcheck.service" ]
  [ -f "$SETUP_SYSTEMD_DIR/agent-locbot-healthcheck.timer" ]
}

@test "install_service: nothing is written to the real /etc/systemd/system (seam guard)" {
  cd "$TMP_TEST_DIR"
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  [ ! -e "/etc/systemd/system/agent-locbot.service" ]
}

@test "install_service: installed unit content matches what render_to_file would produce" {
  cd "$TMP_TEST_DIR"
  load_lib render
  load_lib yaml
  yaml_require_yq >/dev/null
  render_load_context "$TMP_TEST_DIR/agent.yml" >/dev/null
  export OPERATOR_USER="$(id -un)" OPERATOR_HOME="$HOME" HOST_NAME="$(hostname)"
  export CLAUDE_BIN="$BIN/claude"
  render_to_file "$REPO_ROOT/modules/systemd-remote-control.service.tpl" "$TMP_TEST_DIR/expected.unit"

  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  diff "$TMP_TEST_DIR/expected.unit" "$SETUP_SYSTEMD_DIR/agent-locbot.service"
}

# ─── T009 (021 US1): regenerate-safety for the new EnvironmentFile/ExecStartPre ───

@test "021/T009: a --regenerate re-installs the unit WITH the .env directive, in the right order" {
  cd "$TMP_TEST_DIR"
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  local env_line rc_line
  env_line=$(grep -n '^EnvironmentFile=-.*/\.env$' "$SETUP_SYSTEMD_DIR/agent-locbot.service" | cut -d: -f1)
  rc_line=$(grep -n '^EnvironmentFile=.*\.state/remote-control\.env$' "$SETUP_SYSTEMD_DIR/agent-locbot.service" | cut -d: -f1)
  [ -n "$env_line" ]
  [ -n "$rc_line" ]
  [ "$env_line" -lt "$rc_line" ]
}

@test "021/T009: --regenerate never creates or touches the workspace .env" {
  cd "$TMP_TEST_DIR"
  [ ! -e "$TMP_TEST_DIR/.env" ]
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  # regenerate renders .env.example, never .env — a pre-existing operator
  # secrets file (or its absence) must never be touched by --regenerate.
  [ ! -e "$TMP_TEST_DIR/.env" ]
  [ -f "$TMP_TEST_DIR/.env.example" ]
}

# ─── 022 US3: session name backfill + idempotency (N8, S26) ─────────────────

@test "022/N8: a pre-022 agent.yml gains deployment.session_name on --regenerate" {
  cd "$TMP_TEST_DIR"
  yq -i 'del(.deployment.session_name)' "$TMP_TEST_DIR/agent.yml"
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  run yq -r '.deployment.session_name' "$TMP_TEST_DIR/agent.yml"
  [ "$output" = "rpi5-locbot" ]
}

@test "022/N8: the INSTALLED unit carries the backfilled name (not a bare --name)" {
  cd "$TMP_TEST_DIR"
  yq -i 'del(.deployment.session_name)' "$TMP_TEST_DIR/agent.yml"
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  grep -q -- '--name "rpi5-locbot" --spawn=session' "$SETUP_SYSTEMD_DIR/agent-locbot.service"
}

# S26 / Principle I: the backfill must converge. A second --regenerate that kept
# rewriting agent.yml would churn the file on every run and make "what the
# operator edited" indistinguishable from "what the tool wrote".
#
# `meta.regenerated_at` is excluded, and ONLY it: setup.sh stamps that field on
# every run by design (it predates 022). Everything else — the backfilled
# session_name included — must be byte-for-byte stable across runs.
@test "022/S26: a second --regenerate leaves agent.yml byte-identical (bar the timestamp)" {
  cd "$TMP_TEST_DIR"
  yq -i 'del(.deployment.session_name)' "$TMP_TEST_DIR/agent.yml"
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  grep -v 'regenerated_at' "$TMP_TEST_DIR/agent.yml" > "$TMP_TEST_DIR/first.yml"
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  grep -v 'regenerated_at' "$TMP_TEST_DIR/agent.yml" > "$TMP_TEST_DIR/second.yml"
  cmp "$TMP_TEST_DIR/first.yml" "$TMP_TEST_DIR/second.yml"
  # Belt: the exclusion above must not be hiding a missing field. Read it with
  # yq, not grep — yq emits a plain scalar (`session_name: rpi5-locbot`), so a
  # textual assertion would be coupled to its quoting style rather than to the
  # value we actually care about.
  run yq -r '.deployment.session_name' "$TMP_TEST_DIR/agent.yml"
  [ "$output" = "rpi5-locbot" ]
}

# An operator-chosen name is configuration, not a derived value: --regenerate
# must never "correct" it back to the composed default.
@test "022: an explicit session_name survives --regenerate untouched" {
  cd "$TMP_TEST_DIR"
  yq -i '.deployment.session_name = "bitacora"' "$TMP_TEST_DIR/agent.yml"
  run bash -c "echo 'n' | ./setup.sh --regenerate"
  [ "$status" -eq 0 ]
  run yq -r '.deployment.session_name' "$TMP_TEST_DIR/agent.yml"
  [ "$output" = "bitacora" ]
  grep -q -- '--name "bitacora" --spawn=session' "$SETUP_SYSTEMD_DIR/agent-locbot.service"
}
