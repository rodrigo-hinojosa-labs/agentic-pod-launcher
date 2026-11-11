# Research: Los hooks de claude-mem 15.x encuentran su lanzador en los agentes docker

**Feature**: `045-plugin-launcher-path` | **Fecha**: 2026-11-11 | **Spec**: [spec.md](spec.md)

Fase 0 del plan. Resuelve las dos afirmaciones que el spec dejó sin medir (qué PATH hereda un job de `crond` y qué entorno hereda una sesión tmux nueva) y fija el diseño.

## Mediciones

Todas en un contenedor desechable (`docker run --rm -u 0 --entrypoint sh`) de `agent-admin:wg-para-e2e`, una imagen del launcher construida el 08-11-2026 (Alpine 3.24.1, BusyBox 1.37.0, tmux 3.6b y `su-exec`, igual que producción), en el Mac del operador (arm64). El script es `scratchpad/045/m_env_probe.sh` y la salida completa está en `scratchpad/045/m_env_probe.out`. El contenedor arranca `crond` como root con el PATH de la imagen, como hace `docker/entrypoint.sh`, y baja a `agent` con `su-exec`, como hace `start_services.sh`.

### M1. El entorno de un job de busybox `crond`

`crond` corre con el PATH de la imagen y una variable de prueba `PROBE_MARK`. Un job de la crontab de `agent` vuelca su entorno.

| Variable | Valor en el job |
| --- | --- |
| `PATH` | `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` (el de `crond`) |
| `HOME` | `/home/agent` |
| `USER` y `LOGNAME` | `agent` |
| `SHELL` | `/bin/sh` |
| `PROBE_MARK` | heredada de `crond` |

**Conclusión**: el job hereda todo el entorno de `crond`, que es root, y `crond` solo fija la identidad del usuario. El heartbeat corre con el PATH de la imagen y no tiene cómo recibir `~/.local/bin` desde arriba sin que también lo tenga `crond`. Eso violaría FR-004.

### M2. El PATH de una sesión tmux nueva cuando el servidor ya existe

`agent` arranca el servidor tmux con el PATH extendido, como lo haría `start_services.sh`. Después, otro cliente con `PATH=/usr/bin:/bin`, como el heartbeat desde cron, crea su propia sesión.

| Pane | PATH |
| --- | --- |
| sesión principal (cliente extendido, arrancó el servidor) | `...:/bin:/home/agent/.local/bin` |
| entorno global del servidor | `...:/bin:/home/agent/.local/bin` |
| sesión del segundo cliente | `/usr/bin:/bin` |

**Conclusión**: en tmux 3.6b, una sesión nueva toma el PATH del **cliente que la crea**, no el del entorno global del servidor. El spec suponía lo contrario (fila «Una sesión tmux nueva hereda el entorno global del servidor tmux del agente»): queda refutado.

### M3. El caso inverso: el servidor lo arrancó un cliente sin el directorio

Un cliente sin el directorio arranca el servidor, y después el cliente extendido crea la sesión principal. Esa sesión tiene `...:/bin:/home/agent/.local/bin`. **Conclusión**: no importa quién arrancó el servidor; manda el cliente que crea la sesión.

### M4. `new-session -e PATH=...`

`tmux new-session -d -s main3 -e "PATH=$PATH" ...` deja el PATH pedido en el pane y en el entorno de la sesión (`show-environment -t main3 PATH`). **Conclusión**: `-e` funciona en tmux 3.6b (y en el 3.6a del host) y fija el PATH de forma explícita, sin depender del entorno del cliente ni del servidor.

### M5. La resolución por nombre con el directorio al final

Con `PATH=<imagen>:/home/agent/.local/bin`, medido como `agent`:

- un ejecutable `probe045`, que solo existe en `~/.local/bin`, se resuelve ahí y corre con `env probe045` (forma exec, sin shell);
- un señuelo `node` en `~/.local/bin` no gana: `command -v node` da `/usr/bin/node`;
- un enlace colgante en `~/.local/bin` que apunta a `/opt/uv/tools/...` da rc 127 al ejecutarlo, igual que un nombre inexistente;
- un proceso root con el PATH de la imagen no encuentra `probe045` (`not-found`).

**Conclusión**: el orden protege los binarios de la imagen (FR-003) y no introduce una regresión con los enlaces colgantes.

### M6. El servidor MCP de claude-mem 15.16.0

Lo leí en el repositorio público del vendor, en `plugin/.mcp.json` de la etiqueta `v15.16.0` (`gh api repos/thedotmack/claude-mem/contents/plugin/.mcp.json?ref=v15.16.0`). El servidor `mcp-search` se lanza con `"command": "node"` y un script en línea, no con el lanzador. **Conclusión**: hoy solo los hooks dependen del lanzador. `agentctl mcp` (`claude mcp list`) no tiene un consumidor actual del directorio. Se cubre igual para que el diagnóstico vea el mismo PATH que la sesión (D3).

### M7. Qué pruebas dependen de las líneas que se tocan (leído en código)

