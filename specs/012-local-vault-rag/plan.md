# Implementation Plan: Vault + RAG operativos en modo local (Linux/systemd)

**Branch**: `012-local-vault-rag` | **Date**: 2026-07-04 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/012-local-vault-rag/spec.md`

## Summary

Portar el subsistema vault/RAG al modo local standalone (feature 011): siembra host-side del skeleton, remap del MCP vault, pipeline QMD completo (setup first-run auto-sanador + timer systemd de reindex + watcher inotify como unit) y backup periódico a `backup/vault` por timer. La lógica existente (`qmd_index.sh`, `qmd_watch.sh`, `backup_vault.sh`) es portable vía sus env-overrides; el trabajo es **reubicar las libs a fuente canónica host-side** (patrón `vault.sh`: canónico en `scripts/lib/`, espejo al `docker/` del workspace en scaffold/regenerate), **renderizar units/timers/entrypoints** desde `agent.yml`, y **cablear** los puntos de enganche del ciclo de vida local de 011 (install_service staged, `--login`, kill-switch, uninstall, agentctl). Docker queda byte-idéntico en comportamiento (DOCKER_E2E lo prueba).

**Deuda que cierra**: brecha FR-004 de 011 (spec-vs-código) + deferral formal de `specs/011/plan.md:11` (qmd watcher, backups) — solo la porción vault/qmd/backup-vault.

## Technical Context

**Language/Version**: Bash (host: compatible bash 3.2 macOS para el launcher; entrypoints/units corren en Linux con bash 4+). Sin lenguajes nuevos.

**Primary Dependencies**: systemd (units/timers, solo Linux — igual que 011); `yq` v4, `jq`; `bun`/`bunx` (pin 1.3.14, ya provisto por `agent-bootstrap.sh`); `@tobilu/qmd` (pin single-source `vault.qmd.version`, default 2.5.3); `inotify-tools` (opcional — degrada al timer backstop); `git` (backup); `flock`/`timeout` de util-linux (opcionales, degradan igual que en docker).

**Storage**: vault en `<ws>/<vault.path>` (default `.state/.vault`); índice QMD en `<ws>/.state/.cache/qmd/` (regenerable, NO respaldado); state files `qmd-index.json` / `vault-backup.json` en `<ws>/scripts/heartbeat/`; cache de clones de backup en `~/.cache/agent-backup` (override `VAULT_BACKUP_CACHE_DIR`).

**Testing**: bats-core host-side (stubs de `systemctl`/`journalctl`/`bunx`/`inotifywait`/`git` — patrón establecido en `tests/local-*.bats`, `tests/qmd-*.bats`, `tests/backup-vault-*.bats`); `shellcheck -S error` sobre scripts renderizados; `DOCKER_E2E=1` para la reubicación de libs (imagen se construye desde un workspace scaffoldeado — el espejo debe reproducir el árbol actual); gate manual en mclaren (Raspberry Pi 5, Debian trixie, arm64) al volver el host.

**Target Platform**: launcher en macOS/Linux; runtime local en Linux/systemd only (heredado de 011).

**Project Type**: CLI/launcher bash + plantillas (single project).

**Performance Goals**: SC-002 — índice respondiendo ≤15 min post-primer-login; edición de `.md` reflejada ≤2 min con watcher activo (debounce ~15 s + reindex).

**Constraints**: docker byte-idéntico (SC-003); cero artefactos con vault/qmd off (SC-005); nunca bloquear `--login` (setup backgroundeado); `--regenerate` reproduce todo (Principio I); sin secretos en argv/journal.

**Scale/Scope**: 1 agente por host (heredado); vault típico < algunos miles de `.md`; índice+modelos ~300 MB.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — PASS. Units/timers/entrypoints nuevos son `modules/local-*.tpl` renderizados desde `agent.yml`; la conversión cron→systemd se computa en render-time desde `vault.qmd.schedule`/`vault.backup_schedule` (sin claves paralelas); siembra y espejos corren en scaffold Y regenerate. Nada editado a mano sobrevive por diseño.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. Cero cambios al modelo del contenedor (`cap_drop`, crond, exec `-u agent` intactos). El modo local opera bajo la violación justificada y acotada de 011 (opt-in, usuario del operador); esta feature NO amplía privilegios: units nuevas corren como `User={{OPERATOR_USER}}`, sin sudo en runtime.
- [x] **III. Test-First, Host-Runnable** — PASS. Bats host-side ANTES de implementar para cada contrato nuevo (ver quickstart/tasks); suite default sin Docker; DOCKER_E2E gated para el espejo de libs; `shellcheck -S error` sobre renders; libs siguen sin side effects al source (guard `BASH_SOURCE` preservado).
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. Se preservan los mecanismos existentes: sentinel `.qmd-setup-ok`, flock + hash-debounce del reindex, hash del backup, siembra `vault_seed_if_empty` (no-op si poblado). Entrypoints nuevos siempre exit 0 en no-op/degradación; el setup nunca rompe `--login`.
- [x] **V. Workspace-Is-the-Agent** — PASS. Todo estado nuevo bajo `<ws>/.state/` o `<ws>/scripts/heartbeat/`; índice QMD regenerable NO respaldado (Constitution V de 010); ramas de backup independientes intactas; `--restore-from-fork` no cambia; secretos jamás versionados/logueados.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. Sin pins nuevos (reusa qmd 2.5.3 single-source y bun 1.3.14 del bootstrap); sin duplicación de pins; `CHANGELOG.md` + `VERSION` 0.5.0 → 0.6.0.

**Post-diseño (re-check)**: sin cambios — el diseño de Phase 1 no introdujo violaciones nuevas.

## Project Structure

### Documentation (this feature)

```text
specs/012-local-vault-rag/
├── plan.md              # Este archivo
├── research.md          # Phase 0 — decisiones consolidadas (auditoría + clarify)
├── data-model.md        # Phase 1 — entidades, state files, variables de render
├── quickstart.md        # Phase 1 — gate manual Linux (mclaren)
├── contracts/
│   ├── lib-relocation.md        # Contrato de reubicación + espejo de libs
│   ├── local-qmd-pipeline.md    # Units qmd + entrypoint + conversión cron→systemd
│   └── local-vault-backup.md    # Unit backup + resolución de vault root por modo
└── tasks.md             # Phase 2 (/speckit-tasks — NO creado por /speckit-plan)
```

### Source Code (repository root)

```text
scripts/lib/                       # + qmd_index.sh, backup_vault.sh (git mv desde docker/scripts/lib/)
scripts/                           # + qmd_watch.sh (git mv desde docker/scripts/)
scripts/lib/local_schedule.sh      # NUEVO: cron→systemd (formas comunes + fallback, puro, testeable)
modules/
├── mcp-json.tpl                   # remap arg del MCP vault por modo (patrón #if/#unless)
├── local-qmd-reindex.sh.tpl       # NUEVO entrypoint: setup-if-needed + reindex (env overrides)
├── local-qmd-reindex.service.tpl  # NUEVO oneshot
├── local-qmd-reindex.timer.tpl    # NUEVO timer (schedule convertido)
├── local-qmd-watch.service.tpl    # NUEVO Restart=always
├── local-vault-backup.sh.tpl      # NUEVO entrypoint backup
├── local-vault-backup.service.tpl # NUEVO oneshot
├── local-vault-backup.timer.tpl   # NUEVO timer
└── local-login.sh.tpl             # + dispatch setup qmd en background + units staged nuevas
setup.sh                           # siembra local del vault; espejo de las 3 libs a <dest>/docker/;
                                   # render de units/entrypoints; install_service/uninstall/killswitch
