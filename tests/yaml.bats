#!/usr/bin/env bats

load helper

setup() {
  load_lib yaml
  FIXTURE="$REPO_ROOT/tests/fixtures/sample-agent.yml"
}

@test "yaml_get reads scalar value" {
  result=$(yaml_get "$FIXTURE" '.agent.name')
  [ "$result" = "dockbot" ]
}

@test "yaml_get reads nested value" {
  result=$(yaml_get "$FIXTURE" '.user.nickname')
  [ "$result" = "Alice" ]
}

@test "yaml_get returns empty string for missing path" {
  result=$(yaml_get "$FIXTURE" '.does.not.exist')
  [ -z "$result" ]
}

@test "yaml_get_bool returns 'true' or 'false'" {
  result=$(yaml_get_bool "$FIXTURE" '.features.heartbeat.enabled')
  [ "$result" = "true" ]
  result=$(yaml_get_bool "$FIXTURE" '.mcps.github.enabled')
  [ "$result" = "false" ]
}

@test "yaml_array_length counts array items" {
  result=$(yaml_array_length "$FIXTURE" '.mcps.atlassian')
  [ "$result" = "2" ]
}

@test "yaml_array_item reads by index" {
  result=$(yaml_array_item "$FIXTURE" '.mcps.atlassian' 0 '.name')
  [ "$result" = "work" ]
  result=$(yaml_array_item "$FIXTURE" '.mcps.atlassian' 1 '.email')
  [ "$result" = "alice@personal.com" ]
}

@test "yaml_array_item returns empty string for missing subpath" {
  result=$(yaml_array_item "$FIXTURE" '.mcps.atlassian' 0 '.nonexistent')
  [ -z "$result" ]
}

# yaml_yq_version_ok — guards against Debian-style apt yq (v3) and python-yq.
# Mocks yq via a PATH override so we can simulate every relevant `yq --version`
# output without touching the real binary on the host.

@test "yaml_yq_version_ok rejects mikefarah v3" {
  local mock="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$mock"
  cat > "$mock/yq" <<'EOF'
#!/bin/sh
echo "yq version 3.4.3"
EOF
  chmod +x "$mock/yq"
  PATH="$mock:$PATH" run yaml_yq_version_ok
  [ "$status" -ne 0 ]
}

@test "yaml_yq_version_ok rejects python-yq" {
  local mock="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$mock"
  cat > "$mock/yq" <<'EOF'
#!/bin/sh
echo "yq 3.4.3"
EOF
  chmod +x "$mock/yq"
  PATH="$mock:$PATH" run yaml_yq_version_ok
  [ "$status" -ne 0 ]
}

@test "yaml_yq_version_ok accepts mikefarah v4" {
  local mock="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$mock"
  cat > "$mock/yq" <<'EOF'
#!/bin/sh
echo "yq (https://github.com/mikefarah/yq/) version v4.45.1"
EOF
  chmod +x "$mock/yq"
  PATH="$mock:$PATH" run yaml_yq_version_ok
  [ "$status" -eq 0 ]
}

@test "yaml_yq_version_ok future-proof for v5+" {
  local mock="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$mock"
  cat > "$mock/yq" <<'EOF'
#!/bin/sh
echo "yq (https://github.com/mikefarah/yq/) version v5.0.0"
EOF
  chmod +x "$mock/yq"
  PATH="$mock:$PATH" run yaml_yq_version_ok
  [ "$status" -eq 0 ]
}
