# Specification Quality Checklist: El nightly de docker-e2e ejecuta la suite de verdad

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-10-05
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

- **Sobre "technology-agnostic" y "no implementation details"**: igual que 025, esta es una feature de infraestructura de CI, cuyo DOMINIO son GitHub Actions, bash, bats y Docker. Nombrarlos es describir el problema y sus objetos, no filtrar implementación incidental. El "cómo" queda fuera de los requisitos: FR-007 fija el resultado (un oráculo que falle si el paso aborta con salida extensa, sin poder pasar en vacío) y deja al plan elegir entre ejecutar el paso real con un `docker` sustituto o auditar los `run:` de forma estática. Los "stakeholders" son los mantenedores del launcher, no usuarios finales.
- **Decisiones resueltas en `/speckit-clarify` (05-10-2026, 2 preguntas, ambas con la opción recomendada)**: (a) ante los rojos reales se corrige lo ya diagnosticado (E1 y E3 de 031) y se aísla el resto con salto explícito y seguimiento (FR-012); (b) si la suite no cabe en los 30 minutos del job, el primer remedio es subir el tope y volver a medir, y dividir en jobs paralelos solo con evidencia de que no basta (FR-016, SC-009). El spec sigue sin prometer "nightly verde": exige que ningún rojo quede sin clasificar ni escondido.
- **Hechos verificados el 05-10-2026** (no recordados): los cinco runs rojos y sus commits (`gh run list`), `exit 141` en todos, duración del job de 4 a 11 s, la causa en el log del run 37197340169 (10 líneas de `docker info` y el error 2 ms después), 48 tests en 13 archivos, `contents: read`, y los 4 candidatos `| head` de la búsqueda preliminar. La fecha en que el nightly empezó a fallar NO está medida (025 ya lo daba rojo el 26-07-2026), y que los e2e solo se hayan corrido en arm64 es una inferencia ("hasta donde consta en el repo").
- **Hook opcional no ejecutado a propósito**: `speckit.agent-context.update` (after_specify) reemplaza todo el bloque SPECKIT de `CLAUDE.md` por 3 líneas; el contexto de agente se agrega a mano.
