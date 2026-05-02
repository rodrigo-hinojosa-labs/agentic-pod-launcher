#!/usr/bin/env bats
load 'helper'

@test "--backup invokes heartbeatctl backup-identity in the container" {
  local agent_name="testagent"
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/docker" <<EOF
#!/bin/sh
echo "docker \$@" >> "$BATS_TEST_TMPDIR/docker.calls"
EOF
  chmod +x "$fake_bin/docker"
  export PATH="$fake_bin:$PATH"

  local dest="$BATS_TEST_TMPDIR/ws"
  mkdir -p "$dest"
  cp "$BATS_TEST_DIRNAME/../setup.sh" "$dest/"
  cp -R "$BATS_TEST_DIRNAME/../scripts" "$dest/"
  cat > "$dest/agent.yml" <<YAML
agent:
  name: $agent_name
YAML

  cd "$dest" || return 1
  run bash "$dest/setup.sh" --backup
  # The shim records the command. The exit code from docker isn't important.
  grep -q "exec -u agent $agent_name heartbeatctl backup-identity" "$BATS_TEST_TMPDIR/docker.calls" || {
    echo "expected docker exec call missing; calls were:" >&2
    cat "$BATS_TEST_TMPDIR/docker.calls" >&2
    false
  }
}
