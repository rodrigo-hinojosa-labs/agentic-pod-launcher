# Implementation Plan: Timeout configurable del watchdog del channel (docker)

**Branch**: `026-channel-watchdog-timeout` | **Date**: 2026-08-02 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/026-channel-watchdog-timeout/spec.md`

## Summary

Hacer configurable el timeout que `verify_channel_healthy()` espera a `bun server.ts` tras un lanzamiento `--channels`, hoy hardcodeado en 20s (`docker/scripts/start_services.sh:722`), que provoca flapeo de boot bajo contención de MCPs. El valor pasa a resolverse por un helper `channel_health_timeout()` que lee la variable de entorno del workspace `CHANNEL_HEALTH_TIMEOUT` (entregada al contenedor por `env_file`), con **default 60s** embebido en el script y degradación segura ante valores inválidos. El mensaje de log del watchdog pasa a nombrar el valor efectivo (FR-005). Al boot, si el timeout resuelto alcanza el umbral en que el crash budget deja de dar margen (~65s), se emite un WARN informativo una sola vez (decisión de usuario: WARN sin cap). Cambio **docker-only**, test-first (bats host + DOCKER_E2E), VERSION `0.16.0 → 0.17.0`.

## Technical Context

**Language/Version**: `bash` image-baked, debe correr en 3.2 (macOS stock, suite host) y 5.x (Alpine/CI). Sin construcciones bash-4-only.

**Primary Dependencies**: contenedor Alpine (`docker/`), entrega de env por `docker compose env_file`; `bats-core` para tests; `pgrep`/`sleep` (busybox en runtime, coreutils/BSD en test host).

**Storage**: N/A. Un valor de configuración vive en el `.env` user-owned del workspace; el default vive en el código image-baked.

**Testing**: `bats tests/` (host, sin Docker) sourceando `start_services.sh` con `START_SERVICES_NO_RUN=1`; `DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats` como gate de la cadena de entrega.

**Target Platform**: contenedor del agente (modo docker). El modo local (systemd) NO usa este watchdog — fuera de alcance.

**Project Type**: launcher/scaffolder shell (single project). Cambio en `docker/scripts/` (runtime image-baked) + `tests/` + docs.

**Performance Goals**: el channel aparece en ~3s en calma; ~22-25s bajo contención medida (ferrari). El default 60s cubre ese pico con ~2.5x de margen.

**Constraints**: interacción con el crash budget (`MAX_CRASHES=5`, `WINDOW=300`, `start_services.sh:245-246`): un timeout `≥70s` haría que el 5º fallo consecutivo caiga fuera de la ventana → el backstop no escala a restart de contenedor. El default 60 es seguro (5º fallo a ~260s < 300s). El WARN cubre los overrides que crucen el umbral.

**Scale/Scope**: acotado — 1 función tocada + 1 helper nuevo + 1 WARN de boot + cobertura bats + 1 assert de test cruzado a actualizar + docs + VERSION/CHANGELOG.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.1). Mark each PASS / N/A / VIOLATION.*

- [x] **I. Single Source of Truth** — PASS. No se agrega campo a `agent.yml` ni se toca `render.sh`/schema (decisión FR-007, precedente `TELEGRAM_TYPING_MAX_MS`). El default vive en el script image-baked (se materializa al rebuild); el override vive en el `.env` user-owned, que `--regenerate` NO reescribe (verificado: escrituras de `.env` solo en wizard `:1251`, scaffold-move `:1899`, restore-fork `:1742`; ninguna en `regenerate()` `:1941+`). El cambio sobrevive `--regenerate` por construcción (no hay derivado nuevo que regenerar).
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. Solo se introduce una variable de entorno leída dentro del contenedor; no se tocan `cap_drop`/`cap_add`/`no-new-privileges`, ni se agregan mounts/sockets. Ningún `docker exec` nuevo.
- [x] **III. Test-First, Host-Runnable** — PASS. La lógica se cubre con `bats` sourceando `verify_channel_healthy`/`channel_health_timeout` (host, sin Docker) — RED antes del cambio; el guard `START_SERVICES_NO_RUN`+`BASH_SOURCE` (`:1210`) garantiza source sin efectos. Un test de `crash_budget_check` valida el umbral `T<70`. DOCKER_E2E (`docker-e2e-postlogin.bats`) cubre la entrega `.env → env_file`. `shellcheck -S error` limpio.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. El helper degrada a 60 ante valor ausente/vacío/no-numérico/≤0; nunca falla el boot. El WARN es informativo (no aborta). Re-ejecutable sin efectos.
- [x] **V. Workspace-Is-the-Agent** — PASS. El override vive en el `.env` (user-owned, gitignored, `0600`); no toca `.state/`, no se commitea ni loguea el valor como secreto (no lo es). Backups intactos.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. `VERSION` bump `0.16.0 → 0.17.0` + entrada en `CHANGELOG.md` (`### Fixed`). El default embebido no introduce un pin duplicado nuevo; es la única fuente del valor por defecto.

