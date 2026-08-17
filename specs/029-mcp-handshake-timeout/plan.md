# Implementation Plan: Ventana de handshake MCP configurable (docker + local)

**Branch**: `029-mcp-handshake-timeout` | **Date**: 2026-08-17 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/029-mcp-handshake-timeout/spec.md`

## Summary

Hacer configurable, desde `agent.yml`, la ventana de handshake de **arranque** de los MCP servers
(variable de entorno `MCP_TIMEOUT` de Claude Code, hoy con default de 30 s), con un default de la
feature de 120 s, en **ambos modos** (docker y local). Cierra el modo de falla medido en ferrari
(16-08-2026, agente `donna`): un MCP cuyo primer arranque descarga un paquete de PyPI (~50 s) excede la
ventana de 30 s, Claude Code lo marca failed y **no lo reintenta** por el resto de la sesión.

Enfoque técnico (Fase 0, todo medido — ver [research.md](./research.md)): un campo escalar
`claude.mcp_timeout_ms` en `agent.yml` (fuente única, Principio I) que se rendea a dos artefactos —el
bloque `environment:` del `docker-compose.yml` (como el `TZ` existente) y el `EnvironmentFile`
`remote-control.env` de la unit de sesión systemd—, saneado en el render (entero > 0, degradación al
default) y con backfill `has()` para agentes existentes. **No toca código bajo `docker/`** (el env del
compose llega intacto a `claude`), por lo que la feature es host-testeable y no requiere `DOCKER_E2E`.

## Technical Context

**Language/Version**: bash 3.2+ (macOS stock) y 5.x (CI); `yq` v4+, `jq`, `sed` BSD/GNU.

**Primary Dependencies**: motor de render `scripts/lib/render.sh`; schema `scripts/lib/schema.sh`;
heredoc de `agent.yml` y `regenerate()` en `setup.sh`; plantillas `modules/docker-compose.yml.tpl` y
`modules/remote-control.env.tpl`. Consumidor externo: binario Claude Code (env `MCP_TIMEOUT`, medido en
2.1.223; pin de imagen 2.1.220).

**Storage**: `agent.yml` (fuente única); artefactos derivados `docker-compose.yml` y
`.state/remote-control.env`. N/A base de datos.

**Testing**: `bats` host (sin Docker). Suites a extender: `tests/schema*.bats`, `tests/regenerate.bats`,
`tests/docker-render.bats`, `tests/local-render.bats` (o `modules-render.bats`), y un test nuevo de
saneo/backfill del handshake. `shellcheck -S error` limpio.

**Target Platform**: host del launcher (macOS/Linux) que scaffolda; el valor efectivo lo consume el
proceso `claude` en el contenedor (docker) o bajo systemd (local).

**Project Type**: CLI / generador de scaffolding (bash + plantillas). Single project.

**Performance Goals**: N/A (config estática de arranque).

**Constraints**: el valor efectivo nunca ≤ 0; el render nunca falla por un valor inválido (degrada al
default); dos `--regenerate` byte-idénticos; el literal no se duplica entre plantillas.

**Scale/Scope**: un campo nuevo; ~5 touchpoints de código + tests. Sin migración de estado.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.1).*

- [x] **I. Single Source of Truth** — PASS. El valor vive en `agent.yml` (`claude.mcp_timeout_ms`); los
  dos artefactos derivados se rendean de él vía `render.sh` (mismo placeholder `{{CLAUDE_MCP_TIMEOUT_MS}}`,
  sin literal duplicado). Sobrevive `--regenerate` (backfill `has()` para agentes viejos). Sin edición
  manual de derivados.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. Solo agrega una variable de entorno; no toca
  `cap_drop`/`cap_add`/`no-new-privileges`, no agrega mounts, socket ni capacidades. No cambia ningún
  `docker exec`.
- [x] **III. Test-First, Host-Runnable** — PASS. Cobertura `bats` host-runnable (render docker + local,
  saneo, backfill, schema), escrita antes del fix. **DOCKER_E2E no requerido**: la feature no toca
  `docker/` image-baked ni comportamiento de boot/supervisor; el env del compose llega intacto a
  `claude` (verificado, ver research.md D5). `shellcheck -S error` limpio.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. Backfill idempotente guardado por `has()` (no
  mtime, no `//`); el saneo degrada a default ante valor inválido sin fallar el render. Dos
  `--regenerate` byte-idénticos.
