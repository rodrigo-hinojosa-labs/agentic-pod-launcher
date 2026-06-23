# Contracts: Shell functions (006-headless-bootstrap)

Contratos de las funciones shell nuevas/cambiadas. Todas image-baked en `docker/scripts/`, salvo el `.env` writer/wizard (host-launcher en `setup.sh`). Cada contrato lista firma, entradas, salidas, idempotencia y el seam de test bats (host, sin Docker).

## `has_oauth_token()` — NUEVO (`start_services.sh`, §4 helpers)

- **Firma**: `has_oauth_token()` → exit 0 si `CLAUDE_CODE_OAUTH_TOKEN` no vacío; 1 si unset/empty.
- **Entrada**: env var `CLAUDE_CODE_OAUTH_TOKEN` (heredada del env_file).
- **Salida**: solo código de retorno. NUNCA imprime el valor (secret hygiene).
- **Idempotencia**: lectura pura; sin efectos.
- **Patrón**: espejo de `has_telegram_token` (debe definirse antes de `next_tmux_cmd`/`_check_auth_flip`).
- **Test**: `CLAUDE_CODE_OAUTH_TOKEN` set → rc 0; unset/empty → rc 1.

## `next_tmux_cmd()` — CAMBIO (guard Case A)

- **Contrato nuevo**: el fallback a bare `claude` (Case A, `/login`) se toma solo si `! _channel_plugin_ready && ! has_oauth_token`. Con token presente, NUNCA emite bare-claude; procede a Case B/C (instala plugins / engancha canal) y deja que `ensure_all_plugins_installed` reintente en respawns.
- **Invariante preservada**: sin token y sin plugin listo → Case A (regresión guard intacta).
- **Salida**: string del comando tmux (sin el valor del token).
- **Test**: token set + plugin no listo ⇒ output NO contiene el patrón bare-claude/`/login`; token unset + plugin no listo ⇒ sí (Case A).

## `_check_auth_flip()` — CAMBIO (short-circuit por token)

- **Contrato nuevo**: al tope, si `has_oauth_token`, fijar `_prev_auth_present=1` y `return 0` — el agente token-autenticado se trata como ya autenticado en baseline; la aparición de `.credentials.json` no dispara kick.
- **Invariante preservada**: sin token, el comportamiento de detección absent→present (Story A) es idéntico.
- **Idempotencia**: por-tick; sin estado nuevo.
- **Test (extiende `watchdog-auth-flip-detection.bats`)**: con `has_oauth_token` true, tocar `AUTH_MARKER_OVERRIDE` ⇒ `_kick_count == 0`; sin token, el caso existente sigue verde.

## `ensure_official_marketplace()` — NUEVO (`start_services.sh`, dentro de `pre_accept_extra_marketplaces`)

- **Firma**: `ensure_official_marketplace()` → 0 siempre (fail-silent).
- **Comportamiento**: si `claude plugin marketplace list` NO contiene `claude-plugins-official`, ejecutar `CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR_VAL claude plugin marketplace add anthropics/claude-plugins-official --scope user`; si ya está, no-op. Corre antes de `ensure_all_plugins_installed`.
- **Idempotencia**: guard por `marketplace list` (no re-add).
- **Fail-silent**: fallo de clone/red ⇒ `|| true` + log WARN; no bloquea ni crashea; se reintenta en el próximo tick.
- **Single source**: el slug `anthropics/claude-plugins-official` y el nombre `claude-plugins-official` como constantes (junto a `REQUIRED_CHANNEL_PLUGIN`).
- **Test (extiende `start-services-plugin-install.bats`, stub PATH `claude`)**: list sin el oficial ⇒ llama `marketplace add` con el slug; list con el oficial ⇒ no-op (idempotencia); stub que falla el add ⇒ rc 0 + WARN (fail-silent).

## `retry_plugin_install_bounded()` — CAMBIO (`plugin-install.sh`)

- **Contrato nuevo**: añadir clasificación de "marketplace not found"/"No marketplaces configured"/"unknown marketplace" como outcome distinto (no-retry, etiqueta propia), separado del auth-skip (rc=2). `ensure_plugin_installed_one` deja de loguear el catch-all "not authenticated yet or install failed" para ese caso.
- **Invariante**: auth-skip (rc=2) y fallo genérico (rc=1) sin cambios para los demás casos.
- **Test**: extender `CLAUDE_STUB_MODE` con `no-marketplace` ⇒ NO se reintenta 3× y NO se clasifica como "not authenticated".

## `pre_seed_onboarding()` — NUEVO (`start_services.sh`, llamado en `start_session`)

- **Firma**: `pre_seed_onboarding()` → 0 siempre.
- **Comportamiento**: jq-merge en `$CLAUDE_CONFIG_DIR_VAL/.claude.json` las keys de onboarding (theme/trust/hasCompletedOnboarding — nombres confirmados por diff contra 2.1.170), **creando** el archivo si no existe. Acompañado del relax de `pre_accept_bypass_permissions` para CREAR `settings.json` si falta (seed `{}` antes del merge).
- **Idempotencia**: re-merge no-op si las keys ya están.
- **Version-guard**: si la versión no matchea las keys conocidas ⇒ WARN, no romper (FR-014).
- **Test (`start-services-onboarding.bats`, NUEVO)**: `.claude.json` ausente ⇒ se crea con las keys; presente ⇒ idempotente; `settings.json` ausente ⇒ `pre_accept_bypass_permissions` ahora lo crea con `defaultMode=auto`.

## `.env` writer + wizard — CAMBIO (`setup.sh`)

- **Wizard**: nuevo paso "Claude authentication" (cerca del bloque de notificaciones): instruye `claude setup-token` en el host y recoge con `ask_secret` (vacío = skip válido). Debe funcionar en `wizard.sh` y `wizard-gum.sh` (sin echo del valor).
- **.env writer** (`setup.sh` ~1137): si el token fue provisto, emitir `CLAUDE_CODE_OAUTH_TOKEN=<valor>` al `.env` (idiom condicional existente); `.env` queda `0600`. Si vacío, no emitir línea con valor.
- **`modules/env-example.tpl`**: añadir sección comentada `# Claude headless auth — from 'claude setup-token'` + `CLAUDE_CODE_OAUTH_TOKEN=` (sin valor).
- **Test**: render de `env-example.tpl` contiene `CLAUDE_CODE_OAUTH_TOKEN=` sin valor (`modules-render.bats`); writer escribe la línea con token provisto / la omite sin token (`.env` 0600).
