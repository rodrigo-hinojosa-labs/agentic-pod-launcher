# Feature Specification: Fix QMD Test Drift (post-016 contract)

**Feature Branch**: `019-fix-qmd-test-drift`

**Created**: 2026-07-12

**Status**: Draft

**Input**: User description: "Corregir el drift de tests que dejó la migración 016 (bunx → prefijo bun install gestionado): 7 tests de la suite host fallan de forma permanente porque sus stubs y aserciones apuntan al contrato antiguo. (1) tests/qmd-index.bats: 2 tests stubbean un binario bunx que _qmd_run ya no invoca; (2) tests/qmd-setup.bats: 4 tests con el mismo patrón _install_bunx obsoleto; (3) tests/regenerate.bats: 1 test asume el shape antiguo de .mcp.json (args[0]=@tobilu/qmd@2.5.3, args[1]=mcp) que 016/T036 reemplazó por command={{QMD_MCP_COMMAND}} + args=[]. Objetivo: suite host 100% verde (0 not ok) para poder desplegar con confianza, preservando la INTENCIÓN de cobertura original de cada test (debounce por hash, manejo de error con hash preservado, setup con sentinel, backfill del pin de versión) contra el contrato vigente post-016/017/018. Sin cambios de comportamiento en producción: solo tests y, si hiciera falta, seams de test documentados."

## Context

