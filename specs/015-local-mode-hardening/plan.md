# Implementation Plan: Local-mode & docker RAG hardening (post first hardware gate)

**Branch**: `015-local-mode-hardening` | **Date**: 2026-07-09 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/015-local-mode-hardening/spec.md`

## Summary

Cuatro defectos del launcher, destapados por el primer gate de hardware real (2026-07-08), se llevan del parche-de-host al código con cobertura test-first:

- **US1 (P1)** — `detect_claude_cli` (setup.sh:80-88) devuelve un nombre pelado (`claude`) que se persiste en `agent.yml` y luego `_export_local_context` (setup.sh:2258-2259) resuelve con `command -v` **en la máquina que corre `--regenerate`**; headless eso degrada al literal `claude` → `ExecStart=claude …` → systemd `203/EXEC`. Fix: `detect_claude_cli` resuelve a **ruta absoluta** (candidatos conocidos), el scaffold la persiste en `agent.yml`, y `_export_local_context` la usa si es absoluta+ejecutable, si no re-resuelve, y **falla ruidosamente** si ningún candidato resuelve.
- **US2 (P1)** — `provision_bun` (modules/local-bootstrap.sh.tpl:145-171) baja siempre `bun-linux-<arch>-musl.zip` (línea 159); en host glibc no ejecuta. Fix: detectar la libc del host y elegir la build (`…-musl.zip` en musl, `….zip` glibc), y cambiar el guard idempotente (línea 147) para que verifique **ejecución real** (`bun --version` rc 0), no sólo presencia.
- **US3 (P1)** — el tmpfs `/tmp` de 100 MB (docker-compose.yml.tpl:32) se llena con el cache de `bunx` (~98 MB) → ENOSPC para el runner wiki-graph y qmd; el `2>/dev/null` en la agregación (wiki_graph.sh:325) oculta el error real. Fix: **routear `TMPDIR`/cache de bunx-qmd y los `mktemp` del runner a un dir host-backed bajo `.state`** (el tmpfs `/tmp` no se agranda) + capturar el stderr real de la agregación en el state file (refina Principle IV).
- **US4 (P2, sólo observabilidad en 015)** — el reindex qmd en docker traga el error con `>/dev/null 2>&1` (qmd_index.sh:252,257). Fix en alcance: quitar la redirección, capturar stderr + el env efectivo (secretos redactados). El fix de causa raíz del wrapper se **defiere** al gate confirmatorio con ferrari.

## Technical Context

**Language/Version**: Bash (host launcher: `bash` 4+; workspace/image runtime: POSIX `sh`/`bash`, busybox en Alpine). No hay lenguaje compilado.

**Primary Dependencies**: `yq` v4+, `jq`, `git`, `curl`, `unzip`, BSD/GNU `sed`; runtime: `bun`/`bunx` 1.3.14, `@tobilu/qmd` 2.5.3, `flock`, `timeout`; render engine `scripts/lib/render.sh`.

**Storage**: Archivos. `agent.yml` (single source), derivados renderizados, state files JSON (`wiki-graph.json`, `qmd-index.json`), storage qmd XDG bajo `.state/.cache` (013).

**Testing**: `bats-core` host-side (suite por defecto sin Docker); `DOCKER_E2E=1 bats tests/docker-e2e-*.bats` para el runtime docker; `shellcheck -S error`.

**Target Platform**: Host launcher macOS/Linux; agentes en Alpine (docker, musl) y Debian/Ubuntu (local systemd, glibc), arm64/x86_64.

**Project Type**: CLI / bash scaffolder de tres rutas de código (host-launcher, image-baked, workspace-templated).

**Performance Goals**: N/A (mantenimiento batch); restricción operativa: el reindex/agregación no debe colgar el boot (bounded por `timeout`, Principle IV).

**Constraints**: Cambios reproducibles por `--regenerate` (Principle I); sin tocar el modelo de privilegios del contenedor (Principle II); test-first (Principle III); fail-silent que **registra** errores de infra, no los traga (refina Principle IV); secretos jamás en argv/journal/log (Principle V); pines de dependencias intactos (Principle VI).

**Scale/Scope**: Vaults de miles de páginas (ferrari: 2696). 4 archivos de producto tocados + libs espejadas a docker + tests.

## Constitution Check

*GATE: pasa antes de Phase 0; re-verificado tras Phase 1. Fuente: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — US1 persiste `deployment.claude_cli` (ruta absoluta) en `agent.yml`; el `ExecStart` de la unit se **rerenderiza** de ahí. Todos los cambios sobreviven `--regenerate` (US1 re-resuelve+persiste; US2/US3/US4 viven en templates/libs rerenderizados o espejados). Ninguna edición a derivados a mano. **PASS**.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — el mecanismo elegido para US3 (routear `TMPDIR` host-backed al bind-mount `.state` ya existente) **no** toca `cap_drop`/`no-new-privileges` ni agrega mounts/caps/sockets; `docker-compose.yml.tpl` puede quedar **sin cambios**. `docker exec` sigue con `-u agent`; crontabs root-owned intactos. **PASS** (sin debilitamiento).
- [x] **III. Test-First, Host-Runnable** — cada cambio de comportamiento estrena `bats` escrito antes: fixture unit-render con `claude` sólo en `~/.local/bin` (US1), detección de libc + selección de build (US2), routing de `TMPDIR` y captura de stderr del runner (US3), reindex con error visible (US4). Suite por defecto sin Docker; los cambios a `scripts/lib/{wiki_graph,qmd_index}.sh` (runtime docker) van tras `DOCKER_E2E=1`. `shellcheck -S error` limpio; libs con guard `BASH_SOURCE`. **PASS**.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — US2 refuerza idempotencia (guard por ejecución real, no re-baja/pisa con build incompatible). US1 falla **ruidoso** sólo en el path de scaffold/regenerate (no en boot/heartbeat) — no cruza la frontera fail-silent del supervisor. FR-007 **refina** IV explícitamente: fail-silent ≠ error-swallow; los pasos batch siguen retornando 0 pero **registran** el error de infra en su state/log. **PASS** (alineado; refinamiento documentado en spec).
- [x] **V. Workspace-Is-the-Agent** — `TMPDIR` host-backed cae bajo `.state` (ya bind-mount); nada nuevo se commitea. **Riesgo controlado**: el volcado de env efectivo de US4 MUST redactar secretos (sin valores de tokens/OAuth/API) — se especifica en contracts. **PASS**.
- [x] **VI. Reproducible, Pinned Dependencies** — `bun` sigue pineado 1.3.14 (no se introduce pin nuevo; sólo cambia el **sufijo de build** glibc/musl del mismo pin). `VERSION` 0.8.0 → **0.9.0** + entrada en `CHANGELOG.md`. Oportunidad opcional (SHOULD): consolidar el pin de `bun` local hacia `versions.sh` — se anota en research, no bloquea. **PASS**.

**Resultado del gate: PASS sin violaciones.** Complexity Tracking vacío.

## Project Structure

### Documentation (this feature)

```text
specs/015-local-mode-hardening/
├── plan.md              # Este archivo
├── spec.md              # Especificación (con Clarifications de la sesión 2026-07-09)
├── research.md          # Phase 0: decisiones técnicas de los 3 unknowns deferidos
├── data-model.md        # Phase 1: entidades (claude_cli, build de bun, TMPDIR, state files)
├── quickstart.md        # Phase 1: gate confirmatorio en hardware (mclaren + ferrari)
├── contracts/           # Phase 1: contratos observables por bug
│   ├── claude-cli-resolution.md
│   ├── bun-libc-provisioning.md
│   ├── temp-routing-and-observability.md
│   └── qmd-reindex-observability.md
├── checklists/
│   └── requirements.md  # Del /speckit-specify (16/16)
└── tasks.md             # Phase 2 (/speckit-tasks — NO lo crea /speckit-plan)
```

### Source Code (repository root)

Rutas reales que la feature toca (verificadas file:line en esta sesión):

```text
setup.sh
├── detect_claude_cli()          # L80-88   — US1: resolver a ruta absoluta (candidatos)
├── (scaffold) claude_cli: …     # L1109    — US1: persiste el valor absoluto en agent.yml
└── _export_local_context()      # L2253-60 — US1: usar valor persistido / re-resolver / fail-loud

