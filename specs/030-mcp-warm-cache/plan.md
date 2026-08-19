# Implementation Plan: Warm cache para MCPs fuera del catálogo

**Branch**: `030-mcp-warm-cache` | **Date**: 2026-08-17 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/030-mcp-warm-cache/spec.md`

## Summary

Precalentar, en el arranque del contenedor (docker) y en `--login` (local), los paquetes uvx/npx que
los MCP declarados de un agente necesitan descargar en su primer uso — **derivándolos del `.mcp.json`
efectivo**, no de una lista hardcodeada. Cierra el modo de falla del incidente donna (16-08-2026): un
MCP de overlay (`google-workspace` = `uvx workspace-mcp`) descargaba su wheel de PyPI dentro de la
ventana de handshake y quedaba muerto. 029 ensanchó la ventana (mitigación); 030 elimina la descarga
en frío (causa raíz). Fase 0 (5 agentes de lectura sobre launcher + overlay) fijó: el fix es **100%
del launcher** (el `.mcp.json` post-`custom-apply` ya contiene los MCP de overlay); el warm debe correr
**en boot** leyendo ese `.mcp.json` (un warm de build no puede cubrir overlays inyectados post-build);
y la derivación debe ser **args-aware** (el `google-workspace` usa `command=seed-google-creds.sh,
args=[uvx, workspace-mcp]`, que el selector `command=="uvx"` de hoy no ve). Decisión del operador
(2026-08-17): **paridad de derivación** — docker warma uvx+npx en boot; local corrige su selector a
args-aware (uvx-only, sin sumar warm de npx). Ver `research.md` (D1-D8).

## Technical Context

**Language/Version**: bash 3.2+ (host launcher, matriz CI 3.2/5.x); bash de Alpine (boot del
contenedor); `jq` para parsear `.mcp.json`.

**Primary Dependencies**: `uv`/`uvx` (warm de paquetes Python), `npm`/`npx` (warm de paquetes Node),
`jq`, `yq`. Reusa caches existentes `/opt/uv` (`UV_TOOL_DIR`/`UV_CACHE_DIR`) y `/opt/npm-cache`
(`NPM_CONFIG_CACHE`), ya fuera del bind-mount `/home/agent`.

**Storage**: ninguno nuevo en `agent.yml`. La lista de warm se deriva del `.mcp.json` efectivo (a su
vez derivado de `agent.yml` + overlay). Caches de paquetes en `/opt/uv` + `/opt/npm-cache` (docker) y
`~/.local/share/uv` + `~/.cache/uv` (local, uvx-only).

**Testing**: `bats` host (derivación pura, saneo, mutación, no-regresión) + `DOCKER_E2E=1`
(`tests/docker-e2e-warm-cache.bats`, patrón offline de vault/versions e2e). `shellcheck -S error`.

**Target Platform**: contenedor Alpine (modo docker, foco del incidente) + systemd/host (modo local,
paridad de derivación).

**Project Type**: single project (bash + plantillas). Nueva lib `scripts/lib/mcp_warm.sh` + edición de
`docker/scripts/start_services.sh` (image-baked) + `modules/local-bootstrap.sh.tpl`.

**Performance Goals**: el warm síncrono de boot solo paga costo en el primer boot frío (descarga única);
boots siguientes = no-op idempotente. Timeout por paquete evita cuelgue.

**Constraints**: offline-capable (el objetivo ES que el arranque no dependa de la red); sin secretos en
el warm (FR-006); fail-soft (FR-007); cache fuera del montaje de estado (FR-004);
`UV_PYTHON_PREFERENCE=only-system` intacto (no auto-descargar CPython).

**Scale/Scope**: ~15-25 MCP por agente como máximo; derivación O(n) sobre `.mcpServers`.

## Constitution Check

*GATE: evaluado pre-Fase 0 y re-evaluado post-diseño. Fuente: constitution.md v1.0.1.*

- [x] **I. Single Source of Truth** — PASS. No se hand-editan derivados; la lista de warm se DERIVA del
  `.mcp.json` (ya derivado de `agent.yml`+overlay). No hay estado nuevo que un `--regenerate` borre; el
  warm re-deriva en cada boot/login (FR-011). La lib `mcp_warm.sh` es fuente única de la derivación,
  consumida por docker y local (D6).
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. No se toca el modelo de capacidades: sin cap
  nuevas, sin mounts, sin socket, sin puertos. El warm corre como `agent` (no root), escribiendo caches
  ya chown'd a `agent`. No hay `docker exec` nuevo. Reusa `/opt/uv` y `/opt/npm-cache` existentes.
- [x] **III. Test-First, Host-Runnable** — PASS. La derivación (`mcp_warm.sh`) es host-runnable y se
  cubre con bats sin Docker (12 casos + mutación). El paso de boot se guarda tras
  `START_SERVICES_NO_RUN`/`BASH_SOURCE` para sourcear sin ejecutar. DOCKER_E2E gateado por
  `DOCKER_E2E=1`, NO requerido por la suite default. `shellcheck -S error` limpio.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. El warm es idempotente (cache del gestor),
  fail-soft (best-effort + `warn`, retorna 0 siempre), timeout-bounded; no puede crashear el supervisor
  ni consumir crash budget por fallo (D4/B3). Degrada al comportamiento de 029.
- [x] **V. Workspace-Is-the-Agent** — PASS. No toca `.state/` ni el modelo de backups. Los caches viven
  en `/opt` (docker, fuera de `.state`) y HOME del operador (local). No se commitea ni loguea estado
  sensible; el warm no lee secretos.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. El catálogo baked del `Dockerfile:121-125` se
  conserva; los pins del catálogo siguen single-sourced en `versions.sh`. Los paquetes de overlay se
  warmean al **spec literal del `.mcp.json`** (fidelidad de pin, D3), sin introducir una tabla de pins
  duplicada. `CHANGELOG.md`/`VERSION` se actualizan (user-facing).

**Resultado: 6/6 PASS, sin violaciones.** Nota (no violación): la feature TOCA `docker/` image-baked
(`start_services.sh`, quizá `Dockerfile`) → **DOCKER_E2E obligatorio** (gate de Development Workflow),
diferido a un host Docker (sin daemon en esta sesión), como 016/017/026. No es una violación de
principio; es el gate de calidad que aplica cuando se toca `docker/` o el boot.

## Project Structure

### Documentation (this feature)

```text
specs/030-mcp-warm-cache/
├── plan.md              # Este archivo
├── spec.md              # Spec (/speckit-specify)
├── research.md          # Fase 0 (D1-D8, medido)
├── data-model.md        # Entidades: warm target, caches, manifiesto
├── quickstart.md        # Gates de validación
├── contracts/
│   ├── warm-derivation.md   # Algoritmo + 12 casos oráculo
│   ├── boot-integration.md  # Integración docker boot + local login
│   └── docker-e2e-tiers.md  # E1 GREEN / E2 RED / E3 no-reg / E4 verif offline
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks (NO creado por /speckit-plan)
```

### Source Code (repository root)

```text
scripts/lib/
└── mcp_warm.sh                    # NUEVO — derivación pura (mcp_warm_targets) + warm (mcp_warm_run)

