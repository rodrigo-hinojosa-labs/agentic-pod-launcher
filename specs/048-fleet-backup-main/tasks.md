---
description: "Tareas de 048-fleet-backup-main"
---

# Tasks: Respaldos en main y cierre de los pendientes de la flota

**Input**: `specs/048-fleet-backup-main/` (spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md)

**Tests**: obligatorios. La constitución (Principio III) exige test-first: en cada historia las pruebas se escriben primero, se ven en ROJO contra el código de `origin/main` y recién entonces se implementa.

**Organization**: por historia de usuario (spec.md). Las compuertas del operador llevan la palabra COMPUERTA y no se ejecutan sin su autorización explícita en el momento.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: paralelizable (archivo distinto, sin dependencias abiertas).
- **[Story]**: US1 a US7 de spec.md.
- Rutas relativas a la raíz del repositorio.

## Convenciones de estas tareas

- "Suite completa" = `bats tests/` y `PATH=/bin:$PATH bats tests/`, en serie, nunca a la vez.
- Ningún comando nombra archivos de secretos; las pruebas usan los dobles de 046 (`tests/fixtures/backup-repo/bin/`) y su servidor git (`tests/fixtures/backup-repo/git-auth-server.py`).
- Las pruebas nuevas usan `[ … ]`, `grep -q` o `if cmd; then false; fi` en aserciones intermedias (gotcha de bats en bash 3.2, CLAUDE.md).
- Prefijos de prueba nuevos: `TM` (main, US1/US2), `TL` (migración, US4), `TP` (PR, US2), `TRM` (restauración, US3), `TW` (clon de trabajo, US2), `TD` (doctor y sondas, US6), `TS5` (visibilidad, US5), `EM` (e2e).

---

## Phase 1: Setup

**Purpose**: línea base y mediciones que el diseño necesita (research, M1 y M2).

- [X] T001 Medir la línea base de la suite completa sobre `origin/main` (`6170dda`) en una copia aislada (`git archive origin/main | tar -x -C <scratchpad>/baseline-048`, sin worktree, por preferencia del operador del 21-11-2026; se borra al terminar), en bash 5.x y en 3.2.57, en serie; registrar ok, not ok y saltadas por bash en el Registro de `specs/048-fleet-backup-main/tasks.md`. Esperado de cierre = línea base + pruebas nuevas.
- [X] T002 M1: medir la versión de `git` de la imagen actual (`docker run --rm --entrypoint git agentic-pod:<cualquier tag> --version`) y que soporta `clone --filter=blob:none`, `sparse-checkout set` (cono y no cono), `mktree --missing` y `commit-tree`; medir que construir un commit con R1 (research) y empujarlo desde un clon superficial y parcial no pide al servidor ningún blob fuera de la unidad (peticiones `upload-pack` en el log); medir que el servidor de prueba de 046 sirve clones parciales con `uploadpack.allowFilter=true` y `uploadpack.allowAnySHA1InWant=true`. Registrar en el Registro. Si algo falta, detenerse y replantear R2 con el operador.
- [X] T003 [P] M2: tomar de la documentación oficial de GitHub (*About protected branches*, *Troubleshooting rules*) los textos de rechazo de un push a una rama protegida o con regla (`GH006`, `protected branch hook declined`, rechazo por ruleset) y las respuestas de `PUT /pulls/{n}/merge` (200, 405, 409); citar las URLs en `specs/048-fleet-backup-main/research.md` (sección R7).

---

## Phase 2: Foundational

**Purpose**: la enmienda, el banco de pruebas y las piezas compartidas que usan todas las historias de respaldo. US6 no depende de esta fase.

- [X] T004 Enmendar el Principio V de `.specify/memory/constitution.md` con el texto de `specs/048-fleet-backup-main/contracts/constitution-amendment.md`, versión 1.1.0 → 1.2.0, fecha 2026-11-21 y la fila del Sync Impact Report; confirmar con `grep -rn 'orphan\|backup/' .specify/templates` que las plantillas no necesitan cambios.
- [X] T005 Extender `tests/fixtures/backup-repo/git-auth-server.py` para habilitar los filtros en el `http-backend` (`uploadpack.allowFilter`, `uploadpack.allowAnySHA1InWant`) y sumar dos modos: `protected-main` (un hook `pre-receive` del repo desnudo que rechaza actualizaciones de `refs/heads/main` con el texto de GitHub medido en T003) e `inject-on-push` (antes de aceptar el primer push a `main` de cada conexión, crea en el repo desnudo un commit ajeno sobre `main` que toca `README-work.md`, y lo registra en el log). Sin cambiar los modos de 046.
- [X] T006 [P] Agregar a `tests/helper-backup-repo.bash` los ayudantes `br_main_tree REPO UNIT` (id del subárbol `.agent-backup/<u>` de `main`), `br_main_files REPO UNIT`, `br_main_commits REPO` (sha y archivos tocados por commit), `br_seed_work REPO` (commits de trabajo en `main`: `README-work.md`, `src/app.txt`) y `br_force_count REPO` (empujes forzados en el log del servidor), sin tocar los existentes.
- [X] T007 Escribir primero (ROJO) en `tests/backup-main-units.bats` las pruebas de las piezas compartidas de `docker/scripts/lib/backup_dest.sh`: `TM01` `backup_dest_main_tree` devuelve el subárbol o vacío; `TM02` `backup_dest_check_owner_main` devuelve `new|ok|foreign|other-agent` leyendo `<ref>:.agent-backup/<u>/.agentic-pod-backup.json` sin bajar otros blobs; `TM03` `backup_dest_build_commit` arma un commit cuyo diff contra el padre solo toca las rutas pedidas, con autor `agentic-pod-backup <backup@agentic-pod.invalid>`, asunto `backup(<u>): <agente> <ISO> [skip ci]` y trailer `Agentic-Pod-Backup: <agente>/<u>`; `TM04` el mismo commit reconstruido sobre una punta nueva conserva el subárbol y cambia solo el padre; `TM04b` construir y empujar en un clon `blob:none` no pide blobs ajenos al servidor (I8).
- [X] T008 Implementar en `docker/scripts/lib/backup_dest.sh` `backup_dest_main_tree`, `backup_dest_check_owner_main` (sin alterar `backup_dest_check_owner` de 046) y `backup_dest_build_commit DIR UNIT AGENT PATHS...` según `contracts/main-backup.md` M2 paso 7 (índice temporal solo con las rutas de la unidad, `mktree --missing` para `.agent-backup` y para la raíz, `commit-tree -p FETCH_HEAD`; nunca un `read-tree` del árbol completo), con la guarda `BASH_SOURCE` de la librería; T007 en VERDE en los dos bash.

