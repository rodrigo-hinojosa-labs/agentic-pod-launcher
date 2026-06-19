#!/usr/bin/env bats
# US2 — single source of truth for managed toolchain versions.
#
# scripts/lib/versions.sh holds the default channels + the documented floor;
# agent.yml records the resolved concrete versions; docker-compose passes
# them as build args; the Dockerfile consumes them. The ONLY accepted second
# copy is the Dockerfile ARG default, which a drift-guard (tests/versions.bats)
# keeps equal to the versions.sh floor. These invariants fail if anyone
# re-introduces an independent, drift-prone version literal.

load helper

@test "no-drift: host gum is single-sourced from versions.sh (no stale 0.14.5 literal)" {
  grep -q 'AGENTIC_FLOOR_GUM' "$REPO_ROOT/setup.sh"
  # The old hardcoded gum pin must be gone — bumping gum is a versions.sh edit.
  ! grep -q '0\.14\.5' "$REPO_ROOT/setup.sh"
}

@test "no-drift: setup.sh records the base image via the resolver (no alpine literal)" {
  # The docker block records alpine:${resolved}; no hardcoded alpine:X.Y here.
  ! grep -qE 'alpine:[0-9]' "$REPO_ROOT/setup.sh"
}

@test "no-drift: Dockerfile FROM is build-arg driven (no FROM alpine literal)" {
  ! grep -qE '^FROM alpine:' "$REPO_ROOT/docker/Dockerfile"
}
