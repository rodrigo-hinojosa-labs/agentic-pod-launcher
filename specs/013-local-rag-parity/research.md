# Research: 013-local-rag-parity

**Date**: 2026-07-05. Fase 0 del plan. Todas las incógnitas del Technical Context resueltas — las dos verificaciones diferidas desde el spec (Assumptions) se ejecutaron contra fuentes primarias: el tarball npm real de `@tobilu/qmd@2.5.3` (extraído en scratchpad por la auditoría wf_37295b56 y re-inspeccionado en esta fase) y el árbol del repo en `013-local-rag-parity`.

## R1 — Contrato de env de storage del binario qmd (VERIFICADO)

- **Decision**: relocalizar índice+modelos vía `XDG_CACHE_HOME="${WORKSPACE}/.state/.cache"` (qmd anexa `/qmd`) y mantener `QMD_CACHE_HOME` para el bookkeeping de la lib bash. `INDEX_PATH` se descarta como mecanismo.
- **Rationale**: evidencia del tarball — índice: `INDEX_PATH` > `$XDG_CACHE_HOME/qmd/<index>.sqlite` > `homedir()/.cache/qmd/` (`dist/store.js:420-435`); modelos: `$XDG_CACHE_HOME/qmd/models` o `~/.cache/qmd/models` (`dist/llm.js:119-121`); el help del CLI documenta `XDG_CACHE_HOME` como el mecanismo oficial de relocación ("moves the default index cache, model cache, and MCP daemon PID files", `dist/cli/qmd.js:3151`). `QMD_CACHE_HOME` = 0 ocurrencias en el paquete. `XDG_CACHE_HOME=<ws>/.state/.cache` + `/qmd` = exactamente el valor ya exportado en `QMD_CACHE_HOME` → lib y binario convergen sin tocar la lib.
- **Alternatives considered**: `INDEX_PATH` (solo mueve el índice, no modelos ni PID files del daemon MCP — insuficiente); cambiar la lib para dejar de usar `QMD_CACHE_HOME` (toca la lib espejada sin necesidad; más diff docker).

## R2 — Aislamiento de config de colecciones (VERIFICADO — supuesto del spec confirmado)

- **Decision**: `QMD_CONFIG_DIR="${WORKSPACE}/.state/.config/qmd"` en el mismo par escritor+lector.
- **Rationale**: `dist/collections.js:59-65` — `QMD_CONFIG_DIR` (si está seteado, se usa tal cual) > `XDG_CONFIG_HOME` + `/qmd` > `~/.config/qmd`. Documentado en el help del CLI (`dist/cli/qmd.js:3149`: "overrides the QMD config directory and takes precedence over XDG_CONFIG_HOME"). El comentario del código dice "for testing" pero el help lo publica como contrato de usuario → estable para el pin de 2.5.3 (pin single-source; un upgrade re-verifica, ver R11).
- **Alternatives considered**: `XDG_CONFIG_HOME=<ws>/.state/.config` (equivalente, pero contaminaría la config XDG de cualquier otro proceso hijo si se usara en un scope más amplio; `QMD_CONFIG_DIR` es quirúrgico y explícito).

## R3 — bunx en la imagen docker (VERIFICADO — bug REAL, escaló a FR-016)

- **Decision**: agregar `ln -s /usr/local/bin/bun /usr/local/bin/bunx` al bloque RUN de bun del `docker/Dockerfile` + aserción DOCKER_E2E de que `/usr/local/bin/bunx` existe en la imagen real.
- **Rationale**: el Dockerfile instala SOLO el binario `bun` desde el zip musl (`docker/Dockerfile:105-124`, `mv .../bun /usr/local/bin/bun` — el zip no trae bunx); `grep -rn bunx docker/` = solo un comentario. Pero `qmd_index.sh` invoca `bunx` (`:88`) y lo exige (`command -v bunx` en `:137` y `:215`), y el MCP qmd usa `command: bunx` (`modules/mcp-json.tpl:73-77`). `tests/docker-e2e-qmd.bats:78-97` **stubea bunx**, enmascarando la ausencia. Contraste: el bootstrap local SÍ crea el symlink (`modules/local-bootstrap.sh.tpl:162` `ln -sf bun bunx`). Conclusión: QMD en docker nunca funcionó contra binarios reales; ningún despliegue vivo lo detectó (ferrari tiene qmd off; mclaren es local).
- **Alternatives considered**: cambiar todas las invocaciones a `bun x` (toca lib espejada + mcp-json + bootstrap — diff mucho mayor y divergente del ecosistema bun estándar); feature 014 separada (rechazada en Clarify Q4: bloqueaba QMD-en-ferrari un release y dejaba el e2e mintiendo).

