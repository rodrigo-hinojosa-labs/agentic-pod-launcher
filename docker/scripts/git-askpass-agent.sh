#!/bin/sh
# Answers git's credential prompts from the environment. Prints nothing else.
case "$1" in
  Username*) printf '%s\n' "x-access-token" ;;
  Password*) printf '%s\n' "${GITHUB_PAT:-}" ;;
esac
