# Implementation Plan: Aviso de actualización de conocimiento al iniciar sesión

**Branch**: `038-schema-delta-boot-nudge` | **Date**: 2026-09-30 (reescrito el mismo día; borrador previo
en `d88cbfb`) | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/038-schema-delta-boot-nudge/spec.md`

**Rama base**: `037-second-brain-rag` (VERSION 0.27.0), no `main` (0.26.0). El PR espera el merge de 037;
al rebasar, verificar `VERSION` contra `origin/main` a mano.

## Summary

Un upgrade deja atrás dos capas de conocimiento del agente y hoy nadie se lo dice: el `CLAUDE.md` del
vault (deltas de schema depositados que el agente debe integrar) y el `CLAUDE.md` del workspace (que
`--regenerate` preserva aunque, como se midió en donna, no tenga una sola edición propia). La feature
resuelve ambas con tres piezas:

1. **Detección compartida, sin caché**: `vault_pending_deltas` (marcador `.applied` + hito literal ausente,
   tabla explícita por versión) y `claude_md_state` (comparación byte a byte del `CLAUDE.md` contra el
   render vigente y contra su línea base).
2. **Re-render seguro del `CLAUDE.md` del workspace**: `--regenerate` deja siempre el render vigente en
   `.state/launcher/claude-md.upstream.md` y reemplaza `CLAUDE.md` solo si coincide con su línea base
   (`.state/launcher/claude-md.baseline.md`). Si tiene ediciones propias, se preserva.
3. **Aviso en la sesión**: un hook `SessionStart` (ambos modos) inyecta un aviso en el contexto de la
   sesión interactiva mientras haya pendientes, y `agentctl doctor` muestra un WARN por capa al operador.
   Las sesiones de heartbeat descartan el hook.

Medido el 30-09-2026: `additionalContext` de `SessionStart` llega al modelo al arrancar y al reanudar con
`--continue` (Claude Code 2.1.280), y una sesión reanudada carga el `CLAUDE.md` vigente del disco.

## Technical Context

**Language/Version**: bash 3.2–5.3 en host y modo local; bash del contenedor Alpine en modo docker. Mismo
piso que el resto del repo (sin constructos bash-4-only, sin `local LC_ALL=C`).

**Primary Dependencies**: `jq` (emitir el JSON del hook; ya requerido en host e imagen), `cmp`, `grep -F`,
`yq` v4+ (solo en `setup.sh`/`agentctl`, nunca en el hook). Claude Code con hooks `SessionStart` y
`additionalContext` (medido en 2.1.280; piso del launcher 2.1.170, ver research R1). Sin dependencias nuevas.

**Storage**: dos archivos por workspace en `.state/launcher/` (gitignoreado vía `/.state/`):
`claude-md.upstream.md` (derivado, se reescribe en cada regenerate) y `claude-md.baseline.md` (durable, se
mueve en cada escritura del launcher o confirmación del agente). Un campo nuevo en `agent.yml`:
`features.upgrade_notice.enabled` (default `true`, backfill `has()`).

**Testing**: bats en host para las dos funciones de detección, la decisión de regenerate, el hook
renderizado (ambos modos), el instalador, el aislamiento de heartbeat y doctor. `DOCKER_E2E=1` obligatorio
porque se toca `docker/scripts/start_services.sh` (image-baked). Mutación contra la implementación real.
Gate dual bash 3.2.57 y 5.3.x, secuencial.

**Target Platform**: workspaces scaffoldeados por el launcher, modos docker (Alpine, `claude --channels
--continue` en tmux) y local (systemd, `claude remote-control --spawn=session`).

**Project Type**: single project (CLI de scaffolding en bash), mismos tres caminos de código documentados en
`CLAUDE.md`.

**Performance Goals**: el hook termina en menos de 1 s y emite 0 bytes cuando no hay pendientes (SC-002). La
detección es O(número de deltas conocidos) más dos `cmp`, independiente del tamaño del vault.

**Constraints**: el hook nunca falla (exit 0 en todo camino, sin salida parcial) y nunca escribe; el
instalador es idempotente; `--regenerate` nunca aborta por esta feature y nunca sobrescribe un `CLAUDE.md`
editado sin `--force-claude-md`. Texto del aviso sin tildes (regla de bytes de 033/034/037).

**Scale/Scope**: dos deltas conocidos hoy (0.8.0, 0.27.0). La flota actual (5 agentes) no tiene línea base:
el primer regenerate post-038 reporta desfase en todos, y el operador fuerza el re-render una vez por agente.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.1).*

- [x] **I. Single Source of Truth** — PASS. `CLAUDE.md` sigue siendo un derivado de plantilla + `agent.yml` +
  persona; la feature lo acerca al principio (se re-renderiza cuando no tiene ediciones). El interruptor vive
  en `agent.yml`. El hook se renderiza desde plantilla y sobrevive `--regenerate`.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. Sin capabilities, mounts ni sockets nuevos. El hook corre
  como `agent` dentro del contenedor. En modo local corre como el operador, igual que la sesión (la violación
  justificada de 011 no cambia).
- [x] **III. Test-First, Host-Runnable** — PASS. Toda la lógica nueva es host-testeable (funciones puras +
  hook renderizado ejecutable con stdin falso). `DOCKER_E2E` cubre el cambio image-baked. `shellcheck -S error`
  limpio.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. Decisiones por `cmp -s` y presencia de marcadores, nunca
  por mtime. Instalador con dedupe por comando. Hook con exit 0 incondicional. Escrituras de `.state/launcher/`
  con `|| true`.
- [x] **V. Workspace-Is-the-Agent** — PASS. Todo vive dentro del workspace (`.state/launcher/`, `scripts/hooks/`),
  viaja con `rsync`, nunca se commitea. La pérdida de la línea base degrada a "sin línea base" (aviso
  conservador), nunca a pérdida de datos.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. Sin dependencias nuevas. `VERSION` 0.27.0→0.28.0 y
  `CHANGELOG.md` (cambio visible para el operador).

Re-check post-diseño: sin cambios. Complexity Tracking vacío.

## Project Structure

### Documentation (this feature)

```text
specs/038-schema-delta-boot-nudge/
├── plan.md              # Este archivo
├── research.md          # R1-R9: mecanismo, detección por capa, instalación, texto, doctor, gates
├── data-model.md        # Archivos de estado, tabla de hitos, máquina de estados del CLAUDE.md
├── quickstart.md        # Validación manual, DOCKER_E2E, mutación, gates de hardware, cierre
├── contracts/
│   ├── vault-pending-deltas.md   # Detección de la capa vault
│   ├── claude-md-refresh.md      # Detección y re-render de la capa workspace
│   └── upgrade-notice-hook.md    # Hook SessionStart, instalador, texto del aviso, doctor
├── checklists/requirements.md
└── tasks.md             # Fase 2 (/speckit-tasks), no creado aquí
```

### Source Code (repository root)

```text
scripts/lib/vault.sh                    # + vault_delta_versions, vault_delta_checkpoint,
                                        #   vault_pending_deltas (la imagen lo copia, Dockerfile:285)