docker/scripts/
├── start_services.sh              # EDIT — pre_warm_mcps síncrono pre-claude (image-baked → DOCKER_E2E)
└── lib/mcp_warm.sh                # mirror de scripts/lib/mcp_warm.sh (COPY/mirror para el boot)

modules/
└── local-bootstrap.sh.tpl         # EDIT — provision_uv_tools usa mcp_warm_targets (args-aware, uvx-only)

setup.sh                           # EDIT (si aplica) — línea de mirror de mcp_warm.sh a docker/local

tests/
├── mcp-warm.bats                  # NUEVO — derivación (12 casos), mutación
├── docker-e2e-warm-cache.bats     # NUEVO — DOCKER_E2E (E1/E2/E3/E4), gateado
└── (local-bootstrap.bats / start-services*.bats)  # EDIT — cobertura del selector args-aware / guard del paso

VERSION, CHANGELOG.md, README.md   # bump + documentación
```

**Structure Decision**: single project. El núcleo es la lib `scripts/lib/mcp_warm.sh` (fuente única de
la derivación, testeable en host), consumida por (a) el boot de docker vía `start_services.sh` con su
copia image-baked y (b) el bootstrap local vía `provision_uv_tools`. El warm de build hardcodeado del
`Dockerfile` se conserva sin cambio (no-regresión del catálogo).

## Complexity Tracking

Sin violaciones de constitución que justificar (6/6 PASS). El único costo estructural es el **mirror de
`mcp_warm.sh` a docker** (gotcha `docker-lib-needs-explicit-copy`) y el **DOCKER_E2E** obligatorio por
tocar image-baked — ambos son gates conocidos del repo, no desviaciones de principio, y se cubren con
una verificación de mirror + el tier e2e RED (build-arg off).
