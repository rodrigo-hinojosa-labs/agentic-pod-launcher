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

# yaml_require_yq + yaml_bootstrap_yq — Ferrari scenario regression:
# Debian/Ubuntu's apt yq is v3 (Python wrapper). Without bootstrap, render.sh
# would die on the first `yq '.. | select(...)'`. This test mocks both yq (v3
# on PATH) and curl (writes a fake v4 binary into the override vendor dir) to
# prove `yaml_require_yq` repairs the situation end-to-end.

@test "yaml_require_yq bootstraps when PATH yq is v3 (Debian apt scenario)" {
  local mock="$BATS_TEST_TMPDIR/bin"
  local vendor="$BATS_TEST_TMPDIR/vendor"
  mkdir -p "$mock" "$vendor"

  # 1. Mock the system yq (v3 — what apt installs on Debian/Ubuntu).
  cat > "$mock/yq" <<'EOF'
#!/bin/sh
echo "yq 3.4.3"
EOF
  chmod +x "$mock/yq"

  # 2. Mock curl: when bootstrap downloads, write a "v4" yq into the output path.
  # The output path is the last positional arg after `-o`.
  cat > "$mock/curl" <<'EOF'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 1
cat > "$out" <<'YQ'
#!/bin/sh
[ "$1" = "--version" ] && echo "yq (https://github.com/mikefarah/yq/) version v4.45.1"
YQ
chmod +x "$out"
EOF
  chmod +x "$mock/curl"

  YAML_VENDOR_DIR_OVERRIDE="$vendor" PATH="$mock:$PATH" run yaml_require_yq
  [ "$status" -eq 0 ]
  [ -x "$vendor/yq" ]
  echo "$output" | grep -q "Detected incompatible yq"
}

@test "yaml_require_yq fails loud when bootstrap can't reach the network" {
  local mock="$BATS_TEST_TMPDIR/bin"
  local vendor="$BATS_TEST_TMPDIR/vendor"
  mkdir -p "$mock" "$vendor"

  cat > "$mock/yq" <<'EOF'
#!/bin/sh
echo "yq 3.4.3"
EOF
  chmod +x "$mock/yq"

  # curl fails (simulates no network / GitHub down).
  cat > "$mock/curl" <<'EOF'
#!/bin/sh
exit 22
EOF
  chmod +x "$mock/curl"

  YAML_VENDOR_DIR_OVERRIDE="$vendor" PATH="$mock:$PATH" run yaml_require_yq
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "auto-download failed"
  # Manual install hint must NOT mention `apt install yq` — that's the v3 trap.
  ! echo "$output" | grep -q "apt install yq"
}