Feature 016 (`016-qmd-native-deps`, PR #71) migrated every QMD invocation from
`bunx @tobilu/qmd@X` to a managed install prefix (`bun install` into
`$QMD_CACHE_HOME/prefix`, then run `prefix/node_modules/.bin/qmd` directly), and
its T036 rewired the MCP server entry in `.mcp.json` from
`command: bunx, args: [@tobilu/qmd@X, mcp]` to a per-mode wrapper
(`command: {{QMD_MCP_COMMAND}}, args: []`). Seven pre-016 host tests still stub
or assert the OLD contract, so they fail on every run — on macOS dev hosts AND
in CI. They are false negatives: the production code they cover works (verified
by 016/017/018 gates), but the suite can no longer prove it, and a permanently
red suite masks real regressions. Feature 018's release gate had to carve out
these 7 failures by hand — that carve-out must not become permanent.

Confirmed failing (bats run 2026-07-11, 1014 lines, 7 `not ok`, all
pre-existing — none touch files modified by 017/018):

| # | File | Test | Broken piece |
|---|------|------|--------------|
| 538 | `tests/qmd-index.bats` | `qmd_reindex runs update+embed and records indexed when the vault changed` | stubs `bunx` binary that `_qmd_run` never calls; stub log stays empty |
| 540 | `tests/qmd-index.bats` | `qmd_reindex records last_status=error and preserves the prior hash on bunx failure` | same stale stub; the "failure" never happens through the stub |
| 566 | `tests/qmd-setup.bats` | `qmd_setup_if_needed runs collection add + update + embed and writes the sentinel` | same `_install_bunx` pattern |
| 570 | `tests/qmd-setup.bats` | `qmd_setup_if_needed refreshes (update + embed, no re-add) when sentinel missing though index present` | same |
| 571 | `tests/qmd-setup.bats` | `qmd_setup_if_needed is fail-silent and writes no sentinel on bunx failure` | same |
| 573 | `tests/qmd-setup.bats` | `qmd_setup_if_needed sentinel-hit is a fast path that never reaches the lock (013 FR-015/T014)` | same (first call in the body never builds the sentinel) |
| 609 | `tests/regenerate.bats` | `--regenerate backfills vault.qmd.version and renders a valid qmd pin (pre-010 upgrade)` | asserts `.mcp.json` `args[0]="@tobilu/qmd@2.5.3"`, `args[1]="mcp"` — the pre-T036 shape |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Maintainer trusts a green suite before deploying (Priority: P1)

As the launcher maintainer, when I run the host test suite before cutting a
release or deploying to real hardware, I need `bats tests/` to exit with ZERO
failures on a healthy tree, so that any `not ok` line is a genuine regression
signal and not known noise I have to remember to ignore.

**Why this priority**: This is the whole point of the feature — the 7
permanent failures currently force every release gate to hand-triage the
suite output. That manual carve-out already had to be written into 018's
release notes and will otherwise be needed forever.

**Independent Test**: Run `bats tests/` on a clean checkout of this branch on
a macOS or Linux host with the standard test deps (bats, yq, jq, git) and NO
real `bun`/network access — the suite reports 0 failures.

**Acceptance Scenarios**:

1. **Given** a clean checkout with standard host test deps and no `bun`
   installed, **When** the full suite runs, **Then** it reports 0 `not ok`.
2. **Given** the same checkout, **When** only `tests/qmd-index.bats`,
   `tests/qmd-setup.bats`, or `tests/regenerate.bats` run standalone,
   **Then** each file passes in isolation.

---

### User Story 2 - Original coverage intent survives the re-stub (Priority: P2)

As the launcher maintainer, I need the 7 repaired tests to keep verifying the
SAME behaviors they were written for — against the current invocation contract
— so that fixing the suite does not silently delete coverage.

**Why this priority**: A trivial way to make the suite green is to delete or
gut the failing tests. That would remove the only host-side proof of: reindex
runs update+embed on a changed vault; a failed engine run records `error` and
preserves the prior hash for retry; first-boot setup runs add→update→embed and
writes the sentinel; a sentinel-less-but-indexed cache refreshes without
re-adding; a failed setup writes no sentinel; the sentinel hit is a pre-lock
fast path; and `--regenerate` backfills the version pin into a valid rendered
artifact.

**Independent Test**: For each repaired test, temporarily break the covered
behavior in the library (e.g., invert the sentinel write, drop the `update`
call) and confirm the repaired test FAILS — then restore. (Executed as a
spot-check during implementation, not committed.)

**Acceptance Scenarios**:

1. **Given** the repaired reindex tests, **When** the engine invocation is
   observed through the new seam, **Then** the assertions still distinguish
   `update` from `embed` calls and still verify state-file outcomes
   (`indexed`/`error`, hash preserved on failure).
2. **Given** the repaired setup tests, **When** first-boot setup runs through
   the new seam, **Then** `collection add` vs `update`/`embed` ordering, the
   sentinel file, and the fail-silent no-sentinel path are still asserted.
3. **Given** the repaired regenerate test, **When** `--regenerate` runs on a
   pre-010 workspace, **Then** the version-pin backfill into `agent.yml` is
   still asserted AND the rendered MCP entry is asserted against the CURRENT
   shape (per-mode wrapper command, empty args).

---

### User Story 3 - Test seams are documented and reusable (Priority: P3)

As a future contributor adding QMD-related tests, I need one documented,
canonical way to stub the QMD engine post-016, so the stale-stub mistake is
not re-introduced and new tests don't invent divergent patterns.

**Why this priority**: The root cause of this drift was an invocation-contract
change (016) that never updated the test seams. Making the canonical seam
explicit prevents a repeat when the contract evolves again.

**Independent Test**: The repaired test files carry a header comment naming
the seam and pointing at its contract doc; both reindex and setup tests use
the same pattern.

**Acceptance Scenarios**:

1. **Given** the repaired files, **When** a contributor reads the file header,
   **Then** the stubbing approach and its rationale (why not `bunx`) are
   stated, with a pointer to the feature 019 contract document.

---

### Edge Cases

- Suite must pass on hosts WITHOUT `bun` installed (macOS dev default, CI):
  the seam must neutralize any real-binary guard the library applies before
  invoking the engine, without weakening that guard in production.
- Suite must pass on hosts WITHOUT `flock`/`timeout` (macOS): existing skips
  stay intact; the re-stub must not accidentally un-skip or break them.
- The 2 already-passing tests in `qmd-index.bats` that use the stale stub
  pattern but happen to pass for other reasons (e.g., no-op paths where the
  stub is never reached) must keep passing unchanged in intent.
- `tests/docker-e2e-qmd.bats` Tier-1 carries the SAME stale `bunx` stub
  (found during 018/T015) but is gated behind `DOCKER_E2E=1` so it does not
  affect host-suite greenness. Aligning it is in scope ONLY if it does not
  require a Docker build to validate; otherwise it is documented as deferred.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The full host suite (`bats tests/`) MUST report zero failures on
  a clean checkout with standard host test deps, with no real `bun` binary and
  no network access required by any test.
- **FR-002**: The 2 failing reindex tests MUST be repaired to observe the
  engine through the current managed-prefix invocation path, preserving their
  original assertions: update+embed ordering on a changed vault, `indexed`
  status on success, `error` status + prior-hash preservation on engine
  failure.
- **FR-003**: The 4 failing setup tests MUST be repaired the same way,
  preserving: add→update→embed on first boot + sentinel write; refresh without
  re-add when the index exists but the sentinel is missing; no sentinel on
  engine failure; sentinel-hit fast path that never reaches the lock.
- **FR-004**: The regenerate test MUST keep asserting the `agent.yml`
  version-pin backfill and MUST assert the rendered `.mcp.json` QMD entry
  against the current contract (per-mode wrapper `command`, empty `args`)
  instead of the retired `bunx` argument shape.
- **FR-005**: Production code behavior MUST NOT change. Any library edit is
  limited to test seams (e.g., an override hook) that are inert in production,
  documented, and mirrored to the Docker copy per the established
  `scripts/lib` ↔ `docker/scripts/lib` rule.
- **FR-006**: The repaired tests MUST NOT use bare `!`-negated pipelines as
  intermediate assertions (known bats quirk in this repo — they don't fail the
  test); negative assertions use `if grep …; then false; fi` or run last.
- **FR-007**: Each repaired test file MUST document the canonical post-016
  stubbing seam in its header comment, replacing the stale "`bunx` stubbed"
  wording.
- **FR-008**: The other tests in the touched files that currently pass MUST
  continue to pass without weakening (no skips added, no assertions removed).

### Key Entities

- **Engine invocation seam**: the single point where tests intercept QMD
  engine calls post-016 (the managed-prefix runner), replacing the retired
  PATH-level `bunx` stub.
- **Stub call log**: the ordered record of engine subcommands a test asserts
  against (`collection add`, `update`, `embed`) — survives the seam change.
- **Rendered MCP entry**: the QMD server block in `.mcp.json` whose current
  contract is per-mode wrapper command + empty args.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `bats tests/` on a clean checkout reports **0 failures** (was:
  7) on macOS and Linux hosts without `bun`.
- **SC-002**: All 7 repaired tests pass while still failing when their covered
  behavior is deliberately broken (spot-checked during implementation for at
  least one behavior per file).
- **SC-003**: Zero production-behavior diffs: the launcher renders, boots, and
  reindexes identically before/after (no template or library logic change
  observable outside tests; Docker mirror byte-identical where required).
- **SC-004**: No test in the three touched files is deleted or skipped to
  achieve greenness; test count in those files is ≥ the current count.

## Assumptions

- The 7 failures are pure test drift: the behaviors they cover are believed
  correct in production (016/017/018 hardware and container gates exercised
  them). If repairing a test exposes a REAL library bug, that bug becomes a
  separate finding surfaced to the user rather than silently patched here.
- The canonical seam choice (function override vs fake prefix binary +
  pre-seeded install hash) is a design decision for the plan phase; the spec
  only fixes the outcome (no real bun, intent preserved, documented).
- `tests/docker-e2e-qmd.bats` Tier-1's stale stub is gated behind
  `DOCKER_E2E=1` and invisible to the host suite; full validation of any fix
  there requires a Docker host, so it may be explicitly deferred with a note
  rather than half-fixed.
- CI (`.github/workflows`) runs the same bats suite on Linux without `bun`;
  greenness there follows from FR-001 with no workflow edits.
