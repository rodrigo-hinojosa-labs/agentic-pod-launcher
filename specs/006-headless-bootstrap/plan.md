# Implementation Plan: Headless bootstrap — token auth, marketplace, onboarding

**Branch**: `006-headless-bootstrap` | **Date**: 2026-06-22 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/006-headless-bootstrap/spec.md`

## Summary

Un agente scaffoldeado no arranca operativo sin intervención: el `/login` interactivo no persiste el credential bajo VirtioFS (incoherencia de cache de `~/.claude` en el bind-mount `./.state:/home/agent`). El enfoque, validado empíricamente en `rodri-cenco-admin`, es autenticación headless por `CLAUDE_CODE_OAUTH_TOKEN` (de `claude setup-token`) inyectado vía el `.env` que docker-compose ya carga con `env_file`. Sobre esa base, el feature cierra los tres gaps de bootstrap que el login roto ocultaba: (1) el supervisor reconoce el token y no cae al flujo `/login` ni dispara kicks espurios; (2) registra el marketplace oficial `anthropics/claude-plugins-official` de forma idempotente en boot para que los plugins/canal instalen; (3) pre-siembra el onboarding (theme/trust) para no bloquear la sesión headless; más una corrección de observabilidad (distinguir "marketplace not found" de "not authenticated"). El path interactivo `/login` se preserva como fallback; mover `~/.claude` a un named volume queda fuera de v1.

## Technical Context

**Language/Version**: Bash 4+ (host launcher) y POSIX `sh` (entrypoint) en Alpine; `claude` CLI **2.1.170** (pineado, auto-updater off); `yq` v4, `jq`, `git`, BSD/GNU `sed`.

**Primary Dependencies**: `docker/scripts/start_services.sh` (supervisor image-baked), `docker/scripts/lib/plugin-install.sh`, `scripts/lib/plugin-catalog.sh`, `setup.sh` (.env writer + wizard), `scripts/lib/wizard.sh` + `wizard-gum.sh`, `modules/env-example.tpl`, `modules/next-steps.{en,es}.tpl`, `scripts/lib/render.sh`.

**Storage**: `<workspace>/.env` (0600, gitignored) para `CLAUDE_CODE_OAUTH_TOKEN` (secreto, también en backup/identity cifrado `.env.age`); `~/.claude/.claude.json` para estado de onboarding (image/runtime, no derivado); registro del marketplace en `~/.claude/settings.json` (user scope) vía `claude plugin marketplace add`.

**Testing**: `bats tests/` (host, sin Docker) como suite por defecto; e2e gateado con `DOCKER_E2E=1`. Seams existentes: `tests/watchdog-auth-flip-detection.bats`, `tests/start-services-watchdog.bats`, `tests/start-services-plugin-install.bats`, `tests/modules-render.bats`, `tests/schema-validate.bats`. `shellcheck -S error` limpio.

**Target Platform**: host macOS (BSD) + Linux (GNU) para el launcher; contenedor Alpine 3.20 para el runtime.

**Project Type**: single-project launcher (CLI/bash con tres code paths: host-launcher, image-baked, workspace-templated).

**Performance Goals**: el registro del marketplace y la instalación de plugins corren en el boot path del watchdog (poll 2s, crash budget 5/300s); el `marketplace add` clona vía git con timeout interno (~120s observado) y debe ser fail-silent para no agotar el budget.

**Constraints**: el token es secreto (nunca en `agent.yml`, logs ni `.env.example` con valor); cambios sobreviven `--regenerate`; least-privilege (cap_drop ALL, correr como `agent` con `CLAUDE_CONFIG_DIR`); valores dependientes de versión (slug marketplace, keys onboarding) verificados contra 2.1.170, no inventados.

**Scale/Scope**: ~6 archivos de producto tocados + cobertura bats; 4 user stories (P1 auth, P2 marketplace, P3 onboarding, P4 log); cero cambios de schema `agent.yml` (el token no es un campo de agent.yml).

## Constitution Check

*GATE: pasa antes de Phase 0. Re-evaluado tras Phase 1. Fuente: constitution.md v1.0.0.*

- [x] **I. Single Source of Truth** — el token es secreto y vive en `.env` (no es un campo de `agent.yml`, igual que los demás secretos), así que no toca el schema ni rompe el modelo. Los outputs derivados que cambian (`.env.example` desde `modules/env-example.tpl`, NEXT_STEPS desde `next-steps.{en,es}.tpl`) se renderizan vía `render.sh` desde templates — no se editan a mano. `start_services.sh` es image-baked (código de la imagen, no archivo derivado), igual que toda la lógica de supervisor existente. El `.env` con el token sobrevive `--regenerate` (regenerate re-renderiza derivados, no borra `.env`). **PASS**.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — sin nuevas capabilities, mounts ni socket; `marketplace add`/`plugin install`/pre-seed corren como `agent` con `CLAUDE_CONFIG_DIR=/home/agent/.claude` (el patrón existente); no se debilita `cap_drop: ALL`/`no-new-privileges`. **PASS**.
- [x] **III. Test-First, Host-Runnable** — cada cambio tiene seam host-bats (helper `has_oauth_token`, decisión `next_tmux_cmd`, baseline `_check_auth_flip`, registro idempotente del marketplace, clasificación marketplace-not-found, pre-seed onboarding, render de `.env.example`). Tests escritos antes (red→green). Default sin Docker; un e2e opcional gateado con `DOCKER_E2E=1`. `shellcheck -S error` limpio; libs guardadas con `BASH_SOURCE`/`START_SERVICES_NO_RUN`. **PASS**.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — `ensure_official_marketplace` guarda con `marketplace list` (no re-registra) y tolera clone fallido (`|| true` + WARN, no bloquea el tick); `pre_seed_onboarding` crea `.claude.json` si falta y es idempotente; el guard del token es lectura pura de una env var. Ninguno crashea el supervisor. **PASS**.
- [x] **V. Workspace-Is-the-Agent** — el token vive en `<workspace>/.env` (gitignored, 0600) y en el backup de identity cifrado; nunca se commitea ni loguea. NO se introduce named volume (out of scope), preservando el modelo bind-mount y el flujo `--restore-from-fork`. **PASS**.
- [x] **VI. Reproducible, Pinned Dependencies** — el slug del marketplace oficial se single-sources como constante junto a `REQUIRED_CHANNEL_PLUGIN` (sin duplicar literales); no se tocan pins de toolchain (auto-updater sigue off); `CHANGELOG.md` + `VERSION` se actualizan (cambio user-facing). **PASS**.

**Resultado: 6/6 PASS. Sin violaciones → Complexity Tracking vacío.**

## Project Structure

### Documentation (this feature)

```text
specs/006-headless-bootstrap/
├── plan.md              # Este archivo
├── research.md          # Phase 0 — decisiones verificadas (slug marketplace, onboarding keys, token contract)
├── data-model.md        # Phase 1 — entidades (token, marketplace, onboarding state)
├── quickstart.md        # Phase 1 — escenarios de validación
├── contracts/
│   └── shell-functions.md   # Contratos de las funciones shell nuevas/cambiadas
├── checklists/
│   └── requirements.md  # Spec quality checklist (de /speckit-specify)
└── tasks.md             # Phase 2 (/speckit-tasks — NO creado por /speckit-plan)
```

### Source Code (repository root)

```text
docker/scripts/
├── start_services.sh            # has_oauth_token (nuevo); guard en next_tmux_cmd (Case A);
│                                #   short-circuit en _check_auth_flip; ensure_official_marketplace
│                                #   (nuevo) en pre_accept_extra_marketplaces; pre_seed_onboarding
│                                #   (nuevo) + relax de pre_accept_bypass_permissions (crear settings.json)
└── lib/
    └── plugin-install.sh        # clasificar "marketplace not found" distinto de auth-skip

