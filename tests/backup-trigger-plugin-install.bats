#!/usr/bin/env bats
load 'helper'

@test "ensure_plugin_installed_one invokes backup-identity on success" {
  local shim_dir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/heartbeatctl" <<EOF
#!/bin/sh
echo "\$@" >> "$BATS_TEST_TMPDIR/heartbeatctl.calls"
EOF
  chmod +x "$shim_dir/heartbeatctl"

  export PATH="$shim_dir:$PATH"

  # Set HOME so plugin_cache_dir_for resolves into our tmpdir, and seed
  # the .installed-ok sentinel so ensure_plugin_installed_one short-
  # circuits to the post-install hooks path (which is where the backup
  # trigger fires).
  export HOME="$BATS_TEST_TMPDIR/home"
  local cache="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"
  mkdir -p "$cache"
  : > "$cache/.installed-ok"

  # Sourcing start_services.sh would trigger main() if BASH_SOURCE
  # equals $0, but in bats it does not — the guard short-circuits and
  # only function definitions are loaded.
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../docker/scripts/start_services.sh"
  CLAUDE_CONFIG_DIR_VAL="$HOME/.claude"

  run ensure_plugin_installed_one "telegram@claude-plugins-official"
  [ "$status" -eq 0 ]

  [ -f "$BATS_TEST_TMPDIR/heartbeatctl.calls" ]
  grep -q "backup-identity" "$BATS_TEST_TMPDIR/heartbeatctl.calls"
}
