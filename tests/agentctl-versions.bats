#!/usr/bin/env bats
# US3 — `agentctl versions [--check] [--json] [--upgrade]`.
# Runs against a minimal workspace (agent.yml + agentctl + libs). The suite
# is offline (helper.bash AGENTIC_VERSIONS_OFFLINE=1), so versions_resolve
# returns the documented floor — deterministic "latest" for --check/--upgrade.

load helper

setup() { setup_tmp_dir; }
teardown() { teardown_tmp_dir; }

# Build a minimal workspace. claude_code is intentionally BEHIND the floor
# (2.1.119 < 2.1.170) so --check reports outdated and --upgrade moves it;
# gum is pinned so --upgrade must skip it.
_mk_ws() {
  local ws="$TMP_TEST_DIR/ws"
  mkdir -p "$ws/scripts/lib"
  cp "$REPO_ROOT/scripts/agentctl" "$ws/scripts/agentctl"
  cp "$REPO_ROOT/scripts/lib/yaml.sh" "$REPO_ROOT/scripts/lib/versions.sh" "$ws/scripts/lib/"
  cat > "$ws/agent.yml" <<'YML'
version: 1
agent:
  name: vbot
docker:
  base_image: "alpine:3.24.1"
  claude_code_version: "2.1.119"
  uv_version: "0.11.22"
  bun_version: "1.3.14"
  gum_version: "0.17.0"
  toolchain_channels:
    claude_code: stable
    gum: pinned
YML
  printf '%s' "$ws"
}

@test "agentctl versions lists recorded versions + channels" {
  local ws; ws=$(_mk_ws); cd "$ws"
  run bash scripts/agentctl versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude_code"* ]]
  [[ "$output" == *"2.1.119"* ]]
  [[ "$output" == *"alpine"* ]]
  [[ "$output" == *"3.24.1"* ]]
}

@test "agentctl versions --check flags outdated vs upstream (offline floor)" {
  local ws; ws=$(_mk_ws); cd "$ws"
  run bash scripts/agentctl versions --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"2.1.170"* ]]   # resolved latest (floor)
  [[ "$output" == *"outdated"* ]]  # claude_code 2.1.119 < 2.1.170
  [[ "$output" == *"current"* ]]   # uv 0.11.22 == floor
}

@test "agentctl versions --json emits a valid array" {
  local ws; ws=$(_mk_ws); cd "$ws"
  run bash scripts/agentctl versions --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[0].component' >/dev/null
  [ "$(echo "$output" | jq -r '.[] | select(.component=="claude_code") | .recorded')" = "2.1.119" ]
}

@test "agentctl versions --upgrade records non-pinned, skips pinned, writes .prev" {
  local ws; ws=$(_mk_ws); cd "$ws"
  run bash scripts/agentctl versions --upgrade
  [ "$status" -eq 0 ]
  [ -f agent.yml.prev ]
  [ "$(yq -r '.docker.claude_code_version' agent.yml)" = "2.1.170" ]
  [[ "$output" == *"pinned"* ]]   # gum skipped
}
