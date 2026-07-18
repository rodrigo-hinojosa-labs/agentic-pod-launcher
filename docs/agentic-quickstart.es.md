# Quickstart — Modo agentico (español)

En vez de responder el wizard interactivo, clonas el repo, abres una sesión de Claude Code en el directorio clonado, y pegas un único prompt que maneja todo `./setup.sh` por ti.

## Cuándo usar este modo

- Ya estás trabajando dentro de Claude Code y no quieres salir al shell.
- Quieres reproducir el mismo agente en varios hosts con la misma configuración.
- Prefieres revisar el bloque de configuración en un solo lugar antes de ejecutar.

## Atajo: el slash command `/quickstart`

Si no quieres pegar dos bloques, abre `claude` dentro del repo y tipea `/quickstart`. El comando carga este doc + `tests/helper.bash::wizard_answers()` como referencia, te pide en un solo mensaje los valores obligatorios (`AGENT_NAME`, `DISPLAY_NAME`, `ROLE`, `USER_NAME`, `EMAIL`; `DESTINATION` es opcional y cae al default `$HOME/Claude/Agents/<agent_name>`), te ofrece los opcionales (fork, heartbeat, vault, MCPs, plugins), aplica defaults sensatos al resto, y ejecuta el wizard. Es la forma más corta de scaffoldear un agente desde Claude Code.

El resto del documento sigue siendo válido: cubre los inputs en detalle (útil para auditar o para cuando quieras escribir un único bloque copy-paste sin pasar por el slash).

## Prerequisitos

Pins y versiones de esta sección: a la fecha de v0.12.0.

