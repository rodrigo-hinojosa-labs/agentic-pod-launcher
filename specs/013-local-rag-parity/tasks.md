# Tasks: RAG local agnóstico al modo de instalación

**Input**: Design documents from `/specs/013-local-rag-parity/` — plan.md (D1–D12), research.md (R1–R12), data-model.md (E1–E5), contracts/ (4), quickstart.md (gates)

**Tests**: OBLIGATORIOS (Constitution III, test-first) — cada tarea de test se escribe y se ve FALLAR (RED) antes de su implementación.

**Organization**: por user story; US1 y US2 son P1 (US1 = MVP), US3 = P2, FR-016 transversal en fase propia.

## Phase 1: Setup

- [ ] T001 Baseline verde: correr `bats tests/` completa y `shellcheck -S error` sobre `setup.sh`, `scripts/agentctl`, `scripts/lib/*.sh`, `scripts/*.sh`; registrar el conteo (debe coincidir con el estado de main v0.6.0) para atribuir cualquier regresión a 013

## Phase 2: Foundational

*Sin tareas — no hay prerequisitos bloqueantes compartidos: cada historia lleva su propio cableado (la var `QMD_MCP_ENV` es exclusiva de US1 y se hace ahí).*

## Phase 3: User Story 1 — Memoria RAG durable y coherente (P1) — MVP

**Goal**: índice/config qmd bajo `<ws>/.state/` para escritor Y lector (par atómico, FR-001/002/003); purge/nuke sin huérfanos nuevos (FR-004). Contrato: `contracts/storage-env-contract.md`.

**Independent Test**: render del entrypoint local + `.mcp.json` en ambos modos (stubs; sin systemd real): storage bajo el workspace en local, docker byte-idéntico.

- [ ] T002 [P] [US1] Test RED: en `tests/local-qmd.bats`, el render de `scripts/local/agent-qmd-reindex.sh` exporta `XDG_CACHE_HOME=<ws>/.state/.cache`, `QMD_CONFIG_DIR=<ws>/.state/.config/qmd` Y conserva `QMD_CACHE_HOME=<ws>/.state/.cache/qmd` (convergencia lib↔binario, E1)
- [ ] T003 [P] [US1] Test RED: en `tests/mcp-json.bats`, render local → bloque qmd con `env` conteniendo `XDG_CACHE_HOME` y `QMD_CONFIG_DIR` bajo el workspace; render docker → línea `"env": {}` byte-exacta (SC-003)
- [ ] T004 [P] [US1] Test: en `tests/schema.bats`, agregar `QMD_MCP_ENV` a AMBAS listas `known_external` (gotcha 012: hay dos, ~L62-66 y ~L107-113)
- [ ] T005 [P] [US1] Test RED: en `tests/uninstall.bats`, `--uninstall --purge`/`--nuke` en workspace local (HOME stubbeado) remueve `~/.cache/agent-backup/vault-clone` y NO toca `~/.cache/qmd` (R12)
- [ ] T006 [US1] Implementar en `setup.sh`: export `QMD_MCP_ENV` por modo (docker literal `{}`; local JSON con ambas claves), junto al bloque `VAULT_MCP_PATH`/`GCAL_CREDS_PATH` existente (D2)
- [ ] T007 [US1] Implementar el PAR ATÓMICO (un solo commit): `modules/local-qmd-reindex.sh.tpl` agrega los exports `XDG_CACHE_HOME`/`QMD_CONFIG_DIR` + `mkdir -p` del config root, Y `modules/mcp-json.tpl` cambia el bloque qmd a `"env": {{QMD_MCP_ENV}}` (FR-001 prohíbe mergear un lado solo)
- [ ] T008 [US1] Implementar en `setup.sh` `uninstall()`: rama purge/nuke con `deployment.mode=local` remueve `~/.cache/agent-backup/vault-clone`; jamás rutas legacy `~/.cache/qmd`/`~/.config/qmd` (R11/R12)
- [ ] T009 [US1] Verificar: `bats tests/local-qmd.bats tests/mcp-json.bats tests/schema.bats tests/uninstall.bats` verdes + `shellcheck -S error setup.sh`

**Checkpoint**: US1 entregable sola — storage correcto y byte-identidad docker probada.

## Phase 4: User Story 2 — Refresco confiable bajo systemd (P1)

**Goal**: PATH auto-provisto en los 3 wrappers (FR-005), watcher observando el vault real (FR-006), loop supervisado (FR-007), flock del setup (FR-015). Contrato: `contracts/batch-runtime-env.md`.

**Independent Test**: renders de wrappers + bats con PATH mínimo estilo systemd y stubs bunx/yq/inotifywait; sin systemd real.