- `tests/start-services-watchdog.bats:247` fija el texto exacto del `claude` sin canal (`CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR_VAL claude`). Modificar el texto del comando lo rompería; `-e` no lo toca.
- `tests/start-services-warm.bats:150-156` busca la línea `tmux new-session` de `start_session` para verificar el orden, y sigue siendo una sola línea.
- `tests/docker-render.bats:217` verifica que `pre_accept_bypass_permissions` va antes de `cmd=$(next_tmux_cmd)`. No cambia.
- `tests/agentctl.bats:146-152` espera `claude`, `mcp` y `list` como argumentos sueltos de `docker exec`. Con D3, `claude mcp` corre dentro de un `sh -c`, y esa prueba se actualiza (justificada en el plan).
- `tests/start-services-watchdog.bats:587` congela `_run_watchdog` con un sha; el diseño no toca esa función.
- Ninguna prueba del repo usa `docker exec -u root` (búsqueda en `tests/`, `scripts/agentctl` y `docs/`).
- Ninguna prueba fija el total de 49 pruebas e2e (búsqueda de `total=49`, `executed=49` y `49 de 49` en `tests/` y `.github/`: sin resultados).

### M8. Dónde queda registrado el error de un hook (análisis del 11-11-2026)

Lectura de solo los campos del registro, sin la conversación, en el transcript de la sesión de cbum (`~/.claude/projects/-workspace/*.jsonl`, primera entrada a las 04:39 UTC del 11-11-2026):

- cada falla de un hook queda como un registro `hook_non_blocking_error`, con `hookName`, `hookEvent`, `exitCode`, `command` y `stderr`;
- hay 3, de `SessionStart:startup`, `UserPromptSubmit` y `PreToolUse:Bash`, entre las 04:39 y las 04:49 UTC (antes del parche), con `exitCode` 1;
- el `stderr` es `Failed with non-blocking status code: Error occurred while executing hook command: Executable not found in $PATH: "claude-mem"`, **con comillas**. El texto sin comillas que usaba el borrador del spec no aparece nunca (0 coincidencias).

**Conclusión**: SC-001 se mide en el transcript, con el texto con comillas y filtrando por hora (con `--continue` la sesión es la misma). Los 3 registros existentes son el control positivo. `claude.log` no sirve: no tiene saltos de línea y se reinicia con el contenedor. El almacén de claude-mem es `~/.claude-mem/claude-mem.db` con su `-wal`, cuya fecha marca la última escritura.

## Decisiones

### D1. El mecanismo: `tmux new-session -e PATH=...` en los dos lugares que crean sesiones de `claude`

- **Decisión**: `start_session` (`docker/scripts/start_services.sh:842-880`) y la función que lanza el tick en `scripts/heartbeat/heartbeat.sh` (`:216`) pasan `-e "PATH=<PATH compuesto>"` a su `tmux new-session`. El PATH compuesto es el PATH del proceso que crea la sesión con `/home/agent/.local/bin` agregado al final (D2). El entorno de `start_services.sh` y el de `heartbeat.sh` no cambian: solo el de la sesión que crean.
- **Por qué**: M2 y M3 muestran que tmux toma el PATH del cliente que crea la sesión. Fijarlo en la creación, con `-e`, cubre la sesión principal, sus respawns (todos pasan por `start_session`), el `claude` sin canal del `/login`, el wizard del token (los tres son el comando de esa sesión) y los ticks del heartbeat. No depende de quién arrancó el servidor tmux (M3 y M4) ni del entorno de `crond` (M1). Los procesos root no se tocan, así que FR-004 se cumple por construcción.
- **Alternativas descartadas**:
  - `ENV PATH` en el Dockerfile: llega a todo proceso del contenedor, incluidos el entrypoint, el bucle del crontab, `crond` y un `docker exec -u root` (viola FR-004). El entrypoint podría limpiarlo para sus hijos, pero `docker exec -u root` lo recibiría igual.
  - Un `export PATH` global en `start_services.sh`: no llega al heartbeat (M1 y M2) y extiende el PATH de cada hijo del supervisor (instalación de plugins, calentamiento de uv y npm, qmd) sin un consumidor.
  - Agregar `PATH=...` al texto del comando (`next_tmux_cmd` y la línea del heartbeat): rompe la prueba que fija el texto exacto (M7) y mete el PATH en la línea `launching:` del log.
  - Un perfil de shell (`/etc/profile.d`): ni `docker exec` ni los panes de tmux (`sh -c`, sin login) lo leen.
  - Un envoltorio solo para `claude-mem`: lo descartó el operador (Clarifications, alcance general).

### D2. Una sola fuente: `docker/scripts/lib/agent_path.sh`

