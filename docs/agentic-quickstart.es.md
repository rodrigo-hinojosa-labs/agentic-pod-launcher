# Quickstart — Modo agentico (español)

En vez de responder el wizard interactivo, clonas el repo, abres una sesión de Claude Code en el directorio clonado, y pegas un único prompt que maneja todo `./setup.sh` por ti.

## Cuándo usar este modo

- Ya estás trabajando dentro de Claude Code y no quieres salir al shell.
- Quieres reproducir el mismo agente en varios hosts con la misma configuración.
- Prefieres revisar el bloque de configuración en un solo lugar antes de ejecutar.

## Atajo: el slash command `/quickstart`

Si no quieres pegar dos bloques, abre `claude` dentro del repo y tipea `/quickstart`. El comando carga este doc + `tests/helper.bash::wizard_answers()` como referencia, te pide los valores mínimos en un solo mensaje (`AGENT_NAME`, `USER_NAME`, `EMAIL`, `DESTINATION`, opcionalmente `FORK_*` y `VAULT_*`), aplica defaults sensatos al resto, y ejecuta el wizard. Es la forma más corta de scaffoldear un agente desde Claude Code.

El resto del documento sigue siendo válido: cubre los inputs en detalle (útil para auditar o para cuando quieras escribir un único bloque copy-paste sin pasar por el slash).

## Prerequisitos

- `git`, `yq` v4+, `gh` y `claude` instalados.
- Un Personal Access Token de GitHub con scope `repo` (y `delete_repo` si vas a usar `--delete-fork` en el futuro).
- Acceso de push al owner del fork (cuenta personal u org de la que seas miembro).

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
5. Claude valida prerequisitos, corre `./setup.sh`, y te muestra el `NEXT_STEPS.md` al terminar.

---

## Bloque 1 — Configuración (rellena antes de pegar)

```bash
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
FORK_PRIVATE="y"
TEMPLATE_URL="https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher"
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
HEARTBEAT_INTERVAL="30m"               # 5m, 30m, 1h, 6h, 1d, etc.
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
1. Confirma que `yq` (v4+), `git` y `gh` están en el PATH.
2. Si FORK_ENABLED="y", exporta GH_TOKEN=$FORK_PAT y verifica que `gh api user`
   retorne un login válido. Si falla, detente y muéstrame el error.
3. Verifica que $DESTINATION no exista (`[ ! -e $DESTINATION ]`). Si existe, detente.
4. Si algún valor obligatorio está vacío detente y pídeme los faltantes:
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
`tests/helper.bash::wizard_answers()`, que es la fuente canonical y se mantiene
con cada PR):

  1. Identity (4 líneas):           AGENT_NAME, DISPLAY_NAME, ROLE, VIBE
  2. About you (5 líneas):          USER_NAME, NICKNAME (vacío→primer nombre),
                                    TIMEZONE (vacío→auto), EMAIL, LANGUAGE
  3. install_service (Linux only):  INSTALL_SERVICE   ← saltear si `uname -s` ≠ Linux
  4. Fork (1 + sub si y):           FORK_ENABLED [si y: FORK_OWNER, FORK_NAME
                                    (vacío→<agent>-agent), FORK_PRIVATE,
                                    TEMPLATE_URL, FORK_PAT]
  5. Heartbeat notif (1 + sub):     NOTIFY_CHANNEL [si telegram: NOTIFY_BOT_TOKEN
                                    + auto-discover prompt = "n" + NOTIFY_CHAT_ID]
  6. MCP Atlassian (1 + loop si y): ATLASSIAN_ENABLED [si y: por cada workspace
                                    name|url|email|token + "n" para terminar loop]
  7. MCP GitHub (1 + sub si y):     GITHUB_MCP_ENABLED [si y: GITHUB_MCP_EMAIL,
                                    GITHUB_MCP_PAT]
  8. Heartbeat schedule (1 + sub):  HEARTBEAT_ENABLED [si y: HEARTBEAT_INTERVAL,
                                    HEARTBEAT_PROMPT]
  9. Principles (1):                USE_DEFAULT_PRINCIPLES
 10. Vault (1 + 3 sub si y):        VAULT_ENABLED [si y: VAULT_SEED_SKELETON,
                                    VAULT_MCP_ENABLED, VAULT_QMD_ENABLED]
 11. Optional plugins (5, alfa):    PLUGIN_CODE_SIMPLIFIER, PLUGIN_COMMIT_COMMANDS,
                                    PLUGIN_GITHUB, PLUGIN_SKILL_CREATOR,
                                    PLUGIN_SUPERPOWERS
 12. Review action (1):             "proceed"   ← literal, sin comillas en el printf

EJECUCIÓN:
13. Pipea ese stdin a `./setup.sh --destination $DESTINATION` y captura
    stdout+stderr. NO uses --non-interactive (eso requiere un agent.yml
    pre-existente — flujo distinto).
14. Si CUALQUIER paso del scaffold falla (clone, fork creation, fetch, rebase,
    docker-compose render), muéstrame el error completo y detente. NO intentes
    "corregir" mutando agent.yml a mano sin avisarme.
15. Si el scaffold termina con éxito:
    - Imprime el `NEXT_STEPS.md` que se rendereó en $DESTINATION.
    - Resumen: rama live creada, URL del fork (si aplica), comandos pendientes
      (push inicial, /login, pairing de Telegram, validar MCPs).

No pidas confirmación entre pasos pre-flight y construcción de stdin —
procede salvo que falte un valor crítico o falle una validación.
```

