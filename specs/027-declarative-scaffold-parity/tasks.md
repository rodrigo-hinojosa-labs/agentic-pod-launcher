# Tasks: Declarative Local-Scaffold Parity

**Feature**: `027-declarative-scaffold-parity` | **Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

**Test-first is mandatory** (Constitution III): every behavior change ships `bats` coverage, written RED before the implementation that turns it GREEN, plus a mutation check that the test genuinely pins the fix.

**Scope refinement (2026-08-06)**: US1 and US4 live in the shared `regenerate()` path (docker + local). To keep docker rendering **byte-identical** (FR-012) and the feature cleanly local-only, both are **gated to `deployment.mode == local`**. The docker equivalents (US1 identity, US4 NEXT_STEPS, US3 Dockerfile pins) are one deferred docker follow-up.

**Touched files**: `setup.sh` (US1, US4), `modules/local-bootstrap.sh.tpl` (US2, US3), `scripts/lib/versions.sh` (US3), `tests/*.bats` (+ fixtures). No `docker/` file changes → no `DOCKER_E2E`.

---

## Phase 1: Setup

- [X] T001 Record the host-suite baseline: run `bats tests/` under bash 5.x AND under bash 3.2 (`PATH=/bin:$PATH bats tests/`) and note the `ok`/`not ok` counts, to prove SC-005/SC-006 non-regression after the change.

## Phase 2: Foundational (blocking prerequisite for US3)

