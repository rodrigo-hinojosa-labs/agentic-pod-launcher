# Feature Specification: Los hooks de claude-mem 15.x encuentran su lanzador en los agentes docker

**Feature Branch**: `045-plugin-launcher-path`

**Created**: 2026-11-11

**Status**: Draft

**Input**: Hallazgo del alta de CBum (11-11-2026). claude-mem 15.16.0 declara sus hooks en forma exec (`"command": "claude-mem"`, sin shell) y deja su lanzador en `$HOME/.local/bin`, un directorio que no está en el PATH de ningún proceso del contenedor. Cada hook falla en cada prompt y claude-mem no captura nada. CBum funciona hoy con un enlace manual que se pierde al recrear el contenedor. El operador decidió (11-11-2026) aplicar el parche en ese momento y abrir el arreglo de fondo como la feature 045. Es un arreglo de producto en código horneado en la imagen: lleva DOCKER_E2E, CHANGELOG y bump de `VERSION`.

## Contexto

**El defecto, medido (ferrari, 11-11-2026).** El `hooks.json` de claude-mem 15.16.0 en cbum declara ocho eventos con `"command": "claude-mem"` y `args`, sin campo `shell`:

- `SessionStart`: `start` y `hook claude-code context`;
- `UserPromptSubmit`, `PreToolUse`, `PostToolUse` y `PostToolUseFailure`;
- `Stop`, `SubagentStop` y `SessionEnd`.

El mismo `SessionStart` corre `node ${CLAUDE_PLUGIN_ROOT}/scripts/ensure-launcher.cjs`, que instala el lanzador `claude-mem` en `/home/agent/.local/bin`. Ese lanzador es un ELF musl de 101.653.608 bytes que corre en Alpine, y queda dentro del bind-mount `.state/`, así que sobrevive a un rebuild. El PATH que ven los procesos del agente es el de la imagen, `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`. Se midió en un `docker exec -u agent`, en el entorno global de tmux y en el pane de la sesión, en donna, linus y cbum. Ese PATH no incluye `/home/agent/.local/bin`, así que cada hook falla con `Executable not found in $PATH: "claude-mem"` (no bloqueante) y claude-mem no registra nada. El transcript de la sesión guarda cada falla como un registro `hook_non_blocking_error`.

**Por qué el directorio no está en el PATH (leído en código).** La feature 036 lo dejó fuera a propósito. Movió los enlaces de uv a `/opt/uv/bin` porque los enlaces colgantes en `~/.local/bin`, que sobreviven a un rebuild, bloqueaban `uv tool install`, y anotó que el PATH no se amplía porque un directorio nuevo ahí "no tenía consumidor" (`docker/Dockerfile:118-125`). claude-mem 15.x es ese consumidor. La poda `mcp_warm_prune_stale_links` borra en cada arranque los enlaces de uv que quedaron colgando en `~/.local/bin` (`scripts/lib/mcp_warm.sh:150-182`, llamada en `docker/scripts/start_services.sh:837`).

**Quién está afectado hoy (medido).**

- **cbum** (claude-mem 15.16.0): afectado. Funciona con el parche manual `docker exec -u root cbum ln -s /home/agent/.local/bin/claude-mem /usr/local/bin/claude-mem` más `heartbeatctl kick-channel`, aplicado el 11-11-2026 y rehecho tras la actualización de flota de ese día. El enlace vive en la capa del contenedor y se pierde cada vez que este se recrea.
- **donna** (13.13.1) y **linus** (13.14.0): no afectados. Sus hooks son de shell y anteponen `export PATH="$($SHELL -lc 'echo $PATH' 2>/dev/null):$PATH"`. Caerán igual cuando su claude-mem suba a 15.x, y eso podría pasar sin que nadie lo decida si claude-mem se actualiza solo (inferido, ver la tabla).
- **Modo local** (ferrari-admin, mclaren-admin): no afectado (leído en código). `modules/remote-control.env.tpl:13` pone `{{OPERATOR_HOME}}/.local/bin` primero en el PATH de la sesión systemd, con `HOME` igual al home del operador (`:8`).

**Dónde corre `claude` en docker (leído en código).**

