# Implementation Plan: El nightly de docker-e2e ejercita el embed real de qmd

**Branch**: `041-nightly-qmd-embed` | **Date**: 2026-10-15 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/041-nightly-qmd-embed/spec.md`

## Summary

El nightly ejecuta los 48 e2e desde 039, pero el test del qmd real pasa sin ejercer el embed. Esa fase vive tras `QMD_EMBED_E2E=1`, que el workflow no define, y el verde no lo avisa. Esta feature hace que el nightly ejecute el embed real, que una regresión lo deje en rojo con la fase nombrada, que una falla de red no se lea como regresión, y que cuando la fase no corra lo diga como un salto con motivo.

**Lo que la investigación cambió del punto de partida** (detalle en [research.md](research.md)):

1. El embed **probablemente falle en el runner amd64 por un defecto de producto**. El reemplazo de la extensión vectorial deja intacta, en silencio, la disposición x64: medido con la función real contra un prefijo falso (M7). Que bun instale la variante x64 y que esa extensión glibc no cargue en musl sigue siendo inferencia. Si E1 lo confirma, la fase queda apagada con el salto que nombra el defecto (FR-014) y el arreglo es una feature de producto aparte.
2. `qmd vsearch` también carga el **modelo de expansión, de 1,28 GB** (M3). Por eso la obtención baja dos modelos, unos 1,6 GB (decisión del operador del 15-10-2026).
3. Precargar los modelos funciona y conserva el mismo camino de código que producción: con el nombre esperado, `resolveModelFile` los usa sin red (M4).
4. qmd apaga el embed si recibe `CI` (M3), y llama.cpp se compila en el `postinstall`, es decir, en la fase A (M5).

**Enfoque, todo CI y tests, sin runtime:**

1. Un paso `fetch_models` corre `.github/scripts/fetch-qmd-models.sh`, que baja y verifica los dos modelos (tamaño y sha256 fijados en una tabla única) con reintentos acotados y un presupuesto de 480 s. El resultado pasa a la suite por `$GITHUB_ENV`.
2. La suite corre aunque falle la obtención (`if: !cancelled() && verify_deps`) y declara la puerta `QMD_EMBED_E2E: '1'`. El `run:` de los dos pasos de 039 no cambia.
3. La fase del embed sale de `qmd real (016)` a un test propio. Ese test salta con motivo antes de tocar Docker, siembra los modelos verificados, marca cada una de sus ocho fases, falla rápido cuando el setup ya registró su falla, comprueba la extensión vectorial sin depender de la arquitectura y verifica que qmd no baje modelos dentro del contenedor.
4. Un oráculo del host de 36 tests, sin Docker ni red, con 101 mutaciones: cada test tiene al menos una que demuestra que puede ponerse en rojo.
5. Evidencia real con compuertas (E1 a E4). Si E1 no llega a la última fase, un DOCKER_E2E local en arm64 es obligatorio antes del PR. Entrada en CHANGELOG y CLAUDE.md, sin bump de `VERSION`.

## Technical Context

**Language/Version**: Bash 3.2 a 5.x (la suite del host corre en ambos); POSIX `sh` para `vec0-libc.sh`, que corre con el busybox del contenedor; YAML de GitHub Actions; `bats-core` (1.11.0 en el nightly y en el brazo Linux de `test.yml`; el brazo macOS instala el de Homebrew; local 1.13.0). `test.yml` solo corre en PR y en `main`, así que la primera CI del oráculo es la del PR.

**Primary Dependencies**: `curl` y `sha256sum` o `shasum` en el script; `yq` v4 y `jq` en el oráculo (la CI usa yq v4.44.3 y el local v4.52.5); `python3` para el servidor HTTP local del oráculo; Docker con Compose solo en el e2e (`DOCKER_E2E=1`).

**Storage**: los modelos van a `$RUNNER_TEMP/qmd-models` (1.616.029.856 bytes) y se enlazan con hard link en el `.state` del workspace desechable del test. No hay cache entre noches (decisión del 14-10-2026).

**Testing**: `tests/qmd-embed-nightly.bats` (nuevo, host); `tests/docker-e2e-qmd.bats` (e2e, tras `DOCKER_E2E=1` y `QMD_EMBED_E2E=1`); `tests/ci-workflows.bats` de 039 sin cambios; corridas reales de `workflow_dispatch` como evidencia.

**Target Platform**: `ubuntu-latest` amd64 para el nightly; contenedor Alpine 3.24.1 con musl; host de desarrollo macOS arm64.

**Project Type**: infraestructura de CI y de tests, sin código de producción.

**Performance Goals**: la nocturna completa cabe en 30 minutos con al menos 5 de margen (FR-013); la obtención fallida cuesta 8 minutos como máximo (D4). La duración normal de la fase está estimada, no medida (D16).

**Constraints**: FR-018 (nada bajo `docker/`, `scripts/`, `modules/` ni `setup.sh`; sin secretos ni permisos; sin bump de `VERSION`); FR-019 (el `run:` de los dos pasos de 039 no cambia, vigilado por sha256); script y fixtures en ASCII; las enmiendas al oráculo de 040 se declaran (D15).

**Scale/Scope**: dos modelos de unos 1,6 GB en total; un test e2e nuevo (de 48 pasan a 49); 36 tests de host nuevos; de 3 a 4 corridas de evidencia con compuerta (E2 y E4 se excluyen), más el DOCKER_E2E local si E1 no llega a la última fase.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.1).*

- [x] **I. Single Source of Truth**: N/A. No hay salidas derivadas de `agent.yml` y `--regenerate` no cambia. La identidad de los modelos tiene una sola fuente, la tabla del script, con guards. PASS.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)**: no se toca `docker/`, ni compose, ni capacidades. Cada `docker compose exec` y `run` del test conserva `-u agent`. El workflow mantiene `permissions: contents: read` y no gana `secrets.`. PASS.
- [x] **III. Test-First, Host-Runnable**: el oráculo del host se escribe y se ve en rojo antes del script y del cambio en el workflow, y cada test tiene su mutación (quickstart §3). La suite del host sigue sin Docker ni red: el `curl` real solo habla con 127.0.0.1. El e2e sigue tras `DOCKER_E2E=1`. El script nuevo entra al gate de shellcheck (M11); `tests/fixtures` queda fuera de ese gate, como todo `tests/`. PASS.
- [x] **IV. Idempotent, Fail-Silent Lifecycle**: N/A. No toca arranque, parches, instalación ni backups. El script de CI falla de forma explícita por diseño: no es un paso del ciclo de vida del agente. PASS.
- [x] **V. Workspace-Is-the-Agent**: N/A. Solo se usan workspaces desechables del test; ningún `.state` real se lee ni se escribe. PASS.
- [x] **VI. Reproducible, Pinned Dependencies**: los dos modelos quedan fijados por tamaño y sha256 en una sola tabla (D5). `QMD_MODELS_QMD_VERSION` registra con qué versión de qmd se verificó la tabla: no es un pin nuevo de qmd, y el guard G1 impide que derive del pin real. `docs/qmd-upgrade-checklist.md` gana el paso. `CHANGELOG.md` recibe entrada y **no se sube `VERSION`**: es CI y tests (precedente de 019, 025, 039 y 040), y se verifica a mano contra `origin/main`. PASS.

**Veredicto**: 6/6 PASS (I, IV y V N/A), sin violaciones. Complexity Tracking vacío.

## Project Structure

### Documentation (this feature)

```text
specs/041-nightly-qmd-embed/
├── spec.md              # actualizado con los hechos de la investigación (Clarifications del 15-10-2026)
├── plan.md              # este archivo
├── research.md          # Fase 0: mediciones M1-M15 y decisiones D1-D18
├── data-model.md        # Fase 1: identidad de modelos, resultado de la obtención, interruptor, fases, noche
├── quickstart.md        # Fase 1: oráculos, 101 mutaciones, DOCKER_E2E local, evidencia E1-E4
├── contracts/
│   ├── fetch-models-script.md   # el script de obtención: entradas, algoritmo, salidas, invariantes
│   ├── workflow-delta.md        # el cambio en docker-e2e.yml, sobre main y combinado con 040
│   ├── embed-test.md            # el test 041, el asistente común y vec0-libc.sh
│   └── host-oracle.md           # los 36 tests del host y su arnés
├── checklists/requirements.md
└── tasks.md             # Fase 2 (/speckit-tasks; no lo crea este comando)
```

### Source Code (repository root)

```text
.github/
├── scripts/
│   └── fetch-qmd-models.sh            # NUEVO (100755): obtiene y verifica los dos modelos; tabla única
└── workflows/
    └── docker-e2e.yml                 # id verify_deps; paso fetch_models; if: y QMD_EMBED_E2E en la suite

