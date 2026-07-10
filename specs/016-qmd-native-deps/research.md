# Phase 0 Research: qmd deps nativas en Alpine (016)

**Fecha**: 2026-07-10 | **Método**: recon directo en ferrari + 2 workflows multi-agente (17 + 5 agentes) contra el código de qmd/node-llama-cpp y fuentes primarias (npm registry, GitHub issues/PRs). Verificación adversarial de la receta musl.

Las decisiones de mecanismo (Opción A — mantener Alpine, embed en alcance, DOCKER_E2E real) vienen fijadas por `/speckit-clarify` (ver `spec.md` § Clarifications). Este documento resuelve los unknowns técnicos de *cómo*.

---

## Decisión 1 — Hacer que `node-llama-cpp` (embed) compile y corra en Alpine musl aarch64

**Decision**: FACTIBLE sin cambiar el base OS. Receta:
1. Agregar al bloque apk del Dockerfile, **persistiendo en la imagen final** (el addon compila en runtime, no en un stage descartable): `build-base cmake git linux-headers libgomp`. Opcional `samurai` (binario `ninja`) para acelerar; `make` de build-base ya es un generador garantizado.
2. **No** agregar env var de selección de cmake: `apk add cmake` pone `cmake` en PATH → `node-llama-cpp` (`src/utils/cmake.ts::getCmakePath()`/`hasBuiltinCmake()`) lo resuelve vía `which cmake`, `getCmakePathArgs()` retorna `[]` (cmake-js usa el cmake del PATH) y `downloadCmakeIfNeeded()` early-return → **nunca** descarga el xpack cmake glibc (que no corre en musl). Agregar un guard `command -v cmake` en el wrapper para fallar-fuerte si falta.
3. Forzar build portable/reproducible aarch64 exportando en el env del wrapper qmd: `NODE_LLAMA_CPP_CMAKE_OPTION_GGML_NATIVE=OFF` y `NODE_LLAMA_CPP_CMAKE_OPTION_GGML_CPU_ARM_ARCH=armv8-a` (evita el fallo `-march=native` de CPU-probe). node-llama-cpp lee cualquier `NODE_LLAMA_CPP_CMAKE_OPTION_*` (config.ts `customCmakeOptionsEnvVarPrefix`).
4. Mitigar el hazard **runtime** `std::regex`/stack de musl (128KB pthread stack vs 2–10MB glibc → SIGSEGV en vocab-load/tokenización/grammar) con un shim `bigstack.so` (override `pthread_create` → stack 8MB; `dlsym(RTLD_NEXT)`), compilado en build (`gcc -shared -fPIC -o /opt/agent-admin/bigstack.so bigstack.c -ldl`) y activado con `LD_PRELOAD=/opt/agent-admin/bigstack.so` **solo** en el env del wrapper de embed (no global, para no afectar bun/tmux/otros).

**Rationale**: leído del source de node-llama-cpp: `cmake-js` es dependencia **regular** (no dev), así que el build lazy en runtime funciona en instalación de producción; `detectGlibc.ts` retorna false en Alpine y no existe `@node-llama-cpp/linux-arm64-musl` (solo el glibc `@node-llama-cpp/linux-arm64`) → el prebuilt se descarta y el build-from-source se fuerza automáticamente. llama.cpp compila/enlaza en musl desde el PR que guarda `execinfo.h`/`backtrace` tras `__GLIBC__` (merge 2024-08-01); node-llama-cpp 3.18.1 fija un release de llama.cpp de 2025 que lo incluye (inferencia, a re-confirmar en el tag exacto). `-Wl,-z,stack-size=N` **no** sirve (musl lee `PT_GNU_STACK` del ejecutable principal = `bun`, que no podemos relinkear); solo el `LD_PRELOAD` que override `pthread_create` arregla los stacks de worker-threads (referencia viva: `SamuelTallet/alpine-llama-cpp-server` bigstack.so 8MB). `openssl-dev` NO hace falta (el addon fuerza `LLAMA_CURL/LLAMA_HTTPLIB/LLAMA_OPENSSL=OFF`).

