# Specification Quality Checklist: Los hooks de claude-mem 15.x encuentran su lanzador en los agentes docker

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-11-11
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- **Histórico (11-11-2026): dos marcadores abiertos a propósito, resueltos el mismo día con el operador (hoy el spec tiene 0 marcadores y los tres ítems que dependían de ellos están en [x]).** En los dos eligió la opción recomendada. FR-001: el arreglo es general, con `/home/agent/.local/bin` al final del PATH de los procesos del agente y nunca en el de root. FR-011: el DOCKER_E2E local más un gate en cbum con la imagen de la rama antes del merge, sin corrida manual de CI. Las preguntas originales eran si el arreglo es general o acotado a claude-mem (un enlace o envoltorio horneado solo para ese nombre), y qué evidencia hace falta antes del merge.
- **Sobre «technology-agnostic» y «no implementation details»**: igual que 025 y 039 a 044, es una feature de infraestructura cuyo dominio son el PATH del contenedor, los hooks de un plugin y el modelo de privilegios. Nombrarlos, junto con archivos y líneas, describe el problema y la evidencia, no el diseño. Los requisitos fijan resultados observables: el nombre se resuelve en cada contexto, nada se sombrea, root no ve el directorio y el modo local no cambia. El mecanismo lo elige el plan. Los «stakeholders» son los mantenedores del launcher y el operador de la flota.
- **Hechos verificados el 11-11-2026** (leídos o medidos, no recordados):
  - `docker/Dockerfile:118-125`, `docker/entrypoint.sh:64-108,118`, `docker/scripts/start_services.sh:668-697,837,842,865`;
  - `scripts/lib/mcp_warm.sh:150-182`, `scripts/heartbeat/heartbeat.sh:216`, `scripts/agentctl:966`, `modules/remote-control.env.tpl:8,13`, `tests/start-services-watchdog.bats:587`;
  - en ferrari, con sondas de solo lectura: el `hooks.json` de claude-mem en los tres agentes, el PATH de `docker exec -u agent`, del entorno global de tmux y del pane, el contenido de `~/.local/bin`, `features.heartbeat.enabled`, el worker de claude-mem en cbum y que el enlace manual es el único `claude-mem` en el PATH de la imagen.
- **Inferencias que NO son hechos**: que los hooks siguientes de la primera sesión encuentren el lanzador, que donna y linus puedan pasar a 15.x solos y que un proceso root con el directorio en su PATH pudiera ejecutar algo plantado por `agent`. Otras dos inferencias del primer borrador se midieron en la Fase 0 del plan (11-11-2026): un job de `crond` hereda el entorno de `crond` (confirmado, `research.md` M1), y una sesión tmux nueva NO hereda el entorno global del servidor, sino el del cliente que la crea (refutado, M2 y M3). Los 16 ítems siguen en [x].
- **Revalidado tras `/speckit-analyze` (11-11-2026)**: el análisis encontró 1 CRITICAL, 2 HIGH, 7 MEDIUM y 6 LOW, y el operador pidió corregirlos todos. Cambiaron el contexto, una fila de la tabla (el error del hook pasó a medido en el transcript), US2, US3, los casos borde, FR-001, FR-002, FR-007, FR-009, FR-010, FR-011, FR-013, SC-001 a SC-003 y Assumptions. Se agregó la sesión de Clarifications del análisis. Los 16 ítems siguen en [x]: SC-001 ahora tiene un método verificable con control positivo, y FR-004 se verifica sin root.
- **Corrección durante la implementación (11-11-2026)**: el spec decía que el tick del heartbeat enlaza los plugins, y en realidad los deshabilita todos (`heartbeat.sh:125-172`, `research.md` M9). Se corrigieron el contexto, la fila de la tabla, US1 escenario 3 y FR-002, y se agregó la decisión del operador de mantener el heartbeat por consistencia. Los 16 ítems siguen en [x].
- **Sin hooks ni rama nueva por spec-kit**: `.specify/extensions.yml` tiene `hooks: {}`. La rama `045-plugin-launcher-path` se creó a mano en su worktree propio (`.claude/worktrees/045-plugin-launcher-path`) desde `origin/main` = `c242c31`. El número 045 sale de `feature_numbering: sequential`: `specs/` llega hasta 044.
