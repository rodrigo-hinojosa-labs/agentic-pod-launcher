# Contrato: guardrail de versión qmd ↔ sqlite-vec

**Dónde**: `tests/qmd-sqlite-vec.bats` (host, sin Docker).

## Objetivo
Impedir que un bump de `qmd` cambie transitivamente la versión de `sqlite-vec` (y su fuente/typedefs) invalidando el shim de compilación musl en silencio. Patrón `wizard-prompt-test-touchpoints`: el cambio de pin rompe un test a propósito.

## Aserciones (MUST)
1. El pin de qmd conocido-bueno es `2.5.3` (leído del default del wizard / `agent.yml`).
2. El `SQLITE_VEC_VERSION` del `docker/Dockerfile` (ARG) es `0.1.9`.
3. El test asevera el **par** (qmd `2.5.3` ↔ sqlite-vec `0.1.9`). Si cualquiera cambia sin actualizar el otro y este contrato, el test falla con un mensaje que instruye re-verificar la compilación musl de sqlite-vec (R2/research).

## Fuentes de verdad (evitar duplicar pins — Principle VI)
- qmd: única fuente en `agent.yml vault.qmd.version` (+ default del wizard).
- sqlite-vec: única fuente en `SQLITE_VEC_VERSION` (ARG Dockerfile), plumbeado a build.args.
- El test lee de esas fuentes, no de literales duplicados.
