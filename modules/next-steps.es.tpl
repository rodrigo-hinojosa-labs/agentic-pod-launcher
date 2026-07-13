# {{AGENT_DISPLAY_NAME}} — siguientes pasos ({{#if DEPLOYMENT_MODE_IS_DOCKER}}modo Docker{{/if}}{{#unless DEPLOYMENT_MODE_IS_DOCKER}}modo local{{/unless}})

{{#if DEPLOYMENT_MODE_IS_DOCKER}}Tu agente está scaffoldeado como contenedor Docker en `{{DEPLOYMENT_WORKSPACE}}`.

## 1. Build y arranque

```bash
cd {{DEPLOYMENT_WORKSPACE}}
docker compose build
./scripts/agentctl up                    # docker compose up -d (pre-crea .state/ si falta)
```

El contenedor arranca y el supervisor lanza Claude Code dentro de una sesión tmux detached. Conéctate con `agentctl attach` — el wrapper hace retry-loop interno (15s máx) hasta que el supervisor termine de respawnear la sesión:

```bash
./scripts/agentctl attach
```

> **Nota**: `agentctl` es un wrapper host-side de `docker exec -u agent {{AGENT_NAME}} ...`. Resuelve el nombre del container desde `agent.yml` (cwd) o de la flag `-a NAME`. Subcomandos (a la fecha de v0.12.0): `doctor`, `attach`, `logs [-f]`, `status`, `heartbeat <sub>`, `mcp [list]`, `versions [--check]`, `shell [--root]`, `up`, `start`, `stop`, `restart`, `ps`, `run <cmd…>`. Equivalente raw (si prefieres tipearlo): `docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent`.

Para salir sin matar el contenedor: `Ctrl-b d` (atajo estándar de tmux).

## 2. Autenticar Claude (una sola vez)

### Token headless (recomendado)

En macOS la credencial del `/login` interactivo no persiste — la incoherencia de
cache de VirtioFS sobre el bind-mount `~/.claude` la descarta, así que Claude
vuelve a "Not logged in" en cada arranque. Usa un token de larga duración:
genéralo una vez en el **host** y ponlo en `.env` ANTES del primer `agentctl up`.

```bash
claude setup-token            # en el HOST; autoriza OAuth, pega el código EN LA TERMINAL
#   → imprime un token de larga duración: sk-ant-oat01-…
$EDITOR {{DEPLOYMENT_WORKSPACE}}/.env   # define CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-…
./scripts/agentctl up         # el agente arranca ya autenticado — sin /login
```

El token vive solo en `.env` (0600, gitignored) — nunca en `agent.yml`. El backup
de identidad **nunca** sube un `.env` en texto plano: con un recipient age/SSH
configurado (modo completo) viaja cifrado como `.env.age`; sin recipient (modo
parcial) el `.env` **queda fuera del fork por completo** — el token entonces NO
se recupera con `./setup.sh --restore-from-fork` y hay que volver a crearlo
después de un restore. Configura un recipient para tenerlo respaldado cifrado:

```bash
./scripts/agentctl heartbeat backup-identity --configure-key <path|pubkey>
```

### /login interactivo (fallback)

Si omites el token, haz login dentro de la sesión tmux:

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

## 5. Vault, índice semántico y wiki-grafo (opcional)

Modo docker: todo esto corre **dentro del contenedor** por cron (no hay unidades
systemd); cada pieza está gateada en `agent.yml` y no hace nada si está apagada.
Defaults a la fecha de v0.12.0:

| Feature | Gate en `agent.yml` | Cadencia (override) |
|---|---|---|
| Backup del vault → rama `backup/vault` | `vault.enabled: true` | `0 * * * *` (`vault.backup_schedule`) |
| Índice semántico QMD (backstop de reindex) | `vault.qmd.enabled: true` | `*/5 * * * *` (`vault.qmd.schedule`) |
| Wiki-grafo: derive + lint estructural | vault on; se apaga con `vault.wiki_graph.enabled: false` | `20 */6 * * *` (`vault.wiki_graph.schedule`) |

Con QMD encendido, el supervisor además construye el índice en background en el
primer boot y mantiene un watcher inotify, así que una edición reindexa de
inmediato; la línea de cron es solo el backstop. Ambos llaman al mismo comando
con flock, así que nunca se pisan.

El workspace está bind-mounted en `/workspace`, así que el estado y los logs se
leen desde el host sin entrar al contenedor:

```bash
cd {{DEPLOYMENT_WORKSPACE}}
tail -f scripts/heartbeat/logs/qmd-reindex.log     # corridas de reindex
tail -f scripts/heartbeat/logs/wiki-graph.log      # corridas de derive + lint
tail -f scripts/heartbeat/logs/backup-vault.log    # pushes del backup del vault
jq . scripts/heartbeat/qmd-index.json              # hash, last_run, last_status, pending
jq . scripts/heartbeat/wiki-graph.json             # last_run, last_status, counts

# Acciones manuales (con flock; seguras aunque el cron esté armado)
./scripts/agentctl heartbeat qmd-reindex           # reindex ahora (--dry-run solo reporta)
./scripts/agentctl heartbeat wiki-graph            # regenerar el grafo ahora
./scripts/agentctl heartbeat backup-vault --dry-run
```

**Completitud del embed.** `qmd embed` no alcanza a terminar un primer índice
grande en una sola sesión del motor, así que una corrida de reindex encadena
pasadas frescas hasta cubrir el corpus, con un tope fijo (12 pasadas a la fecha
de v0.12.0). `qmd-index.json` deja el resultado: `last_status: indexed` +
`pending: 0` = corpus completo; `partial` = se alcanzó el tope y quedan
`pending: N`; `stalled` = una pasada no avanzó nada. Mientras `pending` sea
distinto de cero (o no exista), la corrida siguiente **reanuda** el embed en vez
de saltarlo por el guard de "vault sin cambios" — no hay que hacer el loop a
mano. `skipped` = vault sin cambios y ya completo; `error` = la corrida falló
(revisa el log de arriba). Un corpus parcial se nota como búsquedas semánticas
flojas, no como error.

## Uso diario

```bash
# Reconectar a la sesión
./scripts/agentctl attach

# Ver estado del heartbeat
./scripts/agentctl status

# Tail del log de Claude
./scripts/agentctl logs -f

# Rotar un secreto (.env se inyecta como env_file al CREAR el contenedor)
$EDITOR {{DEPLOYMENT_WORKSPACE}}/.env
docker compose up -d --force-recreate    # `agentctl restart` NO re-inyecta el .env

# Actualizar a una versión nueva del template
cd {{DEPLOYMENT_WORKSPACE}}
git pull                                 # si tu workspace es un fork
docker compose build
./scripts/agentctl up                    # up -d recrea el contenedor con la imagen nueva
```

> **`restart` no es `stop` + `up`.** `agentctl restart` ejecuta `docker compose restart`: reinicia el proceso del contenedor **existente**, sin recrearlo. No levanta una imagen recién construida ni vuelve a leer `.env` (incluido `CLAUDE_CODE_OAUTH_TOKEN`). Para cualquier cambio de imagen o de secretos usa `./scripts/agentctl up` (o `docker compose up -d --force-recreate`).

### Cheatsheet completo de `agentctl`

```bash
# Ciclo de vida del contenedor
./scripts/agentctl up                    # docker compose up -d (pre-crea .state/ si falta)
./scripts/agentctl stop                  # docker compose down (remueve el contenedor; .state/ se preserva)
./scripts/agentctl restart               # docker compose restart (mismo contenedor: NO recarga imagen ni .env)
./scripts/agentctl ps                    # docker compose ps

# Sesión interactiva
./scripts/agentctl attach                # tmux attach (retry-loop 15s)
./scripts/agentctl shell                 # bash dentro del contenedor (como agent)
./scripts/agentctl shell --root          # bash como root (debugging)
./scripts/agentctl run <cmd…>            # ejecuta un comando arbitrario (como agent)

# Observabilidad
./scripts/agentctl logs                  # tail del claude.log
./scripts/agentctl logs -f               # follow
./scripts/agentctl logs --stderr         # forensic tail del MCP stderr de Telegram
./scripts/agentctl status                # heartbeat status (atajo a heartbeat status)
./scripts/agentctl doctor                # diagnóstico completo; exit 0 limpio / 1 warnings / 2 errores

# Pins del toolchain registrados en agent.yml
./scripts/agentctl versions              # versiones + canales registrados
./scripts/agentctl versions --check      # además consulta upstream y marca lo desactualizado
./scripts/agentctl versions --upgrade    # re-resuelve los canales no pineados en agent.yml

# MCP servers
./scripts/agentctl mcp                   # claude mcp list (ver servers + estado)

# Heartbeat (proxy a heartbeatctl)
./scripts/agentctl heartbeat status      # last run + counters
./scripts/agentctl heartbeat test        # un tick manual
./scripts/agentctl heartbeat logs        # últimos 20 runs
./scripts/agentctl heartbeat pause       # pausar el cron
./scripts/agentctl heartbeat resume      # reanudar
./scripts/agentctl heartbeat set-interval 5m
./scripts/agentctl heartbeat set-prompt "..."
./scripts/agentctl heartbeat kick-channel  # respawn de tmux cuando Telegram ghosting
./scripts/agentctl heartbeat backup-identity
./scripts/agentctl heartbeat backup-vault
./scripts/agentctl heartbeat backup-config
./scripts/agentctl heartbeat qmd-reindex   # reindex del índice semántico del vault
./scripts/agentctl heartbeat wiki-graph    # derivar el wiki-grafo + lint
./scripts/agentctl heartbeat token-check   # probe ad-hoc de salud de tokens
```

> **Resolución de nombre del agente**: `agentctl` lee `agent.yml` del cwd (o el flag `-a NAME`) para saber qué container atacar. Si cambias de directorio o tienes varios agentes, usa `-a <name>`.

{{PLUGINS_BLOCK}}

## Desmantelamiento

```bash
./setup.sh --uninstall --yes             # detiene contenedor, remueve unit de host (estado en .state/ se preserva)
./setup.sh --uninstall --purge --yes     # también borra agent.yml/.env/.state/
./setup.sh --uninstall --nuke --yes      # también borra este directorio de workspace entero
```

## Troubleshooting

### Si algo no anda: corre `agentctl doctor` primero

Antes de cualquier otra cosa:

```bash
./scripts/agentctl doctor
```

Recorre los chequeos en orden de dependencia (daemon de Docker → contenedor existe → contenedor corriendo → health → `agent.yml` + versión del launcher → `.env` 0600 → tmux → crond → plugin de Telegram → heartbeat → vault → patches del plugin → `.state/` como fuente del bind-mount) y después agrega frescura de los tres backups (identity/vault/config), plugins que el supervisor no pudo instalar y salud de los tokens (GitHub, Telegram, Atlassian, OAuth de Claude). Reporta `✓` / `⚠` / `✗` por cada uno con una sugerencia accionable, y sale `0` limpio / `1` con warnings / `2` con errores. Es la forma más rápida de saber qué subsistema está roto sin ejecutar 8 comandos distintos: cada plugin fallido viene con su comando de reintento copy-paste.

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

1. **Falta `-u agent`**: `docker exec` por defecto entra como root, y tmux guarda el socket por UID en `/tmp/tmux-<uid>/`. La sesión vive en el UID de `agent` — el UID de tu host, horneado como build-arg (típicamente `501` en macOS, `1000` en Linux; el default de la imagen es `ARG UID=1000`) —, así que root mira `/tmp/tmux-0/` y reporta vacío. `agentctl attach` siempre pasa `-u agent`. Equivalente raw: `docker exec -it -u agent {{AGENT_NAME}} tmux attach -t agent`.

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

1. **Plugin no instalado todavía** — en el primer boot claude arranca antes del `/login`, así que los plugins no pueden instalarse. Después del `/login`, el watchdog lo detecta y auto-instala los plugins + re-lanza con `--channels` — sin reinicio manual. Dentro de tmux, `/mcp` muestra el estado: debería verse `✔ connected`. Si alguno queda en fallo, `agentctl doctor` lo lista con un comando de reintento.
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

Dentro del agente corre `/mcp` para ver cada servidor y su estado. Los que importan: `plugin:telegram:telegram`, `atlassian-*`, `github`, `playwright` y —cuando el vault está encendido— `vault` y `qmd`. Las fallas típicas son env vars faltantes en `.env` (tokens de Atlassian, GitHub PAT) o binarios ausentes (`bun`, `uvx`, `npx`).

`qmd` es un caso aparte: no corre por `bunx`. Su `command` en `.mcp.json` es el wrapper horneado en la imagen `/opt/agent-admin/scripts/qmd-mcp`, que levanta el server desde el mismo prefijo bun gestionado al que escribe el reindex. Si falla, mira primero el log del reindex (`scripts/heartbeat/logs/qmd-reindex.log`): un prefijo roto rompe a los dos.
{{/if}}{{#unless DEPLOYMENT_MODE_IS_DOCKER}}Tu agente está scaffoldeado en **modo local** (Linux/systemd) en `{{DEPLOYMENT_WORKSPACE}}` — corre directo en el host, sin contenedor Docker, como una sesión persistente de Claude Code Remote Control bajo systemd.

> **Advertencia de seguridad.** El agente corre como **tu usuario** y hereda tus privilegios y secretos (archivos, llaves SSH, tokens). No hay aislamiento de contenedor. Quien controle la cuenta claude.ai controla esta máquina: **MFA es obligatorio**. Nunca se usa `--dangerously-skip-permissions`.

## Requisitos (host Linux)

- `systemd`, `jq`, `git`, `bash`.
- Claude Code **≥ 2.1.51** (a la fecha de v0.12.0; el helper de login verifica la versión y aborta si no se cumple).
- Cuenta claude.ai con plan compatible con Remote Control (toggle ON en Team/Enterprise).
- **MFA activo** en la cuenta.

## 1. Login full-scope (único paso manual, one-time)

```bash
cd {{DEPLOYMENT_WORKSPACE}}
./setup.sh --login        # verifica versión, pre-siembra onboarding, lanza el OAuth,
                          # aplica el trust del workspace, pre-acepta el prompt de Remote Control,
                          # provisiona los runtimes MCP y habilita el servicio systemd
```

- Es un login OAuth interactivo (el token inference-only de `claude setup-token` NO sirve para Remote Control).
- En headless: tuneliza el puerto del callback por SSH (`ssh -L <port>:localhost:<port> host`) y completa el OAuth en tu navegador.
- Deja `{{DEPLOYMENT_WORKSPACE}}/.state/.claude/.credentials.json` (0600, gitignored) y re-aplica el trust (el login reescribe `.claude.json`).
- Corre `scripts/local/agent-bootstrap.sh` ("Provisioning MCP runtimes") antes de habilitar la unit: ese paso instala `uv`/`uvx`, los symlinks `node`/`npx`, `bun` y `github-mcp-server` en `~/.local/bin`. Necesita red; sin él, cada MCP server muere con `ENOENT` en su primer arranque.
- Es idempotente: re-ejecutarlo no rompe nada.

## 2. Operación

Modo local: `agentctl` no queda en tu `PATH` — invócalo como `./scripts/agentctl`
desde el workspace. Los subcomandos exclusivos de docker (`up`, `attach`, `shell`,
`logs`, `mcp`, …) se niegan con exit 2 y apuntan al equivalente systemd.

```bash
systemctl status  agent-{{AGENT_NAME}}.service          # estado de la sesión
journalctl -u     agent-{{AGENT_NAME}}.service -f        # logs (busca 'session url'/'connected')
./scripts/agentctl status                               # dashboard de la unit + vault/RAG
./scripts/agentctl doctor                               # diagnóstico; exit 0 limpio / 1 warnings / 2 errores
./scripts/agentctl versions --check                     # pins del toolchain en agent.yml vs upstream
./scripts/local/agent-killswitch.sh                     # KILL SWITCH (detiene sesión + qmd + wiki-grafo + backup del vault + healthcheck)
```

El `doctor` local chequea `claude` en el `PATH` y su versión, que la unit esté
`active`, una señal de conexión reciente en el journal, `.credentials.json`
(presente + `0600`), `.env` (presente + `0600` + el secreto requerido de cada
MCP habilitado, no vacío) y —cuando el vault está encendido— las units de QMD y
wiki-grafo, la frescura del índice y la del backup del vault. Como sale con
`0`/`1`/`2`, `./scripts/agentctl doctor || alert` sirve para monitoreo. Al kill
switch agrégale `--disable` para que además no arranque en el próximo boot.

**Los secretos** (`.env`) llegan a la sesión vía `EnvironmentFile=-.env` en la
unit de systemd. Edita `.env` y después
`sudo systemctl restart agent-{{AGENT_NAME}}.service` — systemd solo lo lee al
arrancar el proceso, así que editar el archivo solo no hace nada hasta que la
unit se reinicia. Corre `doctor` después para confirmar.
{{#if VAULT_QMD_ENABLED}}
### RAG (QMD) — frescura y control

Los entrypoints de reindex son fail-silent (exit 0); el detalle va al journal de systemd, no a un log del workspace:

```bash
journalctl -u agent-{{AGENT_NAME}}-qmd-reindex.service   # corridas de reindex programadas
journalctl -u agent-{{AGENT_NAME}}-qmd-watch.service     # watcher inotify (reindex al cambiar)
systemctl list-timers 'agent-{{AGENT_NAME}}-*'           # todos los timers del agente
./scripts/agentctl heartbeat qmd-reindex                 # forzar un reindex ahora (no acepta --dry-run: reindexaría de verdad)
jq . scripts/heartbeat/qmd-index.json                    # hash, last_run, last_status, pending
```

**Completitud del embed.** `qmd embed` no alcanza a terminar un primer índice grande en una sola sesión del motor, así que una corrida de reindex encadena pasadas frescas hasta cubrir el corpus, con un tope fijo (12 pasadas a la fecha de v0.12.0). `qmd-index.json` deja el resultado: `last_status: indexed` + `pending: 0` = corpus completo; `partial` = se alcanzó el tope y quedan `pending: N`; `stalled` = una pasada no avanzó nada. Mientras `pending` sea distinto de cero (o no exista), el siguiente tick del timer **reanuda** el embed en vez de saltarlo por el guard de "vault sin cambios" — no hay que hacer el loop de `qmd embed` a mano. `skipped` = vault sin cambios y ya completo; `error` = la corrida falló (revisa el journal). Un corpus parcial se nota como búsquedas semánticas flojas, no como error.
{{/if}}{{#if VAULT_ENABLED}}
```bash
journalctl -u agent-{{AGENT_NAME}}-vault-backup.service  # pushes del backup del vault
./scripts/agentctl heartbeat backup-vault                # forzar un backup (agrega --dry-run para previsualizar)
```
{{/if}}{{#if WIKI_GRAPH_ENABLED}}
### Wiki-grafo — derivar y lint

El runner del wiki-grafo es fail-silent (exit 0); el detalle va al journal, a los artefactos `.graph/` y al state file:

```bash
journalctl -u agent-{{AGENT_NAME}}-wiki-graph.service    # corridas programadas de derive+lint
systemctl list-timers 'agent-{{AGENT_NAME}}-*'           # todos los timers del agente
./scripts/agentctl heartbeat wiki-graph                  # regenerar el grafo ahora
./scripts/agentctl status                                # frescura del grafo + counts de hallazgos
```
{{/if}}
Controlas el agente desde **claude.ai/code** y la app móvil (identidad `<hostname>-{{AGENT_NAME}}`). El healthcheck corre por timer (~5 min) y avisa si el login expira, hay error de auth, o la unit del watcher QMD / wiki-grafo está `failed`. Auto-recuperación: si el proceso muere, systemd lo rearranca en ~10 s (`Restart=always`).

## 3. Verificación (gates en el host)

1. `claude --version` → ≥ 2.1.51.
2. `.credentials.json` presente y `0600` tras el login.
3. `systemctl is-active agent-{{AGENT_NAME}}.service` = `active` **y** señal de conexión en el journal.
4. `CLAUDE_CONFIG_DIR={{DEPLOYMENT_WORKSPACE}}/.state/.claude claude -p "Reply: READY"` → `READY` sin 401.
5. Idempotencia: re-correr `./setup.sh --regenerate` y `--login` no cambia nada.
6. Auto-recuperación: `kill -9` del proceso `claude remote-control` → rearranca en ~10 s.
{{/unless}}