- La sesión interactiva en tmux que lanza `docker/scripts/start_services.sh` (`start_session`, `:842`; `tmux new-session`, `:865`), con sus tres variantes: el `claude` sin canal para el `/login`, el wizard del token y la sesión con canales (`next_tmux_cmd`, `:668-697`). El watchdog la respawnea cuando muere.
- Los ticks del heartbeat: `scripts/heartbeat/heartbeat.sh:216` abre un `tmux new-session` con `claude --print` desde un job de busybox `crond`, con un `CLAUDE_CONFIG_DIR` aislado que enlaza los plugins, así que los hooks de claude-mem también corren ahí. Hoy el heartbeat está desactivado en los tres agentes.
- `agentctl mcp`, que corre `docker exec -u agent <agente> claude mcp` (`scripts/agentctl:966`), y, fuera de lo que lanza el producto, `agentctl run` (`:918-927`), `agentctl shell` y cualquier `docker exec -u agent` manual.

**Una restricción de seguridad que el arreglo no puede romper (Principio II).** El entrypoint, el bucle de sincronización del crontab y `crond` corren como root (`docker/entrypoint.sh:64-108`); `start_services.sh` corre como `agent` tras `su-exec` (`:118`). `/home/agent/.local/bin` lo puede escribir el usuario `agent`. Si un proceso root tuviera ese directorio en su PATH y resolviera un nombre que la imagen no trae, ejecutaría como root algo que `agent` plantó ahí (inferido por razonamiento, sin medir). El arreglo no debe abrir esa vía.

### Estado de cada afirmación

| Afirmación | Estado | Fuente |
| --- | --- | --- |
| claude-mem 15.16.0 declara ocho eventos con `"command": "claude-mem"` en forma exec, sin shell, y un `SessionStart` con `node .../ensure-launcher.cjs` | Medido (cbum, 11-11-2026) | `hooks.json` de 15.16.0 en el caché de plugins de cbum |
| `ensure-launcher.cjs` deja un ELF musl de 101.653.608 bytes en `/home/agent/.local/bin/claude-mem` | Medido (cbum) | listado de `~/.local/bin` |
| El PATH de `docker exec -u agent`, del entorno global de tmux y del pane de la sesión es el de la imagen, sin `~/.local/bin` | Medido (donna, linus y cbum) | sonda de solo lectura del 11-11-2026 |
| Cada hook falla con `Executable not found in $PATH: "claude-mem"` mientras no exista el enlace manual | Medido: el transcript de la sesión de cbum guarda 3 registros `hook_non_blocking_error` con ese texto, de `SessionStart`, `UserPromptSubmit` y `PreToolUse`, entre las 04:39 y las 04:49 UTC del 11-11-2026, antes del parche. `claude.log` no sirve para contarlos: no tiene saltos de línea y se reinicia con el contenedor | transcript de cbum (`~/.claude/projects/-workspace/*.jsonl`), leyendo solo los campos del registro, no la conversación |
| Con el enlace manual, el worker de claude-mem corre, y ese enlace es el único `claude-mem` en los directorios del PATH de la imagen | Medido (cbum, 11-11-2026) | sonda de solo lectura: `ps` y búsqueda en los seis directorios del PATH |
| claude-mem escribe su almacén en `~/.claude-mem/claude-mem.db` y su `-wal` | Medido (metadatos): el `-wal` tiene fecha de 03:49 del 11-11-2026, la hora del reinicio de la actualización de flota | listado de `~/.claude-mem` |
| claude-mem guarda un estado de autoactualización, así que donna y linus podrían pasar a 15.x sin que nadie lo decida | Inferido (existe `~/.claude-mem/auto-update-state.json` en cbum; no se leyó su contenido ni la política del vendor) | listado de `~/.claude-mem` |
| Los hooks de claude-mem 13.13.1 y 13.14.0 arman su propio PATH en un shell | Medido (donna y linus) | `hooks.json` de cada versión |
| `~/.local/bin` está vacío en donna y linus y solo tiene `claude-mem` en cbum | Medido | listado del 11-11-2026 |
| La imagen deja `~/.local/bin` fuera del PATH a propósito (036) | Leído en código | `docker/Dockerfile:118-125` |
| La poda de enlaces colgantes de uv corre en cada arranque | Leído en código | `scripts/lib/mcp_warm.sh:150-182`; `start_services.sh:837` |
| El modo local ya pone `~/.local/bin` del operador primero en el PATH, con su `HOME` | Leído en código | `modules/remote-control.env.tpl:8,13` |
| El heartbeat lanza `claude` en un `tmux new-session` desde un job de `crond`, con los plugins enlazados | Leído en código | `scripts/heartbeat/heartbeat.sh:216`; `docker/entrypoint.sh:105-108` |
| El heartbeat está desactivado en los tres agentes | Medido (`features.heartbeat.enabled: false`) | `agent.yml` de donna, linus y cbum |
| El entrypoint, el bucle del crontab y `crond` corren como root; la sesión, como `agent` | Leído en código | `docker/entrypoint.sh:64-108,118` |
| Un job de busybox `crond` hereda el PATH de `crond` | Medido en la Fase 0 del plan: hereda todo el entorno de `crond` (que es root) y `crond` solo fija `HOME`, `USER`, `LOGNAME` y `SHELL` | `research.md` M1 (BusyBox 1.37.0) |
| Una sesión tmux nueva hereda el entorno global del servidor tmux del agente | **Refutado**: en tmux 3.6b la sesión toma el PATH del cliente que la crea, no el del servidor; `new-session -e` lo fija de forma explícita | `research.md` M2 a M4 |
| `_run_watchdog` está congelado por un oráculo de sha | Leído en código | `tests/start-services-watchdog.bats:587` |
| En la primera sesión tras instalar claude-mem 15.x, `claude-mem start` corre antes que `ensure-launcher.cjs` | Leído (orden del `SessionStart` en `hooks.json`); la consecuencia es inferida | `hooks.json` de 15.16.0 |
| Un proceso root con `~/.local/bin` en su PATH podría ejecutar un binario plantado por `agent` | Inferido por razonamiento, sin medir; el diseño lo evita, y el e2e lo verifica en el entorno que Docker entrega al contenedor (`docker inspect`), sin entrar como root | Principio II; `contracts/e2e-and-gate.md` E5 |
| El servidor MCP de claude-mem 15.16.0 se lanza con `node`, no con el lanzador | Leído en el repositorio público del vendor | `plugin/.mcp.json` de la etiqueta `v15.16.0`; `research.md` M6 |

