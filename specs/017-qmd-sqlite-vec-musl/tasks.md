---
description: "Task list — 017-qmd-sqlite-vec-musl"
---

# Tasks: qmd sqlite-vec en Alpine musl (cierre del embed semántico)

**Input**: Design documents from `/specs/017-qmd-sqlite-vec-musl/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: OBLIGATORIOS. Principle III (constitución): los cambios de comportamiento son test-first; bats host antes de implementar.

**Organization**: por historia (US1 P1, US2 P2, US3 P3). MVP = US1.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: paralelizable (archivo distinto, sin dependencias pendientes)
- Rutas exactas incluidas.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: fijar la versión y su integridad antes de compilar.

- [X] T001 Calcular el `sha256` de `sqlite-vec-0.1.9-amalgamation.tar.gz` (release oficial asg017) y registrarlo como constante en `docker/scripts/build-sqlite-vec.sh` y en `specs/017-qmd-sqlite-vec-musl/contracts/sqlite-vec-build.md`
- [X] T002 Añadir `ARG SQLITE_VEC_VERSION=0.1.9` en `docker/Dockerfile` y plumbearlo vía compose `build.args` en `docker-compose.yml.tpl` (y en `setup.sh` donde se ensamblan los build args, junto a `QMD_NATIVE_TOOLCHAIN`)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: ninguno adicional — el toolchain de build (016) y `_qmd_ensure_prefix` (016) ya existen. Esta fase queda vacía a propósito; US1 arranca directo.

---

## Phase 3: User Story 1 — Embed semántico en musl (Priority: P1) 🎯 MVP

**Goal**: `qmd embed`/`vsearch` funcionan en la imagen Alpine musl reemplazando el prebuilt glibc de sqlite-vec por uno compilado para musl.

**Independent Test**: en la imagen musl real, `collection add → update → embed → vsearch` cierra con "Embedded N chunks" y un hit semántico (ver quickstart.md).

### Tests (test-first) — US1

- [X] T003 [P] [US1] Test host de la lógica de swap en `tests/qmd-sqlite-vec.bats`: con mocks de la ruta del artefacto horneado (`QMD_VEC0_MUSL_SO`) y del probe de libc — (a) musl + artefacto presente → copia el `.so` al prefijo; (b) glibc (artefacto ausente) → no-op silencioso; (c) musl + artefacto ausente → warn redactado + continúa (no falla, no crashea). Aserciones con `grep -q`/`[ ]`, nunca `[[ ]]`/`!`-negado intermedio (quirk bats del proyecto).

### Implementation — US1

- [X] T004 [US1] Crear `docker/scripts/build-sqlite-vec.sh`: descargar la amalgamación (URL de versión fija por `SQLITE_VEC_VERSION`), verificar `sha256` (fail-loud), `apk add --no-cache sqlite-dev`, compilar `cc -O2 -fPIC -shared -Du_int8_t=uint8_t -Du_int16_t=uint16_t -Du_int64_t=uint64_t -I<sqlite3ext dir> -I. sqlite-vec.c -o vec0.so -lm`, verificar que es musl (`! strings vec0.so | grep -q GLIBC_`), instalar en `/opt/agent-admin/sqlite-vec/vec0.so`, limpiar (`apk del sqlite-dev` + fuente). `set -euo pipefail`, guard `BASH_SOURCE`.
- [X] T005 [US1] En `docker/Dockerfile`, dentro del bloque gateado por `QMD_NATIVE_TOOLCHAIN=1`: `COPY scripts/build-sqlite-vec.sh /opt/agent-admin/scripts/build-sqlite-vec.sh` + `RUN` que lo ejecuta con `SQLITE_VEC_VERSION`; si `QMD_NATIVE_TOOLCHAIN!=1`, no hornear (degrada en runtime).
- [X] T006 [US1] Implementar el swap en `scripts/lib/qmd_index.sh::_qmd_ensure_prefix` (fuente): tras confirmar el binario de qmd, si existe `${QMD_VEC0_MUSL_SO:-/opt/agent-admin/sqlite-vec/vec0.so}` **y** la libc es musl (probe inline `[ -e /lib/ld-musl-aarch64.so.1 ]`, sin depender de `_libc_variant`), `cp -f` sobre `node_modules/sqlite-vec-linux-arm64/vec0.so` + `_qmd_log`; si musl sin artefacto → `_qmd_log` warn redactado + continuar; en glibc → no-op. Idempotente.
- [X] T007 [US1] Espejar la lib a docker: actualizar `docker/scripts/lib/qmd_index.sh` (vía `mirror_catalog_to_docker`/`./setup.sh --regenerate`, o mirror manual si no está trackeado) para que el `docker build` (context `./docker`) copie la versión con el swap.

**Checkpoint US1**: la suite host pasa T003; el swap está en la fuente y espejado. (La validación real del embed es US2 vía DOCKER_E2E.)

---

## Phase 4: User Story 2 — DOCKER_E2E des-stubeado (Priority: P2)

**Goal**: el gate ejerce `embed`+`vsearch` reales y detecta RED sin el toolchain; cierra el defecto de la Fase A.

**Independent Test**: `DOCKER_E2E=1 QMD_EMBED_E2E=1 bats tests/docker-e2e-qmd.bats` verde; build con `QMD_NATIVE_TOOLCHAIN=0` → RED detectado.

### Tests / cambios de test — US2

- [X] T008 [US2] Arreglar la Fase A en `tests/docker-e2e-qmd.bats`: reemplazar `bunx @tobilu/qmd@... --help` por el path de producción (`_qmd_run`/prefijo gestionado); la aserción de sanidad debe discriminar por carga real del binding, no por `--help`.
- [X] T009 [US2] Extender el tier `QMD_EMBED_E2E=1` en `tests/docker-e2e-qmd.bats` para correr el pipeline real `collection add → update → embed → vsearch <consulta semántica>` dentro del container (`--entrypoint bash -u agent`) y aseverar con `grep -q`: "Embedded" (no "sqlite-vec extension is unavailable") + el doc esperado en `vsearch`. Cachear el modelo gguf entre corridas si es posible.
- [X] T010 [US2] Añadir/ajustar la detección RED en `tests/docker-e2e-qmd.bats`: build con `--build-arg QMD_NATIVE_TOOLCHAIN=0` → embed no disponible; aserción RED con patrón `if echo "$out" | grep -q 'Embedded'; then false; fi` (sin `!`-negado intermedio).

**Checkpoint US2**: el gate DOCKER_E2E cierra el embed real y discrimina el RED.

---

## Phase 5: User Story 3 — Guardrail de versión (Priority: P3)

**Goal**: un bump de qmd no puede cambiar sqlite-vec en silencio.

**Independent Test**: `bats tests/qmd-sqlite-vec.bats` verde; falla si el par qmd/sqlite-vec cambia sin actualizar el contrato.

### Tests — US3

- [X] T011 [US3] Añadir en `tests/qmd-sqlite-vec.bats` el guardrail de versión: leer el pin de qmd (default del wizard / `agent.yml vault.qmd.version`) y `SQLITE_VEC_VERSION` del `docker/Dockerfile`; aseverar el par conocido-bueno (qmd `2.5.3` ↔ sqlite-vec `0.1.9`) con mensaje que instruya re-verificar la compilación musl si cambia. Leer de las fuentes de verdad, no de literales duplicados.

---

## Phase 6: Polish & Cross-Cutting

- [X] T012 [P] Bump `VERSION` 0.10.0 → 0.11.0
- [X] T013 [P] Añadir entrada 017 en `CHANGELOG.md` (cierre del embed semántico en docker/musl; sqlite-vec musl; des-stub e2e; guardrail)
- [X] T014 Correr la suite host completa (`bats tests/`) verde + `shellcheck -S error` sobre `scripts/lib/qmd_index.sh`, `docker/scripts/lib/qmd_index.sh`, `docker/scripts/build-sqlite-vec.sh`
- [X] T015 Correr `DOCKER_E2E=1 QMD_EMBED_E2E=1 bats tests/docker-e2e-qmd.bats` (gate del fix) + verificación manual del binario musl (quickstart §3)
- [X] T016 Marcar tasks completadas [X] y actualizar el marcador SPECKIT de `CLAUDE.md` (017 → estado implementado/gates)

---

## Dependencies & Order

- **Setup (T001-T002)** antes de todo lo de build.
- **US1 (T003-T007)** es el MVP: T003 (test) antes de T006 (impl del swap); T004→T005 (build script antes de invocarlo en Dockerfile); T006→T007 (fuente antes de espejo). T004/T005 (docker build) y T006 (lib) son mayormente independientes salvo el espejo T007.
- **US2 (T008-T010)** depende de US1 (necesita el artefacto horneado y el swap para que el embed real pase; el RED T010 no).
- **US3 (T011)** independiente de US1/US2 (solo lee versiones); puede ir en paralelo.
- **Polish (T012-T016)** al final; T014/T015 son los gates.

## Parallel Opportunities

- T001 [P] con la lectura de contratos.
- T003 [P] (test host US1) mientras se redacta el build script T004.
- T011 [US3] [P] en paralelo con US1/US2 (archivo/tarea independiente).
- T012 [P] y T013 [P] (VERSION y CHANGELOG, archivos distintos).

## Implementation Strategy (MVP-first)

1. **MVP = US1**: compilar+hornear+swap → el embed carga en musl. Es el 80% del valor.
2. **US2** convierte el MVP en garantía reproducible (gate real).
3. **US3** protege el pin a futuro.
4. Polish + gates → PR → (tras merge) un solo despliegue completo a mclaren+ferrari.
