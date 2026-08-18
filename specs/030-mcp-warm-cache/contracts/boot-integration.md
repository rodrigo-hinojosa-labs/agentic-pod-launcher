# Contrato — integración del warm en boot (docker) y en login (local)

## Docker — `mcp_warm_run` en `start_services.sh`

- **B1 (pre-claude, síncrono)**: el warm corre ANTES del `tmux new-session` que lanza `claude`
  (`start_services.sh:797`), de modo que cuando `claude` arranca sus MCPs el paquete ya está tibio.
  Ubicación: un `pre_warm_mcps` junto a los `pre_*` de `start_session()` (`:781-783`) o al final de
  `boot_side_effects()` (`:134-176`). Síncrono (no background): backgroundear no arregla el race del
  mismo boot (research D4).
- **B2 (usuario `agent`)**: corre como `agent` (privilegios ya bajados, `entrypoint.sh:118`), que puede
  escribir `/opt/uv` y `/opt/npm-cache`.
- **B3 (timeout + fail-soft)**: cada warm es best-effort con timeout por paquete; un fallo emite `warn`
  y continúa (FR-007). El paso SIEMPRE retorna 0; nunca aborta el boot ni consume crash budget por
  fallo (solo por crash, que este paso no produce).
- **B4 (sin secretos)**: no lee `.env` ni credenciales (FR-006/SC-005). Instalar el paquete es
  independiente de las credenciales de arranque del MCP.
- **B5 (idempotente)**: segundo boot → no-op rápido (cache del gestor).
- **B6 (testable sin Docker)**: `pre_warm_mcps` guarda su side-effect tras `START_SERVICES_NO_RUN`/
  `BASH_SOURCE` (patrón `:1256`) para que los bats sourceen `start_services.sh` sin ejecutar el warm.
- **B7 (warmers)**: `uvx` → `uv tool install <spec>` (con `--python python3` si hay, reusando el
  patrón `provision_uv_tools`); `npx` → poblar `/opt/npm-cache` con el spec (p. ej.
  `npm exec --prefer-offline -y --package=<spec> -- true`). Warm al **spec literal** (fidelidad de pin).

## Docker — distribución de la lib (mirror)

- **B8**: `scripts/lib/mcp_warm.sh` se hace disponible en la imagen (mirror a `docker/scripts/lib/` como
  `mcp-catalog.sh`, o git-track + COPY como `backup_config.sh`) y `start_services.sh` la sourcea. La
  línea de mirror/COPY es obligatoria (gotcha `docker-lib-needs-explicit-copy`); un test/verificación lo
  cubre.

## Local — `provision_uv_tools` args-aware

- **B9**: `provision_uv_tools` (`local-bootstrap.sh.tpl`) deriva sus paquetes uvx vía `mcp_warm_targets`
  (filtrando `runtime==uvx`), en vez del selector `command=="uvx" | args[0]`. Así cubre el wrapper
  google-workspace (D5). Mantiene el `--with mcp==<lib>` y `_mcp_pin` para el catálogo.
- **B10 (alcance)**: local warmea uvx-only (no se agrega warm de npx en local; deuda preexistente,
  fuera de 030). Corre en `--login`, sin `sudo`.
- **B11 (single-source)**: la derivación es la MISMA que usa docker (`mcp_warm_targets`); no se duplica
  el jq. Ubicación de la lib para el bootstrap local = tarea de implementación; el invariante es fuente
  única.

## No-regresión (ambos)

- **B12**: un agente sin MCP de overlay warmea exactamente el set de hoy; el catálogo baked del
  `Dockerfile:121-125` se conserva (FR-009). El `.mcp.json` derivado y el comportamiento de arranque no
  cambian para ese caso.