**Alternatives considered**:
- Multi-stage hornear el `.node`: **descartado** — el bind-mount `./.state:/home/agent` enmascara `/home/agent` y `bunx` reinstala en runtime; el artefacto horneado no se ve (verificado en el workflow de 17 agentes).
- Cambiar a base glibc (Opción B): descartado en clarify (enmienda de constitución + migración de privilegios) — queda como **fallback**.
- Embeddings remotos (Opción C): descartado en clarify (saca el vault del host) — queda como **fallback**.

**Open risks** (→ Constitution Check Principle III / DOCKER_E2E):
- El tokenizer del modelo real puede o no disparar el regex-overflow: **no verificado** hasta correr el modelo real → shipear `bigstack.so` proactivo (barato, posición fail-loud de 015).
- `cmake-js` 7.x vs 8.x según el tag 3.18.1: re-confirmar `NODE_LLAMA_CPP_CMAKE_OPTION_*` y la resolución PATH contra el tag exacto en implementación.
- **Build-time network requerido**: node-llama-cpp git-clona/descarga el release de llama.cpp + el modelo ~300MB en el primer build lazy; un pod offline no puede compilar → documentar el requisito de red.
- `node-llama-cpp` hardcodea `npm` (presente, 11.12.1); si un slimming futuro lo quita, el build runtime se rompe aun bajo bun.
- El PATH del wrapper debe incluir `/usr/bin` cuando bunx invoca node-llama-cpp (reusar el wrapper-PATH self-provisioning de 013/015).

---

## Decisión 2 — Estrategia tree-sitter: no compilar, controlar los scripts confiados

**Decision**: **No** compilar tree-sitter, **no** `--ignore-scripts` global, **no** `--omit=optional`. El conflicto "no puedo saltar scripts y a la vez compilar node-llama-cpp" **no existe** bajo bun (default-deny de lifecycle scripts). Cambiar `_qmd_run` (scripts/lib/qmd_index.sh:95-105, espejado a docker) de `bunx "$@"` a un **prefijo gestionado**:
- Generar `$(qmd_cache_root)/pkg/package.json` con `{dependencies:{"@tobilu/qmd": <VER>}, trustedDependencies:["better-sqlite3","node-llama-cpp"]}`.
- Correr `bun install` en ese cwd de forma **idempotente** (debounce por hash del package.json).
- Ejecutar `"$prefix/node_modules/.bin/qmd" "$@"` en vez de `bunx`.

**Rationale**: bun solo corre install-scripts de deps listadas en `trustedDependencies`. Confiando **solo** `better-sqlite3` y `node-llama-cpp`, sus builds nativos corren; los `tree-sitter-*` (`install: node-gyp-build`) quedan **sin ejecutar** (default-deny) → qmd usa el `.wasm` de `web-tree-sitter` en runtime (que qmd carga de todos modos). Esto resuelve el abort de tree-sitter **y** habilita node-llama-cpp con una sola pieza de control. `--omit=optional` se descarta porque dropearía `sqlite-vec-linux-arm64`, la optionalDependency **real** que sí se necesita para vectores.

**Alternatives considered**:
- Dejar compilar tree-sitter con el toolchain presente: funcionaría pero desperdicia tiempo de build en runtime para un binding que qmd no usa; y depende de que node-gyp compile 4 grammars.
- `bunx` con `--ignore-scripts`: bajo bun solo afecta scripts del root, irrelevante para deps → no cambia nada.

**Open risks**: `sqlite-vec` / `better-sqlite3` en musl arm64 — confirmar en implementación que compilan/cargan (better-sqlite3 fallback node-gyp con el toolchain ya presente; sqlite-vec puede tener prebuilt o requerir build). El drift-guard bats debe fijar `trustedDependencies` exactamente `[better-sqlite3, node-llama-cpp]` sin ningún `tree-sitter-*`.

---

## Decisión 3 — DOCKER_E2E des-stubeado, en tiers

