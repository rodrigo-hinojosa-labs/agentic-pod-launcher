# Specification Quality Checklist: Los tests e2e de qmd dejan de caer por la carrera del `.reindex.lock`

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-10-29
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

- **Histórico (29-10-2026): dos marcadores abiertos a propósito, resueltos en el clarify de la misma sesión (hoy el spec tiene 0 marcadores y los cuatro ítems que dependían de ellos están en [x]).** FR-008 llevaba `[NEEDS CLARIFICATION]` porque la pregunta cambiaba el alcance (¿entra también la fase 3 de la prueba 12, que supone el lock libre y no tiene falla registrada?) y FR-011 porque cambiaba las compuertas y el calendario (¿corridas manuales en CI antes del PR?). El operador pidió resolverlas en `/speckit-clarify`, una a la vez con `AskUserQuestion`, como en 041 y 042, y en las dos eligió la opción recomendada. FR-008: sí, todos los sitios que suponen el lock libre (la fase 3 de la prueba 12 entra; el segundo tick de la prueba 13 ya estaba en FR-007 por ser la misma prueba). FR-011: una corrida manual en CI antes del PR, no tres. Al revalidar, los ítems «No markers remain», «testable and unambiguous», «Scope is clearly bounded» y «clear acceptance criteria» pasaron a [x]. Además, SC-003 cambió «la duración de hoy más o menos el ruido» por un umbral medido: la prueba 16 sin su fase `setup` no sube más de 5 s sobre los 16 a 19 s de las nocturnas del 25 al 28-10.
- **Sobre «technology-agnostic» y «no implementation details»**: igual que 025, 039, 041 y 042, esta es una feature de infraestructura de pruebas, cuyo DOMINIO son el e2e de qmd, el lock `.reindex.lock`, bats y GitHub Actions. Nombrarlos (y nombrar archivos, líneas y mensajes de log) es describir el problema y la superficie que ve el mantenedor, no filtrar implementación incidental. El «cómo» queda fuera de los requisitos: FR-001 a FR-007 fijan resultados observables (qué se reintenta, qué se afirma, qué dice el reporte) y el plan elige el mecanismo (sondeo, bucle, variable de entorno). Los «stakeholders» son los mantenedores del launcher.
- **Hechos verificados el 29-10-2026** (leídos o medidos, no recordados): `scripts/lib/qmd_index.sh:453-488`, `:491-540`, `:545-573` y `:669-717` (el lock, el sentinel y el estado que deja cada corrida); `scripts/qmd_watch.sh:20,52-77` y `docker/scripts/start_services.sh:183-188,225` (el vigilante y el despacho del setup); `docker/scripts/heartbeatctl:388,1102-1130` (el cron del wiki-graph y el reindex manual); `tests/docker-e2e-qmd.bats:57-97,264-276,400-528,636-688,753-938` (el estado al fallar, la fase 3 de la prueba 12, la prueba 13, el workspace de qmd real y el test 041); `tests/qmd-embed-nightly.bats:855-985` (el molde del oráculo); y el log completo del run 40865079036 (cronología de las fases y estado al fallar).
- **Inferencias que NO son hechos**: que el reindex del vigilante pueda adelantarse al manual cuando este espera más de 15 s y deje `skipped`; que la prueba 13 aborte por el `cat` de la línea 496 (sin volcado del contenedor que lo confirme); que el dueño del lock fuera un descendiente del setup con el descriptor 9 o el vigilante, y que no fuera el propio subshell del setup. Ninguna está medida; el estado al fallar de FR-009 es lo que las confirmará o refutará si la falla vuelve.
- **Sin hooks ni rama nueva**: `.specify/extensions.yml` tiene `hooks: {}` (no se ejecutó ningún hook). La rama `043-e2e-lock-race-hardening` se creó a mano en su worktree propio (`.claude/worktrees/043-e2e-lock-race-hardening`) desde `origin/main` = `cd8b74f`; el número 043 sale del autonumerado de `feature_numbering: sequential` (`specs/` de esa base llega hasta 042; la 040 vive solo en su rama sin mergear) y coincide con el que el operador y la memoria del proyecto le dieron.
