# Implementation Plan: RAG local agnóstico al modo de instalación

**Branch**: `013-local-rag-parity` | **Date**: 2026-07-05 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/013-local-rag-parity/spec.md`

## Summary

Cerrar los 30 gaps confirmados por la auditoría de paridad RAG (wf_37295b56) para que la memoria RAG sea igual de buena en ambos modos de deployment. Tres frentes: (1) contrato de storage real de qmd — el binario honra `XDG_CACHE_HOME`/`QMD_CONFIG_DIR`, no `QMD_CACHE_HOME` — aplicado como **par atómico** escritor (wrappers) + lector (env granular del MCP en `.mcp.json`); (2) entorno de ejecución de los contextos batch bajo systemd — PATH auto-provisto en los 3 wrappers, env del vault en el watcher, loop supervisado; (3) operabilidad honesta — kill-switch completo, doctor con `last_status`/staleness/exit codes, acciones manuales, healthcheck del watcher, NEXT_STEPS, fallback de schedule persistente. Dos excepciones docker aprobadas en Clarifications: flock del setup en la lib espejada (FR-015) y symlink `bunx` en la imagen (FR-016, bug docker confirmado en research) — ambas gated por DOCKER_E2E. Todo lo demás docker queda byte-idéntico a v0.6.0.

## Technical Context

**Language/Version**: bash 3.2+ (host launcher, compatible macOS) / bash 4+ (wrappers locales en Linux); plantillas del render engine propio (`scripts/lib/render.sh`)

**Primary Dependencies**: systemd (units de sistema, modo local), `@tobilu/qmd@2.5.3` (contrato de env verificado contra el tarball npm), bun/bunx 1.3.14, yq v4 (vendorado), inotify-tools (opcional, ExecCondition)

**Storage**: índice+modelos qmd bajo `<ws>/.state/.cache/qmd`; config de colecciones bajo `<ws>/.state/.config/qmd`; state files en `<ws>/scripts/heartbeat/` (`qmd-index.json`, `vault-backup.json`, nuevo marker de schedule fallback)

**Testing**: bats host-side (test-first, stubs systemd/bunx/yq ya establecidos en `tests/local-*.bats`); `DOCKER_E2E=1` obligatorio por FR-015/FR-016; `shellcheck -S error`

**Target Platform**: modo local = Linux/systemd (Debian-like, arm64/x86_64); modo docker = Alpine 3.20 (byte-idéntico salvo FR-015/FR-016)

**Project Type**: CLI/launcher bash — plantillas `modules/*.tpl` + libs `scripts/lib/` + `setup.sh` + `scripts/agentctl`

**Performance Goals**: reindex-on-change ~15s (watcher) / backstop = ciclo del timer; sin doble descarga del modelo (~300MB) en solapes de setup

**Constraints**: docker byte-idéntico salvo las 2 excepciones aprobadas; render engine sin `{{#if}}` anidado (variables por modo precomputadas en `setup.sh`); fail-silent exit 0 en entrypoints (Principle IV); secretos jamás en argv/journal

**Scale/Scope**: ~14 archivos tocados (7 templates `modules/local-*`, `mcp-json.tpl`, `next-steps.{en,es}.tpl`, `scripts/lib/qmd_index.sh`, `docker/Dockerfile`, `setup.sh`, `scripts/agentctl`) + ~8 archivos de test

## Constitution Check

*Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — PASS. Todos los cambios de comportamiento renderizado salen de plantillas + variables precomputadas en `setup.sh` desde `agent.yml`; el marker de schedule fallback lo escribe/borra `--regenerate` (derivado puro); nada sobrevive por edición manual.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. El symlink `bunx` (FR-016) no toca caps/mounts/sockets; el modo local sigue siendo la violación justificada y heredada de 011 (opt-in con warning), sin cambios de postura en 013.
- [x] **III. Test-First, Host-Runnable** — PASS. Cada FR lleva bats host-side escrito antes de implementar; DOCKER_E2E gated para FR-015/FR-016; `shellcheck -S error`; la lib modificada mantiene guards `BASH_SOURCE`.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. Entrypoints siguen exit 0; flock añade serialización sin nuevos modos de crash; el loop del watcher degrada reintentando, nunca crashea la unit; sentinel/lock/hash se mantienen como guards (no mtime).
- [x] **V. Workspace-Is-the-Agent** — PASS (refuerza): el fix mueve el índice/config qmd DE fuera del workspace HACIA `.state/`; purge/nuke local limpia el clone cache del backup; nada nuevo se respalda ni committea.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. Sin pins nuevos ni duplicados (el symlink reusa el bun ya pinneado); CHANGELOG + VERSION 0.6.0 → 0.7.0.

## Project Structure

### Documentation (this feature)

```text
specs/013-local-rag-parity/
├── spec.md              # + Clarifications (4 decisiones)
├── plan.md              # este archivo
├── research.md          # Phase 0 — contrato qmd verificado, decisiones D1-D12
├── data-model.md        # Phase 1 — contrato de env, layout de storage, inventario de units
├── quickstart.md        # Phase 1 — gates: suite host, DOCKER_E2E, mclaren, ferrari
├── contracts/
│   ├── storage-env-contract.md    # FR-001/002/003/004 (US1)
│   ├── batch-runtime-env.md       # FR-005/006/007/015 (US2)
│   ├── local-ops-parity.md        # FR-008..FR-013 (US3)
│   └── docker-qmd-runtime.md      # FR-016 (transversal)
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks (no lo crea este comando)
```

### Source Code (repository root)

```text
modules/
├── local-qmd-reindex.sh.tpl      # US1: +XDG_CACHE_HOME/QMD_CONFIG_DIR; US2: +PATH
├── local-qmd-watch.sh.tpl        # US2: +PATH, +QMD_VAULT_DIR/VAULT_ROOT_OVERRIDE, loop supervisado
├── local-vault-backup.sh.tpl     # US2: +PATH
├── mcp-json.tpl                  # US1: "env": {{QMD_MCP_ENV}} (docker → {} byte-idéntico)
├── local-killswitch.sh.tpl       # US3: AUX_UNITS completo (+vault-backup.timer, +healthcheck.timer)
├── local-healthcheck.sh.tpl      # US3: WARN si qmd-watch failed
└── next-steps.{en,es}.tpl        # US3: bloque journal/timers condicionado a VAULT_QMD_ENABLED
scripts/
├── agentctl                      # US3: doctor last_status/staleness/exit codes; acciones manuales locales
└── lib/qmd_index.sh              # FR-015: flock en qmd_setup_if_needed (lib espejada → DOCKER_E2E)
setup.sh                          # US1: export QMD_MCP_ENV por modo; US3: marker schedule fallback; purge/nuke local
docker/Dockerfile                 # FR-016: ln -s bun → bunx (única línea docker)
tests/
├── local-qmd.bats                # extendido: envs del par, PATH, loop, watcher env
├── mcp-json.bats                 # extendido: QMD_MCP_ENV por modo + docker byte-idéntico
├── local-vault-backup.bats       # extendido: PATH del wrapper
├── agentctl-local.bats           # extendido: doctor honesto, exit codes, acciones manuales
├── local-login-install.bats / scaffold.bats / schema.bats  # aserciones nuevas donde ya existan suites
├── qmd-setup.bats                # extendido: flock del setup (lib compartida)
└── docker-e2e-qmd.bats           # extendido: aserción bunx en imagen real (no stub)
```

**Structure Decision**: mismos tres code paths del repo (host-launcher / image-baked / workspace-templated); 013 toca casi exclusivamente el primero y el tercero. Las dos excepciones al árbol docker (lib espejada + Dockerfile) están acotadas por FR-015/FR-016 y el gate DOCKER_E2E.

## Decisiones de diseño (D1–D12)

- **D1 — Contrato de storage real**: el binario qmd resuelve índice/modelos vía `INDEX_PATH` > `XDG_CACHE_HOME/qmd` > `~/.cache/qmd` (tarball 2.5.3: `dist/store.js:420-435`, `dist/llm.js:119-121`) y la config de colecciones vía `QMD_CONFIG_DIR` > `XDG_CONFIG_HOME/qmd` > `~/.config/qmd` (`dist/collections.js:59-65`; documentado en el help, `dist/cli/qmd.js:3149-3150`). Los wrappers locales exportan `XDG_CACHE_HOME="${WORKSPACE}/.state/.cache"` y `QMD_CONFIG_DIR="${WORKSPACE}/.state/.config/qmd"` JUNTO al `QMD_CACHE_HOME` existente (bookkeeping de la lib) → lib y binario convergen en `<ws>/.state/.cache/qmd`.
- **D2 — Lector MCP (par atómico)**: `setup.sh` precomputa `QMD_MCP_ENV` (docker: literal `{}`; local: `{"XDG_CACHE_HOME":"<ws>/.state/.cache","QMD_CONFIG_DIR":"<ws>/.state/.config/qmd"}`) y `mcp-json.tpl` renderiza `"env": {{QMD_MCP_ENV}}` — sin `{{#if}}` anidado, docker byte-idéntico verificable por test. Escritor y lector cambian en el mismo commit (FR-001).
- **D3 — PATH de los contextos batch**: `export PATH="{{OPERATOR_HOME}}/.local/bin:{{DEPLOYMENT_WORKSPACE}}/scripts/vendor/bin:$PATH"` al inicio de los 3 wrappers (no en las units): cubre timer, watcher, dispatch de `--login` y ejecución manual por igual, y no arrastra el resto del env de sesión.
- **D4 — Env del watcher**: `local-qmd-watch.sh.tpl` exporta `QMD_VAULT_DIR="{{LOCAL_VAULT_DIR}}"` y `VAULT_ROOT_OVERRIDE="{{LOCAL_VAULT_DIR}}"` (espejo exacto de `local-qmd-reindex.sh.tpl:24-26`).
- **D5 — Resiliencia del watcher** (Clarify Q1): loop supervisado en el wrapper — `while :; do bash qmd_watch.sh; sleep 30; done` — reemplaza el `exec`; la unit conserva `ExecCondition` (sin inotify-tools queda inactive, el loop nunca arranca) y `Restart=always` como cinturón si el propio loop muere. `failed` pasa a ser señal real para FR-011.
- **D6 — Flock del setup** (Clarify Q3, FR-015): `qmd_setup_if_needed` toma `flock -n` sobre el mismo `.reindex.lock`; el perdedor loguea y retorna 0 (el guard del siguiente tick reintenta). Cambio en `scripts/lib/qmd_index.sh` (espejada) → DOCKER_E2E.
- **D7 — bunx en docker** (Clarify Q4, FR-016): `ln -s /usr/local/bin/bun /usr/local/bin/bunx` dentro del bloque RUN de bun del Dockerfile; `docker-e2e-qmd.bats` gana una aserción de que `/usr/local/bin/bunx` existe en la imagen real (el stub del PATH no la satisface).
- **D8 — Acciones manuales locales**: `agentctl heartbeat qmd-reindex|backup-vault` en modo local ejecutan directamente el script del workspace (`scripts/local/agent-qmd-reindex.sh` / `agent-vault-backup.sh`) como el operador — mismo usuario que `User=` de las units, sin `systemctl start` (evita polkit/sudo). Passthrough de `--dry-run` donde el script lo soporte.
- **D9 — Doctor honesto**: `_local_vault_qmd_doctor` lee `.last_status` de `qmd-index.json` (warn/fail en `error`); staleness del backup reusando `_check_backup_freshness` (umbral 25h, igual docker); `cmd_local_doctor` replica el epílogo de exit codes 0/1/2 de `cmd_doctor`. `_local_vault_qmd_status` agrega `last_run`.
- **D10 — Fallback de schedule persistente**: cuando `cron_to_systemd_calendar` cae al default, `setup.sh` escribe `<ws>/scripts/heartbeat/qmd-schedule.fallback` (original + convertido + timestamp) y lo borra cuando la conversión vuelve a ser exacta; `status`/`doctor` lo reportan. Derivado puro del regenerate (Principle I).
- **D11 — Kill-switch y healthcheck completos**: `AUX_UNITS` suma `vault-backup.timer` y `healthcheck.timer` (stop/disable best-effort ya existente); `local-healthcheck.sh.tpl` agrega WARN si `agent-<name>-qmd-watch.service` existe y está `failed` (WARN, no DEGRADED — el timer backstop preserva frescura).
- **D12 — Purge/nuke local**: en `uninstall()` rama purge/nuke con `deployment.mode=local`, remover `~/.cache/agent-backup/vault-clone` (único clone usado por local). El índice/config qmd ya caen dentro del workspace tras D1. Residuos legacy pre-013 (`~/.cache/qmd`, `~/.config/qmd`): limpieza manual documentada en CHANGELOG, jamás `rm` automático en el HOME del operador fuera de rutas propias del launcher.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| Tocar la lib espejada a docker (FR-015, flock) | Cerrar el solape --login vs primer tick (doble descarga ~300MB) | Diferir dejaba 29/30 y una lib con contrato de concurrencia asimétrico; efecto docker benigno (un dispatcher al boot), gated por DOCKER_E2E |
| Tocar `docker/Dockerfile` (FR-016, symlink bunx) | QMD en docker nunca funcionó contra bunx real (el e2e lo stubea); sin esto 013 no es "agnóstico al modo" y ferrari (docker) queda fuera | Fix separado (014) bloqueaba habilitar QMD en ferrari un release más y dejaba el e2e mintiendo sobre la imagen |
| (Heredada 011) modo local corre como usuario operador | Naturaleza del modo local | Justificada y aceptada en 011; 013 no amplía la superficie |

## Gates

- Suite host `bats tests/` verde completa + `shellcheck -S error` limpio.
- `DOCKER_E2E=1` verde (obligatorio por FR-015/FR-016): `docker-e2e-qmd` (con la nueva aserción bunx real) + `docker-e2e-vault` + smoke.
- Byte-identidad docker: test de render que compara `.mcp.json` (y units sin cambios) contra el contrato v0.6.0.
- Gate manual confirmatorio en mclaren cuando vuelva (quickstart.md); validación ferrari post-merge para QMD docker (rebuild de imagen).
