---
feature: 005-fix-schema-false
branch: 005-fix-schema-false
---

# Tasks: schema validation accepts a present boolean `false`

**Spec**: [spec.md](./spec.md) · **Plan**: [plan.md](./plan.md)

TDD: the bug-reproducing test is written and shown failing before the fix. Default `bats` suite (no Docker) must stay green. Single user story (P1) — no phasing beyond setup/test/fix/polish.

## Format: `[ID] [P?] [Story] Description with file path`

---

## Phase 1: Tests (write first — must fail)

- [ ] T001 [P] [US1] In the schema test file (`tests/schema.bats` or `tests/schema-validate.bats`, whichever drives `agent_yml_validate`), add a red case: a minimal valid `agent.yml` with a required boolean leaf set to `false` (`features.heartbeat.enabled: false`) passes `agent_yml_validate` (status 0, no "missing required field" for that leaf). Confirm it FAILS against current `main`.
- [ ] T002 [P] [US1] Add the no-regression / absence cases (same file): (a) the leaf set to `true` passes; (b) the leaf genuinely absent (key deleted) STILL reports "missing required field"; (c) a present-but-empty required string leaf STILL flags. Confirm (b)/(c) already pass (guard against over-correction).

## Phase 2: Fix (make green)

- [ ] T003 [US1] In `scripts/lib/schema.sh::_schema_get`, drop the `// ""` fallback: read `yq -r "$path"` and keep the existing `[ "$val" = "null" ] && val=""` normalization so a present `false` survives as `"false"` while absent/`null` becomes `""`. Update the helper comment. (green for T001; T002 stays green)
- [ ] T004 [US1] Run `bats tests/schema.bats tests/schema-validate.bats` (T001 green, T002 green) + `shellcheck -S error scripts/lib/schema.sh`.

## Phase 3: Polish & verification

- [ ] T005 Run the full default suite `bats tests/` (0 fail) — confirm no regression anywhere that reads `_schema_get`.
- [ ] T006 Functional check (SC-001): a scaffolded `agent.yml` with `features.heartbeat.enabled: false` passes `./setup.sh --regenerate` (no "missing required field").
- [ ] T007 [P] `CHANGELOG.md` `### Fixed` entry + bump `VERSION` (patch, 0.3.0 → 0.3.1) per FR/Principle VI.

## Dependencies

- T001/T002 (tests) before T003 (fix). T003 before T004/T005/T006. T007 [P] anytime after the fix.

## Implementation Strategy

Single P1 slice. Red (T001) → fix (T003) → green (T004) → suite + functional (T005/T006) → polish (T007). One file of product code (`schema.sh`), one test file, CHANGELOG/VERSION.
