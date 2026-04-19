# Quickstart — Modo agéntico (español)

En vez de responder el wizard interactivo, clonas el repo, abres una sesión de Claude Code en el directorio clonado, y pegas un único prompt que maneja todo `./setup.sh` por ti.

## Cuándo usar este modo

- Ya estás trabajando dentro de Claude Code y no quieres salir al shell.
- Quieres reproducir el mismo agente en varios hosts con la misma configuración.
- Prefieres revisar el bloque de configuración en un solo lugar antes de ejecutar.

## Prerequisitos

- `git`, `yq`, `gh` y `claude` instalados.
- Un Personal Access Token de GitHub con scope `repo` (y `delete_repo` si vas a usar `--delete-fork` en el futuro).
- Acceso de push al owner del fork (cuenta personal u org de la que seas miembro).

## Pasos

1. Clona el repo y entra en él:
   ```bash
   git clone https://github.com/rodrigo-hinojosa-labs/agent-admin-template.git
   cd agent-admin-template
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

```
AGENT_NAME="linus"
DISPLAY_NAME="Linus 🐧"
ROLE="Admin assistant for my ecosystem"
VIBE="Direct, useful, no drama"

USER_NAME="Tu Nombre Completo"   # usado en CLAUDE.md y agent.yml
NICKNAME="Tú"                    # como el agente debe dirigirse a ti
TIMEZONE="America/Santiago"      # zona IANA — ajusta a la tuya
EMAIL="you@example.com"
LANGUAGE="es"                    # es | en | mixed

HOST=""                          # vacío = hostname -s del host actual
DESTINATION="$HOME/Claude/Agents/linus"
INSTALL_SERVICE="y"              # y | n

# Perfil de Claude: si lo dejas vacío, el wizard auto-hereda el
# $CLAUDE_CONFIG_DIR de la sesión actual. Sólo se usa si la wizard pregunta
# (cuando hay múltiples ~/.claude* y no hay $CLAUDE_CONFIG_DIR). Pon el
# número de la opción, ej "1" para la primera candidata existente.
CLAUDE_PROFILE_CHOICE=""         # vacío = auto, "1".."N" = elegir candidato

FORK_ENABLED="y"                 # y | n — si n, ignora todos los FORK_*
FORK_OWNER="your-github-user-or-org"   # usuario u organización
FORK_NAME=""                     # vacío = <agent>-agent (compartido entre hosts; las branches llevan el host)
FORK_PRIVATE="y"
TEMPLATE_URL="https://github.com/rodrigo-hinojosa-labs/agent-admin-template"
FORK_PAT=""                      # ghp_... con scope repo

HEARTBEAT_NOTIF="none"           # none | log | telegram
ATLASSIAN_ENABLED="n"
GITHUB_MCP_ENABLED="n"
GITHUB_MCP_EMAIL=""              # si ENABLED=y
GITHUB_MCP_PAT=""                # si ENABLED=y — puede reutilizar FORK_PAT

HEARTBEAT_ENABLED="n"
HEARTBEAT_INTERVAL="30m"
HEARTBEAT_PROMPT="Check status and report"
USE_DEFAULT_PRINCIPLES="y"
```

## Bloque 2 — Instrucciones (pégalo tal cual después del bloque 1)

```
Ejecuta el wizard de agent-admin-template usando los valores de arriba.

Antes de ejecutar:
1. Confirma que `yq`, `git` y `gh` están en el PATH.
2. Si FORK_ENABLED="y", exporta GH_TOKEN=$FORK_PAT y verifica `gh api user` responde con un login válido.
3. Verifica que $DESTINATION no exista ya.
4. Si algún valor obligatorio está vacío (AGENT_NAME, USER_NAME, EMAIL, o — cuando FORK_ENABLED=y — FORK_OWNER y FORK_PAT), detente y pídeme los valores faltantes antes de continuar.

Luego:
5. Construye el stdin del wizard con `printf` respetando el orden exacto de prompts:
   - Agent identity: AGENT_NAME, DISPLAY_NAME, ROLE, VIBE
   - About you: USER_NAME, NICKNAME, TIMEZONE, EMAIL, LANGUAGE
   - Deployment: HOST, DESTINATION, INSTALL_SERVICE
   - Perfil de Claude: sólo pregunta si hay múltiples ~/.claude* Y $CLAUDE_CONFIG_DIR no está seteado. Si pregunta, pasa CLAUDE_PROFILE_CHOICE (default "1" = primer perfil existente)
   - Fork: FORK_ENABLED [si y: FORK_OWNER, FORK_NAME, FORK_PRIVATE, TEMPLATE_URL, FORK_PAT]
   - Heartbeat notifications: HEARTBEAT_NOTIF
   - MCPs: ATLASSIAN_ENABLED [si y: loop atlassian], GITHUB_MCP_ENABLED [si y: email + PAT]
   - Features: HEARTBEAT_ENABLED [si y: INTERVAL, PROMPT]
   - Principles: USE_DEFAULT_PRINCIPLES
   - Action: "" (proceed)

6. Redirige ese stdin a `./setup.sh` y captura stdout+stderr.
7. Si falla cualquier paso del scaffold (fork creation, fetch, rebase), muéstrame el error completo y detente — no intentes "corregir" mutando agent.yml sin avisarme.
8. Si el scaffold termina con éxito, imprime el `NEXT_STEPS.md` que se rendereó en $DESTINATION y resume:
   - Rama live creada (p. ej. `<host>-<agent>-v1/live`)
   - URL del fork
   - Qué queda pendiente (push inicial, validar SSH/MCP, instalar plugins)

No pidas confirmación entre pasos — procede salvo que falte un valor crítico o falle una validación.
```

---

## Seguridad

⚠ El PAT queda en el contexto de la sesión de Claude. Si tu sistema de memoria (`claude-mem`, plugins similares) indexa las sesiones, **considera el token comprometido** y revócalo desde https://github.com/settings/tokens cuando termines. Genera uno nuevo para uso continuo.

## Alternativa: wizard interactivo

Si prefieres el flujo tradicional por prompts en terminal, usa `./setup.sh` y responde cada pregunta a mano — ver la sección [Quick start](../README.md#quick-start) del README.

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
