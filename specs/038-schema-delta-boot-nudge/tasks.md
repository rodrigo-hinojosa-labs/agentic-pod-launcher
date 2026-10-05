---

description: "Task list for 038-schema-delta-boot-nudge"
---

# Tasks: Aviso de actualización de conocimiento al iniciar sesión

**Input**: `specs/038-schema-delta-boot-nudge/` (plan.md, spec.md, research.md, data-model.md, contracts/,
quickstart.md)

**Prerequisites**: rama `038-schema-delta-boot-nudge` sobre `037-second-brain-rag` (VERSION 0.27.0). No mergear
antes que 037.

**Tests**: obligatorios (Constitución III, test-first). Cada tarea de implementación tiene antes su tarea RED;
se confirma que el test falla por la razón correcta antes de escribir código, y se confirma GREEN después.

**Organización**: por historia de usuario. US1 (docker) es el MVP: cubre a donna y linus, donde se midió la
falla. US4 (local) depende del gate G0.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: paralelizable (archivo distinto, sin dependencia de una tarea incompleta).
- **[Story]**: US1-US4 según spec.md.
- Rutas relativas a la raíz del repo. Contratos: `CVP` = `contracts/vault-pending-deltas.md`, `CMR` =
  `contracts/claude-md-refresh.md`, `UNH` = `contracts/upgrade-notice-hook.md`.

## Reglas transversales (aplican a toda tarea)

- bash 3.2 a 5.3: sin constructos bash-4-only, sin `local LC_ALL=C` dentro de funciones de `setup.sh`.
- Nunca `producer | grep -q` bajo `pipefail`; leer a variable y decidir con `case`, o `grep -q` sobre archivo.
- Comparaciones de archivos con `cmp -s`, nunca mtime ni hash.
- Negativos en bats al final del test, o como `run …; [ "$status" -ne 0 ]` (un `!` intermedio no falla).
- Payloads grandes por archivo, nunca por argv/env (límite de 128 KiB por string en Linux).
- Auditoría de bytes tras cada edición de `.md`, `.tpl` o `.bats`: `LC_ALL=C grep -c $'\xcc\x80'` y
  `$'\xcc\x81'` en 0. Los textos CANON del aviso son ASCII puro.
- Suites dual bash siempre secuenciales, nunca concurrentes (la contención produce rojos falsos).

---

## Phase 1: Setup

**Purpose**: línea base, gate de factibilidad local y auditoría de impacto antes de tocar código.

- [X] T001 Línea base de suites en el árbol actual: `bats tests/` (bash 5.x) y luego `PATH=/bin:$PATH bats tests/` (bash 3.2.57), secuenciales; anotar en Notes de `specs/038-schema-delta-boot-nudge/tasks.md` el SHA de HEAD y los conteos `ok`/`not ok` de cada una. Si hay rojos, identificar si son preexistentes antes de seguir.
- [ ] T002 [P] Gate G0 (quickstart §7, research R7), con el operador: en ferrari-admin (`ssh ferrari`, workspace `~/Documents/Personal/Claude/Agents/ferrari-admin`) respaldar `.state/.claude/settings.json`, agregar un hook `SessionStart` sonda (script en el workspace que hace `cat >> <ws>/.state/038-g0-probe.jsonl`), reiniciar `agent-ferrari-admin.service` (requiere sudo del operador), pedirle al operador que abra una sesión desde el cliente de Remote Control, leer el archivo. Restaurar el `settings.json` respaldado y borrar la sonda. Anotar en Notes: fecha, versión de `claude`, si disparó y el `source` recibido. Resultado decide el alcance de US4.
- [X] T003 [P] Auditar tests afectados por el re-render automático (CMR §"Efectos sobre tests existentes"): `grep -n 'CLAUDE.md' tests/*.bats` y revisar cada test que (a) corre regenerate más de una vez cambiando `agent.yml` o la persona y espera `CLAUDE.md` intacto, o (b) asierta líneas de salida de regenerate sobre `CLAUDE.md`. Anotar la lista con archivo:línea en Notes; es la entrada de T025.

---

## Phase 2: Foundational (bloqueante para todas las historias)

**Purpose**: las dos librerías de detección y el campo nuevo de `agent.yml`.

**CRITICAL**: ninguna historia empieza antes de cerrar esta fase.

