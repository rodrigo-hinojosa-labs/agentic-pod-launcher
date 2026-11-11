# Contrato: el oráculo del host

**Feature**: `045-plugin-launcher-path` | Cubre FR-009 y SC-003.

Archivo nuevo, `tests/agent-user-bin-path.bats`. Corre sin Docker, en bash 3.2.57 (`PATH=/bin:$PATH bats ...` en el Mac) y en 5.x. Usa `tmux` real del host solo en H1 y H2, como `tests/heartbeat-runs-jsonl.bats`. Cada prueba fija `HOME` en un directorio temporal: ninguna toca el `~/.local/bin` del operador.

## Pruebas

| Id | Qué afirma | Contra `origin/main` |
| --- | --- | --- |
| P1 | `agent_path_compose "/a:/b" "$H" 501` imprime `/a:/b:$H/.local/bin`, una sola línea, con rc 0 y stderr vacío | ROJO (la librería no existe) |
| P2 | idempotencia: con el directorio al inicio, en el medio o al final, la salida es igual a la entrada | ROJO |
| P3 | con UID 0, la salida es igual a la entrada | ROJO |
| P4 | con `HOME` vacío, `/`, con `:` o con un salto de línea, y con un PATH vacío, la salida es igual a la entrada | ROJO |
| P5 | cargar la librería con `sh` (no bash) y llamar la función funciona, y cargarla no cambia `PATH` ni define variables globales nuevas | ROJO |
| P6 | el directorio se agrega aunque no exista (la función no mira el disco) | ROJO |
| S1 | `start_session`, con `tmux`, `sleep` y los pasos previos como funciones de prueba, crea la sesión con `-e PATH=<PATH>:$HOME/.local/bin`; el texto del comando no cambia y el PATH del supervisor sigue igual después de la llamada | ROJO |
| S2 | sin `agent_path_compose` (función borrada), `start_session` crea la sesión con `-e PATH=<PATH>`, sale con 0 y deja una línea en el log que dice que el directorio no entró | ROJO (hoy no pasa `-e` ni escribe esa línea) |
| H1 | un tick real de `heartbeat.sh` (tmux del host y un `claude` de prueba que vuelca su PATH) corre `claude` con un PATH que termina en `$HOME/.local/bin` y empieza con el PATH del tick | ROJO |
| H2 | con `HEARTBEAT_AGENT_PATH_LIB` apuntando a un archivo inexistente, el tick termina con `status: ok` en `runs.jsonl`, sin errores en stderr, y `claude` recibe el PATH del tick sin cambios | VERDE (nace verde) |
| A1 | `agentctl mcp` graba `exec -u agent <agente> sh -c <script> agentctl-mcp list`; el script carga `/opt/agent-admin/scripts/lib/agent_path.sh` solo si existe y termina en `exec claude mcp "$@"`; `agentctl shell --root` sigue sin `-u agent` y sin el script | ROJO |
| G1 | estructural (FR-004): `docker/Dockerfile` no tiene ninguna instrucción `ENV` que nombre `.local/bin`, leída completa (uniendo las líneas que terminan en `\`), `docker/entrypoint.sh` no nombra `agent_path` ni `.local/bin`, y en `start_services.sh` y `heartbeat.sh` no hay ningún `export PATH` que nombre el directorio | VERDE (nace verde) |
| G2 | estructural: `docker/Dockerfile` copia `scripts/lib/agent_path.sh` a `/opt/agent-admin/scripts/lib/agent_path.sh`, y `start_services.sh`, `heartbeat.sh` y `agentctl` nombran esa misma ruta | ROJO |

13 pruebas: 11 caen contra `origin/main` y 2 nacen verdes (H2 y G1). Las que nacen verdes se prueban con las mutaciones M12 (H2) y M13, M14 y M18 (G1).

**Prueba existente que cambia, justificada**: `tests/agentctl.bats`, «agentctl mcp default delegates to 'claude mcp list'» (`:146-152`). Espera `claude` y `mcp` como argumentos sueltos de `docker exec`, y con C4 esos argumentos viven dentro del script de `sh -c`. Se reescribe para afirmar `-u agent`, `sh`, `-c`, que el script termina en `exec claude mcp "$@"` y que el último argumento es `list`. Su intención (que el valor por defecto sea `list`) se conserva. Ninguna otra prueba existente cambia.

**Esperado de la suite del host**: la línea base medida sobre `origin/main` más 18, con 0 `not ok` en los dos bash. Son las 13 pruebas de este archivo y las 5 de `tests/docker-e2e-user-bin-path.bats`, que en el host salen saltadas (precedente de 041).

## Catálogo de mutaciones

Cada mutación se aplica sobre una copia aislada del árbol, se corre `tests/agent-user-bin-path.bats` (y `tests/agentctl.bats` donde se indica) en los dos bash, y debe caer al menos la prueba nombrada.

| Id | Mutación | Debe caer |
| --- | --- | --- |
| M0 | control: el árbol de `origin/main` | P1 a P6, S1, S2, H1, A1 y G2 |
| M1 | el directorio se agrega al inicio y no al final | P1, H1, S1 |
| M2 | sin la comprobación de idempotencia | P2 |
| M3 | sin la guarda de UID 0 | P3 |
| M4 | sin la guarda de `HOME` (vacío, `/`, `:`) | P4 |
| M5 | sin la guarda de PATH vacío | P4 |
| M6 | la librería hace `export PATH=...` al cargarse | P5 |
| M7 | la función usa una construcción solo de bash (`[[ ]]`) | P5 (con `sh` de dash o BusyBox; en el Mac `/bin/sh` es bash, así que la mutación se registra como equivalente ahí y se prueba en la pata Linux) |
| M8 | la función comprueba que el directorio exista | P6 |
| M9 | `start_session` sin `-e` | S1 |
| M10 | `start_session` con `export PATH=...` en lugar de `-e` | S1 (el PATH del supervisor cambió) |
| M11 | `start_session` llama la función sin la guarda `command -v` | S2 |
| M12 | `heartbeat.sh` carga la librería sin la guarda `[ -f ]` y sin el respaldo `"$PATH"` | H2 |
| M13 | el Dockerfile agrega `ENV PATH=$PATH:/home/agent/.local/bin` | G1 |
| M14 | `entrypoint.sh` carga la librería y exporta el PATH | G1 |
| M15 | el Dockerfile sin la línea `COPY` de la librería | G2 |
| M16 | `heartbeat.sh` sin `-e` | H1 |
| M17 | `agentctl mcp` vuelve a `docker exec -u agent <agente> claude mcp` | A1 |
| M18 | el Dockerfile agrega `PATH=$PATH:/home/agent/.local/bin` como línea de continuación del `ENV` multilínea de `:126` | G1 |

**Pata Linux**: P5 y M7 corren también en `ubuntu:24.04` (dash como `sh`), como no root, con el repo copiado y no montado (lección de 039).