**Checkpoint**: constitución enmendada, servidor y ayudantes listos, piezas compartidas probadas.

---

## Phase 3: User Story 1 - Cada unidad respalda en su directorio de main (Priority: P1) MVP

**Goal**: con `backup.repo.url`, las cinco unidades escriben `.agent-backup/<u>/` en `main` sin tocar nada más.

**Independent Test**: repo de prueba con trabajo en `main`; correr las cinco unidades; `main` gana exactamente los cinco directorios y el README, el trabajo queda igual, un segundo ciclo no crea commits.

### Tests for User Story 1

- [X] T009 [US1] Escribir primero (ROJO) en `tests/backup-main-units.bats`: `TM05` primer ciclo de cada unidad crea `.agent-backup/<u>/` con su marca y un commit que solo toca esa ruta (I1); `TM06` config además escribe `.agent-backup/README.md` y es la única que lo toca; `TM07` segundo ciclo sin cambios: `no changes since last backup` y 0 commits nuevos (I4, SC-004); `TM08` un archivo borrado del agente desaparece de su directorio y nada fuera cambia; `TM09` agente sensible: el oráculo de cifrado de 046 sobre la nueva raíz (I5); `TM10` repo público o no verificable: no escribe (FR-012); `TM11` repo sin `main`: `no-main`, rc 0; `TM12` el token no aparece en `argv`, URL ni `.git/config` de la caché (I7, espía `br_argv_spy`); `TM13` estado con `location: main` y `last_tree` igual al subárbol remoto; `TM20` un `.agent-backup/<u>/` en `main` sin marca: `foreign-dir`, rc 0, `main` sin cambios (FR-013); `TM21` con la marca de otro agente o de otra unidad: `other-agent`, rc 0, `main` sin cambios.
- [X] T010 [US1] Adaptar las pruebas del camino de repositorio de `tests/backup-repo-units.bats` que afirman ramas `backup/<u>` (TU*) para que afirmen `.agent-backup/<u>/` en `main`, listando cada prueba editada y el motivo en el Registro; las pruebas de fork y sin destino (incluidos los dorados TU19, TU20, TU21) NO se editan. Anotar también qué pruebas de 046 adaptadas cubren el candado, la credencial y los límites de tiempo de FR-012.

### Implementation for User Story 1

- [X] T011 [P] [US1] `docker/scripts/lib/backup_config.sh`: `config_main_prepare URL` (caché `config-main`, `--filter=blob:none`, `fetch --depth 1 origin main`, checkout parcial cono de `.agent-backup/config` y `.agent-backup/README.md`, vaciado del directorio conservando `store/` cuando se pide), `config_main_stage` (las funciones de staging de 046 con raíz `.agent-backup/config/`) y `config_main_readme AGENT` (texto fijo en ASCII: qué es cada directorio, quién lo escribe, cómo restaurar, la recomendación de clonar con `--filter=blob:none`).
- [X] T012 [P] [US1] `scripts/lib/backup_vault.sh`: `vault_main_prepare` y `vault_main_stage_markdown` con raíz `.agent-backup/vault/` (mismo filtro de markdown de 046); verificar si el archivo tiene espejo en `docker/scripts/lib/` y mantenerlo idéntico.
- [X] T013 [P] [US1] `docker/scripts/lib/backup_identity.sh`: `identity_main_prepare` (caché `identity-backup/identity-main`) e `identity_main_stage` con raíz `.agent-backup/identity/` (lista blanca y archivo de secretos cifrado de 046).
- [X] T014 [P] [US1] `docker/scripts/lib/backup_memory.sh` y `docker/scripts/lib/backup_history.sh`: `memory_main_prepare`, `history_main_prepare` y el staging en claro de memory con raíz `.agent-backup/<u>/`.
- [X] T015 [US1] `docker/scripts/heartbeatctl`: camino `main` de la orquestación común. `_repo_verify` lee `refs/heads/main` del archivo de heads (`no-main` si falta); nuevo `_repo_main_owner_ok`; idempotencia por `hash` y `last_tree` (R3, `contracts/main-backup.md` M2 paso 4); `_repo_store_pack` con `--store <caché>/.agent-backup/<u>/store`; `_repo_main_push` que llama `backup_dest_build_commit` y empuja `<commit>:refs/heads/main` sin force; escritura de `location` y `last_tree`; mensaje `backup-<u>: <sha8> pushed to main`. Conectar `_bi_run_repo`, `_bv_run_repo`, `_bc_run_repo` y `_repo_store_unit` al camino `main`. Los resultados nuevos y sus textos, exactamente los de `contracts/main-backup.md` M1.
- [X] T016 [US1] Correr `tests/backup-main-units.bats` (T009) y `tests/backup-repo-units.bats` (T010) en VERDE en los dos bash; correr además los dorados de fork y sin destino (TU19, TU20, TU21, TR06) sin editar.

**Checkpoint**: MVP: las cinco unidades respaldan en `main` en un repo de prueba.

---

## Phase 4: User Story 2 - Los respaldos conviven con el trabajo en main (Priority: P1)

**Goal**: carreras con commits ajenos sin force ni pérdida; clon de trabajo sin `.agent-backup/`; sin CI; camino PR con `main` protegida.