- `git` y `claude` instalados. `git` es el único requisito duro del host que `setup.sh` no auto-instala.
- `yq` v4+ y `gh`: opcionales. Si faltan, `setup.sh` los vendoriza automáticamente en `scripts/vendor/bin/` la primera vez — `yaml_require_yq` descarga mikefarah/yq v4+ y `ensure_gh` descarga un gh pineado en 2.62.0. Un `gh` que ya esté en el `PATH` se usa tal cual, **sin chequeo de versión**, así que asegúrate de que sea ≥ 2.40: `scaffold_with_fork` necesita `gh repo edit --accept-visibility-change-consequences`, que las versiones viejas no traen. En Debian/Ubuntu, **no instales con `apt install yq`** — ese paquete es el wrapper Python v3 (sintaxis incompatible); el launcher lo detecta y vendoriza el binario correcto igual. Para pre-instalarlo a mano: `brew install yq` (macOS) o baja el binario de [github.com/mikefarah/yq](https://github.com/mikefarah/yq#install).
- Solo si habilitas el fork (prompt 14): un Personal Access Token de GitHub con scope `repo` (más `delete_repo` si vas a usar `--delete-fork` en el futuro), y acceso de push al owner del fork (tu cuenta personal o una org de la que seas miembro).
- Solo en modo local: un host Linux con systemd, más `jq` y Claude Code ≥ 2.1.51 en el host (el helper `--login` gatea en ambos). El modo docker funciona en macOS y Linux.

## Pasos

1. Clona el repo y entra en él:
   ```bash
   git clone https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher.git
   cd agentic-pod-launcher
   ```
2. Abre Claude Code:
   ```bash
   claude
   ```
3. Rellena el bloque de configuración de abajo con tus valores.
4. Pega el bloque de configuración seguido del bloque de instrucciones en la sesión de Claude.
5. Claude valida prerequisitos, corre `./setup.sh`, y te muestra el `NEXT_STEPS.md` renderizado al terminar. Ese archivo se bifurca según el modo de deployment: la versión docker cubre `docker compose build`/`up` + login dentro del contenedor; la versión local cubre `./setup.sh --login` + unidades systemd.

---

## Orden de prompts del wizard (canónico, a la fecha de v0.12.0)

El wizard hace hasta 52 preguntas. La tabla de abajo refleja el orden canónico que la suite de tests impone (`tests/helper.bash::wizard_answers()`); los prompts condicionales declaran su disparador en "Se pregunta cuando". Los marcados "siempre" salen en toda corrida. El stdin pipeado debe responder exactamente los prompts que se disparan, en este orden — ni uno más, ni uno menos.

**El prompt de deployment mode es el PRIMERO, en todas las plataformas** (feature 011, `setup.sh:451`). Cualquier receta de stdin que empiece con el nombre del agente se desincroniza desde la línea 1: `ask_choice` repregunta hasta leer una línea que sea exactamente `docker` o `local`, así que se tragaría `AGENT_NAME`, `DISPLAY_NAME`, … hasta que alguno coincidiera por accidente.

| # | Prompt | Se pregunta cuando | Default | Significado |
|---|--------|--------------------|---------|-------------|
| 1 | Deployment mode | siempre (PRIMERO, todas las plataformas) | `docker` | Elección entre `docker` (contenedor aislado, least-privilege, recomendado) y `local` (systemd del host, solo Linux). Todo el wizard y el render se bifurcan según esta respuesta. Elegir `local` imprime una advertencia de seguridad: el agente corre como tu usuario de login, sin aislamiento de contenedor, MFA obligatoria. |
| 2 | Agent name (lowercase, no spaces) | siempre | `my-agent` | Identificador de máquina, normalizado a un label tipo DNS (lowercase, espacios a guiones). Se usa para archivos, ramas, nombres de contenedor y unidades systemd. |
| 3 | Use '<normalizado>'? | solo si la normalización cambió el input | y | Confirma el nombre normalizado; `n` vuelve a preguntar. Nunca se dispara si pipeas un nombre ya válido. |
| 4 | Display name (with emoji) | siempre | `MyAgent 🤖` | Nombre visible del agente. |
| 5 | Role description | siempre | `Admin assistant for my ecosystem` | Rol en una línea (una persona multilínea puede venir de `--role-file`). |
| 6 | Vibe / personality (one line) | siempre | `Direct, useful, no drama` | Personalidad en una línea, escrita en `agent.yml` / CLAUDE.md. |
| 7 | Your full name | siempre | ninguno — repite hasta que sea no-vacío | Nombre completo del operador; su primera palabra es el default del nickname. |
| 8 | Nickname | siempre | primera palabra del nombre completo | Cómo te trata el agente. |
| 9 | Timezone | siempre | auto-detectado (`timedatectl` / `/etc/localtime`, fallback `UTC`) | Zona horaria IANA validada; alimenta el scheduling de cron/heartbeat. |
| 10 | Primary email | siempre | ninguno — validado, obligatorio | Se reutiliza después como default de los sub-prompts de email de Atlassian / MCP GitHub. |
| 11 | Preferred language | siempre | `en` | Elección entre `es en mixed`. |
| 12 | Agent destination directory | solo si NO se pasó `--destination` | `<padre-del-installer>/agents/<agent_name>` | Ruta del workspace. La receta agéntica de abajo siempre pasa `--destination`, así que **no emitas línea de stdin para este prompt**. |
| 13 | Install as system service? | solo Linux (en macOS imprime un aviso de skip y fuerza false) | y | Unidad systemd del host. En macOS el stream lleva una respuesta menos. |
| 14 | Create a GitHub fork for this agent? | siempre | y | Habilita el fork de template-sync; `n` saltea los prompts 15-19. |
| 15 | Fork owner (user or org) | fork = y | `your-github-user-or-org` | Owner del fork del agente en GitHub. |
| 16 | Fork repo name | fork = y | `<agent>-agent` | Único por agente; el hostname vive en el nombre de la rama, no del repo. |
| 17 | Make the fork private? (recommended) | fork = y | y | Un fork de un template PÚBLICO no puede ser privado en GitHub. El wizard sondea la visibilidad del template (`fork_resolve_visibility`, `scripts/lib/fork.sh`) y, ante el conflicto público+privado, se bifurca según el modo: interactivo (TTY) → te deja elegir `proceed-public` o `disable-fork`; **no interactivo (stdin pipeado — la ruta agéntica) → DESHABILITA el fork por completo** (aviso en stderr, exit 0), salvo que exportes `FORK_ACCEPT_PUBLIC=1`, que lo crea público. El template default de este repo **es público**: en la ruta pipeada responde `n` acá, o responde `y` y exporta `FORK_ACCEPT_PUBLIC=1` — ambas producen un fork PÚBLICO. Un fork realmente privado exige que `TEMPLATE_URL` apunte a un template privado. |
| 18 | Template repo URL | fork = y | la URL de este repo en GitHub | Upstream usado para crear el fork y para `--sync-template`. |
| 19 | GitHub PAT for fork | fork = y | ninguno (secreto, sin echo) | Scope `repo` (+ `delete_repo` para `--delete-fork`). Solo para el fork; independiente del PAT del MCP GitHub. |
| 20 | Heartbeat notification channel | siempre | `none` | Elección entre `none log telegram`. Pings de estado de una vía — NO es el plugin de chat bidireccional de Telegram. |
| 21 | Heartbeat bot token (or skip) | canal = telegram | vacío = skip (rellenas `NOTIFY_BOT_TOKEN` en `.env` después) | Un input no-vacío debe pasar el chequeo de formato del token; vacío saltea por completo los prompts 22-23. |
| 22 | Auto-discover chat id by messaging the bot now? | telegram Y token no-vacío | y | `y` espera un Enter y luego consulta la API de Telegram; las corridas pipeadas deben responder `n` (ruta de pegado manual). |
| 23 | Chat ID (or skip) | telegram Y token no-vacío Y (auto-discover = n O la discovery falló) | vacío = skip (rellenas `NOTIFY_CHAT_ID` en `.env` después) | Pegado manual del chat id. |
| 24 | Install aws? | siempre (MCP opcional 1/6, orden alfabético del catálogo) | n | Sin sub-prompt de secreto. |
| 25 | Install firecrawl? | siempre (MCP opcional 2/6) | n | Si respondes `y`, sigue un sub-prompt de secreto: `FIRECRAWL_API_KEY (or skip)`. |
| 26 | Install google-calendar? | siempre (MCP opcional 3/6) | n | Si respondes `y`, sigue un sub-prompt de secreto: `GOOGLE_OAUTH_CREDENTIALS (or skip)`. |
| 27 | Install playwright? | siempre (MCP opcional 4/6) | n | Sin secreto. |
| 28 | Install time? | siempre (MCP opcional 5/6) | n | Sin secreto. |
| 29 | Install tree-sitter? | siempre (MCP opcional 6/6) | n | Sin secreto. |
| 30 | Enable Atlassian MCP? | siempre | n | `y` entra en un loop por workspace con los prompts 31-35. |
| 31 | Workspace alias | atlassian = y (por workspace) | ninguno — obligatorio | Id único; se pasa a mayúsculas para armar los nombres de variables `ATLASSIAN_<ALIAS>_*`. |
| 32 | Atlassian URL | atlassian = y (por workspace) | ninguno — validado como URL | URL base del sitio; se le agrega `/wiki` para las variables de Confluence. |
| 33 | Email (Atlassian) | atlassian = y (por workspace) | tu email primario | Usuario de Confluence/Jira para ese workspace. |
| 34 | API token (or skip) | atlassian = y (por workspace) | vacío = skip (rellenas `ATLASSIAN_<ALIAS>_TOKEN` en `.env` después) | Token de API del workspace. |
| 35 | Add another Atlassian workspace? | atlassian = y (después de cada workspace) | n | `n` cierra el loop. |
| 36 | Enable GitHub MCP? | siempre | n | `y` dispara los prompts 37-38. Independiente del token del fork. |
| 37 | GitHub account email | MCP github = y | tu email primario | Identidad para el MCP de GitHub. |
| 38 | GitHub PAT for MCP (or skip) | MCP github = y | vacío = skip (lo rellenas en `.env` después) | El PAT que el servidor MCP de GitHub usa para llamar a la API. |
| 39 | Enable heartbeat (periodic auto-execution)? | siempre | y | `n` saltea los prompts 40-41. |
| 40 | Default interval (Nm/Nh or 5-field cron) | heartbeat = y | `30m` | Intervalo/cron validado. |
| 41 | Default prompt | heartbeat = y | `Status check — return a short plain-text report (uptime, notable issues). No tool use; your stdout is forwarded verbatim to the notifier.` | El prompt que envía cada tick del heartbeat. |
| 42 | Use default opinionated agent principles? (recommended) | siempre | y | Bloque de principios que trae el template para CLAUDE.md. |
| 43 | Enable knowledge vault? | siempre | y | Vault estilo Obsidian por agente en `.state/.vault/` (patrón de tres capas de Karpathy). `n` saltea los prompts 44-46. |
| 44 | Seed initial vault structure? | vault = y | y | Scaffoldea plantillas, schema y log. |
| 45 | Register MCPVault server (@bitbonsai/mcpvault)? | vault = y | y | Registra el MCP del vault en `.mcp.json`. |
| 46 | Enable QMD hybrid search? | vault = y | n | BM25+vector+rerank; descarga un modelo de embeddings de ~300MB la primera vez. |
| 47 | Install code-simplifier? | siempre (plugin opcional 1/5, alfabético) | n | Los 5 plugins always-on (telegram, claude-mem, context7, claude-md-management, security-guidance) nunca se preguntan. |
| 48 | Install commit-commands? | siempre (plugin opcional 2/5) | n | |
| 49 | Install github? | siempre (plugin opcional 3/5) | n | Plugin de Claude Code — distinto del MCP de GitHub (prompt 36). |
| 50 | Install skill-creator? | siempre (plugin opcional 4/5) | n | |
| 51 | Install superpowers? | siempre (plugin opcional 5/5) | n | |
| 52 | Action | siempre (después de la pantalla de resumen) | `proceed` | Elección entre `proceed edit abort`; `edit` pregunta "Edit which field number?" y vuelve a mostrar el resumen. Pipea el literal `proceed`. |

Conteos a la fecha de v0.12.0: 6 MCPs opcionales de catálogo, 5 plugins opcionales — ambas listas se derivan de `modules/mcps/*.yml` / `modules/plugins/*.yml` y se ordenan alfabéticamente, así que agregar un archivo de catálogo cambia el conteo y el orden. El wizard renderiza con `gum` cuando stdin es una TTY, pero el stdin pipeado (la ruta agéntica) siempre cae al fallback de `read` plano — el orden y la semántica son idénticos.

---

## Bloque 1 — Configuración (rellena antes de pegar)

```bash
# ── Deployment mode (el wizard lo pregunta PRIMERO) ───
DEPLOYMENT_MODE="docker"               # docker | local — local = systemd del host, solo Linux, sin aislamiento

# ── Identidad del agente ─────────────────────────────
AGENT_NAME="linus"                     # lowercase, sin espacios (se normaliza igual)
DISPLAY_NAME="Linus 🐧"                 # con emoji opcional
ROLE="Admin assistant for my ecosystem"
VIBE="Direct, useful, no drama"

# ── Sobre ti ─────────────────────────────────────────
USER_NAME="Tu Nombre Completo"         # usado en CLAUDE.md y agent.yml
NICKNAME=""                            # vacío = primer nombre de USER_NAME
TIMEZONE=""                            # vacío = auto (timedatectl/readlink) → "America/Santiago"
EMAIL="you@example.com"
LANGUAGE="es"                          # es | en | mixed

# ── Deployment ───────────────────────────────────────
DESTINATION="$HOME/Claude/Agents/linus"     # debe NO existir todavía
INSTALL_SERVICE="y"                    # Linux only — en macOS el wizard salta este prompt

# ── Fork de GitHub (template sync) ───────────────────
FORK_ENABLED="y"                       # y | n — si n, ignora todos los FORK_*
FORK_OWNER="your-github-user-or-org"   # usuario u organización
FORK_NAME=""                           # vacío = <agent>-agent (compartido cross-host; las branches llevan el host)
FORK_PRIVATE="n"                       # OJO: el TEMPLATE_URL de abajo es PÚBLICO, y un fork de un repo público
                                       # NO puede ser privado. Con "y" + template público, la corrida pipeada
                                       # (no interactiva) DESHABILITA el fork entero y sigue de largo. Deja "n"
                                       # (fork público), o pon "y" y además FORK_ACCEPT_PUBLIC="1" — mismo
                                       # resultado. "y" a secas solo sirve si TEMPLATE_URL es un repo PRIVADO.
FORK_ACCEPT_PUBLIC="0"                 # 1 = acepta el fork PÚBLICO cuando pediste privado. Es una variable de
                                       # ENTORNO que se exporta a setup.sh, NO una línea de stdin.
TEMPLATE_URL="https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher"   # público
FORK_PAT=""                            # ghp_... con scope repo (NUNCA inventes este valor)

# ── Heartbeat — notificaciones ───────────────────────
NOTIFY_CHANNEL="none"                  # none | log | telegram
NOTIFY_BOT_TOKEN=""                    # sólo si NOTIFY_CHANNEL=telegram
NOTIFY_CHAT_ID=""                      # sólo si NOTIFY_CHANNEL=telegram

# ── MCPs ────────────────────────────────────────────
ATLASSIAN_ENABLED="n"                  # si y → loop de workspaces (ver formato abajo)
# Formato: cada workspace es "name|url|email|token", separados por espacio.
# Email vacío = se usa $EMAIL como default. Token vacío = se rellena en .env después.
# Ejemplo: ATLASSIAN_WORKSPACES="work|https://acme.atlassian.net|me@acme.com|atl_xxx personal|https://me.atlassian.net||"
ATLASSIAN_WORKSPACES=""

GITHUB_MCP_ENABLED="n"                 # MCP GitHub (≠ del fork; PAT distinto)
GITHUB_MCP_EMAIL=""                    # vacío = $EMAIL si ENABLED=y
GITHUB_MCP_PAT=""                      # ghp_... — puede reutilizar FORK_PAT si quieres

# ── Heartbeat — schedule + prompt ────────────────────
HEARTBEAT_ENABLED="y"                  # y = el wizard pide los siguientes; n = saltea
HEARTBEAT_INTERVAL="30m"               # Nm / Nh (5m, 30m, 2h) o cron de 5 campos ("0 9 * * *")
HEARTBEAT_PROMPT="Status check — return a short plain-text report (uptime, notable issues). No tool use; your stdout is forwarded verbatim to the notifier."

# ── Principios ───────────────────────────────────────
USE_DEFAULT_PRINCIPLES="y"             # y = pega el opinionated default; n = empezar de cero

# ── Vault de conocimiento (Karpathy LLM Wiki) ────────
VAULT_ENABLED="y"                      # vault Obsidian-style en .state/.vault/
VAULT_SEED_SKELETON="y"                # plantilla 3-layer (raw_sources/wiki/schema)
VAULT_MCP_ENABLED="y"                  # registrar MCPVault (@bitbonsai/mcpvault)
VAULT_QMD_ENABLED="n"                  # hybrid search BM25+vector — descarga ~300MB la 1ra vez

# ── Plugins opcionales (5; orden alfabético del wizard) ──
PLUGIN_CODE_SIMPLIFIER="n"
PLUGIN_COMMIT_COMMANDS="n"
PLUGIN_GITHUB="n"
PLUGIN_SKILL_CREATOR="n"
PLUGIN_SUPERPOWERS="n"
```

## Bloque 2 — Instrucciones (pégalo tal cual después del bloque 1)

```
Ejecuta el wizard de agentic-pod-launcher usando los valores de arriba.

PRE-FLIGHT — antes de tocar setup.sh:
1. Confirma que `git` está en el PATH (obligatorio, no se auto-instala). NO bloquees
   por la ausencia de `yq` o `gh` — `setup.sh` los vendoriza en `scripts/vendor/bin/`
   automáticamente (`yaml_require_yq` baja mikefarah/yq v4+ aunque el sistema tenga
   apt yq v3; `ensure_gh` baja un gh pineado en 2.62.0). Si `gh` YA está en el PATH,
   `ensure_gh` lo acepta SIN chequear versión — avísame si `gh --version` es < 2.40 y
   FORK_ENABLED="y" (el flujo de fork necesita
   `--accept-visibility-change-consequences`).
2. Si FORK_ENABLED="y" y `gh` ya está disponible, exporta GH_TOKEN=$FORK_PAT y
   verifica que `gh api user` retorne un login válido. Si `gh` no está en PATH,
   sáltate este chequeo — `ensure_gh` lo vendoriza durante el wizard y la
   verificación de auth pasa allí.
   VISIBILIDAD DEL FORK (crítico en esta ruta): como el stdin va pipeado, el
   wizard corre NO interactivo. Si FORK_PRIVATE="y" y TEMPLATE_URL es un repo
   público, `fork_resolve_visibility` (scripts/lib/fork.sh) deshabilita el fork
   entero: el scaffold termina en éxito y `git init` deja igual una rama local
   `<agent>/live`, pero NO hay fork, ni remoto, ni rama versionada empujada
   (`<host>-<agent>-vN/live`), ni backup a fork. Antes de ejecutar: si FORK_PRIVATE="y" y el template es
   público (chequéalo con `gh api repos/<owner>/<repo> --jq .visibility`) y
   FORK_ACCEPT_PUBLIC no es "1", detente y pídeme que elija entre fork público
   (FORK_PRIVATE="n" o FORK_ACCEPT_PUBLIC="1") o un TEMPLATE_URL privado.
3. Verifica que $DESTINATION no exista (`[ ! -e $DESTINATION ]`). Si existe, detente.
4. Verifica que DEPLOYMENT_MODE sea exactamente "docker" o "local". Si es "local"
   y `uname -s` no es Linux, detente — el modo local es solo Linux/systemd.
5. Si algún valor obligatorio está vacío detente y pídeme los faltantes:
   - AGENT_NAME, USER_NAME, EMAIL — siempre requeridos
   - FORK_OWNER, FORK_PAT — sólo si FORK_ENABLED="y"
   - NOTIFY_BOT_TOKEN, NOTIFY_CHAT_ID — sólo si NOTIFY_CHANNEL="telegram"
   - GITHUB_MCP_PAT — sólo si GITHUB_MCP_ENABLED="y"

REGLA — NUNCA inventes secretos (PATs, bot tokens, chat IDs, API tokens
de Atlassian). Si falta alguno y la feature lo requiere, ofréceme dos opciones:
(a) lo proveo y reintentamos, (b) desactivamos esa feature (ej. set
NOTIFY_CHANNEL=none) y la configuramos después con heartbeatctl o re-run del
wizard.

CONSTRUCCIÓN DEL STDIN — usa `printf` y respeta este orden EXACTO (espejo de
`tests/helper.bash::wizard_answers()`, que es la fuente canónica; si este doc y
esa función discrepan, LEE LA FUNCIÓN Y SÍGUELA — tests/quickstart-doc.bats solo
cuida parte de la sincronía: los marcadores de bloque de wizard_answers(), la
cobertura de MCPs de catálogo y la paridad de tokens ES/EN — no el orden línea
a línea):

  0. Deployment mode (1 línea):     DEPLOYMENT_MODE   ← se pregunta PRIMERO en
                                    todas las plataformas (feature 011). Literal
                                    "docker" o "local"; cualquier otro valor
                                    re-promptea y desincroniza todo lo siguiente.
  1. Identity (4 líneas):           AGENT_NAME, DISPLAY_NAME, ROLE, VIBE
                                    (un AGENT_NAME ya válido nunca dispara el
                                    confirm "Use '<normalizado>'?" — NO emitas
                                    línea para eso)
  2. About you (5 líneas):          USER_NAME, NICKNAME (vacío→primer nombre),
                                    TIMEZONE (vacío→auto), EMAIL, LANGUAGE
  3. install_service (Linux only):  INSTALL_SERVICE   ← saltear si `uname -s` ≠ Linux
  4. Fork (1 + 5 sub si y):         FORK_ENABLED [si y: FORK_OWNER, FORK_NAME
                                    (vacío→<agent>-agent), FORK_PRIVATE,
                                    TEMPLATE_URL, FORK_PAT]
  5. Heartbeat notif (1 + sub):     NOTIFY_CHANNEL [si telegram: NOTIFY_BOT_TOKEN
                                    + auto-discover prompt = "n" + NOTIFY_CHAT_ID;
                                    un token VACÍO saltea ambos follow-ups]
  6. MCPs catálogo (6 opc, alfa):   MCPS_AWS_ENABLED, MCPS_FIRECRAWL_ENABLED,
                                    MCPS_GOOGLE_CALENDAR_ENABLED, MCPS_PLAYWRIGHT_ENABLED,
                                    MCPS_TIME_ENABLED, MCPS_TREE_SITTER_ENABLED
                                    [un "y" agrega como máximo UNA línea de secreto:
                                    firecrawl → FIRECRAWL_API_KEY,
                                    google-calendar → GOOGLE_OAUTH_CREDENTIALS;
                                    los otros cuatro no tienen; vacío = rellenar .env después]
  7. MCP Atlassian (1 + loop si y): ATLASSIAN_ENABLED [si y: por cada workspace
                                    name|url|email|token + "n" para terminar loop]
  8. MCP GitHub (1 + sub si y):     GITHUB_MCP_ENABLED [si y: GITHUB_MCP_EMAIL,
                                    GITHUB_MCP_PAT]
  9. Heartbeat schedule (1 + sub):  HEARTBEAT_ENABLED [si y: HEARTBEAT_INTERVAL,
                                    HEARTBEAT_PROMPT]
 10. Principles (1):                USE_DEFAULT_PRINCIPLES
 11. Vault (1 + 3 sub si y):        VAULT_ENABLED [si y: VAULT_SEED_SKELETON,
                                    VAULT_MCP_ENABLED, VAULT_QMD_ENABLED]
 12. Optional plugins (5, alfa):    PLUGIN_CODE_SIMPLIFIER, PLUGIN_COMMIT_COMMANDS,
                                    PLUGIN_GITHUB, PLUGIN_SKILL_CREATOR,
                                    PLUGIN_SUPERPOWERS
 13. Review action (1):             "proceed"   ← literal, sin comillas en el printf

EJECUCIÓN:
14. Pipea ese stdin a `./setup.sh --destination $DESTINATION` y captura
    stdout+stderr. Si FORK_ACCEPT_PUBLIC="1", expórtala al entorno de setup.sh
    (`FORK_ACCEPT_PUBLIC=1 ./setup.sh …`) — es env var, NO línea de stdin. Como
    pasas --destination, el wizard nunca pregunta por el directorio — NO emitas
    línea para ese prompt. NO uses --non-interactive (eso requiere un agent.yml
    pre-existente — flujo distinto).
15. Si CUALQUIER paso del scaffold falla (clone, fork creation, fetch, rebase,
    render de plantillas), muéstrame el error completo y detente. NO intentes
    "corregir" mutando agent.yml a mano sin avisarme.
16. Si el scaffold termina con éxito:
    - Si stderr trae "disabling the fork to avoid exposing data", el scaffold
      quedó SIN fork (conflicto público/privado resuelto en contra). Dímelo
      explícito: hay rama local `<agent>/live`, pero NO reportes URL de fork ni
      rama versionada empujada — no existen.
    - Imprime el `NEXT_STEPS.md` que se rendereó en $DESTINATION.
    - Resume según el modo de deployment:
      · modo docker: rama live creada, URL del fork (si aplica), comandos
        pendientes — `docker compose build`, `./scripts/agentctl up`, `/login`
        dentro de tmux (conéctate con `./scripts/agentctl attach`), pairing de
        Telegram, validar MCPs.
      · modo local: rama live creada, URL del fork (si aplica), comandos
        pendientes — `./setup.sh --login` (OAuth único en el host + instala las
        unidades systemd que quedaron staged), y luego verificar con
        `systemctl status agent-<name>.service` y `./scripts/agentctl status`.

No pidas confirmación entre pasos pre-flight y construcción de stdin —
procede salvo que falte un valor crítico o falle una validación.
```

---

## Tabla de campos — required vs default vs nunca-inventar

| Categoría | Campos | Notas |
|---|---|---|
| **Required** (el wizard rechaza vacío) | `USER_NAME`, `EMAIL` | `USER_NAME` repite hasta que sea no-vacío; `EMAIL` se valida y no tiene default. |
| **Required en la práctica** (default genérico que casi nunca quieres) | `AGENT_NAME` (cae a `my-agent`), `DESTINATION` (cae a `<padre-del-installer>/agents/<name>`) | El vacío se *acepta* — como el default. Trátalos como obligatorios para no scaffoldear `my-agent` por accidente: el agente que pipea impone el no-vacío, no el wizard. |
| **Required condicional** | `FORK_OWNER` + `FORK_PAT` (si fork=y), `NOTIFY_BOT_TOKEN` + `NOTIFY_CHAT_ID` (si telegram), `GITHUB_MCP_PAT` (si MCP GitHub) | Sólo cuando habilitas la feature. |
| **Default seguro** | `DEPLOYMENT_MODE` (`docker`), `VIBE`, `NICKNAME` (auto del primer nombre), `TIMEZONE` (auto), `LANGUAGE` (`en`), `INSTALL_SERVICE` (Linux=`y`), `FORK_NAME` (`<agent>-agent`), `NOTIFY_CHANNEL` (`none`), `HEARTBEAT_*` (30m, prompt default), `USE_DEFAULT_PRINCIPLES` (`y`), `VAULT_*` (todos `y` excepto QMD=`n`) | Acepta el default si no tienes preferencia explícita. |
| **Default que NO es seguro en la ruta pipeada** | `FORK_PRIVATE` (default del wizard: `y`) | Contra el template público del repo, `y` sin `FORK_ACCEPT_PUBLIC=1` deshabilita el fork en toda corrida no interactiva. Ver prompt 17. |
| **NUNCA inventar** | `FORK_PAT`, `NOTIFY_BOT_TOKEN`, `NOTIFY_CHAT_ID`, `GITHUB_MCP_PAT`, `FIRECRAWL_API_KEY`, `GOOGLE_OAUTH_CREDENTIALS`, todos los tokens `ATLASSIAN_*` | Secretos del usuario. Si faltan y la feature los requiere, desactiva la feature o detente y pídelos. |

---

## Validaciones aplicadas por el wizard

El wizard (manual y agéntico) valida los inputs antes de aceptarlos. Si el slash command pipea un valor inválido, el wizard hace re-prompt y queda colgado esperando entrada que nunca llega — por eso el slash command **debe validar antes de pipear**:

| Campo | Regla | Ejemplo válido | Ejemplo inválido |
|---|---|---|---|
| `DEPLOYMENT_MODE` | Literalmente `docker` o `local` (prompt de elección: cualquier otro valor re-promptea y desincroniza el pipe) | `docker`, `local` | `Docker`, `container`, `k8s` |
| `AGENT_NAME` | DNS label: lowercase + dígitos + guiones, sin guiones al inicio/fin, sin doble guion, 1..63 chars | `my-agent`, `agent01` | `My_Agent`, `-agent`, `agent--01` |
| `EMAIL` (cualquiera) | Match `user@host.tld` (RFC 5322 simplificado) | `alice@example.com` | `alice@example`, `not-an-email` |
| `TIMEZONE` | Debe existir en `/usr/share/zoneinfo/` o cumplir patrón `Region/City` | `America/Santiago`, `UTC` | `Chile time`, `hace 2 horas` |
| `HEARTBEAT_INTERVAL` | `Nm` / `Nh` o expresión cron de 5 campos | `30m`, `2h`, `0 * * * *` | `1d`, `30 minutes`, `every hour` |
| `NOTIFY_BOT_TOKEN` (si no vacío) | `<dígitos>:<base64-like 25+>` | `123456789:AAEhBP0...` | `mi-token`, `123:short` |
| `*_URL` (Atlassian, fork) | http(s) only, sin whitespace | `https://acme.atlassian.net` | `acme.atlassian.net`, `ftp://...` |
| Alias de workspace Atlassian | Solo letras, dígitos, guion bajo (se interpola en `ATLASSIAN_<ALIAS>_TOKEN`; un guion produce un nombre de variable systemd inválido) | `work`, `cenco_corp` | `cenco-corp`, `mi equipo` |
| `UID`/`GID` | Entero no-negativo (auto-detectado, no se pregunta) | `1000`, `501` | `-1`, `abc` |

El mismo comportamiento de re-prompt aplica a todos los prompts de elección: `LANGUAGE` (`es`/`en`/`mixed`), `NOTIFY_CHANNEL` (`none`/`log`/`telegram`) y la acción final (`proceed`/`edit`/`abort`).

Si el slash command no puede validar localmente (e.g. el token es opaco), pipea el valor crudo y deja al wizard hacer el rechazo. Si el wizard re-prompt'ea, el stdin pipeado se desincroniza — captura ese caso reportando "wizard rechazó X — re-ejecuta el quickstart con un valor válido".

---

## Después del scaffold: primer arranque, por modo

El scaffold deja un workspace en `$DESTINATION` con un `NEXT_STEPS.md` específico del modo. Resumen de ambas rutas (el archivo renderizado es la versión autoritativa por agente):

### Modo docker (default)

Build y arranque:

```bash
cd "$DESTINATION"
docker compose build
./scripts/agentctl up          # == docker compose up -d
```

Autenticación, una sola vez. `NEXT_STEPS.md` ofrece dos rutas, y el **token headless es la recomendada** — en macOS la credencial del `/login` interactivo no persiste entre arranques (incoherencia de caché de VirtioFS en el bind-mount de `~/.claude`), así que Claude vuelve a "Not logged in" en cada boot:

```bash
claude setup-token                      # en el HOST; autoriza y pega el código en la terminal
$EDITOR "$DESTINATION/.env"             # define CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-…
./scripts/agentctl up                   # arranca ya autenticado — sin /login
```

Fallback (`/login` interactivo, dentro de la sesión tmux del contenedor):

```bash
./scripts/agentctl attach      # wrapper con retry-loop sobre docker exec -u agent … tmux attach
```

Elige tema, confirma trust en `/workspace`, corre `/login`, autoriza en el navegador, pega el código de vuelta y `/exit`. Las credenciales quedan en `$DESTINATION/.state/` (bind-mounted al `/home/agent` del contenedor) y sobreviven rebuilds. El watchdog respawnea la sesión; vuelve a conectarte con el mismo comando. Para desconectarte sin matar el contenedor: `Ctrl-b d`.

Operación diaria:

```bash
./scripts/agentctl status      # dashboard del heartbeat
./scripts/agentctl logs -f     # tail de claude.log
./scripts/agentctl doctor      # diagnóstico completo (exit 0 limpio / 1 warnings / 2 fallas)
```

### Modo local (Linux/systemd)

Sin contenedor y sin `docker compose`. El scaffold renderizó los helpers de `scripts/local/` (login, bootstrap, healthcheck, kill-switch, más los entrypoints de qmd/vault/wiki-graph cuando esas features están encendidas) y, o bien instaló las unidades systemd — si el `sudo -n` sin password funcionó en tiempo de scaffold — o las dejó staged en el workspace para después. Un solo paso manual hace el resto:

```bash
cd "$DESTINATION"
./setup.sh --login
```

`--login` se niega a correr en un workspace de modo docker (lee `deployment.mode` desde `agent.yml`) y es idempotente — re-ejecutarlo es seguro. En orden, `scripts/local/agent-login.sh`:

1. Gatea en Claude Code ≥ 2.1.51 y `jq` en el host (Remote Control necesita ambos) y pre-siembra los flags de onboarding.
2. Corre el **login OAuth full-scope** guiado, por única vez — abre Claude Code, tú corres `/login`, completas el flujo en el navegador y sales con `/exit`. Se saltea si `.state/.claude/.credentials.json` ya existe. El token inference-only de `claude setup-token` NO sirve acá (Remote Control lo rechaza), por eso este paso es interactivo. Host headless: tuneliza antes el puerto del callback OAuth por SSH.
3. Re-aplica el trust del workspace y pre-acepta el prompt "Enable Remote Control?" (el login resetea ambos; sin eso la unidad se cuelga en un prompt sin TTY).
4. Provisiona los runtimes de los MCPs en `~/.local/bin` vía `scripts/local/agent-bootstrap.sh` — uv/uvx, bun, github-mcp-server, con pins de versión espejados de los ARGs del Dockerfile de la imagen docker.
5. **Instala y habilita las unidades — este es el paso que pide `sudo`** (son unidades de sistema bajo `/etc/systemd/system`): `agent-<agent_name>.service`, el timer de healthcheck (~5 min) y, cuando la feature correspondiente está activa, el timer de reindex de qmd + el servicio watcher `qmd-watch`, el timer de backup del vault y el timer del wiki-graph. Después dispara en background el primer build del índice QMD y el derive del wiki-graph.

Verificación (en el host):

```bash
systemctl is-active agent-<agent_name>.service        # esperado: active
journalctl -u agent-<agent_name>.service -f           # busca la señal session-url / connected
systemctl list-timers 'agent-<agent_name>-*'          # healthcheck + timers de qmd/vault/wiki-graph
systemctl is-active agent-<agent_name>-qmd-watch.service   # el watcher del vault es servicio, no timer
./scripts/agentctl status                             # estado de la unidad + señal de conexión + login + frescura del RAG
./scripts/agentctl doctor                             # diagnóstico local (exit 0 limpio / 1 warnings / 2 fallas)
```

Al agente lo manejas desde claude.ai/code y la app móvil — "active" no es lo mismo que "controlable", y por eso tanto `status` como `doctor` buscan una señal de conexión reciente en el journal. Los subcomandos de `agentctl` que son docker-only (`up`, `start`, `stop`, `restart`, `ps`, `attach`, `shell`, `run`, `logs`, `mcp`) se niegan a correr en modo local: salen con exit 2 y una pista de `systemctl`/`journalctl` en vez de tocar Docker. `status` y `doctor` funcionan en ambos modos (en local leen systemd en vez del contenedor); `heartbeat` degrada a las tres acciones de mantención que tienen equivalente local — `heartbeat qmd-reindex`, `heartbeat backup-vault`, `heartbeat wiki-graph` — y sale con 2 en cualquier otra. Parada de emergencia: `./scripts/local/agent-killswitch.sh`.

---

## Seguridad

⚠ El PAT queda en el contexto de la sesión de Claude. Si tu sistema de memoria (`claude-mem`, plugins similares) indexa las sesiones, **considera el token comprometido** y revócalo desde https://github.com/settings/tokens cuando termines. Genera uno nuevo para uso continuo.

El modo local suma su propia superficie de riesgo: el agente corre como **tu usuario de login**, sin aislamiento de contenedor, así que quien controle la cuenta de claude.ai controla el host. El wizard imprime esta advertencia cuando eliges `local`; el MFA en la cuenta es obligatorio.

## Alternativa: wizard interactivo

Si prefieres el flujo tradicional por prompts en terminal, usa `./setup.sh` y responde cada pregunta a mano — ver la sección [Quickstart](../README.md#quickstart) del README.

---

## Telegram (chat bidireccional)

Cuando el agente ya está arriba, si quieres hablarle desde el móvil: configura el canal oficial del plugin `telegram@claude-plugins-official` (uno de los 5 plugins always-on — el wizard nunca pregunta por él). Permite DMs al agente desde Telegram con control de acceso por pairing + allowlist.

Complementa al heartbeat: heartbeat = el agente te busca; Telegram = tú buscas al agente.

**Modo docker: el flujo scaffoldeado ya hace casi todo esto por ti.** El `NEXT_STEPS.md` renderizado (pasos 3-4) lo cubre: después de autenticarte, el supervisor lanza un wizard dentro del contenedor que pide el token de BotFather, escribe `/workspace/.env` (0600), y el watchdog relanza Claude con `--channels plugin:telegram@claude-plugins-official`. Tú solo haces el pairing. La receta manual de abajo es para configurar el canal a mano — que es la ruta del modo local, y el fallback si el wizard in-container no corrió.

### Requisitos

- `bun` en el sistema (el servidor MCP del plugin está en TypeScript y arranca con `bun run`). **Sin `bun`, el server muere silenciosamente al spawnearse y las tools `telegram__*` nunca aparecen.**
  - Modo docker: ya viene horneado en la imagen (bun 1.3.14, pineado en `docker/Dockerfile`) — no hay nada que hacer.
  - Modo local: `./setup.sh --login` instala ese mismo bun pineado en `~/.local/bin` vía `scripts/local/agent-bootstrap.sh`. Para instalarlo a mano: `curl -fsSL https://bun.sh/install | bash`.
- Plugin habilitado en el `settings.json` del agente (docker: `/home/agent/.claude`; local: `<workspace>/.state/.claude`):
  ```json
  "enabledPlugins": { "telegram@claude-plugins-official": true }
  ```

### Pasos

1. **Crear bot** → habla con [@BotFather](https://t.me/BotFather) → `/newbot` → copia el token (`123456789:AAH...`).
2. **Guardar token** → en la sesión de Claude: `/telegram:configure <token>`. Queda en `~/.claude/channels/telegram/.env` con permisos 600.
3. **Reiniciar Claude Code completo.** No basta `/reload-plugins` si `bun` se instaló en la misma sesión — el PATH del proceso padre no se refresca.
4. **Pairing** → mándale un DM al bot desde Telegram. El bot responde con un código. Apruébalo con `/telegram:access pair <código>`.
5. **Lockdown** → `/telegram:access policy allowlist` para cerrar el canal solo a los IDs ya capturados. Pairing es transitorio, **no es política final**: si lo dejas así, cualquier chat que hable con el bot pasa.

### Gotchas

- **Orden de instalación de `bun`**: si lo instalas DESPUÉS de arrancar Claude Code, el proceso en memoria no ve el binario en PATH. Reinicio completo (no reload), siempre.
- **Pairing abierto**: mientras esté en modo pairing, el canal acepta nuevos IDs. Cierra con `allowlist` apenas tengas tu(s) chat_id aprobado(s).
- **Dos cosas distintas**: este plugin es para chat bidireccional. Si además quieres que el heartbeat te notifique por Telegram, eso es el driver `telegram` del heartbeat (se configura en el wizard, bot separado).