tests/
├── qmd-embed-nightly.bats             # NUEVO: oráculo del host (W, F, V, K, G, P)
├── docker-e2e-qmd.bats                # asistente _qmd_real_ws; 016 sin Tier 2; test qmd real (041) nuevo
└── fixtures/qmd-e2e/                  # NUEVO
    ├── vec0-libc.sh                   # comprobación de libc de la extensión vectorial, POSIX
    └── fake-curl                      # curl falso del oráculo, con plan por llamada

docs/qmd-upgrade-checklist.md          # el paso de revisar la tabla de modelos y la receta nueva del DOCKER_E2E del embed
CHANGELOG.md                           # entrada; sin bump de VERSION
CLAUDE.md                              # a mano: entrada de 041 y la corrección de la frase de «Common gotchas»
```

**Structure Decision**: el script va en `.github/scripts/`, fuera de `scripts/` (FR-018) y dentro del gate de shellcheck, como el de 040. Los ejecutables de apoyo de los tests van en `tests/fixtures/qmd-e2e/`, como el `gh` falso de 040. El oráculo es un archivo nuevo y no una ampliación de `tests/ci-workflows.bats`: 039 queda intacto y la frontera entre features se ve en el árbol. `tests/helper.bash` no se toca.

## Complexity Tracking

> Vacío: la Constitution Check no tiene violaciones que justificar.

## Phase 0: Outline & Research

Completa. [research.md](research.md) resuelve todas las incógnitas del Technical Context:

- dónde y con qué nombre lee qmd los modelos (M3, M4);
- si un modelo precargado se usa sin red (M4);
- dónde se compila llama.cpp (M5);
- qué señales deja el setup (M6);
- qué hace el reemplazo de `sqlite-vec` con la disposición x64 (M7);
- la semántica de GitHub Actions en que se apoya el workflow (M9);
- lo que congela 040 (M10).

Dos resultados obligaron a actualizar el spec antes de diseñar, con la historia intacta:

- el supuesto «la búsqueda vectorial solo usa el modelo de embeddings» quedó refutado, y la decisión que lo reemplaza está en Clarifications, sesión del 15-10-2026;
- varias filas de «Estado de cada afirmación» pasaron de inferencia o supuesto a hecho verificado.

Queda **sin medir, a propósito**, todo lo que solo se puede medir en el runner: el costo real de la fase, el tiempo de la compilación, la velocidad de descarga y el disco libre. Lo mide E1, que es una compuerta (D14 y D16).

## Phase 1: Design & Contracts

- [data-model.md](data-model.md): identidad de un modelo, resultado de la obtención, interruptor de defecto y sus transiciones, fases del embed y cómo se ve cada resultado de la noche.
- [contracts/fetch-models-script.md](contracts/fetch-models-script.md): entradas, costuras validadas, algoritmo, salidas e invariantes del script.
- [contracts/workflow-delta.md](contracts/workflow-delta.md): el cambio exacto en el workflow, qué no puede cambiar y la forma combinada con 040.
- [contracts/embed-test.md](contracts/embed-test.md): el asistente común, el test 016 recortado, el test 041 con sus fases y `vec0-libc.sh`.
- [contracts/host-oracle.md](contracts/host-oracle.md): los 36 tests del host y su arnés.
- [quickstart.md](quickstart.md): oráculos, gate dual, 101 mutaciones, DOCKER_E2E local (obligatorio si E1 no llega a la última fase), E1 a E4 con compuertas, las tres noches posteriores al merge y los gates finales.
- **Contexto del agente**: se agrega **a mano** la entrada de 041 en `CLAUDE.md`. spec-kit 1.1.2 ya no trae la extensión de contexto de agente, y el script de este comando no modificó `CLAUDE.md`: su sha256 quedó idéntico antes y después.

## Re-evaluación Constitution Check (post-diseño)

Sin cambios: 6/6 PASS. El diseño no agrega nada bajo `docker/`, `scripts/`, `modules/` ni `setup.sh`, ni permisos ni secretos. Los únicos archivos compartidos que toca fuera de `tests/` y `.github/` son `CHANGELOG.md`, `CLAUDE.md` y dos ítems de `docs/qmd-upgrade-checklist.md`. Tras `/speckit-analyze` (16-10-2026), el asistente del e2e toma la versión de qmd de `qmd_pkg` en vez de repetir el literal: consolida un duplicado existente (Principio VI) sin tocar `scripts/`.

## Riesgos declarados

| Riesgo | Estado | Mitigación |
| --- | --- | --- |
| El embed falla en amd64 por el reemplazo de `sqlite-vec` | inferencia fuerte, con su núcleo medido (M7) | FR-014: se apaga con salto y defecto registrado; feature de producto aparte |
| El margen frente al tope queda bajo 5 min por la segunda compilación y la expansión en CPU | estimado (D16) | subir el tope y volver a medir (FR-013); compartir el prefijo compilado queda como mejora posterior medida (D8) |
| Las fases posteriores a `setup` no corren en CI si E1 cae en `setup` | previsto (M7) | DOCKER_E2E local en arm64 obligatorio antes del PR (FR-020, D14) |
| Un modelo cambia en origen | posible | sin reintento y con motivo propio en `fetch_models` (D4); se revisa la tabla |
| Un setup colgado sin línea de falla agota el tope | posible (D16) | salida anticipada por el log (D11); plazo del centinela recalibrado con la medición de E1 |
| Una falla de la CDN de HuggingFace | infraestructura | reintentos y presupuesto (D4); la noche queda roja en `fetch_models` y la suite corre igual |
| Las enmiendas al oráculo de 040 al rebasar | conocido (M10) | declaradas en contracts/workflow-delta.md §3 y en las Notes de `tasks.md` |
| La salida de `yq` cambia entre v4.44.3 y v4.52.5 y altera el sha256 de M13 | no medido | paridad de los tests W con yq v4.44.3 antes del gate |
