# Tasks: Vault + RAG operativos en modo local (Linux/systemd)

**Input**: Design documents from `/specs/012-local-vault-rag/`
**Prerequisites**: plan.md, research.md (D1-D8), data-model.md, contracts/ (3), quickstart.md

**Organización**: por user story; test-first obligatorio (Constitución III) — cada contrato tiene su tarea de test RED antes de la implementación. `[P]` = paralelizable (archivos distintos, sin dependencia pendiente).

**Gotcha activo** (memoria del repo): agregar un `{{VAR}}` de render nuevo rompe `known_external` en `tests/schema.bats` (y tocar prompts del wizard rompe `wizard_answers` + el array de `e2e-smoke.bats`). Las tareas que exportan variables nuevas lo incluyen explícitamente.

## Phase 1: Foundational (bloquea todas las stories)

**Goal**: libs canónicas host-side + primitivas nuevas (override de root, conversión de schedules). Sin esto ninguna story puede sourcear nada.

- [ ] T001 Reubicar libs con historia: `git mv docker/scripts/lib/qmd_index.sh scripts/lib/qmd_index.sh`, `git mv docker/scripts/lib/backup_vault.sh scripts/lib/backup_vault.sh`, `git mv docker/scripts/qmd_watch.sh scripts/qmd_watch.sh`; ajustar SOLO los paths de carga en tests existentes (`tests/qmd-setup.bats`, `tests/qmd-index.bats`, `tests/qmd-watch.bats`, `tests/backup-vault-lib.bats`, `tests/backup-vault-git.bats`, `tests/backup-vault-cmd.bats`, `tests/start-services-qmd.bats` si referencia el path) sin tocar aserciones; `bash -n` + `shellcheck -S error` sobre los 3 archivos movidos; correr esos bats → verdes (refactor guardado por tests existentes, contrato `contracts/lib-relocation.md`).
- [ ] T002 [P] Test RED en `tests/scaffold.bats`: scaffold modo docker espeja `qmd_index.sh`/`backup_vault.sh` a `<dest>/docker/scripts/lib/` y `qmd_watch.sh` a `<dest>/docker/scripts/` (cmp byte-idéntico al canónico); scaffold modo local NO crea árbol `docker/` (invariante 011 se mantiene).
- [ ] T003 Implementar el espejo en `setup.sh`: extender el bloque existente de `vault.sh`/vault-skeleton (scaffold `setup.sh:1501-1535`) y el refresh de regenerate para copiar las 3 libs, con validación de presencia fail-loud, gateado a modo docker → T002 GREEN.
- [ ] T004 [P] Test RED en `tests/backup-vault-lib.bats`: caso nuevo — con `VAULT_ROOT_OVERRIDE=/x/y` seteado, `vault_resolve_root` devuelve `/x/y` literal (sin rebase); casos existentes (rebase `/home/agent`) intactos sin edición.
- [ ] T005 Implementar cortocircuito `VAULT_ROOT_OVERRIDE` al inicio de `vault_resolve_root` en `scripts/lib/backup_vault.sh` (contrato `contracts/lib-relocation.md`) → T004 GREEN.
- [ ] T006 [P] Test RED nuevo `tests/local-schedule.bats`: tabla de conversión completa del contrato `contracts/local-qmd-pipeline.md` — `*/5|*/30 * * * *`, `0|15 * * * *`, `30 3 * * *`, `0 12 * * *`, forma no soportada → default + warning en stderr, vacío → default sin warning; función pura, source sin side effects.
- [ ] T007 Implementar `scripts/lib/local_schedule.sh::cron_to_systemd_calendar CRON DEFAULT` (guard `BASH_SOURCE` como las demás libs) → T006 GREEN.

**Checkpoint**: suite host completa verde (una corrida) antes de entrar a stories.

## Phase 2: User Story 1 — Vault base en modo local (P1) 🎯 MVP

**Goal**: cierra la brecha FR-004 de 011 — skeleton sembrado host-side + MCP vault apuntando al workspace.

**Independent Test**: workspace de prueba `mode=local` + `vault.enabled=true` → `--regenerate` siembra y `.mcp.json` referencia `<ws>/.state/.vault`. Sin systemd ni login.