- [X] T004 [P] RED `tests/vault-pending-deltas.bats` (nuevo; `load_lib vault`), casos de CVP: (a) raíz vacía, inexistente o sin `_templates/` → salida vacía, código 0; (b) `.applied` de 0.27.0 sin hito → `0.27.0`; (c) ambos `.applied` sin hitos → `0.8.0` y `0.27.0` en ese orden, una por línea; (d) hito de 0.8.0 presente a mitad de línea (`see wiki/normalization/ folder`) → solo `0.27.0`; (e) ambos hitos → vacío; (f) `.applied` presentes y sin `CLAUDE.md` → vacío; (g) `CLAUDE.md` con `chmod 000` → vacío (skip si corre como root); (h) `vault_delta_checkpoint 9.9.9` → código 1 sin salida; (i) `vault_delta_versions` imprime exactamente `0.8.0` y `0.27.0`. Guardias de deriva: (G1) cada `modules/vault-deltas/schema-updates-*.md` tiene hito y cada versión tiene documento; (G2) `modules/vault-skeleton/CLAUDE.md` contiene cada hito (`grep -F`); (G3) el literal del `grep -F` de `integrated` en `scripts/lib/wiki_graph.sh` es igual a `vault_delta_checkpoint 0.27.0`; (G4) `modules/vault-deltas/schema-updates-0.27.0.md` contiene su hito.
- [X] T005 [P] RED `tests/claude-md-refresh.bats` (nuevo), sección "lib" (`load_lib claude_md`), con archivos `C`/`U`/`B` en `$TMP_TEST_DIR`. `claude_md_state`: `U` ausente → `unknown`; `C=U` con y sin `B` → `in_sync`; `C≠U`, `B=U` → `customized`; `C≠U`, `B≠U` → `pending_template`; `C≠U` sin `B` → `pending_no_baseline`; `C` ausente con `U` → `pending_no_baseline`; `U` con `chmod 000` → `unknown` (skip si root). `claude_md_regenerate_decision C U B force launcher_own`: `C` ausente → `render`; `force=true` con `C` editado → `render`; `launcher_own=true` → `render`; `B` existe, `C=B`, `C≠U` → `refresh`; `C=U` sin `B` → `adopt`; `C=U` con `B` distinta → `adopt`; `C=U=B` → `noop`; `C` editado (`C≠B`, `C≠U`) → `preserve`; `force` gana sobre `refresh`. Todas con código 0 y un solo token en stdout.
- [X] T006 [P] RED `tests/upgrade-notice-config.bats` (nuevo; molde `tests/askq-guard-config.bats`): (a) `agent.yml` sin `features.upgrade_notice` → tras `--regenerate`, `enabled: true`; (b) `enabled: false` explícito sobrevive dos regenerate (backfill con `has()`, no `//`); (c) el segundo regenerate deja `agent.yml` byte-idéntico al primero (`cmp -s` contra copia); (d) `enabled: yes` → `agent_yml_validate` (`scripts/lib/schema.sh:106`) lo rechaza (molde `tests/schema-validate.bats`); (e) `tests/fixtures/sample-agent.yml` y `sample-agent-with-vault.yml` tienen el campo (la prueba de placeholders de `tests/schema.bats` lo exige).
- [X] T007 GREEN `scripts/lib/vault.sh`: agregar `vault_delta_versions`, `vault_delta_checkpoint` y `vault_pending_deltas` según CVP, junto a `vault_seed_missing` sin modificarla. Sin efectos al cargar. Comprobar `[ -r "$root/CLAUDE.md" ]` antes del bucle. T004 en verde.
- [X] T008 GREEN `scripts/lib/claude_md.sh` (nuevo): `claude_md_state` y `claude_md_regenerate_decision` según CMR, solo `cmp`/`test`, sin `yq`, cabecera y guardia de carga como el resto de `scripts/lib/`. T005 sección lib en verde.
- [X] T009 GREEN configuración: `'.features.upgrade_notice.enabled'` en `_SCHEMA_BOOLEANS` de `scripts/lib/schema.sh`; bloque `upgrade_notice: { enabled: true }` en el heredoc del wizard de `setup.sh` justo después de `askuserquestion_guard` (`setup.sh:1264-1266`); backfill con `has()` en `regenerate()` después del de `askuserquestion_guard` (`setup.sh:2316-2326`), con comentario `# 038:`; el mismo bloque en `tests/fixtures/sample-agent.yml` y `tests/fixtures/sample-agent-with-vault.yml`. T006 en verde.
- [X] T010 Checkpoint: `bats tests/vault-pending-deltas.bats tests/claude-md-refresh.bats tests/upgrade-notice-config.bats tests/schema.bats tests/schema-validate.bats tests/vault.bats` en bash 5.x y luego en 3.2.57; 0 `not ok`. Auditoría de bytes.

**Checkpoint**: detección lista y testeada; las historias pueden empezar.

---

## Phase 3: User Story 1 - El agente sabe al iniciar sesión qué tiene pendiente (Priority: P1) MVP

**Goal**: en modo docker, cada inicio de la sesión interactiva recibe el aviso CANON mientras haya pendientes, y
nada cuando no los hay. Las sesiones de heartbeat no lo reciben.

**Independent Test**: hook renderizado ejecutado con stdin falso contra estados fabricados de vault y workspace
(sin depender de US2, que solo produce `U` en regenerate: aquí `U` y `B` se crean a mano).

