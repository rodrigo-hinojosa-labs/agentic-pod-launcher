#!/usr/bin/env bats
# Story B (003-bootstrap-hardening): before creating a fork, detect the template
# repo's visibility. A fork of a PUBLIC repo can't be private (GitHub 422), so if
# the operator asked for a private fork against a public template, warn — and in
# a non-interactive run, default to disable-fork (never silently public, FR-B4).
# gh is mocked; host-only, no network (Principle III).
#
# Decision is printed to stdout as "<enabled> <private>"; warnings/notice go to
# stderr. Tests capture stdout via command substitution (2>/dev/null) and stderr
# separately (2>&1 >/dev/null). Stub vars are exported so the mocked gh inherits.

load helper

setup() {
  setup_tmp_dir
  load_lib fork
  load_lib wizard
  mkdir -p "$TMP_TEST_DIR/bin"
  cat > "$TMP_TEST_DIR/bin/gh" <<'STUB'
#!/bin/bash
# Mock: `gh api repos/OWNER/REPO --jq .visibility`
[ "${GH_STUB_FAIL:-0}" = "1" ] && exit 1
echo "${GH_STUB_VISIBILITY:-public}"
STUB
  chmod +x "$TMP_TEST_DIR/bin/gh"
  export PATH="$TMP_TEST_DIR/bin:$PATH"
}

teardown() { teardown_tmp_dir; }

@test "gh_get_repo_visibility parses owner/repo from URL and returns visibility" {
  export GH_STUB_VISIBILITY=public
  run gh_get_repo_visibility "https://github.com/acme/tmpl.git" "tok"
  [ "$status" -eq 0 ]
  [ "$output" = "public" ]
}

@test "gh_get_repo_visibility returns non-zero (empty) when gh errors" {
  export GH_STUB_FAIL=1
  run gh_get_repo_visibility "https://github.com/acme/tmpl" "tok"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "fork_resolve_visibility: fork disabled → unchanged, no probe" {
  export GH_STUB_FAIL=1   # must NOT be called
  local dec
  dec=$(fork_resolve_visibility "https://github.com/acme/tmpl" "false" "true" "tok" 2>/dev/null)
  [ "$dec" = "false true" ]
}

@test "fork_resolve_visibility: private not requested → unchanged, no probe" {
  export GH_STUB_FAIL=1   # must NOT be called
  local dec
  dec=$(fork_resolve_visibility "https://github.com/acme/tmpl" "true" "false" "tok" 2>/dev/null)
  [ "$dec" = "true false" ]
}

@test "fork_resolve_visibility: private template + private requested → no conflict" {
  export GH_STUB_VISIBILITY=private
  local dec
  dec=$(fork_resolve_visibility "https://github.com/acme/tmpl" "true" "true" "tok" 2>/dev/null)
  [ "$dec" = "true true" ]
}

@test "fork_resolve_visibility: public template + private + non-interactive → disable-fork + notice" {
  export GH_STUB_VISIBILITY=public FORK_NONINTERACTIVE=1
  local dec err
  dec=$(fork_resolve_visibility "https://github.com/acme/tmpl" "true" "true" "tok" 2>/dev/null)
  [ "$dec" = "false false" ]
  err=$(fork_resolve_visibility "https://github.com/acme/tmpl" "true" "true" "tok" 2>&1 >/dev/null)
  [[ "$err" == *"PUBLIC"* ]]
}

@test "fork_resolve_visibility: non-interactive + FORK_ACCEPT_PUBLIC=1 → proceed public" {
  export GH_STUB_VISIBILITY=public FORK_NONINTERACTIVE=1 FORK_ACCEPT_PUBLIC=1
  local dec
  dec=$(fork_resolve_visibility "https://github.com/acme/tmpl" "true" "true" "tok" 2>/dev/null)
  [ "$dec" = "true false" ]
}

@test "fork_resolve_visibility: interactive choice proceed-public → keep fork (public)" {
  export GH_STUB_VISIBILITY=public FORK_NONINTERACTIVE=0
  ask_choice() { echo "proceed-public"; }   # stub the interactive prompt
  local dec
  dec=$(fork_resolve_visibility "https://github.com/acme/tmpl" "true" "true" "tok" 2>/dev/null)
  [ "$dec" = "true false" ]
}

@test "fork_resolve_visibility: interactive choice disable-fork → disable" {
  export GH_STUB_VISIBILITY=public FORK_NONINTERACTIVE=0
  ask_choice() { echo "disable-fork"; }
  local dec
  dec=$(fork_resolve_visibility "https://github.com/acme/tmpl" "true" "true" "tok" 2>/dev/null)
  [ "$dec" = "false false" ]
}

@test "fork_resolve_visibility: probe failure → non-zero (caller fails loud)" {
  export GH_STUB_FAIL=1
  run fork_resolve_visibility "https://github.com/acme/tmpl" "true" "true" "tok"
  [ "$status" -ne 0 ]
}
