# Feature Specification: Vault + RAG operativos en modo local (Linux/systemd)

**Feature Branch**: `012-local-vault-rag`

**Created**: 2026-07-04

**Status**: Draft

**Input**: User description: "Vault + RAG operativos en modo local (Linux/systemd): cerrar la brecha FR-004 de la feature 011 y portar el pipeline QMD/RAG y el backup del vault al modo local standalone, para que un agente local tenga paridad funcional de vault/RAG con el modo Docker. El modo docker queda byte-idéntico."

## Contexto

La feature 011 (mergeada, PR #66, v0.5.0) creó el modo local standalone: la base del agente se rendera en el host y una sesión Remote Control persiste vía systemd. El fix de MCP runtimes (commit `5ffca3e`) hizo ejecutables los MCP fetch/git/filesystem/atlassian/github. Pero el subsistema vault/RAG quedó en cero en modo local — auditoría del 2026-07-04 con evidencia file:línea:

1. **Brecha spec-vs-código (la más seria)**: el FR-004 de `specs/011-local-standalone-mode/spec.md:100` prometía "vault sembrado, configuración RAG/qmd" en el render local, pero `setup.sh` nunca invoca la siembra — esta vive solo en el boot del contenedor (`docker/scripts/start_services.sh:66-116`, paths `/opt/agent-admin` y `/home/agent`). En local con `vault.enabled` + `seed_skeleton` el vault jamás se siembra. La lib `scripts/lib/vault.sh` ya es host-compatible y está testeada (`tests/vault.bats`, 21 tests).
2. **MCP vault apunta a la nada**: `modules/mcp-json.tpl:70` conserva el path de contenedor `/home/agent/.vault` hardcodeado, sin el remap por modo que el commit `5ffca3e` aplicó a git/filesystem.
3. **QMD sin corpus**: el runtime bun/bunx sí se instala en local y el bloque MCP qmd rendera bien, pero nadie ejecuta el contrato `collection add → update → embed` → MCP vivo con índice vacío. El storage implícito `~/.cache/qmd` cae fuera del workspace (en docker persiste solo por el bind `.state → /home/agent`).
4. **Sin freshness**: no existe equivalente local del cron `*/5` (generado por `heartbeatctl:252-257`) ni del watcher inotify (`docker/scripts/qmd_watch.sh`, respawneado por el watchdog). Deferral formal en `specs/011/plan.md:11` — esta feature ES ese follow-up.
5. **Backup del vault asimétrico**: `--restore-from-fork` restaura la rama `backup/vault` en cualquier modo (`setup.sh:1623-1647`), pero en local nada respalda. `vault_resolve_root` (`docker/scripts/lib/backup_vault.sh:23-38`) rebasea bajo `/home/agent` asumiendo el bind.

**Apalancamiento verificado**: la lógica es mayormente portable ya — `qmd_index.sh` y `qmd_watch.sh` tienen env-overrides completos (`QMD_CACHE_HOME`, `QMD_VAULT_DIR`, `QMD_INDEX_STATE_FILE`, `QMD_REINDEX_CMD`, …) y el flock+hash-debounce es agnóstico. inotify es Linux nativo. El trabajo es cablear (reubicar libs, inyectar env, escribir units systemd), no reescribir.

**Restricción estructural**: el workspace local NO lleva el árbol `docker/` (`setup.sh:1721`) ni `heartbeatctl` (image-baked). `qmd_index.sh`, `qmd_watch.sh` y `backup_vault.sh` viven hoy solo bajo `docker/scripts/`. Se requiere reubicación de fuente canónica a `scripts/lib/` con espejo a `docker/` en scaffold/regenerate — patrón ya establecido para `scripts/lib/vault.sh` y `plugin-catalog.sh` (`setup.sh:1501-1535`). El Dockerfile mantiene sus `COPY` sobre las copias espejadas (cada lib necesita su línea `COPY` explícita).

## Clarifications

### Session 2026-07-04

- Q: ¿Dónde se engancha el setup first-run de QMD (add→update→embed) en el flujo local? → A: Doble enganche auto-sanador — `--login` lo dispara en background Y el entrypoint del timer de reindex ejecuta setup-if-needed (sentinel = no-op) antes de reindexar; si el login falló o se saltó, el primer tick del timer construye el índice (paridad con el boot de docker).
- Q: ¿Cómo maneja el modo local los schedules cron de `agent.yml` al renderizar timers systemd? → A: Conversión de formas comunes con fallback — `*/N * * * *` (cada N min), `M * * * *` (horario al minuto M) y `M H * * *` (diario a H:M) se convierten; cualquier otra expresión cae al default del feature (5 min qmd / 1 h backup) con warning visible en el render. `agent.yml` sigue siendo la única fuente, en sintaxis cron.
- Q: ¿`agentctl status`/`doctor` deben reportar las units nuevas en modo local? → A: Sí, en 012 — `status` muestra el estado de las units vault/qmd cuando aplican (activas/staged/ausentes) y `doctor` agrega chequeos básicos (índice presente, último reindex/backup desde los state files).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Vault base en modo local (Priority: P1)

Como operador de un agente en modo local con `vault.enabled=true`, quiero que el scaffold/regenerate siembre el skeleton del vault en el host y que el MCP vault apunte al path real del workspace, para que el agente nazca con su wiki operativa — igual que en Docker. Cierra la brecha FR-004 de 011.

**Why this priority**: Es un incumplimiento de la spec 011 ya mergeada, no deuda nueva. Sin esto, todo lo demás (QMD, backup) no tiene sobre qué operar.

**Independent Test**: En un workspace de prueba con `deployment.mode=local` y `vault.enabled=true`, correr scaffold (o `--regenerate`) y verificar que el skeleton existe bajo el path del vault resuelto en el workspace y que `.mcp.json` referencia ese path (no `/home/agent/.vault`). No requiere systemd ni login.

**Acceptance Scenarios**:

1. **Given** un workspace local con `vault.enabled=true`, `vault.seed_skeleton=true` y destino de vault vacío, **When** corre el scaffold o `--regenerate`, **Then** el skeleton (estructura Karpathy LLM Wiki completa) queda sembrado bajo `<workspace>/<vault.path>` (default `.state/.vault`), sin rebase `/home/agent`.
2. **Given** un vault ya poblado, **When** corre `--regenerate`, **Then** la siembra es no-op (idempotente; no pisa contenido).
3. **Given** `vault.force_reseed=true`, **When** corre la siembra local, **Then** aplica el mismo contrato backup-and-reseed de la lib (respaldo con timestamp, re-siembra, flag auto-reseteado en `agent.yml`).
4. **Given** modo local con `vault.mcp.enabled=true`, **When** se rendera `.mcp.json`, **Then** el arg del MCP vault es el path del vault bajo el workspace; **Given** modo docker, **Then** sigue siendo `/home/agent/.vault` byte-idéntico.
5. **Given** `vault.enabled=false`, **When** corre el scaffold local, **Then** cero artefactos de vault (no-op total).

---

### User Story 2 - Pipeline QMD/RAG local (Priority: P1)

Como operador de un agente local con `vault.qmd.enabled=true`, quiero que el índice semántico se construya solo (first-run) y se mantenga fresco (timer programado + watcher de cambios), para que el MCP qmd responda con corpus real — paridad con el diseño dual-trigger de la feature 010.

**Why this priority**: Sin corpus, el MCP qmd conecta pero es inútil; el RAG es la razón de ser del vault para el agente.

**Independent Test**: Con stubs host-side (bunx/systemctl/inotifywait), verificar que (a) el setup first-run ejecuta add→update→embed con el storage bajo el workspace, (b) el timer/entrypoint de reindex honra el schedule y mantiene flock+hash-debounce, (c) la unit del watcher rendera correcta y degrada limpio sin inotify-tools. La integración real se valida en el gate manual Linux.

**Acceptance Scenarios**:

1. **Given** un workspace local con qmd habilitado y sin índice previo, **When** corre el flujo de setup local (post-instalación de runtimes), **Then** se registra la colección y se construye el índice con storage bajo `<workspace>/.state/.cache/qmd` (durabilidad: viaja con el workspace), estado en `<workspace>/scripts/heartbeat/qmd-index.json`, sin bloquear el login.
2. **Given** un setup ya completado (sentinel presente), **When** se repite el flujo (nuevo `--login` o tick del timer), **Then** no-op idempotente; **Given** un setup fallido, **Then** sin sentinel y el próximo tick del timer lo reintenta (auto-sanación sin intervención manual).
3. **Given** las units instaladas, **When** vence el intervalo del timer (honra `vault.qmd.schedule`, default cada 5 min), **Then** corre el reindex con exclusión mutua (flock) y hash-debounce (skip si el vault no cambió).
4. **Given** el watcher activo, **When** se edita un `.md` del vault, **Then** un único reindex se dispara tras el debounce (~15 s), coalesciendo ráfagas; **Given** el proceso del watcher muere, **Then** systemd lo revive (`Restart=always`).
5. **Given** un host sin inotify-tools, **When** systemd intenta arrancar el watcher, **Then** la unit queda inactive por condición no cumplida — sin restart-loop ni estado failed — y el timer queda como backstop (misma degradación funcional que 010).
6. **Given** `vault.qmd.enabled=false`, **Then** cero units, cero timer, cero setup (no-op total).
7. **Given** el scaffold local sin sudo passwordless, **When** se instalan las units qmd, **Then** quedan staged y `--login` las instala + habilita (mismo patrón validado en 011); el kill-switch y `--uninstall` las detienen/remueven.

---

### User Story 3 - Backup del vault en modo local (Priority: P2)

Como operador de un agente local con vault y fork configurados, quiero que el snapshot markdown del vault se respalde periódicamente a la rama `backup/vault` del fork, para cerrar la asimetría actual (restore funciona, backup no) y que una pérdida del host no pierda el conocimiento del agente.

**Why this priority**: P2 porque el vault local puede respaldarse manualmente vía Remote Control mientras tanto, y restore ya funciona; pero la paridad de durabilidad con docker exige el ciclo completo.

**Independent Test**: Con un fork simulado (repositorio git local como remote), verificar que el entrypoint de backup produce el commit en la rama huérfana con las mismas exclusiones e idempotencia por hash que docker, resolviendo el vault bajo el workspace sin rebase `/home/agent`.

**Acceptance Scenarios**:

1. **Given** vault local poblado + fork configurado, **When** vence el timer (honra `vault.backup_schedule`, default horario), **Then** el snapshot markdown llega a `backup/vault` con las exclusiones estándar (`.obsidian/workspace*.json`, cache, trash, sync-conflicts) y las mutaciones (deletes incluidos) se propagan.
2. **Given** un vault sin cambios desde el último backup, **When** corre el timer, **Then** no-op por hash (sin commit vacío, sin push).
3. **Given** un workspace sin fork configurado, **When** corre el backup, **Then** no-op limpio (exit 0, sin error ruidoso) — igual que docker.
4. **Given** modo docker, **Then** el contrato existente no cambia: `vault_resolve_root` sigue rebaseando bajo `/home/agent` (los tests `backup-vault-lib.bats` lo fijan) y el cron del contenedor sigue operando idéntico.

---

### Edge Cases

- `vault.path` custom (no default): la resolución local debe usar `<workspace>/<vault.path>` literal — sin el rebase `/home/agent/${path#.state/}` del modo docker.
- Workspace local creado antes de 012 (`--regenerate` sobre un agente 011 existente): las piezas nuevas aparecen (siembra si aplica, units staged), nada existente se rompe; sin vault habilitado, cero cambios visibles.
- `bunx`/`bun` ausente en el host al correr setup qmd (bootstrap falló o se saltó): el setup degrada con warning, sin sentinel; el próximo tick del timer de reindex lo reintenta (guard setup-if-needed) — nunca rompe el login.
- Expresión cron no soportada en `vault.qmd.schedule`/`vault.backup_schedule` (p. ej. listas o días de semana): el render cae al default del feature con warning visible — nunca genera un timer inválido ni aborta el regenerate.
- Índice qmd corrupto o cache borrado a mano: el reindex/setup lo reconstruye (índice regenerable por diseño; Constitution V de 010 — no se respalda).
- Dos disparadores simultáneos (timer + watcher): el flock garantiza un solo reindex; el perdedor sale 0 silencioso.
- `--uninstall` local: detiene y remueve también las units qmd/backup (staged o instaladas); `--purge`/`--nuke` conservan su semántica actual sobre `.state`.
- Reubicación de libs: los tests existentes (`qmd-*.bats`, `backup-vault-*.bats`, `vault.bats`) siguen verdes; si `load_lib` apunta al path viejo, se ajusta el path — no el contrato.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Con `deployment.mode=local` y `vault.enabled=true`, el scaffold y `--regenerate` MUST sembrar el skeleton host-side vía la lib de vault existente cuando `vault.seed_skeleton=true` y el destino esté vacío — idempotente, respetando `vault.force_reseed` con el contrato backup-and-reseed, y resolviendo `vault.path` relativo al workspace (default `<ws>/.state/.vault`, sin rebase `/home/agent`).
- **FR-002**: `.mcp.json` MUST remapear el arg del MCP vault por modo de deployment con el patrón condicional existente: docker → `/home/agent/.vault` (byte-idéntico), local → path del vault bajo el workspace derivado de `vault.path`.
- **FR-003**: Las libs `qmd_index.sh`, `qmd_watch.sh` y `backup_vault.sh` MUST reubicarse con fuente canónica en `scripts/lib/` (o `scripts/`) del launcher, espejadas a `docker/` en scaffold/regenerate según el patrón de `vault.sh`/`plugin-catalog.sh`, con las líneas `COPY` del Dockerfile apuntando a las copias espejadas. El comportamiento del modo docker MUST quedar intacto (DOCKER_E2E lo prueba).
- **FR-004**: Con `vault.qmd.enabled=true` en modo local, el setup first-run de qmd — contrato add→update→embed, sentinel de idempotencia, reintento en fallo — MUST engancharse en DOS puntos auto-sanadores: (a) `--login` lo dispara en background tras provisionar runtimes (sin bloquear el login), y (b) el entrypoint del timer de reindex ejecuta setup-if-needed antes de reindexar (sentinel = no-op; si el login falló o se saltó, el primer tick lo construye). Storage bajo `<ws>/.state/.cache/qmd`, vault dir resuelto localmente, estado en `<ws>/scripts/heartbeat/qmd-index.json`.
- **FR-005**: El modo local MUST proveer reindex programado vía systemd timer + service oneshot que honre `vault.qmd.schedule` según la política de conversión de FR-012 (default equivalente a cada 5 minutos), ejecutando un entrypoint renderizado en `scripts/local/` (no `heartbeatctl`) que preserve flock + hash-debounce.
- **FR-006**: El modo local MUST proveer el watcher de cambios como unit systemd propia (`Restart=always`) que ejecute la lib del watcher con el comando de reindex apuntando al entrypoint local; MUST degradar limpio sin inotify-tools (el timer queda de backstop) y coalescer ráfagas con el debounce existente.
- **FR-007**: Con `vault.enabled=true` + fork configurado en modo local, un systemd timer + service oneshot MUST ejecutar el backup del vault honrando `vault.backup_schedule` según la política de conversión de FR-012 (default horario), con la misma semántica que docker: exclusiones estándar, idempotencia por hash, propagación de deletes, no-op limpio sin fork; estado en `<ws>/scripts/heartbeat/vault-backup.json`.
- **FR-008**: La resolución del vault root MUST parametrizarse por modo: docker conserva el rebase `/home/agent` (contrato fijado por tests existentes); local resuelve `<ws>/<vault.path>` directo.
- **FR-009**: Todas las units/timers nuevos MUST seguir el ciclo de vida local establecido en 011: instalación directa con sudo disponible, staged en el workspace sin sudo, instalación+habilitación por `--login`, y remoción/parada por kill-switch y `--uninstall`.
- **FR-010**: Con `vault.enabled=false` (o `vault.qmd.enabled=false` para las piezas qmd), el modo local MUST no generar ninguno de estos artefactos (cero costo cruzado), y el modo docker MUST quedar byte-idéntico en todos los casos.
- **FR-011**: Todo artefacto nuevo MUST renderarse desde `agent.yml` vía plantillas en `modules/*.tpl` y sobrevivir `./setup.sh --regenerate`.
- **FR-012**: Los schedules cron de `agent.yml` (`vault.qmd.schedule`, `vault.backup_schedule`) MUST convertirse a systemd por política de formas comunes con fallback: `*/N * * * *` → cada N minutos, `M * * * *` → horario al minuto M, `M H * * *` → diario a las H:M; cualquier otra expresión MUST caer al default del feature (5 min qmd / 1 h backup) emitiendo un warning visible en el render. `agent.yml` permanece como única fuente, en sintaxis cron (sin claves paralelas por modo).
- **FR-013**: En modo local, `agentctl status` MUST reportar el estado de las units vault/qmd cuando los features estén habilitados (activas / staged / ausentes), y `agentctl doctor` MUST agregar chequeos básicos del subsistema: índice qmd presente y timestamp del último reindex/backup leídos de los state files. Con vault/qmd deshabilitados, ni `status` ni `doctor` mencionan el subsistema.

### Key Entities

- **Vault local**: directorio `<ws>/<vault.path>` (default `.state/.vault`) con el skeleton Karpathy; mismo contenido que en docker, distinto path de resolución.
- **Índice QMD local**: `<ws>/.state/.cache/qmd/` (index.sqlite + modelos, ~300 MB); regenerable, nunca respaldado; viaja con el workspace.
- **Units systemd qmd**: timer+service de reindex (`agent-<name>-qmd-reindex.*`) y service del watcher (`agent-<name>-qmd-watch.service`); renderadas desde `agent.yml`.
- **Units systemd backup**: timer+service (`agent-<name>-vault-backup.*`); dependen de fork configurado.
- **Archivos de estado**: `qmd-index.json` y `vault-backup.json` bajo `<ws>/scripts/heartbeat/` (mismo esquema que docker).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Un agente local recién scaffoldeado con vault habilitado tiene el skeleton sembrado y el MCP vault conectado apuntando al workspace — verificable con la lista de MCPs del agente — sin ninguna intervención manual posterior al flujo estándar (scaffold + login).
- **SC-002**: Con qmd habilitado, el índice existe y responde búsquedas dentro de los 15 minutos posteriores al primer login (setup first-run + primer ciclo del timer), y una edición de un `.md` del vault se refleja en el índice en menos de 2 minutos con el watcher activo.
- **SC-003**: El modo docker permanece byte-idéntico: la suite host completa y los e2e Docker de vault/qmd pasan sin cambios de contrato.
- **SC-004**: Un vault local con fork configurado aparece respaldado en la rama `backup/vault` dentro del primer intervalo de backup, y `--restore-from-fork` sobre un host nuevo reconstruye el vault — ciclo backup/restore simétrico.
- **SC-005**: Deshabilitar vault (o qmd) produce cero artefactos nuevos en el workspace local — verificable por diff de scaffold.

## Assumptions

- Las decisiones heredadas de 010/011 NO se reabren: pin qmd single-source (`vault.qmd.version`, default 2.5.3), identidad local = usuario del operador, units de sistema (no `systemd --user`), 1 agente por host, índice regenerable no respaldado, modelo de tres ramas huérfanas intacto, nunca `--dangerously-skip-permissions`.
- El backup local usa las credenciales git del entorno del operador (helper HTTPS o llave SSH ya configurada en el host); el launcher no gestiona esa credencial — se documenta el supuesto.
- inotify-tools puede no estar preinstalado en el host; su ausencia degrada al backstop del timer (no se auto-instala con root — el bootstrap solo instala a nivel usuario).
- El gate manual de integración corre en mclaren (Raspberry Pi 5, Debian trixie, arm64) cuando el host vuelva a estar alcanzable; mientras tanto la evidencia es host-side (bats con stubs) + DOCKER_E2E.
- Polish opcional si el plan lo estima barato: validación de `vault.enabled/path/mcp.enabled/backup_schedule` en el schema, remap del path de google-calendar en `.mcp.json`, párrafo de modo local en `docs/architecture.md`.

## Out of Scope

- Heartbeat scheduling y plugin auto-install en modo local (siguen diferidos; esta feature cubre solo vault/qmd/backup-vault del deferral de 011).
- macOS/launchd.
- Rediseñar RAG/qmd, el esquema del skeleton o el modelo de backup de tres ramas.
- Multi-agente por host.
- Cambios de comportamiento del modo docker (solo cambia el origen espejado de las libs, probado por DOCKER_E2E).