## R4 — Vehículo del env del lector MCP (decidido en Clarify Q2)

- **Decision**: `setup.sh` precomputa `QMD_MCP_ENV` — docker: `{}` literal; local: `{"XDG_CACHE_HOME":"<ws>/.state/.cache","QMD_CONFIG_DIR":"<ws>/.state/.config/qmd"}` — y `mcp-json.tpl` renderiza `"env": {{QMD_MCP_ENV}}`.
- **Rationale**: el render engine no soporta `{{#if}}` anidado dentro de `{{#if VAULT_QMD_ENABLED}}` (limitación conocida, patrón `VAULT_MCP_PATH` de 012); el literal `{}` en docker preserva byte-identidad demostrable por test. Alcance quirúrgico: solo el proceso MCP qmd recibe el pin.
- **Alternatives considered**: `remote-control.env` global (redirige caches XDG de toda la sesión — blast radius injustificado); ambos (redundante, doble superficie de test).

## R5 — PATH de los contextos batch (decidido; cubre RC2)

- **Decision**: `export PATH="{{OPERATOR_HOME}}/.local/bin:{{DEPLOYMENT_WORKSPACE}}/scripts/vendor/bin:$PATH"` como primera acción de los 3 wrappers (`local-qmd-reindex.sh.tpl`, `local-qmd-watch.sh.tpl`, `local-vault-backup.sh.tpl`).
- **Rationale**: el PATH default de systemd para services de sistema excluye `~/.local/bin` (bunx, del bootstrap 011) y `<ws>/scripts/vendor/bin` (yq v4 vendorado). Fijarlo en el wrapper — no en la unit — cubre los 4 contextos de invocación (timer, watcher→QMD_REINDEX_CMD, dispatch nohup de `--login`, ejecución manual del operador/agentctl) con un solo cambio testeable por render. Patrón ya validado por 011 para la sesión (`remote-control.env.tpl:13`).
- **Alternatives considered**: `Environment=PATH=...` en las 3 units (no cubre dispatch de --login ni ejecución manual); `EnvironmentFile=remote-control.env` en las units (arrastra `CLAUDE_CONFIG_DIR`/`HOME` innecesarios a contextos batch).

## R6 — Env del watcher (cubre RC3)

- **Decision**: `local-qmd-watch.sh.tpl` exporta `QMD_VAULT_DIR="{{LOCAL_VAULT_DIR}}"` y `VAULT_ROOT_OVERRIDE="{{LOCAL_VAULT_DIR}}"`.
- **Rationale**: hoy solo exporta `QMD_WATCH_AGENT_YML` y `QMD_REINDEX_CMD` (`modules/local-qmd-watch.sh.tpl:15-16`); sin override, `qmd_watch.sh:33-43` resuelve vía `vault_resolve_root` que rebasea a `/home/agent/.vault`. `QMD_VAULT_DIR` es override contractual de la lib; `VAULT_ROOT_OVERRIDE` (aditivo de 012) cubre el mismo camino en `backup_vault.sh`. Espejo exacto del patrón ya presente en `local-qmd-reindex.sh.tpl:24-26`.
- **Alternatives considered**: ninguna seria — es la omisión simétrica del template hermano.

## R7 — Resiliencia del watcher (decidido en Clarify Q1)

- **Decision**: loop supervisado en el wrapper (`while :; do bash "${WORKSPACE}/scripts/qmd_watch.sh"; sleep 30; done`) reemplazando el `exec`; la unit conserva `ExecCondition=command -v inotifywait` y `Restart=always`/`RestartSec=2` como cinturón.
- **Rationale**: replica el respawn infinito del watchdog docker manteniendo la unit `active` estable; `failed` queda reservado a anomalías reales (señal para el WARN del healthcheck, FR-011); sin churn de restarts en journal. `ExecCondition` sigue resolviendo la degradación sin inotify-tools ANTES de arrancar el loop.
- **Alternatives considered**: `StartLimitIntervalSec=0` (churn de journal cada 2s en degradaciones largas; NRestarts sin significado); híbrido (dos mecanismos que testear sin beneficio marginal — Restart=always ya queda de cinturón del loop).

