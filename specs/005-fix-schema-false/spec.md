# Feature Specification: schema validation accepts a present boolean `false`

**Feature Branch**: `005-fix-schema-false`

**Created**: 2026-06-21

**Status**: Draft

**Input**: Re-installing an agent from scratch with the heartbeat disabled (`features.heartbeat.enabled: false`) surfaced that `./setup.sh --regenerate` aborts with "missing required field: .features.heartbeat.enabled" even though the field is present and valid. The required-field check treats a present boolean `false` as if the field were absent.

## User Scenarios & Testing *(mandatory)*

The actor is an **operator** who maintains a scaffolded agent whose `agent.yml` legitimately sets a required boolean field to `false` (e.g. `features.heartbeat.enabled: false` to disable the periodic heartbeat) and runs a lifecycle command that validates `agent.yml`.

### User Story 1 - Regenerate an agent that disables a feature (Priority: P1)

An operator has an agent with `features.heartbeat.enabled: false` and runs `./setup.sh --regenerate` (or any command that validates `agent.yml`). Validation passes and the derived files regenerate, exactly as it would for an agent with the field set to `true`.

**Why this priority**: It is the whole bug. A required boolean field set to its valid `false` value blocks every validate-gated lifecycle command (`--regenerate`, mutation paths), so an agent that disables any feature cannot be regenerated without hand-editing the schema or the agent.yml — a silent footgun that contradicts "agent.yml is the single source of truth".

**Independent Test**: Take a valid `agent.yml` whose only "issue" is a required boolean leaf set to `false`; run the validator (or `--regenerate`); it succeeds.

**Acceptance Scenarios**:

1. **Given** an `agent.yml` with a required boolean leaf set to `false`, **When** the validator runs, **Then** it reports no "missing required field" error for that leaf and validation passes.
2. **Given** an `agent.yml` with the same leaf set to `true`, **When** the validator runs, **Then** it still passes (no regression).
3. **Given** an `agent.yml` where a required leaf is genuinely absent, **When** the validator runs, **Then** it still reports that leaf as a missing required field (the real error is not masked).

### Edge Cases

- **Present-but-empty string** in a required string leaf: still reported as missing/empty (the fix must not turn a genuinely empty required value into a pass).
- **Literal `null`** value: treated as absent (missing required field), same as today.
- **Enum and boolean-shape checks**: a leaf whose value is `false` must reach the boolean-shape check (and pass it), not be short-circuited as "empty" before it.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Required-field validation MUST treat a present boolean `false` as PRESENT — it MUST NOT be reported as a missing required field.
- **FR-002**: Validation MUST still report a genuinely absent required field (missing key or `null`) as missing — the fix must not weaken absence detection.
- **FR-003**: A present-but-empty required string leaf MUST still be flagged (the empty-string case is unchanged).
- **FR-004**: All existing validation behavior (enums, boolean-shape, optional-non-empty leaves, top-level required blocks) MUST be unchanged for every value other than a present `false`.
- **FR-005**: The fix MUST be covered by a test that reproduces the bug (a required boolean leaf set to `false` is wrongly rejected → red) and proves the fix (→ green), and the existing default (no-Docker) test suite MUST stay green.

### Key Entities

- **Required boolean leaf**: an `agent.yml` field that is mandatory and whose valid values are `true`/`false` (e.g. `features.heartbeat.enabled`). A present `false` is a valid, complete value — not an absence.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `./setup.sh --regenerate` succeeds on an `agent.yml` whose only previously-blocking trait is a required boolean leaf set to `false`.
- **SC-002**: The validator reports zero false "missing required field" errors for any required boolean leaf set to `false`, and still reports a real missing/`null` leaf.
- **SC-003**: The default (no-Docker) `bats` suite stays green, with new coverage that fails before the fix and passes after.

## Assumptions

- This re-applies the intent of the orphaned `002-fix-schema-bool` work: the spec directory `specs/002-fix-schema-bool/` exists but the `scripts/lib/schema.sh` code change never reached `main` (the `// ""` fallback is still there on `main`).
- The fix is localized to the schema-validation value-reading helper; no `agent.yml` schema fields, enums, or required sets change.
- Out of scope: any other schema field/enum changes, and re-validating agents that already pass today (their behavior is unchanged).