- [X] T011 [P] [US1] RED `tests/upgrade-notice-hook.bats` (nuevo), sección "hook". Setup: workspace temporal con `scripts/`, `modules/`, `setup.sh` y un `agent.yml` docker como el de `tests/regenerate.bats` (`user.language: es`); `./setup.sh --regenerate` para renderizar `scripts/hooks/upgrade-notice.sh`; vault fabricado en `$TMP_TEST_DIR/vault` y pasado por `VAULT_ROOT_OVERRIDE`; `C` = `<ws>/CLAUDE.md`, `U`/`B` en `<ws>/.state/launcher/`. Casos (UNH §1-2): (1) nada pendiente → stdout vacío, código 0; (2) delta 0.27.0 pendiente, workspace `in_sync` → `jq -e` válido, `hookEventName` = `SessionStart`, `additionalContext` igual a CANON-N1-es, N2-es (DOC = copia del vault) y N5-es unidas por `\n`; (3) dos deltas → dos N2 en orden ascendente; (4) delta borrado del vault → DOC = `<ws>/modules/vault-deltas/schema-updates-0.27.0.md`; (5) `pending_no_baseline` → N3-es con `{C}`, `{U}`, `{B}` absolutos; (6) `pending_template` → N4-es; (7) `customized` y `unknown` → vacío; (8) todo pendiente → orden cabecera, deltas, workspace, cierre, y menos de 2048 bytes; (9) `language: en` → CANON-*-en; `mixed` → es; (10) `enabled: false` + regenerate → vacío pese a pendientes; (11) fallas → código 0 y salida vacía: sin `<ws>/scripts/lib/claude_md.sh`, PATH sin `jq` (directorio de symlinks a las herramientas necesarias excepto `jq`), `CLAUDE.md` del vault con `chmod 000` (skip si root); (12) stdout de los casos con aviso: `LC_ALL=C grep -c '[^ -~]'` = 0; (13) stdin vacío y stdin de 200 KiB desde archivo → código 0; (14) 20 corridas medidas con `perl -MTime::HiRes`, máximo menor a 1 s; (15) FR-013: en los casos con aviso, el `CLAUDE.md` del vault, `C`, `U` y `B` quedan byte-idénticos a copias tomadas antes de correr el hook; (16) FR-012: con `features.heartbeat.review.enabled` en `false` y en `true` (más regenerate), la salida del caso (2) es idéntica.
- [X] T012 [US1] RED `tests/upgrade-notice-hook.bats`, sección "installer" (tras T011, mismo archivo), contra `scripts/hooks/install-upgrade-notice-hook.sh` renderizado (UNH §3): (a) `settings.json` ausente → creado con una entrada `SessionStart` `{type:"command",command:<arg>,timeout:10}`, sin clave `matcher`; (b) `settings.json` con `permissions`, `enabledPlugins`, `.hooks.Stop` y `.hooks.PreToolUse` → esas claves quedan iguales (comparación con `jq -S`) y se agrega la entrada; (c) tres corridas → exactamente una entrada con ese comando; (d) una entrada `SessionStart` previa con otro comando → se conserva y se agrega la nuestra; (e) sin argumentos → código 0, archivo intacto; (f) PATH sin `jq` → código 0, intacto; (g) JSON inválido → código 0, intacto.
- [X] T013 [P] [US1] RED `tests/heartbeat-isolation.bats`: nuevo test `038:` que agrega `.hooks.SessionStart` (además de `Stop` y `PreToolUse`) al `settings.json` fuente y asierta que la copia aislada no tiene ninguna de las tres claves (molde del test `031:` en `:172-182`).
- [X] T014 [P] [US1] RED `tests/start-services-upgrade-notice.bats` (nuevo; molde `tests/start-services-warm.bats`: `START_SERVICES_NO_RUN=1`, `HOME` temporal, `source docker/scripts/start_services.sh`, luego `WORKDIR=$TMP_TEST_DIR`): (a) `pre_install_upgrade_notice_hook` está definida; (b) sin instalador en `$WORKDIR/scripts/hooks/` → código 0, `$HOME/.claude/settings.json` no se crea; (c) con un instalador stub que registra sus argumentos → se llama con `$HOME/.claude/settings.json` y `$WORKDIR/scripts/hooks/upgrade-notice.sh`; (d) instalador que sale 1 → la función retorna 0; (e) en el cuerpo de `start_session` (extraído con `awk` desde `start_session() {` hasta la `}` de cierre) la llamada aparece después de `pre_install_askq_hook` y antes de `pre_warm_mcps`.
- [X] T015 [US1] GREEN `modules/upgrade-notice.sh.tpl` (nuevo) según UNH §1-2: valores horneados como variables de shell al inicio (`_enabled="{{FEATURES_UPGRADE_NOTICE_ENABLED}}"`, `_lang="{{USER_LANGUAGE}}"`, `_vault="${VAULT_ROOT_OVERRIDE:-{{VAULT_MCP_PATH}}}"`), sin `{{#if}}` (el motor no soporta anidarlos), `ws` derivado de la ubicación del script, textos CANON exactos armados con `printf '%s'` (el EN contiene un apóstrofo: nada de comillas simples alrededor), JSON con `jq -n --arg`. Cabecera "Rendered from … DO NOT hand-edit" como `modules/stop-hook-install.sh.tpl`. T011 en verde.
- [X] T016 [P] [US1] GREEN `modules/upgrade-notice-install.sh.tpl` (nuevo), molde `modules/stop-hook-install.sh.tpl` cambiando `.hooks.Stop` por `.hooks.SessionStart` y agregando `timeout: 10`. T012 en verde.
- [X] T017 [US1] GREEN render en `setup.sh::regenerate()`: después del bloque 031 (`setup.sh:2722-2731`), sin gate, renderizar ambas plantillas a `scripts/hooks/upgrade-notice.sh` y `scripts/hooks/install-upgrade-notice-hook.sh`, `chmod +x`, línea `  ✓ scripts/hooks/ (upgrade-notice.sh + install-upgrade-notice-hook.sh)`, comentario `# 038:` explicando por qué no hay gate (el interruptor va horneado; apagarlo nunca deja una referencia colgando en `settings.json`). Depende de T015 y T016.
- [X] T018 [P] [US1] GREEN `scripts/heartbeat/heartbeat.sh:151`: agregar `| del(.hooks.SessionStart)` al filtro `jq` y extender el comentario con `# 038:`. T013 en verde.
- [X] T019 [P] [US1] GREEN `docker/scripts/start_services.sh`: función `pre_install_upgrade_notice_hook` con la forma de `pre_install_askq_hook` (`:801-805`) pero usando `$WORKDIR` en vez del literal `/workspace` (testeable), y su llamada en `start_session` después de `pre_install_askq_hook`. No tocar `_run_watchdog` (oráculo sha en `tests/start-services-watchdog.bats`). T014 en verde.
- [X] T020 [US1] Renderizar ambos hooks a un directorio temporal y correr `shellcheck -S error` sobre ellos (CI no revisa `.tpl`); correr además el comando exacto de `.github/workflows/shellcheck.yml`. rc=0.
- [X] T021 [US1] Checkpoint: `bats tests/upgrade-notice-hook.bats tests/heartbeat-isolation.bats tests/start-services-upgrade-notice.bats tests/start-services-watchdog.bats tests/regenerate.bats tests/docker-render.bats` en bash 5.x y 3.2.57; 0 `not ok`. Auditoría de bytes.

**Checkpoint**: MVP docker completo y testeado en host. DOCKER_E2E en Polish.

---

## Phase 4: User Story 2 - El CLAUDE.md del workspace se actualiza solo cuando nadie lo editó (Priority: P2)

**Goal**: `--regenerate` escribe siempre `U`, re-renderiza `C` solo si coincide con `B`, y nunca pisa ediciones.

