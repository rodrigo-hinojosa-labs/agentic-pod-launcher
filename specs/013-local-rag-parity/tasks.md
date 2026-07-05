# Tasks: RAG local agnóstico al modo de instalación

**Input**: Design documents from `/specs/013-local-rag-parity/` — plan.md (D1–D12), research.md (R1–R12), data-model.md (E1–E5), contracts/ (4), quickstart.md (gates)

**Tests**: OBLIGATORIOS (Constitution III, test-first) — cada tarea de test se escribe y se ve FALLAR (RED) antes de su implementación.

**Organization**: por user story; US1 y US2 son P1 (US1 = MVP), US3 = P2, FR-016 transversal en fase propia.

*(T041–T043 fueron añadidos por la remediación del `/speckit-analyze` 2026-07-05; ejecutan en la posición de su fase, no en orden numérico.)*

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
- [ ] T043 [P] [US1] Test RED: en `tests/local-qmd.bats`, migración simulada (SC-002, analyze G4) — `cp -a` del workspace stubbeado (con sentinel + índice fake bajo `.state/.cache/qmd`) a otra ruta: `qmd_setup_if_needed` es no-op por sentinel-hit en el destino y ningún path absoluto del origen queda embebido en el estado
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
- [ ] T018 [US2] Test: en `tests/local-qmd.bats`, el render de `agent-<n>-qmd-watch.service` queda byte-idéntico al contrato v0.6.0 (la unit NO cambia; solo el wrapper) — *guard post-implementación por naturaleza (asevera no-cambio; se escribe verde — excepción C2 del analyze, Principio III usa SHOULD)*
- [ ] T019 [US2] Verificar: `bats tests/local-qmd.bats tests/local-vault-backup.bats tests/qmd-setup.bats tests/qmd-index.bats tests/qmd-watch.bats` verdes + `shellcheck -S error scripts/lib/qmd_index.sh`

**Checkpoint**: US1+US2 = RAG local funcional y fresco; el resto es operabilidad.

## Phase 5: User Story 3 — Operabilidad honesta y control total (P2)

**Goal**: kill-switch completo (FR-008), doctor/status honestos + exit codes (FR-009, FR-013), acciones manuales (FR-010), healthcheck del watcher (FR-011), NEXT_STEPS (FR-012). Contrato: `contracts/local-ops-parity.md`.

**Independent Test**: bats sobre `agentctl` y renders con `systemctl` y state files stubbeados.

