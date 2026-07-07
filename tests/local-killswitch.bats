#!/usr/bin/env bats
# 013-local-rag-parity (US3, FR-008): the local kill switch must halt ALL agent
# activity — not just the session + qmd, but also the vault-backup timer (which
# otherwise keeps pushing to the fork with the operator's credentials) and the
# healthcheck timer (which otherwise keeps notifying) hours after "kill".

load helper

setup() {
  setup_tmp_dir
  load_lib render
  load_lib yaml
  export AGENT_NAME=locbot
}

teardown() { teardown_tmp_dir; }

@test "kill switch AUX_UNITS lists all four companion units (013 FR-008/T020)" {
  render_to_file "$REPO_ROOT/modules/local-killswitch.sh.tpl" "$TMP_TEST_DIR/kill.sh"
  # AGENT_NAME is a rendered placeholder, but the unit names reference it as a
  # shell var (`agent-${AGENT_NAME}-…`), so grep the literal shell-var form.
  local k="$TMP_TEST_DIR/kill.sh"
  grep -q 'agent-${AGENT_NAME}-qmd-reindex.timer' "$k"
  grep -q 'agent-${AGENT_NAME}-qmd-watch.service' "$k"
  grep -q 'agent-${AGENT_NAME}-vault-backup.timer' "$k"
  grep -q 'agent-${AGENT_NAME}-healthcheck.timer' "$k"
}

@test "kill switch AUX_UNITS includes the wiki-graph timer (014/T021)" {
  render_to_file "$REPO_ROOT/modules/local-killswitch.sh.tpl" "$TMP_TEST_DIR/kill.sh"
  grep -q 'agent-${AGENT_NAME}-wiki-graph.timer' "$TMP_TEST_DIR/kill.sh"
}

@test "kill switch stops each AUX unit best-effort (|| true, never errors out)" {
  render_to_file "$REPO_ROOT/modules/local-killswitch.sh.tpl" "$TMP_TEST_DIR/kill.sh"
  # the stop loop must tolerate a missing unit (hosts without qmd/backup enabled)
  grep -q 'systemctl stop "\$_aux"' "$TMP_TEST_DIR/kill.sh"
  grep -qE 'll true|\|\| true' "$TMP_TEST_DIR/kill.sh"
}
