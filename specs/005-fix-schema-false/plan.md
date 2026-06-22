# Implementation Plan: schema validation accepts a present boolean `false`

**Branch**: `005-fix-schema-false` | **Date**: 2026-06-21 | **Spec**: [spec.md](./spec.md)

## Summary

`scripts/lib/schema.sh::_schema_get` reads a value via `yq -r "$path // \"\""`. yq's `//` alternative operator treats a present boolean `false` as falsy and returns the RHS, so `_schema_get` yields `""` for `enabled: false`. The required-leaf loop then flags `[ -z "$val" ]` as "missing required field". Fix: read raw (`yq -r "$path"`) and normalize only the literal `"null"` to empty — a present `false` survives as the string `"false"`, an absent/null path still becomes `""`. One-line change in one helper, already guarded by the existing null check. Re-applies the orphaned `002-fix-schema-bool`.

## Technical Context

**Language/Version**: Bash (host), `yq` v4 (mikefarah), `bats` for tests
**Primary Dependencies**: `scripts/lib/schema.sh` (sourced by `setup.sh` on `--regenerate`/mutations and by `tests/schema*.bats`)
**Testing**: default no-Docker `bats` suite; `tests/schema.bats` / `tests/schema-validate.bats` exercise `agent_yml_validate` / `_schema_get`
**Target Platform**: host launcher (macOS + Linux)
**Project Type**: single-project launcher
**Constraints**: no `agent.yml` schema field/enum/required-set change; absence detection (missing key / `null`) and empty-required-string detection unchanged; default suite stays green
**Scale/Scope**: 1 helper function, ~1 line + comment; 1–2 new test cases; CHANGELOG + VERSION

## Constitution Check

*Gate against `.specify/memory/constitution.md` v1.0.0. No violations.*

- [x] **I. Single Source of Truth** — `agent.yml` stays the source of truth; this only makes the validator read it correctly. No derived-file hand-edits; no schema field changes.
- [x] **II. Least-Privilege** — host-side validation only; no container/privilege surface touched.
- [x] **III. Test-First, Host-Runnable** — a `bats` case reproduces `enabled: false` rejection (red) before the fix and passes after (green); runs with no Docker; `shellcheck -S error scripts/lib/schema.sh` clean; `schema.sh` keeps no side effects on source.
- [x] **IV. Idempotent, Fail-Silent** — validation is a pure read; the fix narrows a false-positive without adding state.
- [x] **V. Workspace-Is-the-Agent** — no state/secret surface; `.state` untouched.
- [x] **VI. Reproducible, Pinned Dependencies** — no dependency change; `CHANGELOG.md` + `VERSION` bumped (patch) per the discipline.

## Project Structure

```
scripts/lib/
└── schema.sh          # _schema_get: drop the `// ""` fallback, read raw + null→""
tests/
└── schema.bats        # (or schema-validate.bats) new red→green case: required bool leaf = false
CHANGELOG.md · VERSION  # patch bump
```

**Structure Decision**: Single-project launcher; the fix is one helper in `scripts/lib/schema.sh` plus host-only `bats` coverage. No new modules, no `data-model.md`/`contracts/` (internal validation fix, no new entities or interfaces).

## Complexity Tracking

*No constitution violations — no entries.*
