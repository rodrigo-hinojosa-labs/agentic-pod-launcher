#!/usr/bin/env bats
# Unit tests for scripts/lib/wizard-gum.sh::_abort_if_interrupted.
#
# gum >= 0.15.0 changed the Esc exit code for `gum input`/`gum choose`
# from 2 to 1. The abort check must treat that as "user wants out" for
# input/choose, but NOT for `gum confirm` (where rc=1 is the legitimate
# "no" answer). These tests pin that widget-scoped contract.

load helper

setup() { load_lib wizard-gum; }

@test "input: Esc rc=1 (gum >=0.15) aborts the wizard" {
  run _abort_if_interrupted 1 input
  [ "$status" -eq 130 ]
  [[ "$output" == *"aborted"* ]]
}

@test "choose: Esc rc=1 (gum >=0.15) aborts the wizard" {
  run _abort_if_interrupted 1 choose
  [ "$status" -eq 130 ]
}

@test "input: legacy Esc rc=2 (gum <0.15) still aborts" {
  run _abort_if_interrupted 2 input
  [ "$status" -eq 130 ]
}

@test "any widget: Ctrl+C rc=130 aborts" {
  run _abort_if_interrupted 130 input
  [ "$status" -eq 130 ]
  run _abort_if_interrupted 130 confirm
  [ "$status" -eq 130 ]
}

@test "confirm: rc=1 is a legitimate 'no', must NOT abort" {
  run _abort_if_interrupted 1 confirm
  [ "$status" -eq 0 ]
}

@test "any widget: success rc=0 never aborts" {
  run _abort_if_interrupted 0 input
  [ "$status" -eq 0 ]
  run _abort_if_interrupted 0 confirm
  [ "$status" -eq 0 ]
}
