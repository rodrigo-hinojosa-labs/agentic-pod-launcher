# Tasks: Corregir drift de tests del contrato MCP renderizado

**Feature**: 007-fix-mcp-test-drift · **Branch**: `007-fix-mcp-test-drift`
**Spec**: [spec.md](./spec.md) · **Plan**: [plan.md](./plan.md) · **Contrato**: [contracts/mcp-render-contract.md](./contracts/mcp-render-contract.md)

Alcance test-only. Las 6 aserciones objetivo YA existen y hoy fallan (estado "rojo" de partida); la implementación corrige el valor esperado al contrato vigente. No se tocan templates ni runtime.

> **Corrección durante implementación**: la 6ª falla (test global 397 "wizard with vault…") está en `tests/scaffold.bats`, NO en `tests/regenerate.bats` como se asumió en el spec inicial. Reparto real: mcp-json.bats (4) + regenerate.bats (1) + scaffold.bats (1). Los guards de `tests/modules-render.bats` (afirman AUSENCIA del contrato viejo) son correctos y NO se tocaron.

## Phase 1: Setup (baseline rojo)

- [x] T001 Capturar el baseline rojo: `bats tests/ 2>&1 | grep -E "^not ok"` confirmó las 6 fallas (320, 321, 324, 328 en tests/mcp-json.bats; 367 en tests/regenerate.bats; 397 en tests/scaffold.bats) sobre 668 tests.

## Phase 2: Foundational (fijar el contrato fuente — solo lectura)

- [x] T002 Confirmado el contrato vigente leyendo `modules/mcp-json.tpl` (github líneas 60-66: `command: github-mcp-server`, `args: ["stdio"]`; vault líneas 67-71: `args: ["-y", "@bitbonsai/mcpvault@0.12.0", "/home/agent/.vault"]`) y la versión fuente `scripts/lib/versions.sh::AGENTIC_FLOOR_MCP_VAULT="0.12.0"`. Ninguno modificado.

## Phase 3: User Story 1 — Suite por defecto verde y fiel al contrato vigente (Priority: P1)

**Goal**: las 6 aserciones afirman el contrato renderizado actual y la suite queda verde total.

**Independent Test**: `bats tests/mcp-json.bats`, `bats tests/regenerate.bats`, `bats tests/scaffold.bats` y `bats tests/` → 0 fallas.

- [x] T003 [US1] En `tests/mcp-json.bats`, github: `.mcpServers.github.command` de `npx` → `github-mcp-server` en los 3 tests (líneas 88, 172, 255, vía `replace_all` sobre la línea idéntica) + aserción nueva `.mcpServers.github.args[0] == "stdio"` en el test canónico "has github when enabled".
- [x] T004 [US1] En `tests/mcp-json.bats`, vault: `.mcpServers.vault.args[1]` de `@bitbonsai/mcpvault@latest` → `@bitbonsai/mcpvault@0.12.0` (línea 110). Mismo archivo que T003 → editado en secuencia.
- [x] T005 [US1] En `tests/regenerate.bats` (línea 95) y `tests/scaffold.bats` (línea 154), vault `@latest` → `@0.12.0`. Archivos distintos a T003/T004.
- [x] T006 [US1] Verde por archivo: `tests/mcp-json.bats` (11 tests), `tests/regenerate.bats` (6), `tests/scaffold.bats` (12) → 0 fallas cada uno.

## Phase 4: Polish & Cross-Cutting

- [x] T007 Suite completa `bats tests/` → `FALLAS_TOTALES=0` (668 `ok`).
- [x] T008 Disciplina de alcance: el working tree solo toca `tests/` (3 archivos), `CHANGELOG.md`, `VERSION`, más overhead de spec-kit (`specs/007-*`, `.specify/feature.json`, marcador SPECKIT en `CLAUDE.md`). Cero archivos en `modules/`, `docker/`, `scripts/`, `setup.sh`.
- [x] T009 `VERSION` 0.4.0 → 0.4.1 y entrada en `CHANGELOG.md` (`### Fixed`, 007-fix-mcp-test-drift) describiendo el drift corregido y la deuda fuera de alcance (parametrizar la versión de vault desde versions.sh, Principio VI).
- [x] T010 Re-corrida `bats tests/` tras CHANGELOG/VERSION → sigue verde (ver Completion Report).

## Dependencies

- T001 → T002 → (T003 → T004) ‖ T005 → T006 → T007 → T008 → T009 → T010.
- T003 y T004 tocan el MISMO archivo (`tests/mcp-json.bats`) → secuenciales entre sí.
- T005 toca `tests/regenerate.bats` + `tests/scaffold.bats` → paralelizable con T003/T004.

## Parallel Execution Example

```text
# Tras T002, en paralelo (archivos distintos):
T003+T004 (tests/mcp-json.bats, secuencial entre ellas)  ||  T005 (regenerate.bats + scaffold.bats)
# Converge en T006 (verificación por archivo).
```

## Implementation Strategy

MVP = US1 completa (única historia). Entrega incremental: github primero (T003), vault después (T004/T005), verificar por archivo (T006), luego suite completa y cierre de disciplina (T007-T010). Cada paso verificable con `bats` en el host, sin Docker.
