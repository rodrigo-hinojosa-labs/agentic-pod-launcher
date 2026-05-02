# {{AGENT_DISPLAY_NAME}} — siguientes pasos (modo Docker)

Tu agente está scaffoldeado como contenedor Docker en `{{DEPLOYMENT_WORKSPACE}}`.

## 1. Build y arranque

```bash
cd {{DEPLOYMENT_WORKSPACE}}
docker compose build
./scripts/agentctl up                    # docker compose up -d
```

El contenedor arranca y el supervisor lanza Claude Code dentro de una sesión tmux detached. Conéctate con `agentctl attach` — el wrapper hace retry-loop interno (15s máx) hasta que el supervisor termine de respawnear la sesión:

```bash
./scripts/agentctl attach
```

> **Nota**: `agentctl` es un wrapper host-side de `docker exec -u agent {{AGENT_NAME}} ...`. Resuelve el nombre del container desde `agent.yml` (cwd) o de la flag `-a NAME`. Subcomandos: `attach`, `logs [-f]`, `status`, `heartbeat <sub>`, `mcp [list]`, `shell [--root]`, `up`, `stop`, `restart`, `ps`, `run <cmd…>`. Equivalente raw (si prefieres tipearlo): `docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent`.

Para salir sin matar el contenedor: `Ctrl-b d` (atajo estándar de tmux).

## 2. Login en Claude (una sola vez)

Dentro de la sesión tmux:

1. Elige un tema (Enter acepta el default) y confirma trust en `/workspace`.
2. Corre `/login`, abre la URL en el navegador, autoriza, pega el código de vuelta. Las credenciales viven en `{{DEPLOYMENT_WORKSPACE}}/.state/` (bind-mounted al `/home/agent` del contenedor) y sobreviven rebuilds.
3. Escribe `/exit` (o Ctrl-D). Claude cierra; el watchdog se entera y re-evalúa qué lanzar.
4. Re-conecta con `./scripts/agentctl attach` — el retry-loop interno espera al supervisor.

## 3. Ingresa el token del bot de Telegram

Reconéctate a la sesión tmux:

```bash
./scripts/agentctl attach
```

El supervisor ahora detecta el perfil autenticado y lanza el wizard in-container:

- `Telegram bot token (from @BotFather):` — pega tu token.
- `Add a GitHub Personal Access Token (for gh / MCP)?` — opcional.
- Por cada workspace de Atlassian declarado en `agent.yml`, pega el API token (o Enter para saltarlo).

El wizard escribe `/workspace/.env` (0600) y sale. El watchdog ve que la sesión murió, re-decide, y esta vez arranca Claude con `--channels plugin:telegram@claude-plugins-official`. El MCP server del plugin (`bun server.ts`) arranca solo y empieza a polear Telegram.

## 4. Emparejar tu cuenta de Telegram

Re-attach una vez más:

```bash
./scripts/agentctl attach
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
./scripts/agentctl attach

# Ver estado del heartbeat
./scripts/agentctl status

# Tail del log de Claude
./scripts/agentctl logs -f

# Rotar un secreto
$EDITOR {{DEPLOYMENT_WORKSPACE}}/.env
./scripts/agentctl restart

# Actualizar a una versión nueva del template
cd {{DEPLOYMENT_WORKSPACE}}
git pull                                 # si tu workspace es un fork
docker compose build && ./scripts/agentctl restart
```

{{PLUGINS_BLOCK}}

## Desmantelamiento

```bash
./setup.sh --uninstall --yes             # detiene contenedor, remueve unit de host (estado en .state/ se preserva)
./setup.sh --uninstall --purge --yes     # también borra agent.yml/.env/.state/
./setup.sh --uninstall --nuke --yes      # también borra este directorio de workspace entero
```

## Troubleshooting

### Si algo no anda: corré `agentctl doctor` primero

Antes de cualquier otra cosa:

```bash
./scripts/agentctl doctor
```

Hace 12 chequeos en orden de dependencia (Docker daemon → container → health → agent.yml → tmux → crond → plugin Telegram → heartbeat → vault → patches) y reporta `✓` / `⚠` / `✗` por cada uno con sugerencia accionable cuando algo falla. Es la forma más rápida de saber qué subsistema está roto sin ejecutar 8 comandos distintos.

### El agente deja de responder en Telegram ("ghosting")

Síntoma: mandas mensajes por Telegram al bot de chat, el agente responde una vez tras un reinicio y luego se queda en silencio. `ps` muestra que `bun server.ts` y `claude` siguen vivos, pero los mensajes no llegan a Claude. Es un bug conocido del puente MCP del plugin `claude-plugins-official/telegram` (upstream, no de este repo).

**Recuperación:**

```bash
./scripts/agentctl heartbeat kick-channel
```

Mata la sesión tmux `agent`; el watchdog de `start_services.sh` la respawna en ~2 segundos con el plugin re-conectado fresco. Tu siguiente mensaje debería llegar.

El watchdog también detecta automáticamente si `bun server.ts` muere (otro modo de falla distinto) y hace el respawn sin intervención. `kick-channel` es para cuando bun está vivo pero el puente se quedó colgado.