modules/
├── local-bootstrap.sh.tpl       # L145-171 provision_bun — US2: detección de libc + guard por ejecución
├── systemd-remote-control.service.tpl  # L14 ExecStart={{CLAUDE_BIN}} — sin cambios (recibe abs. path)
└── docker-compose.yml.tpl       # L31-32 tmpfs /tmp — SIN CAMBIOS con mecanismo A (routing en wrappers)

scripts/lib/                     # espejados a docker/scripts/lib/ (COPY explícito en Dockerfile)
├── rag_obs.sh                   # NUEVO (Foundational): redact_secrets + scratch_dir — US3/US4
├── wiki_graph.sh                # L290 mktemp TMPDIR, L323-327 agregación + 2>/dev/null — US3
└── qmd_index.sh                 # L84-89 _qmd_run, L252/257 reindex >/dev/null 2>&1 — US3/US4

docker/Dockerfile                # L230-231 COPY de las libs — re-mirror por --regenerate
scripts/lib/versions.sh          # L35 AGENTIC_FLOOR_BUN — referencia opcional de consolidación (VI)

tests/                           # bats host-side, test-first
├── (nuevo) claude_cli_resolution.bats
├── (nuevo/extend) local_bootstrap.bats            # provision_bun libc
├── (extend) wiki_graph.bats / qmd_index.bats      # TMPDIR + observabilidad
└── docker-e2e-*.bats            # gate docker runtime (US3/US4)

VERSION                          # 0.8.0 → 0.9.0
CHANGELOG.md                     # entrada de hardening
```

**Structure Decision**: No se introduce estructura nueva. La feature es hardening quirúrgico sobre archivos existentes de las tres rutas de código, con tests `bats` nuevos/extendidos. El mecanismo A de US3 mantiene `docker-compose.yml.tpl` intacto (routing en los wrappers), lo que evita tocar el modelo de privilegios (Principle II) y reduce la superficie de `DOCKER_E2E` al runtime de las dos libs.

## Complexity Tracking

> Sin violaciones de la Constitution Check. Tabla vacía.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| — | — | — |
