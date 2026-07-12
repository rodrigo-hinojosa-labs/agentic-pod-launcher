# Tasks: qmd Embed Completion (multi-pass beyond the 30-minute session cap)

**Input**: Design documents from `/specs/018-qmd-embed-completion/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/
**Tests**: MANDATORY (Constitution Principle III — test-first, host-runnable bats). Every behavior task
is preceded by its failing test.

## Path Conventions

Single project. Primary file: `scripts/lib/qmd_index.sh` (host), mirrored to
`docker/scripts/lib/qmd_index.sh` by `setup.sh::mirror_catalog_to_docker` at `--regenerate`. Tests
under `tests/`. All paths repo-relative.

---

## Phase 1: Setup (shared test scaffolding)

- [X] T001 Create `tests/qmd-embed-completion.bats` skeleton: `load_lib qmd_index`, a `setup()` that
  builds a temp workspace + `QMD_INDEX_STATE_FILE`, and a reusable `stub_qmd()` helper that puts a fake
  `qmd` on `PATH` emitting canned `embed`/`status` output per invocation (driven by a per-test script
  of pass outcomes). No assertions yet — just the harness.
  - Implemented as `_qmd_run` function override (not a `bunx` PATH stub — 016 rewired qmd invocation to
    a managed `bun install` prefix, so a `bunx` stub no longer intercepts anything; confirmed the
    pre-existing `qmd-index.bats`/`qmd-setup.bats` stubs are stale for this exact reason).

---

## Phase 2: Foundational (blocking prerequisites for all stories)

**Purpose**: shared primitives (`qmd_write_state` pending arg, `_qmd_pending_count`,
`QMD_EMBED_MAX_PASSES`) that US1/US2/US3 all build on. Test-first.

- [X] T002 [P] Add failing tests to `tests/qmd-index.bats`: `qmd_write_state` with a 4th `pending` arg
  writes `.pending` (integer); the 3-arg form still works (back-compat); `indexed` ⇒ `pending==0`; the
  existing existence-assertion still passes.
  - Design refinement vs the original task wording: 3-arg calls do NOT default `pending` to `0` — they
    CARRY FORWARD the prior file's `pending` (including its absence). Defaulting to `0` would make an
    `error` write after a `partial` run look "fully embedded", defeating FR-003's resume guarantee.
- [X] T003 [P] Add failing tests to `tests/qmd-embed-completion.bats` for `_qmd_pending_count PKG`:
  parses `Pending: <N> need embedding` from stubbed `qmd status` → echoes `N`; echoes empty + non-zero
  return when status fails or the line is absent (unknown); never prints secrets.
- [X] T004 Implement the optional 4th `pending` arg in `qmd_write_state` in `scripts/lib/qmd_index.sh`
  (emit `pending` in the JSON via `jq`, default `0`; preserve atomic tmp+`mv` and fail-silent
  `return 0`). Make T002 pass.
- [X] T005 Implement `_qmd_pending_count` and the fixed constant
  `QMD_EMBED_MAX_PASSES="${QMD_EMBED_MAX_PASSES:-12}"` in `scripts/lib/qmd_index.sh` (run
  `_qmd_run "$pkg" status`, grep the pending line, echo integer or empty; env-overridable for tests
  only, no `agent.yml` field). Make T003 pass.

---

## Phase 3: User Story 1 — Large vault embeds completely without manual intervention (P1)

**Goal**: successive `qmd embed` passes drive a large corpus to full coverage in one maintenance
invocation.
**Independent Test**: with a stub that reports pending>0 after pass 1 then 0 after a later pass (or
emits "All content hashes already have embeddings"), the loop runs multiple passes and records
`last_status=indexed`, `pending=0` — not a single-pass stop.

- [X] T006 [US1] Add failing tests to `tests/qmd-embed-completion.bats`: multi-pass completion —
  stub pass 1 "Embedded N … Session expired" + `status` pending 700; pass 2 "Embedded 700…" +
  `status` pending 0; assert `_qmd_embed_until_complete` runs ≥2 passes, stops on complete, writes
  `last_status=indexed`, `pending=0`, `hash=<current>`. Also assert the "already all embedded" fast
  path (pass emits "All content hashes already have embeddings") stops immediately as `indexed`.
  - Debugging note kept for future maintainers: the stub's pass counter MUST live in a file, not a bash
    variable — `_qmd_embed_until_complete` captures `_qmd_run` via `out=$(_qmd_run ...)`, which forks a
    subshell, so a plain variable increment inside the stub is lost each iteration (first attempt
    silently always replayed pass 1's canned output → false "stalled").
- [X] T007 [US1] Implement `_qmd_embed_until_complete PKG STATE_FILE HASH` in
  `scripts/lib/qmd_index.sh` (complete + progress paths per contracts/embed-completion.md: loop
  `_qmd_run embed`, detect complete via "All content…" or `pending==0`, continue on decreasing
  pending; per-pass redacted `_qmd_log` progress; always `return 0`). Make the completion-path
  assertions in T006 pass.
  - Signature ended up `_qmd_embed_until_complete PKG STATE_FILE HASH LAST_HASH` (added `LAST_HASH`) so
    a hard embed failure can preserve the prior known-good hash, matching the pre-existing `update`
    failure convention exactly.
- [X] T008 [US1] Wire `_qmd_embed_until_complete` into the changed-vault path of `_qmd_reindex_locked`
  in `scripts/lib/qmd_index.sh`, replacing the single `_qmd_run "$pkg" embed` at the current
  embed step (keep `update` before it; keep the `error` path on `update`/embed hard-failure with the
  prior hash preserved).

**Checkpoint**: a changed vault now embeds to completion across passes (MVP).

---

## Phase 4: User Story 2 — Incomplete embeddings resume even when the vault has not changed (P2)

**Goal**: an unchanged vault with pending>0 resumes; an unchanged, fully-embedded vault skips cheaply.
**Independent Test**: set state hash == current vault hash; with `pending>0` (or absent) the embed loop
runs; with `pending==0` it writes `skipped` and invokes no embed pass.

- [X] T009 [US2] Add failing tests to `tests/qmd-embed-completion.bats`: (a) unchanged vault + state
  `pending>0` → `_qmd_reindex_locked` runs the embed loop (assert a pass was invoked) and does NOT run
  `update`; (b) unchanged vault + state `pending==0` → writes `last_status=skipped`, invokes no embed
  pass; (c) unchanged vault + state missing `pending` (pre-018 file) → runs a resume pass (unknown ⇒
  resume, never silent skip).
  - Fixing this ALSO required updating the pre-existing (016-era) test
    "qmd_reindex skips embed when the vault is unchanged" in `tests/qmd-index.bats`: it encoded the OLD
    contract (unchanged ⇒ always skip). Renamed to "...unchanged AND fully embedded" and given an
    explicit `pending=0` — a deliberate, spec-driven test update, not a workaround. Two OTHER failures
    in that same file (`grep -q "update"/"embed"` against a stubbed `bunx`, and the "bunx failure"
    error-path test) are PRE-EXISTING and unrelated to 018: 016 rewired qmd invocation from `bunx` to a
    managed `bun install` prefix, so those tests' `bunx` stub no longer intercepts anything on ANY host
    (confirmed reproducible before touching `qmd_index.sh` at all, and CI has no `bun` installed either
    — same root cause either way). Left as-is; out of scope for 018.
- [X] T010 [US2] Amend the unchanged-vault guard in `_qmd_reindex_locked`
  (`scripts/lib/qmd_index.sh`): read persisted `pending` (`jq -r '.pending // ""'`); if `pending==0`
  keep today's cheap `skipped` write; if `pending>0` or unknown, call
  `_qmd_embed_until_complete` (no `update`). Make T009 pass.

**Checkpoint**: static, partially-embedded vaults now finish; fully-embedded ones stay cheap.

---

## Phase 5: User Story 3 — Bounded, observable completion (P3)

**Goal**: the loop never runs forever and its outcome (complete/partial/stalled + residual pending) is
recorded.
**Independent Test**: a stub whose pending never decreases stops as `stalled`; a stub that always makes
tiny progress with `QMD_EMBED_MAX_PASSES=2` stops after 2 passes as `partial`; state always carries a
`pending` count.

- [X] T011 [US3] Add failing tests to `tests/qmd-embed-completion.bats`: (a) stall — `status` pending
  stuck at same value across passes → loop stops, `last_status=stalled`, `pending>0`, and no more than
  N+1 passes ran; (b) pass cap — `QMD_EMBED_MAX_PASSES=2` with always-progressing stub that never
  reaches 0 → exactly 2 passes, `last_status=partial`, `pending>0`; (c) every terminal state writes a
  numeric `pending`. Also added: a hard embed failure (rc≠0) records `error` and preserves the prior
  hash (mirrors the pre-existing `update`-failure convention).
- [X] T012 [US3] Implement stall detection (pending did not decrease vs previous) + pass-cap
  termination + `partial`/`stalled` state writes in `_qmd_embed_until_complete`
  (`scripts/lib/qmd_index.sh`). Make T011 pass.

**Checkpoint**: bounded and observable; permanently-failing docs cannot hang the loop.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T013 Run `shellcheck -S error scripts/lib/qmd_index.sh` and fix any finding. Clean, no findings.
- [X] T014 Mirror to Docker: run `./setup.sh --regenerate` from a scaffolded workspace (or the repo's
  mirror path) so `docker/scripts/lib/qmd_index.sh` matches, then verify
  `diff -q scripts/lib/qmd_index.sh docker/scripts/lib/qmd_index.sh` is identical.
  - Verified via a throwaway scaffold (this repo has no `docker/scripts/lib/` of its own — it's
    populated only inside a scaffolded workspace): `diff -q` reported IDENTICAL.
- [X] T015 Extend `tests/docker-e2e-qmd.bats` (gated by `DOCKER_E2E=1`): after reindex on the e2e
  corpus, assert `qmd status` → `Pending: 0` and `qmd-index.json` → `last_status=indexed`, `pending=0`.
  Use `if grep …; then false; fi` (never a bare `!`-negated pipeline — see the bats quirk).
  - Added the `pending=0` assertion to the existing Tier-2 (`QMD_EMBED_E2E=1`) real-qmd test, right
    after its `last_status` check. Did NOT run the slow Tier-2 (native compile + model download) in
    this session — same precedent as 015/016/017, which deferred that exact cost to the dedicated
    hardware/e2e pass. Instead ran a FAST, targeted, real-runtime check: built the image and, inside
    the actual Alpine/musl/busybox container, sourced the mirrored `qmd_index.sh` with a stubbed
    `_qmd_run` (same technique as the host bats) and exercised `_qmd_pending_count`,
    `_qmd_embed_until_complete` (2-pass completion), and `_qmd_reindex_locked`'s resume guard directly —
    proving jq/mktemp/date-u syntax and the new logic are correct under the REAL target runtime, not
    just macOS bash. All three behaved exactly as designed. Also discovered (analogous to the
    qmd-index.bats finding): Tier 1's `bunx` stub in this same file is ALSO stale for the SAME
    016-migration reason — pre-existing, out of scope for 018.
- [X] T016 Run the full host suite `bats tests/` and confirm green (no regressions). See Completion
  Report in the chat for the exact before/after counts.
  - Final clean run (post-edit, non-contaminated): 1014 lines, 7 `not ok`. All 7 confirmed
    pre-existing and out of scope for 018 (none touch a file this feature modified): 2 in
    `qmd-index.bats` (stale `bunx` stub vs. post-016 managed-`bun install` prefix — already
    documented), 4 in `qmd-setup.bats` (same 016-migration root cause, same stale `_install_bunx`
    stub pattern), 1 in `regenerate.bats` (`--regenerate backfills vault.qmd.version...` asserts the
    OLD bunx-style `.mcp.json` `args[0]/args[1]` shape; 016/T036 changed `mcp-json.tpl` to
    `args: []` + `{{QMD_MCP_COMMAND}}`, and this assertion was never updated). All new 018 tests
    (qmd-embed-completion.bats: 13/13, qmd-index.bats new pending-arg tests: 5/5,
    docker-e2e-qmd.bats pending=0 assertion) pass. Zero regressions attributable to 018.
- [X] T017 Bump `VERSION` 0.11.0 → 0.12.0 and add a `CHANGELOG.md` entry describing the multi-pass
  embed completion (user-facing: large vaults now finish embedding).
- [ ] T018 On merge: update `CLAUDE.md` — move 018 into the prior-features list and flip its SPECKIT
  block to MERGED with the PR/merge SHA (do NOT commit `.claude/settings.json`).

---

## Dependencies & Execution Order

- **Setup (T001)** → **Foundational (T002–T005)** → **US1 (T006–T008)** → **US2 (T009–T010)** →
  **US3 (T011–T012)** → **Polish (T013–T018)**.
- US2 and US3 depend on US1's `_qmd_embed_until_complete` (they resume-into / extend it), so despite
  being separate stories they are NOT independently mergeable before US1. Priority order is the build
  order.
- Foundational blocks all three stories (shared state arg + pending signal + cap).
- Polish runs after all stories; T014 (mirror) + T015 (DOCKER_E2E) + T016 (full suite) are the release
  gates; T018 is merge-time.

## Parallel Opportunities

- **T002 ∥ T003**: different test files (`tests/qmd-index.bats` vs `tests/qmd-embed-completion.bats`),
  no shared code → `[P]`.
- All implementation tasks (T004, T005, T007, T008, T010, T012) edit the SAME file
  `scripts/lib/qmd_index.sh` → strictly sequential (no `[P]`).
- Within a story, the test task must complete (and fail) before its implementation task (test-first).

## Implementation Strategy (MVP first)

- **MVP = US1 (T001–T008)**: a large vault embeds to completion across passes. This alone fixes the
  observed ferrari failure and delivers the core value.
- **US2 (T009–T010)** makes it hold for static vaults (resume-on-unchanged) — the common real case.
- **US3 (T011–T012)** hardens against runaway/stall and adds the partial/stalled observability.
- Ship incrementally; each phase leaves the suite green. The ferrari hardware gate (SC-006) is the
  final confirmation — its behavior is already being previewed by the manual embed loop run during the
  017 gate.