**Independent Test**: matriz de regenerate real sobre un workspace temporal (CMR, data-model §4).

- [X] T022 [US2] RED `tests/claude-md-refresh.bats`, sección "regenerate" (setup como `tests/regenerate.bats`, modo docker, con `agent.role_file` apuntando a `personas/regen-bot.md` que contiene `PERSONA_038_MARKER`; regenerate con `echo 'n' |` como en ese archivo). Casos: (R1) sin `C` → `C=U=B`, salida contiene `✓ CLAUDE.md`; (R2) segundo regenerate sin cambios → salida `CLAUDE.md (up to date)` y `C`, `U`, `B` byte-idénticos a copias previas; (R3) cambiar `features.heartbeat.enabled` → salida `refreshed: no local edits`, `C=U`, `B=U`, `C` contiene `PERSONA_038_MARKER` y ya no la sección `## Heartbeat`; (R4) editar `C` y cambiar `agent.yml` → salida `preserved: differs from the current template`, `C` byte-idéntico al editado, `U` actualizado, `B` sin cambio; (R5) luego `cp U B` y regenerate → `preserved: local edits, template unchanged`; (R6) borrar `B` con `C=U` → `up to date; baseline recorded` y `B=U`; (R7) borrar `B` con `C` editado → preserve y `claude_md_state` = `pending_no_baseline`; (R8) `printf 'y\n' | ./setup.sh --regenerate --force-claude-md` con `C` editado → `overwritten`, `C=U=B`; con `n` → `C` intacto; (R9) modo local con el `CLAUDE.md` del launcher (helper `_write_launcher_claude_md` de `tests/regenerate.bats`) → reemplazado y `B=U`; (R10) `C=U` con `B` basura → `adopt`, `B=U`; (R11) `.state/launcher` con `chmod 555` tras R1 (skip si root) → regenerate código 0 y `C` intacto.
- [X] T023 [US2] GREEN `setup.sh::regenerate()`: reemplazar el bloque `setup.sh:2680-2700` según CMR §"Integración": `mkdir -p .state/launcher`, un solo render a `U`, resolución de `force` (conservando el `ask_yn` destructivo) y `launcher_own`, `claude_md_regenerate_decision`, escrituras por copia de `U` con `|| true`, y las líneas de salida exactas de CMR (las tres actuales sin cambios). Agregar `source "$SCRIPT_DIR/scripts/lib/claude_md.sh"` en la cabecera de `setup.sh` (`:7-18`, junto a las demás librerías). T022 en verde.
- [X] T024 [US2] Correr `tests/regenerate.bats`, `tests/docker-render.bats`, `tests/local-render.bats` y los tests 037 de byte-identidad de `claude-md.tpl` (`docker-render.bats:353`, `local-render.bats:355`); confirmar que siguen en verde.
- [X] T025 [US2] Ajustar los tests listados por T003 que asumían `CLAUDE.md` preservado tras un cambio de entrada: cambiar el oráculo a la regla nueva (refresh si coincide con la línea base) y dejar en cada uno un comentario `# 038:` con el porqué. Ningún ajuste que debilite una aserción sin explicarlo.
- [X] T026 [US2] Checkpoint: suites completas `bats tests/` en bash 5.x y luego 3.2.57; 0 `not ok` salvo los preexistentes de T001, explicados.

**Checkpoint**: la capa workspace se mantiene sola cuando no hay ediciones.

---

## Phase 5: User Story 3 - El aviso se apaga solo y el operador lo ve en doctor (Priority: P3)

**Goal**: `agentctl doctor` muestra un WARN por capa pendiente, en ambos modos, hasta que se resuelva.

**Independent Test**: `_upgrade_notice_doctor` llamada directamente con `AGENTCTL_NO_RUN=1` contra estados
fabricados, más verificación del cableado en ambos doctores.

- [X] T027 [P] [US3] RED `tests/agentctl-doctor-upgrade-notice.bats` (nuevo): `AGENTCTL_NO_RUN=1 source scripts/agentctl`; workspace temporal con `scripts/lib/vault.sh` y `scripts/lib/claude_md.sh` copiados. Casos según UNH §6: vault vacío → línea skip; sin pendientes → PASS; `0.27.0` → WARN con `0.27.0`; dos → `0.8.0 0.27.0`; cada estado de workspace → su línea exacta; libs ausentes → una sola línea skip `workspace predates 038` y código 0; cada WARN incrementa `_doctor_warn_count`; dos llamadas seguidas producen la misma salida (no se auto-silencia); resolución: agregar el hito → PASS en la siguiente llamada, `cp U B` → `local edits on the current template`. `_upgrade_notice_vault_root <ws> <yml>`: `vault.enabled` distinto de `true` → vacío; `vault.path` relativo → `<ws>/<path>`; ausente → `<ws>/.state/.vault`. Cableado: los cuerpos de `cmd_doctor` y `cmd_local_doctor` (extraídos con `awk`) contienen `_upgrade_notice_doctor`.
- [X] T028 [US3] GREEN `scripts/agentctl`: `_upgrade_notice_vault_root` y `_upgrade_notice_doctor` según UNH §6 (cargar las libs desde `${ws}/scripts/lib/` como `_local_secrets_doctor` hace con `env_file.sh`); llamada en `cmd_doctor` después de la sección 11 usando `$WORKSPACE` (resuelto en `:672`) y `$yml`, y en `cmd_local_doctor` después de `_local_vault_qmd_doctor`. T027 en verde; `tests/agentctl*.bats` siguen en verde.
- [X] T029 [US3] Checkpoint: `bats tests/agentctl*.bats tests/agentctl-doctor-upgrade-notice.bats` en bash 5.x y 3.2.57; 0 `not ok`.

**Checkpoint**: el operador ve el estado de ambas capas en `agentctl doctor`, en ambos modos (en docker, con el contenedor corriendo: el doctor docker sale antes si está caído).

