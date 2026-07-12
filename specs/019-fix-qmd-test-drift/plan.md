# Implementation Plan: Fix QMD Test Drift (post-016 contract)

**Branch**: `019-fix-qmd-test-drift` | **Date**: 2026-07-12 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/019-fix-qmd-test-drift/spec.md`

## Summary

Seven host tests fail permanently because they stub/assert the pre-016 QMD
invocation contract (`bunx` on PATH; `.mcp.json` `args[0]=@tobilu/qmd@X`).
Fix: re-stub through the CURRENT contract — a fake `qmd` engine binary planted
inside the managed prefix (`$QMD_CACHE_HOME/pkg/node_modules/.bin/qmd`) with a
pre-seeded `.installed-hash` so `_qmd_ensure_prefix` takes its skip path, plus
a no-op `bun` on PATH to satisfy the `command -v bun` guards — and update the
regenerate assertion to the post-T036 `.mcp.json` shape. Zero production-code
changes: every seam already exists (`QMD_CACHE_HOME`, `_qmd_manifest`,
`_qmd_sha` are exported by sourcing the lib). Bonus alignment of the
`docker-e2e-qmd.bats` Tier-1 stub is included ONLY as a syntax-level edit with
explicit deferral of Docker validation (documented, gated behind
`DOCKER_E2E=1`, cannot go red on the host suite).

## Technical Context

**Language/Version**: Bash 3.2+ (macOS host) / bats-core; library under test is
POSIX-leaning bash sourced by tests via `tests/helper.bash::load_lib`.

**Primary Dependencies**: bats-core, yq v4+, jq, git (host test deps — no
`bun`, no network). Library: `scripts/lib/qmd_index.sh` (post-016/017/018).

**Storage**: tmpdir-per-test (`setup_tmp_dir`); fake prefix under
`$QMD_CACHE_HOME/pkg`; stub call log `$QMD_STUB_LOG`.

**Testing**: `bats tests/qmd-index.bats tests/qmd-setup.bats
tests/regenerate.bats` standalone + full `bats tests/` (SC-001: 0 failures).

**Target Platform**: macOS dev host + Linux CI (no bun in either); Docker
paths untouched.

**Project Type**: Test-suite repair inside the launcher repo (single project).

**Performance Goals**: N/A (test runtime unchanged; no sleeps added).

**Constraints**: No production behavior change (FR-005); no bare `!`-negated
intermediate pipelines (FR-006, repo bats quirk); tests must pass without
`flock`/`timeout` (existing macOS skips preserved).

**Scale/Scope**: 3 test files repaired (7 failing tests), 1 gated e2e stub
aligned, 0 library/template changes expected.

## Verified Current Contract (evidence, read 2026-07-12)

- `_qmd_run PKG ARGS...` → `_qmd_ensure_prefix` then executes
  `"$prefix/node_modules/.bin/qmd" "$@"` — the engine binary receives
  `collection add …` / `update` / `embed` / `status` directly as `$1…`
  (`scripts/lib/qmd_index.sh:235-250`). `bunx` appears nowhere.
- `_qmd_prefix` = `$(qmd_cache_root)/pkg`; `qmd_cache_root` =
  `${QMD_CACHE_HOME:-$HOME/.cache/qmd}` (lines 62, 103) — both test-overridable.
- `_qmd_ensure_prefix` SKIPS `bun install` when
  `$prefix/.installed-hash` == `sha256(_qmd_manifest VER)` AND
  `$prefix/node_modules/.bin/qmd` is executable (lines 195-202). Both helper
  functions are available to tests after `source`.
- `_qmd_swap_sqlite_vec` is a guaranteed no-op off musl (`_qmd_on_musl ||
  return 0`, line 131) — safe on macOS/CI hosts.
- Guards: `_qmd_reindex_locked` and `_qmd_setup_locked` both require
  `command -v bun` (fail-silent skip otherwise) — the seam must provide a
  no-op `bun` on PATH or the code under test exits before reaching the stub.
- 018 changed the reindex success contract: after `update`, completion goes
  through `_qmd_embed_until_complete`, which needs the completion signal —
  `embed` output containing `All content hashes already have embeddings`, or
  `status` reporting `Pending: 0`. The repaired "vault changed → indexed"
  test MUST make its stub emit that signal (single-pass completion) or it
  would now end `partial`/`stalled` — this is 018-aware repair, not a revert.
- `.mcp.json` QMD entry post-T036 (`modules/mcp-json.tpl:73-77`):
  `command: {{QMD_MCP_COMMAND}}`, `args: []`, `env: {{QMD_MCP_ENV}}`.
  `QMD_MCP_COMMAND` = `/opt/agent-admin/scripts/qmd-mcp` (docker mode) or
  `<workspace>/scripts/local/agent-qmd-mcp.sh` (local mode) — `setup.sh:2018-2022`.
  The regenerate test's seed workspace backfills `deployment.mode=docker`.

## Constitution Check

*Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — PASS. No derived files or templates
  change; the regenerate test asserts the EXISTING rendered contract.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS/N-A. No container
  surface touched.
- [x] **III. Test-First, Host-Runnable** — PASS (this feature IS the
  principle): restores a truthful, Docker-free default suite; `tests/` is
  excluded from shellcheck by CI config, but the edited bats keep `-S error`
  discipline where applicable; no side effects added to sourced libs (no lib
  edits expected at all).
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS/N-A. Covered behaviors
  (fail-silent setup, sentinel guards) are preserved by FR-003; not modified.
- [x] **V. Workspace-Is-the-Agent** — PASS/N-A. No state layout or secret
  handling changes; stubs live in per-test tmpdirs.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. No dependency or pin
  changes. VERSION/CHANGELOG: test-only change, no user-facing behavior →
  no VERSION bump; a short CHANGELOG note under Unreleased for traceability.

**Post-design re-check**: PASS on all six — design introduces no library,
template, Dockerfile, or schema edits. If implementation DOES end up needing a
library seam (contingency in research.md R3), Principle III's "sourced libs
have no side effects" and the docker-mirror rule apply and the plan must be
amended.

## Project Structure

### Documentation (this feature)

```text
specs/019-fix-qmd-test-drift/
├── spec.md
├── checklists/requirements.md
├── plan.md              # This file
├── research.md          # Phase 0
├── data-model.md        # Phase 1 (seam + stub-log shapes)
├── quickstart.md        # Phase 1
├── contracts/
│   └── qmd-test-seam.md # Canonical post-016 stubbing contract for tests
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
tests/
├── qmd-index.bats        # replace _install_bunx* → _install_qmd_stub*; repair 2 tests
├── qmd-setup.bats        # same seam; repair 4 tests; keep flock/concurrency tests intact
├── regenerate.bats       # update 1 assertion block to post-T036 .mcp.json shape
└── docker-e2e-qmd.bats   # Tier-1 stub aligned syntactically; Docker validation deferred
```

No changes under `scripts/`, `docker/`, `modules/`, or `setup.sh`.

**Structure Decision**: test-only feature; all edits under `tests/`. The seam
contract doc lives in this feature's `contracts/` and is referenced from each
repaired file's header comment (FR-007).

## Complexity Tracking

No constitution violations. Table intentionally empty.