- [ ] T010 [P] [US2] Test RED: en `tests/local-qmd.bats`, los renders de `agent-qmd-reindex.sh` y `agent-qmd-watch.sh` tienen `export PATH="<op_home>/.local/bin:<ws>/scripts/vendor/bin:$PATH"` como primera acción ejecutable (antes de cualquier yq/bunx/source)
- [ ] T011 [P] [US2] Test RED: en `tests/local-vault-backup.bats`, el render de `agent-vault-backup.sh` incluye el mismo `export PATH` inicial
- [ ] T012 [P] [US2] Test RED: en `tests/local-qmd.bats`, el render del watcher exporta `QMD_VAULT_DIR` y `VAULT_ROOT_OVERRIDE` = `<ws>/<vault.path>` (LOCAL_VAULT_DIR), contiene el loop `while :` con `sleep 30`, y NO contiene `exec bash`
- [ ] T013 [P] [US2] Test RED: en `tests/local-qmd.bats`, ejecutar el wrapper watch con `qmd_watch.sh` stub que sale inmediato y `sleep` stubbeado → ≥2 reinvocaciones sin propagar exit≠0 (resiliencia D5)
- [ ] T014 [P] [US2] Test RED: en `tests/qmd-setup.bats`, dos `qmd_setup_if_needed` concurrentes (stub bunx lento) → una sola secuencia add/update/embed, perdedor exit 0; sentinel-hit sigue siendo no-op sin tomar el lock (FR-015)
- [ ] T015 [US2] Implementar el `export PATH` inicial en los 3 templates: `modules/local-qmd-reindex.sh.tpl`, `modules/local-qmd-watch.sh.tpl`, `modules/local-vault-backup.sh.tpl` (D3)
- [ ] T016 [US2] Implementar en `modules/local-qmd-watch.sh.tpl`: exports `QMD_VAULT_DIR`/`VAULT_ROOT_OVERRIDE` (D4) + loop supervisado reemplazando el `exec` (D5)
- [ ] T017 [US2] Implementar en `scripts/lib/qmd_index.sh`: `flock -n` sobre `$cache_root/.reindex.lock` envolviendo el cuerpo efectivo de `qmd_setup_if_needed` (guards `BASH_SOURCE` intactos; lib espejada → activa gate DOCKER_E2E) (D6)
- [ ] T018 [US2] Test: en `tests/local-qmd.bats`, el render de `agent-<n>-qmd-watch.service` queda byte-idéntico al contrato v0.6.0 (la unit NO cambia; solo el wrapper)
- [ ] T019 [US2] Verificar: `bats tests/local-qmd.bats tests/local-vault-backup.bats tests/qmd-setup.bats tests/qmd-index.bats tests/qmd-watch.bats` verdes + `shellcheck -S error scripts/lib/qmd_index.sh`

**Checkpoint**: US1+US2 = RAG local funcional y fresco; el resto es operabilidad.

## Phase 5: User Story 3 — Operabilidad honesta y control total (P2)

**Goal**: kill-switch completo (FR-008), doctor/status honestos + exit codes (FR-009, FR-013), acciones manuales (FR-010), healthcheck del watcher (FR-011), NEXT_STEPS (FR-012). Contrato: `contracts/local-ops-parity.md`.

**Independent Test**: bats sobre `agentctl` y renders con `systemctl` y state files stubbeados.

- [ ] T020 [P] [US3] Test RED: crear `tests/local-killswitch.bats` — el render del kill switch lista en `AUX_UNITS` las 4 units auxiliares (`qmd-reindex.timer`, `qmd-watch.service`, `vault-backup.timer`, `healthcheck.timer`)
- [ ] T021 [P] [US3] Test RED: en `tests/agentctl-local.bats` — doctor con `qmd-index.json` fixture `last_status=error` → warn + exit 1; `vault-backup.json` stale >25h con fork → warn staleness; todo sano → exit 0; `status` imprime `last_run`
- [ ] T022 [P] [US3] Test RED: en `tests/agentctl-local.bats` — `agentctl heartbeat qmd-reindex` y `heartbeat backup-vault` en workspace local ejecutan el script correspondiente de `scripts/local/` (stub registra invocación) y NO imprimen el error "Docker-mode command"
- [ ] T023 [P] [US3] Test RED: en `tests/local-healthcheck.bats` — el render incluye el chequeo `is-failed` de la unit qmd-watch gated por su existencia; con systemctl stub en failed → WARN (nunca DEGRADED); sin la unit → silencio
- [ ] T024 [P] [US3] Test RED: en `tests/scaffold.bats` — NEXT_STEPS en/es local con qmd on: `journalctl -u` de las 3 units + `systemctl list-timers`; con qmd off: bloque ausente
- [ ] T025 [P] [US3] Test RED: en `tests/local-schedule.bats` — regenerate local con schedule no convertible crea `scripts/heartbeat/qmd-schedule.fallback` (original + applied); con `*/5 * * * *` el marker se elimina si existía (FR-013/R10)
- [ ] T026 [US3] Implementar `modules/local-killswitch.sh.tpl`: AUX_UNITS completo (D11)
- [ ] T027 [US3] Implementar en `scripts/agentctl`: `_local_vault_qmd_doctor` (last_status → `_doctor_warn`, staleness vía `_check_backup_freshness <agent> vault 25`, reporte del marker de fallback), `_local_vault_qmd_status` (+`last_run`), `cmd_local_doctor` con epílogo de exit codes 0/1/2 de `cmd_doctor` (D9)
- [ ] T028 [US3] Implementar en `scripts/agentctl`: dispatch local de `heartbeat qmd-reindex`/`heartbeat backup-vault` → exec directo del script del workspace con passthrough `--dry-run` (D8); demás subcomandos docker-only conservan su error+hint
- [ ] T029 [US3] Implementar `modules/local-healthcheck.sh.tpl`: WARN si `agent-<n>-qmd-watch.service` existe y está failed (D11)
- [ ] T030 [US3] Implementar `modules/next-steps.en.tpl` y `modules/next-steps.es.tpl`: bloque local de observabilidad RAG condicionado a `VAULT_QMD_ENABLED` (vault-backup condicionado a `VAULT_ENABLED`) (FR-012)
- [ ] T031 [US3] Implementar en `setup.sh`: crear/eliminar `scripts/heartbeat/qmd-schedule.fallback` según resultado de `cron_to_systemd_calendar` en el render local (derivado puro del regenerate, D10)
- [ ] T032 [US3] Verificar: `bats tests/local-killswitch.bats tests/agentctl-local.bats tests/local-healthcheck.bats tests/scaffold.bats tests/local-schedule.bats` verdes + `shellcheck -S error scripts/agentctl setup.sh`

