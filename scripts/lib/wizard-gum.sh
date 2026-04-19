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

# _abort_if_interrupted RC  → exit the wizard cleanly when gum catches Ctrl+C.
# gum returns 130 on SIGINT (the standard convention) and 2 when the user
# hits Esc in gum choose. Either one means "I want out", not "accept
# default and keep going". We print a one-line note and exit so the whole
# wizard stops instead of silently advancing question by question.
_abort_if_interrupted() {
  local rc="$1"
  if [ "$rc" -eq 130 ] || [ "$rc" -eq 2 ]; then
    printf '\n✗ Wizard aborted (Ctrl+C). No files were written.\n' >&2
    exit 130
  fi
}

# ask PROMPT DEFAULT → user input or default
# The default is pre-filled into the field (gum --value) so it can be
# accepted with a single Enter. To replace it with a custom value, press
# Ctrl+U to clear the field in one keystroke, then type. Ctrl+C aborts
# the whole wizard via _abort_if_interrupted.
ask() {
  local prompt="$1" default="$2" result rc=0
  if [ -n "$default" ]; then
    result=$("$GUM" input --prompt "$prompt: " --value "$default") || rc=$?
  else
    result=$("$GUM" input --prompt "$prompt: " --placeholder "...") || rc=$?
  fi
  _abort_if_interrupted "$rc"
  result="${result:-$default}"
  _log_qa "$prompt" "$result"
  echo "$result"
}

# ask_required PROMPT → repeats until non-empty. Ctrl+C aborts the wizard.
ask_required() {
  local prompt="$1" result="" rc=0
  while [ -z "$result" ]; do
    result=$("$GUM" input --prompt "$prompt: ") || rc=$?
    _abort_if_interrupted "$rc"
  done
  _log_qa "$prompt" "$result"
  echo "$result"
}

# ask_yn PROMPT DEFAULT(y|n) → "true" or "false". Ctrl+C aborts.
ask_yn() {
  local prompt="$1" default="$2"
  local default_flag
  if [ "$default" = "y" ]; then
    default_flag="--default=yes"
  else
    default_flag="--default=no"
  fi
  local rc=0
  "$GUM" confirm "$prompt" $default_flag || rc=$?
  _abort_if_interrupted "$rc"
  if [ "$rc" -eq 0 ]; then
    _log_qa "$prompt" "yes"
    echo "true"
  else
    _log_qa "$prompt" "no"
    echo "false"
  fi
}

# ask_secret PROMPT → reads without echoing. Ctrl+C aborts.
ask_secret() {
  local prompt="$1" result rc=0
  result=$("$GUM" input --password --prompt "$prompt: ") || rc=$?
  _abort_if_interrupted "$rc"
  if [ -n "$result" ]; then
    _log_qa "$prompt" "********"
  else
    _log_qa "$prompt" "(skipped)"
  fi
  echo "$result"
}

# ask_choice PROMPT DEFAULT OPTIONS(space-separated) → chosen option.
# Ctrl+C / Esc aborts the wizard.
ask_choice() {
  local prompt="$1" default="$2" options="$3"
  local args=(--header "$prompt" --selected "$default")
  local opt
  for opt in $options; do
    args+=("$opt")
  done
  local result rc=0
  result=$("$GUM" choose "${args[@]}") || rc=$?
  _abort_if_interrupted "$rc"
  result="${result:-$default}"
  _log_qa "$prompt" "$result"
  echo "$result"
}