scripts/lib/
└── plugin-catalog.sh            # (referencia) constante del marketplace oficial — single source

setup.sh                          # wizard: paso "Claude authentication"; .env writer: línea CLAUDE_CODE_OAUTH_TOKEN
modules/
├── env-example.tpl              # placeholder comentado CLAUDE_CODE_OAUTH_TOKEN=
├── next-steps.en.tpl            # path headless (recomendado) + /login fallback
└── next-steps.es.tpl            # ídem en español

tests/                            # bats host (test-first)
├── watchdog-auth-flip-detection.bats   # + caso: token presente → sin kick
├── start-services-watchdog.bats        # + next_tmux_cmd con token → no bare /login
├── start-services-plugin-install.bats  # + marketplace-add idempotente; marketplace-not-found ≠ auth
├── start-services-onboarding.bats      # NUEVO: pre_seed_onboarding crea/idempotente
├── modules-render.bats                 # + .env.example expone CLAUDE_CODE_OAUTH_TOKEN
└── (setup .env-writer test)            # token escrito a .env 0600 cuando provisto / ausente si no

CHANGELOG.md · VERSION             # bump (0.3.1 → 0.4.0, feature)
```

**Structure Decision**: single-project launcher. Los cambios se reparten entre image-baked (`docker/scripts/`), host-launcher (`setup.sh`, `modules/`, `scripts/lib/`) y tests host (`tests/`), respetando los tres code paths. Sin nuevos módulos ni reestructuración.

## Complexity Tracking

*Constitution Check 6/6 PASS — sin entradas.*
