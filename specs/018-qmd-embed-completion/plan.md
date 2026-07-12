# Implementation Plan: qmd Embed Completion (multi-pass beyond the 30-minute session cap)

**Branch**: `018-qmd-embed-completion` | **Date**: 2026-07-10 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/018-qmd-embed-completion/spec.md`

## Summary

`qmd embed` hard-caps a single embedding session at 30 minutes (`store.js:1377`,
`maxDuration: 30 * 60 * 1000`), so a first-time embedding of a large vault stops partway and the
scheduled re-index never resumes it (its `vault unchanged → skip embed` guard). The fix loops
embedding **around** the engine — never patching it — inside the existing maintenance critical section
`_qmd_reindex_locked` (`scripts/lib/qmd_index.sh`, mirrored to `docker/scripts/lib/`): a single
maintenance invocation runs successive `qmd embed` passes (each a fresh 30-minute session) until
coverage is complete, no forward progress is made, or a fixed internal pass cap is hit. The
`vault unchanged` guard is amended to resume when embeddings are still pending. Outcome
(complete / partial / stalled + residual pending count) is recorded in the existing state file. All
three clarified decisions (loop-around, single-invocation loop, fixed constant) come from the
2026-07-10 Clarifications session.

## Technical Context

**Language/Version**: POSIX-ish `bash` (host launcher + image-baked libs); the changed file is
`scripts/lib/qmd_index.sh`, sourced by `heartbeatctl` and by bats tests.

**Primary Dependencies**: `jq` (state file), `flock` (existing concurrency guard), the managed `qmd`
prefix (`@tobilu/qmd@2.5.3`) invoked via `_qmd_run`. No new dependencies.

**Storage**: qmd index at `<cache_root>/index.sqlite`; maintenance state JSON at
`/workspace/scripts/heartbeat/qmd-index.json` (`QMD_INDEX_STATE_FILE`). Both already exist.

**Testing**: `bats` host suite (no Docker) with a stubbed `qmd`/`_qmd_run`; `DOCKER_E2E=1`
`tests/docker-e2e-qmd.bats`; `shellcheck -S error`.

**Target Platform**: Both deployment modes — Docker (Alpine musl) and local (systemd/glibc). The
30-minute cap is engine-level and libc-agnostic, so the fix lives in the shared, mirrored lib.

**Project Type**: CLI/infra launcher (bash), single project. No web/mobile.

**Performance Goals**: A first-time bulk completion may run several 30-minute sessions (>1h total) as a
one-time catch-up; routine incremental maintenance MUST still finish in a single pass.

**Constraints**: MUST NOT patch/modify the qmd engine; MUST NOT add `agent.yml` schema; MUST NOT weaken
the container privilege model; MUST NOT expose secrets in logs/argv/state; MUST be bounded (no infinite
loop); MUST survive `./setup.sh --regenerate` and stay mirrored host↔docker.

**Scale/Scope**: Vaults up to a few thousand documents (ferrari: ~2,423 chunks / ~638 docs). Change is
confined to `_qmd_reindex_locked`, `qmd_write_state`, two new helpers, and their tests.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — PASS. No derived/rendered file changes; the max-passes cap is a
  fixed lib constant (env-overridable for tests only), NOT an `agent.yml` field (Clarifications
  2026-07-10). The lib change is carried into the image by the existing
  `mirror_catalog_to_docker` COPY at `--regenerate`; behavior reproduces from `agent.yml` via
  `--regenerate` with no hand-edited runtime file.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS / N/A. No `docker/` privilege changes, no new
  capability/mount/socket, no compose edit; `docker exec` paths unchanged (`-u agent`). The loop runs
  inside the same non-root maintenance process.
- [x] **III. Test-First, Host-Runnable** — PASS. New bats coverage (host, no Docker, stubbed qmd)
  written before implementation; DOCKER_E2E extended and gated behind `DOCKER_E2E=1`; `shellcheck -S
  error` clean; the lib keeps its `BASH_SOURCE` no-side-effect-on-source guard.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. Re-runnable (incremental embed; completion is
  content-derived from qmd's pending count / "all embedded" signal, not mtime); degrades to
  partial/stalled and always `return 0` so it never crashes the supervisor/heartbeat; bounded by a
  pass cap + no-progress stop.
- [x] **V. Workspace-Is-the-Agent** — PASS. State stays in `qmd-index.json` under the workspace;
  redaction of qmd stderr preserved; no secrets logged; backup branches untouched.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. No new/dup pins; the max-passes constant is
  single-sourced in the lib. `VERSION` 0.11.0 → 0.12.0 and `CHANGELOG.md` updated (user-facing:
  the RAG now finishes embedding a large vault).

**Result**: All principles PASS. No violations → Complexity Tracking empty.

## Project Structure

### Documentation (this feature)

```text
specs/018-qmd-embed-completion/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── embed-completion.md
│   └── reindex-state.md
├── checklists/
│   └── requirements.md  # from /speckit-specify
└── tasks.md             # /speckit-tasks output (NOT created here)
```

### Source Code (repository root)

```text
scripts/lib/qmd_index.sh          # PRIMARY change: _qmd_reindex_locked loop + guard;
                                  #   new _qmd_pending_count, _qmd_embed_until_complete;
                                  #   qmd_write_state gains optional pending arg
docker/scripts/lib/qmd_index.sh   # MIRROR (populated by setup.sh::mirror_catalog_to_docker at
                                  #   --regenerate); must match the host copy
tests/qmd-embed-completion.bats   # NEW host bats: loop, guard, stall, state outcomes (stubbed qmd)
tests/qmd-index.bats              # existing state-shape assertions (add `pending` coverage)
tests/docker-e2e-qmd.bats         # extend: assert reindex drives pending→0 + records complete
VERSION                           # 0.11.0 → 0.12.0
CHANGELOG.md                      # 018 entry
```

No new modules/services; the change is localized to the qmd maintenance library and its tests.

## Complexity Tracking

No constitutional violations. No new capabilities, mounts, dependencies, or `agent.yml` schema. The
only added surface is two small shell helpers + one optional state field, all inside the existing
mirrored lib. Table intentionally empty.

## Phase 0 — Research

See [research.md](./research.md). All unknowns resolved (root cause confirmed by reading the qmd dist;
mechanism/operational-model/bounds decided in Clarifications). No open NEEDS CLARIFICATION.

## Phase 1 — Design & Contracts

- [data-model.md](./data-model.md) — the maintenance state entity (extended) + the pending-count signal.
- [contracts/embed-completion.md](./contracts/embed-completion.md) — behavioral contract of the
  embed-until-complete loop and the amended guard.
- [contracts/reindex-state.md](./contracts/reindex-state.md) — the `qmd-index.json` schema contract
  (backward-compatible extension).
- [quickstart.md](./quickstart.md) — how to validate (host bats, DOCKER_E2E, ferrari multi-pass gate).
- Agent context: CLAUDE.md SPECKIT block updated to reference this plan.

**Post-design Constitution re-check**: still all PASS — the design added no derived files, no privilege
changes, no `agent.yml` surface, and keeps the mirror + test-first + fail-silent guarantees.
