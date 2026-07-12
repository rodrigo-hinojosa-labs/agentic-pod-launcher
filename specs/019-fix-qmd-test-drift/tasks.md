# Tasks: Fix QMD Test Drift (post-016 contract)

**Input**: Design documents from `/specs/019-fix-qmd-test-drift/`
**Prerequisites**: plan.md, research.md (R1–R6), data-model.md,
contracts/qmd-test-seam.md, quickstart.md

**Tests**: This feature IS test repair — every task is test work; no separate
test-first phase applies. The TDD equivalent here: T001 records the RED
baseline before any edit, and US2 proves the repaired tests still detect
broken behavior.

**Organization**: Tasks grouped by user story (US1 suite-green P1, US2
intent-preserved P2, US3 documented-seam P3) per spec.md.

## Phase 1: Setup

- [X] T001 Record the RED baseline: run `bats tests/qmd-index.bats
  tests/qmd-setup.bats tests/regenerate.bats` standalone and capture the 7
  exact failing test names to the feature notes (must match the spec's
  Context table; confirms no drift since 2026-07-11).

## Phase 2: Foundational (blocking all user stories)

- [X] T002 Add the canonical seam helpers to `tests/helper.bash`:
  `install_qmd_stub [VER]` (success variant per
  contracts/qmd-test-seam.md — fake `qmd` at
  `$QMD_CACHE_HOME/pkg/node_modules/.bin/qmd`, `.installed-hash` seeded via
  the lib's own `_qmd_manifest`/`_qmd_sha`, `collection` → creates
  `index.sqlite`, `embed` → prints the 018 completion line, `status` →
  `Pending: 0 need embedding`, appends `"$@"` to `$QMD_STUB_LOG`, exit 0) and
  `install_qmd_stub_fail [VER]` (same layout, exit 1, no completion output),
  both installing a no-op `bun` into `$TMP_TEST_DIR/bin` on PATH. Helpers
  must be pure functions (no side effects at source time — Principle III).

## Phase 3: US1 — Maintainer trusts a green suite (P1) MVP

- [X] T003 [P] [US1] Repair `tests/qmd-index.bats`: replace
  `_install_bunx`/`_install_bunx_fail` with the shared seam helpers; the
  "vault changed → update+embed → indexed" test asserts `update` and `embed`
  in `$QMD_STUB_LOG` + `last_status=indexed` (+ `pending=0`, 018 schema); the
  "engine failure" test (rename from "bunx failure") asserts
  `last_status=error` + `hash=STALEHASH` preserved; update the file header
  comment to name the seam and point at
  `specs/019-fix-qmd-test-drift/contracts/qmd-test-seam.md`; verify the 4
  currently-passing tests in the file still pass unchanged (FR-008). No bare
  `!`-negated intermediate pipelines (FR-006).
- [X] T004 [P] [US1] Repair `tests/qmd-setup.bats`: same helper swap for the
  4 failing tests (first-boot add→update→embed + sentinel; refresh
  without re-add; fail-silent no-sentinel; sentinel fast path never reaches
  the lock); port the local slow variant to the seam
  (`_install_qmd_stub_slow`, `case "$1" in collection) sleep 1 …` — arg
  position shifts from `$2` to `$1` per data-model.md); keep the flock
  concurrency test and its macOS skip intact; update the header comment
  (FR-007). Negative assertion `! grep -q "collection add"` in the refresh
  test must become `if grep -q …; then false; fi` (FR-006).
- [X] T005 [P] [US1] Repair `tests/regenerate.bats` qmd-pin test: keep
  `yq '.vault.qmd.version' == "2.5.3"` (backfill — the core intent); replace
  the two retired assertions with the post-T036 contract:
  `jq -r '.mcpServers.qmd.command'` == `/opt/agent-admin/scripts/qmd-mcp`
  (docker-mode seed) and `jq '.mcpServers.qmd.args | length'` == `0`; update
  the test's rationale comment to name T036 and the wrapper contract.
