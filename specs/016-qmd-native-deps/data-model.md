# Data Model: qmd deps nativas en Alpine (016)

Esta feature es un fix de infraestructura de build; no hay entidades de dominio. Las "entidades" son objetos de configuración y build que el diseño introduce/modifica.

## 1. Toolchain de imagen (build)

- **Ubicación**: `docker/Dockerfile` (bloque apk, L27-47).
- **Contenido**: `build-base cmake git linux-headers libgomp` (opcional `samurai`). Persisten en la imagen final.
- **Gate**: build-arg `QMD_NATIVE_TOOLCHAIN` (default `1`); `RUN if [ "$QMD_NATIVE_TOOLCHAIN" = 1 ]; then apk add --no-cache ...; fi`.
- **Fuente del valor**: `modules/docker-compose.yml.tpl` → `build.args` (Principle VI: plumbed, no hardcode-only). El default `1` en el Dockerfile permite build directo; el `0` lo usa el test de detección RED.
- **Versión**: gobernada por el pin del base `alpine:3.24.1` (sin pin duplicado nuevo — Principle VI).

## 2. Prefijo de instalación de qmd (runtime)

- **Ubicación**: `$(qmd_cache_root)/pkg/` (bajo `.state/.cache/qmd`, feature 013).
- **`package.json` generado**:
  ```json
  {
    "dependencies": { "@tobilu/qmd": "<vault.qmd.version>" },
    "trustedDependencies": ["better-sqlite3", "node-llama-cpp"]
  }
  ```
- **Regla de identidad/idempotencia**: `bun install` corre solo si el hash del `package.json` cambió (debounce). El binario resultante se invoca como `"$prefix/node_modules/.bin/qmd"` (reemplaza `bunx @tobilu/qmd@<ver>`).
- **Invariante crítico**: `trustedDependencies` == exactamente `[better-sqlite3, node-llama-cpp]`; **ningún** `tree-sitter-*`. Cubierto por drift-guard bats.

## 3. Env del wrapper qmd (runtime)

- **Ubicación**: `scripts/lib/qmd_index.sh::_qmd_run` (espejado a `docker/scripts/lib/`).
- **Variables**:
  | Var | Valor | Alcance | Propósito |
  |-----|-------|---------|-----------|
  | `NODE_LLAMA_CPP_CMAKE_OPTION_GGML_NATIVE` | `OFF` | build de node-llama-cpp | evita `-march=native` (fallo CPU-probe) |
  | `NODE_LLAMA_CPP_CMAKE_OPTION_GGML_CPU_ARM_ARCH` | `armv8-a` | build | target aarch64 portable |
  | `LD_PRELOAD` | `/opt/agent-admin/bigstack.so` | **solo** el sub-wrapper de `embed` | pthread stacks 8MB (hazard std::regex musl) |
  | `TMPDIR`/`TMP`/`TEMP` | host-backed bajo `.state` | build + run | reuso de 015 US3 (evita ENOSPC) |
  | `PATH` | incluye `/usr/bin` | build | que `which cmake` encuentre el apk cmake (reuso wrapper-PATH 013/015) |
- **Guard**: `command -v cmake` antes del embed → fail-loud si falta (evita fallback silencioso al xpack glibc).

## 4. `bigstack.so` (mitigación runtime)

- **Fuente**: `docker/bigstack.c` (NUEVO) — override `pthread_create`: si `attr==NULL`, setea stack 8MB; delega vía `dlsym(RTLD_NEXT)`.
- **Build**: en el Dockerfile, `gcc -shared -fPIC -o /opt/agent-admin/bigstack.so bigstack.c -ldl` (image-baked, fuera de `.state`).
- **Activación**: `LD_PRELOAD` scoped al embed (no global).

## 5. Tiers del DOCKER_E2E

- **Fase A** (build-detector): `bunx/qmd --help` → RC0. Sin modelo.
- **Fase B** (update léxico): vault mínimo → `qmd-reindex` → `last_status=ok` + índice ≥1 doc.
- **Fase C** (embed real, gate `QMD_EMBED_E2E=1`): modelo cacheado → `qmd embed` rc0 + `*.gguf` + consulta ≥1 hit.
- **RED** (detección): `--build-arg QMD_NATIVE_TOOLCHAIN=0` → Fase A RC≠0 + causa real en stderr.
- **Model cache**: `QMD_E2E_MODEL_CACHE` (default `$HOME/.cache/agentic-qmd-e2e/models`) bind-mount al `models/` de qmd.

## 6. Pin de versión + guardrail (US4)

- **Fuente única**: `agent.yml` `vault.qmd.version` (hoy `2.5.3`).
- **Guardrail**: test bats que fija la cadena esperada + checklist pre-bump (contracts/qmd-version-guardrail.md). Un bump sin actualizar el test/checklist rompe el test.
