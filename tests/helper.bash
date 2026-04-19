#!/usr/bin/env bash
# Shared test helpers

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

setup_tmp_dir() {
  TMP_TEST_DIR=$(mktemp -d)
  export TMP_TEST_DIR
}

teardown_tmp_dir() {
  if [ -n "${TMP_TEST_DIR:-}" ] && [ -d "$TMP_TEST_DIR" ]; then
    rm -rf "$TMP_TEST_DIR"
  fi
  # Always succeed — if the test itself nuked TMP_TEST_DIR, that's fine.
  return 0
}

load_lib() {
  local name="${1:-}"
  [ -z "$name" ] && { echo "load_lib: missing argument" >&2; return 1; }
  local lib="$REPO_ROOT/scripts/lib/${name}.sh"
  [ ! -f "$lib" ] && { echo "load_lib: not found: $lib" >&2; return 1; }
  source "$lib"
}
