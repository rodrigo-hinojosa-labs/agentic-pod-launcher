# Contrato: el e2e en contenedor y el gate en cbum

**Feature**: `045-plugin-launcher-path` | Cubre FR-008, FR-010, FR-011, SC-001, SC-002 y SC-005.

## E. `tests/docker-e2e-user-bin-path.bats`

Archivo nuevo, saltado sin `DOCKER_E2E=1`. Sigue el molde de `tests/docker-e2e-heartbeat.bats`: arma un workspace con `agent.yml`, copia `modules/`, `scripts/`, `docker/` y `setup.sh`, corre `--regenerate`, construye la imagen y la arranca con un `claude` de prueba montado en `/usr/local/bin/claude` (el `docker-compose.yml` generado se edita en el lugar para agregar ese montaje). Un solo arranque sirve a todas las pruebas (`setup_file`).

Es la confirmación en un contenedor real. El oráculo test-first es el del host (`contracts/host-oracle.md`), como en 044. El wizard del token no se ejecuta aquí, porque requiere sesión iniciada; lo cubre S1, que prueba la misma línea `tmux new-session`. Ninguna prueba usa `docker exec -u root` (Principio II).

**Siembra, antes del arranque** (en `.state/.local/bin`, que es `/home/agent/.local/bin` en el contenedor):

- `probe045`, un ejecutable que imprime una marca;
- `node`, un señuelo que imprime `DECOY`.

**El `claude` de prueba** agrega, en cada invocación, una línea a `/workspace/scripts/heartbeat/logs/stub-claude.jsonl` con su modo, sus argumentos, su `TMUX_PANE`, su PATH, `command -v probe045`, la salida de `probe045` y `command -v node`. Con `--print` responde y sale; con `mcp` sale con 0; fuera de tmux (las llamadas `claude plugin ...` que el supervisor hace antes de cada sesión, `ensure_official_marketplace`) es `supervisor` y sale con 1 de inmediato; dentro de tmux sin `--print` es la sesión y se queda viva (`sleep`). Sin la clase `supervisor`, la revisión independiente encontró que E1 tomaba un registro del supervisor por la sesión.

| Id | Qué afirma |
| --- | --- |
| E1 | la sesión principal (caso A, `claude` sin canal, registro con `pane` no vacío) corre con un PATH igual a `<PATH de la imagen>:/home/agent/.local/bin`; `probe045` se resuelve ahí y corre, y `node` se resuelve en `/usr/bin/node`. Además, un registro `supervisor` tiene exactamente el PATH de la imagen: el supervisor no cambia su propio PATH (C2) |
| E2 | tras matar la sesión, el watchdog la respawnea y la nueva invocación cumple lo mismo que E1 |
| E3 | un tick real del cron (heartbeat activado con intervalo de 1 minuto) invoca `claude --print` con el mismo contrato; `runs.jsonl` registra el tick con `trigger` `cron` (se espera a que aparezca, porque el tick lo escribe al terminar) |
| E4 | `scripts/agentctl mcp`, desde el host, invoca `claude mcp list` en el contenedor con el mismo contrato |
| E5 | el entorno que Docker entrega al contenedor (`docker inspect --format '{{json .Config.Env}}'`) tiene un `PATH` igual al de la imagen, `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`, sin `.local/bin`. De ese entorno heredan `tini`, el entrypoint, el bucle del crontab, `crond` y un `docker exec -u root` por defecto; que el entrypoint no cambie el PATH lo garantiza G1 en el código. La igualdad exacta, y no solo la ausencia, impide que la prueba pase con un entorno vacío |

Después corre el DOCKER_E2E entero en arm64 (`DOCKER_E2E=1 bats tests/docker-e2e-*.bats`), con COMPUERTA. Esperado: las 49 pruebas de hoy más las 5 nuevas, con 0 `not ok`.

## G. El gate en cbum, antes del merge (FR-011)

Requiere COMPUERTA del operador, porque toca un agente en producción. Todo en ferrari, en el workspace de cbum.

1. **Respaldo**: `docker tag agentic-pod:cbum agentic-pod:cbum-pre045`; copias de `agent.yml` y de `modules/`, `scripts/`, `docker/`, `setup.sh` y `VERSION` actuales.
2. **Código de la rama**: desde un clon de la rama en ferrari, seguir el procedimiento de `README.md` («Upgrade an existing agent», pasos 2 y 3). Se copian `setup.sh`, `VERSION`, `.gitignore` y `LICENSE`; se borran y se reponen `modules/` y `docker/`; y `scripts/` se copia encima sin borrarlo, para conservar el estado del heartbeat y del RAG. Después, `./setup.sh --regenerate`.
3. **Imagen**: `docker compose build`.
4. **Reinicio**: stop, 150 s, up (evita el 409 de Telegram). El enlace manual de `/usr/local/bin` desaparece con el contenedor viejo.
5. **Medición (SC-001)**:
   - el canal está sano, hay 0 reinicios y `/usr/local/bin/claude-mem` no existe;
   - el PATH del pane de la sesión termina en `/home/agent/.local/bin`;
   - **control positivo, antes del reinicio**: en el transcript más reciente de `~/.claude/projects/-workspace/`, los registros `hook_non_blocking_error` cuyo `stderr` contiene `Executable not found in $PATH: "claude-mem"` son 3 o más (los del 11-11-2026, anteriores al parche). Se anota la hora del reinicio;
   - **después**, tras tres prompts reales que el operador envía por Telegram, el mismo conteo, limitado a los registros con hora posterior al reinicio, da 0. Con `--continue` la sesión es la misma, así que el filtro por hora es obligatorio. Se cuenta con `jq` sobre `type`, `timestamp` y `stderr` del registro, sin leer la conversación. `claude.log` no sirve: no tiene saltos de línea y se reinicia con el contenedor;
   - claude-mem registró la sesión: el worker (`worker-service.cjs --daemon`) sigue vivo y `~/.claude-mem/claude-mem.db-wal` cambió de fecha o de tamaño después de los prompts.
6. **Si falla**: volver a `agentic-pod:cbum-pre045` con los archivos respaldados. Los hooks de claude-mem vuelven a fallar (sin bloquear) hasta corregir la causa. Rehacer el enlace manual exige `docker exec -u root`, fuera del Principio II, y solo se hace con la autorización explícita del operador, como el 11-11-2026. Registrar la causa.

Se registra lo que pide FR-011: commit, imagen, conteo de errores, evidencia de claude-mem, reinicios y canal.

## D. El despliegue después del merge (SC-005)

Lo hace el operador. donna y linus se reconstruyen con el mismo método, cada uno con su respaldo `agentic-pod:<agente>-pre045`, y se observan 24 h: 0 errores de hook nuevos y 0 reinicios atribuibles al cambio. cbum ya corre la imagen de la rama desde el gate y solo se vuelve a alinear con `main` si el merge cambió algo respecto de la rama.
