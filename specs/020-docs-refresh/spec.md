# Feature Specification: Docs Refresh to v0.12.0 Reality

**Feature Branch**: `020-docs-refresh`

**Created**: 2026-07-12

**Status**: Draft

**Input**: User description: "Actualizar toda la documentación del repo del launcher a la realidad de la versión actual (VERSION 0.12.0, features 001-019 mergeadas): README.md raíz (hoy docker-only, omite modo local 011, stack RAG 010/012-014, backups de 3 ramas, hardening 015-018, suite real); quickstarts agénticos docs/agentic-quickstart.{es,en}.md (pre-011, deben cubrir los DOS modos con paridad es/en); auditoría de drift del resto de docs/ y de los templates de docs por workspace. Regla dura anti-alucinación: toda afirmación no trivial verificada contra código/tests reales antes de escribirla. Docs-only."

## Context

The launcher's code has advanced through 19 merged features (v0.12.0) but its
documentation froze at different points along the way: the root `README.md`
still presents the project as Docker-only (the local/systemd deployment mode
shipped in 011), the agentic quickstarts (`docs/agentic-quickstart.es.md` /
`.en.md`, consumed by the `/quickstart` skill) predate the wizard's deployment
-mode prompt entirely, and several `docs/` guides date from mid-June (before
the RAG stack, the three-branch backup model, and the 015-018 hardening).
Stale documentation actively misleads: a new operator following the README
never learns local mode exists; an agent driving `/quickstart` answers a
prompt sequence that no longer matches the wizard; a contributor reading
`state-layout.md` designs against a layout that moved. This feature brings
every repo doc back to verified truth, with the project's hallucination-
prevention rule applied to documentation itself: no claim gets written from
memory — each non-trivial statement is checked against the current code,
templates, or tests before it lands.

Current inventory (dates = last substantive edit):

| Doc | Last touched | Known/suspected drift |
|-----|--------------|----------------------|
| `README.md` | pre-011 framing | "Docker-only" positioning; no local mode, no RAG stack, no 3-branch backups; prerequisites/quickstart sections predate deployment-mode prompt |
| `docs/agentic-quickstart.es.md` + `.en.md` | Jun 20 | No deployment-mode prompt; wizard answer order stale vs `tests/helper.bash::wizard_answers()`; no local-mode flow or post-scaffold steps |
| `docs/getting-started.md` | Jul 4 | 011-era; RAG (012-014) and hardening (015-018) missing |
| `docs/architecture.md` | Jul 7 | 014-era; 015-018 changes (managed prefix, sqlite-vec swap, embed loop, TMPDIR routing) missing |
| `docs/heartbeatctl.md` | Jul 7 | 014-era; newer subcommands/state files (qmd-index.json pending, wiki-graph) to verify |
| `docs/vault.md` | Jul 7 | 014-era; qmd invocation contract changed in 016-018 |
| `docs/state-layout.md` | Jun 18 | Very stale: predates local mode, managed qmd prefix, wiki-graph `.graph/`, scratch/TMPDIR layout |
| `docs/adding-an-mcp.md` | Jun 18 | Predates 016/T036 wrapper contract (`QMD_MCP_COMMAND`), per-mode env resolution |
| `docs/adding-a-notifier.md` | Jun 18 | Low churn area; verify against current notifier contract |
| `docs/qmd-upgrade-checklist.md` | Jul 10 | Fresh (017); verify 018 additions (pending/partial/stalled) |
| `modules/next-steps.{en,es}.tpl` | (workspace-rendered) | Audit against current wizard/post-scaffold reality |
| `modules/claude-md.tpl` | (workspace-rendered) | Audit against current runtime features the agent should know |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - New operator gets an accurate README (Priority: P1)

As a new operator evaluating or installing the launcher, I read `README.md`
and get a truthful picture of what the project does TODAY: both deployment
modes (docker and local/systemd), the RAG stack (vault + lexical/semantic
index + wiki-graph), the three-branch backup/restore model, real
prerequisites per mode, and a quickstart that matches the wizard I will
actually face.

**Why this priority**: The README is the front door; today it silently
hides half the product (local mode) and its flagship subsystem (RAG).

**Independent Test**: A reader following the README's quickstart on a clean
machine reaches a running agent in EITHER mode without hitting a prompt,
flag, or file the README never mentioned; every command quoted in the README
exists and runs as written.

**Acceptance Scenarios**:

1. **Given** the updated README, **When** a reader checks the feature
   overview, **Then** both deployment modes and the RAG/backup subsystems
   are described, each traceable to current code.
2. **Given** the quickstart section, **When** its commands are compared to
   the real wizard/agentctl surfaces, **Then** every command, flag, and
   referenced file exists (no retired flags, no renamed scripts).
