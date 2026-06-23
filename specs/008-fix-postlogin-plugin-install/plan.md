# Implementation Plan: Reparar auto-instalación de plugins post-login (DOCKER_E2E a verde)

**Branch**: `008-fix-postlogin-plugin-install` | **Date**: 2026-06-23 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/008-fix-postlogin-plugin-install/spec.md`

## Summary

Tres defectos encadenados detectados durante la validación E2E post-006/007 dejan `docker-e2e-postlogin` rojo (1/11): (1) `ensure_official_marketplace` (006) hace `claude plugin marketplace list | grep`, pero el stub `claude` del test (de 004) solo maneja `plugin install` → cae a `sleep 86400` → el pipe cuelga el boot antes del watchdog; (2) esa llamada no tiene timeout, así que un `claude` colgado brickea el boot sin recuperación; (3) `docker/scripts/lib/plugin-install.sh` (que define `retry_plugin_install_bounded`) llega al workspace por la copia wholesale del árbol `docker/` pero el Dockerfile no lo `COPY`a a la imagen → retry acotado muerto, path legacy. Plan: arreglar el stub (US1, devuelve E2E a verde), acotar las llamadas a `claude` con `timeout` y degradación (US2, Principio IV), y agregar la línea `COPY` faltante (US3). Test-first host-side para US2 y US3; validación final con rebuild + `DOCKER_E2E=1`.

## Technical Context

**Language/Version**: Bash (supervisor `docker/scripts/start_services.sh`, image-baked; `setup.sh` host-launcher); `bats-core` para tests; Dockerfile (Alpine 3.24.1, busybox `timeout`).

**Primary Dependencies**: busybox `timeout` (presente en la imagen Alpine); `claude` CLI (real en prod, stub en el E2E); `git`/`jq`/`yq` host-side.

**Storage**: N/A (sin estado persistente nuevo; el state file de fallas de plugin lo gestiona `plugin-install.sh` ya existente).

**Testing**: `bats tests/` host-side (sin Docker) para US2 (no-cuelgue/timeout de `ensure_official_marketplace`) y US3 (Dockerfile COPY + presencia en `<dest>` tras scaffold). `DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats` (y la suite E2E completa) para la validación de integración (US1, y US3 en runtime).

**Target Platform**: Imagen Alpine del agente (image-baked) + host del launcher. Cambios image-baked requieren rebuild para validar en runtime.

**Project Type**: CLI / bash tooling + contenedor. Single-project.

**Performance Goals**: El timeout de US2 es del orden de segundos (no debe ralentizar el boot normal; el happy path con `claude` real responde en <1s).

**Constraints**: Menor privilegio del contenedor intacto (Principio II, sin nuevas capabilities/mounts). Sobrevive `--regenerate`. Suite host-side verde. Sin pins duplicados nuevos. `timeout` con degradación a llamada directa si ausente.

**Scale/Scope**: ~1 línea en Dockerfile (US3); ~2-6 líneas en `ensure_official_marketplace` (US2); ~5-10 líneas en el stub del test (US1); 2 archivos de test nuevos/ampliados host-side; CHANGELOG + VERSION.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — **PASS**. No se edita output derivado a mano. `plugin-install.sh` y `start_services.sh` son image-baked (no derivados de `agent.yml`); el Dockerfile es image-baked. Nada que `--regenerate` produzca cambia su contrato. La copia wholesale de `docker/` y el render siguen igual.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — **PASS**. No se agregan capabilities, mounts ni socket. `timeout` es un binario ya presente; correr `claude` bajo `timeout` no cambia el modelo de privilegios (sigue como `agent`, `CLAUDE_CONFIG_DIR` intacto). Cambio bajo `docker/` revisado contra Principio II: sin impacto.
- [x] **III. Test-First, Host-Runnable** — **PASS**. US2 y US3 reciben tests host-side que fallan antes y pasan después (sin Docker). La suite por defecto debe quedar verde. US1 se valida con el E2E (gated `DOCKER_E2E=1`), que NO se requiere para la suite por defecto. `shellcheck -S error` debe quedar limpio en los `.sh` tocados (`start_services.sh`).
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — **PASS (central al feature)**. US2 hace `ensure_official_marketplace` resiliente: acota `claude` con `timeout`, degrada a llamada directa si `timeout` falta, permanece fail-silent (retorna 0, loguea WARN). US3 restaura el retry acotado (presupuesto/registro de fallas) que es justamente el mecanismo idempotente de 004. Ningún cambio puede colgar el supervisor (ese ERA el bug).
- [x] **V. Workspace-Is-the-Agent** — **N/A**. No toca `.state/`, secretos ni ramas de backup.
- [x] **VI. Reproducible, Pinned Dependencies** — **PASS**. No introduce pins nuevos ni duplicados. Cierra con `CHANGELOG.md` + bump `VERSION` 0.4.1 → 0.4.2.

**Resultado del gate: PASS (6/6).** Sin violaciones → Complexity Tracking vacío.

**Quality gates aplicables (Development Workflow):** Test gate (host bats verde + DOCKER_E2E para cambios en `docker/`/boot). Privilege gate (cambio en `docker/` revisado vs Principio II: OK). Documentation gate (CHANGELOG + VERSION). Regenerate-safety: el COPY y el supervisor son image-baked, no derivados.

## Project Structure

### Documentation (this feature)

```text
specs/008-fix-postlogin-plugin-install/
├── plan.md              # Este archivo (/speckit-plan)
├── research.md          # Fase 0 (/speckit-plan)
├── data-model.md        # Fase 1 (/speckit-plan)
├── quickstart.md        # Fase 1 (/speckit-plan)
├── contracts/
│   └── supervisor-marketplace-contract.md   # Contrato: ensure_official_marketplace acotado + stub
├── checklists/
│   └── requirements.md  # Creado por /speckit-specify
└── tasks.md             # Fase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
docker/scripts/start_services.sh   # US2: ensure_official_marketplace con timeout + degradación (image-baked)
docker/Dockerfile                  # US3: + COPY scripts/lib/plugin-install.sh (image-baked)
docker/scripts/lib/plugin-install.sh   # SIN CAMBIOS — define retry_plugin_install_bounded (ya existe)
setup.sh                           # SIN CAMBIOS en mirror — plugin-install.sh es image-only (ya en build context)
tests/docker-e2e-postlogin.bats    # US1: stub claude maneja plugin marketplace list/add + plugin list
tests/start-services-marketplace.bats   # US2 (NUEVO host-side): ensure_official_marketplace no cuelga / usa timeout
tests/docker-setup.bats            # US3 (AMPLIAR host-side): Dockerfile COPYa plugin-install.sh + presente en <dest>
CHANGELOG.md                       # entrada del feature
VERSION                            # 0.4.1 → 0.4.2
```

**Structure Decision**: Single-project. US1 es test-only (stub). US2 toca el supervisor image-baked + test host-side nuevo. US3 toca el Dockerfile (1 línea) + test host-side. `mirror_catalog_to_docker` NO se toca (verificado: `plugin-install.sh` es image-only y ya llega al build context vía la copia wholesale de `docker/`). Validación final requiere rebuild + `DOCKER_E2E=1`.

## Complexity Tracking

> Sin violaciones de la constitución. Tabla vacía a propósito.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| (ninguna) | — | — |
