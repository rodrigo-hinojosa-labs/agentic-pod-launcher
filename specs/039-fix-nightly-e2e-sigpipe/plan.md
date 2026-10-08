# Implementation Plan: El nightly de docker-e2e ejecuta la suite de verdad

**Branch**: `039-fix-nightly-e2e-sigpipe` | **Date**: 2026-10-05 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/039-fix-nightly-e2e-sigpipe/spec.md`

## Summary

El job nocturno `docker-e2e` aborta a los 4 a 11 s en el paso `Verify deps + docker`: `docker info | head -10` bajo `set -euo pipefail` entrega SIGPIPE (141) y el job muere antes de ejecutar un solo e2e. Es la misma clase de defecto que la regla de `CLAUDE.md` sobre `PRODUCER | grep -q`, y lleva al menos cinco noches medidas sin que la red automática que exige la constitución vigile nada.

Enfoque (todo CI y tests, sin runtime): (1) reescribir el paso de verificación sin consumidor que cierre antes de tiempo, pidiendo a Docker solo lo que se quiere ver con `docker info --format` para que siga siendo ruidoso si el daemon falla; (2) reestructurar el paso de la suite para que pase por `tee`, cuente el TAP, imprima un resumen y termine en rojo si no se ejecutó ningún e2e (el verde vacío medido en M5); (3) un oráculo en la suite del host, `tests/ci-workflows.bats`, que extrae los `run:` reales del workflow y los ejecuta contra un `docker` falso realista, con autotest que demuestra que el arnés puede fallar, más un ratchet estático contra los consumidores que cierran antes en todos los workflows; (4) la primera corrida real por `workflow_dispatch` sobre la rama (amd64, cold) para clasificar los rojos que salgan, corrigiendo E1 y E3 de 031 (causa ya fundada) y aislando el resto con salto explícito, motivo y seguimiento; (5) entrada en `CHANGELOG.md`, sin bump de `VERSION`.

Las decisiones y sus mediciones están en [research.md](research.md); el resultado de la auditoría de los 14 pasos `run:` en su D5.

## Technical Context

**Language/Version**: Bash 3.2 a 5.x (la suite del host corre en ambos); YAML de GitHub Actions; `bats-core` (el CI fija v1.11.0, local 1.13.0).

**Primary Dependencies**: `yq` v4 (mikefarah) y `jq` para extraer el texto de los `run:` (ambos ya exigidos por la suite); `bats`; un `docker` falso escrito en bash dentro del propio test.

**Storage**: N/A.

**Testing**: `bats tests/ci-workflows.bats` (nuevo, host, sin Docker ni red) bajo el gate dual de bash; `DOCKER_E2E=1 bats tests/docker-e2e-askq-guard.bats` para E1 y E3; una corrida real de `workflow_dispatch` como evidencia (FR-014).

**Target Platform**: nightly en `ubuntu-latest` (amd64, Docker 28.0.4 y Compose v2.38.2 el 05-10-2026); la suite del host en macOS con bash 3.2 y ubuntu con bash 5.x (matriz de 025).

**Project Type**: infraestructura de CI y de tests; sin código de producción.

**Performance Goals**: el oráculo suma menos de 5 s a la suite del host; el nightly debe terminar dentro del tope vigente del job (30 min, subido solo si se mide un tiempo agotado, FR-016).

**Constraints**: FR-015 (no se toca `docker/`, `scripts/` ni `modules/`; sin permisos ni secretos nuevos; `contents: read` se conserva); no se rediseña la matriz de `test.yml` (solo cambian dos líneas); el comando exacto de CI de `shellcheck` no cambia; empujar a `.github/workflows/` exige el scope `workflow` (el token ya lo tiene).

**Scale/Scope**: 3 workflows con 14 pasos `run:`, 5 pipes reales de los que 4 tienen un consumidor que cierra antes; 48 e2e en 13 archivos.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.1).*

- [x] **I. Single Source of Truth** — N/A: no se agregan salidas derivadas de `agent.yml`; `--regenerate` no cambia. PASS.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — no se toca `docker/`, ni compose, ni capacidades. Las correcciones de E1 y E3 conservan `--user agent` en cada `docker compose run`. El workflow mantiene `permissions: contents: read`. PASS.
- [x] **III. Test-First, Host-Runnable** — es el corazón de la feature: el oráculo se escribe antes del arreglo y se demuestra rojo (autotest sobre el paso congelado con el defecto) y luego verde; la suite del host sigue sin necesitar Docker; los e2e siguen tras `DOCKER_E2E=1`; `shellcheck -S error` con el comando exacto de CI debe seguir en rc 0. El oráculo hace cumplir la parte del gate de calidad que dice que el e2e debe pasar para cambios en `docker/` o en el arranque, hoy sin vigilancia automática. PASS.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — N/A: no toca arranque, parches, instalación ni backups. La corrección de E1 respeta que el instalador es fail-silent: se arregla el arnés, no el instalador. PASS.
- [x] **V. Workspace-Is-the-Agent** — N/A: no toca `.state/` ni backups. Los stubs viven en directorios temporales de bats. PASS.
- [x] **VI. Reproducible, Pinned Dependencies** — sin pins nuevos; `bats` y `yq` ya están fijados en el workflow. `CHANGELOG.md` recibe entrada y **no se sube `VERSION`**: es CI y tests, sin cambio de runtime (precedente 019 y 025); se verifica a mano contra `origin/main` al implementar. PASS.

**Veredicto**: 6/6 PASS (I, IV y V N/A), sin violaciones. Complexity Tracking vacío.

## Project Structure

### Documentation (this feature)

```text
specs/039-fix-nightly-e2e-sigpipe/
├── plan.md              # Este archivo (/speckit-plan)
├── research.md          # Fase 0: decisiones D1-D10 y mediciones M1-M8
├── data-model.md        # Fase 1: corrida nocturna, rojo clasificado
├── quickstart.md        # Fase 1: cómo validar cada criterio de éxito
├── contracts/
│   ├── workflow-step-oracle.md    # arnés de extracción y ejecución, stub de docker
│   ├── suite-step.md              # paso de la suite: TAP, resumen, semántica de salida
│   └── e2e-classification.md      # formato del registro de rojos clasificados
├── checklists/requirements.md
└── tasks.md             # Fase 2 (/speckit-tasks; no lo crea este comando)
```

### Source Code (repository root)

```text
.github/workflows/
├── docker-e2e.yml       # paso de verificación sin pipe; paso de la suite con tee, resumen y guarda de verde vacío;
│                        # timeout-minutes solo si una corrida real mide un tiempo agotado (FR-016)
└── test.yml             # solo las dos líneas `| head -1` del paso "Verify deps + pin the bash target"

