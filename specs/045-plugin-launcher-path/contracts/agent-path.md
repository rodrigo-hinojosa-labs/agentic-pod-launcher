# Contrato: el PATH de los procesos del agente

**Feature**: `045-plugin-launcher-path` | Cubre FR-001 a FR-007 y D1 a D4 de `research.md`.

## C1. `agent_path_compose CURRENT_PATH HOME UID`

Archivo nuevo, `docker/scripts/lib/agent_path.sh`. Es POSIX sh (lo cargan bash y el `sh` de BusyBox) y solo define funciones: cargarlo no tiene efectos.

- **Entradas**: el PATH actual, el `HOME` y el UID efectivo, siempre como argumentos. La función no lee variables de entorno para decidir, así que se puede probar de forma hermética.
- **Salida**: una sola línea en stdout con el PATH resultante, según la tabla de `data-model.md` («PATH compuesto»). Nada en stderr. Siempre sale con 0.
- **Directorio**: exactamente `"$HOME/.local/bin"`, sin barra final.
- **Idempotencia**: si `":$CURRENT_PATH:"` ya contiene `":$HOME/.local/bin:"`, devuelve la entrada tal cual.
- **Prohibido**: exportar, leer el sistema de archivos, invocar comandos externos, mover o quitar directorios de la entrada.

## C2. La sesión interactiva (`start_services.sh`)

- La librería se carga con la cascada de las demás (`/opt/agent-admin/scripts/lib/agent_path.sh`; si no está, la ruta del repositorio, para las pruebas del host).
- En `start_session`, después de `cmd=$(next_tmux_cmd)` y antes de crear la sesión:
  - si `agent_path_compose` existe, el PATH de la sesión es `agent_path_compose "$PATH" "$HOME" "$(id -u)"`;
  - si no, es `"$PATH"`, y el log dice, una vez por arranque, que el directorio no entró.
- La única línea `tmux new-session` de `start_session` pasa `-e "PATH=<PATH de la sesión>"`. El texto de `$cmd` no cambia.
- El PATH del propio `start_services.sh` no cambia (no hay `export`).
- No cambian: `_run_watchdog` (su oráculo de sha), `next_tmux_cmd`, la línea `launching:` del log, `pre_warm_mcps` ni la poda.

## C3. El tick del heartbeat (`scripts/heartbeat/heartbeat.sh`)

- Carga la librería desde `${HEARTBEAT_AGENT_PATH_LIB:-/opt/agent-admin/scripts/lib/agent_path.sh}`, con la guarda `[ -f ]`. El script no usa `set -e` y no puede abortar por la librería.
- Antes de su `tmux new-session`, compone el PATH con la misma regla que C2 y lo pasa con `-e "PATH=..."`. Si la función no existe, usa `"$PATH"`.
- No cambian: el texto del comando del tick (`CLAUDE_CONFIG_DIR=... claude --print ...`), el escapado con `sh_sq`, el aislamiento de `CLAUDE_CONFIG_DIR` ni el contrato de `runs.jsonl` y `state.json`.

## C4. `agentctl mcp` (`scripts/agentctl`)

- `cmd_mcp` ejecuta `docker exec -u agent <agente> sh -c '<script>' agentctl-mcp <args>`, donde el script:
  1. si `/opt/agent-admin/scripts/lib/agent_path.sh` existe, lo carga y exporta `PATH="$(agent_path_compose "$PATH" "$HOME" "$(id -u)")"`;
  2. termina con `exec claude mcp "$@"`.
- Sin argumentos, el comando sigue siendo `list`. Con una imagen anterior, sin la librería, se comporta como hoy.
- `cmd_shell`, con y sin `--root`, no cambia.

## C5. Lo que no cambia (FR-004 a FR-006)

- `docker/Dockerfile` no agrega ningún `ENV PATH`. Solo agrega la línea `COPY scripts/lib/agent_path.sh /opt/agent-admin/scripts/lib/agent_path.sh` y reescribe el comentario de 036.
- `docker/entrypoint.sh` no se toca. `crond`, el bucle del crontab y `tini` conservan el PATH de la imagen.
- `docker-compose.yml.tpl`, los bind-mounts, `cap_drop`, `cap_add` y `no-new-privileges` no se tocan.
- `modules/`, `setup.sh` y los artefactos del modo local no se tocan; el render local queda byte-idéntico.