## Phase 6: FR-016 — bunx en la imagen docker (transversal)

**Goal**: QMD en docker funciona contra binarios reales. Contrato: `contracts/docker-qmd-runtime.md`.

- [ ] T033 Test RED: en `tests/docker-render.bats` (drift-guard host, sin Docker) — el bloque bun de `docker/Dockerfile` contiene la línea `ln -s /usr/local/bin/bun /usr/local/bin/bunx`
- [ ] T034 Implementar en `docker/Dockerfile`: symlink `bunx` tras el `chmod +x` de bun (única línea docker de 013; sin pin nuevo) (D7)
- [ ] T035 Test: en `tests/docker-e2e-qmd.bats` — aserción contra la imagen real: `test -x /usr/local/bin/bunx && readlink` → apunta a `bun` (independiente del stub de PATH)

## Phase 7: Polish & Gates

- [ ] T036 [P] Actualizar `CHANGELOG.md` (entry 013: 3 causas raíz, par atómico, 2 excepciones docker declaradas, nota de limpieza manual legacy `~/.cache/qmd`//`~/.config/qmd` para instalaciones locales pre-013) y `VERSION` 0.6.0 → 0.7.0
- [ ] T037 [P] Actualizar `docs/architecture.md`: sección vault/RAG modo local — contrato real de env (`XDG_CACHE_HOME`/`QMD_CONFIG_DIR`), loop del watcher, acciones manuales de `agentctl`
- [ ] T038 Suite host completa: `bats tests/` verde total + `shellcheck -S error` global (comparar contra el baseline de T001)
- [ ] T039 Gate DOCKER_E2E (obligatorio por FR-015/FR-016): `DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats tests/docker-e2e-vault.bats tests/docker-e2e-smoke.bats` verdes (smoke: reintentar aislado si flakea en 1er boot)
- [ ] T040 Gate manual confirmatorio (quickstart.md gates 4–5): mclaren (diferido — host caído; los 3 fallos predichos por la auditoría verificados corregidos) y ferrari (post-merge: rebuild + qmd on + `claude mcp list` Connected)

## Dependencies

- T001 → todo lo demás.
- US1 (T002–T009) → US2 (T010–T019): comparten `local-qmd-reindex.sh.tpl` (T007 antes de T015).
- US3 (T020–T032) depende solo de Setup (archivos disjuntos de US1/US2) — puede correr en paralelo con US2 si se desea, pero el orden P1→P2 es el recomendado.
- Phase 6 (T033–T035) es independiente de US1–US3 (solo docker/Dockerfile + e2e) — paralelizable con cualquier fase.
- Polish (T036–T040) al final; T039 requiere T017 (lib) y T034 (Dockerfile) hechos.

## Parallel Examples

- US1: T002, T003, T004, T005 en paralelo (4 archivos de test distintos); luego T006→T007→T008 secuencial (setup.sh y el par atómico).
- US2: T010–T014 en paralelo; T015/T016 tras sus tests; T017 independiente de T015/T016.
- US3: T020–T025 en paralelo (6 suites distintas); T026–T031 mayormente paralelos (archivos distintos, salvo T027/T028 ambos en agentctl → secuencial).

## Implementation Strategy

MVP = Phase 3 (US1): con solo US1, el índice local es correcto, durable y consultado por el MCP — valor entregable y probado. Incremento 2 (US2) lo mantiene fresco; incremento 3 (US3) lo hace operable; Phase 6 extiende la promesa a docker. Cada checkpoint deja la suite verde y el repo coherente (commits por fase, patrón 012).