**Independent Test**: `inject-on-push` y dos unidades a la vez; todos los commits ajenos quedan; clon de trabajo no ve el directorio; servidor `protected-main` con y sin merge permitido.

### Tests for User Story 2

- [X] T017 [US2] Escribir primero (ROJO) en `tests/backup-main-units.bats`: `TM14` con `inject-on-push` la unidad reconstruye y empuja, y el commit ajeno es ancestro de `main` (I3); `TM15` 100 ciclos alternando unidades con inyección: 0 commits ajenos perdidos, 0 commits de respaldo con rutas fuera de su directorio, `br_force_count` = 0 (SC-001, SC-002); `TM16` dos unidades en paralelo (dos procesos) quedan ambas en `main`; `TM17` con 5 rechazos seguidos: `main-busy`, rc 2, registro del intento; `TM18` un commit ajeno que modifica `.agent-backup/vault/x.md`: la unidad restaura el directorio y escribe en stderr `was changed outside the launcher - restoring it` (FR-008); `TM19` el asunto de todo commit de respaldo termina en `[skip ci]`; `TM22` una rama de trabajo abierta antes de varios ciclos de respaldo: `git diff main...rama` no lista ninguna ruta bajo `.agent-backup/` (US2, escenario 5).
- [X] T018 [P] [US2] Escribir primero (ROJO) `tests/agent-repo-sparse.bats` con `TW01` a `TW05` de `contracts/work-clone.md` W3 (directorio ausente del árbol de trabajo, commit del agente sin `.agent-backup/`, `git add -f` rechazado por el hook, hook ajeno intacto, fork o sin destino sin efecto) y `TW06`: un clon de trabajo existente de 046 queda con los ajustes nuevos tras `agent_repo_ensure`.
- [X] T019 [P] [US2] Escribir primero (ROJO) `tests/backup-main-pr.bats` con `TP01` a `TP03` de `contracts/pr-fallback.md` P3 y `TP04`: un rechazo por no fast-forward nunca activa el camino PR; `TP05`: `BACKUP_GH_API_BASE` fuera de `https://api.github.com` y `http://127.0.0.1:<puerto>` se ignora.
- [X] T020 [P] [US2] Crear `tests/fixtures/backup-repo/gh-api-server.py`: servidor local de la API de GitHub (`POST /repos/{o}/{r}/pulls`, `PUT .../pulls/{n}/merge`, `PATCH .../pulls/{n}`), con modos `merge-ok` (hace el merge en el repo desnudo del servidor git con `git merge --no-ff`) y `merge-405`; `server_bind` sobreescrito sin `getfqdn` (gotcha de CLAUDE.md); log de método, ruta y código, nunca del token.

### Implementation for User Story 2

- [X] T021 [US2] `docker/scripts/heartbeatctl` (`_repo_main_push`): reintento hasta 5 veces con espera aleatoria de 1 a 5 s y `fetch --depth 1` antes de reconstruir (R4); detección de cambio ajeno en el directorio (`contracts/main-backup.md` M2 paso 5); verificación posterior (paso 9).
- [X] T022 [US2] Crear `docker/scripts/lib/backup_pr.sh` con el contrato P (`backup_pr_merge URL UNIT COMMIT`), el token por `curl -K` 0600 creado y borrado en la llamada, `--max-time 20` por llamada y presupuesto total de 90 s; agregar su línea `COPY` en `docker/Dockerfile` junto a las de `backup_dest.sh`; cablearlo en `_repo_main_push` solo ante los textos de protección de T003.
- [X] T023 [US2] `docker/scripts/lib/agent_repo.sh`: en `_agent_repo_settings` y `_agent_repo_create`, checkout parcial no cono (`/*`, `!/.agent-backup/`), `remote.origin.promisor`, `remote.origin.partialclonefilter=blob:none`, `--filter=blob:none` en la creación y el hook `pre-commit` con la línea `# agentic-pod-launcher: agent-backup guard` (contrato W1).
- [X] T024 [US2] Textos del camino de repositorio (FR-011), en ASCII: en `modules/claude-md.tpl`, la sección `## Backups` del bloque `{{#if BACKUP_REPO_ENABLED}}` (líneas ~244-256: directorios de `main` en vez de ramas) y la sección *Your repository* (W2); en `setup.sh`, el `BACKUP_REPO_NEXT_STEPS` pre-renderizado (~línea 1595); y las menciones del camino de repositorio en `modules/next-steps.{en,es}.tpl`. Escribir primero una prueba que afirme el texto nuevo con repositorio, y que `tests/fixtures/backup-repo/claude-md-backups-section.golden` (sección del FORK, comparada en `tests/agent-repo-surface.bats:393`) siga idéntico: ese dorado NO se edita (FR-019).
- [ ] T025 [US2] T017, T018 y T019 en VERDE en los dos bash.

**Checkpoint**: convivencia probada con carreras, clon de trabajo y `main` protegida.

---

## Phase 5: User Story 3 - El operador restaura desde main (Priority: P1)

**Goal**: `--restore-from-repo` lee de `main` y cae a las ramas.

**Independent Test**: restaurar desde `main`, desde ramas y mixto; mismos archivos y hashes que 046.

- [X] T026 [US3] Escribir primero (ROJO) `tests/backup-main-restore.bats` con `TRM01` a `TRM04` de `contracts/restore-from-main.md` R3' (igualdad de conjunto y hashes entre `main` y ramas, solo ramas como 046, mixto con informe por unidad, R9 de 046 sobre la nueva raíz) y `TRM05`: una marca inválida en `main` cae a la rama con la línea `⚠ restore: .agent-backup/<u> in main has no valid mark — trying backup/<u>`.
- [X] T027 [US3] `setup.sh`: nuevo `_restore_clone_main URL` (`clone --filter=blob:none --depth 1 --no-checkout --branch main`, checkout parcial por unidad) y selección de raíz por unidad en `_restore_store_unit` y en el paso de config de `restore_from_fork`, con las líneas de informe de R2'; sin `local LC_ALL=C` dentro de funciones (gotcha de CLAUDE.md).
- [X] T028 [US3] T026 en VERDE en los dos bash; `tests/backup-repo-restore.bats`, `tests/restore-unified.bats` y `tests/restore-from-fork.bats` en VERDE sin editarse (R-I2).

