---

description: "Tareas de 045-plugin-launcher-path: los hooks de claude-mem 15.x encuentran su lanzador en los agentes docker"
---

# Tasks: Los hooks de claude-mem 15.x encuentran su lanzador en los agentes docker

**Input**: `specs/045-plugin-launcher-path/` ([spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [quickstart.md](quickstart.md), [contracts/](contracts/))

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: obligatorios y primero (Principio III; FR-009). Son las 13 pruebas de `contracts/host-oracle.md`, en `tests/agent-user-bin-path.bats`, más la prueba de `agentctl mcp` reescrita en `tests/agentctl.bats`:

- **Once caen contra el código actual**: P1 a P6, S1, S2, H1, A1 y G2. Se escriben y se ven en ROJO antes del arreglo (US1).
- **Dos nacen verdes a propósito**: H2 y G1. Guardan el fail-silent del heartbeat y la exclusión de root. El catálogo de mutaciones prueba que pueden fallar.

El catálogo es el control M0 más 18 mutaciones (M1 a M18), en bash 5.x y 3.2 en el host, y P5 y M7 otra vez en una pata Linux con dash como `sh` (SC-003).

**Organization**: por **dependencia** sobre los mismos archivos, no por prioridad (precedente de 040 a 044):

```text
Setup -> Foundational (esqueleto del oráculo) -> US1 (P1, el arreglo) -> US2 (P1, lo que no cambia)
      -> Polish (documentos) -> US3 (P2, evidencia y gate en cbum) -> Cierre
```

- **US1** escribe las once pruebas que caen, registra el ROJO y aplica el arreglo: la librería `agent_path.sh`, el `-e PATH` de `start_session` y del heartbeat, `agentctl mcp` y la línea `COPY`.
- **US2** agrega H2 y G1, que nacen verdes, y comprueba que ninguna otra prueba existente cambia ni cae, que el modo local queda intacto y que `shellcheck` pasa.
- **Polish** escribe el comentario del Dockerfile, `docs/architecture.md`, CHANGELOG, `VERSION` y `CLAUDE.md` antes de la evidencia, porque la revisión independiente y los commits los incluyen.
- **US3** es la evidencia. Incluye las mutaciones, la pata Linux, el e2e nuevo, el DOCKER_E2E entero, la revisión independiente, el gate completo, los commits, el push, el gate en cbum y el PR.

**Orden de la evidencia**: el DOCKER_E2E (T030) va **antes** del gate completo del host (T032), como en 043 y 044. Un defecto que aparezca en el contenedor obliga a editar y a repetir el gate, que cuesta unos 25 minutos por bash. Con este orden, el gate corre una sola vez sobre el árbol final, y su huella sha256 se compara con la del DOCKER_E2E. El gate en cbum (T035) va después del push, porque reconstruye la imagen en ferrari desde la rama publicada.

**Compuertas**:

- **Qué la lleva**: cada commit, push, creación o borrado de una rama remota, PR y merge exige la confirmación explícita del operador, CADA VEZ, y está marcado COMPUERTA. También la llevan el DOCKER_E2E local (T030), el gate en cbum (T035), el despliegue de donna y linus (T038) y toda escritura en Confluence (T039).
- **Qué no la lleva**: las mediciones en contenedores desechables `--rm` de unos minutos con imágenes ya en caché (T004 y T028). Se avisa antes de empezar.
- **Reglas fijas**:
  - nada se commitea antes de T002, y no hay hooks que ejecutar (`.specify/extensions.yml` tiene `hooks: {}`);
  - no se tocan los worktrees de 041 a 044, ni los contenedores o las imágenes del operador que no sean de las pruebas;
  - todo `docker exec` en un contenedor de agente lleva `-u agent` (Principio II), sin excepciones. E5 lee el entorno de root con `docker inspect`. El rollback del gate en cbum no rehace el enlace manual (que exige `-u root`) sin la autorización explícita del operador;
  - el merge es siempre del operador, y no se propone antes de que pase el gate en cbum (FR-011).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: se puede hacer en paralelo (archivos distintos, sin dependencia de una tarea abierta).
- **[Story]**: la historia del spec a la que sirve la tarea (US1 a US3).
- Las rutas son relativas a la raíz del worktree `.claude/worktrees/045-plugin-launcher-path`.
- `<scratchpad>` es `/private/tmp/claude-501/-Users-rodrigo-hinojosa-Documents-Cencosud-Claude-Agents-agentic-pod-launcher/39e5ee01-c1c3-454a-ba47-6d398dabb108/scratchpad`. Se borra entre sesiones, así que lo que deba durar va a la memoria o a este archivo. Las herramientas de medición viven en `<scratchpad>/045/` y no se versionan; la auditoría de bytes es `<scratchpad>/tools/byte_audit_files.py`.
- En el Mac, `bats`, `yq`, `gh`, `gpg` y `tmux` necesitan `/opt/homebrew/bin` en el PATH.
- Ferrari se alcanza por `ssh ssh-ferrari` (Cloudflare Access, de vuelta el 11-11-2026 tras reautenticar) o por la LAN (`ssh rodrigo-hinojosa@192.168.1.200`), que sirvió mientras la otra ruta no pasaba del banner.
- Las líneas citadas son las de `origin/main` `c242c31`.

---

## Phase 1: Setup

**Purpose**: fijar el punto de partida, commitear los artefactos y medir la línea base.

- [X] T001 Verificar, solo con lecturas, y registrar en el Registro de este archivo:
  - **El remoto**: `origin/main` sigue en `c242c31` (por el camino HTTPS con el ayudante de `gh`, como en T001 de 044, porque el remoto `origin` es SSH y la clave de este Mac resuelve a otra cuenta). `git show origin/main:VERSION` da 0.30.0. Si `main` se movió, leer `git log --stat c242c31..origin/main` y ver si toca algún archivo de esta feature.
  - **Los PR abiertos** (`gh pr list --state open`) y si alguno toca esos archivos.
  - **El estado local**: `git status --short` muestra solo `.specify/feature.json` modificado y `specs/045-plugin-launcher-path/` sin rastrear.
  - **Las anclas del arreglo**:
    - `docker/scripts/start_services.sh:865` es la única línea `tmux new-session -d -s "$SESSION" -c "$WORKDIR" "$cmd"`;
    - `scripts/heartbeat/heartbeat.sh:216-217` es la única llamada `tmux new-session` del archivo;
    - `scripts/agentctl:966` es `exec docker exec -u agent "$agent" claude mcp "${@:-list}"`;
    - las líneas `COPY scripts/lib/...` de `docker/Dockerfile:258-268` y el comentario de 036 en `:118-125`;
    - la prueba de `tests/agentctl.bats:146-152`;
    - en `docker/Dockerfile`, `docker/entrypoint.sh`, `docker/scripts/start_services.sh` y `scripts/heartbeat/heartbeat.sh`, ninguna línea `ENV`, `export PATH` ni `PATH=` agrega `.local/bin`. Las menciones de `.local/bin` son comentarios (`docker/Dockerfile:119,124,156`) y la poda de `start_services.sh:837`.
  - **Los archivos de ignorar** (paso de `/speckit-implement`): `.gitignore` y `docker/.dockerignore` (si existe) cubren lo que importa. No se agregan patrones: la feature solo agrega un `.sh` y dos `.bats`.
  - **La identidad de los commits**: la misma que en 043 y 044 (T001 de `specs/044-qmd-lock-fd-leak/tasks.md`), por variables de entorno, porque el `user.email` del repo es otro.
- [ ] T002 COMPUERTA (commit local): commitear `specs/045-plugin-launcher-path/**` y `.specify/feature.json`.
  - **Antes**: `python3 -I <scratchpad>/tools/byte_audit_files.py` sobre cada archivo de `specs/045-plugin-launcher-path/`, con 0 hallazgos. Tras el `git add`, comprobar con `git ls-files -s` que los modos son 100644.
  - **El mensaje**: en español, en imperativo y sin atribución, con la identidad de T001. Por ejemplo, `docs: agrega los artefactos de spec-kit de 045 (claude-mem 15.x sin su lanzador en el PATH)`.
  - Sin push.
- [ ] T003 Medir la línea base de la suite del host en una copia aislada de `origin/main`:
  - **La copia**: `git worktree add --detach <scratchpad>/045/base origin/main`. Se conserva hasta T027, porque la usan T020 (render local) y el control M0, y se quita ahí con `git worktree remove` y `git worktree prune`.
  - **Las corridas**: en secuencia y sin otros procesos bats, `bats tests/` (bash 5.x del PATH) y `PATH=/bin:$PATH bats tests/` (bash 3.2.57), con la salida a archivos del scratchpad.
  - **Lo que se registra**: `1..N`, los ok, los `not ok`, las saltadas, la duración y la salida de error (vacía).
  - **Lo esperado**: 1951 de 1951 en cada bash, con 56 saltadas en 5.x y 57 en 3.2, que es lo que dejó el gate final de 040 en este Mac. Si da otra cifra, se registra y manda la medida. El esperado final es la línea base más 18: las 13 pruebas del oráculo y las 5 del e2e nuevo, que en el host salen saltadas (precedente de 041).
  - Mientras corre se pueden escribir archivos (T005 a T010), pero no correr ningún `bats` en el worktree.
- [ ] T004 [P] Comprobar, solo con lecturas y consultas por nombre, el estado de Docker para T028 y T030, y registrarlo:
  - **El daemon**: `docker info --format '{{.ServerVersion}} {{.Architecture}} {{.NCPU}} {{.MemTotal}}'`.
  - **Las imágenes en caché**: `alpine:3.24.1`, `ubuntu:24.04` y `agent-admin:e2e` (`docker image inspect --format '{{.Id}}'`).
  - **El disco libre** del host.
  - No se toca ningún contenedor ni imagen.

---

## Phase 2: Foundational

**Purpose**: el esqueleto del oráculo. Bloquea todas las historias.

- [ ] T005 Crear `tests/agent-user-bin-path.bats` sin pruebas todavía (`contracts/host-oracle.md`):
  - **La cabecera**: un comentario con el propósito (045), los contratos y la regla de las aserciones: ningún `[[ ]]` ni `!` intermedio; se usa `[ ]`, `grep -q` o `if cmd; then false; fi`, y un `[[ ]]` solo como última línea.
  - **`load helper`** y un `setup()` que:
    - llama a `setup_tmp_dir` y exporta `HOME="$TMP_TEST_DIR/home"` (creado), para que ninguna prueba vea el `~/.local/bin` del operador;
    - define `AGENT_PATH_LIB="$REPO_ROOT/docker/scripts/lib/agent_path.sh"` y `UB="$HOME/.local/bin"`;
    - define `TMUX_PREFIX="ub045-$$"`, el prefijo de las sesiones tmux que creen H1 y H2.
  - **Un `teardown()`** que mata toda sesión tmux cuyo nombre empiece con `$TMUX_PREFIX` o con el nombre de agente de H1 y H2 (`tmux list-sessions -F '#{session_name}'`), antes de `teardown_tmp_dir`.
  - **Un ayudante** `_compose ARGS...` que corre `run sh -c '. "$1"; shift; agent_path_compose "$@"' _ "$AGENT_PATH_LIB" ARGS...`, para que las pruebas P carguen la librería con `sh` y no con bash.
  - `bats tests/agent-user-bin-path.bats` en los dos bash termina sin pruebas y sin error de carga.

**Checkpoint**: el archivo carga en los dos bash y no deja sesiones tmux.

---

## Phase 3: User Story 1 - Los hooks de claude-mem 15.x corren sin intervención manual (Priority: P1), MVP

**Goal**: toda sesión de `claude` que crea el producto en docker (la principal y sus respawns, el `/login`, el wizard del token y los ticks del heartbeat), más `agentctl mcp`, tiene `/home/agent/.local/bin` al final de su PATH (FR-001 y FR-002; contratos C1 a C5).

**Independent Test**: `bats tests/agent-user-bin-path.bats` en los dos bash. Contra el código actual caen P1 a P6, S1, S2, H1, A1 y G2, y la prueba reescrita de `tests/agentctl.bats`. Con el arreglo pasan todas.

- [ ] T006 [US1] ROJO: escribir P1 a P6 en `tests/agent-user-bin-path.bats` (contrato C1, `data-model.md` «PATH compuesto»):
  - **P1**: `_compose "/a:/b" "$HOME" 501` da `status` 0, `output` exactamente `/a:/b:$HOME/.local/bin` y una sola línea (`[ "${#lines[@]}" -eq 1 ]`). Con `run --separate-stderr` si la versión de bats lo admite (1.13.0 en el Mac, 1.11.0 en la CI); si no, se afirma stderr vacío redirigiendo a un archivo.
  - **P2**: con el directorio al inicio (`$UB:/a`), en el medio (`/a:$UB:/b`) y al final (`/a:$UB`), la salida es igual a la entrada.
  - **P3**: `_compose "/a:/b" "$HOME" 0` da `/a:/b`. Regla: «UID 0: root nunca recibe el directorio».
  - **P4**: con `HOME` vacío, `HOME=/`, un `HOME` con `:` y un `HOME` con un salto de línea, la salida es `/a:/b`. Con un PATH vacío, la salida es vacía. Regla: «HOME vacío, /, o con : o salto de línea» y «PATH vacío: no se crea un PATH que tenga solo el directorio del usuario».
  - **P5**: en un `sh -c`, guardar `PATH` y la lista de variables (`set | sort` sin las líneas de `_`, `LINENO` y `PPID`), cargar la librería y comparar: PATH y variables iguales. Después llamar `agent_path_compose` en el mismo `sh` y comprobar que `PATH` sigue igual.
  - **P6**: con un `HOME` cuyo `.local/bin` no existe, el directorio se agrega igual.
  - Contra el código actual, las seis caen porque la librería no existe.
- [ ] T007 [US1] ROJO: escribir S1 y S2 en `tests/agent-user-bin-path.bats` (contrato C2):
  - **El arnés de ambas**: en la propia prueba (no con `run`), `export START_SERVICES_NO_RUN=1`, `WORKDIR="$TMP_TEST_DIR"`, `WATCHDOG_RUNTIME_DIR="$TMP_TEST_DIR/wd"` y `source "$REPO_ROOT/docker/scripts/start_services.sh"`, como en `tests/start-services-watchdog.bats:9-23`. Después se redefinen como funciones vacías `pre_accept_bypass_permissions`, `pre_seed_onboarding`, `pre_install_stop_hook`, `pre_install_askq_hook`, `pre_install_upgrade_notice_hook`, `pre_warm_mcps` y `sleep`. Además, `next_tmux_cmd() { echo "CLAUDE_CONFIG_DIR=/x claude"; }` y `tmux() { printf '%s\n' "$@" >> "$TMP_TEST_DIR/tmux.rec"; printf '%s\n' '--' >> "$TMP_TEST_DIR/tmux.rec"; return 0; }`. También se redefine `log` para que agregue a `"$TMP_TEST_DIR/log.rec"`.
  - **S1**: guardar `P0="$PATH"`, llamar `start_session` y afirmar:
    - rc 0;
    - en `tmux.rec`, la llamada `new-session` trae las líneas `-e` y `PATH=$P0:$HOME/.local/bin`, y su último argumento es `CLAUDE_CONFIG_DIR=/x claude`, sin cambios;
    - `"$PATH"` sigue igual a `P0`.
  - **S2**: lo mismo, con `unset -f agent_path_compose` después del `source`. Afirmar:
    - rc 0;
    - la llamada `new-session` trae `-e` y `PATH=$P0`, sin el directorio;
    - `log.rec` tiene una línea que dice que `~/.local/bin` no entró en el PATH de la sesión.
  - Contra el código actual caen las dos, porque no hay `-e` ni esa línea de log.
- [ ] T008 [US1] ROJO: escribir H1 en `tests/agent-user-bin-path.bats` (contrato C3), en el molde de `tests/heartbeat-runs-jsonl.bats:5-55`:
  - **El workspace**: un `WORKSPACE` llamado como el agente (`$TMUX_PREFIX-hb`), con `scripts/heartbeat` copiado y `heartbeat.conf` con `NOTIFY_CHANNEL="none"` y un timeout de 5 s.
  - **Las variables del heartbeat**: `HEARTBEAT_STATE_LIB="$REPO_ROOT/docker/scripts/lib/state.sh"` y `HEARTBEAT_AGENT_PATH_LIB="$AGENT_PATH_LIB"`.
  - **El `claude` de prueba**: va en `"$TMP_TEST_DIR/bin"`, primero en el PATH. Escribe su `$PATH` en `"$TMP_TEST_DIR/claude.path"` y sale con 0.
  - **La corrida**: `run bash "$WORKSPACE/scripts/heartbeat/heartbeat.sh"`.
  - **Lo que se afirma**:
    - `status` 0;
    - `runs.jsonl` con `status` `ok`;
    - el contenido de `claude.path` empieza con el PATH del tick y termina en `:$HOME/.local/bin`.
  - Contra el código actual cae, porque `claude` recibe el PATH del tick sin el directorio.
- [ ] T009 [US1] ROJO: escribir A1 en `tests/agent-user-bin-path.bats` y reescribir la prueba «agentctl mcp default delegates to 'claude mcp list'» de `tests/agentctl.bats:146-152` (contrato C4; `contracts/host-oracle.md`, «Prueba existente que cambia»):
  - **El grabador**: el de `docker` de `tests/agentctl.bats:11-20`, que escribe un argumento por línea.
  - **A1**, para `AGENT_NAME=test agentctl mcp`:
    - la grabación contiene, en orden, `exec`, `-u`, `agent`, `test`, `sh` y `-c`;
    - una línea con el script contiene `/opt/agent-admin/scripts/lib/agent_path.sh` y termina en `exec claude mcp "$@"`;
    - siguen `agentctl-mcp` y `list`.
  - **A1, segunda parte**: `agentctl shell --root` sigue sin `-u` y sin ese script.
  - **La prueba reescrita de `agentctl.bats`**: afirma `-u` y `agent`, `sh` y `-c`, que el script termina en `exec claude mcp "$@"` y que la última línea es `list`. Conserva su nombre y su intención (el valor por defecto es `list`).
  - Contra el código actual caen las dos.
- [ ] T010 [US1] ROJO: escribir G2 en `tests/agent-user-bin-path.bats` (contrato C5):
  - `docker/Dockerfile` tiene la línea `COPY scripts/lib/agent_path.sh` con destino `/opt/agent-admin/scripts/lib/agent_path.sh` (`grep -E`);
  - `docker/scripts/start_services.sh`, `scripts/heartbeat/heartbeat.sh` y `scripts/agentctl` contienen esa misma ruta;
  - el archivo `docker/scripts/lib/agent_path.sh` existe.
  - Contra el código actual cae en la primera aserción.
- [ ] T011 [US1] Registrar el ROJO (SC-003) en bash 5.x y en 3.2, con `bats tests/agent-user-bin-path.bats tests/agentctl.bats` sobre el código actual:
  - **Lo esperado**: caen P1 a P6, S1, S2, H1, A1, G2 y la prueba reescrita de `agentctl.bats`; el resto de `agentctl.bats` pasa.
  - **La comprobación**: la línea que falla de cada prueba es la prevista (la librería ausente, la falta de `-e`, la falta de la línea de log, el PATH de `claude` sin el directorio, el `claude` suelto en la grabación o el `COPY` ausente), y no un error del arnés. Por ejemplo, no debe ser un `heartbeat.sh` que no encuentra `state.sh`, un `start_services.sh` que no carga, ni una sesión tmux que queda viva. Un ROJO por otra razón se corrige ahora y se vuelve a registrar.
- [ ] T012 [US1] Crear `docker/scripts/lib/agent_path.sh` (contrato C1, `research.md` D2):
  - **POSIX sh**, sin `[[ ]]`, `local`, arreglos ni `$'...'`. Solo define `agent_path_compose`. Cabecera en inglés con el porqué (045; root nunca; al final, para no sombrear la imagen; idempotente; sin mirar el disco).
  - **Las reglas, en este orden** (`data-model.md`, citadas literalmente):
    1. «UID 0: root nunca recibe el directorio» (si el tercer argumento es `0`, imprime la entrada).
    2. «HOME vacío, /, o con : o salto de línea: no se puede formar un directorio confiable» (imprime la entrada).
    3. «PATH vacío: no se crea un PATH que tenga solo el directorio del usuario» (imprime la entrada).
    4. «PATH que ya contiene el directorio en cualquier posición: idempotencia» (con `case ":$1:" in *":$2/.local/bin:"*)`).
    5. «cualquier otro caso: se agrega al final» (`printf '%s\n' "$1:$2/.local/bin"`).
  - Siempre `return 0`. Sin comandos externos.
  - Modo 100755 no hace falta (se carga, no se ejecuta); queda 100644.
  - P1 a P6 en verde en los dos bash.
- [ ] T013 [US1] Cambiar `docker/scripts/start_services.sh` (contrato C2, `research.md` D1 y D4):
  - **La carga**: junto a la cascada de `mcp_warm.sh` (`:64-76`), con el mismo molde: `/opt/agent-admin/scripts/lib/agent_path.sh` y, si no está, `"$(dirname "${BASH_SOURCE[0]}")/lib/agent_path.sh"`. Con un comentario de una línea (045).
  - **En `start_session`**, entre `log "launching: $cmd"` y `tmux kill-session`:
    - `local session_path="$PATH"`;
    - si `command -v agent_path_compose >/dev/null 2>&1`, entonces `session_path=$(agent_path_compose "$PATH" "$HOME" "$(id -u)")`;
    - si `session_path` es distinto de `PATH`, una línea de log que nombra el directorio agregado; si es igual porque la función no existe, la línea de log de S2, solo la primera vez por proceso (una variable global, por ejemplo `_AGENT_PATH_WARNED`).
  - **La línea `tmux new-session`** (`:865`) pasa a `tmux new-session -d -s "$SESSION" -c "$WORKDIR" -e "PATH=$session_path" "$cmd"`. Sigue siendo una sola línea (`tests/start-services-warm.bats:150-156`).
  - **Lo que no cambia**: `_run_watchdog`, `next_tmux_cmd`, la línea `launching:`, la poda ni el orden de los pasos previos.
  - S1 y S2 en verde. `tests/start-services-watchdog.bats` (incluido su oráculo de sha de `_run_watchdog`), `tests/start-services-warm.bats`, `tests/start-services-marketplace.bats`, `tests/start-services-postlogin-retry.bats` y `tests/docker-render.bats` en verde, sin editarlos.
- [ ] T014 [US1] Cambiar `scripts/heartbeat/heartbeat.sh` (contrato C3):
  - **La carga**, después de la de `STATE_LIB` (`:17-19`): `AGENT_PATH_LIB="${HEARTBEAT_AGENT_PATH_LIB:-/opt/agent-admin/scripts/lib/agent_path.sh}"` y `[ -f "$AGENT_PATH_LIB" ] && . "$AGENT_PATH_LIB"`, con `# shellcheck source=/dev/null`. El script no usa `set -e`, así que un archivo ausente no aborta.
  - **Antes del `tmux new-session`** (`:216`): calcular `hb_path` con la misma regla que T013 (respaldo `"$PATH"` si la función no existe) y pasar `-e "PATH=$hb_path"` antes del comando. El texto del comando del tick no cambia.
  - H1 en verde. `tests/heartbeat-*.bats` y `tests/heartbeatctl.bats` en verde, sin editarlos.
- [ ] T015 [US1] Cambiar `cmd_mcp` en `scripts/agentctl` (`:962-967`, contrato C4):
  - pasa a `exec docker exec -u agent "$agent" sh -c '<script>' agentctl-mcp "${@:-list}"`;
  - el script, en una sola cadena entre comillas simples: si `/opt/agent-admin/scripts/lib/agent_path.sh` existe, lo carga y hace `PATH=$(agent_path_compose "$PATH" "$HOME" "$(id -u)")` y `export PATH`; termina con `exec claude mcp "$@"`;
  - un comentario de dos líneas con el porqué (045; el diagnóstico ve el mismo PATH que la sesión);
  - `cmd_shell` no cambia;
  - A1 y `tests/agentctl.bats` en verde; `tests/agentctl-*.bats` en verde, sin editarlos.
- [ ] T016 [US1] Agregar a `docker/Dockerfile` la línea `COPY scripts/lib/agent_path.sh /opt/agent-admin/scripts/lib/agent_path.sh`, junto a la de `mcp_warm.sh` (`:268`), con la misma alineación. No se agrega ningún `ENV`; el comentario de 036 se reescribe en T022. G2 en verde.
- [ ] T017 [US1] Punto de control en bash 5.x y en 3.2:
  - `tests/agent-user-bin-path.bats` da 11 de 11 (H2 y G1 todavía no existen);
  - las suites nombradas en T013 a T015, en verde;
  - `bash -n` sobre los tres scripts cambiados (con `/bin/bash` y con el bash 5.x del PATH) y `sh -n docker/scripts/lib/agent_path.sh`.
  - Registrar.

**Checkpoint**: el defecto está cubierto en el host, sin Docker, en los dos bash.

---

## Phase 4: User Story 2 - El arreglo no sombrea nada ni abre una vía hacia root (Priority: P1)

**Goal**: los binarios de la imagen siguen ganando, ningún proceso root recibe el directorio, el fail-silent se mantiene y el modo local y las demás pruebas no cambian (FR-003 a FR-007).

**Independent Test**: H2 y G1 en verde, toda prueba existente en verde salvo la reescrita de `agentctl.bats`, el diff fuera del alcance vacío y `shellcheck` limpio. El señuelo `node` y los procesos root se miden en el contenedor (E1 y E5, T029).

- [ ] T018 [US2] Escribir H2 y G1 en `tests/agent-user-bin-path.bats`. Nacen verdes a propósito:
  - **H2** (FR-005, D4): el arnés de H1, con `HEARTBEAT_AGENT_PATH_LIB="$TMP_TEST_DIR/no-such-lib.sh"`. Afirmar:
    - `status` 0;
    - `runs.jsonl` con `status` `ok`;
    - ninguna línea de stderr que nombre `agent_path` o `no such file`;
    - `claude.path` igual al PATH del tick, sin el directorio.
  - **G1** (FR-004), estructural:
    - `docker/Dockerfile` no tiene ninguna instrucción `ENV` que nombre `.local/bin`, leída completa: se unen las líneas que terminan en `\` antes de revisar cada instrucción, para que una línea de continuación no se escape (M18);
    - `docker/entrypoint.sh` no nombra `agent_path` ni `.local/bin`;
    - `docker/scripts/start_services.sh` y `scripts/heartbeat/heartbeat.sh` no tienen ninguna línea `export PATH` ni `PATH=` (fuera de un `-e "PATH=`) que nombre `.local/bin` ni `agent_path_compose` como valor exportado;
    - `cmd_shell` de `scripts/agentctl` no nombra `agent_path`.
  - Las dos en verde en los dos bash. El control M0 y las mutaciones M12 (H2) y M13, M14 y M18 (G1) (T027) prueban que pueden fallar.
- [ ] T019 [US2] Comprobar que nada más cambia (FR-005 a FR-007):
  - `git diff --stat origin/main -- tests/` muestra solo `tests/agent-user-bin-path.bats` (nuevo) y la prueba reescrita de `tests/agentctl.bats`;
  - `git diff origin/main -- modules/ setup.sh docker/entrypoint.sh` queda vacío (FR-005 y FR-006; `modules/` incluye `docker-compose.yml.tpl` y las plantillas del modo local);
  - `tests/local-render.bats`, `tests/local-bootstrap.bats`, `tests/mcp-warm.bats`, `tests/docker-setup.bats` y `tests/docker-render.bats` en verde, en los dos bash.
  - Registrar.
- [ ] T020 [US2] Comprobar el render del modo local, byte a byte (SC-004):
  - con el arnés de `tests/local-render.bats`, renderizar el mismo `agent.yml` de modo local desde la copia aislada de T003 y desde la rama, a directorios del scratchpad;
  - `diff -r` da 0 diferencias en `remote-control.env`, las units y `.mcp.json`.
  - Registrar.
- [ ] T021 [US2] `shellcheck` con el comando exacto del job `shellcheck` (`.github/workflows/shellcheck.yml:29-47`), rc 0. Además, `shellcheck -s sh -S error docker/scripts/lib/agent_path.sh`, para verificar que la librería es POSIX. Registrar.

**Checkpoint**: 13 de 13 en el host, sin regresiones.

---

## Phase 5: Polish (documentos; local, sin compuertas)

- [ ] T022 [P] Reescribir el comentario de 036 en `docker/Dockerfile:118-125` (D5). Debe decir:
  - el `ENV` de la imagen sigue sin `~/.local/bin` a propósito, porque lo heredan los procesos root (el entrypoint, el bucle del crontab, `crond` y `docker exec -u root`) y el directorio lo escribe `agent`;
  - desde 045, el directorio entra al **final** del PATH de las sesiones de `claude` del agente, con `agent_path.sh`, porque claude-mem 15.x invoca su lanzador por nombre desde ahí;
  - lo de los enlaces de uv, sin cambios.
- [ ] T023 [P] Agregar en `docs/architecture.md`, en el modelo de privilegios, un párrafo corto con la invariante de 045:
  - el directorio de binarios del agente nunca está en el PATH de un proceso root;
  - entra al final del PATH de cada sesión de `claude` (sesión principal, respawns y ticks del heartbeat) y en `agentctl mcp`;
  - un `docker exec -u agent` manual o `agentctl shell` no lo tienen, y se agrega con `PATH="$PATH:$HOME/.local/bin"` (D3).
- [ ] T024 [P] Escribir la entrada de 0.31.0 en `CHANGELOG.md` (FR-012), en el formato de las anteriores, y subir `VERSION` a 0.31.0 tras verificar `git show origin/main:VERSION` = 0.30.0:
  - el defecto y su causa;
  - el arreglo;
  - lo que no cambia (root, `ENV` de la imagen y modo local);
  - que hace falta reconstruir la imagen;
  - que el enlace manual de cbum queda innecesario.
- [ ] T025 Escribir a mano el bloque de 045 en `CLAUDE.md`, en el molde de 044 (estado, diseño, decisiones del operador, mediciones y pendientes). Agregar en «Common gotchas» una viñeta con las dos mediciones que sirven más allá de esta feature:
  - en tmux 3.6b, una sesión nueva toma el PATH del cliente que la crea, no del servidor, así que lo que exporte el supervisor no llega a una sesión creada desde cron;
  - un job de busybox `crond` hereda todo el entorno de `crond`, que es root.

  Se commitea con `git add -f CLAUDE.md`. Auditar los bytes de los cuatro archivos de esta fase con `byte_audit_files.py`.

---

## Phase 6: User Story 3 - La corrección se demuestra y llega a la flota (Priority: P2)

**Goal**: el ROJO antes del VERDE, el catálogo de mutaciones entero, el contrato en un contenedor real y claude-mem funcionando en cbum sin el parche manual, antes del merge (FR-009 a FR-011; SC-001 a SC-003).

**Independent Test**: el Registro de este archivo tiene cada medición con su comando y su resultado.

- [ ] T026 [US3] Preparar el corredor de mutaciones en `<scratchpad>/045/mutate.sh`, en el molde de 044. Para cada mutación:
  - copia el árbol a un directorio limpio;
  - aplica el cambio con `python3` (reemplazo exacto, con un error si no encuentra el ancla);
  - corre `bats tests/agent-user-bin-path.bats` (y `tests/agentctl.bats` en M17) con bash 5.x y con `PATH=/bin:$PATH`;
  - registra qué pruebas cayeron.

  M0 corre el archivo de pruebas final contra el árbol de `origin/main`.
- [ ] T027 [US3] Correr M0 a M18 de `contracts/host-oracle.md` en los dos bash y registrar la tabla:
  - M0 hace caer exactamente P1 a P6, S1, S2, H1, A1 y G2, y deja verdes H2 y G1;
  - cada mutación de M1 a M18 hace caer al menos la prueba nombrada en el contrato;
  - M7 se registra como equivalente en el Mac (`/bin/sh` es bash) y se prueba en T028.

  Una mutación que sobreviva obliga a endurecer la prueba (precedente de 034 M6 y 037 M5), con su ROJO visto, y a repetir la corrida. Al terminar, quitar la copia de T003 (`git worktree remove` y `git worktree prune`).
- [ ] T028 [US3] Pata Linux, en un contenedor desechable `ubuntu:24.04` (sin COMPUERTA; se avisa antes):
  - con el repo copiado y no montado, como usuario no root, `bats` y `tmux` instalados con `apt`;
  - correr P1 a P6 de `tests/agent-user-bin-path.bats` con dash como `sh`;
  - aplicar M7 (`[[ ]]` en la función) y ver caer P5;
  - registrar las versiones (`bats --version`, `tmux -V`, `readlink -f /bin/sh`) y el resultado.
- [ ] T029 [US3] Escribir `tests/docker-e2e-user-bin-path.bats` (contrato `contracts/e2e-and-gate.md` sección E), en el molde de `tests/docker-e2e-heartbeat.bats`:
  - **El arranque**: `skip` sin `DOCKER_E2E=1`, un solo arranque en `setup_file`, nombre de agente `ub-e2e` y `image_tag: agent-admin:ub045-e2e`, heartbeat con intervalo `1m`, `plugins: []`.
  - **La siembra**: `probe045` y el señuelo `node` en `.state/.local/bin` antes del arranque.
  - **El `claude` de prueba**: montado en `/usr/local/bin/claude` con el override de compose. En cada invocación agrega una línea JSON con sus argumentos, `PATH`, `command -v probe045` y `command -v node` a `/workspace/scripts/heartbeat/logs/stub-claude.jsonl`. Sin `--print` y sin `mcp` duerme; con `--print` imprime `ok` y sale; con `mcp` sale con 0.
  - **Es la confirmación** en un contenedor real; el oráculo test-first es el del host. El wizard del token no se ejecuta aquí (requiere sesión iniciada) y lo cubre S1.
  - **E5 sin root**: `docker inspect --format '{{json .Config.Env}}'` del contenedor da un `PATH` exactamente igual al de la imagen (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`). La igualdad exacta impide que pase con un entorno vacío. No se usa `docker exec -u root`.
  - **Las pruebas**: E1 a E5, cada una con su espera acotada (un tick del cron puede tardar hasta 120 s) y un volcado de diagnóstico solo al fallar (logs del contenedor, `stub-claude.jsonl` y `ps`). `teardown_file` baja el contenedor y borra la imagen de prueba.
  - **El host**: el archivo carga y salta limpio en los dos bash sin Docker.
- [ ] T030 [US3] COMPUERTA (DOCKER_E2E local, arm64):
  - registrar la huella sha256 de los archivos de código de la rama (los de T012 a T016 y T022);
  - correr `DOCKER_E2E=1 bats tests/docker-e2e-user-bin-path.bats` (5 de 5);
  - después correr `DOCKER_E2E=1 bats tests/docker-e2e-*.bats`, con 49 más 5 y 0 `not ok`;
  - registrar la duración, el pico de memoria si se puede leer y cada resultado.

  Un rojo se diagnostica con el volcado, se corrige test-first y se repite (y obliga a volver a T027 si toca la librería, la sesión, el heartbeat o `agentctl`).
- [ ] T031 [US3] Revisión independiente de solo lectura (agente `code-reviewer`), antes del gate completo, con este brief. Incluye la **revisión de privilegios** que la constitución exige para todo cambio bajo `docker/` (Principio II, gate de privilegios): capacidades, mounts, qué corre como root, el PATH de root y cualquier `docker exec` sin `-u agent` en el código y en las pruebas. Su resultado se registra aparte:
  - los archivos de código y de pruebas cambiados, y los contratos;
  - las clases de hallazgo de la memoria (aserciones vacuas, guardias redundantes, una guardia de seguridad sin prueba, un verificador propio que falla en silencio).

  Triar cada hallazgo. Los que se acepten se corrigen test-first, con su ROJO visto, y se repite lo afectado de T027 y T030.
- [ ] T032 [US3] Gate completo del host sobre el árbol final (quickstart V4):
  - **Las corridas**: `bats tests/` en bash 5.x y en 3.2, en secuencia. Esperado: la línea base de T003 más 18, 0 `not ok`, las saltadas de la línea base más las 5 del e2e nuevo, y stderr vacío.
  - **Las comprobaciones**: el `shellcheck` de T021, el diff fuera del alcance de T019, `VERSION` 0.31.0 contra `origin/main` y la huella de T030 sin cambios.
  - Registrar.
- [ ] T033 [US3] COMPUERTA (commits locales), en commits atómicos y sin ninguno intermedio en rojo:
  1. `fix:` la librería, la sesión, el heartbeat, `agentctl`, el Dockerfile y las pruebas;
  2. `docs:` CHANGELOG, `VERSION`, `docs/architecture.md`, `CLAUDE.md` y el Registro de este archivo.

  Con la identidad de T001, sin atribución. Antes, comprobar los modos con `git ls-files -s` y auditar los bytes de los archivos nuevos.
- [ ] T034 [US3] COMPUERTA (push): empujar la rama `045-plugin-launcher-path` por el camino HTTPS con el ayudante de `gh` (T001).
- [ ] T035 [US3] COMPUERTA (gate en cbum, antes del merge; `contracts/e2e-and-gate.md` sección G y quickstart V6). Por `ssh ssh-ferrari`, o por la LAN si esa ruta falla:
  1. respaldar la imagen como `agentic-pod:cbum-pre045` y los archivos;
  2. traer la rama a un clon en ferrari y seguir el procedimiento de `README.md` («Upgrade an existing agent», pasos 2 y 3): copiar `setup.sh`, `VERSION`, `.gitignore` y `LICENSE`; borrar y reponer `modules/` y `docker/`; copiar `scripts/` encima sin borrarlo; y correr `./setup.sh --regenerate`;
  3. `docker compose build`;
  4. stop, 150 s, up;
  5. medir SC-001 (`contracts/e2e-and-gate.md` sección G, paso 5). Antes del reinicio, el control positivo: los registros `hook_non_blocking_error` del transcript con `Executable not found in $PATH: "claude-mem"` son 3 o más. Se anota la hora del reinicio. Después de los tres prompts que el operador envía por Telegram, el mismo conteo con hora posterior al reinicio da 0. También se comprueba que el worker siga vivo y que `claude-mem.db-wal` haya cambiado;
  6. registrar lo que pide FR-011.

  Si falla, volver a `agentic-pod:cbum-pre045` con los archivos respaldados. Los hooks de claude-mem vuelven a fallar (sin bloquear) hasta corregir la causa. Rehacer el enlace manual exige `docker exec -u root`, fuera del Principio II, y solo se hace con la autorización explícita del operador, como el 11-11-2026. Registrar la causa.
- [ ] T036 [US3] COMPUERTA (PR): abrir el PR contra `main` con el resumen, la evidencia de T027 a T035 y el despliegue pendiente. Esperar la CI en verde en los tres checks (shellcheck, bats en ubuntu y en macOS) y registrar los conteos de cada brazo. El merge lo hace el operador.

**Checkpoint**: la evidencia de cierre de FR-011 está completa y el PR espera el merge.

---

## Phase 7: Cierre

- [ ] T037 Tras el merge que hace el operador: verificar `main` con lecturas. El árbol debe ser igual al de la cabeza validada, `VERSION` 0.31.0, existir `docker/scripts/lib/agent_path.sh` con su línea `COPY`, y la línea `tmux new-session` de `start_session` debe tener `-e "PATH=`. Registrar.
- [ ] T038 COMPUERTA (despliegue de donna y linus; `contracts/e2e-and-gate.md` sección D). Cada agente lleva su respaldo `agentic-pod:<agente>-pre045`, se reconstruye y se reinicia con stop, 150 s, up. Después se observan 24 h (SC-005): 0 errores de hook nuevos y 0 reinicios atribuibles. Si `main` cambió algo respecto de la rama, cbum se vuelve a alinear.
- [ ] T039 COMPUERTA (registro fuera del repo):
  - actualizar la ficha de cbum (memoria y `definiciones/cbum/cbum.md`): parche manual retirado, 045 desplegada;
  - en Confluence, el pendiente «claude-mem 15.x» de la página del equipo (397072) y una fila por agente en el Historial de versiones de la flota (32243715);
  - un PR de documentos con el Registro final.
- [ ] T040 La limpieza (el worktree, la rama local y la rama remota de 045) la hace el operador: el modo auto bloquea `git push --delete`.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (T001 a T004)**: T002 antes de cualquier otro commit. T003 corre en segundo plano mientras se escriben T005 a T010.
- **Foundational (T005)**: bloquea US1.
- **US1 (T006 a T017)**: el ROJO (T006 a T011) antes de cualquier cambio de código (T012 a T016). T012 antes de T013, T014 y T015, que la usan.
- **US2 (T018 a T021)**: después de US1.
- **Polish (T022 a T025)**: después de US2. Va antes de US3 porque la revisión y los commits incluyen los documentos.
- **US3 (T026 a T036)**: T027 antes de T030. T030 antes de T031 y de T032. T032 antes de T033. T034 antes de T035, y T035 antes de T036.
- **Cierre (T037 a T040)**: después del merge del operador.

### Within Each User Story

- Las pruebas se escriben y se ven en ROJO antes del código que cubren.
- Cada cambio de código tiene un punto de control en los dos bash antes de pasar al siguiente archivo.

### Parallel Opportunities

- T003 (línea base) y T004 (Docker), mientras se escriben T005 a T010.
- T014, T015 y T016 tocan archivos distintos y se pueden hacer en cualquier orden una vez que existe la librería (T012), pero `bats` no se corre en paralelo.
- T022, T023 y T024 tocan archivos distintos.

## Parallel Example: Polish

```text
T022 docker/Dockerfile (comentario)   |   T023 docs/architecture.md   |   T024 CHANGELOG.md + VERSION
```

## Implementation Strategy

### MVP primero (US1)

US1 sola ya cierra el defecto: con la librería, el `-e` de la sesión y el del heartbeat, claude-mem 15.x encuentra su lanzador. US2 y US3 son las garantías y la evidencia que exige un cambio en código horneado.

### Entrega incremental

1. Setup y Foundational: la línea base y el esqueleto.
2. US1: el ROJO y el arreglo, en el host.
3. US2: lo que no cambia, en el host.
4. Polish: los documentos.
5. US3: las mutaciones, el contenedor, la revisión, el gate, los commits, el push, cbum y el PR.
6. Cierre: después del merge.

## Notes

- **Lo que no se hace**: tocar `_run_watchdog`, `next_tmux_cmd`, el entrypoint, compose, `modules/` o `setup.sh`; agregar un `ENV PATH`; extender el PATH de `start_services.sh` o del heartbeat fuera de la sesión que crean; tocar `agentctl shell`.
- **El conteo esperado**: la línea base más 18 en el host (13 del oráculo y 5 del e2e nuevo, saltadas), y 49 más 5 en el e2e.
- **El enlace manual de cbum**: desaparece al recrear el contenedor en T035. Si el gate falla y se revierte, rehacerlo exige `docker exec -u root` y la autorización explícita del operador.

### Registro (se completa durante la implementación)

- **T001 (11-11-2026)**: `origin/main` en `c242c31` (por HTTPS con el ayudante de `gh`) y `VERSION` 0.30.0. Sin PR abiertos. El árbol local tiene solo `.specify/feature.json` modificado y `specs/045-plugin-launcher-path/` sin rastrear. Las anclas coinciden: `start_services.sh:865` es la única línea `tmux new-session` de la sesión, `heartbeat.sh:216-217` la del tick, `agentctl:966` la de `cmd_mcp`, las líneas `COPY` de `Dockerfile:258-268` y la prueba de `agentctl.bats:146-152`. Ninguna línea `ENV`, `export PATH` ni `PATH=` agrega `.local/bin` en los cuatro archivos. No existe `docker/.dockerignore` y no se crea (precedente de 044: las imágenes se construyen desde el workspace). La identidad de los commits es la del autor de `8cb45e4`.