## Clarifications

### Session 2026-11-11

- Q: ¿El arreglo es general o acotado a claude-mem? → A: General. `/home/agent/.local/bin` entra al final del PATH de los procesos del agente y cubre cualquier ejecutable que un plugin instale ahí. Nunca entra al PATH de root (FR-001, FR-003 y FR-004).
- Q: ¿Qué evidencia hace falta antes del merge? → A: El DOCKER_E2E local en arm64 y un gate en cbum con la imagen de la rama, sin el enlace manual, antes del merge, como el gate de hardware de 024. No se pide una corrida manual de CI. El rebuild de cbum lleva COMPUERTA (FR-011).

### Session 2026-11-11 (análisis)

- Q: El análisis encontró 1 CRITICAL, 2 HIGH, 7 MEDIUM y 6 LOW. ¿Qué se corrige antes de implementar? → A: Todo, incluidos los LOW.
- Q: La prueba E5 leía el entorno de los procesos root con `docker exec -u root`, que el Principio II prohíbe. ¿Cómo se verifica FR-004? → A: Con `docker inspect` (el entorno que Docker entrega al contenedor y del que heredan los procesos root) y con la guardia G1 sobre el código, sin ningún `docker exec -u root`.
- Q: SC-001 buscaba un texto que no coincide con el error real y en un log que no sirve para contarlo. ¿Cómo se mide? → A: En el transcript de la sesión, contando los registros `hook_non_blocking_error` con `Executable not found in $PATH: "claude-mem"` posteriores al reinicio. Los 3 registros que ya existen son el control positivo.
- Q: FR-001 decía "el PATH de los procesos del agente", y el diseño solo cubre las sesiones de `claude` que crea el producto y `agentctl mcp`. ¿Cuál es el alcance? → A: El del diseño. `agentctl run`, `agentctl shell` y un `docker exec -u agent` manual quedan fuera y documentados (FR-001 y FR-002).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Los hooks de claude-mem 15.x corren sin intervención manual (Priority: P1)

En un agente docker con claude-mem 15.x, cada hook que invoca `claude-mem` por nombre lo encuentra, en cada contexto donde el producto corre `claude`. No hace falta crear enlaces a mano ni repetirlos después de recrear el contenedor.

