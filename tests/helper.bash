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

# wizard_answers — emit canonical wizard responses for the common path.
#
# Pipes one answer per line in the order setup.sh asks them. Caller pipes
# the output into `./setup.sh --destination <path>`.
#
# Args (all optional, kw=val):
#   name=<str>           agent.name           (default: test-bot)
#   display=<str>        agent.display_name   (default: TestBot)
#   role=<str>           agent.role           (default: r)
#   vibe=<str>           agent.vibe           (default: v)
#   vault=on|off         vault.enabled        (default: off — preserves prior behavior)
#   qmd=on|off           vault.qmd.enabled    (default: off; implies vault=on if on)
#   superpowers=on|off   superpowers plugin   (default: off)
#
# Specialized paths NOT covered (use a custom heredoc for these):
#   - notifications.channel = telegram (extra prompts for token + chat id)
#   - --in-place mode (extra workspace-path prompt)
#   - Atlassian MCP enabled (sub-prompts for workspace name/url/email/token)
#   - GitHub MCP enabled (sub-prompts for email/PAT)
#
# The Linux-only install_service prompt is auto-detected via uname.
wizard_answers() {
  local name=test-bot display=TestBot role=r vibe=v
  local vault=off qmd=off superpowers=off
  local kv
  for kv in "$@"; do
    case "$kv" in
      name=*)        name="${kv#name=}" ;;
      display=*)     display="${kv#display=}" ;;
      role=*)        role="${kv#role=}" ;;
      vibe=*)        vibe="${kv#vibe=}" ;;
      vault=*)       vault="${kv#vault=}" ;;
      qmd=*)         qmd="${kv#qmd=}" ;;
      superpowers=*) superpowers="${kv#superpowers=}" ;;
      *) echo "wizard_answers: unknown kv: $kv" >&2; return 1 ;;
    esac
  done
  [ "$qmd" = "on" ] && vault=on

  # Identity (4 prompts)
  printf '%s\n%s\n%s\n%s\n' "$name" "$display" "$role" "$vibe"
  # User (5 prompts)
  printf 'Alice\nAlice\nUTC\na@b.com\nen\n'
  # install_service (Linux only — macOS skips the prompt entirely)
  [ "$(uname -s)" = "Linux" ] && printf 'n\n'
  # GitHub fork
  printf 'n\n'
  # Notify channel
  printf 'none\n'
  # Optional MCPs from the catalog (alphabetical): aws, firecrawl,
  # google-calendar, playwright, time, tree-sitter.
  # All 'n' for the common test path. Secret sub-prompts only fire when
  # the parent ask_yn was 'y', so they don't appear in this stdin stream.
  printf 'n\nn\nn\nn\nn\nn\n'
  # Atlassian + GitHub MCPs (both n; sub-prompts skipped)
  printf 'n\nn\n'
  # Heartbeat: enabled, interval, prompt
  printf 'y\n30m\nok\n'
  # Use default principles
  printf 'y\n'
  # Vault block (1-4 prompts)
  if [ "$vault" = "on" ]; then
    printf 'y\ny\ny\n'                                # enabled, seed, mcp
    if [ "$qmd" = "on" ]; then printf 'y\n'; else printf 'n\n'; fi
  else
    printf 'n\n'
  fi
  # Optional plugins, alphabetical: code-simplifier, commit-commands, github, skill-creator, superpowers
  printf 'n\nn\nn\nn\n'
  if [ "$superpowers" = "on" ]; then printf 'y\n'; else printf 'n\n'; fi
  # Review action
  printf 'proceed\n'
}
