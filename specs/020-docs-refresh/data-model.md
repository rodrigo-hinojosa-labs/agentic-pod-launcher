# Data Model: Docs Refresh (020)

No production data. The feature's "entities" are the audit artifacts and
their lifecycle through implementation.

## Drift finding (row in drift-audit.md)

| Field | Meaning |
|-------|---------|
| doc | in-scope document it belongs to |
| claim + location | what the doc says today, where |
| verdict | `false` / `stale` / `needs-qualifier` / `unverified-suspicion` |
| evidence | the file:line or command output that disproves/qualifies it |
| suggested_fix | one-sentence direction (writer re-verifies at edit time) |
| severity | high / medium / low (high = breaks a user flow or mental model) |

**Lifecycle**: recorded (Phase 0) → resolved during implement
(corrected / removed / kept-with-qualifier; `unverified-suspicion` must
first be verified or dropped) → re-checked in the SC-001 closing audit.
Invariant: no finding may end the feature unresolved.

## Coverage gap (row in coverage-map.md)

| Field | Meaning |
|-------|---------|
| subsystem + feature | what shipped (011-019) and where it came from |
| currently_documented | yes / partial / no — with the auditor's grep proof |
| best_home_doc | the existing doc that must absorb it (no new docs) |

**Lifecycle**: `no`/`partial` → covered in its home doc, or a recorded
won't-document decision (FR-006). The 4 `yes` rows need no action.

## Canonical prompt (row in wizard-prompt-order.md)

| Field | Meaning |
|-------|---------|
| order | position in the real wizard flow |
| asked_when | always vs the exact condition (mode, platform, prior answer) |
| default + semantics | what Enter does and what the prompt controls |
| source | file:line in wizard.sh / setup.sh / helper.bash |

**Invariant (SC-002)**: quickstarts cover 52/52, in order, no retired
prompts; conditionals annotated with their trigger.

## Doc status (tracking through implement)

Per in-scope doc: `audited` → `updated` → `re-audited` (SC-001 pass) with
its strategy from research R2 (rewrite | surgical). Templates additionally
carry `render-tests-checked` (R4).