**Why this priority**: Es el defecto. Hoy claude-mem no registra nada en un agente nuevo, y el único parche es manual, necesita root y se pierde en cada recreación. Todo agente que instale o actualice claude-mem a 15.x cae igual.

**Independent Test**: En un contenedor construido desde la rama, sin login, se coloca un ejecutable de prueba en `/home/agent/.local/bin` con un nombre que la imagen no trae, y se verifica que se resuelve por nombre, sin shell, desde cada contexto que el arnés puede reproducir. La prueba real con claude-mem necesita un agente con login: cbum, en el gate previo al merge, con la imagen de la rama y sin el enlace manual.

**Acceptance Scenarios**:

1. **Given** un agente docker con claude-mem 15.x y su lanzador ya instalado, **When** el operador envía un prompt en la sesión interactiva, **Then** los hooks `UserPromptSubmit`, `PreToolUse`, `PostToolUse` y `Stop` corren sin el error `Executable not found in $PATH`.
2. **Given** la sesión interactiva respawneada por el watchdog, **When** arranca, **Then** el `SessionStart` de claude-mem corre sin ese error.
3. **Given** un agente con el heartbeat activado, **When** corre un tick, **Then** los hooks de claude-mem del tick encuentran el lanzador.
4. **Given** un contenedor recreado (rebuild, `docker compose up` tras un stop), **When** arranca, **Then** los hooks siguen funcionando sin volver a crear ningún enlace.

---

### User Story 2 - El arreglo no sombrea nada ni abre una vía hacia root (Priority: P1)

Los binarios de la imagen siguen ganando sobre cualquier cosa del estado persistente, ningún proceso root resuelve ejecutables desde un directorio que `agent` puede escribir, y el modo local y los agentes con claude-mem 13.x se comportan igual que hoy.

**Why this priority**: El directorio en cuestión vive en el bind-mount, sobrevive a los rebuilds y lo puede escribir el agente. 036 ya pagó una caída de 25 minutos por enlaces colgantes ahí. Si el arreglo dejara que algo de ese directorio sombreara un binario de la imagen, o que corriera como root, abriría un defecto peor que el que cierra. Vale tanto como el arreglo.

**Independent Test**: En el contenedor real, un señuelo con el nombre de un binario de la imagen colocado en `/home/agent/.local/bin` no gana, y se inspecciona el entorno que Docker entrega al contenedor (`docker inspect`), del que heredan los procesos root, para confirmar que no tiene el directorio. No hace falta entrar como root (Principio II). En el host, el render del modo local queda byte-idéntico.

**Acceptance Scenarios**:

1. **Given** un ejecutable en `/home/agent/.local/bin` con el mismo nombre que uno de la imagen (por ejemplo `node`), **When** un proceso del agente lo invoca por nombre, **Then** corre el de la imagen.
2. **Given** el contenedor arrancado, **When** se inspecciona el entorno que Docker le entrega, del que heredan el entrypoint, el bucle de sincronización del crontab y `crond`, y el código confirma que el entrypoint no cambia el PATH, **Then** ninguno tiene `/home/agent/.local/bin` en su PATH.
3. **Given** un enlace colgante en `/home/agent/.local/bin` que apunta a `/opt/uv/tools`, **When** arranca el contenedor, **Then** la poda de 036 lo borra igual que hoy y `uv tool install` no se bloquea.
4. **Given** un agente en modo local, **When** se regenera con el mismo `agent.yml`, **Then** sus artefactos renderizados son byte-idénticos a los de `origin/main`.
5. **Given** un agente con claude-mem 13.x, **When** corre una sesión después del despliegue, **Then** sus hooks funcionan igual que hoy (se observa después del merge, FR-007).

---

### User Story 3 - La corrección se demuestra y llega a la flota (Priority: P2)

Las pruebas nuevas que cubren el arreglo caen contra el código actual; las que guardan lo que no cambia nacen verdes, y las mutaciones prueban que pueden fallar. Todas pasan con el arreglo, en el host, y el contrato se confirma en un contenedor real. La evidencia de cierre muestra claude-mem 15.x funcionando en un agente real sin el parche manual.

**Why this priority**: Sin el ROJO visto antes del VERDE no se sabe si las pruebas podían fallar (Principio III). Sin un agente real con login, el e2e solo prueba que el nombre se resuelve, no que claude-mem capture algo.

