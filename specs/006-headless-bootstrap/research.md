# Research: Headless bootstrap

**Feature**: 006-headless-bootstrap · **Date**: 2026-06-22

Verificación empírica contra el agente de prueba `rodri-cenco-admin` (claude **2.1.170**, contenedor Alpine, Docker Desktop macOS/VirtioFS). Resuelve las incógnitas dependientes de versión que el spec marcó como "a verificar, no inventar" (FR-014).

## D1 — Transporte y precedencia del token de auth headless

- **Decisión**: autenticar por `CLAUDE_CODE_OAUTH_TOKEN` en `<workspace>/.env`; docker-compose ya lo inyecta vía `env_file: ./.env`, así que el proceso `claude` (en tmux) lo hereda sin cambios de compose.
- **Evidencia**: tras poner el token (108 chars, `sk-ant-oat01-…`) en `.env` + recrear el contenedor, `CLAUDE_CODE_OAUTH_TOKEN=SET (len=108)` en el entorno y `claude -p "…"` → `READY` sin `401`; el proceso `claude` de tmux porta el token (`/proc/<pid>/environ` count=1). Precedencia documentada (docs.claude.com): API key > `ANTHROPIC_AUTH_TOKEN` > `apiKeyHelper` > OAuth; aquí todas las API keys están `unset`, así que el token OAuth es el método efectivo.
- **Diagnóstico de errores**: un token corrupto produce `401 Invalid bearer token` (no "Not logged in"); esto prueba que claude **usa** la env var (el método es correcto) y el valor es el problema. Causa del 401 inicial: se pegó el *authorization code* (`code#state`, 92 chars) en vez del token de larga duración. El flujo correcto: `claude setup-token` → pegar el `code#state` **en la terminal** → claude imprime `sk-ant-oat01-…` → ese va al `.env`.
- **Alternativas descartadas**: (a) `/login` interactivo — no persiste bajo VirtioFS (el bug); (b) `ANTHROPIC_API_KEY` — no es subscription-based, cambia el modelo de facturación/identidad; (c) named volume para `~/.claude` — out of scope (reintroduce el regression "down -v borra login" de PR #3).

## D2 — Registro del marketplace oficial (headless)

- **Decisión**: registrar con `claude plugin marketplace add anthropics/claude-plugins-official --scope user`, idempotente con guard previo `claude plugin marketplace list | grep claude-plugins-official`. Insertar en `pre_accept_extra_marketplaces` (corre antes de `ensure_all_plugins_installed` en `next_tmux_cmd`).
- **Evidencia**: ejecutado headless con el token →
  ```
  ✔ Successfully added marketplace: claude-plugins-official (declared in user settings)
  claude plugin install telegram@claude-plugins-official → ✔ Successfully installed plugin
  ```
  El nombre de marketplace registrado (`claude-plugins-official`) coincide con la cache key que `plugin_cache_dir_for` espera. El repo fuente es `github.com/anthropics/claude-plugins-official` ("Official, Anthropic-managed directory of high quality Claude Code Plugins").
- **Por qué hoy falla**: `plugin_catalog.sh` deliberadamente no emite nada en `extraKnownMarketplaces` para specs `@claude-plugins-official` (comment "Plugins without a marketplace contribute nothing"); bajo `/login` interactivo el onboarding de claude sembraba el marketplace oficial, pero la auth headless lo salta → `marketplace list` vacío → todo `install` falla.
- **Riesgos**: `marketplace add` clona por red (HTTPS git) hacia el bind-mount VirtioFS → clone lento/fallido debe tolerarse (`|| true` + WARN, no bloquear el watchdog tick). El slug se single-sources como constante (cf. `REQUIRED_CHANNEL_PLUGIN`) para no duplicar literales (Principio VI).
- **Alternativas descartadas**: añadir el oficial a `extraKnownMarketplaces` vía jq — `extraKnownMarketplaces` registra marketplaces *conocidos* pero `marketplace add` es el primitivo que además clona/valida; el path probado y funcional es `marketplace add`.

## D3 — Saltar el onboarding de primer arranque (theme + trust)

- **Decisión**: pre-sembrar el estado de onboarding en `~/.claude/.claude.json` (NO `settings.json`) y crear `settings.json` si falta para que `defaultMode=auto` + skip-perms apliquen desde el primer boot. El valor exacto de las keys se confirma con un experimento de "diff de onboarding" contra 2.1.170 **en la fase de implementación** (test-first), no se hardcodea a ciegas.
- **Evidencia parcial**: con un `CLAUDE_CONFIG_DIR` fresco en tmpfs, `claude -p "hi" --dangerously-skip-permissions` corre **sin** bloquear y escribe un `.claude.json` (24946 bytes) cuyas keys top-level son `cachedExperimentFeatures … firstStartTime migrationVersion … projects seenNotifications … userID`; las keys candidatas (`theme`, `hasCompletedOnboarding`, `hasTrustDialogAccepted`, `bypassPermissionsModeAccepted`) están **ausentes/`null`** porque el modo `-p` no ejecuta el onboarding interactivo. El theme picker + trust dialog bloquean solo el **TUI** (bare `claude` / `--channels`), no `-p`.
- **Implicación de implementación**: el método para fijar las keys correctas es completar el onboarding una vez en un `CLAUDE_CONFIG_DIR` coherente (tmpfs) y diffear el `.claude.json` resultante (keys que pasan de ausente→presente), capturando los nombres reales para 2.1.170. Guardar el pre-seed con version-guard/fail-loud (FR-014): si las keys no matchean la versión, log WARN y no romper. Reutilizar el patrón jq-merge de `pre_accept_bypass_permissions` pero **creando** el archivo si no existe (hoy hace `[ -f ] || return 0`).
- **Alternativas consideradas**: (a) pre-warm con un `claude -p` en boot para sembrar `firstStartTime`/`userID` y ver si el TUI ya no pide onboarding — a evaluar en implementación como camino más simple si el diff confirma que basta con el perfil existente; (b) `--dangerously-skip-permissions` ya neutraliza el trust dialog en Case C (verificado: `-p` con esa flag no pidió trust), así que el foco del pre-seed es el **theme picker** del TUI.

## D4 — Reconocimiento del token en el supervisor

- **Decisión**: helper `has_oauth_token()` (presencia de `CLAUDE_CODE_OAUTH_TOKEN` en el entorno, espejo de `has_telegram_token`); guard en `next_tmux_cmd` para no caer a bare-claude `/login` con token presente; short-circuit en `_check_auth_flip` (baseline `_prev_auth_present=1`) para que la ausencia de `.credentials.json` no dispare un kick espurio.
- **Evidencia**: con el token, el proceso claude autentica (D1) y `claude plugin install` deja de devolver el rc=2 "not authenticated"; el único fallo restante era el marketplace (D2). El happy path ya funciona implícitamente (install OK → sentinel → `_channel_plugin_ready` true → Case A saltado), pero sin el guard es frágil: un fallo no-auth del primer install dejaría al watchdog en bare-claude (que con token NO muestra `/login`, sino que queda idle) sin nada que lo haga avanzar — de ahí el guard explícito.
- **Riesgo**: el token escribe **no** `.credentials.json`; sin el short-circuit, si un `/login` interactivo se mezcla y materializa el archivo, el flip dispararía un kill-session a mitad de conversación.

## D5 — Observabilidad: distinguir "marketplace not found" de "not authenticated"

- **Decisión**: en `plugin-install.sh::retry_plugin_install_bounded`, añadir una rama que reconozca "No marketplaces configured"/"not found in marketplace"/"unknown marketplace" como outcome distinto (no-retry, etiqueta propia), y corregir el mensaje catch-all de `ensure_plugin_installed_one` para no conflacionar con "not authenticated".
- **Evidencia**: con el marketplace ausente, el install emite `Plugin "telegram" not found in marketplace "claude-plugins-official". Your local copy may be out of date`, pero el regex de auth-skip no matchea → se reintenta 3× en vano y se loguea como "not authenticated yet or install failed" (el mensaje que costó tiempo de diagnóstico real).

## Resumen de decisiones

| # | Decisión | Estado |
|---|----------|--------|
| D1 | Auth headless por `CLAUDE_CODE_OAUTH_TOKEN` en `.env` (env_file) | Verificado (READY, sin 401) |
| D2 | `marketplace add anthropics/claude-plugins-official --scope user`, idempotente | Verificado (add + install OK) |
| D3 | Pre-seed onboarding en `.claude.json`; keys exactas vía diff en implementación | Parcial — método definido |
| D4 | `has_oauth_token` + guards en `next_tmux_cmd` y `_check_auth_flip` | Diseño cerrado |
| D5 | Clasificar marketplace-not-found ≠ not-authenticated | Diseño cerrado |