- [x] **V. Workspace-Is-the-Agent** — N/A. No toca `.state/` de estado durable, backups ni
  `--restore-from-fork`. (El artefacto local vive en `.state/remote-control.env`, que es un derivado
  rendeado, no estado durable — se regenera; no contiene secretos.)
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. Valor single-sourced en `agent.yml` (sin nuevo
  pin duplicado). `VERSION` bump + entrada en `CHANGELOG.md`. No introduce toolchain nueva.

**Resultado: 6/6 (II/V sin fricción). Sin violaciones → sin Complexity Tracking.**

Re-check post-diseño (Fase 1): sin cambios. El diseño (campo `agent.yml` + dos plantillas + saneo en
`setup.sh` + backfill) no introduce ninguna violación nueva. 6/6 se mantiene.

## Project Structure

### Documentation (this feature)

```text
specs/029-mcp-handshake-timeout/
├── plan.md              # Este archivo
├── research.md          # Fase 0 — medición del binario + mapeo del repo + 7 decisiones
├── data-model.md        # Fase 1 — entidad, saneo, backfill, artefactos, invariantes
├── quickstart.md        # Fase 1 — configurar + verificar en ambos modos
├── contracts/
│   └── mcp-timeout-contract.md   # C1..C6 (campo, saneo, entrega docker/local, no-regresión)
├── checklists/
│   └── requirements.md  # checklist de calidad de la spec
└── tasks.md             # Fase 2 (/speckit-tasks — aún no creado)
```

### Source Code (repository root)

Touchpoints concretos (todos existentes; la feature agrega, no crea subsistemas):

```text
setup.sh
├── heredoc de agent.yml (~:1203-1205)   # + `mcp_timeout_ms: 120000` en el bloque claude:
├── regenerate() (~:1965, bloque backfill ~:2048)  # backfill has() del campo
└── mcp_timeout_effective() (nuevo helper)  # saneo + re-export de CLAUDE_MCP_TIMEOUT_MS

scripts/lib/schema.sh          # registrar claude.mcp_timeout_ms como opcional (sin validación dura)

modules/
├── docker-compose.yml.tpl     # +1 línea en environment:  MCP_TIMEOUT: "{{CLAUDE_MCP_TIMEOUT_MS}}"
└── remote-control.env.tpl      # +1 línea:  MCP_TIMEOUT={{CLAUDE_MCP_TIMEOUT_MS}}

tests/
├── schema*.bats               # el campo opcional no rompe la validación
├── regenerate.bats            # backfill + idempotencia byte-estable
├── docker-render.bats         # MCP_TIMEOUT en el environment: del compose
├── local-render.bats          # MCP_TIMEOUT en remote-control.env
└── mcp-handshake-timeout.bats # NUEVO: saneo (válido/ausente/0/no-numérico → default), single-source

VERSION                        # bump (MINOR: nueva capacidad)
CHANGELOG.md                   # entrada de la feature
```

**Structure Decision**: single project (bash + plantillas). No hay `src/` — el código es `setup.sh` +
`scripts/lib/` + `modules/`, y los tests son `bats` en `tests/`. La feature es aditiva sobre esos
archivos existentes; el único archivo nuevo es el test `tests/mcp-handshake-timeout.bats` (y el helper
`mcp_timeout_effective()` dentro de `setup.sh`).

## Complexity Tracking

Sin violaciones de constitución → sin entradas. (La feature es aditiva, single-sourced y no toca el
modelo de privilegios ni el estado durable.)