**Independent Test**: El oráculo del host corre en bash 3.2 y en 5.x contra `origin/main` (ROJO) y contra la rama (VERDE). El DOCKER_E2E corre entero. La verificación en cbum cuenta los errores de hook y confirma que claude-mem registró la sesión.

**Acceptance Scenarios**:

1. **Given** el código actual, **When** corre el oráculo nuevo, **Then** caen las 11 pruebas que cubren el arreglo y pasan las 2 que guardan lo que no cambia.
2. **Given** el código con el arreglo, **When** corre el oráculo en bash 3.2 y en 5.x, **Then** pasan todas, y cada mutación del catálogo hace caer al menos una.
3. **Given** cbum, antes del merge, con la imagen de la rama y sin el enlace manual, **When** se reinicia y se envían tres prompts, **Then** el transcript no tiene ningún registro `hook_non_blocking_error` con `Executable not found in $PATH: "claude-mem"` posterior al reinicio, y claude-mem registra la sesión.

---

### Edge Cases

- **La primera sesión tras instalar claude-mem 15.x.** El `SessionStart` corre `claude-mem start` y `hook claude-code context` antes que `ensure-launcher.cjs`, así que en esa sesión los dos primeros hooks pueden fallar aunque el PATH esté bien. Los hooks siguientes de la misma sesión deberían encontrar el lanzador, porque el PATH se resuelve en cada ejecución (inferido). Es comportamiento del vendor: se declara, no se arregla.
- **Un enlace colgante en `~/.local/bin`** que no apunta a `/opt/uv/tools` (la poda no lo toca): un nombre que solo existe ahí y no resuelve falla igual que hoy. No hay regresión.
- **Un ejecutable de un plugin con el nombre de uno de la imagen**: gana el de la imagen (FR-003). Un plugin que necesite su propia versión de un binario de la imagen no la obtiene, y queda declarado.
- **Un binario glibc instalado por un plugin en `~/.local/bin`**: no corre en Alpine, igual que hoy con el enlace manual. Fuera de alcance.
- **Un rebuild de cbum con una imagen sin 045** (por ejemplo, la respaldada, si el gate falla y se revierte): el enlace manual se pierde con el contenedor y los hooks vuelven a fallar, sin bloquear. Rehacer el enlace exige `docker exec -u root`, fuera del Principio II, y solo se hace con la autorización explícita del operador (el procedimiento está en la ficha de cbum).
- **Un `docker exec -u agent` manual, `agentctl run` o `agentctl shell`**: heredan el entorno de la imagen, no el de la sesión, y no se cubren (FR-002). La documentación dice cómo agregar el directorio a mano.
- **Un `docker exec -u root`**: el producto no lo usa para escribir archivos del agente (Principio II), y no debe recibir el directorio en su PATH.
- **Un workspace que se migra entre hosts**: `~/.local/bin` viaja dentro de `.state/` con lo que los plugins instalaron.
- **Agentes desplegados con una imagen anterior**: siguen con el defecto hasta reconstruirla. El arreglo llega con el upgrade normal y no migra datos.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: En un agente docker, `/home/agent/.local/bin` entra al final del PATH de las sesiones de `claude` que crea el producto y de `agentctl mcp` (FR-002). Así, un hook que invoca por nombre, sin shell, un ejecutable que un plugin instaló ahí lo encuentra. Hoy ese ejecutable es el lanzador de claude-mem 15.x. El arreglo es general: no depende del nombre del ejecutable ni mantiene una lista.
- **FR-002**: El arreglo cubre todos los contextos en que el producto corre `claude` como `agent`:
  - la sesión interactiva en tmux y sus respawns del watchdog;
  - la sesión sin canal del `/login` y el wizard del token;
  - los ticks del heartbeat;
  - los subcomandos de `agentctl` que corren `claude` dentro del contenedor (hoy, `agentctl mcp`).

  `agentctl run`, `agentctl shell` y un `docker exec -u agent` manual no se cubren. Con el diseño elegido (`research.md` D1 y D3), cubrirlos exigiría un `ENV PATH` de imagen, y eso violaría FR-004. La documentación dice cómo agregar el directorio a mano.