---

## Phase 6: User Story 4 - Los agentes ya desplegados migran sin perder la restauración (Priority: P2)

**Goal**: cada unidad borra su rama `backup/<u>` solo tras verificar su directorio en `main` y solo con la marca del agente.

**Independent Test**: repo de prueba con las cinco ramas de 046 sembradas (`br_seed_branch`); un ciclo; `main` con los cinco directorios y las ramas borradas; ramas sin marca o ajenas intactas.

- [X] T029 [US4] Escribir primero (ROJO) `tests/backup-main-legacy.bats` con `TL01` a `TL04` de `contracts/legacy-migration.md` L3 y: `TL05` una falla inyectada en la verificación posterior deja la rama (`kept: not-verified`) y el ciclo siguiente la borra; `TL06` un fallo del empuje de borrado deja `kept: delete-failed`; `TL07` el borrado elimina la caché `<u>-repo` de 046; `TL08` una restauración entre la primera escritura en `main` y el borrado funciona desde cualquiera de las dos ubicaciones.
- [X] T030 [US4] Implementar el contrato L: `backup_dest_delete_legacy URL UNIT AGENT HEADS TREE` en `docker/scripts/lib/backup_dest.sh` (lectura de la marca de la rama con `fetch --depth 1 --filter=blob:none`, `push origin :refs/heads/backup/<u>` solo), su llamada al final de cada unidad en `docker/scripts/heartbeatctl` y el campo `legacy_branch` del estado.
- [X] T031 [US4] T029 en VERDE en los dos bash.

---

## Phase 7: User Story 6 - El doctor solo avisa lo que es verdad (Priority: P2)

**Goal**: sin los tres avisos falsos medidos el 21-11-2026. Independiente de las fases 2 a 6: puede hacerse primero.

**Independent Test**: tabla D1 con `curl` falso; doctor con `state.json` real; sonda de Claude con token de entorno.

- [X] T032 [P] [US6] Escribir primero (ROJO) en `tests/token-health-lib.bats` `TD01` a `TD06`: las seis filas de la tabla D1 de `contracts/doctor-and-probes.md` con un `curl` falso que responde por URL y registra cuántas consultas hubo (Jira 2xx/401/403 y 5xx: una sola consulta), y `TD07`: una URL configurada terminada en `/wiki` no duplica `/wiki`.
- [X] T033 [P] [US6] Escribir primero (ROJO) en `tests/token-health-claude-oauth.bats` `TD08` (token de entorno → `skipped 000 0 login by environment token (expiry not observable)`), `TD09` (con token de entorno, un archivo de login ilegible no cambia la salida) y en `tests/token-health-cmd.bats` `TD10` (`check_token_health.sh` llama la sonda con solo el token de entorno).
- [X] T034 [P] [US6] Escribir primero (ROJO) `tests/agentctl-doctor-heartbeat.bats` con `TD11` (estado en `scripts/heartbeat/state.json` con `last_run.status=ok`, `ts` y `duration_ms` → `Heartbeat last run: ok @ <ts> (<ms>ms)`), `TD12` (sin estado → el aviso de hoy) y `TD13` (estado `error` → el fallo de hoy), con el `docker` falso de los otros `agentctl-doctor-*.bats`.
- [X] T035 [US6] Implementar D1 y D2 en `docker/scripts/lib/token_health.sh` (`probe_atlassian`, `probe_claude_oauth`) y en `docker/scripts/check_token_health.sh`; D3 en `scripts/agentctl` (ruta `/workspace/scripts/heartbeat/state.json` y campo `.last_run.ts`).
- [X] T036 [US6] T032 a T034 en VERDE en los dos bash; `tests/agentctl-doctor-token-health.bats` y `tests/heartbeatctl-token-health.bats` en VERDE sin editarse.

---

## Phase 8: User Story 5 - El operador ve y acota el costo de tener los respaldos en main (Priority: P3)

**Goal**: `backup-status` con ubicación y rama heredada; aviso de peso del repositorio.

**Independent Test**: estado sembrado con `location` y `legacy_branch`; API falsa con `size` sobre y bajo 1 GB.

- [X] T037 [US5] Escribir primero (ROJO) en `tests/backup-main-units.bats` `TS501` (`backup-status` muestra las columnas `location` y `legacy` y `--json` expone `location`, `legacy_branch` y `repo_size_kb`) y `TS502` (`repo_size_kb` se consulta a lo sumo una vez por día y se guarda en el registro del destino), y en `tests/agentctl-doctor-freshness.bats` `TS503` (sobre 1.048.576 KB el doctor avisa con el texto de `contracts/doctor-and-probes.md` D4; debajo, no).
- [X] T038 [US5] Implementar D4: `cmd_backup_status` en `docker/scripts/heartbeatctl` (columnas y JSON), la consulta diaria de `size` con `curl -K` (reutilizar el envoltorio de `backup_pr.sh`) y el aviso en `scripts/agentctl`; T037 en VERDE en los dos bash.

---

## Phase 9: Polish & Cross-Cutting

