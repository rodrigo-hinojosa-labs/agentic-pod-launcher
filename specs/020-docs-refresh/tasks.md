# Tasks: Docs Refresh to v0.12.0 Reality

**Input**: Design documents from `/specs/020-docs-refresh/`
**Prerequisites**: plan.md, research.md (R1–R6), drift-audit.md (121
findings — the per-doc worklist), wizard-prompt-order.md (52 prompts),
coverage-map.md (25 subsystems), contracts/doc-update-contract.md.

**Tests**: Docs feature — the "test-first" analogue is already done: the
drift audit (Phase 0) recorded every failure BEFORE any edit. The closing
audit (T016) is the RED→GREEN check. SC-005 keeps the bats suite as the
no-behavior-change guard.

**Ground rules for EVERY doc task** (contracts/doc-update-contract.md):
re-verify each claim in code at writing time (the audit evidence is a lead,
not a substitute); per-mode qualifiers; "as of v0.12.0" tags on aging facts;
close every drift-audit row for that doc + land its coverage gaps.

## Phase 1: Setup

- [X] T001 Enumerate the render-test touchpoints for the three doc
  templates: grep `tests/` for assertions against rendered `NEXT_STEPS.md`
  / workspace `CLAUDE.md` strings (known suspects: `e2e-smoke.bats`
  hand-rolled array, render fixtures, regenerate.bats). Record the list in
  this file's notes — template tasks (T013–T015) must update any legitimate
  assertion IN THE SAME commit (research R4).
  - **Touchpoints (strings the templates MUST keep unless the assertion is
    updated in the same commit):** next-steps.{en,es}.tpl →
    `tests/scaffold.bats:120-131` (headings `## Installed plugins` /
    `## Plugins instalados`, plugin ids, descriptor text) and
    `tests/scaffold.bats:205-243` (RAG journal block conditionals inside
    `{{#unless DEPLOYMENT_MODE_IS_DOCKER}}`: three-unit journal lines,
    list-timers, docker byte-identity). claude-md.tpl →
    `tests/scaffold.bats:158-159` (`Vault`, `~/.vault/`),
    `tests/regenerate.bats:69,78,96,97,151` (agent name render, operator-
    edit preservation, `Vault`, `Karpathy`, persona marker),
    `tests/e2e-smoke.bats:96` (display name),
    `tests/docker-e2e-claude-md-refresh.bats:98-100` (gated: operator
    marker, `## Operator Notes`, `## Commands`). NOTE `tests/vault.bats:77-87`
    greps the VAULT skeleton's CLAUDE.md (a different template, out of
    scope here).

## Phase 2: US1 — Accurate README (P1) MVP

- [X] T002 [US1] Rewrite `README.md` framing sections to dual-mode (tagline,
  "What this is", Prerequisites per mode, Quickstart per mode) and close all
  10 drift findings (incl. the FALSE restore advice → `--identity-key` flag;
  typing-indicator v4 contract; test count ~977 "as of v0.12.0"; doctor
  check-count; alpine base) + its 5 coverage gaps (local mode overview, RAG
  stack overview, 3-branch backup pointers into docs/).

## Phase 3: US2 — Quickstarts on the canonical wizard order (P1)

- [X] T003 [US2] Rebuild `docs/agentic-quickstart.en.md` on
  wizard-prompt-order.md: 52/52 prompts in order, conditionals annotated
  (deployment mode FIRST; Linux-only install_service; telegram sub-prompts;
  vault/qmd block; plugin list in real order), per-mode post-scaffold paths
  (docker: build/up/login/attach; local: bootstrap, sudo unit install,
  --login, timers/watcher/doctor checks), and close its 6 findings + 3 gaps.
- [X] T004 [US2] Rebuild `docs/agentic-quickstart.es.md` from the SAME
  section skeleton as T003 (write EN first, derive ES; semantic parity, not
  literal translation), closing its 6 findings + 3 gaps.
