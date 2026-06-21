#!/usr/bin/env bats
load 'helper'

# Story H: the in-container CLAUDE.md refresh must instruct Claude to PRESERVE
# every pre-existing section verbatim and only ADD missing docs. We capture the
# prompt passed to `claude --print` via a stub — without running real claude —
# and assert the preserve-all wording is present.

setup() { setup_tmp_dir; }
teardown() { teardown_tmp_dir; }

@test "wizard-container refresh prompt says preserve-all, scan section headers, no reorder" {
  local stub="$TMP_TEST_DIR/bin"
  mkdir -p "$stub"

  # claude stub: capture the prompt passed after --print.
  cat > "$stub/claude" <<EOF
#!/bin/sh
shift                       # drop --print
printf '%s' "\$1" > "$TMP_TEST_DIR/prompt.txt"
EOF
  chmod +x "$stub/claude"

  # timeout stub: passthrough (a stock macOS host has no coreutils timeout).
  cat > "$stub/timeout" <<'EOF'
#!/bin/sh
shift                       # drop the duration
exec "$@"
EOF
  chmod +x "$stub/timeout"

  # gum stub: run whatever follows the '--' separator (gum spin -- CMD...).
  cat > "$stub/gum" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
[ "$1" = "--" ] && shift
exec "$@"
EOF
  chmod +x "$stub/gum"

  # A CLAUDE.md must exist for the refresh to fire.
  local claude_md="$TMP_TEST_DIR/CLAUDE.md"
  printf '## Identity\n\n- **Role:** test\n' > "$claude_md"

  # Source the script (no top-level wizard run) and call just the refresh fn.
  export WIZARD_CONTAINER_NO_RUN=1
  # shellcheck source=/dev/null
  source "$REPO_ROOT/docker/scripts/wizard-container.sh"

  CLAUDE_MD="$claude_md" PATH="$stub:$PATH" refresh_claude_md

  [ -f "$TMP_TEST_DIR/prompt.txt" ]
  run cat "$TMP_TEST_DIR/prompt.txt"
  [[ "$output" == *"Preserve ALL"* ]]
  [[ "$output" == *"section headers"* ]]
  [[ "$output" == *"do not edit or reorder"* ]]
}