- **FR-003**: Ningún ejecutable de la imagen queda sombreado. Si un nombre existe en la imagen y en `/home/agent/.local/bin`, gana el de la imagen.
- **FR-004**: Ningún proceso que corre como root en el contenedor (el entrypoint, el bucle de sincronización del crontab, `crond` y un `docker exec -u root`) resuelve ejecutables desde un directorio que `agent` puede escribir.
- **FR-005**: Nada más cambia:
  - el modelo de privilegios del contenedor: `cap_drop`, `cap_add`, `no-new-privileges`, `docker-compose.yml.tpl` y los bind-mounts (Principio II);
  - `UV_TOOL_BIN_DIR=/opt/uv/bin` y la poda `mcp_warm_prune_stale_links`;
  - `_run_watchdog`, cuyo oráculo de sha debe seguir en verde.
- **FR-006**: El modo local no cambia. Sus artefactos renderizados quedan byte-idénticos para el mismo `agent.yml`.
- **FR-007**: Los agentes con claude-mem 13.x se comportan igual: sus hooks, que arman su propio PATH, siguen funcionando. Se verifica después del merge (SC-005), porque no hay un agente con claude-mem 13.x y sesión iniciada en el que probarlo antes. Lo respalda un razonamiento: agregar un directorio al final del PATH no cambia la resolución de ningún nombre que ya se encontraba antes.
- **FR-008**: El parche manual de cbum queda innecesario. Tras reconstruir la imagen y recrear el contenedor, los hooks corren sin el enlace en `/usr/local/bin`, y la ficha de cbum y la documentación que lo describen pasan a decir que se retiró.
- **FR-009**: El oráculo del host es test-first y corre sin Docker. Las pruebas que cubren el arreglo caen contra `origin/main`; las que guardan lo que no cambia nacen verdes. Todas pasan con el arreglo, en bash 3.2 y en 5.x. Lo acompaña un catálogo de mutaciones en que cada prueba nueva cae al menos una vez.
- **FR-010**: Un contenedor real construido desde la rama confirma el contrato en cada contexto de FR-002 que el arnés puede reproducir sin login:
  - un ejecutable de prueba colocado en `/home/agent/.local/bin` se resuelve por nombre, sin shell;
  - un señuelo con el nombre de un binario de la imagen no gana;
  - el entorno que Docker entrega al contenedor, del que heredan los procesos root, no tiene el directorio. Se lee con `docker inspect`, sin entrar como root.

  El DOCKER_E2E pasa entero, porque el cambio está en código horneado.
- **FR-011**: Antes del merge hacen falta dos evidencias, en este orden:
  1. el DOCKER_E2E local en arm64, con COMPUERTA;
  2. un gate en cbum: se respalda su imagen actual, se reconstruye desde la rama, se recrea el contenedor sin el enlace manual (stop, 150 s, up; COMPUERTA) y se mide SC-001. Si el gate falla, cbum vuelve a su imagen respaldada. Rehacer el enlace manual exige `docker exec -u root` y solo se hace con la autorización explícita del operador.

  No se pide una corrida manual de CI: el PATH no depende de la arquitectura, y la nocturna posterior al merge cubre amd64. Del gate se registra:
  - el commit de la rama y el identificador de la imagen;
  - la cantidad de errores de hook de claude-mem en la sesión medida, con el método de SC-001;
  - la evidencia de que claude-mem registró esa sesión;
  - los reinicios del contenedor y el estado del canal.
- **FR-012**: El CHANGELOG describe el arreglo y su evidencia, y `VERSION` sube con un bump MINOR, de 0.30.0 a 0.31.0, verificado a mano contra `origin/main` antes de subirlo y después de cualquier rebase.
- **FR-013**: La documentación describe el estado nuevo:
  - el comentario de 036 en `docker/Dockerfile`, cuyo motivo ("sin consumidor") deja de ser cierto;
  - `docs/architecture.md`, en el modelo de privilegios: la invariante de 045 y cómo agregar el directorio en un `docker exec` manual;
  - el bloque de la feature en `CLAUDE.md`, escrito a mano como en 041 a 044.

### Key Entities

