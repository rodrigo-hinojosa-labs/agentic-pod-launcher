# Specification Quality Checklist: Las secciones con lock de qmd sueltan `.reindex.lock` en cuanto terminan

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-11-06
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

- **Histórico (06-11-2026): dos marcadores abiertos a propósito, resueltos el mismo día con el operador (hoy el spec tiene 0 marcadores y los cuatro ítems que dependían de ellos están en [x]).** En las dos eligió la opción recomendada: FR-006 cubre todo lo que corre bajo el lock, y FR-009 pide el DOCKER_E2E local más una corrida manual de CI antes del PR. Las preguntas originales: FR-006 cambia el alcance: ¿el arreglo cubre solo las llamadas a qmd de `_qmd_run`, también el `bun install` de `_qmd_ensure_prefix`, o todo proceso que se lance bajo el lock? FR-009 cambia las compuertas y el calendario: ¿hace falta una corrida manual en CI antes del PR, como en 043?
- **Sobre «technology-agnostic» y «no implementation details»**: igual que 025, 039, 041, 042 y 043, esta es una feature de infraestructura cuyo dominio son el lock `.reindex.lock`, el `timeout` de BusyBox y el e2e de qmd. Nombrarlos, junto con archivos y líneas, describe el problema y la evidencia, no el diseño. Los requisitos fijan resultados observables: el lock libre en el primer sondeo, el tope intacto y la semántica intacta. El mecanismo lo elige el plan: el `9>&-` del issue es una propuesta no validada. Los «stakeholders» son los mantenedores del launcher y el operador de la flota.
- **Hechos verificados el 06-11-2026** (leídos o medidos, no recordados):
  - `scripts/lib/qmd_index.sh:209-284` (`_qmd_ensure_prefix` y `_qmd_run`), `:336-400` (la migración y su comentario), `:474-479`, `:491-540`, `:556-572`, `:612`, `:630`, `:681` y `:708`;
  - `docker/Dockerfile:5,45,265` y `setup.sh:1653-1676`;
  - `scripts/qmd_watch.sh:20,44-70`;
  - `docker/scripts/heartbeatctl:1157-1194`, `scripts/agentctl:1703-1709` y `modules/local-qmd-reindex.sh.tpl:54-61`;
  - la búsqueda de `flock` y `timeout` en `scripts/lib/`, `docker/scripts/lib/` y los scripts del boot;
  - el issue #116 con sus dos comentarios;
  - los logs de las cinco nocturnas del 02 al 06-11-2026, extraídos con `scratchpad/t046/t046_nights.py`.
- **Inferencias que NO son hechos**: que una edición del vault quede sin indexar hasta el próximo cron, y que la noche roja de #112 fuera este mecanismo. Otras dos inferencias del primer borrador ya se midieron en la Fase 0 del plan: las sustituciones de comando NO cuestan 1 s más (refutado, `research.md` M2) y el `timeout` de GNU no deja vigilante (confirmado, M3).
- **Revalidado tras `/speckit-analyze` (07-11-2026)**: el análisis reescribió SC-002, SC-004, SC-005 y SC-006, FR-010, el caso borde de la sección que muere a mitad de camino, la prueba independiente y dos escenarios de US2, y agregó la sesión de Clarifications del 07-11-2026 y una fila a «Estado de cada afirmación». Los 16 ítems siguen en [x]: SC-006 ahora declara sin medir lo que no se puede medir en vez de prometerlo, y SC-004 dice cómo se mide.
- **Hallazgo lateral declarado y fuera de alcance**: la migración manual corre sin el lock (leído en código). Se propone un issue propio, con COMPUERTA.
- **Sin hooks ni rama nueva**: `.specify/extensions.yml` tiene `hooks: {}`. La rama `044-qmd-lock-fd-leak` se creó a mano en su worktree propio (`.claude/worktrees/044-qmd-lock-fd-leak`) desde `origin/main` = `8cb45e4`. El número 044 sale del autonumerado de `feature_numbering: sequential`: `specs/` de esa base llega hasta 043, y la 040 vive solo en su rama sin mergear.
