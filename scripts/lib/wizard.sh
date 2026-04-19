#!/usr/bin/env bash
# Interactive wizard helpers — read from stdin, write prompts to stderr.

# ask PROMPT DEFAULT → user input or default
ask() {
  local prompt="$1" default="$2" answer
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " answer >&2 2>&1
    echo "${answer:-$default}"
  else
    read -r -p "$prompt: " answer >&2 2>&1
    echo "$answer"
  fi
}

# ask_required PROMPT → repeats until non-empty
ask_required() {
  local prompt="$1" answer
  while true; do
    read -r -p "$prompt: " answer >&2 2>&1
    if [ -n "$answer" ]; then
      echo "$answer"
      return 0
    fi
    echo "  (required)" >&2
  done
}

# ask_yn PROMPT DEFAULT(y|n) → "true" or "false"
ask_yn() {
  local prompt="$1" default="$2" answer
  local hint
  if [ "$default" = "y" ]; then
    hint="Y/n"
  else
    hint="y/N"
  fi
  read -r -p "$prompt [$hint]: " answer >&2 2>&1
  answer="${answer:-$default}"
  answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')
  case "$answer" in
    y|yes|true) echo "true" ;;
    *) echo "false" ;;
  esac
}

# ask_secret PROMPT → reads without echoing
ask_secret() {
  local prompt="$1" answer
  read -r -s -p "$prompt: " answer >&2 2>&1
  echo "" >&2
  echo "$answer"
}

# ask_choice PROMPT DEFAULT OPTIONS(space-separated) → chosen option
ask_choice() {
  local prompt="$1" default="$2" options="$3" answer
  while true; do
    read -r -p "$prompt ($options) [$default]: " answer >&2 2>&1
    answer="${answer:-$default}"
    for opt in $options; do
      if [ "$answer" = "$opt" ]; then
        echo "$answer"
        return 0
      fi
    done
    echo "  must be one of: $options" >&2
  done
}