- [ ] T008 [P] [US1] Test RED nuevo `tests/local-vault-seed.bats`: (a) regenerate local con vault on + destino vacío → skeleton completo bajo `<ws>/.state/.vault`; (b) vault poblado → no-op byte-exacto; (c) `force_reseed=true` → backup timestampeado + re-siembra + flag reseteado en `agent.yml`; (d) `vault.enabled=false` → cero efectos; (e) `vault.path` custom → `<ws>/<path>` literal sin rebase. (Lib real `scripts/lib/vault.sh`, sin stubs de systemd.)
- [ ] T009 [P] [US1] Test RED en `tests/mcp-json.bats`: modo local (`DEPLOYMENT_MODE_IS_DOCKER=false` + `LOCAL_VAULT_DIR` exportado) → `.mcpServers.vault.args[-1]` = `<ws>/.state/.vault`; modo docker → `/home/agent/.vault` byte-idéntico (caso existente sin tocar).
- [ ] T010 [US1] `setup.sh`: computar y exportar `LOCAL_VAULT_DIR` (`<ws>/<vault.path>`, default `.state/.vault`) junto al export de `DEPLOYMENT_MODE_IS_DOCKER` (ANTES del render de `.mcp.json`, en regenerate y en el camino NEXT_STEPS si aplica); agregar `LOCAL_VAULT_DIR` a `known_external` en `tests/schema.bats`.
- [ ] T011 [US1] Remap del arg del MCP vault en `modules/mcp-json.tpl` con el patrón `{{#if DEPLOYMENT_MODE_IS_DOCKER}}/home/agent/.vault{{/if}}{{#unless …}}{{LOCAL_VAULT_DIR}}{{/unless}}` (contrato `contracts/local-vault-backup.md`) → T009 GREEN.
- [ ] T012 [US1] Siembra host-side en la rama local de `regenerate()` en `setup.sh` (junto al render de artefactos locales `setup.sh:2026-2035`): source `scripts/lib/vault.sh`; `vault_ensure_paths` + `vault_seed_if_empty` (skeleton `modules/vault-skeleton`, `SCAFFOLD_DATE`) + camino `force_reseed` vía `vault_backup_and_reseed`; gate `vault.enabled` → T008 GREEN.
- [ ] T013 [US1] Checkpoint: `bats tests/local-vault-seed.bats tests/mcp-json.bats tests/scaffold.bats` verdes + suite completa verde.

## Phase 3: User Story 2 — Pipeline QMD/RAG local (P1)

**Goal**: índice construido solo (doble enganche auto-sanador) y fresco (timer + watcher systemd).

**Independent Test**: con stubs (bunx/systemctl/inotifywait): entrypoint respeta gate/flag/env; units renderan con OnCalendar convertido y Restart=always; wrapper degrada sin inotify-tools.

