#!/usr/bin/env bats

load helper

setup() {
  load_lib wizard
}

@test "ask returns default when user just presses Enter" {
  result=$(ask "Your name" "Default Name" <<< "")
  [ "$result" = "Default Name" ]
}

@test "ask returns user input when provided" {
  result=$(ask "Your name" "Default Name" <<< "Alice")
  [ "$result" = "Alice" ]
}

@test "ask_yn returns 'true' for yes/y/Y/YES" {
  [ "$(ask_yn 'ok?' 'y' <<< 'y')" = "true" ]
  [ "$(ask_yn 'ok?' 'y' <<< 'Y')" = "true" ]
  [ "$(ask_yn 'ok?' 'y' <<< 'yes')" = "true" ]
  [ "$(ask_yn 'ok?' 'y' <<< '')" = "true" ]
}

@test "ask_yn returns 'false' for no/n/N/NO" {
  [ "$(ask_yn 'ok?' 'y' <<< 'n')" = "false" ]
  [ "$(ask_yn 'ok?' 'y' <<< 'N')" = "false" ]
  [ "$(ask_yn 'ok?' 'y' <<< 'no')" = "false" ]
  [ "$(ask_yn 'ok?' 'n' <<< '')" = "false" ]
}

@test "ask_required re-prompts when input empty until valid" {
  result=$(ask_required "Email" <<< $'\n\nalice@example.com')
  [ "$result" = "alice@example.com" ]
}

@test "ask_choice validates against allowed options" {
  result=$(ask_choice "Channel" "none" "none log telegram" <<< "telegram")
  [ "$result" = "telegram" ]
  result=$(ask_choice "Channel" "none" "none log telegram" <<< "")
  [ "$result" = "none" ]
}