---

## Phase 6: User Story 4 - Mismo comportamiento en modo local (Priority: P4)

**Goal**: el hook queda registrado en los agentes locales nuevos (login) y existentes (regenerate), con el mismo
texto que en docker.

**Independent Test**: login y regenerate locales registran el hook; el texto local coincide con el docker salvo
rutas.

**Gate**: depende de T002. Si G0 mostró que Remote Control no ejecuta `SessionStart`, igual se implementa (es
inocuo y queda listo para cuando lo soporte), pero docs y CHANGELOG declaran que en local el aviso al agente no
llega y que doctor es la superficie.

- [X] T030 [P] [US4] RED `tests/local-login-install.bats`: con `scripts/hooks/install-upgrade-notice-hook.sh` presente, el login renderizado registra la entrada `SessionStart` en `${CONFIG_DIR}/settings.json`; sin el instalador, no la registra y el login sigue (molde de los pasos 4c/4d).
- [X] T031 [US4] RED `tests/upgrade-notice-hook.bats`, sección "local" (tras T012, mismo archivo; `install_claude_stub` y `deployment.claude_cli` como en `tests/regenerate.bats`): (a) regenerate local con `.state/.claude/` existente → `settings.json` con la entrada `SessionStart` al comando absoluto del workspace; (b) sin `.state/.claude/` → no se crea; (c) regenerate docker nunca escribe `.state/.claude/settings.json`; (d) paridad SC-006: mismo estado pendiente, hook docker (con `VAULT_ROOT_OVERRIDE`) y hook local → `additionalContext` igual tras reemplazar las rutas por marcadores; (e) SC-007: workspace local creado desde cero (sin `CLAUDE.md`, vault sembrado por el propio regenerate) → el hook no emite nada, `vault_pending_deltas` del vault queda vacío y `claude_md_state` da `in_sync`.
- [X] T032 [US4] GREEN `modules/local-login.sh.tpl`: paso `4e. 038:` después del 4d (`:80-88`), mismo molde, con mensaje `  ✓ upgrade notice hook registered in ${CONFIG_DIR}/settings.json`. T030 en verde.
- [X] T033 [US4] GREEN `setup.sh::regenerate()`, rama local (`setup.sh:2778-2826`): si `$SCRIPT_DIR/.state/.claude` es directorio, ejecutar el instalador renderizado contra `$SCRIPT_DIR/.state/.claude/settings.json` con `|| true`, y la línea `  ✓ upgrade notice hook registered (.state/.claude/settings.json)`. T031 en verde.
- [X] T034 [US4] Checkpoint: `bats tests/local-login-install.bats tests/upgrade-notice-hook.bats tests/local-render.bats` en bash 5.x y 3.2.57; 0 `not ok`.

---

## Phase 7: Polish & Cross-Cutting