- [X] T039 [P] Crear `tests/docker-e2e-backup-main.bats` (`DOCKER_E2E=1`): `EM01` las cinco unidades empujan a `main` del servidor de prueba desde el contenedor real; `EM02` el clon de trabajo arranca sin `.agent-backup/`; `EM03` la migración borra ramas sembradas tras verificar; `EM04` `git` de la imagen con filtro y checkout parcial (M1 en la imagen nueva). Adaptar `tests/docker-e2e-backup-repo.bats` a `main` declarando cada cambio.
- [X] T040 Documentación: README (sección *Backups*: `main` en vez de ramas, consecuencias aceptadas, cómo clonar con `--filter=blob:none` y excluir `.agent-backup/`, poda solo reescribiendo historia), `docs/heartbeatctl.md` (resultados nuevos, `backup-status`), `docs/state-layout.md` (cachés `-main`, campos nuevos), `docs/architecture.md` (regla de destino y construcción del commit), `docs/getting-started.md`; CLAUDE.md del repo (bloque de 048 y gotchas medidos; `git add -f CLAUDE.md`).
- [X] T041 CHANGELOG (entrada `### Changed` y `### Fixed` de 0.34.0) y VERSION 0.33.0 → 0.34.0, verificando antes `git show origin/main:VERSION`.
- [ ] T042 Catálogo de mutaciones en `specs/048-fleet-backup-main/tasks.md` (Registro), corrido en copias aisladas en los dos bash: como mínimo, quitar la reconstrucción sobre la punta (debe caer TM14/TM15), usar `--force` (TM15 por `br_force_count`), stagear fuera del directorio (TM05/I1), comparar idempotencia por `last_commit` (TM07 con inyección), borrar la rama antes de verificar (TL01), borrar sin leer la marca (TL02), omitir `[skip ci]` (TM19), quitar el `!/.agent-backup/` del clon (TW01), quitar el hook (TW03), consultar Confluence también con Jira 401 (TD02), no quitar `/wiki` (TD07), volver a `logs/state.json` (TD11), leer el archivo de login con token de entorno (TD09). Cada una debe caer en su prueba; un sobreviviente endurece el oráculo antes de seguir.
- [X] T043 Revisión independiente de solo lectura (agente `code-reviewer`) antes del gate final, con foco en: borrado de ramas, construcción del commit, token fuera de `argv`, `set -e` y `pipefail` en los caminos nuevos, y cobertura de las invariantes I1 a I7, L-I1 a L-I4, P-I1 a P-I3; triar y corregir test-first.
- [X] T044 Revisión de privilegios (Principio II) del diff bajo `docker/`: sin capacidades, montajes ni puertos nuevos; registrar en el Registro.
- [X] T045 `shellcheck` con el comando exacto de la CI y suite completa en bash 5.x y 3.2.57, en serie; esperado = línea base de T001 + pruebas nuevas, 0 not ok, stderr vacío.
- [X] T046 `DOCKER_E2E=1` de `tests/docker-e2e-backup-repo.bats` en arm64 local (los casos de 048 se sumaron a ese archivo en T039; no hay `docker-e2e-backup-main.bats`).

---

## Phase 10: User Story 7 - La flota queda migrada, verificada y limpia (Priority: P3)

**Goal**: el contrato G de `contracts/fleet-gate.md`.

- [ ] T047 [US7] COMPUERTA (commit): commits locales en español e imperativo, sin atribución: artefactos de spec-kit y registro de 046; enmienda de la constitución; implementación con sus pruebas; documentación. Ninguno intermedio en rojo.
- [ ] T048 [US7] COMPUERTA (push y PR): push de `048-fleet-backup-main` y PR contra `main` con el resumen, la evidencia de T042 a T046 y el plan de G; CI en verde en los tres checks, con los conteos por brazo en el Registro. El merge lo hace el operador.
- [ ] T049 [US7] Tras el merge: verificar `main` (árbol igual a la cabeza validada, VERSION 0.34.0, constitución 1.2.0) y la primera nocturna posterior (`e2e summary` sin fallas ni saltadas inesperadas).
- [ ] T050 [US7] COMPUERTA (cbum): G2 de `contracts/fleet-gate.md`, con respaldo `pre034` y `--force-claude-md`; comprobar cinco `location: main`, cinco `legacy: deleted`, `.agent-backup/` y README en `main` del repo de cbum, segundo ciclo sin cambios y doctor sin los tres avisos (SC-009).
- [ ] T051 [US7] COMPUERTA (ensayo, lo corre el operador): G3, restauración de cbum desde `main` en la Mac con la llave del M4 en un destino desechable; el asistente compara nombres y sha256 contra cbum vivo sin imprimir contenidos (SC-011) y borra los destinos temporales.
- [ ] T052 [US7] COMPUERTA (linus y donna): G4, uno por vez; ambos con `--force-claude-md` y luego `custom-apply --no-regenerate`, comprobando el bloque `BEGIN overlay` y los MCP del overlay de donna; comprobar que todos los commits previos de su `main` siguen siendo ancestros (SC-005) y que un commit de respaldo no dispara el workflow de donna (M4, SC-007).
- [ ] T053 [US7] COMPUERTA (limpieza): G5, borrar en ferrari y mclaren los respaldos `pre033`, `pre034`, `~/old-clones-20261121/` y `~/<host>-preUpgrade-v033-*`, registrando fecha, ruta y tamaño (SC-012).
- [ ] T054 [US7] Registro final: actualizar la memoria del proyecto y el bloque de 048 en CLAUDE.md con el resultado de la flota.

---

## Dependencies & Execution Order

- Setup (T001 a T003) → Foundational (T004 a T008) → US1 (T009 a T016) → US2 (T017 a T025) y US3 (T026 a T028), que pueden avanzar en paralelo tras US1 → US4 (T029 a T031) → US5 (T037 a T038) → Polish (T039 a T046) → US7 (T047 a T054).
- US6 (T032 a T036) no depende de ninguna fase de respaldo: puede ejecutarse primero, después de T001.
- Dentro de cada historia: pruebas en ROJO → implementación → VERDE en los dos bash.
- T022 depende de T003 (textos de rechazo) y de T020 (servidor de API).

## Parallel Opportunities

- T002 y T003; T005 y T006.
- En US1: T011, T012, T013 y T014 (archivos distintos), después de T009.
- En US2: T018, T019 y T020 (archivos distintos) en paralelo con T017.
- En US6: T032, T033 y T034.
- US2 y US3 en paralelo una vez cerrada US1.

## Implementation Strategy