**Decision**: des-stubear = borrar del patch python3 de `tests/docker-e2e-qmd.bats` la inyección del bind-mount `- ./bin/bunx:/usr/local/bin/bunx:ro` (y el bloque que escribe `DEST/bin/bunx`), conservando el stub de `claude` (sleep). La imagen ya trae `bunx→bun` real (Dockerfile:126). Toolchain gateado por build-arg `QMD_NATIVE_TOOLCHAIN` (propagado en `docker-compose.yml.tpl` build.args — Principle VI). Tres tiers:
- **Fase A (Tier 1, detector de build)**: `bunx @tobilu/qmd@2.5.3 --help` → RC=0 (paga install+compile nativo; no baja modelo).
- **Fase B (Tier 1, update léxico)**: seed de vault mínimo (3–5 `.md` con frontmatter válido) → `heartbeatctl qmd-reindex` → assert `last_status=ok` + índice ≥1 doc (confirmar el subcomando de conteo desde `qmd --help` en el contenedor, no asumir).
- **Fase C (Tier 2, embed real, gate `QMD_EMBED_E2E=1`)**: con cache-modelo montado, `qmd embed` → assert rc0 + `*.gguf` presente + una consulta semántica ≥1 hit. `skip` si el gate no está seteado.
- **Test de detección (RED)**: segunda imagen con `--build-arg QMD_NATIVE_TOOLCHAIN=0` → Fase A debe dar RC≠0 **y** grep del stderr redactado por causa real (`exited with 1` / `node-gyp` / `cmake`), para no confundir un RED por red-caída con detección. Cubre SC-003 en ambos sentidos.
- **Cache-modelo**: `QMD_E2E_MODEL_CACHE` (default `$HOME/.cache/agentic-qmd-e2e/models`) bind-mounteado al `models/` de qmd; persistir solo `models/`, no el build.

**Rationale**: el stub de bunx fue exactamente lo que ocultó BUG 4; ejercer qmd real es el objetivo (SC-003). El split en tiers mantiene el inner-loop rápido (Fase A/B sin modelo) y aísla el costo del modelo ~300MB tras un gate opt-in. El toggle del ARG da el poder de detección bidireccional sin una imagen artificial.

**Alternatives considered**: smoke acotado (build+carga sin index) — descartado en clarify (poca detección). Un solo test monolítico con modelo — descartado (lento, frágil en CI sin red).

**Open risks**: red requerida para el primer build/embed; tiempo del embed (compile llama.cpp + modelo). Reusar el TMPDIR host-backed de 015 (US3) para el build (evitar ENOSPC en `/tmp`).

---

## Veredicto adversarial (2 verificadores sobre la receta musl)

`holds_in_musl = true`, **confianza media**. La ingeniería musl es sólida (SamuelTallet como referencia viva + verificación del source `cmake.ts` + PR de llama.cpp), así que **Opción A es viable y es el camino primario**. PERO ninguna fuente demuestra el **conjunto completo**: node-llama-cpp compilado-desde-fuente, **cargado por bun**, corriendo `qmd embed` con modelo real en Alpine musl aarch64. El eje **bun + N-API** tiene historial de segfaults en dispose/exit — el modo de falla más probable, e **independiente de musl** (ocurriría también en glibc).

**Implicaciones para el plan**:
1. **DOCKER_E2E no es formalidad, es la prueba que decide**: debe correr `update` y `embed` end-to-end con el modelo real, ejercer dispose/salida del proceso, y verificar en el log que compiló con el `cmake` de apk (ausencia del fallback xpack/glibc) y que no hubo SIGSEGV/`regex_error`.
2. **Mantener el fallback B/C armado** con criterio de disparo explícito: si el addon crashea bajo bun por N-API (no por musl), o si el shim no cubre el hilo del tokenizer.
3. Presupuestar red-en-runtime + disco en `.state` para el primer embed (clone+compile+modelo), reusando la mitigación TMPDIR host-backed de 015.

## Criterio de disparo del fallback (B base glibc / C embeddings remotos)

Se activa el fallback si, tras la receta de Opción A, el gate confirmatorio (DOCKER_E2E `QMD_EMBED_E2E` + ferrari) muestra **cualquiera** de:
- `qmd embed` crashea reproduciblemente bajo bun por N-API (dispose/exit) pese al `bigstack.so`.
- el `bigstack.so` no cubre el hilo real del tokenizer (SIGSEGV persistente).
- el build de llama.cpp no enlaza en musl aarch64 pese al toolchain.

En ese caso, la decisión de mecanismo se re-abre (nuevo `/speckit-clarify` acotado) hacia B o C. `update` (léxico) queda operativo de todos modos por la Decisión 2.