**Resultado**: 6/6 PASS. Sin violaciones → Complexity Tracking vacío.

## Project Structure

### Documentation (this feature)

```text
specs/026-channel-watchdog-timeout/
├── plan.md              # Este archivo
├── research.md          # Fase 0 (workflow de 5 investigadores + síntesis)
├── data-model.md        # Fase 1
├── quickstart.md        # Fase 1
├── contracts/           # Fase 1
│   └── channel-health-timeout.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Fase 2 (/speckit-tasks — NO creado por /speckit-plan)
```

### Source Code (repository root)

```text
docker/scripts/start_services.sh     # verify_channel_healthy (:721-732), start_session (:758-763),
                                      #   comentario (:719-720), + helper channel_health_timeout() nuevo,
                                      #   + WARN de boot en main() (:1191+)
tests/
├── start-services-watchdog.bats     # + tests de channel_health_timeout / verify_channel_healthy
│                                     #   (seam: START_SERVICES_NO_RUN=1, stub pgrep+sleep)
├── docker-render.bats               # :162 assert "never appeared within 20s" → actualizar al mensaje dinámico
└── docker-e2e-postlogin.bats        # + verificación de entrega CHANNEL_HEALTH_TIMEOUT (gate DOCKER_E2E)

README.md                            # doc de CHANNEL_HEALTH_TIMEOUT junto a TELEGRAM_TYPING_MAX_MS
CLAUDE.md                            # Watchdog state machine (:67-75): verify timeout + crash budget
docs/architecture.md                 # pseudocódigo del watchdog (:112-121)
CHANGELOG.md                         # entrada ### Fixed
VERSION                              # 0.17.0
```

**Structure Decision**: no hay estructura nueva. Es una modificación quirúrgica del runtime image-baked (`docker/scripts/start_services.sh`) más su cobertura de test y documentación. `start_services.sh` no está espejado en `scripts/lib/` (una sola copia, `docker/Dockerfile:231`), así que no requiere mirror; el gate DOCKER_E2E aplica por ser cambio de boot/supervisor.

## Complexity Tracking

*Sin violaciones de constitución. Sección vacía.*

## Decisiones de diseño cerradas (de research + clarify)

1. **Variable**: `CHANNEL_HEALTH_TIMEOUT`, segundos, default 60.
2. **Resolución**: helper `channel_health_timeout()` (lectura call-time, valida `^[0-9]+$` sin comillas + `>0`, fallback 60). Único punto de verdad para `:722` y `:760`.
3. **Log honesto (FR-005)**: `:760` interpola `$(channel_health_timeout)s`; `tests/docker-render.bats:162` se actualiza al mismo tiempo.
4. **WARN de boot (crash budget, decisión usuario D)**: en `main()`, si el timeout resuelto ≥ umbral (candidato 65s, bajo el punto de ruptura 70s), un WARN una-vez; sin cap; no toca el crash budget. Un test de `crash_budget_check` valida el umbral `T<70`.
5. **Docker-only**: sin mirror; gate DOCKER_E2E vía `docker-e2e-postlogin.bats`.
6. **Retiro del override de ferrari**: post-deploy, preservando `CHANNEL_HEALTH_TIMEOUT=90` en `.env` (ver `research.md` (f); forma del override confirmada por conocimiento directo).
7. **Docs**: README/CLAUDE.md/architecture.md; NO `env-example.tpl`.
8. **VERSION/CHANGELOG**: `0.17.0`, `### Fixed`.
