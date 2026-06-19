#!/usr/bin/env bats
# Unit tests for scripts/lib/versions.sh — default channels + the
# best-effort upstream resolver. No live network: the resolver's HTTP
# fetch is dependency-injected via _versions_fetch so tests stub it.

load helper

setup() {
  setup_tmp_dir
  # versions.bats exercises the REAL resolver (fetch+parse), so opt out of
  # the suite-wide offline default (helper.bash); individual tests that want
  # the offline path set AGENTIC_VERSIONS_OFFLINE explicitly.
  export AGENTIC_VERSIONS_OFFLINE=""
}

teardown() { teardown_tmp_dir; }

@test "versions.sh sources without side effects (no output, exit 0)" {
  run bash -c "source '$REPO_ROOT/scripts/lib/versions.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "versions.sh defines the default channels" {
  load_lib versions
  [ "$AGENTIC_CHANNEL_CLAUDE_CODE" = "stable" ]
  [ "$AGENTIC_CHANNEL_ALPINE" = "latest" ]
  [ "$AGENTIC_CHANNEL_UV" = "latest" ]
  [ "$AGENTIC_CHANNEL_BUN" = "latest" ]
  [ "$AGENTIC_CHANNEL_GUM" = "latest" ]
}

# Stub the injected HTTP fetch with representative upstream payloads.
_stub_fetch_ok() {
  _versions_fetch() {
    case "$1" in
      *registry.npmjs.org*) printf '%s' '{"dist-tags":{"stable":"2.1.170","latest":"2.1.181","next":"2.1.183"}}' ;;
      *astral-sh/uv*)       printf '%s' '{"tag_name":"0.11.22"}' ;;
      *oven-sh/bun*)        printf '%s' '{"tag_name":"bun-v1.3.14"}' ;;
      *charmbracelet/gum*)  printf '%s' '{"tag_name":"v0.17.0"}' ;;
      *alpinelinux.org*)    printf 'version: 3.24.1\n' ;;
      *) return 1 ;;
    esac
  }
}

@test "versions_resolve claude_code reads the npm stable dist-tag (not latest/next)" {
  load_lib versions
  _stub_fetch_ok
  run versions_resolve claude_code
  [ "$status" -eq 0 ]
  [ "$output" = "2.1.170" ]
}

@test "versions_resolve uv reads the github releases/latest tag" {
  load_lib versions
  _stub_fetch_ok
  run versions_resolve uv
  [ "$status" -eq 0 ]
  [ "$output" = "0.11.22" ]
}

@test "versions_resolve bun strips the bun-v prefix" {
  load_lib versions
  _stub_fetch_ok
  run versions_resolve bun
  [ "$status" -eq 0 ]
  [ "$output" = "1.3.14" ]
}

@test "versions_resolve gum strips the leading v" {
  load_lib versions
  _stub_fetch_ok
  run versions_resolve gum
  [ "$status" -eq 0 ]
  [ "$output" = "0.17.0" ]
}

@test "versions_resolve alpine reads the latest-stable release version" {
  load_lib versions
  _stub_fetch_ok
  run versions_resolve alpine
  [ "$status" -eq 0 ]
  [ "$output" = "3.24.1" ]
}

@test "versions_resolve falls back to the floor and returns non-zero when offline" {
  load_lib versions
  _versions_fetch() { return 1; }
  run versions_resolve uv
  [ "$status" -ne 0 ]
  [ -n "$output" ]
}

@test "AGENTIC_VERSIONS_OFFLINE returns the floor and never queries upstream" {
  load_lib versions
  # If the resolver wrongly fetched, it would return 9.9.9 from this stub.
  _versions_fetch() { printf '%s' '{"dist-tags":{"stable":"9.9.9"},"tag_name":"9.9.9"}'; }
  AGENTIC_VERSIONS_OFFLINE=1 run versions_resolve claude_code
  [ "$output" = "2.1.170" ]
  AGENTIC_VERSIONS_OFFLINE=1 run versions_resolve uv
  [ "$output" = "0.11.22" ]
}

@test "versions_resolve rejects an unknown component" {
  load_lib versions
  run versions_resolve nonsense
  [ "$status" -ne 0 ]
}

@test "Dockerfile FROM is build-arg driven (no hardcoded alpine pin)" {
  local df="$REPO_ROOT/docker/Dockerfile"
  grep -Eq '^ARG BASE_IMAGE=' "$df"
  grep -Eq '^FROM \$\{BASE_IMAGE\}' "$df"
  run grep -Eq '^FROM alpine:[0-9]' "$df"
  [ "$status" -ne 0 ]
}

@test "Dockerfile ARG version defaults match the versions.sh floor (drift guard)" {
  load_lib versions
  local df="$REPO_ROOT/docker/Dockerfile"
  grep -Eq "^ARG BASE_IMAGE=alpine:${AGENTIC_FLOOR_ALPINE}\$" "$df"
  grep -Eq "^ARG GUM_VERSION=${AGENTIC_FLOOR_GUM}\$" "$df"
  grep -Eq "^ARG UV_VERSION=${AGENTIC_FLOOR_UV}\$" "$df"
  grep -Eq "^ARG BUN_VERSION=${AGENTIC_FLOOR_BUN}\$" "$df"
  grep -Eq "^ARG CLAUDE_CODE_VERSION=${AGENTIC_FLOOR_CLAUDE_CODE}\$" "$df"
}

@test "Dockerfile sets UV_PYTHON_PREFERENCE=only-system (uv 0.8.0 guard)" {
  grep -Eq 'UV_PYTHON_PREFERENCE=only-system' "$REPO_ROOT/docker/Dockerfile"
}
