# Specification Quality Checklist: El nightly de docker-e2e ejercita el embed real de qmd

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-10-14
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

- **Histórico (14-10-2026): tres marcadores abiertos a propósito; se resolvieron en el clarify del 14, 15 y 16-10-2026 (hoy el spec tiene 0 marcadores y los tres ítems están en [x]).** FR-008 (política ante una falla de descarga del modelo), FR-010 (si el modelo se conserva entre noches) y FR-013 (si el tope de 30 minutos se mide primero o se sube de antemano) llevan `[NEEDS CLARIFICATION]` porque el operador pidió resolverlos en `/speckit-clarify` y no en el momento de especificar. Por eso quedan sin marcar tres ítems que dependen de ellos: «No markers remain», «testable and unambiguous» y «clear acceptance criteria» (las políticas de FR-008, FR-010 y FR-013 definen el comportamiento esperado de US3 y US4). Se revalidan al cerrar la aclaración. El resto de los requisitos es verificable tal como está escrito.
- **Sobre «technology-agnostic» y «no implementation details»**: igual que 025 y 039, esta es una feature de infraestructura de CI, cuyo DOMINIO son GitHub Actions, bash, bats, Docker y qmd. Nombrarlos es describir el problema y sus objetos, no filtrar implementación incidental. El «cómo» queda fuera de los requisitos: FR-007 fija un resultado (la falla del modelo se atribuye por separado) y FR-016 fija qué debe vigilar el host, y el plan elige el mecanismo. Los «stakeholders» son los mantenedores del launcher.
- **Hechos verificados el 14-10-2026** (leídos o ejecutados, no recordados): el workflow sin `QMD_EMBED_E2E`; el test (líneas 669, 677, 687-719); `qmd_index.sh:130`, `:132` y `:207-208`; la aserción de la línea 690 ejecutada contra un archivo ausente (imprime `MUSL`); los metadatos de `sqlite-vec@0.1.9` en el registro de npm (paquetes `linux-x64` y `linux-arm64`, sin campo `libc`); la corrida 37873376103 (suite de 885,4 s, `qmd real (016)` de 288,5 s); las cinco nocturnas verdes de 13 min 11 s a 15 min 29 s; la diferencia de `docker-e2e.yml` entre `origin/main` y la rama 040 (+102/-1). La tabla «Estado de cada afirmación» del spec separa lo verificado de lo inferido y de lo no medido.
- **Inferencias que NO son hechos (histórico, 14-10-2026; la tercera quedó refutada el 15-10-2026: `vsearch` también carga el modelo de expansión de 1,28 GB, `store.js:3783` y `llm.js:1062`, y por eso se precargan dos modelos; las otras dos siguen sin medir hasta la primera corrida E1)**: que en amd64 se instale la variante x64 y el reemplazo de la extensión no ocurra; que la extensión x64 glibc no cargue en musl; que la búsqueda vectorial solo use el modelo de embeddings. Ninguna está medida; la primera corrida manual sobre la rama las confirma o las refuta, y el spec no promete «nightly verde» sino que el embed se ejecuta o se declara saltado, y que un rojo nombra su fase.
- **Cuatro puntos de la descripción original se corrigieron al verificar**: (1) las variables de compilación de llama.cpp las fija `scripts/lib/qmd_index.sh:207-208`, no el Dockerfile; (2) agregar una variable al `env:` del paso de la suite NO rompe los oráculos de 039 (S6 solo exige `DOCKER_E2E=1` y S1-S5 ejecutan el `run:`); solo cambiar el `run:` obligaría a enmendarlos (FR-019); (3) la duración del nightly medida es de 13 min 11 s a 15 min 29 s, no «14 a 16»; (4) hallazgo nuevo que no estaba en la descripción: el reemplazo de `sqlite-vec` y la aserción de la línea 690 solo conocen la ruta arm64.
- **Sin hooks ni rama**: `.specify/extensions.yml` tiene `hooks: {}` (no se ejecutó ningún hook de contexto de agente) y no se creó ni cambió de rama, por instrucción del operador.