- [ ] T014 [P] [US2] Test RED nuevo `tests/local-qmd.bats` (sección entrypoint): render de `scripts/local/agent-qmd-reindex.sh` desde el tpl; (a) `vault.qmd.enabled=false` → exit 0 sin efectos; (b) `--setup-only` invoca solo setup (stub `bunx` registra llamadas; sentinel escrito); (c) sin flag → setup-if-needed (sentinel = no-op) y luego reindex (flock+hash preservados — stub de la lib real); (d) env horneada correcta: `QMD_CACHE_HOME=<ws>/.state/.cache/qmd`, `QMD_VAULT_DIR=<ws>/.state/.vault`, `QMD_INDEX_STATE_FILE=<ws>/scripts/heartbeat/qmd-index.json`; (e) exit siempre 0 ante fallo de bunx.
- [ ] T015 [P] [US2] Test RED en `tests/local-qmd.bats` (sección units): render de `local-qmd-reindex.timer.tpl` → `OnCalendar=*-*-* *:0/5:00` con schedule default y `OnCalendar=*-*-* *:0/30:00` con `*/30`, + warning/default con cron no soportado; `local-qmd-watch.service.tpl` → `Restart=always`, `RestartSec=2`, `User=<operador>`, `WorkingDirectory=<ws>`; `local-qmd-reindex.service.tpl` → `Type=oneshot` + `ExecStart=<ws>/scripts/local/agent-qmd-reindex.sh`.
- [ ] T016 [P] [US2] Test RED en `tests/local-qmd.bats` (sección watcher): (a) render de `local-qmd-watch.service.tpl` contiene `ExecCondition=/bin/sh -c 'command -v inotifywait'` — la degradación sin inotify-tools la maneja la UNIT (condición fallida → skipped/inactive, sin disparar `Restart=always`; patrón validado por 011 con `.credentials.json`; un wrapper que "sale limpio" con Restart=always golpea el start-limit → failed); (b) wrapper `agent-qmd-watch.sh` ejecuta `scripts/qmd_watch.sh` con `QMD_REINDEX_CMD=<ws>/scripts/local/agent-qmd-reindex.sh` y `QMD_WATCH_AGENT_YML=<ws>/agent.yml` (stub `inotifywait` en PATH); (c) la lib conserva su guard interno (cinturón redundante — ya cubierto por `tests/qmd-watch.bats`).
- [ ] T017 [P] [US2] Crear `modules/local-qmd-reindex.sh.tpl` (entrypoint, flag `--setup-only`, env horneada, siempre exit 0; contrato `contracts/local-qmd-pipeline.md`).
- [ ] T018 [P] [US2] Crear `modules/local-qmd-watch.sh.tpl` (wrapper con guard de inotifywait + exec de `scripts/qmd_watch.sh`).
- [ ] T019 [P] [US2] Crear `modules/local-qmd-reindex.service.tpl`, `modules/local-qmd-reindex.timer.tpl` (`OnCalendar={{QMD_TIMER_ONCALENDAR}}`, `Persistent=true`) y `modules/local-qmd-watch.service.tpl` (con `ExecCondition=/bin/sh -c 'command -v inotifywait'` + `Restart=always`/`RestartSec=2` — contrato C1 de `contracts/local-qmd-pipeline.md`).
- [ ] T020 [US2] `setup.sh`: exportar `QMD_TIMER_ONCALENDAR` (vía `local_schedule.sh`, default `*-*-* *:0/5:00`) y renderizar entrypoint+wrapper en `scripts/local/` (rama local, gate `vault.qmd.enabled`, `chmod +x`); agregar la var a `known_external` de `tests/schema.bats`; incluir aserción FR-011 en el test: un SEGUNDO `--regenerate` re-produce entrypoint+wrapper+units (presentes, ejecutables, contenido esperado — sobrevive regenerate explícito, hallazgo G1) → T014-T016 GREEN.
- [ ] T021 [US2] `setup.sh install_service` rama local: renderizar + instalar (sudo) o stagear (sin sudo, a `scripts/local/`) las 3 units qmd condicionadas por el gate; `--uninstall` local: `disable --now` + rm de esas units (instaladas y staged); `modules/local-killswitch.sh.tpl`: stop de reindex.timer + watch.service cuando existen. Tests RED primero en los archivos que fijan esos contratos (`tests/local-qmd.bats` sección lifecycle o `tests/uninstall.bats` según corresponda).
- [ ] T022 [US2] Test RED + impl en `tests/local-login-install.bats` y `modules/local-login.sh.tpl`: (a) con qmd on, `--login` despacha `agent-qmd-reindex.sh --setup-only` en background (nohup, no bloquea — stub registra la invocación) y NO lo hace con qmd off; (b) generalizar el loop de instalación staged (hoy healthcheck, paso 6) a una lista que incluya las units qmd; los tests existentes del loop healthcheck siguen verdes.
- [ ] T023 [US2] Checkpoint: `bats tests/local-qmd.bats tests/local-login-install.bats` + suite completa verde.

## Phase 4: User Story 3 — Backup del vault en modo local (P2)

**Goal**: ciclo backup/restore simétrico — snapshot markdown periódico a `backup/vault`.

**Independent Test**: fork simulado (repo git local como remote) → commit en rama huérfana con exclusiones + hash-noop; resolución `<ws>/<vault.path>` sin rebase.

- [ ] T024 [P] [US3] Test RED nuevo `tests/local-vault-backup.bats`: render de `scripts/local/agent-vault-backup.sh`; (a) sin fork en `agent.yml` → exit 0 silencioso sin efectos; (b) con fork (remote = repo git bare local) → commit en `backup/vault` respetando exclusiones (`.obsidian/workspace*.json`, `.trash`, `*.sync-conflict-*`) y propagando deletes; (c) segunda corrida sin cambios → no-op por hash (sin nuevo commit); (d) `VAULT_ROOT_OVERRIDE` horneado = `<ws>/.state/.vault` (sin rebase `/home/agent`); (e) state en `<ws>/scripts/heartbeat/vault-backup.json`.
- [ ] T025 [P] [US3] Test RED en `tests/local-vault-backup.bats` (sección units): `local-vault-backup.timer.tpl` → `OnCalendar=*-*-* *:00:00` con schedule default `0 * * * *` y conversión de `30 3 * * *` → `*-*-* 03:30:00`; service `Type=oneshot`; gate `vault.enabled` (off → setup.sh no los rendera).
- [ ] T026 [P] [US3] Crear `modules/local-vault-backup.sh.tpl` + `modules/local-vault-backup.service.tpl` + `modules/local-vault-backup.timer.tpl` (contrato `contracts/local-vault-backup.md`).
- [ ] T027 [US3] `setup.sh`: exportar `BACKUP_TIMER_ONCALENDAR` (default `*-*-* *:00:00`) + render del entrypoint (rama local, gate `vault.enabled`) + wiring en `install_service`/`--uninstall`/kill-switch/loop staged de `--login`; agregar la var a `known_external` de `tests/schema.bats`; incluir aserción FR-011: segundo `--regenerate` re-produce entrypoint+units de backup (hallazgo G1) → T024-T025 GREEN.
- [ ] T028 [US3] Checkpoint: `bats tests/local-vault-backup.bats` + suite completa verde.