- [X] T002 [P] On a clean env with `uv`, validate and FREEZE the US3 pin combo: install `mcp-server-fetch==2026.6.4`, `mcp-server-git==2026.6.16`, and `mcp-atlassian==0.21.1` each with `--with mcp==1.28.1`; confirm each starts without `ImportError` and (given creds) `claude mcp list` reports Connected. If `mcp-atlassian` cannot share `mcp==1.28.1`, record a per-server `mcp` override. Freeze the final four values for `scripts/lib/versions.sh` (record them in this file's Notes).

---

## Phase 3: User Story 1 — agent has its OWN identity (Priority: P1)

**Goal**: a non-interactive/declarative local render produces the agent's `CLAUDE.md`, not the launcher's dev doc; a genuine operator doc is preserved.

**Independent test**: render a local workspace whose `CLAUDE.md` is the launcher's dev doc → result is the agent's doc, no prompt; an operator doc (no sentinel) is preserved; a docker workspace is untouched.

- [X] T003 [US1] Write FAILING bats in `tests/regenerate.bats`: (a) local-mode workspace whose `CLAUDE.md` contains the launcher sentinel `This is **the launcher**, not an agent` → `./setup.sh --non-interactive` → `CLAUDE.md` now contains `## Identity` and the agent name, and NOT the sentinel, with no prompt; (b) a `CLAUDE.md` WITHOUT the sentinel (operator doc) → `--regenerate` preserves it byte-for-byte; (c) a docker-mode workspace whose `CLAUDE.md` is the launcher doc → `--regenerate` PRESERVES it (local gate). [RED]
- [X] T004 [US1] In `setup.sh`, add helper `_is_launcher_own_claude_md FILE` (returns success iff FILE greps the sentinel `This is \*\*the launcher\*\*, not an agent`) and extend the `regenerate()` CLAUDE.md render condition (~`setup.sh:2228`) to also render when the current `CLAUDE.md` is the launcher's own doc AND `deployment.mode == local` (guard on `DEPLOYMENT_MODE_IS_DOCKER` false). [GREEN → T003]
- [X] T005 [US1] Mutation check: revert the discriminator clause; confirm T003(a) goes red; restore.

**Checkpoint**: US1 independently deliverable — a fresh local declarative scaffold gets the right `CLAUDE.md`.

---

## Phase 4: User Story 2 — QMD works after a fresh scaffold (Priority: P1)

**Goal**: the provisioner installs `bun` when the QMD MCP is present as its wrapper (not only for literal `bunx`).

**Independent test**: `BOOTSTRAP_DRY_RUN=1` plans a `bun` install for a QMD workspace, and does not for a QMD-off workspace.

- [X] T006 [US2] Write FAILING bats in `tests/local-bootstrap.bats` (create if absent; otherwise extend the existing bootstrap test): with `BOOTSTRAP_DRY_RUN=1`, a `.mcp.json` whose `qmd` command is `…/agent-qmd-mcp.sh` → output contains `PLAN bun`; a `.mcp.json` with no qmd and no bunx → NO `PLAN bun`; a `.mcp.json` with a literal `bunx` command → `PLAN bun` (regression guard). [RED]
- [X] T007 [US2] In `modules/local-bootstrap.sh.tpl` `main()`, extend the bun trigger (`local-bootstrap.sh.tpl:219`) to fire when `$cmds` contains `bunx` OR a command referencing `agent-qmd-mcp.sh`. Preserve fail-silent/exit-0. [GREEN → T006]
- [X] T008 [US2] Mutation check: revert the wrapper clause; confirm the qmd-workspace `PLAN bun` test goes red; restore.

**Checkpoint**: US2 independently deliverable — QMD's `bun` is provisioned on a fresh local scaffold.

---

## Phase 5: User Story 3 — fetch/git/atlassian MCPs pinned (Priority: P2)

**Goal**: the provisioner pins the uvx MCP servers + the `mcp` lib to a validated, single-sourced set.

**Independent test**: `BOOTSTRAP_DRY_RUN=1` plan lines surface the pinned versions (matching `versions.sh`), never unpinned.

- [X] T009 [US3] Write FAILING bats in `tests/local-bootstrap.bats`: with `BOOTSTRAP_DRY_RUN=1`, the plan lines for `mcp-server-fetch`/`mcp-server-git`/`mcp-atlassian` carry `==<version>` matching `versions.sh` AND `(mcp==<AGENTIC_FLOOR_MCP_LIB>)`; assert no warmed uvx tool is unpinned. [RED]
- [X] T010 [US3] Add `AGENTIC_FLOOR_MCP_FETCH`, `AGENTIC_FLOOR_MCP_GIT`, `AGENTIC_FLOOR_MCP_ATLASSIAN`, `AGENTIC_FLOOR_MCP_LIB` to `scripts/lib/versions.sh` (frozen values from T002), beside the existing `AGENTIC_FLOOR_MCP_FILESYSTEM/_VAULT/_GH_MCP`.
- [X] T011 [US3] Inject the four pins into the rendered bootstrap: add them to `setup.sh`'s render context for `local-bootstrap.sh.tpl` (new `{{MCP_*_VERSION}}` vars), reference them in the template, and change `provision_uv_tools` to install `pkg==<pin>` with `--with mcp==<AGENTIC_FLOOR_MCP_LIB>` (per-server override if T002 recorded one); update both the real install and the `PLAN uv-tool …` dry-run line to carry the pins. [GREEN → T009]
- [X] T012 [US3] Mutation check: revert the pins/injection; confirm the pin-surfacing test goes red; restore.

**Checkpoint**: US3 independently deliverable — a fresh local scaffold's fetch/git/atlassian connect deterministically.

---

## Phase 6: User Story 4 — declarative NEXT_STEPS guidance (Priority: P3)

**Goal**: `--non-interactive`/`--regenerate` render `NEXT_STEPS.md` (local mode) from the existing template.

**Independent test**: after `--non-interactive`, `NEXT_STEPS.md` exists and names the local next-actions; `--regenerate` re-produces it idempotently; docker `--regenerate` does not add it (byte-identical); the wizard still prints it.

- [X] T013 [US4] Write FAILING bats in `tests/regenerate.bats`: local-mode workspace → `--non-interactive` → `NEXT_STEPS.md` exists and contains the `./setup.sh --login` command + the unit-install path; a second `--regenerate` → identical bytes (idempotent); a docker-mode workspace → `--regenerate` does NOT create `NEXT_STEPS.md` (local gate, FR-012). [RED]
- [X] T014 [US4] Refactor `render_next_steps()` (`setup.sh:1410`) to expose a quiet file-write path (template selection by `user.language` + `{{PLUGINS_BLOCK}}` injection, no stdout `cat`); call it from `regenerate()` gated to `deployment.mode == local`. Keep the wizard's existing print behavior unchanged. [GREEN → T013]
- [X] T015 [US4] Mutation check: revert the `regenerate()` NEXT_STEPS call; confirm the NEXT_STEPS-present test goes red; restore.

**Checkpoint**: US4 independently deliverable — the declarative operator gets post-scaffold guidance.

---

## Phase 7: Polish & Cross-Cutting

- [X] T016 [P] Docker non-regression bats (FR-012, SC-005): a docker-mode `agent.yml` `--regenerate` renders `CLAUDE.md`/`.mcp.json` unchanged and produces NO `NEXT_STEPS.md`, and the docker render path is byte-identical to pre-feature (US1/US4 local-gated; US2/US3 touch only the local bootstrap template).
- [X] T017 [P] `shellcheck -S error` clean on `setup.sh`, `modules/local-bootstrap.sh.tpl`, `scripts/lib/versions.sh`, and any new/edited `tests/*.bats` helpers per the repo gate.
- [X] T018 Full host suite green on bash 5.x AND bash 3.2 (`PATH=/bin:$PATH bats tests/`), `ok` count = baseline (T001) + the new tests, `0 not ok`, byte-identical across both bash versions (SC-006).
- [X] T019 Bump `VERSION` `0.17.0 → 0.18.0`; add a `CHANGELOG.md` entry (US1-US4, local-only, docker follow-up noted) (Principle VI).
- [X] T020 [P] Update `docs/creating-an-agent.md` (and remove the now-obsolete "manual gotchas" it documents): the declarative scaffold now renders the agent's `CLAUDE.md`, provisions `bun`, pins uvx, and emits `NEXT_STEPS.md` automatically — keep only guidance that stays true.
- [ ] T021 Live-host acceptance (SC-001/SC-002; deferred to a local systemd host): on a throwaway local scaffold (or a ferrari `--regenerate` + `--login`), confirm NO manual runtime steps are needed — agent `CLAUDE.md` correct, QMD `last_status=indexed`, `claude mcp list` 7/7 Connected, `NEXT_STEPS.md` present.

---

## Dependencies

- **T001** first (baseline).
- **T002** (foundational) blocks US3 (T009-T012 need the frozen pin values).
- **US1 (T003-T005)**, **US2 (T006-T008)**, **US3 (T009-T012)**, **US4 (T013-T015)** are otherwise independent user stories.
- **Same-file serialization**: T004 and T014 both edit `setup.sh` → sequential (T004 before T014). T003 and T013 both edit `tests/regenerate.bats` → sequential. T007 and T011 both edit `modules/local-bootstrap.sh.tpl` → sequential (T007 before T011). T006 and T009 both edit `tests/local-bootstrap.bats` → sequential. T011 also depends on T010 (versions.sh).
- **Phase 7** after all US phases: T016-T018 gates, T019-T020 docs, T021 last (needs a host).

## Parallel opportunities

- **T002** runs in parallel with the US1/US2 RED tests (T003, T006) — different concern, needs a host.
- Across the two test files, **T003 (regenerate.bats)** and **T006 (local-bootstrap.bats)** can be written in parallel [P].
- Across the two impl files, **T004 (setup.sh)** and **T007 (local-bootstrap.sh.tpl)** can proceed in parallel [P].
- **T016, T017, T020** in Phase 7 are independent [P].

## Implementation strategy (MVP first)

- **MVP = US1 + US2** (both P1): a fresh local declarative scaffold gets the right identity AND working QMD — the two highest-blast-radius fixes. Ship/validate these first (T001→T008).
- Then **US3** (P2, fetch/git/atlassian determinism) and **US4** (P3, guidance).
- Then **Phase 7** gates + docs + the live-host acceptance.
- Each user story is independently testable and revertible; the mutation checks (T005/T008/T012/T015) collectively satisfy SC-007.

## Notes

- Frozen US3 pin values (T002): `MCP_FETCH=2026.6.4`, `MCP_GIT=2026.6.16`, `MCP_ATLASSIAN=0.21.1`, `MCP_LIB=1.28.1` (single `mcp` lib for all three; no per-server override). Source: the working mclaren host + the ferrari manual fix (`--with mcp==1.28.1`), research.md §US3. Live install-validation (`uv tool install …` + `claude mcp list` Connected) runs on a host with `uv` — folded into **T021** (this dev Mac has no `uv`); fetch/git/lib are hardware-confirmed, the atlassian↔`mcp==1.28.1` shared-lib is the one residual the live gate closes.
- The bootstrap must keep its idempotent, fail-silent, exit-0 contract throughout (FR-016) — no new hard failure.
- No `docker/` file is edited; the docker follow-up (US1/US3/US4 docker equivalents) is tracked separately per the 2026-08-06 scope decision.
