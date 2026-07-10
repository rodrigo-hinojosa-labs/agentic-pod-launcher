# Implementation Plan: qmd sqlite-vec en Alpine musl (cierre del embed semántico)

**Branch**: `017-qmd-sqlite-vec-musl` | **Date**: 2026-07-10 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/017-qmd-sqlite-vec-musl/spec.md`

## Summary

`qmd embed` falla en la imagen Alpine musl aarch64 porque el prebuilt `sqlite-vec-linux-arm64@0.1.9` es un binario **glibc** (necesita `ld-linux-aarch64.so.1` y símbolos `GLIBC_2.17`) que no carga bajo musl. Es el tercer módulo nativo del pipeline de embed; 016 resolvió los otros dos (tree-sitter → WASM, node-llama-cpp → toolchain+bigstack) pero se mergeó sin correr el DOCKER_E2E que lo habría destapado.

**Enfoque técnico** (verificado end-to-end en esta sesión sobre la imagen musl real): compilar la amalgamación oficial de `sqlite-vec` v0.1.9 para musl en tiempo de **build** de la imagen (reutilizando el toolchain que 016 ya agregó, con el shim `-Du_int8_t=uint8_t …` obligatorio porque musl no expone los nombres BSD), hornear el `vec0.so` musl en una ruta de la imagen no enmascarada por el bind-mount `.state`, y **sustituir** el prebuilt glibc en el prefijo gestionado durante el aprovisionamiento (`_qmd_ensure_prefix`), gateado por la presencia del artefacto horneado (que solo existe en la imagen docker/musl). Se des-stubea el DOCKER_E2E para ejercer `embed`+`vsearch` reales y se agrega un guardrail de versión qmd/sqlite-vec. El modo local (glibc) queda intacto: su prebuilt glibc ya carga.

## Technical Context

**Language/Version**: Bash (host `bash` 4+; imagen busybox ash + bash), C (amalgamación sqlite-vec, compilada con `cc`/gcc de `build-base`), bats para tests.

**Primary Dependencies**: `@tobilu/qmd@2.5.3` (pin en `agent.yml vault.qmd.version`) → `sqlite-vec@0.1.9` (prebuilt `sqlite-vec-linux-arm64`); toolchain de build de 016 (`build-base`, `cmake`, `linux-headers`, `libgomp`) gateado por `QMD_NATIVE_TOOLCHAIN`; headers de compilación de la extensión SQLite (`sqlite3ext.h`/`sqlite3.h`) vía `apk sqlite-dev` en build.

**Storage**: N/A (la extensión opera sobre la DB de qmd bajo `.state`; no cambia el esquema).

**Testing**: `bats tests/` (host, sin Docker) para guardrail + lógica de swap; `DOCKER_E2E=1 QMD_EMBED_E2E=1 bats tests/docker-e2e-qmd.bats` para el embed real; `shellcheck -S error`.

**Target Platform**: Imagen Alpine musl aarch64 (docker) — el único afectado. Modo local glibc no requiere el fix.

**Project Type**: Launcher bash + imagen docker single-stage + librerías espejadas `scripts/lib` ↔ `docker/scripts/lib`.

**Performance Goals**: El fix agrega una compilación C única en build (~segundos) y una copia de ~150KB por aprovisionamiento del prefijo; el embed en runtime lo domina la inferencia de node-llama-cpp (016), no sqlite-vec.

**Constraints**: No cambiar el OS base ni el modelo de privilegios (Principle II); imagen Alpine single-stage; secretos jamás en argv/journal; fail-silent si el artefacto falta (léxico sigue).

**Scale/Scope**: Cambio quirúrgico: 1 bloque en `docker/Dockerfile`, 1 función en `qmd_index.sh` (+ espejo docker), des-stub de 1 test e2e, 1 test host de guardrail, `VERSION`+`CHANGELOG`. Gate confirmatorio ferrari (vault real ~2696 páginas).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — PASS. El cambio de comportamiento vive en la lib `qmd_index.sh` (espejada a docker vía COPY) y en `docker/Dockerfile`; ningún archivo derivado se edita a mano. `SQLITE_VEC_VERSION` se plumbea como build-arg (compose `build.args`), no como literal hardcodeado inalcanzable. El swap es un paso de aprovisionamiento del prefijo (como el `bun install` mismo), no un archivo renderizado; sobrevive `--regenerate` (la lib se re-espeja).
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. `docker-compose.yml.tpl` NO se toca; sin nuevas capabilities, mounts ni socket; `-u agent` intacto; crontabs root-owned intactos. La compilación ocurre en build (root, como el resto del Dockerfile), el runtime solo copia un archivo. El artefacto horneado (~150KB) se registra en Complexity Tracking.
- [x] **III. Test-First, Host-Runnable** — PASS. Tests bats host (guardrail de versión + lógica de swap con mocks del artefacto horneado y del libc-probe) se escriben ANTES de la implementación; el DOCKER_E2E queda gateado por `DOCKER_E2E=1`/`QMD_EMBED_E2E=1` y no bloquea la suite host; `shellcheck -S error` limpio; la lib mantiene sus guards `BASH_SOURCE`.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. El swap es idempotente (`cp -f` del mismo artefacto determinista; re-ejecutable). Si el artefacto horneado falta (p.ej. `QMD_NATIVE_TOOLCHAIN=0`), se loguea un warning redactado y se continúa (embed no disponible, léxico intacto); nunca crashea el reindex ni el supervisor.
- [x] **V. Workspace-Is-the-Agent** — PASS. Sin cambios de estado; el `vec0.so` musl vive en la imagen y se copia al prefijo bajo `.state` en runtime (igual que el resto del `node_modules` del prefijo). No toca secretos ni los loguea.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. `SQLITE_VEC_VERSION` pinneado como ARG del Dockerfile + compose `build.args`; descarga por URL de versión fija con verificación `sha256`; guardrail bats que fija el par (qmd 2.5.3 ↔ sqlite-vec 0.1.9) para forzar re-verificación ante un bump; `CHANGELOG.md` + `VERSION` 0.10.0 → 0.11.0.

**Resultado**: Sin violaciones que requieran enmienda de constitución. Bloat de imagen (~150KB artefacto + `sqlite-dev`/build transitorios) registrado en Complexity Tracking, consistente con el ya aceptado por 016.

## Project Structure

### Documentation (this feature)

```text
specs/017-qmd-sqlite-vec-musl/
├── plan.md              # Este archivo
├── research.md          # Phase 0 — decisiones (root cause + fix ya verificados)
├── data-model.md        # Phase 1 — entidades (artefacto, prefijo, versión)
├── quickstart.md        # Phase 1 — cómo validar (host + DOCKER_E2E + ferrari)
├── contracts/           # Phase 1 — contratos (compile, swap, e2e-tiers, guardrail)
└── tasks.md             # Phase 2 (/speckit-tasks — no lo crea /speckit-plan)
```

### Source Code (repository root)

```text
docker/
├── Dockerfile                     # + bloque compile sqlite-vec musl (gateado QMD_NATIVE_TOOLCHAIN), ARG SQLITE_VEC_VERSION, bake a /opt/agent-admin/sqlite-vec/vec0.so
├── scripts/
│   ├── build-sqlite-vec.sh        # NUEVO (opcional): script de build invocado por el Dockerfile (download+verify+compile+bake)
│   └── lib/
│       └── qmd_index.sh           # ESPEJO (regenerado): recibe la lógica de swap en _qmd_ensure_prefix
scripts/
└── lib/
    └── qmd_index.sh               # FUENTE: swap del vec0.so musl en _qmd_ensure_prefix (gateado por artefacto horneado + libc musl)