tests/
├── ci-workflows.bats                      # NUEVO: oráculo de ejecución + autotest del arnés + ratchet estático
├── fixtures/ci/                           # NUEVO
│   ├── step-verify-with-defect.sh         # el paso de da22a06 copiado verbatim (prueba de que el arnés puede fallar)
│   ├── tap-all-skip.tap  tap-empty.tap  tap-mixed.tap  tap-failing.tap
│   └── ratchet-bad.yml  ratchet-good.yml  # patrones prohibidos y pipes benignos para probar el detector
└── docker-e2e-askq-guard.bats             # E1 y E3: correcciones de arnés, acotadas al test

CHANGELOG.md                               # entrada; sin bump de VERSION
CLAUDE.md                                  # a mano: entrada de 039 (referencia al plan) y una línea de gotcha
```

**Structure Decision**: nada bajo `docker/`, `scripts/`, `modules/` ni `setup.sh` (FR-015, SC-008). Los asistentes del arnés (extraer un paso, armar el `PATH` de stubs, ejecutar) viven **dentro** de `tests/ci-workflows.bats` y no en `tests/helper.bash`: ese archivo lo cargan todos los tests y no hay razón para ampliar su superficie. Un solo archivo de tests con dos bloques (oráculo y ratchet) en vez de dos, porque comparten la extracción con `yq` y `jq`.

## Complexity Tracking

> Vacío: la Constitution Check no tiene violaciones que justificar.

## Phase 0: Outline & Research

Completa, salvo una medición con compuerta. [research.md](research.md) cierra (a) el método del oráculo, (b) la detección del verde vacío, (d) la auditoría de los `run:` y (e) la causa y el arreglo de E1 y E3, todo con mediciones M1 a M8. **(c)**, cuántos e2e fallan realmente, queda diferida: se mide por CI en la primera corrida real sobre la rama (necesita que el operador autorice el push), y localmente solo con el visto bueno del operador porque Docker Desktop está apagado y el Mac está cargado (D8). La diferida no bloquea el diseño: el spec ya fija qué hacer con cada rojo que salga (FR-011 a FR-013).

## Phase 1: Design & Contracts

- [data-model.md](data-model.md): las dos entidades del spec (corrida nocturna y rojo clasificado) con sus campos, reglas de validación y transiciones.
- [contracts/workflow-step-oracle.md](contracts/workflow-step-oracle.md): cómo se extrae y ejecuta un paso, el contrato del `docker` falso (incluido el renderizado de `--format` y el modo Docker caído) y las aserciones de cada caso.
- [contracts/suite-step.md](contracts/suite-step.md): el paso de la suite, con el resumen y la tabla de semántica de salida.
- [contracts/e2e-classification.md](contracts/e2e-classification.md): el formato del registro que exige SC-004.
- [quickstart.md](quickstart.md): los comandos para validar SC-001 a SC-009, incluida la mutación que reintroduce el defecto.
- **Agent context**: se actualiza **a mano** la entrada de 039 en `CLAUDE.md` con la referencia a este plan; el hook `speckit.agent-context.update` no se ejecuta porque reemplaza todo el bloque SPECKIT.

## Re-evaluación Constitution Check (post-diseño)

Sin cambios respecto de la verificación inicial: 6/6 PASS. El diseño no introduce nada bajo `docker/`, no agrega permisos ni dependencias, y el único archivo compartido que se toca fuera de `tests/` y `.github/` es `CHANGELOG.md` (más `CLAUDE.md`, que es guía operativa). Un riesgo declarado, no una violación: los nombres de campo de `docker info --format` se validan contra el stub y solo se confirman contra un Docker real en la corrida de evidencia (D3).