## Phase 5: Polish & Cross-Cutting

- [ ] T029 [P] Test RED en `tests/agentctl-local.bats`: `status` modo local con vault+qmd on lista las 5 units con estado (active/staged/absent — stubs `systemctl`) y con flags off no menciona el subsistema; `doctor` reporta `index.sqlite` presente/ausente, edad de `last_run` en `qmd-index.json` y frescura de `vault-backup.json` (helper existente `agentctl:170-210`).
- [ ] T030 Implementar FR-013 en `scripts/agentctl` (bloques status/doctor modo local) → T029 GREEN.
- [ ] T031 [P] Polish schema: validar `vault.enabled` (bool estricto), `vault.path`/`vault.backup_schedule` (opcional no-vacío), `vault.mcp.enabled` (bool) en `scripts/lib/schema.sh` + casos en `tests/schema-validate.bats` (legacy-safe: ausentes = válido).
- [ ] T032 [P] Polish colateral: remap del path de google-calendar en `modules/mcp-json.tpl` (mismo patrón #if/#unless → `{{DEPLOYMENT_WORKSPACE}}/.state/.gcal/gcp-oauth.keys.json` en local — NO `OPERATOR_HOME`: en docker `/home/agent/.gcal` ≡ `<ws>/.state/.gcal` por el bind, y la equivalencia `.state` es la regla de durabilidad de todo el subsistema — las credenciales deben viajar con el workspace) + caso en `tests/mcp-json.bats`.
- [ ] T033 [P] Docs: párrafo de modo local en `docs/architecture.md` (sección vault, paths y units) + entrada 012 en `CHANGELOG.md` + `VERSION` 0.5.0 → 0.6.0 (+ drift-guard de versión si `tests/version-*.bats` lo exige).
- [ ] T034 Suite host completa verde (UNA corrida — evitar el falso-fallo por contención de bats) + `shellcheck -S error` sobre todos los renders locales nuevos (entrypoints, wrapper, login).
- [ ] T035 `DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats tests/docker-e2e-vault.bats tests/docker-e2e-smoke.bats` verde — valida que el espejo reproduce el árbol de imagen (contratos T035-010 y vault e2e sin cambios).
- [ ] T036 Gate manual Linux en mclaren según `quickstart.md` (criterios (a)-(f) del spec) — pendiente de que el host vuelva; NO bloquea el PR si T034+T035 están verdes (se registra como pendiente explícito en el PR, mismo criterio que 011).

## Dependencies

```text
Phase 1 (T001→T007) ──► bloquea todo (libs + primitivas)
  T001 ──► T002/T003 (espejo copia los paths nuevos)
  T001 ──► T004/T005 (override edita la lib ya movida)
  T006/T007 independientes de T001 (lib nueva)
US1 (T008-T013) ──► independiente de US2/US3 (MVP)
US2 (T014-T023) ──► requiere T007 (conversión) y T001 (libs); independiente de US1 en código,
                    pero el gate real necesita vault sembrado (US1) para tener corpus
US3 (T024-T028) ──► requiere T005 (override) y T007; independiente de US2
Polish T029/T030 ──► tras US2+US3 (reportan sus units)
T034/T035 ──► al final; T036 asíncrono (host caído)
```

## Parallel Examples

- Phase 1: T002 ∥ T004 ∥ T006 (tests RED en archivos distintos) tras T001.
- US1: T008 ∥ T009 (tests RED) → T010 → T011 ∥ T012.
- US2: T014 ∥ T015 ∥ T016 (RED) → T017 ∥ T018 ∥ T019 (tpls distintos) → T020 → T021 → T022.
- US3: T024 ∥ T025 → T026 → T027.
- Polish: T029 ∥ T031 ∥ T032 ∥ T033.

## Implementation Strategy

**MVP = Phase 1 + US1** (vault sembrado + MCP correcto — cierra la brecha FR-004 y ya es entregable). Luego US2 (el RAG cobra vida), US3 (durabilidad), Polish. Cada checkpoint corre la suite completa UNA vez. Commits por fase con mensajes `feat(012)`/`test(012)` en español imperativo; push a la rama `012-local-vault-rag` (HTTPS vía gh). El gate mclaren (T036) se ejecuta apenas el host vuelva — si el PR se abre antes, queda declarado como pendiente.