1. **Valor inmediato**: US6 completa (T032 a T036) apenas termina T001; quita los avisos falsos en cuanto se despliegue.
2. **MVP de respaldo**: Foundational + US1 (las cinco unidades en `main` en un repo de prueba).
3. **Seguro para producción**: US2 (carreras, clon de trabajo, PR) + US3 (restauración) + US4 (migración). Sin estas tres no se despliega.
4. **Visibilidad**: US5.
5. **Cierre**: Polish con el gate completo, y US7 en la flota con cbum como canario.

## Registro

_(Las mediciones, decisiones y resultados de cada tarea se anotan aquí con fecha DD-MM-YYYY.)_

- **/speckit-analyze (21-11-2026): 12 hallazgos (0 CRITICAL, 3 HIGH, 5 MEDIUM, 4 LOW), todos remediados con la aprobación del operador.** HIGH: (C1) el commit sobre la punta se armaba con un índice completo, que en un clon `blob:none` exige o descarga los blobs de las otras unidades y anula R2: ahora `mktree --missing` sobre `ls-tree`, con I8 y TM04b como oráculo y la medición en T002; (C2) T024 mandaba editar el dorado de la sección de Backups del FORK, que FR-019 exige idéntico: ahora se prohíbe y se afirma; (E1) FR-013 no tenía prueba: TM20 y TM21. MEDIUM: textos del camino de repositorio en `## Backups`, `BACKUP_REPO_NEXT_STEPS` y next-steps (T024 ampliada); `--force-claude-md` y `custom-apply` en G2/G4 (T050, T052); línea base con `git archive` en vez de worktree (T001); TM22 para el diff de PR; SC-007 declarado como verificación en vivo. LOW: edge case de rebase por subárbol, umbral de peso, mapa de bloques no reutilizado, cobertura de FR-012 anotada en T010. Sin cambio en el número de tareas (54).

- **T002 / M1 (21-11-2026)**: medido con `/private/tmp/.../scratchpad/m1-probe.sh` (repo desnudo `file://` con `uploadpack.allowFilter` y `allowAnySHA1InWant`). Mac: git 2.53.0; imagen (`agentic-pod:cbum`, ferrari): git 2.54.0. En los dos: `fetch --depth 1 --filter=blob:none`, `sparse-checkout set --cone`, `mktree --missing` y `commit-tree` funcionan; construir el commit con R1 y empujarlo dispara **0** descargas del promisor (eventos `fetch` de `GIT_TRACE2_EVENT`), el diff del commit solo toca `.agent-backup/vault/` y el blob de 512 KiB de `.agent-backup/memory/` queda intacto en el servidor sin haberse bajado. Hallazgo: el modo cono incluye siempre los archivos de la RAÍZ (`README-work.md` se bajó en el checkout, 11 eventos de fetch); para no bajar archivos de trabajo, las cachés de las unidades usan checkout parcial NO cono con el patrón `/.agent-backup/<u>/` (config: además `/.agent-backup/README.md`). Falta medir el filtro sobre el `http-backend` del servidor de 046 (T005).
- **T003 / M2 (21-11-2026)**: documentación de GitHub leída (agente web-fetch). Literal en https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches: `remote: error: GH006: Protected branch update failed for refs/heads/main.` `GH013` (rulesets) NO aparece en https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/troubleshooting-rules: se detecta de forma defensiva, sin afirmar su texto. Códigos de `PUT /pulls/{n}/merge` (https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request, leídos por resumen, no literal): 200 merge hecho, 403, 404, 405 merge imposible, 409 la cabeza no coincide con `sha`, 422 validación. Decisión: un rechazo cuenta como protección si su stderr contiene `GH006`, `GH013`, `protected branch` o `Repository rule violations` (sin distinguir mayúsculas); cualquier otro rechazo que no sea no fast-forward es `push-failed` como en 046.
- **US6 (T032 a T036), 21-11-2026**: ROJO visto antes de cada arreglo. Atlassian: TD01 a TD07 en `tests/token-health-lib.bats` (TD02 y TD03 nacen verdes a propósito: fijan que Jira 401/403/5xx no consulta Confluence; TD01 cayó primero por una trailing space del formato de 046 y su regex se ajustó a `ok 200 N ?$`, el comportamiento no cambió). Claude: TD08, TD08b y TD09 en `tests/token-health-claude-oauth.bats` y TD10 en `tests/token-health-cmd.bats`; ambos archivos ganan `unset CLAUDE_CODE_OAUTH_TOKEN` en su `setup` (hermeticidad frente a un token exportado en la shell; ninguna aserción existente cambió). Heartbeat: `tests/agentctl-doctor-heartbeat.bats` nuevo (TD11 a TD14; TD14 fija que un `logs/state.json` viejo se ignora). Implementación: `probe_atlassian` con fallback (`docker/scripts/lib/token_health.sh`), `probe_claude_oauth` con token de entorno y su llamada en `docker/scripts/check_token_health.sh`, y `scripts/agentctl` con la ruta `scripts/heartbeat/state.json` y el campo `.last_run.ts`. VERDE en bash 5.x y 3.2.57: los seis archivos de token-health y doctor (79 pruebas) y `agentctl-doctor-heartbeat.bats` con `agentctl-doctor-freshness.bats` (18). `shellcheck -S error` limpio en los tres archivos.
- **T004 (21-11-2026)**: Principio V enmendado con el texto del contrato K (versión 1.2.0, *Last Amended* 2026-11-21, nuevo Sync Impact Report 1.1.0 → 1.2.0); la viñeta del cifrado pasa de "backup branches" a "backups" y el rationale de "branches" a "units". `grep -rn 'orphan\|backup/' .specify/templates` = 0: sin plantillas que actualizar; ninguna prueba lee la constitución.
- **Checkpoint WIP (22-11-2026)**: commit local `d3d499d` (`wip: 048 en curso ...`), sin push, por decisión del operador; T047 lo rehace en commits limpios.
- **Cambios de diseño medidos en la implementación (22-11-2026)**, registrados también en research.md:
  - **Caché local + clon de publicación.** Cada unidad sigue preparando y commiteando en su propia caché (`<u>-repo`, el código de 046 casi intacto: con `BACKUP_REPO_TARGET=main` no hace fetch de su rama ni empuja). Su árbol se publica en `main` desde un clon BARE `blob:none` de profundidad 1 (`<u>-main`) con un alternate hacia la caché de la unidad: solo árboles, la marca y los objetos propios. No hace falta checkout parcial en las cachés (T011 a T014 se resolvieron así, sin funciones `<u>_main_*` por unidad). La pieza compartida vive en una librería nueva, `docker/scripts/lib/backup_main.sh` (con su `COPY`), y no en `backup_dest.sh`, cuyo encabezado promete no commitear.
  - **Sin fetch si `main` no se movió.** El estado guarda `main_tip`; si la cabeza de `main` del `ls-remote` coincide, el ciclo sin cambios no hace ningún fetch (conserva el costo de 046; TU33 lo exige).
  - **Mensajes.** El éxito conserva el texto de 046 (`backup-<u>: <sha8> pushed`); el destino lo dice `backup-status`.
  - **Rechazo por carrera.** Además de `non-fast-forward`/`fetch first`, el `http-backend` responde `remote rejected ... (incorrect old value provided)` cuando `main` cambia entre el anuncio y el empuje (medido con `inject-once`); cuenta como `main` movida.
  - **Borrado de la rama heredada.** La caché `<u>-repo` NO se borra (es la caché local del camino main); TL07 cambia a "la caché sobrevive".
  - **Restauración.** Las líneas restauradas desde `main` terminan en ` (from main)`; las de una rama quedan con el texto de 046, para que el fork siga byte a byte igual.