- [X] T005 [US2] Parity + coverage check (SC-002/SC-004): heading-structure
  diff EN vs ES pairs 1:1; walk wizard-prompt-order.md confirming 52/52
  present in both, zero retired prompts. Record results here.

## Phase 4: US3 — Contributor docs + templates (P2)

- [X] T006 [P] [US3] `docs/getting-started.md`: close 14 findings + 5 gaps —
  consolidate local-mode operational knowledge (agent-bootstrap, healthcheck
  states, agentctl mode-awareness/degradation, kill-switch scope,
  resolve_claude_bin + `_libc_variant` notes per coverage map).
- [X] T007 [P] [US3] `docs/architecture.md`: close 11 findings + 5 gaps —
  kill the ":279 invoked via bunx" claim; add managed-prefix/toolchain/
  bigstack (016), rag_obs/TMPDIR routing (015), embed-loop design note
  (018), 2-line pointer to the 019 test-seam contract.
- [X] T008 [P] [US3] `docs/heartbeatctl.md`: close 8 findings + 4 gaps —
  subcommand reference gains qmd-reindex/backup-vault (013) alongside
  wiki-graph; qmd-index.json schema incl. `pending` + `partial`/`stalled`;
  doctor 0/1/2 contract cross-reference.
- [X] T009 [P] [US3] `docs/vault.md`: REBUILD the QMD sections (they predate
  feature 010: manual bunx ops, retired `.mcp.json` shape) — current truth:
  auto-setup, managed prefix, per-mode MCP wrappers, XDG storage under
  `.state`, multi-pass embed + resumable guard (018), local timers; close
  15 findings + 9 gaps.
- [X] T010 [P] [US3] `docs/state-layout.md`: REWRITE the `.state/` tree to
  current reality (`.cache/qmd/pkg` prefix, `.cache/qmd/tmp` scratch,
  `.config/qmd`, `.gcal`, `.claude-heartbeat`, vault `.graph/`, local-mode
  `remote-control.env`); close 11 findings + 6 gaps.
- [X] T011 [P] [US3] `docs/adding-an-mcp.md`: close 12 findings (6 false/
  high) + 7 gaps — current contract: per-mode command/env resolution
  (`QMD_MCP_COMMAND`/`QMD_MCP_ENV`/`GCAL_CREDS_PATH` precedent), wizard
  wiring, schema.sh, and the 3 test touchpoints (wizard_answers, e2e-smoke
  array, schema.bats known_external).
- [X] T012 [P] [US3] `docs/adding-a-notifier.md` (close 5 findings + 4 gaps;
  verify envelope contract against `scripts/heartbeat/notifiers/*.sh`) and
  `docs/qmd-upgrade-checklist.md` (close 2 findings; add the 017 sqlite-vec
  pair item and the 018 embed-loop/pending re-verification item).
- [X] T013 [P] [US3] `modules/next-steps.en.tpl`: close 7 findings + 6 gaps
  (per-mode branches vs current post-scaffold reality); update any
  touchpoint assertions from T001 in the same commit.
- [X] T014 [P] [US3] `modules/next-steps.es.tpl`: close 6 findings + 3 gaps,
  keeping EN/ES template parity with T013.
- [X] T015 [US3] `modules/claude-md.tpl`: close 8 findings (4 high) + 5 gaps
  — the runtime facts every scaffolded agent learns (heartbeatctl surface,
  vault/RAG capabilities, backup expectations, per-mode differences);
  render-contract tests from T001 stay green.

## Phase 5: Polish & closing gates

