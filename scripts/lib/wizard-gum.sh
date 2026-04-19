#!/usr/bin/env bash
# Wizard helpers backed by gum. Requires $GUM to be set to the gum binary path.
#
# gum renders its interactive UI to stderr and emits the captured value to
# stdout. Do NOT silence stderr here — that would hide the prompt and make
# the wizard look frozen. The `|| fallback` branches catch Ctrl+C / errors.
#
# After each prompt returns we echo `  › prompt: answer` to stderr so the
# Q/A history stays in the terminal scrollback (gum clears its widget line
# when done). Stdout stays clean so callers can still capture the value.

# _log_qa PROMPT ANSWER  → stderr record of the exchange
_log_qa() {
  printf '  › %s: %s\n' "$1" "$2" >&2
}

# ask PROMPT DEFAULT → user input or default
# The default is shown as a placeholder hint (gray, inside the field) so the
# user can type immediately without having to delete a pre-filled value.
# Empty submit (just Enter) falls back to $default via the :- substitution.
ask() {
  local prompt="$1" default="$2" result
  if [ -n "$default" ]; then
    result=$("$GUM" input --prompt "$prompt: " --placeholder "$default") || result="$default"
  else
    result=$("$GUM" input --prompt "$prompt: " --placeholder "...") || result=""
  fi
  result="${result:-$default}"
  _log_qa "$prompt" "$result"
  echo "$result"
}

# ask_required PROMPT → repeats until non-empty
ask_required() {
  local prompt="$1" result=""
  while [ -z "$result" ]; do
    result=$("$GUM" input --prompt "$prompt: ") || result=""
  done
  _log_qa "$prompt" "$result"
  echo "$result"
}

# ask_yn PROMPT DEFAULT(y|n) → "true" or "false"
ask_yn() {
  local prompt="$1" default="$2"
  local default_flag
  if [ "$default" = "y" ]; then
    default_flag="--default=yes"
  else
    default_flag="--default=no"
  fi
  if "$GUM" confirm "$prompt" $default_flag; then
    _log_qa "$prompt" "yes"
    echo "true"
  else
    _log_qa "$prompt" "no"
    echo "false"
  fi
}

# ask_secret PROMPT → reads without echoing
ask_secret() {
  local prompt="$1" result
  result=$("$GUM" input --password --prompt "$prompt: ") || result=""
  if [ -n "$result" ]; then
    _log_qa "$prompt" "********"
  else
    _log_qa "$prompt" "(skipped)"
  fi
  echo "$result"
}

# ask_choice PROMPT DEFAULT OPTIONS(space-separated) → chosen option
ask_choice() {
  local prompt="$1" default="$2" options="$3"
  local args=(--header "$prompt" --selected "$default")
  local opt
  for opt in $options; do
    args+=("$opt")
  done
  local result
  result=$("$GUM" choose "${args[@]}") || result="$default"
  result="${result:-$default}"
  _log_qa "$prompt" "$result"
  echo "$result"
}