scripts/agentctl                   # status/doctor: units vault/qmd + qmd-index.json (FR-013)
docker/scripts/{lib/qmd_index.sh,lib/backup_vault.sh,qmd_watch.sh}   # ELIMINADOS del repo
                                   # (el espejo de scaffold/regenerate los recrea en el workspace docker)
tests/
├── local-vault-seed.bats          # NUEVO: siembra host-side (lib real, sin stubs de systemd)
├── local-qmd.bats                 # NUEVO: entrypoint + units + conversión (stubs)
├── local-vault-backup.bats        # NUEVO: entrypoint + resolución local (fork = repo git local)
├── local-schedule.bats            # NUEVO: tabla de conversión cron→systemd
├── mcp-json.bats                  # + caso vault path local
├── local-login-install.bats       # + setup qmd dispatch + units staged nuevas
├── agentctl-local.bats            # + status/doctor vault/qmd
└── qmd-*.bats / backup-vault-*.bats / vault.bats   # intactos salvo path de load_lib
```

**Structure Decision**: la feature invierte la relación de propiedad de las libs qmd/backup — de image-baked (docker/scripts/) a host-canónicas (scripts/lib/) con espejo al build context del workspace, exactamente como `vault.sh` (verificado: `docker/scripts/lib/vault.sh` NO existe checked-in; el scaffold lo copia a `<dest>/docker/scripts/lib/` en `setup.sh:1501-1535` y el Dockerfile lo COPY-a desde ese build context). Esto hace que las libs viajen con TODO workspace (docker y local) y elimina duplicación en el repo.

## Decisiones de diseño clave (resumen — detalle en research.md y contracts/)

1. **Reubicación de libs (FR-003)**: `git mv` de `qmd_index.sh`/`backup_vault.sh` → `scripts/lib/` y `qmd_watch.sh` → `scripts/`; extender el bloque de espejo de `setup.sh` (scaffold + regenerate, solo modo docker) para copiarlas a `<dest>/docker/scripts/{lib/,}`; las líneas `COPY` del Dockerfile no cambian (leen el build context del workspace, que el espejo puebla). Tests existentes ajustan solo el path de `load_lib`.
2. **Resolución del vault root por modo (FR-008)**: override aditivo `VAULT_ROOT_OVERRIDE` (nombre final en contract) chequeado primero en `vault_resolve_root`; default actual (`/home/agent` rebase) intacto → tests docker sin cambios. Los entrypoints locales lo setean a `<ws>/<vault.path>`. Igual para qmd: se reusa `QMD_VAULT_DIR` (ya existe).
3. **Conversión cron→systemd (FR-012)**: función pura `cron_to_systemd_calendar()` en `scripts/lib/local_schedule.sh`; `setup.sh` la evalúa en render-time y exporta `{{QMD_TIMER_ONCALENDAR}}`/`{{BACKUP_TIMER_ONCALENDAR}}`; forma no soportada → default + warning en stdout del render. Templates quedan tontos.
4. **Enganche del setup qmd (FR-004, clarify)**: `--login` backgroundea el entrypoint con flag de solo-setup; el entrypoint del timer SIEMPRE corre setup-if-needed antes de reindexar (sentinel = no-op) — auto-sanación.
5. **Observabilidad**: entrypoints logean a stdout → journal de systemd (`journalctl -u agent-<name>-qmd-reindex`); estado máquina-legible en los state files JSON (mismo esquema que docker). Sin archivos de log nuevos.
6. **agentctl (FR-013)**: `status` agrega bloque local vault/qmd vía `systemctl is-active` (units presentes según flags de `agent.yml`); `doctor` reusa el helper de frescura existente (`agentctl:170-210`) para `vault-backup.json` y agrega chequeo de `qmd-index.json` + existencia de `index.sqlite`.
7. **Ciclo de vida (FR-009)**: `install_service` rama local renderiza+instala (o stagea sin sudo) las units nuevas condicionadas por flags; `--login` generaliza el loop de instalación staged (hoy healthcheck) a una lista que incluye qmd/backup; kill-switch y `--uninstall` las paran/remueven.

## Complexity Tracking

Sin violaciones nuevas. El modo local en sí es la violación justificada de Principio II registrada en 011 (opt-in, advertida, docker intacto); esta feature no la amplía — las units nuevas corren como el usuario operador sin privilegios adicionales.
