# Feature Specification: Hermetic CI test suite + bash 3.2/5.x matrix

**Feature Branch**: `025-hermetic-ci-suite`

**Created**: 2026-07-26

**Status**: Draft

**Input**: El job `tests` de CI está rojo en cada commit de `main` porque la suite bats no es hermética (depende de que el host tenga `claude`/`bun`/`qmd`); y el CI corre en un solo bash, dejando viva la clase de defecto que 023 midió (mismo commit verde en una máquina, rojo en otra según la versión de bash).

## Contexto

El repositorio tiene tres workflows de GitHub Actions: `shellcheck` (verde), `tests` (`bats tests/` en `ubuntu-latest`) y `docker-e2e (nightly)`. El job `tests` está **rojo en cada commit de `main`** desde hace tiempo, con exactamente **16 `not ok`** medidos el 2026-07-26. La causa raíz medida NO es "el runner no tiene `claude`" a secas: `shellcheck` está verde, la suite completa sí ejecuta (~4 min), y de los 16 rojos solo 14 tocan `claude`. La causa común es que **la suite no es hermética**: pasa en cualquier máquina de desarrollo o en el host del agente (mclaren) porque ahí existen `claude`/`bun`/el prefijo qmd, y falla en un runner limpio. Un rojo permanente convierte el CI en ruido: nadie distingue una regresión real de la falla ambiental de fondo.

Segundo problema, ligado: el CI corre bats en una sola versión de bash (5.x de ubuntu). La feature 023 demostró que el mismo commit da verde bajo bash 3.2 y rojo bajo bash 5.2+ (o viceversa) sin que nada en el repo lo declare. La suite host de los devs corre en bash 3.2.57 (macOS de stock); el CI en 5.x. Nada garantiza que ambas se ejerciten en cada cambio.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - El mantenedor confía en el semáforo del CI (Priority: P1)

Como mantenedor del launcher, quiero que el job `tests` sea **verde en un runner limpio** (sin `claude`/`bun`/qmd instalados), para que un rojo signifique una regresión real y no la falla ambiental de fondo.

**Why this priority**: Es el valor central. Con el CI rojo permanente, el semáforo no informa nada: una PR que rompe algo se ve igual que una sana. Sellar la suite recupera la señal. Es también prerequisito del brazo 3.2 (US2): no tiene sentido correr en dos bash si la suite falla por el entorno en cualquiera.

**Independent Test**: Correr la suite completa con un PATH podado que NO contenga `claude` ni `bun` (simulando el runner limpio) y verificar que los 16 tests hoy rojos pasan, sin tocar código de producción.

**Acceptance Scenarios**:

1. **Given** un entorno sin `claude` en PATH, **When** se corre `bats tests/`, **Then** los 14 tests de Clase 1 (modo local `--regenerate`) pasan porque el setup les provee un `claude` falso resoluble.
2. **Given** un entorno sin `bun`/prefijo qmd, **When** se corre `bats tests/`, **Then** los 2 tests de Clase 2 (`qmd-reindex-cmd.bats` 685/686) pasan por la causa medida en Fase 0, no por suerte del entorno.
3. **Given** un host de desarrollo que SÍ tiene `claude` instalado, **When** se corre la suite, **Then** los mismos tests usan el stub forzado (no el `claude` real del host) → el resultado es idéntico dev vs CI.
4. **Given** un `agent.yml` real, **When** se corre `./setup.sh --regenerate` fuera de los tests, **Then** la salida es byte-idéntica a la de antes de esta feature (cero cambio de comportamiento en producción).

---

### User Story 2 - El CI caza regresiones específicas de versión de bash (Priority: P2)

Como mantenedor, quiero que el job `tests` corra la suite bajo **bash 3.2 y bash 5.x** en cada push/PR, para que un defecto que solo aparece en una versión (como el `&` de 023) sea cazado por el CI y no meses después en producción.

**Why this priority**: Formaliza en CI la deuda estructural que 023 midió. Sin esto, el mismo commit puede seguir dando verde en una máquina y rojo en otra sin que nada lo declare. Depende de US1 (la suite debe ser hermética antes de correrla en dos bash).

**Independent Test**: Ver en la corrida de CI dos brazos (`bash 3.2` y `bash 5.x`), cada uno imprimiendo su `bash --version`, ambos verdes; y comprobar que el brazo 3.2 realmente ejecuta 3.2 (la versión impresa empieza con `3.2`).

**Acceptance Scenarios**:

1. **Given** un push a `main` o una PR, **When** corre el workflow `tests`, **Then** aparecen dos ejecuciones de la suite, una por versión de bash, cada una con su `bash --version` visible en el log.
2. **Given** un test legítimamente incompatible con bash 3.2, **When** corre el brazo 3.2, **Then** ese test se **skipea explícitamente con una razón nombrada** (nunca en silencio) y el skip es visible en el conteo.
3. **Given** un commit que introduce una construcción que diverge entre 3.2 y 5.x (p.ej. la clase del bug de 023), **When** corre el CI, **Then** el brazo afectado se pone rojo y lo delata antes del merge.

---

### User Story 3 - Un contribuyente reproduce el CI localmente (Priority: P3)

Como contribuyente sin `claude`/`bun` instalados, quiero poder correr `bats tests/` y que pase, para no necesitar todo el entorno del agente solo para validar un cambio.

**Why this priority**: Baja la barrera de entrada y es el mismo oráculo que sella US1 (PATH podado). Valor incremental sobre US1; no bloquea el semáforo.

**Independent Test**: En una máquina limpia (o con PATH podado), `bats tests/` termina verde sin instalar Claude Code ni bun.

**Acceptance Scenarios**:

1. **Given** una checkout limpia sin dependencias del agente, **When** se instalan solo las deps declaradas del CI (`bats`, `yq`, `jq`, `git`, `tmux`, `age`) y se corre la suite, **Then** pasa completa.

---

### Edge Cases

- **El host del dev tiene `claude`**: el seam debe **forzar** el stub, no depender de "haya o no haya" claude en PATH. Si el test usara el `claude` real cuando existe, el comportamiento diverge dev vs CI y el bug reaparece enmascarado.
- **Un test incompatible con bash 3.2 por razón legítima**: se skipea con nombre propio y motivo declarado; jamás se oculta el rojo bajando la aserción.
- **Causa de 685/686 no confirmada**: la spec fija el OUTCOME (pasan en runner limpio), no el fix. Si Fase 0 mide que la causa es distinta a la hipótesis, se documenta y se corrige la causa real.
- **Un test nuevo que dependa del host se agrega después**: idealmente el propio CI (runner limpio) lo caza; se registra si hace falta un guard adicional.
- **docker-e2e (nightly) `exit 141` (SIGPIPE)**: known-issue **fuera de alcance**; no se toca en esta feature.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: La suite `bats tests/` MUST pasar en un runner sin `claude` en PATH (los 14 tests de Clase 1 dejan de fallar).
- **FR-002**: La suite MUST pasar en un runner sin `bun`/prefijo qmd (los 2 tests de Clase 2 dejan de fallar), por la causa medida en Fase 0.
- **FR-003**: Los tests que ejercen `./setup.sh --regenerate` en modo local MUST proveer un `claude` falso, ejecutable y resoluble a un path absoluto, vía un seam **compartido y reutilizable** entre `deployment-mode.bats` y los tests de vault/qmd afectados.
- **FR-004**: El seam MUST forzar el uso del stub independientemente de si el host tiene `claude` (comportamiento idéntico dev vs CI) y MUST NOT filtrar un path específico del dev-box.
- **FR-005**: CERO cambio de comportamiento en producción. `resolve_claude_bin`, `setup.sh` y `qmd_index.sh` NO se modifican en su runtime; la salida de un `--regenerate` real sobre un `agent.yml` real MUST quedar byte-idéntica.
- **FR-006**: El job `tests` de CI MUST correr la suite bajo bash 3.2 Y bash 5.x en cada push a `main` y en cada PR.
- **FR-007**: Cada brazo del CI MUST imprimir su `bash --version` en el log (la lección de observabilidad de 023).
- **FR-008**: Cualquier test skipeado en un brazo de bash MUST skipearse **explícitamente con una razón nombrada**, y el conteo de skips MUST ser visible; ningún rojo se oculta bajando aserciones.
- **FR-009**: La causa exacta de los tests 685/686 MUST medirse antes de diseñar el fix; el fix ataca la causa medida, no una supuesta.
- **FR-010**: El workflow `docker-e2e` y el árbol `docker/` MUST quedar sin cambios por esta feature (el SIGPIPE nocturno es follow-up aparte).
- **FR-011**: Debe existir evidencia (mutación/observabilidad) de que el seam es **load-bearing**: revertirlo vuelve a poner rojos exactamente los tests hoy rojos en un runner limpio.

### Key Entities

- **Seam de `claude` falso**: binario stub ejecutable, determinista, sembrado por un helper compartido; su path absoluto se inyecta en `deployment.claude_cli` del `agent.yml` de prueba. No es código de producción.
- **Brazo de matriz de bash**: una ejecución del job `tests` parametrizada por versión de bash (3.2, 5.x), cada una con su intérprete verificado por `bash --version`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: El job `tests` queda **verde** en `main` y en PRs sobre un runner limpio (0 de los 16 tests antes rojos falla).
- **SC-002**: El mismo commit produce el mismo veredicto pass/fail en una máquina de desarrollo (con `claude`/`bun`) y en un runner limpio de CI — sin divergencia por entorno.
- **SC-003**: El job `tests` corre en bash 3.2 y bash 5.x; ambos brazos imprimen su versión y quedan verdes (salvo skips nombrados explícitamente), y el brazo 3.2 ejecuta verificablemente 3.2.
- **SC-004**: Un `./setup.sh --regenerate` real sobre un `agent.yml` real produce salida byte-idéntica antes y después de la feature (sin cambio de producción).
- **SC-005**: Revertir el seam de hermeticidad vuelve a poner en rojo exactamente los tests antes rojos en un runner limpio (el fix es load-bearing, no cosmético).
- **SC-006**: El workflow `docker-e2e` y el árbol `docker/` quedan sin modificar por esta feature.

## Assumptions

- Runners hospedados por GitHub. `ubuntu-latest` provee bash 5.x; un runner macOS provee bash 3.2.57 de stock (el mismo bash de la suite host de los devs). **El método concreto para el brazo 3.2 (runner macOS vs compilar 3.2 en ubuntu vs contenedor) se resuelve MIDIENDO en Fase 0**, no se prejuzga aquí; solo se asume que existe un método viable de costo razonable.
- Los 14 tests de Clase 1 fallan únicamente por la resolución de `claude` (medido con `gh run view --log-failed` el 2026-07-26); los 2 de Clase 2 requieren root-cause de Fase 0.
- El bug está en los tests y en la configuración de CI, no en el código de producción; por eso el arreglo no toca runtime.
- El seam sigue el patrón ya presente en el repo (feature 019 `install_qmd_stub` en `tests/helper.bash`; feature 021 seam `SETUP_SYSTEMD_DIR`).

## Out of Scope

- El `exit 141` (SIGPIPE) del workflow `docker-e2e (nightly)` — follow-up separado, docker-only.
- Cualquier cambio al comportamiento de `resolve_claude_bin`, `setup.sh` o `qmd_index.sh` en producción.
- Cambios al modo docker o al árbol `docker/`.