- **Decisión**: una librería nueva, solo para docker, con una función POSIX pura, `agent_path_compose CURRENT_PATH HOME UID`, que imprime el PATH resultante y siempre sale con 0 (contrato C1). Se copia a la imagen con su propia línea `COPY` (`docker/Dockerfile`, junto a las de `:258-268`). `start_services.sh` la carga con la cascada de siempre: primero `/opt/agent-admin/scripts/lib/`, después la ruta del repositorio, como `mcp_warm.sh` en `:64-76`. `heartbeat.sh` la carga con `HEARTBEAT_AGENT_PATH_LIB` (por defecto la ruta de la imagen), como ya hace con `HEARTBEAT_STATE_LIB` (`:17`), con la guarda `[ -f ]`. `agentctl mcp` la carga dentro del contenedor (D3).
- **Por qué**: el mismo criterio se aplica en tres lugares y no debe derivar. POSIX, porque `agentctl` la carga desde el `sh` de BusyBox. Una función pura, sin efectos al cargarse (Principio III). Solo docker, porque el modo local ya tiene el directorio primero en su PATH (FR-006) y `docker/` se copia entero al workspace, así que no hace falta un espejo en `scripts/lib/`.
- **Reglas del contrato** (C1): agrega `$HOME/.local/bin` al final. No lo duplica si ya está en cualquier posición. Con UID 0 devuelve el PATH sin cambios (defensa en profundidad de FR-004). Con `HOME` vacío, `/`, o con `:` o un salto de línea, también. Con un PATH vacío, también: no crea un PATH que tenga solo el directorio del usuario. No mira si el directorio existe, porque claude-mem lo crea durante la sesión y el PATH se resuelve en cada ejecución.
- **Alternativas descartadas**: copiar la expresión en cada lugar (deriva en silencio) y ponerla en una librería existente (ninguna trata de entorno; `state.sh` es del estado del heartbeat).

### D3. `agentctl mcp` se cubre; `agentctl shell` y un `docker exec` manual no

- **Decisión**: `cmd_mcp` (`scripts/agentctl:962-967`) pasa de `docker exec -u agent <agente> claude mcp ...` a `docker exec -u agent <agente> sh -c '<si la librería existe, cargarla y componer el PATH>; exec claude mcp "$@"' agentctl-mcp ...`. Con una imagen anterior, sin la librería, se comporta como hoy. `agentctl shell` (shell interactivo del operador) y un `docker exec -u agent` a mano reciben el PATH de la imagen. La documentación dice cómo agregar el directorio (`PATH="$PATH:$HOME/.local/bin"`).
- **Por qué**: `agentctl mcp` es la herramienta de diagnóstico de los MCP. Si un plugin futuro lanzara su servidor MCP desde `~/.local/bin`, el diagnóstico tiene que ver lo mismo que la sesión. Un shell interactivo no lanza hooks, y extender el PATH ahí no le aporta nada al contrato. `agentctl shell --root` no puede recibirlo (FR-004).
- **Costo**: se actualiza `tests/agentctl.bats:146-152` (M7), justificado por nombre.

### D4. Fail-silent (Principio IV)

Si la librería no está (una imagen anterior con un `heartbeat.sh` nuevo, o un `COPY` olvidado), `start_session` y el heartbeat crean la sesión con el PATH de siempre y no fallan. `start_services.sh` deja una línea en el log, una vez por arranque, que dice que el directorio no entró. Cuando sí entra, deja una línea que lo nombra. Ninguna de las dos imprime secretos: el PATH no los tiene.

### D5. El comentario de 036 y el resto de la documentación

El `ENV` del Dockerfile no cambia. Su comentario (`:118-125`) deja de decir que el directorio "no tiene consumidor" y explica por qué el PATH de la imagen sigue sin él (root) y dónde se agrega para el agente (045). `docs/architecture.md` no describe hoy el PATH de la imagen. Se agrega una línea en el modelo de privilegios: la invariante es de seguridad. CHANGELOG, `VERSION` 0.31.0 y el bloque de `CLAUDE.md` a mano (FR-012 y FR-013).

### D6. Evidencia

- **Host**: un archivo nuevo, `tests/agent-user-bin-path.bats` (contrato `contracts/host-oracle.md`). Sus pruebas caen contra `origin/main`, las que nacen verdes se prueban con mutaciones, y todo corre en bash 3.2 y en 5.x.
- **Contenedor**: un e2e nuevo, `tests/docker-e2e-user-bin-path.bats`, con un solo arranque que cubre la sesión, un tick real del cron, `agentctl mcp`, el entorno de los procesos root (con `docker inspect`, sin `docker exec -u root`) y un respawn. Después corre el DOCKER_E2E entero (contrato `contracts/e2e-and-gate.md`).
- **Antes del merge**: el gate en cbum (FR-011), medido en el transcript según M8.

## Riesgos residuales

- **tmux de otra versión**: M2 y M4 se midieron en 3.6b (imagen) y 3.6a (host). `-e` hace que el resultado no dependa de la semántica de herencia de cada versión, que es justo lo que M2 mostró que cambia de lo esperado.
- **Un plugin que instale en `~/.local/bin` un binario con el nombre de uno de la imagen** no se usa (FR-003). Es una decisión, no un defecto.
- **La primera sesión tras instalar claude-mem 15.x** puede fallar en los dos primeros hooks de `SessionStart` (orden del vendor; spec, casos borde).
- **Agentes con imagen anterior**: siguen con el defecto hasta reconstruirla.
