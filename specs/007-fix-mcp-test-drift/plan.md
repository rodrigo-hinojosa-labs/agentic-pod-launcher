# Implementation Plan: Corregir drift de tests del contrato MCP renderizado

**Branch**: `007-fix-mcp-test-drift` | **Date**: 2026-06-22 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/007-fix-mcp-test-drift/spec.md`

## Summary

Seis assertions de `bats` quedaron congeladas en el contrato MCP previo a PR #59 y hoy fallan en `main` (668 tests, 6 fallando). El template `modules/mcp-json.tpl` ya renderiza el contrato correcto (github → binario nativo `github-mcp-server` args `["stdio"]`; vault → pin `@bitbonsai/mcpvault@0.12.0`). El plan es **alinear las 6 assertions al contrato vigente**, sin tocar templates ni runtime, devolviendo la suite a verde total. Enfoque: editar `tests/mcp-json.bats` (4 tests), `tests/regenerate.bats` (1 test) y `tests/scaffold.bats` (1 test), correr la suite, y cerrar con entrada de `CHANGELOG.md` + bump de `VERSION` 0.4.0 → 0.4.1.

## Technical Context

**Language/Version**: Bash 4+ (tests `bats-core`); `jq` para aserciones sobre `.mcp.json`; `yq` v4+ para el contexto de render.

**Primary Dependencies**: `bats-core`, `jq`, `yq` v4+, `git`, `tmux` (deps de test ya documentadas en CLAUDE.md). Render vía `scripts/lib/render.sh` (no se modifica).

**Storage**: N/A (cambio de aserciones de test; sin estado persistente).

**Testing**: `bats tests/` en el host, sin Docker. Verificación por archivo (`bats tests/mcp-json.bats`, `bats tests/regenerate.bats`) y suite completa.

**Target Platform**: Host del launcher (macOS/Linux). No requiere daemon Docker.

**Project Type**: CLI / bash tooling (launcher host-side). Estructura single-project con `tests/` plano.

**Performance Goals**: N/A. La suite completa ya corre en el orden de segundos-decenas de segundos en el host; el cambio no la altera.

**Constraints**: Test-only. Cero líneas fuera de `tests/`, `CHANGELOG.md` y `VERSION`. La versión de vault en las assertions DEBE ser `0.12.0` (consistente con `AGENTIC_FLOOR_MCP_VAULT`).

**Scale/Scope**: 6 aserciones en 2 archivos de test; ~6-10 líneas de cambio efectivo + CHANGELOG/VERSION.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — **N/A / PASS**. No se crea ni edita ningún archivo derivado ni template; `agent.yml` y el render quedan intactos. El cambio es exclusivamente sobre aserciones de test, que no son output renderizado. Sobrevive `--regenerate` trivialmente (no toca nada que `--regenerate` produzca).
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — **N/A**. No toca `docker/`, capabilities, mounts ni rutas de `docker exec`.
- [x] **III. Test-First, Host-Runnable** — **PASS**. El feature ES coverage: corrige aserciones para que la suite por defecto (sin Docker) vuelva a verde. `shellcheck -S error` no aplica a `.bats` pero se re-verifica limpio en el repo; los archivos de test no introducen side effects en libs sourceadas.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — **N/A**. No toca boot/patch/install/backup ni notifiers.
- [x] **V. Workspace-Is-the-Agent** — **N/A**. No toca `.state/`, secretos ni ramas de backup.
- [x] **VI. Reproducible, Pinned Dependencies** — **PASS con nota**. No introduce un pin duplicado NUEVO: alinea la assertion al literal `0.12.0` que ya existe hardcodeado en `modules/mcp-json.tpl`. La duplicación pre-existente del literal `0.12.0` entre `versions.sh` (`AGENTIC_FLOOR_MCP_VAULT`) y el template es **deuda conocida**, señalada por el Principio VI ("single source of truth rather than the same literal duplicated"); se documenta como fuera de alcance, no se agrava. Cierra con `CHANGELOG.md` + bump de `VERSION` (cambio visible al mantenedor: estado de la suite).

**Resultado del gate: PASS (6/6).** Sin violaciones → Complexity Tracking vacío.

## Project Structure

### Documentation (this feature)

```text
specs/007-fix-mcp-test-drift/
├── plan.md              # Este archivo (/speckit-plan)
├── research.md          # Fase 0 (/speckit-plan)
├── data-model.md        # Fase 1 (/speckit-plan)
├── quickstart.md        # Fase 1 (/speckit-plan)
├── contracts/
│   └── mcp-render-contract.md   # Fase 1: contrato MCP esperado (github + vault)
├── checklists/
│   └── requirements.md  # Creado por /speckit-specify
└── tasks.md             # Fase 2 (/speckit-tasks — NO lo crea /speckit-plan)
```

### Source Code (repository root)

```text
tests/
├── mcp-json.bats        # 4 assertions a corregir (github npx→github-mcp-server; vault @latest→@0.12.0)
├── regenerate.bats      # 1 assertion a corregir (vault @latest→@0.12.0, vía --regenerate)
└── scaffold.bats        # 1 assertion a corregir (vault @latest→@0.12.0, vía wizard/setup.sh)

modules/
└── mcp-json.tpl         # FUENTE DEL CONTRATO — solo lectura, NO se modifica

scripts/lib/
└── versions.sh          # AGENTIC_FLOOR_MCP_VAULT="0.12.0" — fuente de la versión, solo lectura

CHANGELOG.md             # entrada del feature
VERSION                  # 0.4.0 → 0.4.1
```

**Structure Decision**: Single-project, `tests/` plano (convención existente del repo). El cambio se concentra en dos archivos `.bats`; `modules/mcp-json.tpl` y `scripts/lib/versions.sh` se consultan como fuente del contrato/versión pero permanecen intactos.

## Complexity Tracking

> Sin violaciones de la constitución. Tabla vacía a propósito.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (ninguna) | — | — |
