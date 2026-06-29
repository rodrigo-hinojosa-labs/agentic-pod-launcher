# Implementation Plan: Modo agente local standalone (Linux/systemd)

**Branch**: `011-local-standalone-mode` | **Date**: 2026-06-28 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/011-local-standalone-mode/spec.md`

## Summary

Agregar un segundo **modo de despliegue** al wizard (`deployment.mode: docker|local` en `agent.yml`). El modo `docker` (recomendado) queda **byte-idéntico** a hoy. El modo `local` (opt-in, con advertencia de seguridad) renderiza la **base de config del agente en el host** (CLAUDE.md, `.mcp.json`, skills, vault, heartbeat.conf, RAG) **sin** `docker-compose.yml`/`Dockerfile`, y emite los artefactos del modo local: una **unit systemd** que mantiene viva una sesión `claude remote-control --name <name> --spawn=session --verbose`, su `EnvironmentFile`, un **helper de login guiado**, un **healthcheck** (con su timer) y un **kill-switch**, más `NEXT_STEPS` específicos.

**Alcance v1 (Thin — decidido en clarify):** la feature entrega el núcleo — elección de modo, render de la base, y la **persistencia de la sesión Remote Control** vía systemd (login guiado, trust, healthcheck, kill-switch, advertencias de seguridad). La **automatización del supervisor** que hoy vive image-baked en el contenedor (scheduling del heartbeat, auto-install de plugins, qmd watcher, backups) se **defiere a un follow-up**: en modo local el agente puede ejecutar esas tareas interactivamente vía Remote Control, pero no se portan los timers/watchers a systemd en v1.

**Restricción que define la arquitectura:** Remote Control exige token full-scope OAuth interactivo (one-time por host/usuario), incompatible con pods efímeros y sin vía headless. Por eso el modo local solo vive en un host/usuario persistente y el login es un paso manual guiado.

## Technical Context

**Language/Version**: Bash (host launcher, `bash` 4+); plantillas del render engine; unit systemd (Linux). Runtime del agente: Claude Code **>= 2.1.51** (requisito de Remote Control).

**Primary Dependencies**: `yq` v4+, `jq`, `git`, `gum` (opcional) en el host; `systemd` + `jq` en el host destino Linux; `claude` CLI con login full-scope.

**Storage**: `agent.yml` (única fuente de verdad). Estado del agente bajo `<workspace>/.state/` (Principio V). En modo local: `CLAUDE_CONFIG_DIR=<workspace>/.state/.claude` (login en `.state/.claude/.credentials.json`, gitignored).

**Testing**: `bats` host-side (sin Docker) con stubs-on-PATH (`systemctl`/`journalctl`/`jq`/`claude`); `shellcheck -S error`. DOCKER_E2E cubre la **no-regresión del modo docker**; el modo local (systemd/Linux) **no es ejercitable por DOCKER_E2E en macOS** → verificación host-side con stubs + gate manual en host Linux (procedimiento del operador, en quickstart).

**Target Platform**: Host del launcher: macOS/Linux. Persistencia del modo local: **Linux con systemd** (macOS/launchd fuera de alcance).

**Project Type**: CLI/IaC bash (el launcher) que emite artefactos de despliegue.

**Performance Goals**: Recuperación de sesión ≤ ~10 s tras caída (Restart + RestartSec=10). Healthcheck periódico (~5 min). Sin objetivos de throughput.

**Constraints**: opt-in, zero-touch salvo el login one-time; modo docker intacto; nunca `--dangerously-skip-permissions`; secretos nunca versionados ni en argv/journal; idempotente y `--regenerate`-safe.

**Scale/Scope**: v1 = **1 agente local por host** (naming/paths diseñados por-agente para multi futuro). Limitado por las sesiones concurrentes del plan de la cuenta.

## Constitution Check

*GATE. Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — `deployment.mode` y todo artefacto local se renderizan desde `agent.yml` vía `render.sh`; legacy sin la clave hace backfill a `docker`; sobrevive `--regenerate`. **PASS**.
- [ ] **II. Least-Privilege (NON-NEGOTIABLE)** — el modo local **no tiene contenedor**: no hay `cap_drop`/`no-new-privileges`; corre como el usuario del operador. **VIOLATION (justificada)** — ver Complexity Tracking. El modo docker queda **intacto** (Principio II preservado al 100% allí); el modo local es opt-in con advertencia + mitigaciones.
- [x] **III. Test-First, Host-Runnable** — cobertura `bats` host-side (schema, render de artefactos local, trust-merge, healthcheck con stubs); suite por defecto sin Docker; `shellcheck` limpio. Salvedad honesta: la integración real systemd/Linux no la cubre DOCKER_E2E desde macOS → gate manual en host Linux documentado. **PASS (con salvedad documentada)**.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — bootstrap/login-helper/trust-merge/healthcheck idempotentes (guard por contenido, no mtime); la unit usa `ExecCondition` (no arranca sin login → inactive, no failed) + `Restart=always`; el healthcheck degrada con gracia. **PASS**.
- [x] **V. Workspace-Is-the-Agent** — `CLAUDE_CONFIG_DIR` bajo `<workspace>/.state/.claude`; `.credentials.json` y `*.env` del modo local gitignored; nunca logueados. **PASS**.
- [x] **VI. Reproducible, Pinned Dependencies** — requisito explícito Claude `>= 2.1.51` (verificado por el bootstrap), `DISABLE_AUTOUPDATER=1` en el `EnvironmentFile`; `CHANGELOG.md` + bump de `VERSION`. **PASS**.

## Project Structure

### Documentation (this feature)

```text
specs/011-local-standalone-mode/
├── plan.md              # Este archivo
├── research.md          # Decisiones D1..D12 (Phase 0)
├── data-model.md        # agent.yml + entidades (Phase 1)
├── quickstart.md        # Flujo del operador local + gates manuales (Phase 1)
├── contracts/           # Contratos de artefactos local-mode (Phase 1)
│   ├── deployment-mode.md
│   ├── systemd-remote-control.md
│   └── local-cli.md
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
# Host-launcher (se edita)
setup.sh                                  # wizard mode-choice (~449-489) + agent.yml writer (~1075-1080)
                                          # + branch de render (~1901-1909) + install_service (~1933-1960)
                                          # + render_next_steps (~1296-1335) + backfill mode + --login helper