- [X] T006 [US1] Run the three repaired files standalone
  (`bats tests/qmd-index.bats tests/qmd-setup.bats tests/regenerate.bats`) —
  expect 0 failures across all of them (acceptance scenario 2 of US1).

## Phase 4: US2 — Original coverage intent survives (P2)

- [X] T007 [US2] Mutation spot-check (NOT committed): temporarily break one
  covered behavior per file in `scripts/lib/qmd_index.sh` / the render path
  and confirm the repaired test FAILS, then `git checkout --` the change.
  Minimum set: (a) invert the sentinel write in `_qmd_setup_locked`
  (`: > "$sentinel"` → `true`), expect the first-boot sentinel test red;
  (b) drop the `update` call in `_qmd_reindex_locked`'s changed-vault branch,
  expect the reindex-success test red; (c) break the `.mcp.json` qmd command
  rendering (temporary template edit), expect the regenerate test red.
  Record the three observed failures in this file's completion notes
  (SC-002 evidence).

## Phase 5: US3 — Canonical seam documented and reusable (P3)

- [X] T008 [US3] Cross-check documentation: the three repaired files' header
  comments reference the contract doc; `contracts/qmd-test-seam.md` matches
  what T002 actually implemented (update the contract if implementation
  diverged); the seam-B note still points at `tests/qmd-embed-completion.bats`
  as the unit-level example.

## Phase 6: Polish & release gates

- [X] T009 [P] Align the stale Tier-1 `bunx` stub in
  `tests/docker-e2e-qmd.bats` to the same seam (container paths), validation
  DEFERRED to the next `DOCKER_E2E=1` run on a Docker host — add an explicit
  comment noting the deferral (research.md R6). Host-side check only: file
  parses (`bats --count tests/docker-e2e-qmd.bats`) and still self-skips
  without the gate.
- [X] T010 Add a `CHANGELOG.md` entry under Unreleased (test-only fix, NO
  VERSION bump per plan): suite restored to 0 failures; canonical post-016
  test seam documented.
- [X] T011 Release gate: full `bats tests/` run — expect **0 `not ok`**
  (SC-001). Record the total test count and confirm the three files' test
  count is ≥ pre-repair (SC-004).
  - RESULT (2026-07-12): `1..977` — 977 ok, **0 not ok** (was 7), 20 skips
    (expected macOS flock/timeout skips + DOCKER_E2E/QMD_EMBED_E2E gates),
    exit 0. Per-file counts unchanged vs pre-repair: qmd-index 11, qmd-setup
    8, regenerate 9 — no test deleted or skipped to achieve greenness
    (SC-004). Mutation evidence (T007/SC-002): (a) sentinel write disabled →
    first-boot test red at `[ -f "$QMD_CACHE_HOME/.qmd-setup-ok" ]`; (b)
    `update` call dropped → reindex test red at `grep -q "update"`; (c)
    `.mcp.json` qmd command mutated → regenerate test red at the command
    assertion. All three restored via `git checkout --`.
- [X] T012 On merge: update `CLAUDE.md` SPECKIT block — 019 to MERGED with
  PR/SHA, fold into the prior-features list (do NOT commit
  `.claude/settings.json`).
  - DONE 2026-07-12: PR #74, merge `2bf984b`; CLAUDE.md SPECKIT flipped to MERGED with the
    977/0 gate result.

## Dependencies & Execution Order

- T001 → T002 → {T003, T004, T005 in parallel} → T006 → T007 → T008 →
  {T009, T010 in parallel} → T011 → T012 (merge-time).
- US2 and US3 depend on US1's repaired files existing; they are verification/
  documentation passes, not independently mergeable increments — priority
  order is execution order.

## Parallel Opportunities

- T003, T004, T005 touch three different files — parallelizable after T002.
- T009 and T010 are independent of each other.

## Implementation Strategy

MVP = US1 alone (suite green restores the release gate's value). US2 is the
guard against gutted coverage; US3 locks the pattern for the future. All
three land in one PR — the feature is small; splitting would leave the suite
green but undocumented mid-stream.
