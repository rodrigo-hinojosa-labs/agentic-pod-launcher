# Contrato — DOCKER_E2E (gate SC-001)

Gateado por `DOCKER_E2E=1`. No corre en la suite host hermética ni en esta sesión (sin daemon); se
difiere a un host Docker, como 016/017/026. Patrón base: `docker-e2e-vault.bats:207-224` (offline) +
`docker-e2e-versions.bats` (`uv tool list`) + RED por build-arg de `docker-e2e-qmd.bats:417`.

## E1 — Warm cubre un MCP estilo-overlay (GREEN)

1. Scaffold de un agente cuyo `.mcp.json` declara un MCP uvx estilo-overlay: `workspace-mcp` (el
   paquete del incidente), idealmente con la forma wrapper `command=<script>, args=[uvx, workspace-mcp]`
   para ejercer la derivación args-aware end-to-end.
2. `docker compose build`.
3. Recrear el contenedor (o `compose run` throwaway con `--entrypoint` override, `-u agent`).
4. Verificar OFFLINE (sin red = flag del gestor, NO `--network`):
   - uvx: `UV_OFFLINE=1 uvx workspace-mcp --help` rc 0, o `uv tool list | grep workspace-mcp`.
   - (npx, si se declara uno de overlay npx: `npm exec --offline --prefer-offline -y --package=<spec> -- true` rc 0, sin `errno -35`).
5. FR-004: `test -d /opt/uv && test -d /opt/npm-cache` (fuera del bind-mount).

## E2 — Sin warm, el MCP NO está tibio (RED)

Build con el warm de boot desactivado por build-arg (patrón `QMD_NATIVE_TOOLCHAIN=0`). La verificación
offline de E1 DEBE fallar → prueba de que `pre_warm_mcps` es load-bearing. Restaurar.

## E3 — No-regresión del catálogo

Un agente sin MCP de overlay: el catálogo baked (`mcp-atlassian`/`mcp-server-fetch`/`mcp-server-time`)
sigue tibio offline (como hoy, `docker-e2e-versions.bats`). El boot no se alarga de forma que dispare el
watchdog/crash budget en el caso ya-tibio (segundo boot = no-op).

## E4 — Verificación previa del comportamiento offline de `uv` (riesgo D7)

Antes de confiar en E1/E2: confirmar en el host Docker que `UV_OFFLINE=1 uvx <pkg-frío>` FALLA sobre un
cache frío (a diferencia de npm, el offline de uv no está probado en el repo). Si `uv` no falla en frío,
elegir la aserción `uv tool list | grep <pkg>` (presencia del tool instalado) como oráculo, que no
depende del modo offline. Documentar el resultado.

## Gate de hardware (SC-001 real, fuera de CI)

Recrear el contenedor de `donna` en ferrari con la red a PyPI cortada y verificar que `google-workspace`
conecta — el criterio de aceptación duro del incidente. Se cierra en el despliegue de esta versión,
gateado por el operador.
