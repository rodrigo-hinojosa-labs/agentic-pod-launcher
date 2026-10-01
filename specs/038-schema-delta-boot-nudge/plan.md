# Implementation Plan: Aviso automatico de integracion de delta al arrancar

**Branch**: `038-schema-delta-boot-nudge` | **Date**: 2026-09-30 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/038-schema-delta-boot-nudge/spec.md`

**Nota de rama base**: ramificada sobre `037-second-brain-rag` (VERSION 0.27.0), no sobre `main`
(0.26.0) — ver la nota al inicio de spec.md. El PR de esta feature espera a que 037 mergee primero.

## Summary

Cuando un agente sube de version y queda un delta de schema del vault depositado sin integrar (el
caso medido: donna, 30-09-2026, describiendo su RAG con el modelo pre-037 porque nadie le aviso del
delta 0.27.0), el sistema lo nota por su cuenta y se lo hace saber al agente de forma proactiva. Se
construye una funcion de deteccion compartida (`vault_pending_deltas`, nueva en
`scripts/lib/vault.sh`) reusada por dos superficies: un disparo ACTIVO de heartbeat en el boot de
un agente docker (mismo mecanismo `HEARTBEAT_TRIGGER` que el aviso semanal de PARA de 037, pero de
una sola vez, gatillado desde `start_services.sh::boot_side_effects`, no por cron), y una linea
PASIVA nueva en `agentctl doctor`/`status` (ambos modos) para cuando no hay canal de notificacion
separado (modo local) o como respaldo si el aviso activo se perdio.

## Technical Context

**Language/Version**: bash 3.2+ (host/local), Alpine ash-compatible bash en el contenedor (docker)
— mismo piso que el resto del repo.

**Primary Dependencies**: `yq` v4+, `jq`, `grep -F`, el propio `scripts/heartbeat/heartbeat.sh` y
`docker/scripts/heartbeatctl` ya existentes (037). Sin dependencias nuevas.

**Storage**: dos marcadores de archivo nuevos (`_templates/.schema-updates-{version}.nudged`, solo
docker); sin base de datos, sin campos nuevos en `agent.yml`.

**Testing**: `bats` (host, sin Docker, para `vault_pending_deltas` y el dispatch de
`start_services.sh` via `START_SERVICES_NO_RUN=1`), `DOCKER_E2E=1` (obligatorio — toca
`docker/scripts/start_services.sh`, image-baked, requiere COPY en el Dockerfile ya existente para
`scripts/lib/vault.sh`).

**Target Platform**: agentes scaffolded por el launcher, ambos modos (docker/local).

**Project Type**: single project (bash CLI/scaffolding tool) — mismo que el resto del repo.

**Performance Goals**: la deteccion (`vault_pending_deltas`) debe ser O(numero de deltas conocidos)
en filesystem ops, independiente del tamano del vault — debe poder correr sincronicamente dentro de
`agentctl doctor` incluso sobre un vault de miles de paginas sin percance notable (SC-004).

**Constraints**: el dispatch del aviso activo NUNCA debe bloquear ni retrasar el arranque del
contenedor (mismo presupuesto de boot-resilience que protege 036); debe ser fail-soft ante
cualquier fallo (FR-006, SC-005).

**Scale/Scope**: hoy existe UNA version de delta con deteccion (`0.27.0`); la tabla de
`vault_pending_deltas` se disena para soportar mas de una sin cambios estructurales (FR-008), pero
no hay una segunda version real que probar hoy — se documenta en quickstart.md como limite conocido
del alcance de pruebas actual.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.1).*

- [x] **I. Single Source of Truth** — PASS. No hay derivado nuevo desde `agent.yml`; los dos
  marcadores y la linea de doctor son runtime, no rendering. Nada que sobreviva/no sobreviva
  `--regenerate` porque no hay plantilla involucrada.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. Sin capabilities nuevas, sin mounts, sin
  socket. El turno de heartbeat corre exactamente como los turnos existentes (misma isolation de
  `CLAUDE_CONFIG_DIR`).
- [x] **III. Test-First, Host-Runnable** — PASS (comprometido en quickstart.md/tasks.md): suite
  host sin Docker cubre la deteccion y el dispatch via stubs; `DOCKER_E2E=1` cubre el boot real
  image-baked; `shellcheck -S error` limpio.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS por diseno: guardas explicitas por sentinel
  (`.nudged`), nunca por mtime; el dispatch es backgroundeado y con `|| true` en la escritura del
  marcador; el chequeo de doctor nunca falla (`vault_pending_deltas` siempre exit 0).
- [x] **V. Workspace-Is-the-Agent** — PASS. El marcador nuevo vive bajo `_templates/` dentro del
  vault (bind-mounted, ya dentro de `.state/` o el workspace segun modo) — mismo lugar que
  `.applied`. Nada nuevo bajo `.state/` que no sea ya parte del vault existente.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS/N/A. Sin dependencias nuevas que pinnear.
  `CHANGELOG.md`/`VERSION` se actualizan como corresponde a un cambio user-facing.

Sin violaciones. Complexity Tracking vacio.

## Project Structure

### Documentation (this feature)

```text
specs/038-schema-delta-boot-nudge/
├── plan.md              # Este archivo
├── research.md          # R1-R5: deteccion compartida, disparo docker, disparo local, prompt, tests
├── data-model.md        # Marcador .nudged; sin entidades persistentes nuevas
├── quickstart.md         # Validacion manual, DOCKER_E2E, tabla de mutacion, gate de hardware
├── contracts/
│   ├── vault-pending-deltas.md          # Funcion compartida de deteccion
│   └── schema-delta-notice-delivery.md  # Las dos superficies de entrega (activa/pasiva)
└── tasks.md              # Fase 2 (/speckit-tasks) — no creado por /speckit-plan
```

### Source Code (repository root)

```text
scripts/lib/vault.sh                        # + vault_pending_deltas, _vault_delta_known_versions,
                                             #   _vault_delta_checkpoint_text (nuevo, junto a
                                             #   vault_seed_missing — no lo modifica)
docker/scripts/lib/vault.sh                 # espejo (COPY del Dockerfile, ya existente para esta lib)
docker/scripts/start_services.sh            # boot_side_effects(): + dispatch del aviso activo
docker/scripts/heartbeatctl                 # + heartbeat_schema_delta_prompt_default (molde de
                                             #   heartbeat_review_prompt_default)
scripts/agentctl                            # _local_vault_qmd_doctor() + equivalente docker-mode:
                                             #   + linea WARN pasiva

tests/
├── vault-schema-delta-nudge.bats           # nuevo: vault_pending_deltas (host, sin Docker)
├── start-services-schema-delta.bats        # nuevo: dispatch + sentinel via START_SERVICES_NO_RUN=1
├── agentctl-doctor-schema-delta.bats       # nuevo, o extension del bats de doctor existente
└── docker-e2e-schema-delta-nudge.bats      # nuevo, DOCKER_E2E — o extension de docker-e2e-vault.bats
```

**Structure Decision**: single project, sin nuevos directorios de alto nivel — la feature es
puramente aditiva dentro de la estructura de tres-codepaths ya documentada en `CLAUDE.md`
(host-side lib compartida, image-baked docker/, runtime local via `scripts/agentctl`).

## Complexity Tracking

*Vacio — sin violaciones de constitucion que justificar.*