- **Directorio de binarios del usuario agente**: `/home/agent/.local/bin`, dentro del bind-mount `.state/`. Lo escribe `agent`, sobrevive a los rebuilds y es donde claude-mem 15.x instala su lanzador.
- **Lanzador de claude-mem**: el ejecutable `claude-mem` que instala `ensure-launcher.cjs` y que invocan por nombre los hooks de 15.x.
- **Contexto de ejecución**: cada proceso en que el producto corre `claude` dentro del contenedor (FR-002), con su propio entorno heredado.
- **Proceso root del contenedor**: el entrypoint, el bucle de sincronización del crontab, `crond` y cualquier `docker exec -u root`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En el gate previo al merge (FR-011), en cbum con claude-mem 15.16.0, la imagen de la rama y sin el enlace manual, tras el reinicio y tres prompts, el transcript de la sesión tiene 0 registros `hook_non_blocking_error` con `Executable not found in $PATH: "claude-mem"` y hora posterior al reinicio. El mismo conteo sin el filtro de hora encuentra los 3 registros del 11-11-2026 anteriores al parche: es el control positivo de que el método ve el error. Además, claude-mem registra la sesión: su worker sigue vivo y `~/.claude-mem/claude-mem.db-wal` cambia de fecha o de tamaño después de los prompts.
- **SC-002**: En el contenedor real, el ejecutable de prueba se resuelve en el 100 % de los contextos de FR-002 que el arnés puede reproducir, el señuelo no gana en ninguno y el entorno que Docker entrega al contenedor no tiene el directorio.
- **SC-003**: La suite del host da la línea base medida más las pruebas nuevas, con 0 `not ok` en bash 3.2 y en 5.x. Las 11 pruebas que cubren el arreglo caen contra `origin/main`, las 2 que nacen verdes caen con sus mutaciones, el catálogo de mutaciones cae entero en los dos bash y `shellcheck` queda limpio. El DOCKER_E2E pasa entero.
- **SC-004**: El render del modo local entre `origin/main` y la rama, para el mismo `agent.yml`, tiene 0 bytes de diferencia.
- **SC-005**: Tras el despliegue posterior al merge, que hace el operador, donna y linus (claude-mem 13.x) y cbum (15.16.0) tienen 0 errores de hook nuevos y 0 reinicios atribuibles al cambio en sus primeras 24 h, y cbum sigue sin el enlace manual.

## Assumptions

- claude-mem 15.x sigue instalando su lanzador en `$HOME/.local/bin`, como se midió en 15.16.0. Si el vendor cambia de directorio, la feature se revisa.
- Es un arreglo de producto, así que sigue la práctica de 017, 018, 023, 024, 026, 042 y 044: bump MINOR (0.30.0 a 0.31.0) y CHANGELOG. Es un default declarado, reversible antes del PR.
- El DOCKER_E2E local corre en el Mac del operador (arm64), con COMPUERTA. Las mediciones en contenedores desechables `--rm` de unos minutos, con imágenes base en caché, no llevan COMPUERTA y se avisan antes de empezar, como en 043 y 044.
- El e2e no puede iniciar sesión en Claude, así que no ejecuta hooks reales de claude-mem. Prueba la resolución del nombre en cada contexto. La prueba con claude-mem real solo es posible en un agente con login.
- El heartbeat está desactivado en los tres agentes de hoy, pero el contrato lo cubre porque cualquier agente puede activarlo.
- El wizard del token no se ejecuta en el e2e, porque requiere sesión iniciada. Lo cubre la prueba S1 del host: el wizard es uno de los comandos de la misma línea `tmux new-session` de `start_session`.
- El oráculo test-first es el del host. El e2e se escribe después del arreglo y es la confirmación en un contenedor real, como el DOCKER_E2E de 044.
- El gate de cbum es el único despliegue antes del merge. Respalda la imagen actual como `agentic-pod:cbum-pre045` y lleva COMPUERTA. donna y linus se reconstruyen después del merge, con el mismo reinicio (stop, 150 s, up) y su propio respaldo.
- El merge es del operador, y no se propone antes de que el gate de cbum pase.

## Out of Scope

- Cambiar claude-mem o el orden de sus hooks de `SessionStart`: es código del vendor.
- El modo local (FR-006).
- Un chequeo en `agentctl doctor` que detecte hooks cuyo ejecutable no se resuelve. Puede ser una feature aparte.
- Actualizar claude-mem a 15.x en donna y linus.
- Poner el directorio del usuario antes que los de la imagen, o en el PATH de root.
- Una corrida manual del workflow `docker-e2e` en CI antes del PR (decisión del 11-11-2026, FR-011).
- tree-sitter, #111, #117 y #120.