3. **Given** the stated test-suite status, **When** compared to the actual
   suite, **Then** the number matches the current reality (977 tests, 0
   failures at time of writing).

---

### User Story 2 - Agentic quickstarts drive the CURRENT wizard, both modes (Priority: P1)

As a user driving the wizard from a Claude session (`/quickstart`) — or an
agent following the quickstart docs autonomously — the ES and EN quickstart
docs describe the wizard's ACTUAL prompt sequence (deployment mode first,
per 011) with the semantics and safe defaults of every prompt, the local-
mode specific steps (systemd units, sudo step, bootstrap), the docker-mode
steps (build, up, login), and the post-scaffold validation for each mode —
with ES and EN kept in parity.

**Why this priority**: These docs are executable-adjacent: the `/quickstart`
skill consumes them; drift there produces wrong answers piped into the real
wizard — worse than no doc.

**Independent Test**: The prompt order documented in both quickstarts
matches `tests/helper.bash::wizard_answers()` (the canonical order the suite
enforces) one-to-one; a dry-run scaffold in each mode encounters no prompt
missing from the doc; ES and EN cover the same sections with the same
semantics.

**Acceptance Scenarios**:

1. **Given** the updated quickstarts, **When** their prompt walkthrough is
   diffed against the canonical wizard order, **Then** every prompt appears,
   in order, including the deployment-mode choice and every mode-conditional
   branch (Linux-only service prompt, telegram sub-prompts, vault/qmd block,
   plugins).
2. **Given** the local-mode section, **When** followed on a Linux host,
   **Then** it covers the bootstrap, unit installation (sudo step), login,
   and the mode's post-scaffold checks (timers, watcher, doctor).
3. **Given** both language versions, **When** compared section-by-section,
   **Then** they are in structural and semantic parity.

---

### User Story 3 - Contributor docs match the code they describe (Priority: P2)

As a contributor (or a future Claude session) using `docs/` as ground truth
— architecture, state layout, heartbeatctl reference, vault/RAG guide,
extension guides (adding an MCP / a notifier), qmd upgrade checklist — every
claim I rely on (paths, commands, file formats, contracts, env vars) is
true of the current code, and the 011-019 subsystems missing from those docs
are documented where they belong.

**Why this priority**: These docs steer design decisions and reviews;
they're wrong in load-bearing places (state layout predates the managed
prefix; the MCP guide predates the wrapper contract) but they are consulted
less often than the front-door docs of US1/US2.

**Independent Test**: A drift audit lists every stale claim per doc with
its file:line disproof; after the update, a re-audit of the same claims
finds zero remaining falsehoods; spot-checking any documented command/path
against the repo confirms it.

**Acceptance Scenarios**:

1. **Given** the drift audit, **When** each finding is fixed, **Then** the
   doc's corrected claim cites what the auditor verified (commit-time
   accuracy), and no listed falsehood survives.
2. **Given** subsystems shipped in 011-019 with no home in `docs/`, **When**
   the update lands, **Then** each has coverage in the appropriate existing
   doc (no orphan features), or an explicit decision records why not.
3. **Given** the workspace doc templates (`next-steps`, `claude-md`),
   **When** rendered for each mode, **Then** their instructions match the
   current post-scaffold reality of that mode.

---

### Edge Cases

