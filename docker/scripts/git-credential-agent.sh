#!/bin/sh
# git credential helper for the agent's work clone. Answers `get` from the environment.
[ "${1:-}" = get ] || exit 0
[ -n "${GITHUB_PAT:-}" ] || exit 0
printf 'username=%s\npassword=%s\n' "x-access-token" "$GITHUB_PAT"
