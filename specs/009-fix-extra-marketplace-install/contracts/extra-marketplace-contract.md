# Contrato: `ensure_extra_marketplaces`

**Feature**: 009-fix-extra-marketplace-install · **Archivo**: `docker/scripts/start_services.sh`

Función nueva en el supervisor, espejo de `ensure_official_marketplace`, que resuelve los marketplaces de terceros declarados antes del loop de instalación de plugins.

## Firma e invocación

- `ensure_extra_marketplaces` — sin argumentos; deriva la lista de `plugin_catalog_marketplaces_json /workspace/agent.yml`.
- Invocada en `next_tmux_cmd`, en el orden: `pre_accept_extra_marketplaces` → **`ensure_extra_marketplaces`** → `ensure_official_marketplace` → `ensure_all_plugins_installed`.

## Precondiciones

- Puede ejecutarse con o sin `claude` en PATH (degradación: si `command -v claude` falla, no-op `return 0`).
- `plugin_catalog_specs` / `plugin_catalog_marketplaces_json` disponibles (catálogo espejado); si no, no-op `return 0`.

## Comportamiento (por cada marketplace de terceros `key` → `repo`)

1. Si `CLAUDE_CONFIG_DIR=… [timeout N] claude plugin marketplace list` muestra `key` → ya *resuelto*, continuar (idempotente, sin re-registrar).
2. Si no, `CLAUDE_CONFIG_DIR=… [timeout N] claude plugin marketplace add <repo> --scope user`.
   - Éxito → `log "extra marketplace registered: <key>"`.
   - Fallo/timeout → `log "WARN: extra marketplace <key> registration failed or timed out (will retry next tick)"`; continuar con el siguiente.

## Postcondiciones / garantías

- **Idempotente**: un `key` ya resuelto no se re-registra; segura de re-correr en cada respawn.
- **Acotada**: toda invocación a `claude` se envuelve en `timeout ${MARKETPLACE_CMD_TIMEOUT:-12}` cuando `command -v timeout`; si `timeout` no existe (host de test), degrada a la llamada directa. Nunca bloquea indefinidamente el boot (Principio IV).
- **Fail-silent**: siempre `return 0`; el fallo de un marketplace no aborta el boot ni impide registrar otros.
- **Sin secretos**: no imprime tokens; los repos/keys son públicos (no sensibles).
- **Cero regresión oficial**: no toca `ensure_official_marketplace` ni el camino `@claude-plugins-official`.

## Efecto sobre la instalación de plugins

Tras `ensure_extra_marketplaces`, cuando `ensure_all_plugins_installed` → `retry_plugin_install_bounded "plugin@key"` ejecuta `claude plugin install`, el marketplace `key` ya está *resuelto* → no se dispara la rama "marketplace not registered yet" (plugin-install.sh:43-45) y el plugin instala (`return 0`). El skip rc=2 por marketplace no registrado deja de ocurrir en el happy path.

## Observabilidad

- Log por marketplace: `registered` o `WARN: … failed or timed out`.
- Fallos residuales de `plugin install` siguen el registro existente (`PLUGIN_FAILURES_FILE`), sanitizados.

## Cobertura de tests

- **Host-side** (`tests/start-services-extra-marketplace.bats`): registra-cuando-ausente; idempotente-cuando-presente; acotado-cuando-cuelga (con shim `timeout`); degrada-sin-timeout; no-op-sin-claude.
- **DOCKER_E2E** (`tests/docker-e2e-postlogin.bats`, extensión): boot de un agente con un plugin de marketplace de terceros declarado → el plugin queda instalado; el stub `claude` maneja `marketplace add <repo-de-terceros>` y `plugin install <plugin>@<key>`.