---

## Tabla de campos — required vs default vs nunca-inventar

| Categoría | Campos | Notas |
|---|---|---|
| **Required** (sin default seguro) | `AGENT_NAME`, `USER_NAME`, `EMAIL`, `DESTINATION` | El wizard rechaza vacío en estos. |
| **Required condicional** | `FORK_OWNER` + `FORK_PAT` (si fork=y), `NOTIFY_BOT_TOKEN` + `NOTIFY_CHAT_ID` (si telegram), `GITHUB_MCP_PAT` (si MCP GitHub) | Sólo cuando habilitas la feature. |
| **Default seguro** | `VIBE`, `NICKNAME` (auto del primer nombre), `TIMEZONE` (auto), `LANGUAGE` (`en`), `INSTALL_SERVICE` (Linux=`y`), `FORK_NAME` (`<agent>-agent`), `FORK_PRIVATE` (`y`), `NOTIFY_CHANNEL` (`none`), `HEARTBEAT_*` (30m, default prompt), `USE_DEFAULT_PRINCIPLES` (`y`), `VAULT_*` (todos `y` excepto QMD=`n`) | Acepta el default si no tienes preferencia explícita. |
| **NUNCA inventar** | `FORK_PAT`, `NOTIFY_BOT_TOKEN`, `NOTIFY_CHAT_ID`, `GITHUB_MCP_PAT`, todos los `ATLASSIAN_*` tokens | Secretos del usuario. Si faltan y la feature los requiere, desactiva la feature o detente y pídelos. |

---

## Seguridad

⚠ El PAT queda en el contexto de la sesión de Claude. Si tu sistema de memoria (`claude-mem`, plugins similares) indexa las sesiones, **considera el token comprometido** y revócalo desde https://github.com/settings/tokens cuando termines. Genera uno nuevo para uso continuo.

## Alternativa: wizard interactivo

Si prefieres el flujo tradicional por prompts en terminal, usa `./setup.sh` y responde cada pregunta a mano — ver la sección [Quickstart](../README.md#quickstart) del README.

---

## Telegram (chat bidireccional)

Después de que el agente esté arrancando, si quieres hablarle desde el móvil: configura el canal oficial del plugin `telegram@claude-plugins-official`. Permite DMs al agente desde Telegram con control de acceso por pairing + allowlist.

Complementa al heartbeat: heartbeat = el agente te busca; Telegram = tú buscas al agente.

### Requisitos

- `bun` instalado en el sistema (el servidor MCP del plugin está en TypeScript y arranca con `bun run`). **Sin `bun`, el server muere silenciosamente al spawnearse y las tools `telegram__*` nunca aparecen.**
  ```bash
  curl -fsSL https://bun.sh/install | bash
  ```
- Plugin habilitado en `~/.claude/settings.json`:
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
