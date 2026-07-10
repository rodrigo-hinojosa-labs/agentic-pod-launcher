---
description: "Task list — 016 qmd native deps en Alpine (fix root-cause BUG 4)"
---

# Tasks: qmd deps nativas en Alpine (fix root-cause de BUG 4)

**Input**: Design documents from `specs/016-qmd-native-deps/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md (todos presentes)

**Tests**: obligatorios (Principle III — test-first, host-runnable). Los `bats` host van ANTES de la implementación; el DOCKER_E2E des-stubeado valida el runtime real.

**Organization**: por user story. Mecanismo fijado (clarify): Opción A — mantener Alpine + embed en alcance + DOCKER_E2E real. Riesgo residual (bun/N-API + embed real en musl) se resuelve en el gate; fallback B/C armado (research.md).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: paralelizable (archivos distintos, sin dependencias pendientes)
- **[Story]**: US1–US5 (fases de user story); Setup/Foundational/Polish sin label

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: preparar archivos de test y baseline.

- [X] T001 Verificar baseline verde antes de tocar: `bats tests/` y `shellcheck -S error setup.sh scripts/lib/*.sh scripts/*.sh` pasan en la rama `016-qmd-native-deps`
- [X] T002 [P] Crear el skeleton del test host `tests/qmd-invocation.bats` (cabecera + `load_lib qmd_index` con guard `BASH_SOURCE`, sin casos aún)
- [X] T003 [P] Crear el skeleton del test host `tests/qmd-version-guard.bats` (cabecera + carga del pin desde `agent.yml`/render, sin casos aún)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: el wrapper por prefijo, el toolchain de imagen y el des-stubeo del e2e — prerequisitos de US1 y US2. **Ninguna user story puede completarse sin esto.**

**Tests primero (rojo):**

- [X] T004 [P] Test (rojo) en `tests/qmd-invocation.bats`: `_qmd_run` genera `$(qmd_cache_root)/pkg/package.json` con `trustedDependencies` == `["better-sqlite3","node-llama-cpp"]` exactamente y SIN ningún `tree-sitter-*` [contracts/qmd-invocation.md]
- [X] T005 [P] Test (rojo) en `tests/qmd-invocation.bats`: `_qmd_run` NO contiene `bunx "$@"` y ejecuta `"$prefix/node_modules/.bin/qmd"`
- [X] T006 [P] Test (rojo) en `tests/qmd-invocation.bats`: idempotencia — con el sentinel `.installed-hash` sin cambios, `bun install` NO se re-ejecuta (guard por sha256, no mtime — Principle IV)

**Implementación (verde):**

- [X] T007 Implementar en `scripts/lib/qmd_index.sh::_qmd_run` (L95-105): generar el `package.json` del prefijo, `bun install` idempotente (guard sha256 → `.installed-hash`), invocar `"$prefix/node_modules/.bin/qmd" "$@"` en vez de `bunx`; conservar el TMPDIR host-backed de 015 (US3) [contracts/qmd-invocation.md]
- [X] T008 Espejar los cambios a `docker/scripts/lib/qmd_index.sh` (`setup.sh::mirror_catalog_to_docker`) y confirmar su línea `COPY` en `docker/Dockerfile` (paridad de mirror — FR-011)
- [X] T009 Implementar el toolchain gateado en `docker/Dockerfile` (bloque apk L27-47): `ARG QMD_NATIVE_TOOLCHAIN=1` + `RUN if [ "$QMD_NATIVE_TOOLCHAIN" = "1" ]; then apk add --no-cache build-base cmake git linux-headers libgomp; fi` (sin `openssl-dev`) [contracts/dockerfile-toolchain.md]
- [X] T010 Propagar `QMD_NATIVE_TOOLCHAIN` (default 1) en `modules/docker-compose.yml.tpl` → `build.args` (Principle VI: plumbed, no hardcode-only)
- [ ] T011 [P] Test host (rojo→verde) en `tests/render.bats` o `tests/docker-compose.bats`: el compose renderizado pasa `build.args.QMD_NATIVE_TOOLCHAIN` y el Dockerfile contiene el bloque apk bajo el ARG
- [X] T012 Des-stubear `bunx` en `tests/docker-e2e-qmd.bats`: borrar del patch python3 (L100-112) la inyección `- ./bin/bunx:/usr/local/bin/bunx:ro` y el bloque que escribe `DEST/bin/bunx` (L85-97); conservar el stub `claude` (sleep) y la aserción `bunx→bun` (L165-167) [contracts/docker-e2e-tiers.md]

**Checkpoint**: wrapper por prefijo + toolchain + e2e des-stubeado listos; US1 y US2 pueden implementarse.

---

## Phase 3: User Story 1 — qmd `update`/reindex completa en docker (Priority: P1) 🎯 MVP

**Goal**: el reindex léxico deja de abortar por `tree-sitter`; el índice se construye.

**Independent Test**: DOCKER_E2E Fase B — vault mínimo → `qmd-reindex` → `last_status=ok` + índice ≥1 doc.

- [X] T013 [US1] Confirmar en `scripts/lib/qmd_index.sh` que el path de `update` usa el prefijo (T007) y NO exporta `LD_PRELOAD` (eso es solo de embed); env de update mínimo (PATH con `/usr/bin`)
- [X] T014 [US1] DOCKER_E2E Fase A (build-detector) en `tests/docker-e2e-qmd.bats`: `docker compose run ... 'bunx @tobilu/qmd@2.5.3 --help'` → RC=0 (compila node-llama-cpp/better-sqlite3 real; sin modelo) [contracts/docker-e2e-tiers.md]
- [X] T015 [US1] DOCKER_E2E Fase B (update léxico) en `tests/docker-e2e-qmd.bats`: seed de 3–5 `.md` con frontmatter en `DEST/.state/.vault` → `heartbeatctl qmd-reindex` → assert `jq -r .last_status == ok` + índice ≥1 doc (confirmar el subcomando de conteo desde `qmd --help` en el contenedor)
- [X] T016 [P] [US1] Test host (drift-guard) en `tests/qmd-invocation.bats`: el path de `update` no referencia ningún binding nativo `tree-sitter-*` (camino WASM/regex)

**Checkpoint**: US1 entregable — el RAG léxico funciona en docker. MVP alcanzado.

---

## Phase 4: User Story 2 — qmd `embed` (semántico) opera en docker (Priority: P1)

**Goal**: `node-llama-cpp` compila y corre; `qmd embed` genera vectores consultables.

**Independent Test**: DOCKER_E2E Fase C (gate `QMD_EMBED_E2E`) — `qmd embed` rc0 + `*.gguf` + consulta semántica ≥1 hit.

**Tests primero (rojo):**

- [X] T017 [P] [US2] Test (rojo) en `tests/qmd-invocation.bats`: el path de `embed` exporta `NODE_LLAMA_CPP_CMAKE_OPTION_GGML_NATIVE=OFF`, `NODE_LLAMA_CPP_CMAKE_OPTION_GGML_CPU_ARM_ARCH=armv8-a` y `LD_PRELOAD=/opt/agent-admin/bigstack.so`, y que `LD_PRELOAD` NO es global (no aparece en el path de update)
- [X] T018 [P] [US2] DECIDIDO durante impl: NO agregar guard `command -v cmake` fail-loud en runtime — daría falso positivo en modo local glibc con prebuilt (donde cmake no hace falta). La verificación de que el build usó el `cmake` de apk (no el xpack glibc) se hace en el DOCKER_E2E (T023, log check).

**Implementación (verde):**

- [X] T019 [US2] Crear `docker/bigstack.c`: override `pthread_create` → si `attr==NULL`, stack 8MB via `pthread_attr_setstacksize`; delegar con `dlsym(RTLD_NEXT)` [research.md Decisión 1]
- [X] T020 [US2] En `docker/Dockerfile`: `COPY docker/bigstack.c` + `RUN gcc -shared -fPIC -o /opt/agent-admin/bigstack.so bigstack.c -ldl` (dentro del gate `QMD_NATIVE_TOOLCHAIN`, requiere el toolchain)
- [X] T021 [US2] En `scripts/lib/qmd_index.sh` (+ espejo docker): el path de `embed` exporta las 3 env vars (GGML_NATIVE/ARM_ARCH en el build + LD_PRELOAD en el run) SOLO para embed (sin guard cmake runtime — ver T018) [contracts/qmd-invocation.md]
- [X] T022 [US2] Re-espejar `docker/scripts/lib/qmd_index.sh` y confirmar `COPY` (paridad mirror)
- [X] T023 [US2] DOCKER_E2E Fase C (embed real, gate `QMD_EMBED_E2E=1`) en `tests/docker-e2e-qmd.bats`: montar `QMD_E2E_MODEL_CACHE` → `qmd embed` → assert rc0 + `*.gguf` presente + consulta semántica ≥1 hit; `skip` si el gate no está; verificar en el log que compiló con el cmake de apk (sin fallback xpack) y sin SIGSEGV/`regex_error` [contracts/docker-e2e-tiers.md]

**Checkpoint**: US2 entregable — el RAG semántico funciona en docker (sujeto al gate confirmatorio).

---

## Phase 5: User Story 3 — DOCKER_E2E con poder de detección (Priority: P2)

**Goal**: el gate detecta el fallo (falla sin fix, pasa con fix) y aísla el costo del modelo.

**Independent Test**: reconstruir con `--build-arg QMD_NATIVE_TOOLCHAIN=0` → Fase A falla con causa real; con `=1` pasa.

- [X] T024 [US3] Test de detección RED en `tests/docker-e2e-qmd.bats`: 2ª imagen `docker compose build --build-arg QMD_NATIVE_TOOLCHAIN=0` → Fase A RC≠0 **y** grep del stderr redactado por causa real (`exited with 1`/`node-gyp`/`cmake`) — cubre SC-003 en ambos sentidos
- [X] T025 [US3] Implementar el model-cache: `QMD_E2E_MODEL_CACHE` (default `$HOME/.cache/agentic-qmd-e2e/models`, fuera de `TMP_TEST_DIR`) bind-mounteado al `models/` de qmd vía el patch python3; persistir solo `models/`
- [X] T026 [P] [US3] Actualizar la cabecera de `tests/docker-e2e-qmd.bats` (L21-24): reemplazar la nota "bunx is stubbed … NOT exercised" por la descripción del flujo real + los tiers; pre-crear `DEST/.state` antes de todo `compose up/run` (gotcha macOS)

**Checkpoint**: US3 entregable — el gate ya no puede ocultar un fallo de runtime.

---

## Phase 6: User Story 4 — Guardrail de versión de qmd (Priority: P2)

**Goal**: subir `vault.qmd.version` sin re-verificar rompe un test.

**Independent Test**: cambiar el pin sin actualizar el test → el test falla.

- [X] T027 [US4] Test en `tests/qmd-version-guard.bats`: asevera que la cadena por defecto/rendereada de `vault.qmd.version` es `2.5.3` (patrón `wizard-prompt-test-touchpoints`); un cambio sin actualizar el test rompe el test [contracts/qmd-version-guardrail.md]
- [X] T028 [US4] Crear el checklist pre-bump `docs/qmd-upgrade-checklist.md` (o sección en el contrato): verificar clasificación de deps de los grammars, presencia del `.wasm`, vigencia de la receta node-llama-cpp y cobertura de prebuilt musl antes de bumpear

**Checkpoint**: US4 entregable — el pin no se sube en silencio.

---

## Phase 7: User Story 5 — Prerequisito de toolchain en modo local (Priority: P3)

**Goal**: en un host local sin compilador, el prerequisito se documenta/detecta antes de un fallo opaco.

**Independent Test**: en un host local sin `gcc`, doctor/healthcheck o la doc advierte del requisito.

- [X] T029 [US5] Documentar el prerequisito de toolchain (gcc/g++/make/cmake) para modo local con qmd en `NEXT_STEPS`/`docs/` y en el bootstrap local (`modules/local-bootstrap.sh.tpl`): mensaje accionable
- [ ] T030 [P] [US5] (opcional) Agregar una verificación en el doctor/healthcheck local que advierta (WARN, no FAIL) si falta el toolchain cuando qmd está habilitado

**Checkpoint**: US5 entregable — el fallo local deja de ser opaco.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [X] T031 [P] Actualizar `VERSION` 0.9.0 → 0.10.0
- [X] T032 [P] Agregar entrada en `CHANGELOG.md` (### Fixed/Changed): toolchain + wrapper prefijo + bigstack + e2e des-stubeado (Principle VI)
- [X] T033 [P] Documentar en `CLAUDE.md` (Commands) y `quickstart.md`: `QMD_EMBED_E2E`, `QMD_E2E_MODEL_CACHE`, y el requisito de red build-time
- [X] T034 Correr la suite completa: `bats tests/` verde + `shellcheck -S error` limpio; shellcheck del bootstrap renderizado
- [ ] T035 Correr `DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats` (Tier 1: build + update + RED) en un host con Docker; registrar resultado

---

## Phase 9: Gap descubierto durante impl (MCP path)

- [X] T036 [US2] **El MCP server de qmd (`.mcp.json`) invocaba `bunx @tobilu/qmd@<ver> mcp` DIRECTO, sin pasar por `_qmd_run`** → en Alpine musl repetía BUG 4 (tree-sitter abort) y Claude no podía buscar. **RESUELTO (extender 016, decisión del usuario 2026-07-10):**
  - Refactor `qmd_index.sh`: extraído `_qmd_ensure_prefix` (compartido) + nueva `qmd_mcp_exec` (server de larga duración: SIN timeout, `exec qmd mcp` con `LD_PRELOAD=bigstack` porque el server embebe queries → mismo hazard musl que `embed`).
  - Wrapper docker image-baked `docker/scripts/qmd-mcp` (COPY+chmod en Dockerfile) + plantilla local `modules/local-qmd-mcp.sh.tpl` → `<ws>/scripts/local/agent-qmd-mcp.sh` (rendered en setup.sh; exporta PATH + `QMD_CACHE_HOME` para que el prefix coincida con el reindex writer — el `.mcp.json` env solo trae `XDG_CACHE_HOME`).
  - `mcp-json.tpl`: `command` = `{{QMD_MCP_COMMAND}}` (pre-computado por modo en setup.sh, patrón `QMD_MCP_ENV`; el render engine no anida `{{#if}}`), `args: []`. Registrado en `schema.bats::known_external`.
  - Tests: `qmd-invocation.bats` (qmd_mcp_exec desde el prefix + bigstack, no bunx), `mcp-json.bats` (command docker + local, no bunx), `scaffold.bats` (wizard→command docker). DOCKER_E2E Tier 2: el wrapper arranca sin firmas BUG-4.

## Phase 10: Revisión adversarial post-impl (workflow 15 agentes, 2026-07-10)

Fixes aplicados sobre el diff host-side tras la revisión (6 CONFIRMED → 4 defectos, 2 PLAUSIBLE aplicados como endurecimiento, 2 REFUTED):

- [X] T037 [US4] **[CONFIRMED, la regresión que yo introduje]** `_qmd_run` movió el build nativo dentro de un `bun install >/dev/null 2>&1`, perdiendo el error real (cmake/gcc/node-llama-cpp) → el reindex solo veía "No such file or directory". Fix: capturar `bun install` a scratch host-backed; si el build falla y el binario queda ausente, emitir el error redactado por `_qmd_log` y `return 1` (evita que el `exec` posterior sobrescriba el diagnóstico); si sobrevive un binario viejo, degradar a él. Espejado a `_qmd_setup_locked` (first-boot). `scripts/lib/qmd_index.sh`.
- [X] T038 **[CONFIRMED]** `docker/bigstack.c` estaba untracked → el `COPY` (fuera del gate ARG) abortaba el build de imagen en cualquier clone limpio. Fix: `git add docker/bigstack.c` (es fuente, NO se genera por `mirror_catalog_to_docker`; a diferencia de `docker/scripts/lib/*.sh` mirroreados).
- [X] T039 **[CONFIRMED]** Assertion muerta `!`-negada en `tests/qmd-invocation.bats:54` (el guard "no bunx" nunca fallaba). Fix: reordenar para que la negada sea la última. Memoria [[bats-intermediate-double-bracket-quirk]] ampliada al caso `!`-pipe.
- [X] T040 **[CONFIRMED]** DOCKER_E2E SC-003 RED unsound: misma assertion muerta (línea 333) + carryover del cache de bun en `.state` entre GREEN y RED. Fix: `if grep -q RC=0; then false; fi` (sound bajo set -e) + `export HOME=$(mktemp -d)` en el `qr` RED para forzar build from-scratch. `tests/docker-e2e-qmd.bats`.
- [X] T041 [US2] **[PLAUSIBLE → aplicado]** Un solo `QMD_CMD_TIMEOUT` acotaba build+runtime. Fix: `QMD_INSTALL_TIMEOUT` separado (default 3600s; `0`=sin cota) solo para el `bun install`, para que un compile largo en musl no caiga en loop retry-timeout. Documentado en `contracts/qmd-invocation.md`.
- [X] T042 [US2] **[PLAUSIBLE → aplicado]** `bigstack.c` solo agrandaba `attr==NULL`. Fix: cubrir también `attr` no-NULL con stacksize < 8MB (caso OpenMP/libgomp musl 128KB) vía `memcpy` del attr, preservando callers que ya piden ≥8MB. `docker/bigstack.c`.
- [X] T043 [US4] Nuevo test `install failure surfaces the real build error, not a missing-binary symptom` en `tests/qmd-invocation.bats` (stub `bun` que falla sin producir binario → `_qmd_run` retorna no-cero y el log contiene la señal del build, no "No such file"). Suite host 950 verde.

REFUTED (no accionados): data-race en la init perezosa del `static real` (idempotente, ventana no alcanzable) y `dlsym(RTLD_NEXT)` sin check NULL (path no alcanzable en el target).

## Dependencies & Execution Order

- **Setup (Ph1)** → **Foundational (Ph2)** → user stories.
- **US1 (Ph3)** y **US2 (Ph4)** dependen de Foundational (wrapper prefijo + toolchain + des-stubeo). US2 no depende estrictamente de US1, pero comparten el build nativo del prefijo.
- **US3 (Ph5)** depende del e2e des-stubeado (Ph2) y de los tiers de US1/US2.
- **US4 (Ph6)** y **US5 (Ph7)** son independientes (pueden ir en paralelo tras Setup).
- **Polish (Ph8)** al final.

## Parallel Opportunities

- Setup: T002, T003 en paralelo.
- Foundational: los tests T004–T006 en paralelo; T011 en paralelo con la impl de Dockerfile.
- US2: T017, T018 (tests) en paralelo; T019 (bigstack.c) en paralelo con los tests.
- US4 y US5 en paralelo entre sí y con US1/US2 (archivos distintos).
- Polish: T031–T033 en paralelo.

## Implementation Strategy

- **MVP = US1** (Ph1→Ph2→Ph3): restaura el RAG léxico en docker (reindex `ok`). Entregable e independientemente testeable por la Fase B del e2e.
- **Incremento 2 = US2** (embed): el RAG semántico. Sujeto al gate confirmatorio (Fase C + ferrari); si el embed en musl falla reproduciblemente bajo bun, disparar el fallback B/C (research.md) sin perder US1.
- **Incrementos 3–5 = US3/US4/US5**: poder de detección, guardrail, prerequisito local.
- Gate final: DOCKER_E2E des-stubeado (Tier 1 obligatorio; Tier 2 con `QMD_EMBED_E2E`) + confirmatorio ferrari.