- [ ] T020 [P] [US3] Test RED: crear `tests/local-killswitch.bats` — el render del kill switch lista en `AUX_UNITS` las 4 units auxiliares (`qmd-reindex.timer`, `qmd-watch.service`, `vault-backup.timer`, `healthcheck.timer`)
- [ ] T021 [P] [US3] Test RED: en `tests/agentctl-local.bats` — doctor con `qmd-index.json` fixture `last_status=error` → warn + exit 1; `vault-backup.json` stale >25h con fork → warn staleness; unit qmd-watch en `failed` (systemctl stub) → warn + exit 1 (tercer escenario de SC-005, analyze G1); units staged sin instalar → status/doctor reportan "staged" (blinda el reporte 012 de `agentctl:947-952`, analyze G2); todo sano → exit 0; `status` imprime `last_run`
- [ ] T022 [US3] Test RED: en `tests/agentctl-local.bats` — `agentctl heartbeat qmd-reindex` y `heartbeat backup-vault` en workspace local ejecutan el script correspondiente de `scripts/local/` (stub registra invocación) y NO imprimen el error "Docker-mode command"; `heartbeat backup-vault --dry-run` pasa el flag; `heartbeat qmd-reindex --dry-run` → error explícito SIN ejecutar el script (política D8, analyze U3) — *misma suite que T021: secuencial tras T021, no [P]*
- [ ] T023 [P] [US3] Test RED: en `tests/local-healthcheck.bats` — el render incluye el chequeo `is-failed` de la unit qmd-watch gated por su existencia; con systemctl stub en failed → WARN (nunca DEGRADED); sin la unit → silencio
- [ ] T024 [P] [US3] Test RED: en `tests/scaffold.bats` — NEXT_STEPS en/es local: con qmd on + vault on → `journalctl -u` de las 3 units + `systemctl list-timers`; con qmd on + vault off → sin la línea de vault-backup; con qmd off → bloque ausente; y render DOCKER de NEXT_STEPS en/es byte-idéntico a v0.6.0 (plantilla compartida entre modos, analyze U2/constitución)
- [ ] T025 [P] [US3] Test RED: en `tests/local-schedule.bats` — la señal `CRON_FALLBACK` de `scripts/lib/local_schedule.sh` queda en 0 con formas exactas (incluido `*/5 * * * *`, que convierte EXACTO al default — el caso del falso positivo, analyze U1) y en 1 con formas no soportadas; y el flujo de regenerate crea `scripts/heartbeat/qmd-schedule.fallback` (original + applied) solo con señal 1, eliminándolo con señal 0 (FR-013/R10/D10)
- [ ] T026 [US3] Implementar `modules/local-killswitch.sh.tpl`: AUX_UNITS completo (D11)
- [ ] T027 [US3] Implementar en `scripts/agentctl`: `_local_vault_qmd_doctor` (last_status → `_doctor_warn`, staleness vía `_check_backup_freshness <agent> vault 25`, chequeo `systemctl is-failed` de la unit qmd-watch → warn, reporte del marker de fallback; el reporte "staged" existente de 012 se conserva), `_local_vault_qmd_status` (+`last_run`), `cmd_local_doctor` con epílogo de exit codes 0/1/2 de `cmd_doctor` (D9)
- [ ] T028 [US3] Implementar en `scripts/agentctl`: dispatch local de `heartbeat qmd-reindex`/`heartbeat backup-vault` → exec directo del script del workspace; política de flags D8 — `--dry-run` solo se pasa a backup-vault, `qmd-reindex --dry-run` rechaza con error explícito (analyze U3); demás subcomandos docker-only conservan su error+hint
- [ ] T029 [US3] Implementar `modules/local-healthcheck.sh.tpl`: WARN si `agent-<n>-qmd-watch.service` existe y está failed (D11)
- [ ] T030 [US3] Implementar `modules/next-steps.en.tpl` y `modules/next-steps.es.tpl`: bloque `{{#if VAULT_QMD_ENABLED}}` (journal de qmd-reindex/qmd-watch + list-timers) y, como bloque HERMANO secuencial — NUNCA anidado, el engine rompe if-dentro-de-if (`render.sh:126`, analyze U2) —, `{{#if VAULT_ENABLED}}` con la línea de vault-backup; ambos dentro del `{{#unless DEPLOYMENT_MODE_IS_DOCKER}}` existente (if-dentro-de-unless SÍ funciona: el pass de #if precede al de #unless) (FR-012)
- [ ] T031 [US3] Implementar D10 (analyze U1/C1): `scripts/lib/local_schedule.sh` setea la variable global `CRON_FALLBACK=0|1` al convertir (rc/stdout intactos, source-safe); `setup.sh` la consulta tras cada conversión en el render local y crea/elimina `scripts/heartbeat/qmd-schedule.fallback` (original + applied + timestamp); el render en modo docker elimina el marker incondicionalmente (cubre mode-switch local→docker)
- [ ] T041 [US3] Test RED: en `tests/deployment-mode.bats` — scaffold/regenerate local con `vault.qmd.enabled=true` e `install_service=false` imprime la advertencia "RAG sin trigger automático"; con `install_service=true` o qmd off, no la imprime (D13, analyze G3)
- [ ] T042 [US3] Implementar D13 en `setup.sh`: advertencia post-respuesta cuando modo local + qmd habilitado + servicio no instalado (printf, sin prompt nuevo — no toca wizard_answers/e2e-smoke/schema)
- [ ] T032 [US3] Verificar: `bats tests/local-killswitch.bats tests/agentctl-local.bats tests/local-healthcheck.bats tests/scaffold.bats tests/local-schedule.bats tests/deployment-mode.bats` verdes + `shellcheck -S error scripts/agentctl setup.sh scripts/lib/local_schedule.sh`

## Phase 6: FR-016 — bunx en la imagen docker (transversal)

**Goal**: QMD en docker funciona contra binarios reales. Contrato: `contracts/docker-qmd-runtime.md`.

- [ ] T033 Test RED: en `tests/docker-render.bats` (drift-guard host, sin Docker) — el bloque bun de `docker/Dockerfile` contiene la línea `ln -s /usr/local/bin/bun /usr/local/bin/bunx`
- [ ] T034 Implementar en `docker/Dockerfile`: symlink `bunx` tras el `chmod +x` de bun (única línea docker de 013; sin pin nuevo) (D7)
- [ ] T035 Test: en `tests/docker-e2e-qmd.bats` — aserción contra la imagen real: `test -x /usr/local/bin/bunx && readlink` → apunta a `bun` (independiente del stub de PATH) — *post-T034 por naturaleza: exige la imagen reconstruida y está gated por DOCKER_E2E (excepción C2 del analyze)*

## Phase 7: Polish & Gates

- [ ] T036 [P] Actualizar `CHANGELOG.md` (entry 013: 3 causas raíz, par atómico, 2 excepciones docker declaradas, nota de limpieza manual legacy `~/.cache/qmd`//`~/.config/qmd` para instalaciones locales pre-013) y `VERSION` 0.6.0 → 0.7.0
- [ ] T037 [P] Actualizar `docs/architecture.md`: sección vault/RAG modo local — contrato real de env (`XDG_CACHE_HOME`/`QMD_CONFIG_DIR`), loop del watcher, acciones manuales de `agentctl`
- [ ] T038 Suite host completa: `bats tests/` verde total + `shellcheck -S error` global (comparar contra el baseline de T001)
- [ ] T039 Gate DOCKER_E2E (obligatorio por FR-015/FR-016): `DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats tests/docker-e2e-vault.bats tests/docker-e2e-smoke.bats` verdes (smoke: reintentar aislado si flakea en 1er boot)
- [ ] T040 Gate manual confirmatorio (quickstart.md gates 4–5): mclaren (diferido — host caído; los 3 fallos predichos por la auditoría verificados corregidos) y ferrari (post-merge: rebuild + qmd on + `claude mcp list` Connected)

## Dependencies

- T001 → todo lo demás.
- US1 (T002–T009) → US2 (T010–T019): comparten `local-qmd-reindex.sh.tpl` (T007 antes de T015).
- US3 (T020–T032, T041–T042) depende solo de Setup; archivos disjuntos de US2, pero **comparte `setup.sh` con US1** (T006/T008 antes de T031/T042) — el orden P1→P2 recomendado lo resuelve solo.
- Phase 6 (T033–T035) es independiente de US1–US3 (solo docker/Dockerfile + e2e) — paralelizable con cualquier fase.
- Polish (T036–T040) al final; T039 requiere T017 (lib) y T034 (Dockerfile) hechos.

## Parallel Examples

- US1: T003, T004, T005 en paralelo (suites distintas); T002→T043 secuencial (ambos en `local-qmd.bats`); luego T006→T007→T008 secuencial (setup.sh y el par atómico).
- US2: T011 y T014 en paralelo; T010→T012→T013 secuencial (los tres en `local-qmd.bats`; T018 también, al final); T015/T016 tras sus tests; T017 independiente de T015/T016.
- US3: T020, T023, T024, T025, T041 en paralelo (suites distintas); T021→T022 secuencial (ambos en `agentctl-local.bats`); T026–T031 mayormente paralelos (archivos distintos, salvo T027/T028 ambos en agentctl → secuencial; T031/T042 ambos en setup.sh → secuencial).

## Implementation Strategy

MVP = Phase 3 (US1): con solo US1, el índice local es correcto, durable y consultado por el MCP — valor entregable y probado. Incremento 2 (US2) lo mantiene fresco; incremento 3 (US3) lo hace operable; Phase 6 extiende la promesa a docker. Cada checkpoint deja la suite verde y el repo coherente (commits por fase, patrón 012).
