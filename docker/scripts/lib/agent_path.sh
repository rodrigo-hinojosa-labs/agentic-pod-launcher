# shellcheck shell=sh
# agent_path.sh — the PATH of the claude sessions the agent runs (045).
#
# Plugins install their own launchers under the agent user's bin directory,
# $HOME/.local/bin (claude-mem 15.x does, and its hooks call the launcher by name,
# without a shell). That directory lives in the .state/ bind-mount, survives every
# rebuild and is writable by `agent`, so:
#   - it goes at the END of the PATH, after every image directory, so nothing from
#     persistent state can shadow an image binary (036 already paid for stale links
#     there);
#   - root never gets it (UID 0 returns the input unchanged): a root process that
#     resolved a name missing from the image would otherwise run what `agent` planted;
#   - adding it is idempotent, and the directory does not need to exist yet (the
#     plugin creates it during the session; PATH is resolved on every exec).
#
# POSIX sh: sourced by bash (start_services.sh, heartbeat.sh) and by BusyBox sh
# (agentctl mcp's remote `sh -c`). Defines a function and nothing else, so sourcing
# it has no side effects.

# agent_path_compose CURRENT_PATH HOME UID
#   Uses only its positional parameters (no globals, safe under set -u).
#   Prints CURRENT_PATH with "$HOME/.local/bin" appended, or CURRENT_PATH unchanged
#   when UID is not a decimal other than 0 (root, empty or garbage: fail closed),
#   HOME is empty, "/", relative, ends in "/" or contains ':' or a newline,
#   CURRENT_PATH is empty, or the directory is already one of its elements.
#   Always returns 0; nothing on stderr.
agent_path_compose() {
  case "${3-}" in
    ""|*[!0-9]*)
      printf '%s\n' "${1-}"
      return 0
      ;;
  esac
  case "$3" in
    *[!0]*) ;;
    *)
      printf '%s\n' "${1-}"
      return 0
      ;;
  esac
  case "${2-}" in
    ""|/|*/|[!/]*|*:*|*"
"*)
      printf '%s\n' "${1-}"
      return 0
      ;;
  esac
  if [ -z "${1-}" ]; then
    printf '%s\n' ""
    return 0
  fi
  case ":$1:" in
    *":$2/.local/bin:"*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$1:$2/.local/bin" ;;
  esac
  return 0
}
