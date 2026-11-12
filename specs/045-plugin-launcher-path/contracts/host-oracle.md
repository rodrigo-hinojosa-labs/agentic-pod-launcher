# Contrato: el oráculo del host

**Feature**: `045-plugin-launcher-path` | Cubre FR-009 y SC-003.

Archivo nuevo, `tests/agent-user-bin-path.bats`. Corre sin Docker, en bash 3.2.57 (`PATH=/bin:$PATH bats ...` en el Mac) y en 5.x. Usa `tmux` real del host solo en H1, H2 y H3, como `tests/heartbeat-runs-jsonl.bats`, con un servidor privado (`TMUX_TMPDIR`), `SHELL=/bin/sh` y `XDG_CONFIG_HOME` temporal, para que la configuración del operador no toque el PATH. Cada prueba fija `HOME` en un directorio temporal: ninguna toca el `~/.local/bin` del operador. Las pruebas P corren la librería con `dash` si el host lo tiene (`/bin/dash` existe en macOS y es el `/bin/sh` de Ubuntu); el `/bin/sh` del Mac es bash en modo POSIX y aceptaría `[[ ]]`.

## Pruebas

| Id | Qué afirma | Contra `origin/main` |
| --- | --- | --- |
| P1 | `agent_path_compose "/a:/b" "$H" 501` imprime `/a:/b:$H/.local/bin`, una sola línea, con rc 0 y stderr vacío | ROJO (la librería no existe) |
| P2 | idempotencia: con el directorio al inicio, en el medio o al final, la salida es igual a la entrada; un directorio parecido (`$UB-old`, `/x$UB`) no cuenta y el directorio se agrega | ROJO |
| P3 | con UID 0, `00`, vacío o no decimal, la salida es igual a la entrada (falla cerrada); con 1000 se agrega | ROJO |
| P4 | con `HOME` vacío, `/`, relativo, con barra final, con `:` o con un salto de línea, y con un PATH vacío, la salida es igual a la entrada | ROJO |
| P5 | cargar la librería con `sh` (no bash) y llamar la función funciona, y cargarla no cambia `PATH` ni define variables globales nuevas | ROJO |
| P6 | el directorio se agrega aunque no exista (la función no mira el disco) | ROJO |
| S1 | `start_session`, con `tmux`, `sleep` y los pasos previos como funciones de prueba, llama a `tmux new-session` con el PATH `<PATH>:$HOME/.local/bin` (el stub graba el PATH con que lo llamaron) y sin `-e`; el texto del comando no cambia y el PATH del supervisor sigue igual después de la llamada | ROJO |
| S2 | sin `agent_path_compose` (función borrada), `start_session` crea la sesión con el PATH sin cambios, sale con 0 y deja una sola línea en el log que dice que el directorio no entró, aunque se llame dos veces | ROJO (hoy no escribe esa línea) |
| S3 | con un `id` que dice 0, `start_session` crea la sesión con el PATH sin cambios y no registra «appended»: los llamadores pasan el UID real | VERDE (nace verde) |
| H1 | un tick real de `heartbeat.sh` (tmux del host y un `claude` de prueba que vuelca su PATH) corre `claude` con un PATH que termina en `$HOME/.local/bin` y empieza con el PATH del tick. Antes, un cliente con otro PATH arranca el servidor privado, así que el entorno global del servidor y el del cliente son distintos y solo el del cliente puede hacer pasar la prueba (la lección de M4) | ROJO |
| H2 | con `HEARTBEAT_AGENT_PATH_LIB` apuntando a un archivo inexistente, el tick termina con `status: ok` en `runs.jsonl`, sin errores en stderr, y `claude` recibe el PATH del tick sin cambios | VERDE (nace verde) |
| H3 | con un `id` de prueba que dice 0 en el PATH, el `claude` del tick recibe el PATH sin cambios | VERDE (nace verde) |
| A1 | `agentctl mcp` graba `exec -u agent <agente> sh -c <script> agentctl-mcp list`; el script carga `/opt/agent-admin/scripts/lib/agent_path.sh` solo si existe y termina en `exec claude mcp "$@"`; `agentctl shell --root` sigue sin `-u agent` y sin el script | ROJO |
| A2 | el script grabado, ejecutado con un sh POSIX y un `claude` de prueba: sin la librería (el host no tiene `/opt/agent-admin`, la rama de una imagen anterior) sale con 0, `claude` recibe `mcp list` y el PATH sin cambios; con la ruta cambiada a la librería del repo, el PATH gana el directorio | ROJO |
| G1 | estructural (FR-004): `docker/Dockerfile` no tiene ninguna instrucción `ENV` que nombre `.local/bin`, leída completa (uniendo las líneas que terminan en `\`), ni ninguna línea que no sea comentario que lo nombre (un `RUN ln -s` hacia `/usr/local/bin`, la forma del parche manual de cbum); `modules/docker-compose.yml.tpl` no tiene una clave `PATH` en `environment:`; `docker/entrypoint.sh` no nombra `agent_path` ni `.local/bin`; y en `start_services.sh` y `heartbeat.sh` no hay ningún `export PATH` ni una asignación suelta de PATH | VERDE (nace verde) |
| G2 | estructural: `docker/Dockerfile` copia `scripts/lib/agent_path.sh` a `/opt/agent-admin/scripts/lib/agent_path.sh`, y `start_services.sh`, `heartbeat.sh` y `agentctl` nombran esa misma ruta | ROJO |

16 pruebas (13 del diseño y A2, S3 y H3, agregadas por la revisión independiente): 12 caen contra `origin/main` y 4 nacen verdes (H2, G1, S3 y H3). Las que nacen verdes se prueban con las mutaciones M12 (H2), M13, M14, M18, M19 y M20 (G1), M22 (S3) y M23 (H3).

**Prueba existente que cambia, justificada**: `tests/agentctl.bats`, «agentctl mcp default delegates to 'claude mcp list'» (`:146-152`). Espera `claude` y `mcp` como argumentos sueltos de `docker exec`, y con C4 esos argumentos viven dentro del script de `sh -c`. Se reescribe para afirmar `-u agent`, `sh`, `-c`, que el script termina en `exec claude mcp "$@"` y que el último argumento es `list`. Su intención (que el valor por defecto sea `list`) se conserva. Ninguna otra prueba existente cambia.

**Esperado de la suite del host**: la línea base medida sobre `origin/main` (1951) más 21, o sea 1972, con 0 `not ok` en los dos bash. Son las 16 pruebas de este archivo y las 5 de `tests/docker-e2e-user-bin-path.bats`, que en el host salen saltadas (precedente de 041).

## Catálogo de mutaciones

Cada mutación se aplica sobre una copia aislada del árbol, se corre `tests/agent-user-bin-path.bats` (y `tests/agentctl.bats` donde se indica) en los dos bash, y debe caer al menos la prueba nombrada.

| Id | Mutación | Debe caer |
| --- | --- | --- |
| M0 | control: el árbol de `origin/main` | exactamente P1 a P6, S1, S2, H1, A1, A2, G2 y la prueba reescrita de `agentctl.bats`; H2, G1, S3 y H3 verdes |
| M1 | el directorio se agrega al inicio y no al final | P1, H1, S1 |
| M2 | sin la comprobación de idempotencia | P2 |
| M3 | sin la guarda de UID 0 (todo UID decimal cuenta como no root) | P3 |
| M4 | sin la guarda de `HOME` | P4 |
| M5 | sin la guarda de PATH vacío | P4 |
| M6 | la librería hace `export PATH=...` al cargarse | P5 |
| M7 | la función usa una construcción solo de bash (`[[ ]]`) | P1 (el oráculo corre con dash también en el Mac; se repite en la pata Linux) |
| M8 | la función comprueba que el directorio exista | P6 |
| M9 | `start_session` sin el prefijo `PATH=...` en `tmux new-session` | S1 |
| M10 | `start_session` con `export PATH=...` en lugar del prefijo | S1 (el PATH del supervisor cambió) |
| M11 | `start_session` llama la función sin la guarda `command -v` | S2 |
| M12 | `heartbeat.sh` carga la librería sin la guarda `[ -f ]` y sin el respaldo `"$PATH"` | H2 |
| M13 | el Dockerfile agrega `ENV PATH=$PATH:/home/agent/.local/bin` | G1 |
| M14 | `entrypoint.sh` carga la librería y exporta el PATH | G1 |
| M15 | el Dockerfile sin la línea `COPY` de la librería | G2 |
| M16 | `heartbeat.sh` sin el prefijo `PATH=...` | H1 |
| M17 | `agentctl mcp` vuelve a `docker exec -u agent <agente> claude mcp` | A1 |
| M18 | el Dockerfile agrega `PATH=$PATH:/home/agent/.local/bin` como línea de continuación del `ENV` multilínea de `:126` | G1 |
| M19 | el Dockerfile agrega `RUN ln -s /home/agent/.local/bin/claude-mem /usr/local/bin/claude-mem` | G1 |
| M20 | compose gana `PATH: ...:/home/agent/.local/bin` en `environment:` | G1 |
| M21 | el script de `agentctl mcp` carga la librería sin la guarda `[ -f ]` | A2 |
| M22 | `start_session` pasa un UID literal (`501`) en lugar de `$(id -u)` | S3 |
| M23 | el heartbeat pasa un UID literal en lugar de `$(id -u)` | H3 |
| M24 | la idempotencia busca una subcadena en vez de un elemento entero del PATH | P2 |
| M25 | sin la guarda de UID vacío o no decimal (falla abierta) | P3 |
| M26 | sin el rechazo de un `HOME` relativo o con barra final | P4 |

**Pata Linux**: P5 y M7 corren también en `ubuntu:24.04` (dash como `sh`), como no root, con el repo copiado y no montado (lección de 039).