## R8 — Flock del setup (decidido en Clarify Q3; FR-015)

- **Decision**: envolver el cuerpo efectivo de `qmd_setup_if_needed` en `flock -n` sobre el mismo `$cache_root/.reindex.lock` que usa `qmd_reindex`; el perdedor loguea y retorna 0.
- **Rationale**: cierra el solape dispatch-de-login vs primer tick del timer (doble descarga ~300MB / fallos transitorios de `collection add`). Mismo lock = también serializa setup-vs-reindex. Cambio en la lib canónica espejada → comportamiento docker cambia de forma benigna (un solo dispatcher al boot) → DOCKER_E2E obligatorio + CHANGELOG.
- **Alternatives considered**: lock separado `.setup.lock` (no serializa setup-vs-reindex; dos locks que razonar); diferir (rechazado en Clarify Q3).

## R9 — Acciones manuales locales (plan-level)

- **Decision**: en modo local, `agentctl heartbeat qmd-reindex` ejecuta `<ws>/scripts/local/agent-qmd-reindex.sh` y `agentctl heartbeat backup-vault` ejecuta `<ws>/scripts/local/agent-vault-backup.sh`, directamente como el operador; passthrough de `--dry-run` donde exista.
- **Rationale**: las units corren `User=` operador, así que el exec directo produce el mismo efecto sin `systemctl start` (que en units de sistema exige root/polkit — fricción que el flujo local sin sudo passwordless no puede asumir). Los scripts ya son idempotentes/fail-silent.
- **Alternatives considered**: `systemctl start agent-<n>-...` (bloquea a operadores sin polkit/sudo; además `start` de un oneshot en marcha falla con "already running").

## R10 — Persistencia del fallback de schedule (plan-level)

- **Decision**: cuando `cron_to_systemd_calendar` cae al default, `setup.sh` escribe `<ws>/scripts/heartbeat/qmd-schedule.fallback` (contenido: schedule original, OnCalendar aplicado, timestamp del regenerate) y lo elimina cuando la conversión es exacta; `_local_vault_qmd_status`/`doctor` lo reportan.
- **Rationale**: un archivo marker derivado del regenerate es puro (Principle I — se recrea/borra en cada render), consultable en cualquier momento, y no requiere tocar el schema de `qmd-index.json` (que la lib reescribe atómicamente en runtime y pisaría un campo escrito por setup).
- **Alternatives considered**: campo en `qmd-index.json` (la lib lo reescribe entero en cada tick — el campo del setup se perdería); solo warning en stderr (statu quo, efímero — es el gap).

## R11 — Residuos legacy y upgrade de qmd

- **Decision**: instalaciones locales pre-013 dejan índice/config en `~/.cache/qmd` y `~/.config/qmd`; el CHANGELOG documenta la limpieza manual opcional (el índice es regenerable — el primer setup post-upgrade reconstruye bajo el workspace). Ningún `rm` automático fuera de rutas propias del launcher. El contrato R1/R2 queda anclado al pin 2.5.3: la nota de upgrade del pin en `agent.yml` debe incluir "re-verificar contrato de env contra el tarball".
- **Rationale**: borrar en el HOME del operador es exactamente la clase de acción destructiva que el launcher no debe automatizar (regla de seguridad del proyecto); la regeneración del índice hace la limpieza opcional, no necesaria.
- **Alternatives considered**: migrar (mv) el índice viejo al workspace (hereda una config de colecciones potencialmente compartida con el qmd personal del operador — el aislamiento de R2 pide reconstruir limpio).

## R12 — Alcance purge/nuke local

- **Decision**: en `uninstall()` (ramas `--purge`/`--nuke`) con `deployment.mode=local`, remover además `~/.cache/agent-backup/vault-clone`.
- **Rationale**: es el único clone cache que el modo local usa (identity/config no están portados a local), contiene una copia del markdown del vault (remanencia de datos privados post-nuke) y es una ruta creada por el launcher (legítimo removerla). Tras R1, índice/config qmd viven en el workspace y caen solos con purge/nuke.
- **Alternatives considered**: remover todo `~/.cache/agent-backup` (podría llevarse clones de un futuro segundo agente u otros modos — demasiado ancho).