- [X] T035 [P] Escribir `tests/docker-e2e-upgrade-notice.bats` (molde `tests/docker-e2e-askq-guard.bats`; fixture de vault pendiente pre-sembrado en `.state/.vault` antes de levantar, espera del symlink `/home/agent/vault`) con E1-E4 de quickstart §5.
- [X] T036 DOCKER_E2E de verdad en este host: rebuild de la imagen si hace falta y `DOCKER_E2E=1 bats tests/docker-e2e-upgrade-notice.bats tests/docker-e2e-askq-guard.bats tests/docker-e2e-vault.bats` (los dos últimos por regresión de `start_session` y del boot). Si algo falla solo bajo contenedor, arreglar con test RED primero. Resultado en Notes.
- [X] T037 [P] `docs/vault.md`, sección "Upgrading the skeleton": convención para autores de deltas (declarar el hito en el encabezado y agregar la fila en `vault_delta_checkpoint`; la guardia G1 falla si se olvida) y qué ve el agente al iniciar sesión.
- [X] T038 [P] `docs/architecture.md`, sección "Upgrade & Rollback", y `README.md`, sección "Upgrade an existing agent": render vigente y línea base en `.state/launcher/`, re-render automático, confirmación con `cp`, `--force-claude-md` una vez por agente existente y, si un overlay externo reinyecta configuración tras regenerate, correrlo después del `--force-claude-md` (sin nombrar repos externos: el launcher no depende de ellos).
- [X] T039 [P] `CLAUDE.md` del repo: subsección "Upgrade notice and CLAUDE.md refresh (038)" en "Architecture worth knowing" (hook, dos capas, archivos de `.state/launcher/`, aislamiento de heartbeat, convención de hitos) y actualizar la entrada 038 del bloque SPECKIT con el estado. Recordar `git add -f CLAUDE.md`.
- [X] T040 `CHANGELOG.md` (entrada `### Added` bajo `[Unreleased]`, sobre la de 037) y `VERSION` 0.27.0 → 0.28.0. Anotar en Notes que al rebasar sobre `main` con 037 mergeada hay que verificar `VERSION` a mano contra `origin/main`.
- [X] T041 Mutación M1-M12 de quickstart §6 contra la implementación real: aplicar cada una, correr el test predicho, confirmar RED, revertir, confirmar GREEN. Anotar en Notes qué test cazó cada una; si alguna sobrevive, endurecer el oráculo antes de seguir.
- [X] T042 Gate de privilegios de la constitución ("changes under `docker/` MUST be reviewed against Principle II before merge"): revisar el diff de `docker/` (`start_services.sh`: función nueva y su llamada) contra el Principio II: sin capabilities, mounts, sockets ni `-u root` nuevos; la función corre como `agent` dentro de `start_session` y solo escribe `$HOME/.claude/settings.json` vía el instalador. Anotar el veredicto con fecha en Notes antes de T046.
- [X] T043 Gates finales: `bats tests/` en bash 5.x y luego `PATH=/bin:$PATH bats tests/` en 3.2.57, conteos en Notes (línea base de T001 más los nuevos); comando exacto de shellcheck de CI rc=0; auditoría de bytes en 0 en `modules/upgrade-notice*.tpl`, tests nuevos y `specs/038-schema-delta-boot-nudge/`; `git diff --stat` revisado (nada fuera de los archivos del plan).
- [ ] T044 Gate de hardware G1 (quickstart §7), desde la rama 038 y antes de cualquier merge (decisión del operador, 02-10-2026; antes estaba diferido al merge de 037); lo ejecuta el operador con un runbook. Mantener a linus con ambas capas pendientes hasta entonces. Pasos 1-6 de G1 (incluye registrar `claude --version` del contenedor y verificar el aviso tras `/compact`); resultado con fecha en Notes. Precedente 024: el gate corre antes del merge de 038.
- [ ] T045 Gate G2 (local, si G0 pasó) y rollout a la flota según quickstart §7: forzar el re-render una vez por agente, con `custom-apply.sh --agent donna --no-regenerate` después solo en donna (la única con `overlay.yml`; linus y ferrari-admin solo tienen `syncthing.yml`); registrar en Notes.
- [ ] T046 Commit y PR solo con confirmación explícita del operador, staging archivo por archivo (nunca `git add -A`); 037 mergeó el 03-10-2026 (PR #100, squash `6a6ce54`) y la rama ya está rebasada sobre main: faltan subirla (`--force-with-lease`) y abrir el PR, que no se mergea antes de G1.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (T001-T003)**: sin dependencias. T002 corre en ferrari con el operador y puede ir en paralelo con todo
  hasta Phase 6.
- **Foundational (T004-T010)**: después de T001. Bloquea todas las historias.
- **US1 (T011-T021)**: después de Foundational.
- **US2 (T022-T026)**: después de Foundational; T025 necesita T003. Independiente de US1 en código, pero T017 y
  T023 tocan `setup.sh::regenerate()`: hacerlos secuenciales.
- **US3 (T027-T029)**: después de Foundational. Independiente de US1 y US2.
- **US4 (T030-T034)**: después de US1 (usa el hook y el instalador renderizados) y de T002.
- **Polish (T035-T046)**: después de las historias que se vayan a entregar. T044 y T045 además después del merge
  de 037.

### Dependencias dentro de las historias

- RED antes de GREEN, siempre: T004→T007, T005→T008, T006→T009, T011→T015, T012→T016, T013→T018, T014→T019,
  T022→T023, T027→T028, T030→T032, T031→T033.
- Mismo archivo, secuencial: `tests/upgrade-notice-hook.bats` (T011→T012→T031); `tests/claude-md-refresh.bats`
  (T005→T022); `setup.sh` (T009→T017→T023→T033).

### Parallel Opportunities

- Setup: T002 y T003 en paralelo con T001 terminado.
- Foundational: T004, T005 y T006 en paralelo (archivos distintos); luego T007, T008 y T009 en paralelo.
- US1: T011, T013 y T014 en paralelo; T016, T018 y T019 en paralelo.
- US3 completa en paralelo con US2 (archivos disjuntos).
- Polish: T035, T037, T038 y T039 en paralelo.

---

## Parallel Example: User Story 1

```bash
# RED en paralelo (archivos distintos):
T011 tests/upgrade-notice-hook.bats (sección hook)
T013 tests/heartbeat-isolation.bats
T014 tests/start-services-upgrade-notice.bats

# GREEN en paralelo, una vez escrito T015:
T016 modules/upgrade-notice-install.sh.tpl
T018 scripts/heartbeat/heartbeat.sh
T019 docker/scripts/start_services.sh
```

---

## Implementation Strategy

### MVP (US1)

1. Setup y Foundational.
2. US1: el aviso llega en docker. Con eso, donna y linus quedan cubiertos en la capa vault y, con `U`/`B`
   fabricados por el operador o por US2, en la capa workspace.
3. Validar con DOCKER_E2E (T035-T036) antes de seguir.

### Entrega incremental

1. US2: elimina el desfase del workspace en vez de solo avisarlo.
2. US3: el operador ve el estado en doctor.
3. US4: paridad local, según G0.
4. Polish, gates de hardware tras el merge de 037, rollout a la flota.

---

## Notes

Estado al 01-10-2026 (implementación terminada salvo T002, T044, T045 y la parte de PR de T046; commiteada
en local en un solo commit, staging archivo por archivo, sin push). Las mediciones de cada tarea van abajo;
las pendientes están marcadas como tales y no se declaran cerradas.

- **T001 línea base (01-10-2026).** HEAD `d88cbfb` (el código es idéntico al de `91da8c6`; solo difieren
  specs). Medida sobre una COPIA aislada del árbol (la lección de 037: una base medida mientras se edita en
  paralelo sale contaminada). **bash 5.3.15: 1644 tests, 1644 ok, 0 not ok, 52 saltados, rc 0, 18 min 13 s.
  bash 3.2.57 (`PATH=/bin:$PATH`): 1644 ok, 0 not ok, rc 0, 16 min 31 s.** El gate dual es real: se midió
  con una sonda que imprime `$BASH_VERSION` (5.3.15 por defecto, 3.2.57 con `PATH=/bin:$PATH`).
- **T002 gate G0 (Remote Control ejecuta `SessionStart`): PENDIENTE, requiere al operador (decisión del
  operador, 01-10-2026: lo ejecuta él con el runbook de `quickstart.md` sección 7).** Necesita `sudo`
  sobre ferrari-admin (reinicio de la unit) y abrir una sesión desde el cliente. NO se tocó ningún agente
  vivo. Sin esta medición, en modo local `agentctl doctor` es la única superficie garantizada; así lo
  declaran el CHANGELOG, el README, `docs/architecture.md` y `CLAUDE.md`. La implementación local (US4) se
  hizo igual: es inocua si el hook no dispara.
- **T003 auditoría de tests afectados por el re-render.** Ningún test existente asumía "CLAUDE.md
  preservado tras cambiar la entrada": `regenerate.bats:77` (edita y regenera) cae en `preserve`; los tres de
  027 (`:251`, `:262` y el reemplazo del doc del launcher) siguen igual; los de byte-identidad de 037 miden la
  plantilla, no la escritura. **T025 no requirió cambios** (193 de 193 verdes en los 14 archivos que ejercen
  regenerate/scaffold). Hallazgo colateral: `wizard-container.sh::refresh_claude_md` (el wizard in-container
  del primer arranque sin token de Telegram) agrega secciones a `CLAUDE.md` con `claude --print`; eso cuenta
  como edición propia y detiene el refresco automático en ESE agente, que solo recibe el aviso. Es coherente
  con el diseño (no hay forma de distinguirlo de una edición a mano) y no afecta a la flota actual, cuyos
  tokens vienen declarados.
- **T004-T010 (fase base).** `vault_pending_deltas` 22 tests; `claude_md.sh` 24; configuración 9. RED
  verificado antes de cada GREEN: tres tests pasaban en vacío en RED (la guardia G2/G4 con tabla vacía, el
  de solo lectura) y se endurecieron exigiendo que la función realmente corriera. Desviación de T006:
  `agent.yml` NO puede ser byte-idéntico entre dos regenerate (`meta.regenerated_at` cambia), así que se
  compara sin ese campo. Checkpoint T010: 149 de 149 en ambas versiones de bash.
- **T011-T021 (US1, docker).** Hook 25 tests + instalador 10 + composición 2 (luego +7 locales =
  44 en `upgrade-notice-hook.bats`); `start-services-upgrade-notice.bats` 8; aislamiento de heartbeat +1.
  Los textos CANON del hook se GENERAN desde el contrato (script), y un test verifica que cada literal del
  test aparece verbatim en el contrato. Salida real medida con ambas capas pendientes: 2183 bytes con una
  ruta de scratchpad de ~175 caracteres; con `/workspace` ronda 1,4 KB, y con una ruta local de ~70
  caracteres ronda 2 KB (el test de tamaño usa una ruta corta a propósito: acota el TEXTO, no el `TMPDIR`
  del host). Velocidad medida: el peor de 20 corridas fue muy inferior a 1 s. `shellcheck` limpio con el
  comando EXACTO de CI y, además, sobre los dos hooks renderizados y sobre `claude_md.sh` con TODAS las
  severidades (CI no revisa `.tpl`). Checkpoint T021: 162 de 162 en ambas versiones.
- **T022-T026 (US2).** 40 tests en `claude-md-refresh.bats` (24 de librería + 16 de regenerate real),
  incluido el ensayo del rollout (forzar una vez y luego cada upgrade se aplica solo) y la tolerancia a
  fallos (R11: dir y archivo de solo lectura, regenerate sale 0 y `CLAUDE.md` intacto). **La decisión de si
  se puede registrar el render se toma con `test`, NO ejecutando el render dentro de un `if`** (eso apagaría
  errexit para todo el render y dejaría pasar uno a medias). T026: suite completa sobre una instantánea
  tras US1+US2: **bash 5.x 1761 de 1761, 0 not ok, 52 saltados, 18 min 55 s; bash 3.2.57 1761 de 1761, 0 not
  ok, 53 saltados, 20 min 24 s.** (El saltado extra de 3.2 es un test previo de `qmd_watch` que exige bash 4+;
  la línea base de 3.2 también tenía 53.)
- **T027-T029 (US3).** 23 tests de doctor (unidad + tres de punta a punta con stubs de docker/systemctl/
  claude, en ambos doctores). **Divergencia real entre versiones cazada por el gate dual:** bajo `errexit`,
  bash 3.2.57 termina el shell entero ante un `.` sobre un archivo inexistente aunque lleve `|| true`
  (5.x no); en producción `agentctl` no usa `set -e` y funcionaba, pero se cambió a la forma
  `if [ -f ]` por robustez. Checkpoint T029: familia `agentctl*` 144 de 144 en ambas versiones.
- **T030-T034 (US4).** Login +5, sección local del hook +7 (registro en regenerate, paridad docker/local
  SC-006, workspace nuevo con vault sembrado por el propio regenerate SC-007 y ruta de vault local horneada
  probada SIN override). Checkpoint T034: 95 de 95 en ambas versiones.
- **T035-T036 DOCKER_E2E, corrido de verdad (01-10-2026, Docker 29.8.0, arm64, caché caliente).**
  `docker-e2e-upgrade-notice.bats` **4/4** (E1 registro en el boot + el hook ejecutado como `agent` sobre
  busybox/jq de la imagen, con el delta depositado por el propio upgrade aditivo del boot; E2 el boot lo
  re-registra tras borrarlo y no lo duplica en un segundo reinicio; E3 cero bytes con el delta integrado; E4
  el `settings.json` aislado del heartbeat, construido en el contenedor, no lo trae). Se vio rojo con una
  mutación a nivel de contenedor: sacar la llamada de `start_session` tumba E1. Regresión: `docker-e2e-vault`
  **3/3**. **`docker-e2e-askq-guard` 1/3: los dos rojos (E1 y E3 de 031) son PREEXISTENTES**: se corrió el mismo
  archivo sobre la copia de la línea base, sin ningún archivo de 038, y fallan igual y por las mismas causas
  (E1 llama al instalador con `--entrypoint sh` antes de que exista `~/.claude`; E3 busca un plugin de Telegram
  que la imagen no trae). Son deuda de 031 (su e2e se difirió y nunca corrió); NO se tocaron aquí, candidato a
  un arreglo aparte.
- **Autorrevisión: un hueco spec-implementación, arreglado.** El spec (casos borde) exige que con el vault
  deshabilitado solo aplique la capa del workspace, y el hook no leía `agent.yml`: habría pedido integrar un
  delta en un vault que el agente ya no usa (el doctor sí lo saltaba). Se hornea `_vault_enabled` con
  `{{#if VAULT_ENABLED}}`, porque una variable sin definir no equivale a `false` y un `agent.yml` sin bloque
  `vault:` es común. Tres tests nuevos (deshabilitado, control habilitado, sin bloque) y la mutación M19.
- **T041 mutación: 20/20 cazadas** (`mutate.py` sobre instantáneas, nunca sobre el árbol de trabajo, con
  restauración verificada byte a byte). M1-M12 de la tabla del quickstart + M13-M20 propias: rechazo de
  `--force` seguido de refresh automático (M13), guardia de render no escribible (M14), instalador sin
  `|| true` (M15), regenerate local que crea `.state/.claude` (M16), idioma siempre en español (M17), paso 4e
  del login (M18), interruptor del vault (M19), llamada del boot (M20). Ninguna sobrevivió, así que no hubo
  que endurecer oráculos después; sí se endurecieron ANTES (ver T004-T010 y los tests que pasaban en vacío en
  RED: la guardia con tabla vacía, la función ausente dentro de `$(...)`, el timer sobre un hook inexistente).
- **T037-T040 (docs, CHANGELOG, VERSION).** Hecho. `VERSION` 0.27.0 → **0.28.0**; verificado contra
  `origin/main` tras `git fetch`: **0.26.0** (037 sigue sin mergear). AL REBASAR sobre `main` con 037
  mergeada hay que volver a verificar `VERSION` a mano (la lección de 023: git no avisa un conflicto
  semántico de VERSION). Ningún test fija el valor de `VERSION`.
- **T043 gates finales (01-10-2026), sobre una instantánea del árbol ya sin cambios de código pendientes.**
  **bash 5.3.15: 1803 de 1803, 0 not ok, 56 saltados (los 52 de siempre + los 4 e2e), rc 0, 17 min 41 s.
  bash 3.2.57: 1803 de 1803, 0 not ok, rc 0, 17 min 55 s.** 1803 = 1644 de la línea base + 159 nuevos (7
  archivos nuevos y 3 extendidos). `upgrade-notice-config.bats` (modificado después de congelar la instantánea
  para fijar SC-007 por el camino real del wizard) se re-corrió aparte: 9 de 9 en ambas versiones. `shellcheck`
  con el comando EXACTO de CI rc=0 y los hooks renderizados desde el árbol final con todas las severidades
  rc=0. Auditoría de bytes sobre todos los archivos tocados: cero marcas combinantes y UTF-8 válido; el único
  selector de variación es una entrada histórica preexistente del CHANGELOG.
- **T042 revisión de privilegios (Principio II): PASA, 01-10-2026.** El diff bajo `docker/` es
  exclusivamente `docker/scripts/start_services.sh`, +13 líneas (una función y su llamada). No se tocó
  `docker-compose.yml.tpl`, `Dockerfile`, `entrypoint.sh`, `crontab.tpl` ni `heartbeatctl`; los literales de
  capacidades del compose (`cap_drop`, `cap_add`, `no-new-privileges`) siguen en 3 antes y después. La función
  corre como `agent` (el entrypoint hace `exec su-exec agent .../start_services.sh`), solo escribe
  `$HOME/.claude/settings.json` mediante el instalador del workspace y usa mounts que ya existían: sin
  capacidades, mounts, sockets, puertos ni `-u root` nuevos.
- **Dos bloqueos del hook `protect-secrets` durante la implementación**, ambos por menciones incidentales en
  el TEXTO de un comando (un fixture vacío en un directorio temporal y un comentario sobre el archivo de
  login), no por acceso a un secreto. En los dos casos se quitó la mención innecesaria (el fixture no hacía
  falta; el comentario se reformuló) en vez de rodear el guard. Además, un comando con un heredoc largo que
  incluía literales de `--force-claude-md` fue denegado por la capa de permisos; se reescribió con la
  herramienta de edición y los tests se corrieron en un comando aparte.
- **Decisiones y corrección del 02-10-2026.** El operador decidió, por AskUserQuestion: subir 037 y abrir su PR
  (#100, abierto ese día) y correr G1 en linus antes de cualquier merge, desde la rama 038, ejecutándolo él con un
  runbook. **Corrección de un error propio:** el quickstart, T045 y el `CLAUDE.md` decían que donna, linus y
  ferrari-admin tienen overlay de MCPs; era una deducción por nombres de carpeta, sin abrirlas. Verificado en todas
  las ramas del repo de custom-config: solo `donna` tiene `overlay.yml`; `linus` y `ferrari-admin` solo tienen
  `syncthing.yml` (lo consume `bin/syncthing-apply.sh`). Coherente con el despliegue de 037, donde a linus le bastó
  un `--regenerate` limpio y a donna `custom-apply.sh`.
- **Rebase sobre main (03-10-2026).** El operador mergeó el PR #100 de 037 como squash (`6a6ce54`, padre
  `70214d9`; 03-10-2026 01:53 hora de Santiago). El árbol de `origin/main` coincide con el de `91da8c6`
  (`80ec0a35…`), así que `git rebase --onto origin/main 91da8c6` aplicó sin conflictos: `git range-diff` marcó los
  dos parches como idénticos y el árbol resultante fue igual al de `ee652cc` (`9ba89d2b…`) antes de actualizar
  estos documentos. `VERSION` verificada a mano: `origin/main` 0.27.0, rama 0.28.0. El bundle del runbook pasó de
  `219b45a..` a `70214d9..` porque `219b45a` ya no es base de la rama. Quedan: subir la rama rebasada
  (`--force-with-lease`) y abrir el PR, ambos con confirmación del operador; G0 y G1.
