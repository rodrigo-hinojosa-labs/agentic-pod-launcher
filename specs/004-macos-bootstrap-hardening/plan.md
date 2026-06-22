# Implementation Plan: macOS bootstrap hardening (MCP + plugin reliability)

**Branch**: `004-macos-bootstrap-hardening` | **Date**: 2026-06-21 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/004-macos-bootstrap-hardening/spec.md` · Research: [research.md](./research.md)

## Summary

Three independent image-baked fixes so a from-scratch macOS scaffold reaches a fully-functional agent with no manual repair. All land in one PR (refine decision), implemented P1→P2→P3:

- **P1** — pre-warm the default npx MCP packages (`@modelcontextprotocol/server-filesystem`, `@bitbonsai/mcpvault`) into an off-bind-mount image cache (`NPM_CONFIG_CACHE=/opt/npm-cache` + `PREFER_OFFLINE` + a build-time warm step), and pin the vault spec so the runtime `npx -y` resolves warm — mirroring the existing uv `/opt` pattern. (`context7` is a plugin, not an npx MCP — out of P1 scope.)
- **P2** — replace the one-shot post-login plugin install with a non-blocking, tick-based retry in the watchdog: on the credential flip, retry `ensure_all_plugins_installed` each 2s tick for a ~120s budget until every plugin carries its `.installed-ok` sentinel, then kick once for `--channels`. No blocking loop, no per-tick re-kick (crash-budget safe).
- **P3** — replace the deprecated `npx @modelcontextprotocol/server-github` with GitHub's official `github-mcp-server` Go binary (v1.4.0, statically linked → runs on Alpine/musl), baked into `/usr/local/bin` and invoked `github-mcp-server stdio`; `.env` `GITHUB_PAT` unchanged.

## Technical Context

**Language/Version**: Bash (busybox/ash where it runs in-container; bash on host), Dockerfile, Alpine 3.24.1 (node 24, npm 11), one Go binary (`github-mcp-server` v1.4.0)

**Primary Dependencies**: Docker (build + opt-in e2e), npm/npx, the repo's existing uv/bun/gum baked-tool pattern, the GitHub release asset for `github-mcp-server`

**Storage**: ephemeral image paths off the bind-mount — `/opt/npm-cache` (npm cacache + `_npx`), `/usr/local/bin/github-mcp-server`. Durable agent state stays under `.state/` (unchanged).

**Testing**: `bats` default suite (no Docker) asserts the Dockerfile/template **shape** + the host-sourced retry lib; `DOCKER_E2E=1` asserts runtime **behavior** (warm npx connect, github binary runs, post-login plugin install)

**Target Platform**: macOS Docker Desktop (VirtioFS bind-mount) is the failing environment; Linux must not regress

**Project Type**: CLI / launcher (bash + a baked Docker image) — single project, no frontend/backend split

**Performance Goals**: npx/github MCP servers connect within Claude's MCP handshake window (no in-window download); post-login plugins install within a ~120s bounded budget

**Constraints**: least-privilege container unchanged (no DinD, no new caps/mounts); offline-capable handshake for the default MCP set; watchdog poll must not be starved; crash budget (5/300s) must not be tripped by the retry

**Scale/Scope**: 3 fixes, ~6–9 files (`docker/Dockerfile`, `docker/scripts/start_services.sh`, `modules/mcp-json.tpl`, `scripts/lib/versions.sh`, `tests/*`, `CHANGELOG.md`, `VERSION`), one image rebuild

## Constitution Check

*Gate evaluated against `.specify/memory/constitution.md` v1.0.0. No violations — no Complexity Tracking entries required.*

- [x] **I. Single Source of Truth** — `.mcp.json` changes (vault pin, github command/args) are rendered from `agent.yml` via `modules/mcp-json.tpl`; pinned versions recorded in `versions.sh`/build ARGs. All survive `./setup.sh --regenerate`. No hand-edited derived files.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — no new capability, mount, or socket. The github MCP is a baked binary in `/usr/local/bin` (NOT the rejected docker-in-docker image). `cap_drop: ALL` / `no-new-privileges` / `-u agent` / root-owned crontab untouched.
- [x] **III. Test-First, Host-Runnable** — each fix ships `bats` coverage red→green; the default suite runs without Docker (asserts Dockerfile/template shape + the sourced retry lib); image behavior gated behind `DOCKER_E2E=1`; `shellcheck -S error` clean; sourced libs keep no-side-effect-on-load.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — the post-login retry is idempotent (guarded by the `.installed-ok` sentinel), bounded by a deadline (never unbounded), kicks once (no crash-budget churn), and never crashes the watchdog; the build warm step is `|| true` fail-soft.
- [x] **V. Workspace-Is-the-Agent** — durable state stays under `.state/`. The npm cache is **deliberately** moved OFF `.state` to an image path because it is disposable cache, not agent state (same rationale as the existing uv `/opt` cache). Secrets unchanged (`GITHUB_PAT`), never logged/committed; `--restore-from-fork` unaffected.
- [x] **VI. Reproducible, Pinned Dependencies** — the two npm MCP packages and `github-mcp-server` are pinned via build ARGs and tracked in `versions.sh` so the existing Dockerfile-vs-`versions.sh` drift-guard stays meaningful; auto-updater stays off; no new duplicate pins; `CHANGELOG.md` + `VERSION` updated (FR-010).

## Project Structure

### Documentation (this feature)

```
specs/004-macos-bootstrap-hardening/
├── spec.md           # what + why (refined)
├── research.md       # Phase 0 — verified mechanisms for P1/P2/P3
├── plan.md           # this file
├── quickstart.md     # how to verify each fix (bats + DOCKER_E2E)
└── checklists/
    └── requirements.md
```

*No `data-model.md` or `contracts/` — this is an internal launcher/infra fix with no new data entities or external interface contracts. The relevant "entities" (npm cache, plugin set, MCP server definitions) are existing structures described in the spec.*

### Source Code (repository root — existing files touched)

```
docker/
├── Dockerfile                    # P1: NPM_CONFIG_CACHE + warm step; P3: github-mcp-server download stanza
└── scripts/
    └── start_services.sh         # P2: _post_login_plugin_retry + _all_plugins_installed + deadline in _check_auth_flip
modules/
└── mcp-json.tpl                  # P1: pin vault spec; P3: github command/args → binary stdio
scripts/lib/
└── versions.sh                   # P1/P3: pin tracking for the drift guard (Principle VI)
tests/
├── docker-render.bats / modules-render.bats   # P1 vault pin, P3 github command shape
├── versions.bats                 # P1/P3 pin/drift assertions
├── start-services-*.bats         # P2 retry-budget seams
└── docker-e2e-*.bats             # behavior: warm npx connect, github binary, post-login install
CHANGELOG.md · VERSION            # FR-010
```

**Structure Decision**: Single-project launcher. All changes are in the existing `docker/` (image-baked) and `modules/`/`scripts/lib/` (render + pinning) paths; no new modules or directories. Tests follow the established `tests/*.bats` split (default no-Docker shape tests + opt-in `DOCKER_E2E` behavior tests).

## Complexity Tracking

*No constitution violations — no entries.*
