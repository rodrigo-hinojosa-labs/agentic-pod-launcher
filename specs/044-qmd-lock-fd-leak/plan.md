# Implementation Plan: Las secciones con lock de qmd sueltan `.reindex.lock` en cuanto terminan

**Branch**: `044-qmd-lock-fd-leak` | **Date**: 2026-11-06 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/044-qmd-lock-fd-leak/spec.md`

## Summary

El `timeout` de BusyBox deja un vigilante que conserva el descriptor 9, y con él `.reindex.lock`, de 0,9 a 1 s después de cada sección del setup y del reindex. La Fase 0 lo midió con las secciones reales del producto (`research.md` M1): 10 sondeos de 100 ms en BusyBox 1.36.1 y 1.37.0, y 0 con el `timeout` de GNU (M3).

El arreglo (D1, revisado por el análisis del 07-11-2026) es una línea por sección: `flock -u 9 2>/dev/null || true` como último paso del subshell, después de la llamada a la función de la sección. Como el lock pertenece a la descripción de archivo abierta que comparten todos los descendientes, esto cubre a todo lo que corre bajo el lock (FR-006) sin enumerarlo y sin tocar `_qmd_run`.

La primera versión del plan usaba un `trap ... EXIT`, y el análisis la descartó. Ese `trap` se dispara también ante un SIGTERM al subshell y suelta el lock con un qmd hijo todavía vivo. Hoy, en cambio, ese hijo lo retiene y lo protege (`research.md` M8).

Medido con las secciones reales:
- el `trap` dio 0 sondeos en las dos versiones de BusyBox, con GNU y en el host (M4);
- la variante final dio 0 sondeos en el host, en bash 3.2 y 5.x (M9), y T025 la confirma en BusyBox;
- el perdedor sigue saltándose con rc 0.

La Fase 0 también refutó un efecto que el spec suponía: el vigilante deja la salida estándar en `/dev/null`, así que las sustituciones de comando no esperan (M2).

El oráculo del host son 10 pruebas nuevas, que el Mac puede correr sin Docker y en los dos bash. Usan un `timeout` falso con la forma de BusyBox y un `flock` en perl donde el host no lo trae (D2). La integración se confirma con el DOCKER_E2E local y una corrida manual de CI, como en 043.

## Technical Context

**Language/Version**: bash, el de la imagen en docker y el del host en local; el oráculo corre en bash 3.2.57 y 5.x. perl solo en una fixture de prueba.

**Primary Dependencies**: `flock` de util-linux (imagen: `docker/Dockerfile:45`) y `timeout` de BusyBox 1.37.0 (imagen `alpine:3.24.1`). En el modo local de Linux, el de GNU coreutils.

**Storage**: no aplica; no cambia ningún archivo persistente (`data-model.md`).

**Testing**: bats en el host (`tests/qmd-lock-release.bats`, 10 pruebas, fixtures en `tests/fixtures/qmd-lock/`), mutaciones en los dos bash y en una pata Linux, contenedores desechables para el BusyBox real, DOCKER_E2E de `tests/docker-e2e-qmd.bats` y una corrida manual de `docker-e2e.yml`.

**Target Platform**: el contenedor del agente (Alpine 3.24.1, aarch64 en la flota y amd64 en el runner) y el modo local (Linux con glibc).

**Project Type**: CLI y librería de shell (el launcher y su código horneado).

**Performance Goals**: el lock libre en el primer sondeo de 100 ms tras cada sección (SC-001); hoy hacen falta 10.

**Constraints**:
- la semántica del lock no cambia (`flock -n`, el perdedor rc 0);
- el tope, las salidas y los códigos de `_qmd_run` no cambian;
- el código está horneado, así que exige DOCKER_E2E;
- el ayudante de 043 no se toca.

**Scale/Scope**: una línea de código y una de comentario en cada una de dos funciones de `scripts/lib/qmd_index.sh`, 10 pruebas y 2 fixtures; además documentos, CHANGELOG y `VERSION` 0.30.0.

No queda ningún NEEDS CLARIFICATION: el spec se clarificó el 06-11-2026, y la Fase 0 resolvió lo inferido (M2 y M3).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principio | Evaluación | Resultado |
| --- | --- | --- |
| I. Single Source of Truth (`agent.yml`) | No cambia `agent.yml`, plantillas ni archivos derivados | N/A |
| II. Least-Privilege Container Model | El cambio está en `scripts/lib/qmd_index.sh`, que se hornea en la imagen. No agrega capacidades, mounts ni sockets, y no toca `docker-compose.yml.tpl` ni el `Dockerfile` (FR-012). Revisión de privilegios: nada nuevo corre como root. `flock -u` lo ejecuta el mismo proceso que ya tomó el lock, como `agent` | PASS |
| III. Test-First, Host-Runnable | Las 10 pruebas nuevas corren en el host sin Docker y en los dos bash (D2). Las seis que caen se ven en ROJO contra el código actual antes del VERDE; las cuatro que nacen verdes las ponen a prueba el control M0 y las mutaciones. El DOCKER_E2E queda detrás de `DOCKER_E2E=1`. La línea nueva pasa `shellcheck -S error` | PASS |
| IV. Idempotent, Fail-Silent Lifecycle | El `flock -u 9` no puede fallar hacia afuera (`2>/dev/null \|\| true`). El perdedor sigue saliendo con rc 0, la degradación sin `flock` no cambia y una sección que muere por una señal deja el lock como hoy (M8) | PASS |
| V. Workspace-Is-the-Agent | No toca `.state/`, los backups ni el restore | N/A |
| VI. Reproducible, Pinned Dependencies | No agrega dependencias de runtime: perl solo en una fixture de prueba, y el arnés de `tests/ci-workflows.bats` ya lo usa. CHANGELOG y `VERSION` 0.30.0, verificada contra `origin/main` | PASS |

**Re-check after Phase 1**: sin cambios. El diseño (`contracts/lock-release.md`) mantiene una línea por sección y ningún archivo bajo `docker/`. Complexity Tracking queda vacío.

**Re-check tras el análisis (07-11-2026)**: el cambio de D1, del `trap` al `flock -u 9` final, no toca ningún principio. Mejora el IV: una señal al subshell ya no puede soltar el lock mientras trabaja un hijo.

## Project Structure

### Documentation (this feature)

```text
specs/044-qmd-lock-fd-leak/
├── spec.md              # clarificado el 06-11-2026
├── plan.md              # este archivo
├── research.md          # Fase 0: M1 a M7, D1 a D5; análisis: M8 y M9
├── data-model.md        # la descripción del lock, el vigilante y las transiciones
├── quickstart.md        # V1 a V7
├── contracts/
│   ├── lock-release.md      # C1 a C3: la forma de cada sección y lo que garantiza
│   ├── host-oracle.md       # L1 a L8, G1, G2; mutaciones M1 a M9
│   └── evidence-protocol.md # etapas 0 a 13, con sus COMPUERTAS
├── checklists/
│   └── requirements.md  # 16 de 16
└── tasks.md             # /speckit-tasks (07-11-2026): 36 tareas
```

### Source Code (repository root)

```text
scripts/lib/qmd_index.sh            # una línea en qmd_setup_if_needed y otra en qmd_reindex
tests/qmd-lock-release.bats         # nuevo: 10 pruebas
tests/fixtures/qmd-lock/timeout     # nuevo: timeout falso con la forma de BusyBox
tests/fixtures/qmd-lock/flock       # nuevo: flock(2) en perl para hosts sin util-linux
CHANGELOG.md                        # ### Fixed
VERSION                             # 0.29.0 -> 0.30.0
CLAUDE.md                           # la viñeta de 043 en Common gotchas y el bloque de 044 (a mano)
docs/qmd-upgrade-checklist.md       # solo si nombra la contención
```

**Structure Decision**: el arreglo vive donde vive el defecto, en las dos secciones de `scripts/lib/qmd_index.sh`. La imagen lo recibe por la copia que ya existe (`docker/Dockerfile:265`), sin cambio en `docker/`. Las pruebas siguen el molde del repo: un archivo bats nuevo por contrato y fixtures en `tests/fixtures/<tema>/`. No se tocan `tests/docker-e2e-qmd.bats` ni `tests/helper-qmd-e2e.bash` (FR-011).

## Phase 0: Outline & Research

Hecha: `research.md`.

- **Mediciones**:
  - M1: el defecto con las secciones reales en BusyBox 1.36.1 y 1.37.0;
  - M2: el vigilante suelta 0, 1 y 2 y conserva el 9;
  - M3: GNU no deja vigilante;
  - M4: las dos variantes del arreglo;
  - M5: el oráculo del host sin Docker;
  - M6: el inventario de procesos bajo el lock;
  - M7: ninguna otra sección del repo tiene el defecto;
  - M8 (análisis): un `trap ... EXIT` suelta el lock ante un SIGTERM al subshell con el hijo vivo;
  - M9 (análisis): el `flock -u 9` final da 0 sondeos con las secciones reales.
- **Decisiones**:
  - D1: el `flock -u 9` como último paso de cada sección (revisado por el análisis; el `trap` queda como alternativa descartada);
  - D2: las fixtures del oráculo;
  - D3: la evidencia en contenedor es local y registrada;
  - D4: versión y documentos;
  - D5: el hallazgo lateral queda fuera.

## Phase 1: Design & Contracts

Hecha:
- `data-model.md`;
- `contracts/lock-release.md`, `contracts/host-oracle.md` y `contracts/evidence-protocol.md`;
- `quickstart.md`.

El bloque de la feature en `CLAUDE.md` se escribe a mano durante la implementación (spec-kit 1.1.2 no lo toca, y `.specify/extensions.yml` tiene `hooks: {}`).

## Complexity Tracking

Sin violaciones de la constitución que justificar.