scripts/lib/claude_md.sh                # NUEVO: claude_md_state, claude_md_regenerate_decision
setup.sh                                # regenerate(): render a upstream + decisión + línea base;
                                        #   backfill features.upgrade_notice; render del hook y su
                                        #   instalador; en modo local, instalar el hook
scripts/lib/schema.sh                   # + '.features.upgrade_notice.enabled' en _SCHEMA_BOOLEANS
modules/upgrade-notice.sh.tpl           # NUEVO → scripts/hooks/upgrade-notice.sh (hook SessionStart)
modules/upgrade-notice-install.sh.tpl   # NUEVO → scripts/hooks/install-upgrade-notice-hook.sh
modules/local-login.sh.tpl              # + paso 4e: registrar el hook (logins nuevos)
docker/scripts/start_services.sh        # + pre_install_upgrade_notice_hook en start_session
scripts/heartbeat/heartbeat.sh          # aislamiento: + del(.hooks.SessionStart)
scripts/agentctl                        # + _upgrade_notice_doctor, llamado desde doctor docker y local
tests/fixtures/sample-agent{,-with-vault}.yml   # + features.upgrade_notice
docs/vault.md, docs/architecture.md     # convención de hitos; render vigente y línea base
README.md                               # "Upgrade an existing agent"
CHANGELOG.md, VERSION                   # 0.27.0 → 0.28.0
CLAUDE.md                               # sección de arquitectura + entrada SPECKIT (git add -f)

tests/
├── vault-pending-deltas.bats           # NUEVO: matriz de detección + guardias de deriva de hitos
├── claude-md-refresh.bats              # NUEVO: librería claude_md.sh + decisión de regenerate, end-to-end
├── upgrade-notice-config.bats          # NUEVO: backfill/schema de features.upgrade_notice (molde 031)
├── upgrade-notice-hook.bats            # NUEVO: hook renderizado (docker/local), instalador, toggle
├── heartbeat-isolation.bats            # + SessionStart descartado
├── local-login-install.bats            # + paso 4e (registro del hook en el login local)
├── start-services-upgrade-notice.bats  # NUEVO: instalación en start_session, fail-silent
├── agentctl-doctor-upgrade-notice.bats # NUEVO: líneas WARN/PASS por capa, ambos modos
└── docker-e2e-upgrade-notice.bats      # NUEVO, DOCKER_E2E: boot real, hook instalado y ejecutado
```

**Structure Decision**: single project, sin directorios de alto nivel nuevos. El hook sigue el molde de 028
(Stop) y 031 (PreToolUse): plantilla del hook + instalador hermano propio + invocación en el boot docker y en
el login local. No se modifica ningún instalador existente.

## Complexity Tracking

*Vacío: sin violaciones de constitución que justificar.*