- **Estado de US1, US3 y US4 (22-11-2026)**: `tests/backup-main-units.bats` (TM01 a TM04c de la librería, TM05 a TM13, TM20, TM21, TM14 a TM19 y TM22), `tests/backup-main-legacy.bats` (TL01 a TL08) y `tests/backup-main-restore.bats` (TRM01, TRM02, TRM03 y TRM05; TRM04 queda cubierto por TR08, TR11, TR12 y TR13 adaptadas) en VERDE en bash 5.x. Desviación de test-first declarada: la librería, la restauración y la migración se escribieron junto con sus pruebas o antes; su capacidad de fallar se comprobó con mutaciones (sin verificación antes del borrado: cae TL05; sin leer la marca: cae TL02) y el resto entra en el catálogo de T042. T010: 24 pruebas de `tests/backup-repo-units.bats` y 8 de `tests/backup-repo-restore.bats` dependían de ramas; 15 se resolvieron con un adaptador del arnés (`_br_main_loc` en `tests/helper-backup-repo.bash`: las funciones `br_branch_*` y `br_clone_branch` leen `.agent-backup/<u>/` de main cuando la rama `backup/<u>` no existe) y se reescribieron TU01 (segunda pierna: repo vacío = `no-main`), TU17, TU18, TU23, TU03, TU33, TU39, TU12 y TU40 (en TU40 la segunda pierna cambia de semántica: un destinatario reemplazado en main ya no hace rotar la llave, porque la caché es local; el ciclo restaura el directorio), y en TR los ayudantes que falsifican contenido (`_tr_forge_block`, `_tr_forge_manifest`, TR02, TR11, y la siembra de `agent.yml` de TR08 y TR12) pasaron a escribir en main. Ninguna prueba de fork ni sin destino se editó.
- **T001 línea base (21 y 22-11-2026)**: copia aislada de `origin/main` (`6170dda`) con `git archive`, sin worktree. bash 5.3.15: 2196 ok, 0 not ok, 69 saltadas, 3142 s; bash 3.2.57: 2196 ok, 0 not ok, 70 saltadas, 2754 s; stderr vacío en los dos. Esperado de cierre: 2196 + las pruebas nuevas de 048.
- **US2 restante, US3 y US5 (22-11-2026)**: clon de trabajo (`tests/agent-repo-sparse.bats`, TW01 a TW06, ROJO visto en TW01, TW03, TW04 y TW06; TW02 y TW05 nacen verdes a propósito) con checkout parcial no cono, filtro `blob:none` y hook `pre-commit` del launcher en `docker/scripts/lib/agent_repo.sh`; textos del camino de repositorio (TA07 actualizada al texto nuevo y vista en ROJO; la sección de Backups del FORK y su dorado no cambian, TA06 en verde); camino de PR en `docker/scripts/lib/backup_pr.sh` (con su `COPY`) y API falsa `tests/fixtures/backup-repo/gh-api-server.py` (TP01 a TP05, en verde); restauración desde main (TRM01 a TRM05); visibilidad: `backup-status` con `location` y `legacy_branch` por unidad y `repo_size_kb`, que la unidad config consulta a lo sumo una vez al día y guarda en `scripts/heartbeat/backup-repo-size.json` (no en `backup-dest.json`, que `backup_dest_verify` reescribe: medido en TS502), y aviso del doctor sobre 1 GB (TS501 y TS503 en `tests/backup-status.bats`, ROJO visto; TS502 en `tests/backup-main-pr.bats`).
- **T040 y T041 (22-11-2026)**: README (sección *Backups in `main` (0.34.0)*, filas de destino y unidades, tamaño y poda), `docs/heartbeatctl.md`, `docs/state-layout.md`, `docs/architecture.md`, `docs/getting-started.md`, CLAUDE.md del repo (párrafo del camino main y bloque de estado de 048), CHANGELOG (`### Changed` de 048 y la viñeta de `### Fixed` del doctor) y VERSION 0.33.0 → 0.34.0 (`git show origin/main:VERSION` = 0.33.0).
- **T039 (22-11-2026)**: en vez de un archivo e2e nuevo con otra imagen, los casos de 048 se suman a `tests/docker-e2e-backup-repo.bats`, que ya construye el contenedor con repositorio: TE3 adaptado (main se mueve; el clon de trabajo deja fuera `.agent-backup/` y tiene el hook), EM01 (cinco directorios y README en main, sin ramas `backup/*`, sin force) y EM03 (migración en el contenedor). TE1, TE2, TE5 y TE7 leen main a través del adaptador del arnés. EM02 y EM04 quedan cubiertos por TE3 y por TE1 (el `git` de la imagen ejerce `mktree --missing`). Se corre en T046.
- **T043 revisión independiente (22-11-2026, agente `code-reviewer`, solo lectura)**: 0 ALTA, 5 MEDIA, 9 BAJA. Corregidas: M1 (un fallo de `ls-tree` se leía como "sin `.agent-backup`" y el commit habría borrado los directorios de las otras unidades: ahora se distingue la ausencia por el tipo del objeto; el primer arreglo usó `<rev>:<ruta>^{tree}`, que git lee como parte de la ruta, y TM04b, TM05, TM07, TM09, TM15 y TM16 lo cazaron de inmediato); M2 (una marca existente que no se puede leer es `unreachable`, no `foreign-dir`; en la rama heredada, `kept: not-verified`); M3 (el empuje de la rama del PR conserva el tope por unidad de 046 y el presupuesto de la API empieza después); M4 (la restauración dice `could not read main of <url>` cuando el clon de main falla por otra cosa que "no hay main"); M5 (TL03 era vacua: el servidor de prueba registra ahora las referencias de cada empuje y TL03 exige que el borrado viaje solo); B1 (TM05 usa `_tm_one_unit_only`); B2 (borrado con `--force-with-lease` sobre la punta cuya marca se leyó); B3 (el README de config cuenta en "sin cambios"); B5 (`location`/`legacy_branch` solo aparecen en `backup-status` cuando el estado los tiene: la salida con fork queda igual); B6 (el hook lee rutas sin comillas); B8 (contrato L y el texto del aviso del doctor; además, la caché local acumulaba un commit por ciclo con todo el almacén: ahora cada ciclo del camino main empieza un historial nuevo en su lugar, conservando el árbol y `store/`, y TM23 lo fija). Aceptadas y declaradas: B4 (el archivo de configuración de `curl` con el token vive milisegundos en el tmpfs del contenedor, 0600, sin `trap`), B7 (la restauración desde main valida la unidad de la marca, no el agente, igual que 046 con las ramas), B9 (el token de Atlassian en el argv de `curl` es de antes de 048 y queda fuera de alcance) y el costo de B5 en `--restore-from-fork` (cinco clones sin blobs de main del fork antes de caer a sus ramas; la salida no cambia).
- **T044 revisión de privilegios (22-11-2026)**: el diff bajo `docker/` agrega dos líneas `COPY` (`backup_main.sh`, `backup_pr.sh`) y código que corre como `agent`; sin `cap_add`, montajes, puertos, `su-exec` ni cambios de usuario; `modules/docker-compose.yml.tpl` sin cambios. El camino de PR usa la red saliente y la credencial que 046 ya usaba.
- **Revisión de seguridad automática (22-11-2026, sobre `faad4be`)**: MEDIA, el merge del PR no estaba fijado al commit del respaldo (una rama del PR movida entre el empuje y el merge se habría mergeado). Corregido: el merge envía `sha` = el commit del respaldo (GitHub responde 409 si la rama cambió) y la rama temporal lleva un sufijo aleatorio (`agent-backup-pr/<u>-<epoch>-<12 hex>`). TP06 nueva (la API falsa mueve la rama antes del merge): ROJO comprobado quitando el `sha`, VERDE con el arreglo. Este cambio entra después de la cabeza del primer gate; lo cubre el segundo gate.
- **Primer gate (22-11-2026, sobre `faad4be`)**: mutaciones 20 de 20 cazadas en bash 3.2.57 (en 5.x, 19 de 20 y M02 cerrada con TM24). Suite en bash 5.3.15: 2265 ok, 1 not ok, 71 saltadas, 3858 s, stderr vacío. La falla, TS501, era real y de producto: desde B5 una unidad sin `location` en su estado no lleva el campo, `jq` lo lee como `null`, `null != ""` es verdadero, y la tabla de `backup-status` inventaba `location <u>: branch:backup/<u>` para cada unidad sin estado; la aserción de JSON de TS501 (que esperaba `""`) era la que fallaba, y ninguna miraba la tabla. Corregido con `// ""` en el filtro de la tabla; TS501 ahora exige que esa unidad no traiga ninguno de los dos campos y que la tabla muestre una sola línea `location` (ROJO visto en esa aserción antes del arreglo). El brazo 3.2 del primer gate no corrió por un error del guion del gate (una variable de zsh), no del producto.
- **T045 segundo gate (22-11-2026, sobre el árbol de trabajo posterior a `faad4be`: el `sha` del merge, TP06 y TS501)**: `shellcheck` con el comando de la CI, rc 0 y salida vacía. bash 3.2.57: 2266 ok, 1 not ok, 74 saltadas, 3178 s; bash 5.3.15: 2266 ok, 1 not ok, 73 saltadas, 3521 s; stderr vacío en los dos; total 2267 = 2196 de la línea base + 71 de 048. La falla, TU31 en los dos bash, y dos de las saltadas de más (las dos `037 claude-md.tpl`, que piden la rama `main`) son del armado del gate: la copia con `git archive` no tenía `.git` y TU31 usa `git ls-files`. Las tres se repitieron en el checkout real, que sí lo tiene, y pasan en los dos bash. Las otras saltadas nuevas son EM01 y EM03, e2e de 048 que piden `DOCKER_E2E=1` (T046). La diferencia de una saltada entre los bash es la de siempre (`read -t` de qmd_watch pide bash 4+).
- **T046 (22-11-2026)**: `DOCKER_E2E=1 bats tests/docker-e2e-backup-repo.bats` en arm64 local (Docker 29.8.0) sobre el mismo árbol del segundo gate: 10 de 10 en 180 s, stderr vacío, incluidos EM01 y EM03 de 048 y TE1 a TE8 leyendo main a través del adaptador.