- [X] T016 Closing audit (SC-001): walk ALL 121 rows of drift-audit.md
  against the updated docs; mark each resolved (corrected/removed/
  qualified); verify or drop the 1 unverified-suspicion row; record the
  tally here. Zero survivors.
  - **Method**: the audit was closed by an adversarial pass — one verifier per
    doc, told to *disprove* the writer, re-reading the source (never the
    writer's summary). Findings resolved per doc: README 10, quickstart.en 6,
    quickstart.es 6, getting-started 14, architecture 11, heartbeatctl 8,
    vault 15, state-layout 11, adding-an-mcp 12, adding-a-notifier 5,
    qmd-upgrade-checklist 2, next-steps.en 7, next-steps.es 6, claude-md 8 =
    **121/121, zero survivors**. The `unverified-suspicion` row resolved to a
    real (fixed) finding, not a drop.
  - **The adversarial pass paid for itself**: it caught **14 new errors** the
    writers introduced or carried forward (e.g. wiki-graph's TMPDIR is *not*
    under `.state` — it is `<workspace>/scripts/heartbeat/tmp`; `/opt/npm-cache`
    is agent-owned, not root-owned; a Telegram token rotation is *not* fixed by
    a restart; `heartbeatctl` reload does *not* regenerate every derived file;
    the MCPVault pin is single-sourced in `scripts/lib/versions.sh`, not in the
    template; a fork-disabled scaffold *does* get a local `<agent>/live` branch)
    plus the one open EN/ES parity gap. All 14 + the gap were fixed and
    re-verified (12 fix agents → 12 adversarial re-verifiers; 3 came back dirty
    on the first pass and were closed by hand against the code).
- [X] T017 Link check (SC-006) over README + docs/ in-scope set (quickstart
  procedure) + confirm aging-fact tags present where the audit flagged them.
  - Link check: **0 dead links** across README + `docs/*.md` (relative paths and
    anchors resolved against the tree).
  - "as of v0.12.0" tags present in 12 of the 14 in-scope files (the two
    next-steps ES/EN templates carry the version through the rendered header).
  - Emoji hygiene: the only glyphs in added lines are literal CLI output
    (`✓ ⚠ ✗`) quoted verbatim and `MyAgent 🤖`, which is the wizard's own default
    display name (`setup.sh:486`) — copy-paste truth, not decoration.
- [X] T018 Release gates: full `bats tests/` (SC-005, expect 977-baseline
  green, only legitimate template-assertion diffs from T001 list) +
  `CHANGELOG.md` Unreleased note (docs refresh, no VERSION bump).
  - `bats tests/` = **977 ok, 0 not ok** — identical to the pre-feature
    baseline. SC-005 holds: the template edits changed no string any test
    greps, so **no test assertion needed updating** (the T001 touchpoint list
    did its job as a guardrail, not as a work item). No VERSION bump.
  - `CHANGELOG.md`: `### Documentation` entry added under `[Unreleased]`.
- [ ] T019 On merge: update `CLAUDE.md` SPECKIT block — 020 to MERGED with
  PR/SHA (do NOT commit `.claude/settings.json`); also carries the R5 note
  (typing patch v4) for CLAUDE.md's own next maintenance.

## Dependencies & Execution Order

- T001 → everything (template tasks need the touchpoint list; cheap, do
  first). T002 (US1) and T003–T005 (US2) are independent of each other.
- Within US2: T003 → T004 (ES derives from EN skeleton) → T005.
- US3 tasks T006–T014 are parallel [P] (distinct files); T015 after T013/
  T014 only if claude-md.tpl shares touchpoint assertions (T001 decides).
- T016–T018 after all doc tasks; T019 merge-time.

## Parallel Opportunities

- T006–T014: nine distinct files — the widest fan-out; each is
  self-contained (its drift table section + its coverage-map rows).
- T002 and T003 can run alongside US3 tasks (different files).

## Implementation Strategy

US1+US2 first (the front door and the executable-adjacent quickstarts are
the highest-leverage fixes), then the US3 fan-out, then the closing audit
proves SC-001. One PR — the feature is one coherent docs release; splitting
would leave the doc set internally inconsistent mid-stream.