**Ejemplo de secuencia:**

```bash
# Desde tu terminal, cuando el agente no contesta:
./scripts/agentctl heartbeat kick-channel
# heartbeatctl: killed tmux session 'agent' — watchdog will respawn in ~2s

# Mandas "hola" por Telegram. El agente responde.
```

### Otros comandos útiles (`heartbeatctl`)

```bash
./scripts/agentctl status                        # estado + último run
./scripts/agentctl heartbeat logs                # últimos 20 runs
./scripts/agentctl heartbeat test                # un tick manual
./scripts/agentctl heartbeat pause               # pausar heartbeat
./scripts/agentctl heartbeat resume              # reanudar
./scripts/agentctl heartbeat set-interval 5m     # cambiar intervalo
```

Referencia completa (todos los subcomandos + reglas de validación + timing de propagación): [docs/heartbeatctl.md](docs/heartbeatctl.md).

### Otros issues comunes

#### `docker exec ... tmux attach -t agent` dice "no sessions"

Dos causas distintas, ambas resueltas usando `agentctl attach` en lugar del comando raw:

1. **Falta `-u agent`**: `docker exec` por defecto entra como root, y tmux guarda el socket por UID en `/tmp/tmux-<uid>/`. La sesión vive en el UID de `agent` (501 por default), así que root mira `/tmp/tmux-0/` y reporta vacío. `agentctl attach` siempre pasa `-u agent`. Equivalente raw: `docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent`.

2. **Timing del watchdog**: el supervisor poll cada 2s y respawnea la sesión tmux después de `/login`, `/exit`, restart del canal Telegram, o crash de algún proceso. Entre el "muere" y el "respawn completo" hay una ventana de 5–15 segundos donde no hay session `agent`. Reattach inmediato cae en esa ventana → "no sessions". `agentctl attach` poll cada segundo hasta 15s y conecta apenas el supervisor termina el respawn.

   Si después de 15s sigue sin conectar, hay un problema más profundo:

   ```bash
   ./scripts/agentctl logs -n 100             # tail del claude.log
   docker logs {{AGENT_NAME}} | tail -50      # logs del supervisor
   ```

#### `docker attach {{AGENT_NAME}}` cuelga sin output

`docker attach` conecta a stdio del PID 1, que es `start_services.sh` corriendo su watchdog en silencio. Usa `tmux attach` vía `docker exec` (ver arriba). Si te quedaste pegado después de un `docker attach` accidental, detach con `Ctrl-p Ctrl-q` (NO `Ctrl-c` — eso mata el contenedor).

#### Plugin de Telegram no conecta (`plugin:telegram:telegram · ✘ failed`)

Dos causas típicas:

1. **Plugin no instalado todavía** — en el primer boot claude arranca con `--channels` pero el plugin aún no está en cache. Re-ejecuta `docker compose restart` después del `/login` para que el watchdog lo instale y re-lance. Dentro de tmux, `/mcp` muestra el estado: debería verse `✔ connected`.
2. **`bun` falta en la imagen** — el MCP server del plugin corre con bun. La imagen del launcher lo instala; si construiste una imagen custom sin bun, confírmalo:

```bash
docker exec {{AGENT_NAME}} bun --version
```

#### El wizard del token se re-dispara en cada reinicio

Significa que `/workspace/.env` está vacío o sin `TELEGRAM_BOT_TOKEN=<no-vacío>`. Verifica:

```bash
ls -la {{DEPLOYMENT_WORKSPACE}}/.env          # debe ser 0600
grep "^TELEGRAM_BOT_TOKEN=" {{DEPLOYMENT_WORKSPACE}}/.env
docker exec {{AGENT_NAME}} cat /workspace/.env | grep TELEGRAM
```

Las 3 salidas tienen que coincidir. Si la última discrepa, el bind-mount está apuntando mal.

#### UID mismatch (permisos raros en bind-mount)

Pasa cuando `docker.uid` en `agent.yml` no empareja tu UID del host:

```bash
id -u                                              # tu UID
grep "uid:" {{DEPLOYMENT_WORKSPACE}}/agent.yml     # debería coincidir
```

Si difieren, edita `agent.yml` y corre `./setup.sh --regenerate && docker compose build && docker compose up -d --force-recreate`.

#### Logs del contenedor

```bash
docker logs {{AGENT_NAME}}                                    # supervisor (tail)
docker logs -f {{AGENT_NAME}}                                 # follow en vivo
docker exec {{AGENT_NAME}} cat /workspace/claude.log          # captura del tmux
docker exec {{AGENT_NAME}} cat /workspace/claude.cron.log     # log de crond
docker exec -u agent {{AGENT_NAME}} heartbeatctl logs         # runs.jsonl
```

#### "N MCP servers failed" al arrancar

Dentro del agente corre `/mcp` para ver cada servidor y su estado. Los más importantes: `plugin:telegram:telegram`, `atlassian-*`, `github`, `playwright`. Las fallas típicas son env vars faltantes en `.env` (tokens de Atlassian, GitHub PAT) o binarios ausentes (`bun`, `uvx`).
