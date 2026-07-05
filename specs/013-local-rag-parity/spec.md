# Feature Specification: RAG local agnóstico al modo de instalación

**Feature Branch**: `013-local-rag-parity`

**Created**: 2026-07-05

**Status**: Draft

**Input**: User description: "RAG local agnóstico al modo de instalación: cerrar los 30 gaps confirmados por la auditoría de paridad RAG docker↔local (2026-07-05, workflow wf_37295b56: 49 aspectos, 27 gaps confirmados adversarialmente + 0 refutados + 3 confirmados por inspección directa). La memoria RAG del agente debe ser igual de buena en modo local (systemd) que en docker: mismo índice consultado que escrito, mismo refresco, misma durabilidad, misma operabilidad. Docker byte-idéntico."

## Contexto y evidencia

La feature 012 (PR #67, VERSION 0.6.0) portó vault+QMD al modo local, pero su gate manual en hardware real (T036) nunca corrió. Una auditoría de paridad multi-agente (2026-07-05) lo pre-ejecutó estáticamente y contra el paquete npm real, encontrando la cadena RAG local rota en **tres causas raíz**. Efecto neto en un host local real: el índice se construye (a veces) el día del `--login` y después **nunca se refresca** — RAG que funciona el día 1 y envejece en silencio con `systemctl` mostrando todo sano.

- **RC1 — Contrato de env de storage equivocado** (invalida el supuesto D5 de `specs/012-local-vault-rag/research.md:29-33`): `QMD_CACHE_HOME` **no** es una variable que el binario qmd lea. Verificado contra el tarball npm `@tobilu/qmd@2.5.3`: el índice se resuelve `INDEX_PATH` > `$XDG_CACHE_HOME/qmd/` > `~/.cache/qmd/` (`dist/store.js:420-435`); modelos ídem (`dist/llm.js:119-121`); `grep QMD_CACHE_HOME` sobre el paquete = 0 hits. `QMD_CACHE_HOME` solo lo lee la lib bash (`scripts/lib/qmd_index.sh:51`) para bookkeeping. Consecuencias: índice+modelos (~300MB) caen en `~operador/.cache/qmd`; la migración del workspace no lleva el índice; el chequeo de idempotencia mira el dir equivocado (reintento de `collection add` a perpetuidad con journal engañoso); `agentctl status/doctor` reportan "not built yet" indefinidamente; `--purge/--nuke` dejan huérfanos. En docker converge por accidente (`HOME=/home/agent` es el bind de `.state`), por eso DOCKER_E2E nunca lo vio. **Hoy el MCP local también lee `~/.cache/qmd`**: lector y escritor convergen por accidente y las búsquedas funcionan — corregir solo el escritor rompería al lector (qmd auto-crea un sqlite **vacío** en silencio, `store.js:428-435`).
- **RC2 — PATH bajo systemd**: las 3 units de 012 (`modules/local-qmd-reindex.service.tpl:4-8`, `local-qmd-watch.service.tpl:5-19`, `local-vault-backup.service.tpl:4-8`) no fijan PATH; el default de systemd excluye `~/.local/bin` (bunx) y `<ws>/scripts/vendor/bin` (yq v4). Cada tick: `command -v bunx` falla (guards en `qmd_index.sh:137` y `:215`; invocación en `:88`) → exit 0 "exitoso" → el índice jamás se refresca. `yq` inalcanzable rompe además `_qmd_enabled`, `qmd_pkg`, la lectura de `agent.yml` del watcher y el `fork_url` del backup (backup nunca pushea pese a fork configurado). Misma clase de bug que 011 corrigió para la unit de sesión (`remote-control.env.tpl:13`) — no se replicó a los contextos batch.
- **RC3 — Watcher sin env del vault**: `modules/local-qmd-watch.sh.tpl:15-16` no exporta `QMD_VAULT_DIR`/`VAULT_ROOT_OVERRIDE` → `vault_resolve_root` rebasea al default de contenedor `/home/agent/.vault` (inexistente en el host) → el watcher sale al arrancar y con `Restart=always` + el start-limit de la unit (`StartLimitIntervalSec=300`/`StartLimitBurst=5`) queda **failed permanente en <35s**. Reindex-on-change local = inexistente.

Confirmados además por inspección directa: el kill-switch local no detiene `vault-backup.timer` ni `healthcheck.timer` (`modules/local-killswitch.sh.tpl:14` — con kill switch activo el backup sigue pusheando al fork cada hora); el healthcheck local no cubre las units qmd; NEXT_STEPS local solo documenta el journal de la sesión (`modules/next-steps.{en,es}.tpl:303`).

## Clarifications

### Session 2026-07-05

- Q: ¿Cómo se recupera el watcher local de salidas repetidas sin quedar en failed permanente? → A: Loop supervisado en el wrapper (backoff ~30s); la unit queda `active` estable y `failed` pasa a indicar anomalía real.
- Q: ¿Por dónde recibe el proceso MCP qmd (lector) el `XDG_CACHE_HOME` del workspace en local? → A: Env granular en el bloque qmd de `.mcp.json` vía variable precomputada en `setup.sh` (docker emite `env:{}` byte-idéntico; local emite el pin). El caso borde `bunx qmd` manual del agente no hereda el pin — se documenta.
- Q: ¿Se incluye el flock de `qmd_setup_if_needed` (lib compartida espejada a docker) para cerrar el solape `--login` vs primer tick del timer? → A: Sí, incluido — cierra 30/30 gaps; gate DOCKER_E2E verde obligatorio + declaración explícita en CHANGELOG (efecto docker benigno: un solo dispatcher al boot).
- Q: El research confirmó que la imagen docker NO tiene `bunx` (solo `bun`; el e2e lo stubea) — QMD en docker nunca funcionó contra binarios reales. ¿Se incorpora el fix a 013? → A: Sí, incluido (segunda excepción docker aprobada): symlink `bunx` en el Dockerfile + aserción DOCKER_E2E contra la imagen real; sin esto 013 no cumple su promesa de RAG agnóstico al modo.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Memoria RAG durable y coherente (storage correcto) (Priority: P1)

Como operador de un agente en modo local con RAG habilitado, quiero que el índice semántico viva con el workspace y que el agente consulte exactamente el índice que el pipeline construye, para que las búsquedas RAG devuelvan mi corpus real hoy, después de migrar de host, y sin depender de rutas accidentales en mi HOME personal.

**Why this priority**: Es la causa raíz que invalida la promesa central de 012 ("índice workspace-durable") y el único punto donde un fix parcial *empeora* las cosas (RAG permanentemente vacío en silencio). Sin esto, durabilidad, idempotencia y observabilidad reportan sobre una ubicación que no existe.

**Independent Test**: En un workspace local con qmd habilitado (bunx/yq stubbeados), correr el entrypoint de setup y renderizar `.mcp.json`: el índice y la config de colecciones deben resolverse bajo `<ws>/.state/`, el MCP debe recibir el mismo entorno, y el render docker debe ser byte-idéntico a v0.6.0.

**Acceptance Scenarios**:

1. **Given** un workspace local con `vault.qmd.enabled=true`, **When** el setup del índice completa, **Then** `index.sqlite` y los modelos existen bajo `<ws>/.state/.cache/qmd` (no en `~/.cache/qmd`) y el sentinel/bookkeeping de la lib observan esa misma ubicación.
2. **Given** el fix aplicado, **When** el agente consulta vía el MCP qmd, **Then** el proceso MCP resuelve el mismo storage que el escritor (par atómico: entrypoint Y env del MCP cambian juntos, nunca uno solo).
3. **Given** un segundo agente local en el mismo host (o un qmd personal del operador), **When** ambos registran su colección, **Then** cada uno indexa y busca su propio vault (config de colecciones aislada por workspace).
4. **Given** el workspace migrado a otro host por rsync/cp -a, **When** el agente arranca, **Then** el RAG responde sin re-descargar modelos ni reindexar desde cero.
5. **Given** modo docker, **When** se renderizan `.mcp.json` y todos los derivados, **Then** el resultado es byte-idéntico a v0.6.0.
6. **Given** `--uninstall --purge` o `--nuke` en local, **When** completan, **Then** no quedan huérfanos nuevos del índice/config fuera del workspace (instalaciones previas al fix: limpieza manual documentada en CHANGELOG).

---

### User Story 2 - Refresco confiable bajo systemd (Priority: P1)

Como operador, quiero que las ediciones del vault (MCP, Write/Edit del agente, Syncthing) refresquen el índice con la misma latencia y resiliencia que en docker (~15s watcher + backstop programado), para que el agente nunca responda con memoria obsoleta sin que nadie lo note.

**Why this priority**: Con RC2+RC3 el refresco local es literalmente inexistente (timer sin bunx/yq, watcher failed permanente). Es la mitad "se mantiene fresco" de la promesa RAG; sin ella el fix de storage solo produce un índice correcto pero congelado.

**Independent Test**: Render de los tres wrappers locales + bats con PATH mínimo estilo systemd (stubs): los wrappers deben auto-proveerse `~/.local/bin` y `<ws>/scripts/vendor/bin`, el watcher debe recibir el path real del vault, y una salida transitoria del watcher no debe dejar la unit en failed permanente.

**Acceptance Scenarios**:

1. **Given** un entorno con PATH mínimo de systemd y bunx/yq instalados en sus rutas reales (`~/.local/bin`, `<ws>/scripts/vendor/bin`), **When** corre el entrypoint de reindex (por timer, watcher o dispatch de `--login`), **Then** bunx y yq resuelven y el reindex se ejecuta.
2. **Given** el watcher local activo, **When** se edita un `.md` del vault real del workspace, **Then** el watcher observa ese path (no `/home/agent/.vault`) y dispara el reindex en ~15s.
3. **Given** una degradación transitoria (vault temporalmente ausente, p. ej. renombrado por Syncthing durante ~1 min), **When** el watcher sale repetidamente, **Then** la unit se recupera sola al volver el vault — nunca queda en failed permanente por start-limit.
4. **Given** el backup del vault con fork configurado, **When** el timer de backup dispara bajo PATH mínimo, **Then** el push al fork ocurre (yq/git resuelven).

---

### User Story 3 - Operabilidad honesta y control total en local (Priority: P2)

Como operador, quiero que el estado que reportan `status`/`doctor`/healthcheck refleje la realidad del RAG y del backup, que existan acciones manuales equivalentes a las de docker, y que el kill-switch detenga TODA la actividad del agente, para operar el modo local con la misma confianza que el contenedor.

**Why this priority**: Los fallos de US1/US2 pasaron inadvertidos precisamente porque la observabilidad local miente por omisión (doctor imprime ✓ con `last_status=error`) y el kill-switch deja actividad viva (push al fork con credenciales del operador). Es la red de seguridad que evita el próximo "roto en silencio".

**Independent Test**: bats sobre `agentctl`/templates con state files y `systemctl` stubbeados: doctor degrada por `last_status=error` y por staleness del backup con exit codes 0/1/2; el kill-switch lista TODAS las units; el healthcheck reporta watcher failed; NEXT_STEPS local documenta el journal de las 3 units.

**Acceptance Scenarios**:

1. **Given** kill-switch local activado, **When** pasan las ventanas de timer (backup horario, healthcheck 5 min), **Then** ninguna unit del agente ejecuta nada (sesión, healthcheck, qmd-reindex, qmd-watch, vault-backup — las cinco detenidas).
2. **Given** `qmd-index.json` con `last_status=error`, **When** el operador corre `agentctl doctor`, **Then** ve un warn/fail explícito (no un ✓ con fecha reciente) y el exit code es ≥1 para scripting.
3. **Given** un backup de vault sin push hace >25h con fork configurado, **When** corre doctor local, **Then** alerta staleness igual que docker.
4. **Given** modo local, **When** el operador corre `agentctl heartbeat qmd-reindex` o `heartbeat backup-vault`, **Then** la acción se ejecuta contra la unit/script local correspondiente en vez del error "Docker-mode command".
5. **Given** el watcher en estado failed, **When** corre el healthcheck periódico, **Then** el reporte incluye un WARN por el watcher (no DEGRADED: el timer backstop preserva frescura).
6. **Given** un `vault.qmd.schedule` no convertible a OnCalendar, **When** se regenera, **Then** el fallback queda registrado de forma consultable (status/doctor lo muestran), no solo como línea efímera en stderr.
7. **Given** un scaffold local con qmd habilitado, **When** el operador lee NEXT_STEPS, **Then** encuentra los comandos de journal/timers de las units RAG.

---

### Edge Cases

- **Fix parcial del par storage**: corregir escritor sin MCP (o viceversa) parte el par lector/escritor → qmd auto-crea un índice vacío y el RAG queda silenciosamente vacío. El par es atómico por requisito (FR-001); los tests deben cubrir ambos lados en el mismo render.
- **Instalaciones previas al fix**: agentes locales ya desplegados tienen índice/config en `~/.cache/qmd` y `~/.config/qmd`. Tras regenerar con 013, el primer setup reconstruye bajo el workspace (regenerable por diseño); los residuos antiguos se documentan en CHANGELOG como limpieza manual — no se automatiza borrado en HOME ajeno al workspace.
- **Units staged sin `--login`** (host sin sudo passwordless): sin trigger automático el RAG queda vacío en silencio. Cubierto como mejora opcional (dispatch host-side de setup en scaffold/regenerate, no requiere sudo) — si el plan lo difiere, doctor/status deben al menos reportar "units staged, not installed".
- **`install_service=false` con qmd habilitado**: el wizard debe advertir que el RAG queda sin trigger automático (hoy degrada en silencio).
- **Dos agentes locales en el mismo host / qmd personal del operador**: sin aislamiento de config, el segundo registrante de la colección busca sobre el corpus ajeno sin error (FR-002).
- **Vault ausente al arrancar el watcher** (orden de boot, Syncthing inicial): misma semántica de recuperación que la degradación transitoria — nunca failed permanente.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001 (US1)**: En modo local, el storage del índice qmd (índice + modelos) DEBE resolverse bajo `<ws>/.state/.cache/qmd` **tanto para el escritor** (entrypoint de setup/reindex) **como para el lector** (proceso MCP qmd de la sesión), usando el contrato de env que el binario realmente honra (verificado: `XDG_CACHE_HOME`). El cambio de escritor y lector DEBE entregarse como par atómico en el mismo release. `QMD_CACHE_HOME` se mantiene exportado para que el bookkeeping de la lib converja con el binario. Vía del lector decidida (Clarifications 2026-07-05): env granular del server qmd en `.mcp.json`, con variable por modo precomputada en `setup.sh` — docker renderiza `env:{}` byte-idéntico (verificable por test); un `bunx qmd` manual del agente fuera del MCP no hereda el pin (caso borde documentado).
- **FR-002 (US1)**: La configuración de colecciones qmd DEBE aislarse por workspace en modo local (bajo `<ws>/.state/`), de modo que múltiples agentes o un qmd personal del operador no colisionen en el nombre de colección. El mecanismo exacto (`QMD_CONFIG_DIR` u equivalente) se verifica contra el tarball 2.5.3 en fase research.
- **FR-003 (US1)**: Sentinel, lock, chequeo de idempotencia y reporte de presencia/frescura del índice DEBEN observar la misma ubicación donde el binario escribe; queda eliminado el estado "collection add reintentado a perpetuidad".
- **FR-004 (US1)**: `--uninstall --purge/--nuke` en modo local NO DEBEN dejar huérfanos nuevos del subsistema RAG fuera del workspace; los residuos de instalaciones previas al fix se documentan como limpieza manual en CHANGELOG.
- **FR-005 (US2)**: Los tres wrappers locales (reindex, watch, vault-backup) DEBEN auto-proveerse un PATH que incluya `~/.local/bin` del operador y `<ws>/scripts/vendor/bin`, cubriendo por igual timer, watcher y dispatch de `--login`.
- **FR-006 (US2)**: El wrapper del watcher DEBE proveer al proceso la resolución del vault local real (`<ws>/<vault.path>`), con el mismo patrón de override ya usado por reindex y backup.
- **FR-007 (US2)**: El watcher local NO DEBE quedar en failed permanente ante degradaciones transitorias; su semántica de recuperación DEBE ser equivalente al respawn del watchdog docker. Mecanismo decidido (Clarifications 2026-07-05): loop supervisado dentro del wrapper con backoff ~30s — la unit permanece `active`; el estado `failed` queda reservado a anomalías reales, dándole señal al WARN del healthcheck (FR-011).
- **FR-008 (US3)**: El kill-switch local DEBE detener todas las units del agente: sesión, healthcheck.timer, qmd-reindex.timer, qmd-watch.service y vault-backup.timer.
- **FR-009 (US3)**: `agentctl doctor` en local DEBE degradar (warn/fail + exit codes 0/1/2 equivalentes a docker) cuando `last_status=error` en el estado del reindex y cuando el backup del vault esté stale (>25h con fork configurado); `agentctl status` DEBE mostrar frescura (última corrida), no solo presencia.
- **FR-010 (US3)**: `agentctl heartbeat qmd-reindex` y `agentctl heartbeat backup-vault` DEBEN funcionar en modo local (mapeados a la unit/script correspondiente) en vez de fallar como comando docker-only.
- **FR-011 (US3)**: El healthcheck local DEBE reportar WARN cuando la unit del watcher exista y esté failed.
- **FR-012 (US3)**: NEXT_STEPS (en/es) DEBE incluir, condicionado a qmd habilitado, los comandos de observación de las units RAG (journal por unit y listado de timers).
- **FR-013 (US3)**: Un fallback de schedule no convertible DEBE quedar registrado de forma persistente y consultable (reportado por status/doctor), no solo como warning efímero.
- **FR-014 (transversal)**: Todos los derivados renderizados en modo docker DEBEN quedar byte-idénticos a v0.6.0. Las únicas excepciones aprobadas al árbol docker son FR-015 (flock del setup en la lib canónica espejada) y FR-016 (symlink `bunx` en la imagen), ambas gated por DOCKER_E2E verde y declaradas en CHANGELOG; fuera de eso, ningún archivo bajo `docker/` cambia.
- **FR-015 (US2)**: `qmd_setup_if_needed` DEBE serializarse bajo el mismo lock que el reindex (decidido en Clarifications 2026-07-05): el solape entre el dispatch de `--login` y el primer tick del timer no DEBE producir doble descarga del modelo ni fallos transitorios de setup; el perdedor del lock sale limpio y el guard del siguiente tick cubre el reintento. Cambio en la lib compartida → DOCKER_E2E verde es gate obligatorio.
- **FR-016 (transversal)**: La imagen docker DEBE proveer `bunx` ejecutable (confirmado en research: hoy solo existe `bun`; `qmd_index.sh` y el MCP qmd invocan `bunx` y el e2e lo stubea, enmascarando que QMD en docker nunca funcionó contra binarios reales). La suite DOCKER_E2E DEBE aseverar la existencia de `bunx` en la imagen real (no vía stub).

### Key Entities

- **Storage QMD del workspace**: índice sqlite + modelos de embeddings bajo `<ws>/.state/.cache/qmd`; regenerable, nunca respaldado, viaja con el workspace.
- **Config de colecciones**: registro de colecciones qmd, aislado por workspace en local.
- **Estados operacionales**: `qmd-index.json` (última corrida, resultado) y `vault-backup.json` en `<ws>/scripts/heartbeat/` — misma ubicación y schema en ambos modos — más el marker `qmd-schedule.fallback` (archivo separado en el mismo directorio, creado/eliminado exclusivamente por `--regenerate`; NO es un campo de `qmd-index.json`, que la lib reescribe entero en cada tick).
- **Units locales del agente**: sesión, healthcheck (timer+service), qmd-reindex (timer+service), qmd-watch (service), vault-backup (timer+service) — inventario único que kill-switch, uninstall, healthcheck y doctor deben conocer completo.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En modo local, una edición del vault se refleja en las búsquedas RAG en ~15s con watcher activo, y dentro de un ciclo del schedule como backstop sin watcher — misma latencia contractual que docker.
- **SC-002**: Migrar el workspace local a otro host conserva la memoria RAG completa: el agente responde búsquedas sobre su corpus sin re-descarga de modelos (~300MB) ni reindexación completa.
- **SC-003**: El render en modo docker de todos los archivos derivados es byte-idéntico a v0.6.0 (diff vacío), verificado por test.
- **SC-004**: Con el kill-switch activo, la actividad del agente es cero: ninguna unit ejecuta, ningún push al fork ocurre en las siguientes 24h de ventanas de timer.
- **SC-005**: `agentctl doctor` no produce falsos ✓: en los escenarios de fallo simulados por la suite (reindex en error, backup stale, watcher failed) siempre degrada con exit code ≥1.
- **SC-006**: Suite host completa verde (test-first); el gate manual en mclaren pasa el checklist confirmatorio completo cuando el host vuelva (los tres fallos predichos por la auditoría — timer sin bunx, watcher failed <35s, índice en `~/.cache` — verificados corregidos).
- **SC-007**: Con `vault.qmd.enabled=true` en modo docker, el contenedor real resuelve `bunx` (aserción DOCKER_E2E contra la imagen, no contra el stub) y la cadena setup→reindex→MCP funciona con binarios reales.

## Assumptions

- El contrato de env del binario qmd es el verificado contra el tarball npm 2.5.3: `INDEX_PATH` > `XDG_CACHE_HOME` > `~/.cache`; el pin 2.5.3 single-source en `agent.yml` no se reabre. Un upgrade futuro de qmd debe re-verificar este contrato.
- `QMD_CONFIG_DIR` como mecanismo de aislamiento de colecciones es una afirmación del finder **no re-verificada**; la fase research la confirma contra el tarball antes de implementar (si no existe, se busca el equivalente `XDG_CONFIG_HOME` con el mismo criterio de par atómico).
- 1 agente por host sigue siendo el caso soportado v1; el aislamiento de FR-002 prepara multi-agente sin comprometerse a soportarlo.
- Los entrypoints locales mantienen fail-silent con exit 0 (Principle IV); la honestidad operacional va en doctor/healthcheck/status, no en exit codes de units.
- El render engine no soporta `{{#if}}` anidado: las variables por modo se precomputan en `setup.sh` (patrón `VAULT_MCP_PATH` de 012).
- Hosts locales son Linux/systemd (Debian-like); macOS/launchd fuera de alcance.
- mclaren (gate confirmatorio) está caído al especificar; el gate se ejecuta cuando vuelva y no bloquea el merge (mismo criterio que 011/012).

## Out of Scope (deuda registrada, no tocar en 013)

- Lado docker: `status`/`doctor` docker no reportan RAG; stderr del watcher docker va a `/dev/null`; retry de setup docker solo al boot (local queda superior con el double-hook). Backlog para una feature docker-side.
- macOS/launchd; rediseño del esquema qmd o del modelo de tres ramas de backup; heartbeat scheduling y plugin auto-install en local (siguen diferidos de 011).

*(Nota: el symlink `bunx` en la imagen docker estaba aquí condicionado al research; el research lo confirmó REAL y pasó a alcance como FR-016 — ver Clarifications 2026-07-05.)*
