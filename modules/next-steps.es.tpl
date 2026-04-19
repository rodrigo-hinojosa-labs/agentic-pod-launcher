# {{AGENT_DISPLAY_NAME}} — siguientes pasos (modo Docker)

Tu agente está scaffoldeado como contenedor Docker en `{{DEPLOYMENT_WORKSPACE}}`.

## 1. Build y arranque

```bash
cd {{DEPLOYMENT_WORKSPACE}}
docker compose build
docker compose up -d
```

El contenedor arranca y el supervisor lanza Claude Code dentro de una sesión tmux detached. Conéctate con (NO uses `docker attach` — ese muestra los logs del supervisor; la sesión interactiva vive en tmux):

```bash
docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent
```

Para salir sin matar el contenedor: `Ctrl-b d` (atajo estándar de tmux).

## 2. Login en Claude (una sola vez)

Dentro de la sesión tmux:

1. Elige un tema (Enter acepta el default) y confirma trust en `/workspace`.
2. Corre `/login`, abre la URL en el navegador, autoriza, pega el código de vuelta. Las credenciales viven en el named volume (`{{AGENT_NAME}}-state`) y sobreviven rebuilds.
3. Escribe `/exit` (o Ctrl-D). Claude cierra; el watchdog se entera y re-evalúa qué lanzar.
4. **Espera ~2–3 segundos** para que el supervisor detecte el cierre y arranque la siguiente sesión tmux (el wizard de Telegram). Si haces re-attach demasiado rápido, verás `no sessions` — vuelve a intentarlo.

## 3. Ingresa el token del bot de Telegram

Reconéctate a la sesión tmux:

```bash
docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent
```

El supervisor ahora detecta el perfil autenticado y lanza el wizard in-container:

- `Telegram bot token (from @BotFather):` — pega tu token.
- `Add a GitHub Personal Access Token (for gh / MCP)?` — opcional.
- Por cada workspace de Atlassian declarado en `agent.yml`, pega el API token (o Enter para saltarlo).

El wizard escribe `/workspace/.env` (0600) y sale. El watchdog ve que la sesión murió, re-decide, y esta vez arranca Claude con `--channels plugin:telegram@claude-plugins-official`. El MCP server del plugin (`bun server.ts`) arranca solo y empieza a polear Telegram.

**Espera ~2–3 segundos** otra vez antes de re-attach — mismo gap que después de `/exit`.

## 4. Emparejar tu cuenta de Telegram

Re-attach una vez más:

```bash
docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent
```

Luego:

1. Mándale un DM al bot desde Telegram — te responde con un código de 6 caracteres.
2. En la sesión de Claude: `/telegram:access pair <código>` (aprueba el overwrite de `access.json`).
3. Tu chat id queda en el allowlist; el bot confirma con "you're in".
4. Manda otro DM para verificar — el mensaje llega a Claude y Claude responde.

Para salir sin matar la sesión: `Ctrl-b d`.

## Uso diario

```bash
# Reconectar a la sesión
docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent

# Rotar un secreto
$EDITOR {{DEPLOYMENT_WORKSPACE}}/.env
docker compose restart

# Actualizar a una versión nueva del template
cd {{DEPLOYMENT_WORKSPACE}}
git pull                                 # si tu workspace es un fork
docker compose build && docker compose up -d
```

## Desmantelamiento

```bash
./setup.sh --uninstall --yes             # detiene contenedor, remueve named volume + unit de host
./setup.sh --uninstall --nuke --yes      # también borra este directorio de workspace
```

## Troubleshooting

### El agente deja de responder en Telegram ("ghosting")

Síntoma: mandas mensajes por Telegram al bot de chat, el agente responde una vez tras un reinicio y luego se queda en silencio. `ps` muestra que `bun server.ts` y `claude` siguen vivos, pero los mensajes no llegan a Claude. Es un bug conocido del puente MCP del plugin `claude-plugins-official/telegram` (upstream, no de este repo).

**Recuperación:**

```bash
docker exec -u agent {{AGENT_NAME}} heartbeatctl kick-channel
```

Mata la sesión tmux `agent`; el watchdog de `start_services.sh` la respawna en ~2 segundos con el plugin re-conectado fresco. Tu siguiente mensaje debería llegar.

El watchdog también detecta automáticamente si `bun server.ts` muere (otro modo de falla distinto) y hace el respawn sin intervención. `kick-channel` es para cuando bun está vivo pero el puente se quedó colgado.

**Ejemplo de secuencia:**

```bash
# Desde tu terminal, cuando Donna no contesta:
docker exec -u agent {{AGENT_NAME}} heartbeatctl kick-channel
# heartbeatctl: killed tmux session 'agent' — watchdog will respawn in ~2s

# Mandas "hola" por Telegram. El agente responde.
```

### Otros comandos útiles (`heartbeatctl`)

```bash
docker exec -u agent {{AGENT_NAME}} heartbeatctl status   # estado + último run
docker exec -u agent {{AGENT_NAME}} heartbeatctl logs     # últimos 20 runs
docker exec -u agent {{AGENT_NAME}} heartbeatctl test     # un tick manual
docker exec -u agent {{AGENT_NAME}} heartbeatctl pause    # pausar heartbeat
docker exec -u agent {{AGENT_NAME}} heartbeatctl resume   # reanudar
docker exec -u agent {{AGENT_NAME}} heartbeatctl set-interval 5m   # cambiar intervalo
```

Referencia completa (todos los subcomandos + reglas de validación + timing de propagación): [docs/heartbeatctl.md](docs/heartbeatctl.md).

### Otros issues

Plugin no conecta en primer boot, prompts de permisos, crond silencioso, UID mismatch, etc. en [docs/getting-started.md](docs/getting-started.md).
