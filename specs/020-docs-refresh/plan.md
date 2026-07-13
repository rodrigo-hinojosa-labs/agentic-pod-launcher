# Implementation Plan: Docs Refresh to v0.12.0 Reality

**Branch**: `020-docs-refresh` | **Date**: 2026-07-12 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/020-docs-refresh/spec.md`

## Summary

Thirteen in-scope documents (README, both agentic quickstarts, eight `docs/`
guides, three workspace doc templates) drifted across 19 merged features.
Approach: (Phase 0) a multi-agent drift audit produces, per doc, the list of
false/stale claims each with a file:line disproof, plus a canonical wizard
prompt-order extraction and an 011-019 subsystem coverage map — these three
artifacts ARE the research and become the feature's test oracle (SC-001/002).
(Phase 1) the audit findings are normalized into `drift-audit.md` (the
working checklist) and the doc-update contract. (Implementation) each doc is
rewritten/corrected against its findings with re-verification at writing time
(FR-002), quickstarts rebuilt around the extracted canonical prompt order in
ES/EN parity, coverage gaps landed in their best-home docs, and template
fixes ship with any legitimately-updated rendered-string test assertions in
the same commit. Docs-only: no behavior change (FR-008).

## Technical Context

**Language/Version**: Markdown (GitHub-flavored); bash only for verification
commands run during auditing/writing.

**Primary Dependencies**: none at runtime. Verification sources: the v0.12.0
tree (`33bfb74`) — `setup.sh`, `scripts/lib/*.sh`, `docker/`, `modules/*.tpl`,
`tests/` (notably `tests/helper.bash::wizard_answers()` as the canonical
wizard order the suite enforces).

**Storage**: N/A. Audit artifacts live in `specs/020-docs-refresh/`.

**Testing**: SC-001 re-audit (every recorded finding re-checked against the
updated doc); SC-002 prompt-order diff (quickstarts vs extraction); SC-004
ES/EN section parity diff; SC-005 full host suite stays green (`bats tests/`
— 977/0 baseline; render-contract assertions may change ONLY together with a
template doc fix); link check for SC-006.

**Target Platform**: repo docs (GitHub rendering); templates render into
scaffolded workspaces on `--regenerate`.

**Project Type**: documentation refresh inside the launcher repo.

**Performance Goals**: N/A.

**Constraints**: FR-008 no behavior change (no executable code, schema, or
non-doc template edits); code-vs-doc mismatches where CODE is wrong become
recorded findings, not fixes. Bilingual parity limited to the agentic
quickstart pair. Aging facts tagged "as of v0.12.0" (FR-009).

**Scale/Scope**: 13 docs (~130KB of prose), audit fan-out of 14 auditor
agents + 2 extractors; findings volume determined by Phase 0 (see
research.md once the audit lands).

## Constitution Check

*Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — PASS. No derived-file hand-edits: the
  three templates in scope ARE the source (their rendered outputs regenerate
  via `--regenerate`); repo docs are not rendered artifacts.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — N/A→PASS. No container
  surface touched; docs must DESCRIBE the privilege model accurately (audit
  checks this).
- [x] **III. Test-First, Host-Runnable** — PASS. The drift audit is the
  test-first analogue: findings recorded BEFORE edits, re-audit after
  (SC-001). Suite stays green; any rendered-string assertion changes only
  WITH its template fix (same commit). `shellcheck` untouched (no shell
  edits).
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — N/A. No lifecycle code.
- [x] **V. Workspace-Is-the-Agent** — PASS. Docs must describe `.state/`
  truthfully (state-layout is in scope for exactly this); no state handling
  changes.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. No dependency
  changes; version facts in docs get tagged with their verification point
  (FR-009). No VERSION bump (docs-only), CHANGELOG note under Unreleased.

**Post-design re-check**: PASS on all six — design confirms docs/templates
only. If implementation discovers a template fix that would alter rendered
BEHAVIOR (not wording), it is out of scope per FR-008 and becomes a finding.

## Project Structure

### Documentation (this feature)

```text
specs/020-docs-refresh/
├── spec.md
├── checklists/requirements.md
├── plan.md                    # This file
├── research.md                # Phase 0: audit synthesis (findings totals, themes, decisions)
├── drift-audit.md             # Phase 0 artifact: full findings tables per doc (the SC-001 oracle)
├── wizard-prompt-order.md     # Phase 0 artifact: canonical prompt order (the SC-002 oracle)
├── data-model.md              # Phase 1: finding/coverage-gap/doc-status shapes
├── contracts/
│   └── doc-update-contract.md # Per-doc update rules (verification, tagging, parity)
├── quickstart.md              # How to re-run the audits / verify SC-001..006
└── tasks.md                   # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
README.md                        # rewrite to dual-mode + current subsystems
docs/
├── agentic-quickstart.es.md     # rebuild on canonical prompt order (ES)
├── agentic-quickstart.en.md     # rebuild on canonical prompt order (EN, parity)
├── getting-started.md           # correct + extend to both modes
├── architecture.md              # correct 015-018 sections
├── heartbeatctl.md              # correct subcommands/state files
├── vault.md                     # correct qmd contract (016-018)
├── state-layout.md              # rewrite .state tree to current reality
├── adding-an-mcp.md             # correct to wrapper/per-mode contract
├── adding-a-notifier.md         # verify/touch-up
└── qmd-upgrade-checklist.md     # extend with 018 facts
modules/
├── next-steps.en.tpl            # audit-driven fixes (render contract stays green)
├── next-steps.es.tpl            # idem + parity
└── claude-md.tpl                # audit-driven fixes
CHANGELOG.md                     # Unreleased note (docs refresh)
tests/                           # ONLY if a template fix legitimately updates a rendered-string assertion
```

**Structure Decision**: no new standalone docs unless the audit proves one
unavoidable (spec Out of Scope); coverage gaps land in the best-home doc per
the coverage map.

## Phase 0 Execution Note

The audit runs as a 16-agent workflow (run `wf_a96ac163-11f`): 14 doc
auditors (schema-forced findings with evidence, verdicts limited to
false/stale/needs-qualifier/unverified-suspicion) + the wizard-order
extractor + the 011-019 coverage mapper. Findings without concrete evidence
must arrive as `unverified-suspicion` and get resolved (verified or dropped)
during implementation — every fix re-verifies its claim at writing time
anyway (FR-002), which is the second, adversarial-by-construction pass.

## Complexity Tracking

No constitution violations. Table intentionally empty.