scripts/lib/schema.sh                     # _SCHEMA_ENUMS += '.deployment.mode=docker,local'
scripts/lib/render.sh                     # (sin cambios; DEPLOYMENT_MODE flatea solo)

# Plantillas (modules/) — NUEVAS para modo local
modules/systemd-remote-control.service.tpl   # NEW — unit de la sesión Remote Control
modules/remote-control.env.tpl               # NEW — EnvironmentFile (CLAUDE_CONFIG_DIR, DISABLE_AUTOUPDATER, HOME)
modules/local-healthcheck.sh.tpl             # NEW — alive/connected/expired
modules/local-healthcheck.service.tpl        # NEW — oneshot que corre el healthcheck
modules/local-healthcheck.timer.tpl          # NEW — timer ~5min
modules/local-killswitch.sh.tpl              # NEW — systemctl stop/disable
modules/local-login.sh.tpl                   # NEW — helper de login guiado + trust-merge + enable
modules/next-steps.en.tpl / next-steps.es.tpl # EDIT — {{#if DEPLOYMENT_MODE_IS_DOCKER}} / {{#unless}}
modules/docker-compose.yml.tpl               # (sin cambios; su render se omite en setup.sh para local)
modules/systemd.service.tpl                  # (sin cambios; sigue siendo el de docker)

# Tests (tests/) — test-first
tests/schema-validate.bats                # EDIT — deployment.mode enum (docker/local/bogus/absent)
tests/regenerate.bats                      # EDIT — backfill mode→docker + mode preservado + aviso de cambio de modo
tests/deployment-mode.bats                 # NEW — mode=local: sin compose/mirror, artefactos local presentes; mode=docker byte-idéntico
tests/local-render.bats                    # NEW — render de la unit/env/healthcheck/killswitch desde agent.yml
tests/local-healthcheck.bats               # NEW — OK/WARN/DEGRADED con stubs systemctl/journalctl/jq + .credentials.json
tests/local-trust-merge.bats               # NEW — merge idempotente de hasTrustDialogAccepted preservando .claude.json
```

**Structure Decision**: Se reutiliza el motor de render y el flujo del wizard existentes; el modo local **agrega** plantillas y **ramifica** los call-sites de render (no toca el camino docker). El branch se hace **en `setup.sh`** (omitir el `render_to_file` de `docker-compose.yml` + `mirror_catalog_to_docker` cuando `mode=local`), garantizando que el modo docker quede byte-idéntico (no se envuelve `docker-compose.yml.tpl` en condicionales).

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| **Principio II** — el modo local corre sin el contenedor de menor privilegio (sin `cap_drop ALL`/`no-new-privileges`), como el usuario del operador (hereda sus secretos). | Remote Control **exige** token full-scope OAuth interactivo, imposible en pods efímeros; el caso de uso (agente persistente controlable remotamente atado al SO) **requiere** host/usuario persistente. | Mantenerlo en contenedor NO habilita Remote Control (rechaza el token inference-only). Un contenedor con login full-scope persistente reintroduce el login interactivo por pod (inviable) y no es el caso de uso pedido. **Mitigaciones:** opt-in con advertencia explícita en el wizard; modo docker (recomendado) intacto; nunca `--dangerously-skip-permissions` (confirmaciones vivas); MFA obligatorio (documentado); `.credentials.json`/env gitignored; corre como usuario no-root; secretos fuera de argv/journal. |
| **Principio III (salvedad)** — la integración real systemd/Linux no la cubre DOCKER_E2E (que corre Alpine en macOS). | El modo local es Linux/systemd nativo; no hay contenedor que levantar para probarlo en el host del dev (macOS). | Forzar un e2e systemd en macOS no es posible. **Mitigación:** cobertura host-side exhaustiva con stubs (systemctl/journalctl/jq/claude) para toda la lógica (render, trust-merge, healthcheck, branching) + un **gate de verificación manual en host Linux** documentado en quickstart (el procedimiento ya validado en producción por el usuario en RPi5). |