tests/
├── docker-e2e-qmd.bats            # des-stub embed (embed+vsearch reales), fix Fase A (path de producción, no bunx), RED por QMD_NATIVE_TOOLCHAIN=0
└── qmd-sqlite-vec.bats            # NUEVO: guardrail de versión (par qmd/sqlite-vec) + lógica de swap con mocks

VERSION                            # 0.10.0 → 0.11.0
CHANGELOG.md                       # entrada 017
docker-compose.yml.tpl             # (si aplica) plumb SQLITE_VEC_VERSION vía build.args — como QMD_NATIVE_TOOLCHAIN
```

**Structure Decision**: Este repo no sigue `src/models|services`; su estructura son tres code paths (host-launcher / image-baked `docker/` / workspace-templated) + libs espejadas `scripts/lib` ↔ `docker/scripts/lib`. El fix toca (a) el image-baked (`docker/Dockerfile` + un build script), (b) la lib compartida (`scripts/lib/qmd_index.sh`, espejada), (c) los tests. Es el mismo perímetro que 016.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Bloat de imagen: artefacto `vec0.so` musl (~150KB) horneado + `sqlite-dev`/fuente de amalgamación transitorios durante el build | Es la única forma de tener un `sqlite-vec` cargable en musl sin cambiar el OS base (constitución: imagen Alpine single-stage; Principle II). El prebuilt del paquete es glibc y físicamente no carga en musl (probado con `ldd`/`strings`). | (a) Usar el prebuilt glibc: imposible, no carga en musl (falla `ld-linux-aarch64.so.1`). (b) Cambiar la base a glibc (fallback B de 016): exige enmienda de constitución + migración pesada (busybox crond→cron, su-exec→gosu, apk→apt, re-auditar privilegios); desproporcionado para un artefacto de 150KB. (c) Embeddings remotos (fallback C): cambia el contrato de RAG y saca el embed local de alcance. Esta violación es análoga y consistente con el toolchain que 016 ya introdujo y aceptó. |
