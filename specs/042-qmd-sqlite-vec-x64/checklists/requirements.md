# Specification Quality Checklist: El embed de qmd funciona en la imagen docker sobre amd64 y el nightly vuelve a ejercitarlo

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-10-18
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

- **Histórico (18-10-2026): un marcador abierto a propósito, resuelto en el clarify del mismo día (hoy el spec tiene 0 marcadores y los cuatro ítems que dependían de él están en [x]).** FR-014 llevaba `[NEEDS CLARIFICATION]` porque la pregunta cambiaba el alcance (¿el nightly ejercita también el embed en un runner arm64 dentro de esta feature, historia 4, o se difiere?) y el operador pidió resolver esas decisiones en `/speckit-clarify`, una a la vez con `AskUserQuestion`, igual que en 041. Respuesta: se difiere a una feature aparte; la historia 4 salió del spec, FR-014 pasó a fijar que el nightly sigue solo en amd64 y la cobertura permanente en arm64 entró a Out of Scope. Los ítems «No markers remain», «testable and unambiguous», «Scope is clearly bounded» y «clear acceptance criteria» quedaron en [x] al revalidar.
- **Sobre «technology-agnostic» y «no implementation details»**: igual que 025, 039 y 041, esta es una feature de infraestructura, cuyo DOMINIO son la imagen docker, qmd, GitHub Actions y bash. Nombrarlos (y nombrar variables, archivos y líneas de log) es describir el problema y la superficie que ve el mantenedor, no filtrar implementación incidental. El «cómo» queda fuera de los requisitos: FR-004 y FR-005 fijan resultados observables (qué paquete se toca, qué deja el log) y el plan elige el mecanismo. Los «stakeholders» son los mantenedores del launcher y quienes operan la imagen.
- **Hechos verificados el 18-10-2026** (leídos o ejecutados, no recordados): `qmd_index.sh:105-144` y `:202-227` (el destino fijo y la salida callada del reemplazo, y que corre en cada preparación del prefijo); `docker/scripts/build-sqlite-vec.sh` (compila la build musl y falla en voz alta); `tests/qmd-sqlite-vec.bats` (cinco pruebas del reemplazo, todas con la disposición arm64) y el log de la corrida 39069243972 (el mensaje del contenedor, `x86_64` y el veredicto `GLIBC` del paquete x64). La tabla «Estado de cada afirmación» del spec separa lo medido de lo inferido y de lo no medido.
- **Inferencias que NO son hechos**: que las opciones de compilación de llama.cpp pensadas para ARM no impidan el embed en x86_64; que las cinco fases posteriores a `setup` pasen en amd64. Ninguna está medida; la primera corrida de amd64 con el arreglo las confirma o las refuta, y FR-013 fija qué hacer si destapa otro defecto. La existencia del `vec0.so` musl horneado en la imagen amd64 ya no es una inferencia: `qmd real (016)` afirma que existe y que es musl, sin cadenas `GLIBC_` (`tests/docker-e2e-qmd.bats:705-706`), y ese test pasó en amd64 en la corrida 39069243972, la E1 de 041 (`specs/041-nightly-qmd-embed/tasks.md:399`). Verificado el 19-10-2026 contra `origin/main` (`0fc08a8`).
- **Sin hooks ni rama nueva**: `.specify/extensions.yml` tiene `hooks: {}` (no se ejecutó ningún hook) y la rama `042-qmd-sqlite-vec-x64` ya existía en su worktree propio, creada desde `origin/main` en `13cafc3`; el número 042 se fijó a mano (`--number 42`) porque, al crear el spec, el autonumerado daría 040, ya que `specs/` de esa base llegaba hasta 039 y 040 y 041 vivían en ramas. Verificado el 19-10-2026: `origin/main` avanzó a `0fc08a8` con tres merges seguidos (los PR #104 y #105, solo documentación, y el PR #108, que es el de 041), de modo que 041 ya está en `main` y 040 todavía no; la rama sigue en `13cafc3` y queda por rebasar sobre `origin/main` antes de implementar (T003 de `tasks.md`).
- **Revalidado tras el análisis del 18-10-2026**: el `/speckit-analyze` (hallazgo F1) acotó FR-005 y SC-003 (la lista de paquetes solo cuando la causa es el paquete), sumó a FR-013 la excepción de la build musl horneada ausente y dejó la decisión en las Clarifications; los 16 ítems siguen en [x].