- Claims that are true in one deployment mode and false in the other: docs
  must qualify per mode instead of generalizing (the historical root cause
  of the README's staleness).
- Docs describing behavior gated behind opt-ins (vault, qmd, wiki-graph,
  heartbeat): wording must not imply always-on behavior.
- Version-pinned facts (tool versions, test counts, image base) age fast:
  where they appear, they are labeled with the version they were verified
  against (v0.12.0) rather than presented as timeless.
- ES/EN parity: only the agentic quickstarts are bilingual; the audit must
  not "helpfully" translate other docs (out of scope).
- The `docs/superpowers/` design-notes directory and `specs/` histories are
  records, not living docs — excluded from the refresh.
- `CLAUDE.md` (repo) and `CHANGELOG.md` are maintained by their own
  processes (spec-kit block / release discipline) — excluded except where a
  doc cross-references them incorrectly.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `README.md` MUST present both deployment modes as first-class
  (what each is, when to choose it, per-mode prerequisites and quickstart),
  and describe the current subsystem set (heartbeat, backups' three
  independent branches + restore, vault + RAG lexical/semantic + wiki-graph,
  channels, plugin management) at overview depth with pointers into `docs/`.
- **FR-002**: Every command, flag, path, filename, and prompt mentioned in
  updated docs MUST exist in the current codebase, verified at writing time
  (the anti-hallucination rule applied to docs; no claim from memory).
- **FR-003**: Both agentic quickstarts MUST document the wizard's current
  prompt sequence one-to-one with the canonical order the test suite
  enforces (`wizard_answers()`), including the deployment-mode prompt, all
  conditional branches, and each prompt's semantics + safe default.
- **FR-004**: The agentic quickstarts MUST gain a local-mode path (flow,
  bootstrap, unit installation, login, post-scaffold validation) alongside
  the docker path, and ES/EN MUST end in structural + semantic parity.
- **FR-005**: A drift audit MUST be produced for every doc in scope (the
  inventory table) BEFORE editing: per doc, the list of stale/false claims
  each with its current-code disproof (file:line or command output). The
  audit artifact lives with the feature's spec materials.
- **FR-006**: Every audited falsehood MUST be corrected or removed; every
  011-019 subsystem lacking documentation MUST get coverage in the most
  appropriate existing doc, or a recorded won't-document decision.
- **FR-007**: The workspace doc templates (`modules/next-steps.en.tpl`,
  `modules/next-steps.es.tpl`, `modules/claude-md.tpl`) MUST be audited
  against the current wizard output and runtime for BOTH modes; template
  fixes are in scope (they are docs delivered through render), and any
  template change keeps the render contract green (tests).
- **FR-008**: The refresh MUST NOT change behavior: no edits to executable
  code, schemas, or non-doc templates. If the audit uncovers a code bug
  (docs were right, code drifted), it is recorded as a finding for a future
  feature, not fixed here.
- **FR-009**: Facts that age (versions, counts, dates) MUST be tagged with
  the verification point ("as of v0.12.0") wherever stated.
- **FR-010**: Cross-references between docs (links, "see X") MUST resolve
  after the refresh (no dead anchors/paths).

### Key Entities

- **Doc inventory**: the closed list of in-scope documents (table in
  Context) with their audit status.
- **Drift finding**: one stale/false claim — doc, quote, disproof
  (file:line/command), resolution (corrected/removed/kept-with-
  qualification).
- **Coverage gap**: an 011-019 subsystem absent from docs, with its target
  doc or a won't-document decision.
- **Canonical prompt order**: the wizard sequence enforced by
  `tests/helper.bash::wizard_answers()` — the single source the quickstarts
  must mirror.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Zero surviving audited falsehoods: re-running the drift audit
  checks against the updated docs yields no remaining stale claims (the
  audit list is the test).
- **SC-002**: 100% of the wizard's prompts (including conditionals) appear
  in both quickstarts in canonical order; 0 prompts documented that no
  longer exist.
- **SC-003**: Both deployment modes reachable from README alone: each mode's
  quickstart path is complete (clone → running agent) without consulting
  undocumented steps.
- **SC-004**: ES/EN quickstart parity: same section structure, same prompt
  coverage, same defaults (verified by side-by-side section diff).
- **SC-005**: Zero behavior change: full host suite remains green
  (977/0 baseline; render-contract tests pass unchanged unless a template
  doc fix legitimately updates a rendered-string assertion, which then
  changes WITH its test in the same commit).
- **SC-006**: All in-scope docs state their verification point (v0.12.0)
  where aging facts appear; all cross-doc links resolve.

## Assumptions

- Scope is the inventory table: `README.md`, the two agentic quickstarts,
  the eight `docs/*.md` guides, and the three workspace doc templates.
  `docs/superpowers/`, `specs/`, `CLAUDE.md`, `CHANGELOG.md` are excluded
  (edge cases).
- Only the agentic quickstarts are bilingual; all other docs stay
  English-only (current convention).
- "Latest version" means main at v0.12.0 (`33bfb74`); docs are verified
  against that tree, not against unreleased branches.
- The drift audit's disproofs use the repo itself (code, templates, tests,
  rendered scaffolds) — no external sources needed.
- Template fixes (FR-007) may touch rendered-doc assertions in the test
  suite; that is doc-scope, not behavior change, and ships with the
  corresponding test update in the same commit (SC-005).
- Deployment of updated `next-steps`/`claude-md` templates to existing
  workspaces (mclaren/ferrari) is NOT required by this feature — those
  render on the next `--regenerate`; only the launcher repo is in scope.

## Out of Scope

- Translating any doc beyond the existing ES/EN quickstart pair.
- New standalone docs for their own sake (coverage gaps land in existing
  docs unless the audit proves a new file is unavoidable).
- Code/behavior fixes for any code-vs-doc mismatch where the CODE is wrong
  (recorded as findings for a future feature).
- Updating deployed workspaces (mclaren/ferrari) — next `--regenerate`
  picks up template changes.
- `docs/superpowers/` design notes, `specs/` feature histories, repo
  `CLAUDE.md`, `CHANGELOG.md`.
