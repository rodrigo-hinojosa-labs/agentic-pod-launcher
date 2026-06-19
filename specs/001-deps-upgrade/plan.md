# Implementation Plan: Reproducible In-Container Dependency Upgrades

**Branch**: `001-deps-upgrade` | **Date**: 2026-06-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/001-deps-upgrade/spec.md`

## Summary

Make the agent's image toolchain (Claude Code, the Alpine base, `uv`, `bun`,
`gum`) track the latest stable of the moment from a single declared place that
the documented build actually honors, with no hardcoded version literals and no
drift. Approach: the launcher ships only *channels* (`scripts/lib/versions.sh`:
Claude Code → `stable`, others → latest stable) plus a resolver; at scaffold,
`--regenerate`, and an explicit `agentctl versions --upgrade` the resolver queries
each upstream, resolves the latest stable, and **records the concrete version into
`agent.yml`** (`docker:` block). `render.sh` flattens those into
`docker-compose.yml` `build.args`, consumed as `ARG`s by the Dockerfile (including
`FROM alpine:${ALPINE_VERSION}`). Builds use the recorded concrete versions
(reproducible); runtime never auto-updates. `agentctl versions [--check]` reports
recorded-vs-latest via a best-effort upstream query that degrades to "unknown"
offline. First recorded set (resolved 2026-06-18): Claude Code `stable` 2.1.170,
Alpine 3.24.1, `uv` 0.11.22, `bun` 1.3.14, `gum` 0.17.0 — see
[research.md](./research.md).

## Technical Context

**Language/Version**: Bash 4+ (host launcher + image-baked scripts); POSIX `sh`
for in-container `start_services.sh`; Alpine-baked toolchain (Node, Python, `uv`,
`bun`, `gum`) consumed by the image.

**Primary Dependencies**: `yq` v4 + `jq` (config read/write), `scripts/lib/render.sh`
(template engine), Docker + Compose v2 (`build.args`), `curl`/`jq` for the live
upstream version query. No new runtime libraries are introduced.

**Storage**: `agent.yml` `docker:` block holds the recorded concrete versions (the
per-agent SSOT); `scripts/lib/versions.sh` holds the default *channels* + resolver;
no database. Rendered outputs: `docker-compose.yml`, plus the image built from
`docker/Dockerfile`.

**Testing**: `bats-core` host suite (default, no Docker) for render/seed/no-drift/
schema/CLI; opt-in `DOCKER_E2E=1` suite for the `claude --version`-in-container
assertion. `shellcheck -S error` on all shell.

**Target Platform**: macOS/Linux host (the launcher); Alpine Linux container (the
agent). Both BSD and GNU `sed` tolerated.

**Project Type**: CLI / scaffolding tool (single bash project; no app frontend/
backend split).

**Performance Goals**: `agentctl versions` (declared, no network) returns
instantly; `--check` (live upstream) bounded by a per-component network timeout
(target ≤ ~3s/component, all queries best-effort and skippable).

**Constraints**: Every change survives `./setup.sh --regenerate` deterministically;
`DISABLE_AUTOUPDATER=1` stays; the container capability set is unchanged; the
default test suite must not require Docker; the network is never a hard dependency
of building.

**Scale/Scope**: 5 managed components; ~9 repo files touched (1 new lib, Dockerfile,
compose template, setup.sh, schema lib, agentctl, tests, CHANGELOG, VERSION) plus
docs. Per-agent config gains 4 new optional `docker.*` leaves.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.0). Mark each PASS / N/A / VIOLATION; justify any VIOLATION in Complexity Tracking.*

- [x] **I. Single Source of Truth** — PASS. Per-agent SSOT is `agent.yml`'s
  `docker:` block (new `*_version` leaves); launcher-level defaults live once in
  `scripts/lib/versions.sh`. Compose `build.args` and the host-side gum download
  are *derived* from these, never independently maintained. A no-duplicate-pin
  bats test enforces that Dockerfile `ARG` defaults equal `versions.sh`. Survives
  `--regenerate` (regenerate re-stamps, like the existing `meta` block).
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS (N/A surface). Build-time
  `ARG`s do not touch the runtime capability set, `-u agent` exec, or crontab
  ownership. No new mount/socket/capability.
- [x] **III. Test-First, Host-Runnable** — PASS. New behavior is covered by host
  `bats` (render, seed, no-drift, schema, `versions` CLI). The container
  `claude --version` proof is an opt-in `DOCKER_E2E=1` test, not in the default
  suite. New `versions.sh` is `BASH_SOURCE`-guarded (no load-time side effects).
  `shellcheck` clean.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. `versions --check` is
  best-effort: each upstream query is timeout-bounded and degrades to "unknown"
  without erroring; it never blocks a build. Re-seeding `agent.yml` on regenerate
  is idempotent.
- [x] **V. Workspace-Is-the-Agent** — PASS (N/A surface). No change to `.state/`,
  secrets, backup branches, or `--restore-from-fork`.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. This feature *is* the
  embodiment: explicit pins with a single source, `build.args` passthrough so the
  documented build honors them, auto-updater stays off, duplicate literals
  removed/drift-guarded, `CHANGELOG.md` + `VERSION` updated for the bump.

**Result**: All gates PASS. No violations → Complexity Tracking empty.

## Project Structure

### Documentation (this feature)

```text
specs/001-deps-upgrade/
├── plan.md              # This file
├── research.md          # Phase 0 — concrete latest-stable targets + query methods
├── data-model.md        # Phase 1 — version fields, versions.sh constants, report shape
├── quickstart.md        # Phase 1 — operator + maintainer upgrade workflow
├── contracts/
│   └── cli-versions.md   # Phase 1 — `agentctl versions` + build-arg passthrough contract
├── checklists/
│   └── requirements.md   # Spec quality checklist (from /speckit-specify)
└── tasks.md             # Phase 2 — created by /speckit-tasks (NOT here)
```

### Source Code (repository root) — files this feature touches

```text
scripts/lib/versions.sh          # NEW — default channels (stable/latest) + best-effort upstream resolver funcs (BASH_SOURCE-guarded)
docker/Dockerfile                # ARG ALPINE_VERSION before FROM; ARGs for claude_code/uv/bun/gum default-sourced to versions.sh
modules/docker-compose.yml.tpl   # build.args: add CLAUDE_CODE_VERSION/ALPINE_VERSION/UV_VERSION/BUN_VERSION/GUM_VERSION ({{DOCKER_*}})
setup.sh                         # source versions.sh; seed agent.yml docker.*_version at scaffold; host gum download reads versions.sh; --regenerate re-stamps
scripts/lib/schema.sh            # add docker.*_version as optional/defaulted leaves (legacy-safe)
scripts/agentctl                 # new `versions [--check] [--json] [--upgrade]` subcommand + a doctor "toolchain versions" line
tests/versions.bats              # NEW — versions.sh, seed, no-duplicate-pin invariant, agentctl versions
tests/render.bats                # extend — docker.*_version → compose build.args
tests/docker-e2e-*.bats          # extend (opt-in) — declared claude_code_version honored by build → claude --version
CHANGELOG.md, VERSION            # bump for the user-facing change
docs/{getting-started,architecture}.md, README.md  # document the upgrade workflow + agentctl versions
```

**Structure Decision**: Single bash project; this feature is a horizontal change
across the existing render → compose → image pipeline plus the `agentctl` CLI. No
new top-level directory; one new shared lib (`scripts/lib/versions.sh`) following
the existing `scripts/lib/*.sh` `BASH_SOURCE`-guard convention.

## Phase 0 — Research (→ research.md)

Single external unknown: the current latest-stable version of each managed
component and the runnable "query latest" method for the P3 `--check` (dispatched
as a parallel web-research fan-out, one agent per component). Internal wiring
(render flattening `docker.x → $DOCKER_X`, compose `build.args`, `ARG` before
`FROM`, schema leaves, `agentctl` patterns) is already known from the repo
inventory and recorded as decisions in research.md.

## Phase 1 — Design (→ data-model.md, contracts/, quickstart.md)

- **data-model.md** — the `docker.*_version` leaves, `versions.sh` constant set,
  the seed→render→build dataflow, and the Outdated Report row shape.
- **contracts/cli-versions.md** — `agentctl versions [--check] [--json]` output
  contract + the compose-build-arg ↔ Dockerfile-ARG mapping.
- **quickstart.md** — operator upgrade flow (edit `agent.yml` → `--regenerate` →
  rebuild → verify) and maintainer default-bump flow.
- **Agent context** — update the `CLAUDE.md` SPECKIT block to point at this plan.

## Complexity Tracking

> No constitution violations — all six gates PASS. No entries.
