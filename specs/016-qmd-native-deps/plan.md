# Implementation Plan: qmd deps nativas en Alpine (fix root-cause de BUG 4)

**Branch**: `016-qmd-native-deps` | **Date**: 2026-07-10 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/016-qmd-native-deps/spec.md`

## Summary

`qmd embed`/`update` fallan en modo docker (Alpine musl aarch64) porque `@tobilu/qmd@2.5.3` arrastra módulos nativos sin prebuilt musl y la imagen no tiene compilador. Enfoque elegido (clarify): **mantener Alpine** y hacer que qmd compile lo que necesita en runtime, controlando exactamente qué se compila. Tres piezas:

1. **Toolchain en la imagen** (`apk add build-base cmake git linux-headers libgomp`, gateado por build-arg `QMD_NATIVE_TOOLCHAIN`), para que `node-llama-cpp` (embed) y `better-sqlite3` compilen; `apk cmake` en PATH evita que node-llama-cpp descargue su cmake glibc.
2. **Invocación por prefijo `bun install`** en el wrapper qmd (reemplaza `bunx`), con `trustedDependencies: [better-sqlite3, node-llama-cpp]` — así `tree-sitter-*` **no** compila (usa WASM) y `node-llama-cpp` **sí**. Env del wrapper: `NODE_LLAMA_CPP_CMAKE_OPTION_GGML_NATIVE=OFF` + `GGML_CPU_ARM_ARCH=armv8-a`, y `LD_PRELOAD=bigstack.so` (stacks 8MB) solo en el embed para el hazard `std::regex`/stack de musl.
3. **DOCKER_E2E des-stubeado** (quitar el bind-mount de `bunx`), en tiers: build-detector + update léxico + embed real (gate `QMD_EMBED_E2E`), con test de detección RED por toggle del build-arg.

El riesgo residual (bun + N-API + embed real en musl, no demostrado en conjunto) se resuelve **solo** en el gate DOCKER_E2E + ferrari; el **fallback B/C** queda armado con criterio de disparo explícito (research.md).

## Technical Context

**Language/Version**: Bash (host + image-baked libs); templates de `render.sh`; qmd = `@tobilu/qmd@2.5.3` (pin single-source en `agent.yml`). Imagen Alpine 3.24.1 aarch64 (musl); node v24.17.0, npm 11.12.1, bun/bunx 1.3.14, python3 3.14.5, node-gyp 12.2.0.

**Primary Dependencies**: `node-llama-cpp@3.18.1` (embed, cmake-js build-from-source), `better-sqlite3` + `sqlite-vec` (store/vectores), `web-tree-sitter` (WASM, runtime), `tree-sitter-*` (opcionales, NO compilar).

**Storage**: índice + modelo qmd bajo `<workspace>/.state/.cache/qmd` (XDG, feature 013); prefijo `bun install` bajo `$(qmd_cache_root)/pkg`. Bind-mount `.state:/home/agent`.

**Testing**: `bats tests/` (host, sin Docker) para drift-guards y lógica del wrapper; `DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats` (des-stubeado) para el runtime real; gate hardware ferrari (Alpine musl aarch64) + `QMD_EMBED_E2E` para el embed con modelo real.

**Target Platform**: contenedor Alpine musl aarch64 (docker mode). Modo local (glibc) intacto — solo prerequisito de toolchain documentado/verificado (US5).

**Project Type**: launcher bash + image-baked libs (los tres code paths de CLAUDE.md). Cambios en: `docker/Dockerfile`, `scripts/lib/qmd_index.sh` (+ espejo `docker/scripts/lib/`), `modules/docker-compose.yml.tpl` (build.args), `tests/docker-e2e-qmd.bats`, un `bigstack.c` nuevo, `agent.yml`/render para el guardrail de versión.

**Performance Goals**: reindex `update` completa (léxico) sin abortar; `embed` genera vectores consultables. El primer embed paga compile de llama.cpp + descarga de modelo (~300MB) — tolerado por el watchdog/timeout del wrapper (edge case de la spec).

**Constraints**: mantener Alpine single-stage (constitución); Principle II (privilegios) intacto; secretos jamás en argv/journal; TMPDIR host-backed de 015 reusado para el build; build-time network requerido (documentar).

**Scale/Scope**: 1 agente por host; vault real de referencia = 2696 páginas (ferrari). El fix es de infraestructura de build, no de volumen.

## Constitution Check

*GATE: pasa antes de Phase 0. Re-check post-Phase 1. Fuente: constitution.md v1.0.0.*

- [x] **I. Single Source of Truth** — PASS. El build-arg `QMD_NATIVE_TOOLCHAIN` se rendea desde `modules/docker-compose.yml.tpl` (build.args), no se hardcodea; el env del wrapper (`GGML_*`, `LD_PRELOAD`) vive en `scripts/lib/qmd_index.sh` (espejado). El pin de qmd sigue en `agent.yml` (`vault.qmd.version`). Todo sobrevive `--regenerate`.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. No se tocan `cap_drop`/`no-new-privileges`; sin socket/puertos/mounts privilegiados. `LD_PRELOAD` es una env var del wrapper (no un privilegio). `docker exec -u agent` sin cambios.
- [x] **III. Test-First, Host-Runnable** — PASS. Drift-guards bats host (trustedDependencies, presencia de env vars, guard cmake); DOCKER_E2E des-stubeado gateado por `DOCKER_E2E=1` (+ `QMD_EMBED_E2E` para el tier lento); `shellcheck -S error`. Tests antes de la implementación.
- [x] **IV. Idempotent, Fail-Silent** — PASS. El `bun install` del prefijo es idempotente (debounce por hash del package.json); la observabilidad de 015 (env efectivo redactado, causa real) se conserva; el guard de cmake falla-fuerte sin crashear el supervisor.
- [x] **V. Workspace-Is-the-Agent** — PASS. Prefijo, índice y modelo bajo `.state`; `bigstack.so` va en `/opt/agent-admin` (image-baked, no state); secretos no logueados.
- [x] **VI. Reproducible, Pinned** — PASS. El toolchain apk viene del base Alpine **ya pineado** (`alpine:3.24.1`) — sin pin duplicado nuevo; el build-arg se plumbing por `build.args` (no hardcode-only); qmd pin single-source + guardrail (US4); VERSION 0.9.0→0.10.0 + CHANGELOG.

**Resultado**: PASS con **una violación registrada en Complexity Tracking** (bloat de toolchain, abajo). Ninguna violación de un MUST duro: "Alpine, single-stage" se mantiene; Principle II intacto.

## Project Structure

### Documentation (this feature)

```text
specs/016-qmd-native-deps/
├── plan.md              # Este archivo
├── research.md          # Phase 0 (receta musl, tree-sitter, e2e)
├── data-model.md        # Phase 1 (entidades de config/build)
├── quickstart.md        # Phase 1 (cómo validar + gates)
├── contracts/           # Phase 1 (contratos de invocación/build/e2e/guardrail)
└── tasks.md             # Phase 2 (/speckit-tasks — NO lo crea /speckit-plan)
```

### Source Code (archivos tocados)

```text
docker/Dockerfile                      # apk toolchain gateado por ARG QMD_NATIVE_TOOLCHAIN; compilar bigstack.so
docker/bigstack.c                      # NUEVO: shim pthread_create → 8MB (mitiga std::regex musl)
modules/docker-compose.yml.tpl         # build.args: QMD_NATIVE_TOOLCHAIN (Principle VI)
scripts/lib/qmd_index.sh               # _qmd_run: bunx → prefijo bun install + trustedDependencies; env GGML_*/LD_PRELOAD embed
docker/scripts/lib/qmd_index.sh        # espejo (COPY explícito en Dockerfile)
tests/qmd-*.bats                       # drift-guards host: trustedDependencies, env vars, guard cmake, guardrail de versión
tests/docker-e2e-qmd.bats              # des-stubear bunx; tiers A/B/C; test de detección RED (toggle ARG)
agent.yml + render (guardrail versión)  # test que fija vault.qmd.version + checklist pre-bump (US4)
CHANGELOG.md, VERSION                   # 0.9.0 → 0.10.0
docs/ / CLAUDE.md / quickstart.md       # documentar QMD_EMBED_E2E, QMD_E2E_MODEL_CACHE, red build-time, prerequisito toolchain local (US5)
```

**Structure Decision**: los cambios respetan los tres code paths de CLAUDE.md (host-launcher: setup/render/tests; image-baked: `docker/`; libs espejadas `scripts/lib` ↔ `docker/scripts/lib` con COPY explícito). No hay estructura nueva; se extiende la existente.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| **Bloat de toolchain en la imagen runtime** (`build-base cmake git linux-headers libgomp`, ~cientos de MB) — desviación del *espíritu* minimalista de la imagen Alpine | `node-llama-cpp` (embed, requisito duro del RAG semántico) y `better-sqlite3` compilan **en runtime** vía cmake-js/node-gyp bajo el bind-mount `.state`; el bind-mount enmascara cualquier artefacto horneado, así que el toolchain debe estar presente en la imagen final (no en un stage descartable). | **Multi-stage hornear `.node`**: inútil, el bind-mount `.state:/home/agent` lo enmascara y bunx reinstala en runtime. **Base glibc (B)**: enmienda de constitución ("Alpine-based") + migración del modelo de privilegios (su-exec→gosu, crond, apk→apt) — mayor riesgo. **Embeddings remotos (C)**: saca el vault del host (choca con Workspace-Is-Agent). B y C quedan armados como fallback si el gate invalida A. |

Nota: "Alpine, single-stage" (Platform Constraints) **se mantiene** — no hay enmienda de constitución. Principle II (capacidades/privilegios) intacto. El toolchain se gatea por `QMD_NATIVE_TOOLCHAIN` para que el test de detección RED pueda construir una imagen sin él.

## Phase 0 — Outline & Research

Completado. Ver [research.md](./research.md): Decisión 1 (receta node-llama-cpp musl), Decisión 2 (estrategia tree-sitter por prefijo/trustedDependencies), Decisión 3 (DOCKER_E2E en tiers), veredicto adversarial (holds_in_musl=true, confianza media) y criterio de disparo del fallback B/C. No quedan NEEDS CLARIFICATION.

## Phase 1 — Design & Contracts

Completado. Artefactos: [data-model.md](./data-model.md) (entidades de configuración/build), [contracts/](./contracts/) (invocación qmd por prefijo, toolchain del Dockerfile, tiers del DOCKER_E2E, guardrail de versión), [quickstart.md](./quickstart.md) (validación + gates). El marcador SPECKIT de `CLAUDE.md` se actualiza a este plan.

## Re-check Constitution (post-design)

Sin cambios: PASS con la violación de bloat registrada. El diseño por prefijo/trustedDependencies **refuerza** Principle IV (control explícito de qué compila) y Principle I (env single-sourced en el wrapper/template). Listo para `/speckit-tasks`.
