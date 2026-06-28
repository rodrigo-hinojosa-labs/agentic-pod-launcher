# Implementation Plan: Instalación al boot de plugins de marketplaces de terceros

**Branch**: `009-fix-extra-marketplace-install` | **Date**: 2026-06-23 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/009-fix-extra-marketplace-install/spec.md`

## Summary

Los plugins declarados en `agent.yml` que viven en un marketplace de terceros (no `@claude-plugins-official`) no se autoinstalan al boot: el supervisor solo registra el marketplace de terceros editando `extraKnownMarketplaces` en `settings.json`, sin un `claude plugin marketplace add` confirmado, por lo que el `plugin install` posterior falla con "marketplace not registered yet" y queda en skip permanente (la sesión tmux estable no respawnea, así que nunca se reintenta). Enfoque (research D1–D3): añadir `ensure_extra_marketplaces` en `start_services.sh` que resuelve cada marketplace de terceros con `marketplace add` confirmado + `timeout` acotado, fail-silent e idempotente — espejo de `ensure_official_marketplace` — y encadenarla en `next_tmux_cmd` antes del loop de instalación. Test-first host-side + cobertura DOCKER_E2E del camino de terceros. CHANGELOG + VERSION 0.4.2 → 0.4.3.

## Technical Context

**Language/Version**: Bash (image-baked supervisor); busybox `timeout` en Alpine; `jq`.

**Primary Dependencies**: `docker/scripts/start_services.sh` (`ensure_official_marketplace`, `pre_accept_extra_marketplaces`, `next_tmux_cmd`, `ensure_all_plugins_installed`); `scripts/lib/plugin-catalog.sh` (`plugin_catalog_marketplaces_json`, espejado al build context); `docker/scripts/lib/plugin-install.sh` (`retry_plugin_install_bounded`, image-only, ya con su COPY desde 008).

**Storage**: N/A nuevo. Lee `/workspace/agent.yml` (fuente de verdad) y `~/.claude` (estado bajo `.state/`).

**Testing**: `bats` host-side (sourcing de `start_services.sh` con `START_SERVICES_NO_RUN=1`, patrón de `tests/start-services-marketplace.bats`); `DOCKER_E2E=1 bats tests/docker-e2e-*.bats` para integración. `shellcheck -S error`.

**Target Platform**: Imagen Alpine (runtime) + host macOS/Linux (tests). En macOS no existe `timeout` → shim en PATH en los tests.

**Project Type**: CLI launcher / supervisor de contenedor (shell).

**Performance Goals**: N/A estricto. El nuevo paso agrega a lo sumo un `marketplace add` (git clone) por marketplace de terceros, acotado por `MARKETPLACE_CMD_TIMEOUT` (default 12s) para no bloquear el boot.

**Constraints**: Nunca colgar el supervisor antes del watchdog (Principio IV); cero regresión del camino oficial; sobrevive `--regenerate`; menor privilegio intacto.

**Scale/Scope**: Cambio acotado: una función nueva (~25 líneas) + 1 línea de orden en `next_tmux_cmd`; 1 archivo de test host-side nuevo; extensión del e2e post-login; CHANGELOG + VERSION.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — el cambio es código image-baked (`start_services.sh`); no introduce ni edita a mano archivos derivados. La lista de marketplaces de terceros se deriva de `agent.yml` vía `plugin_catalog_marketplaces_json` (catálogo espejado por `mirror_catalog_to_docker`, que corre en `--regenerate`). Sobrevive `--regenerate`. **PASS**
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — sin cambios a `cap_drop`/`no-new-privileges`/mounts/sockets; el helper corre como `agent` dentro del supervisor (que ya corre como `agent`). **PASS**
- [x] **III. Test-First, Host-Runnable** — tests `bats` host-side escritos antes de implementar (US1/US2); corren sin Docker; integración gated tras `DOCKER_E2E=1`; `shellcheck -S error` limpio; el lib sourceado guarda init con `START_SERVICES_NO_RUN`. **PASS**
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — `ensure_extra_marketplaces` es idempotente (guard con `marketplace list | grep`), acota cada llamada a `claude` con `timeout` (degrada si ausente), siempre `return 0`, nunca cuelga el boot. **PASS**
- [x] **V. Workspace-Is-the-Agent** — sin cambios al ciclo de estado; no commitea ni loguea secretos (los fallos residuales pasan por el sanitizador existente). **PASS**
- [x] **VI. Reproducible, Pinned Dependencies** — sin nuevos pins ni duplicados; reusa `MARKETPLACE_CMD_TIMEOUT`. Cambio de comportamiento del boot → `CHANGELOG.md` + bump `VERSION` 0.4.2 → 0.4.3. **PASS**

**Resultado: 6/6 PASS, sin violaciones.** Complexity Tracking vacío.

## Project Structure

### Documentation (this feature)

```text
specs/009-fix-extra-marketplace-install/
├── plan.md              # Este archivo
├── research.md          # Phase 0 — decisiones D1–D5
├── data-model.md        # Phase 1 — entidades y estados
├── quickstart.md        # Phase 1 — reproducción y validación
├── contracts/
│   └── extra-marketplace-contract.md   # Contrato de ensure_extra_marketplaces
├── checklists/
│   └── requirements.md  # del /speckit-specify
└── tasks.md             # Phase 2 (/speckit-tasks — no creado aquí)
```

### Source Code (repository root)

```text
docker/scripts/start_services.sh        # + ensure_extra_marketplaces; orden en next_tmux_cmd
docker/scripts/lib/plugin-install.sh    # (sin cambios esperados; ya tiene COPY desde 008)
scripts/lib/plugin-catalog.sh           # (sin cambios; se reutiliza marketplaces_json)
tests/start-services-extra-marketplace.bats   # NUEVO — cobertura host-side US1/US2
tests/docker-e2e-postlogin.bats         # extensión: plugin de marketplace de terceros (US3)
CHANGELOG.md                            # entrada 009
VERSION                                 # 0.4.2 → 0.4.3
CLAUDE.md                               # marcador SPECKIT → este plan
```

**Structure Decision**: Cambio image-baked acotado al supervisor (`docker/scripts/start_services.sh`) + cobertura de tests (host-side nuevo + extensión e2e). No se tocan `setup.sh`, `modules/`, ni `scripts/lib/` (la derivación de marketplaces ya existe). `plugin-install.sh` permanece sin cambios salvo que el research D1 revele necesidad (no anticipada).

## Complexity Tracking

> Sin violaciones de la constitución. No aplica.
