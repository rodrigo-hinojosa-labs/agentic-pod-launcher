---

description: "Tareas de 044-qmd-lock-fd-leak: las secciones con lock de qmd sueltan .reindex.lock en cuanto terminan"
---

# Tasks: Las secciones con lock de qmd sueltan `.reindex.lock` en cuanto terminan

**Input**: `specs/044-qmd-lock-fd-leak/` ([spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [quickstart.md](quickstart.md), [contracts/](contracts/))

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: obligatorios y primero (Principio III; FR-007). Son las 10 pruebas de `contracts/host-oracle.md`, todas en `tests/qmd-lock-release.bats`:

- **Seis caen contra el código actual**, cada una por la razón prevista: L1, L2, L3, L4 y L7 porque el lock sigue tomado justo después de la sección, y G1 porque el `flock -u 9` final no existe.
- **Cuatro nacen verdes a propósito**: L5, L6, L8 y G2. Guardan la semántica del lock, el estado del índice y el propio arnés, y el catálogo de mutaciones prueba que pueden fallar.

El catálogo es el control M0 (el archivo final contra el código actual) más 9 mutaciones (M1 a M9), en bash 5.x y 3.2 en el host y otra vez en una pata Linux con el `flock` de util-linux (SC-002).

**Organization**: por **dependencia** sobre los mismos archivos, no por prioridad (precedente de 040 a 043):

```text
Foundational (fixtures y G2) -> US1 (P1) -> US2 (P1) -> Polish (documentos) -> US3 (P2, evidencia) -> Cierre
```

- **Foundational** crea las dos fixtures y el esqueleto del archivo de pruebas, con G2, el autotest del arnés. Sin G2 en verde, un ROJO posterior no prueba nada.
- **US1** escribe las pruebas que caen (L1 a L4, L7 y G1) y las de la semántica (L5 y L6), registra el ROJO y aplica el arreglo: un `flock -u 9` como último paso de cada sección en `scripts/lib/qmd_index.sh`. Es la forma que eligió el operador en el análisis del 07-11-2026, en lugar del `trap` del plan (`research.md` M8 y D1).
- **US2** agrega L8 y comprueba que ninguna prueba existente cambia ni cae, junto con `shellcheck` y `bash -n`.
- **Polish** escribe CHANGELOG, `VERSION` y `CLAUDE.md` antes de la evidencia, porque la revisión independiente y los commits los incluyen.
- **US3** es la evidencia. Incluye la pata Linux, las mutaciones, la revisión, el contenedor con el `timeout` real, el DOCKER_E2E local, el gate, los commits, el push, la corrida manual de CI y el issue del hallazgo lateral.

**Orden de la evidencia**: la confirmación en contenedor (T025) y el DOCKER_E2E local (T026) van **antes** del gate completo (T027), como en 043 (`contracts/evidence-protocol.md`, nota de orden). Un defecto que aparezca en un contenedor obliga a editar y a repetir el gate, que cuesta unos 36 minutos por los dos bash. Con este orden, el gate corre una sola vez, sobre el árbol final, y su huella sha256 se compara con la de T025 y T026.

**Compuertas**:

- **Qué la lleva**: cada commit, push, `workflow_dispatch`, creación o borrado de una rama remota, issue, PR y merge exige la confirmación explícita del operador, CADA VEZ, y está marcado COMPUERTA. El DOCKER_E2E local (T026) también la lleva.
- **Qué no la lleva**: T022 y T025, que corren en contenedores desechables `--rm` de unos minutos con imágenes base ya en caché (precedente de T027 y T031 de 043). Se avisa antes de empezar.
- **Reglas fijas**: nada se commitea antes de T002. No hay hooks que ejecutar (`.specify/extensions.yml` tiene `hooks: {}`). No se tocan los worktrees de 040, 041, 042 ni 043, ni los contenedores o las imágenes del operador que no sean de las pruebas. Todo `docker exec` en un contenedor de agente lleva `-u agent` (Principio II). El merge es siempre del operador, y no se propone antes de la décima noche de T046 de 043 (hacia el 11-11-2026).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: se puede hacer en paralelo (archivos distintos, sin dependencia de una tarea abierta).
- **[Story]**: la historia del spec a la que sirve la tarea (US1 a US3).
- Las rutas son relativas a la raíz del worktree `.claude/worktrees/044-qmd-lock-fd-leak`.
- `<scratchpad>` es el directorio de la sesión: `/private/tmp/claude-501/-Users-rodrigo-hinojosa-Documents-Cencosud-Claude-Agents-agentic-pod-launcher--claude-worktrees-043-e2e-lock-race-hardening/39e5ee01-c1c3-454a-ba47-6d398dabb108/scratchpad`. Se borra entre sesiones, así que lo que deba durar va a la memoria o a este archivo. Las herramientas de medición viven en `<scratchpad>/044/` y no se versionan.
- Las líneas citadas de `scripts/lib/qmd_index.sh` son las de `origin/main` `8cb45e4`. Después de T014, las secciones se desplazan dos líneas.

---

## Phase 1: Setup

**Purpose**: fijar el punto de partida, commitear los artefactos y medir la línea base.

- [X] T001 Verificar, solo con lecturas, y registrar en el Registro de este archivo:
  - **El remoto**: `origin/main` sigue en `8cb45e4`, comprobado con `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' ls-remote https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher.git refs/heads/main` (el remoto `origin` es SSH y la clave de este Mac resuelve a otra cuenta). Si se movió, traerlo por el mismo camino y leer con `git log --stat 8cb45e4..origin/main` si toca `scripts/lib/qmd_index.sh`, `tests/helper.bash`, `CHANGELOG.md` o `VERSION`. `git show origin/main:VERSION` debe dar 0.29.0.
  - **Los PR abiertos** (`gh pr list --state open`) y si alguno toca los archivos de esta feature.
  - **El estado local**: `git status --short` muestra solo `.specify/feature.json` modificado y `specs/044-qmd-lock-fd-leak/` sin rastrear.
  - **Las anclas del arreglo**, en `scripts/lib/qmd_index.sh`:
    - aparece una sola vez cada línea del perdedor: `if ! flock -n 9; then _qmd_log "setup: already running — skip"; exit 91; fi` (`:477`) y `if ! flock -n 9; then _qmd_log "reindex: already running — skip"; exit 91; fi` (`:562`);
    - les siguen la llamada de la sección (`_qmd_setup_locked "$agent_yml" "$cache_root" "$vault_dir" "$sentinel"` en `:478`, y `_qmd_reindex_locked "$agent_yml" "$vault_dir"` en `:563`) y el cierre del subshell (`) 9>"$lock" || rc=$?` en `:479` y en `:564`), medido el 07-11-2026;
    - ningún `trap` aparece en el archivo, lo que confirma M7 de research. El arnés de la sesión rechaza un comando que contenga esa palabra, así que se cuenta con un script del scratchpad.
  - **Los archivos de ignorar** (paso de `/speckit-implement`): `.gitignore` existe con los patrones universales que importan aquí. No se crea `.dockerignore` ni se agregan patrones. El stack es solo de shell, la feature no toca `docker/` (FR-012) y las imágenes se construyen desde el workspace del scaffold, no desde este repo.
  - **La identidad de los commits**: `Rodrigo Andres Hinojosa Acuña <rodrigo.hinojosa.developer@gmail.com>` (el autor de `8cb45e4`), por variables de entorno, porque el `user.email` del repo es otro.
- [ ] T002 COMPUERTA (commit local): commitear `specs/044-qmd-lock-fd-leak/**` y `.specify/feature.json`.
  - **Antes**: auditar los bytes con `python3 <scratchpad>/byte_audit_files.py` sobre cada archivo de `specs/044-qmd-lock-fd-leak/` (son nuevos, así que `git diff` no los ve), con 0 ofensores. Tras el `git add`, comprobar con `git ls-files -s` que los modos son 100644.
  - **El mensaje**: en español, ASCII, en imperativo y sin atribución, con la identidad de T001 en `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME` y `GIT_COMMITTER_EMAIL`. Por ejemplo, `docs: agrega los artefactos de spec-kit de 044 (lock de qmd retenido por el timeout de BusyBox)`.
  - Sin push.
- [ ] T003 Medir la línea base de la suite del host en una copia aislada de `origin/main`:
  - **La copia**: `git worktree add --detach <scratchpad>/044/base origin/main`, que se quita al terminar con `git worktree remove` y `git worktree prune`.
  - **Las corridas**: con bats 1.13.0, en secuencia y sin otros procesos bats, `bats tests/` (bash 5.3.15 del `PATH`) y `PATH=/bin:$PATH bats tests/` (bash 3.2.57), con la salida a archivos del scratchpad.
  - **Lo que se registra**: `1..N`, los ok, los `not ok`, las saltadas, la duración y la salida de error (vacía).
  - **Lo esperado**: 1894 de 1894 en cada bash, con 56 saltadas en 5.x y 57 en 3.2, que es lo que dejó 043 en este Mac (la CI de `main` en `ef2f4cf` dio 1894 por brazo; #119 solo tocó documentos). Si da otra cifra, se registra y manda la medida. El esperado final es la línea base más 10.
  - **La duración**: unos 18 minutos por bash. Mientras corre se pueden escribir archivos (T005 a T012), pero no correr ningún `bats` en el worktree.
- [ ] T004 [P] Comprobar, solo con lecturas y consultas por nombre, el estado de Docker para T022, T025 y T026, y registrarlo:
  - **El daemon**: Docker Desktop encendido (`docker info --format '{{.ServerVersion}} {{.Architecture}} {{.NCPU}} {{.MemTotal}}'`).
  - **Las imágenes**: `alpine:3.24.1`, `alpine:3.20` y `ubuntu:24.04` en caché (`docker image inspect --format '{{.Id}}'`). Las etiquetas `agent-admin:qmd-real` y `agent-admin:qmd-embed` no existen (se quitaron el 02-11-2026; el caché de build se conservó, así que T026 las reconstruye).
  - **Los modelos de 041**: `~/.cache/agentic-qmd-e2e/models-041` con 2 archivos, de 333.590.944 y 1.282.438.912 bytes, con el tamaño y el sha256 de la tabla de `.github/scripts/fetch-qmd-models.sh`. Si faltan, obtenerlos lleva COMPUERTA (unos 1,6 GB).
  - **El disco libre** del host.
  - No se toca ningún contenedor ni imagen.

---

## Phase 2: Foundational

**Purpose**: las fixtures y el arnés. Bloquea todas las historias: sin G2 en verde, el ROJO de US1 no es evidencia.

- [ ] T005 [P] Crear `tests/fixtures/qmd-lock/timeout`: bash, ejecutable, compatible con bash 3.2, con la forma de BusyBox de `contracts/host-oracle.md` §1 y `research.md` M2 y M5. Se parte de `<scratchpad>/044/fakebin/timeout`, la versión medida en la Fase 0:
  - **Los argumentos**: acepta y descarta `-k N`, `-s SIG`, cualquier otra opción que empiece con `-` y la duración.
  - **El vigilante**: si `FAKE_TIMEOUT_LINGER` (por defecto 3) es distinto de `0`, lanza `( exec </dev/null >/dev/null 2>&1 3>&-; exec sleep "$FAKE_TIMEOUT_LINGER" ) &`.
    - Conserva todo descriptor heredado salvo 0, 1, 2 y 3. El 3 es el canal de bats: un proceso que lo conserva demora el reporte.
    - El `exec sleep` hace que el PID registrado sea el del proceso que conserva el descriptor 9.
  - **El registro del vigilante**: si `FAKE_TIMEOUT_PIDFILE` tiene valor, agrega `$!` a ese archivo.
  - **El filtro**: si `FAKE_TIMEOUT_ONLY` tiene valor, solo deja vigilante cuando el nombre base del primer argumento del comando (`${1##*/}`) es igual a ese valor (`bun` para L4).
  - **El comando**: termina con `exec "$@"`, así el comando conserva el PID del llamador. No aplica ningún tope: SC-004 se mide con el `timeout` real en T025.
  - **La cabecera**: un comentario que dice qué imita (BusyBox 1.36.1 y 1.37.0), por qué cierra el 3 y que no es un `timeout` de verdad.
  - Queda ejecutable en el árbol; T028 verifica el modo 100755 en el índice.
- [ ] T006 [P] Crear `tests/fixtures/qmd-lock/flock`, en perl y ejecutable (`#!/usr/bin/env perl`, `use strict;`), a partir de `<scratchpad>/044/fakebin/flock`, medido en la Fase 0:
  - **Las formas**: `flock [-n] [-x] FD` toma el descriptor heredado sin duplicarlo (`open($fh, '>&=', FD)`); `flock -u FD` lo suelta; `flock [-n] ARCHIVO COMANDO...` abre el archivo con `>>`, toma el lock y corre el comando mientras lo tiene.
  - **Los códigos**: 1 si no obtiene el lock o no puede abrir, 64 por un uso inválido, 127 si el comando no se puede ejecutar y, si no, el código del comando. El código de conflicto, 1, es el mismo que el de util-linux.
  - **La cabecera**: un comentario que dice que solo se instala donde el host no tiene `flock` (macOS) y que hace la misma llamada `flock(2)` sobre la misma descripción.
- [ ] T007 Crear `tests/qmd-lock-release.bats` sin pruebas todavía (`contracts/host-oracle.md` §1 y §2):
  - **La cabecera**: un comentario con el propósito (#116, 044), los contratos y la regla de las aserciones: ningún `[[ ]]` ni `!` intermedio; se usa `[ ]`, `grep -q` o `if cmd; then false; fi`.
  - **`load helper`** y un `setup()` en el molde de `tests/qmd-index.bats:14-32`:
    - `setup_tmp_dir`, más `HOME`, `QMD_CACHE_HOME`, `QMD_VAULT_DIR` (con `wiki/a.md`), `QMD_INDEX_STATE_FILE`, `QMD_STUB_LOG` y un `AGENT_YML` con `vault.enabled` y `vault.qmd.enabled` en true y `version: "2.5.3"`.
    - Un directorio `"$TMP_TEST_DIR/lockbin"`, primero en el `PATH`, con la copia de `tests/fixtures/qmd-lock/timeout`. La copia de `tests/fixtures/qmd-lock/flock` va ahí **solo** si `command -v flock` falla **antes** de tocar el `PATH`. Si el host no tiene `flock` ni `perl`, el `setup` falla con un mensaje que lo dice; no hay `skip`.
    - `export FAKE_TIMEOUT_LINGER=3`, `export FAKE_TIMEOUT_PIDFILE="$TMP_TEST_DIR/watchdogs.pid"` y `unset FAKE_TIMEOUT_ONLY QMD_STUB_FAIL_ONCE`.
    - `source "$REPO_ROOT/scripts/lib/qmd_index.sh"` y `LOCK="$(qmd_cache_root)/.reindex.lock"`. La ruta sale de la función del producto, no de una cadena, para que el sondeo no pueda mirar otro archivo.
  - **Un `teardown()`** que mata cada PID de `watchdogs.pid` y de `"$TMP_TEST_DIR/owner.pid"` (`kill "$p" 2>/dev/null || true`), antes de `teardown_tmp_dir`. Los vigilantes no son hijos de la prueba, así que `wait` no los alcanza.
  - **Los ayudantes del archivo**:
    - `_probe_now` deja `PROBE_RC` con el código de un solo `flock -n "$LOCK" true` (`PROBE_RC=0; flock -n "$LOCK" true || PROBE_RC=$?`).
    - `_watchdogs` imprime cuántas líneas tiene `watchdogs.pid` (0 si no existe).
    - `_fn_body NOMBRE` imprime el cuerpo de una función de `scripts/lib/qmd_index.sh`, desde `^NOMBRE() {` hasta la primera `^}`, con `awk`.
  - `bats tests/qmd-lock-release.bats` en los dos bash termina sin pruebas y sin error de carga.
- [ ] T008 Escribir **G2** en `tests/qmd-lock-release.bats` (autotest del arnés, FR-007) y cerrar la fase:
  - **La primera parte**: con el vigilante de 3 s, una sección mínima escrita en la prueba, `( flock -n 9 || exit 91; timeout 900 true ) 9>"$LOCK"`, deja `watchdogs.pid` con 1 línea y el lock tomado: `_probe_now` con `PROBE_RC` distinto de 0.
  - **La segunda parte**: con `FAKE_TIMEOUT_LINGER=0`, la misma sección deja `PROBE_RC` en 0.
  - Correr el archivo en bash 5.x y en 3.2: G2 en verde.
  - **Que el arnés no deja nada**: tras la corrida, `ps -Ao pid,command` no muestra ningún `sleep 3` del vigilante, lo que prueba que el `teardown` lo mató. La duración de la corrida no prueba que el vigilante cierre el 3, porque el `teardown` lo mata antes de que bats pueda esperarlo; ese cierre lo comprueba T022 en la pata Linux, con `/proc`.
  - Registrar.

**Checkpoint**: las fixtures reproducen el defecto con una sección escrita en la prueba, en los dos bash, sin Docker.

---

## Phase 3: User Story 1 - El lock queda libre en cuanto termina la sección (Priority: P1), MVP

**Goal**: ninguna sección con lock (el setup, el reindex o el reindex con la migración de 037) deja `.reindex.lock` tomado cuando su función vuelve, por fin normal o por un `return` temprano, y el lock sigue protegiendo la sección mientras corre. Ante una señal al subshell, el lock queda como hoy (contrato `lock-release.md` C2 y C3).

**Independent Test**: `bats tests/qmd-lock-release.bats` en los dos bash. Contra el código actual caen L1, L2, L3, L4, L7 y G1 con la firma del lock tomado; con el arreglo pasan todas.

**Regla de cada prueba de sondeo**:

- **El momento del sondeo**: se toma **inmediatamente** después de que vuelve la función (`_probe_now`, una sola vez), antes de cualquier otra aserción.
- **El orden de las aserciones**: primero las que prueban que la sección corrió de verdad (las llamadas del motor, los vigilantes registrados y el archivo que deja). Al final, `[ "$PROBE_RC" -eq 0 ]`, como **última** línea de la prueba.
- **Por qué**: así el ROJO contra el código actual cae justo en esa línea y no en otra.

- [ ] T009 [US1] ROJO: escribir L1, L2 y L3 en `tests/qmd-lock-release.bats` (`contracts/host-oracle.md` §2):
  - **L1** (FR-001, US1-2), el setup del primer arranque:
    - `install_qmd_stub` y borrar `index.sqlite` y `.qmd-setup-ok` de `$(qmd_cache_root)`;
    - `run qmd_setup_if_needed "$AGENT_YML"` y `_probe_now`;
    - afirmar `status` 0, el log del motor con 3 líneas (`collection add ...`, `update` y `embed`), `.qmd-setup-ok` presente y `_watchdogs` en 3;
    - al final, `PROBE_RC` en 0.
  - **L2** (FR-001, US1-1), el reindex con el vault cambiado y sin índice, así que la migración no aplica (`qmd_collection_migration_state` da `n/a`):
    - `install_qmd_stub`, `qmd_write_state "$QMD_INDEX_STATE_FILE" STALEHASH indexed` y vaciar el log del motor;
    - `run qmd_reindex "$AGENT_YML"` y `_probe_now`;
    - afirmar `status` 0, el log con 2 líneas (`update` y `embed`), `last_status` en `indexed` (`jq`) y `_watchdogs` en 2;
    - al final, `PROBE_RC` en 0.
  - **L3** (FR-001, US1-3), el reindex con la migración de 037 pendiente:
    - `install_qmd_stub`, crear `index.sqlite` en `$(qmd_cache_root)` y el marcador `"$QMD_STUB_DIR/collections/vault"`, dejar sin `.qmd-collection-wiki` y afirmar como precondición que `qmd_collection_migration_state` imprime `pending`;
    - estado `STALE` y vaciar el log;
    - `run qmd_reindex "$AGENT_YML"` y `_probe_now`;
    - afirmar `status` 0, el log con las 7 llamadas medidas en `research.md` M1 (la primera es `collection remove vault`, y el log contiene `cleanup`), `.qmd-collection-wiki` presente y `_watchdogs` en 7;
    - al final, `PROBE_RC` en 0.
- [ ] T010 [US1] ROJO: escribir L4 y L7 en `tests/qmd-lock-release.bats`:
  - **L4** (FR-006), el `bun install` de `_qmd_ensure_prefix`:
    - `export FAKE_TIMEOUT_ONLY=bun`, `install_qmd_stub`, borrar `$(qmd_cache_root)/pkg/.installed-hash` (así `_qmd_ensure_prefix` corre `bun install` con el `bun` falso de `install_qmd_stub`) y borrar `index.sqlite` y `.qmd-setup-ok`;
    - `run qmd_setup_if_needed "$AGENT_YML"` y `_probe_now`;
    - afirmar `status` 0, `.installed-hash` reescrito (el `bun install` corrió y salió bien) y `_watchdogs` exactamente en 1, lo que prueba que el único vigilante es el del `bun install`;
    - al final, `PROBE_RC` en 0. Esta prueba caza M6.
  - **L7** (FR-001, C2), la salida temprana:
    - `export QMD_STUB_FAIL_ONCE=update`, `install_qmd_stub` y borrar `index.sqlite` y `.qmd-setup-ok`;
    - `run qmd_setup_if_needed "$AGENT_YML"` y `_probe_now`;
    - afirmar `status` 0, que `$output` contiene `setup: 'update' failed/timed out` y `retry next boot`, `.qmd-setup-ok` ausente, el log del motor con 2 líneas y `_watchdogs` en 2;
    - al final, `PROBE_RC` en 0.
- [ ] T011 [US1] ROJO: escribir **G1** en `tests/qmd-lock-release.bats` (guardia estructural, `contracts/lock-release.md` I1, I3 e I6). Para cada una de las dos funciones (`qmd_setup_if_needed` y `qmd_reindex`), sobre `_fn_body` con la sangría quitada (`sed 's/^[[:space:]]*//'`):
  - **La línea exacta** `flock -u 9 2>/dev/null || true` aparece una sola vez (`grep -c -x -F`, con `|| true` para que un conteo de 0 no aborte antes de la aserción). Una línea `trap '...' EXIT` que contenga ese texto no cuenta, porque la comparación es de línea completa.
  - **El orden**: su número de línea es mayor que el de la primera llamada a la función de la sección (`_qmd_setup_locked "` o `_qmd_reindex_locked "`) posterior a la línea que empieza con `if ! flock -n 9; then`, y menor que el de la primera línea posterior que empieza con `) 9>"$lock"`, la del cierre del subshell.
  - **Ningún `trap`**: la función no tiene ninguna línea que empiece con `trap`. Esto caza M5, el diseño descartado.
  - La aserción del conteo va primero, así el ROJO de hoy cae en el conteo.
- [ ] T012 [US1] Escribir L5 y L6 en `tests/qmd-lock-release.bats`. Nacen verdes a propósito (FR-002, US1-4):
  - **L5**, el perdedor:
    - **El dueño externo**: lanzar `( exec >/dev/null 2>&1 3>&-; exec 9>"$LOCK"; flock -n 9 || exit 1; exec sleep 30 ) &`, guardar `$!` en `owner.pid` y esperar hasta 5 s, en pasos de 0,1 s, a que un `flock -n "$LOCK" true` falle. Afirmar que el lock quedó tomado.
    - **La corrida**: `install_qmd_stub`, estado `STALE`, vaciar el log, `run qmd_reindex "$AGENT_YML"` y `_probe_now`.
    - **Lo que se afirma**: `status` 0, `$output` con `reindex: already running — skip`, el log del motor vacío (`[ ! -s "$QMD_STUB_LOG" ]`) y `_watchdogs` en 0.
    - Al final, `PROBE_RC` distinto de 0: el lock del dueño sigue tomado. Esta prueba caza M9.
  - **L6**, el lock tomado mientras la sección corre:
    - **El motor envuelto**: tras `install_qmd_stub`, renombrar `$(qmd_cache_root)/pkg/node_modules/.bin/qmd` a `qmd.stub` y escribir un `qmd` envoltorio en `/bin/sh`, ejecutable, con las rutas expandidas al escribirlo. El envoltorio ejecuta `flock -n "<LOCK>" true`, agrega `inner=0` o `inner=1` a `"$TMP_TEST_DIR/inner.log"` según el resultado y termina con `exec "<prefix>/node_modules/.bin/qmd.stub" "$@"`.
    - **La corrida**: estado `STALEHASH` y `run qmd_reindex "$AGENT_YML"`.
    - **Lo que se afirma**: `status` 0, `last_status` en `indexed`, `inner.log` con 2 líneas `inner=1` y ninguna `inner=0` (conteos con `grep -c ... || true`). Esta prueba caza M4.
- [ ] T013 [US1] Registrar el ROJO en el Registro (SC-002), en bash 5.x y en 3.2, con `bats tests/qmd-lock-release.bats` sobre el código actual. Hay 9 pruebas escritas hasta aquí:
  - **Lo esperado**: L1, L2, L3, L4 y L7 caen en su última línea (`[ "$PROBE_RC" -eq 0 ]`); G1 cae en el conteo del `flock -u 9` final; L5, L6 y G2 pasan.
  - **La comprobación**: en la salida de bats, la línea que falla de cada prueba es la prevista, y no un error del arnés. Por ejemplo, un log del motor con otro número de líneas, un `_watchdogs` en 0 porque el `timeout` falso no está primero en el `PATH`, o una precondición de L3 que no da `pending`. Un ROJO por otra razón se corrige ahora y se vuelve a registrar.
- [ ] T014 [US1] Aplicar el arreglo en `scripts/lib/qmd_index.sh` (`contracts/lock-release.md` C1, `research.md` D1):
  - **El cambio**: en `qmd_setup_if_needed` y en `qmd_reindex`, inmediatamente después de la llamada a la función de la sección (`:478` y `:563`) y antes del cierre del subshell (`:479` y `:564`), con la misma sangría, agregar `flock -u 9 2>/dev/null || true`. Es el último comando del subshell. No se agrega ningún `trap` (I6).
  - **El comentario**: se permite una línea de comentario en inglés encima de cada `flock -u 9`, como el resto del archivo. Por ejemplo, `# 044 (#116): BusyBox timeout leaves a watchdog holding fd 9; flock(2) belongs to the open file description, so release it as the last step (not in a trap: a signal must leave it held while a child still runs).`
  - **Lo que no cambia**: el texto del perdedor, el `exit 91`, el `|| rc=$?`, las líneas posteriores, las ramas sin `flock` (`:483-486` y `:568-572`), `_qmd_run` ni `_qmd_ensure_prefix` (I2, I3 e I5).
  - **El diff**: `git diff --stat -- scripts/lib/qmd_index.sh` da 4 inserciones y 0 eliminaciones (2 con el `flock -u 9` y 2 de comentario).
  - **La comprobación estructural** (SC-004, I5; se repite en T027), con un script del scratchpad (`<scratchpad>/044/diff_scope.py`):
    - las 4 líneas agregadas caen dentro de los rangos de líneas de `qmd_setup_if_needed` y de `qmd_reindex`;
    - los cuerpos de `_qmd_run` y de `_qmd_ensure_prefix`, extraídos del árbol y de `git show origin/main:scripts/lib/qmd_index.sh`, son idénticos byte a byte.
    - Registrar.
- [ ] T015 [US1] Punto de control en bash 5.x y en 3.2:
  - `tests/qmd-lock-release.bats` da 9 de 9;
  - `tests/qmd-index.bats` y `tests/qmd-setup.bats` siguen en verde, con sus saltadas por `flock` en macOS y su motivo;
  - `bash -n scripts/lib/qmd_index.sh` con `/bin/bash` y con el bash 5.x del `PATH`.
  - Registrar.

**Checkpoint**: el defecto está cubierto en el host, sin Docker, en los dos bash.

---

## Phase 4: User Story 2 - El arreglo no cambia nada más (Priority: P1)

**Goal**: el tope, las salidas, los códigos de retorno, el log redactado, el modo local y la degradación se comportan igual que hoy (FR-002 a FR-005).

**Independent Test**: L8 en verde, y la suite existente de qmd en verde sin editar ninguna prueba. El tope (SC-004) no tiene prueba en el host y se mide con el `timeout` real en T025.

- [ ] T016 [US2] Escribir **L8** en `tests/qmd-lock-release.bats` (FR-004). Nace verde:
  - **Dos corridas** de `qmd_reindex "$AGENT_YML"` desde el mismo estado inicial (`install_qmd_stub`, estado `STALEHASH` y log vacío): la primera con `FAKE_TIMEOUT_LINGER=0` y la segunda con 3.
  - **Lo que se guarda de cada una**: `status`, la secuencia del log del motor y, del archivo de estado, `last_status`, `pending` y `hash` (`jq -r`).
  - **Lo que se afirma**: las dos corridas son iguales en todos esos campos, con `last_status` en `indexed` y `pending` en 0.
  - **El verde contra el código actual** lo comprueba T023, que corre el archivo final contra el `qmd_index.sh` de `origin/main` (M0).
  - Correr el archivo en los dos bash: 10 de 10.
- [ ] T017 [US2] Punto de control de no regresión, en bash 5.x y en 3.2, en secuencia:
  - **Los archivos**: `bats tests/qmd-index.bats tests/qmd-setup.bats tests/qmd-embed-completion.bats tests/qmd-reindex-cmd.bats tests/qmd-invocation.bats tests/qmd-sqlite-vec.bats tests/qmd-version-guard.bats tests/qmd-watch.bats tests/qmd-e2e-lock.bats tests/qmd-embed-nightly.bats tests/local-qmd.bats tests/start-services-qmd.bats tests/docker-e2e-qmd.bats`. El último carga y se salta limpio sin `DOCKER_E2E`.
  - **Lo esperado**: todo en verde, con las mismas saltadas que en la línea base.
  - **Ninguna prueba existente cambia**: `git diff --stat origin/main -- tests/` muestra solo `tests/qmd-lock-release.bats` y `tests/fixtures/qmd-lock/`, como nuevos (SC-003).
  - **`shellcheck`**: el comando exacto de la CI (`.github/workflows/shellcheck.yml:41-47`), desde la raíz del worktree, sale con 0.
  - Registrar.

**Checkpoint**: US1 y US2 en verde en el host.

---

## Phase 5: Polish (documentos; local, sin compuertas)

**Purpose**: la documentación de FR-013 y FR-014, antes de la revisión y de los commits.

- [ ] T018 [P] Entrada de `CHANGELOG.md` (FR-013), en inglés como las demás, en el primer lugar de `## [Unreleased]` / `### Fixed` (`:151` en `8cb45e4`):
  - **El título**: `qmd's locked sections release .reindex.lock as soon as they end — 044-qmd-lock-fd-leak` (VERSION 0.29.0 → 0.30.0).
  - **El defecto**: el `timeout` de BusyBox 1.36.1 y 1.37.0 deja un vigilante que conserva el descriptor 9 y retiene el lock de 0,9 a 1 s, unos 10 sondeos de 100 ms. Un reindex manual, del cron o del vigilante de archivos que llega en ese segundo se salta con rc 0. Se vio en las cinco nocturnas del 02 al 06-11-2026 (#116).
  - **El arreglo**: un `flock -u 9` como último paso de cada sección. Cubre todos los descendientes porque el lock pertenece a la descripción de archivo abierta. Un `trap ... EXIT` se descartó: soltaba el lock ante un SIGTERM al subshell aunque un qmd hijo siguiera corriendo, que hoy lo retiene.
  - **Lo que no cambia**: el `flock -n` y el perdedor con rc 0, los topes, las salidas, los códigos, el modo local con el `timeout` de GNU (que no tenía el defecto), la degradación sin `flock`, `docker/` y el ayudante de 043.
  - **La verificación**: las 10 pruebas y las 9 mutaciones; 0 sondeos en contenedor con BusyBox 1.36.1 y 1.37.0. Las cifras del DOCKER_E2E y de la CI entran en T032.
  - **Lo que hace falta en la flota**: reconstruir la imagen con el upgrade normal.
  - Sin marcas de borrador: lo pendiente se redacta como estado.
- [ ] T019 [P] Subir `VERSION` de 0.29.0 a 0.30.0 (FR-013). Antes, comprobar a mano `git show origin/main:VERSION` = 0.29.0. Después, `bats tests/version-stamp.bats` en los dos bash.
- [ ] T020 [P] En `CLAUDE.md`, a mano (FR-014):
  - **La viñeta de 043 en «Common gotchas»** (`:238`): la frase que nombra como dueño medido al vigilante del `timeout` (#116) pasa a describir el estado nuevo. Desde 044, cada sección suelta el lock al salir, así que esos vigilantes ya no lo retienen; lo medido antes de 044 se conserva como lo que fue. El ayudante y su regla de uso no cambian (FR-011).
  - **Una entrada de 044 en el bloque de características**, arriba de la de 043 y en su estilo:
    - el origen (#116 y las cinco nocturnas);
    - el diseño: el `flock -u 9` final, por qué cubre a todos los descendientes, y las alternativas descartadas, el `trap` (M8) y `closefd`;
    - las decisiones del operador: el alcance de FR-006 y la corrida manual de CI (06-11-2026), y la forma del arreglo y la medición de SC-004 (07-11-2026);
    - los hallazgos de la Fase 0 (M2 refutó el costo de `$(...)`; M3, GNU sin vigilante) y del análisis (M8);
    - los conteos (10 pruebas, M0 más 9 mutaciones, y el host igual a la línea base más 10) y el estado.
  - **perl como dependencia de prueba**: en «Test deps on the host» (`CLAUDE.md:45`) y en `README.md:430`, una mención de que `tests/qmd-lock-release.bats` usa perl donde el host no tiene `flock`, como en macOS.
  - **No se reescribe** el texto histórico de 043.
  - `CLAUDE.md` está rastreado aunque `.gitignore` lo cubra: `git add CLAUDE.md` funciona, y si `git status` no lo muestra, `git add -f`. Las cifras de la evidencia se agregan en T032.
- [ ] T021 [P] Revisar la documentación que nombra el lock (FR-014):
  - **Los lugares**: `docs/qmd-upgrade-checklist.md:134-145`, `docs/heartbeatctl.md:213` y `:411`, `docs/vault.md:508`, `docs/state-layout.md:264` y lo que encuentre `grep -rn 'reindex.lock\|already running' docs/ README.md`.
  - **El criterio**: se cambia solo el texto que describa el lock retenido después de una sección. La lectura del 07-11-2026 no encontró ninguno; la checklist describe la espera de 043 y al dueño en general, sin nombrar al vigilante.
  - **Si cambia la checklist**: correr `tests/qmd-embed-nightly.bats`, que con G3 guarda el encabezado que cita, en los dos bash.
  - Registrar la decisión, archivo por archivo.

---

## Phase 6: User Story 3 - La corrección se demuestra y se vigila (Priority: P2)

**Goal**: el ROJO antes del VERDE, el `timeout` real confirmando el arreglo, la integración en contenedor y en CI, y el registro de las noches posteriores (FR-007 a FR-010).

**Independent Test**: las tablas del Registro de T022 a T027 y T030, con sus identificadores y cifras.

- [ ] T022 [US3] Pata Linux del oráculo (sin COMPUERTA; contenedor desechable `--rm` de unos minutos; se avisa antes de empezar). El `flock` de util-linux es el de producción, y el host macOS no lo tiene. La herramienta es `<scratchpad>/044/linux_leg.sh`, con un driver en Python:
  - **El entorno**: `ubuntu:24.04` (bash 5.2.21, el de la CI).
    - Como root, solo para instalar `jq`, `git` y `ca-certificates` con `apt-get`, y el `yq` v4.44.3 de la CI (`yq_linux_arm64` en este Mac).
    - Las pruebas corren como `--user 1000:1000`, con `HOME` escribible y una copia del repo que el contenedor no escribe.
    - bats 1.11.0, el de la CI en Linux: se clona el tag en el scratchpad y se revisa antes de ejecutarlo.
    - SIGPIPE ignorada, como la entrega el runner: `perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats ...`.
  - **La comprobación previa**: el log muestra `command -v flock` en `/usr/bin/flock`. Así la prueba usa el de util-linux y no la fixture en perl.
  - **El cierre del descriptor 3**: mientras vive un vigilante de la fixture lanzado con un descriptor 3 abierto, `ls -l /proc/<pid>/fd` muestra el 9 y no el 3 (C1 del análisis). Es una comprobación de la herramienta, no una prueba versionada.
  - **Lo esperado**:
    - con el árbol de la rama, `tests/qmd-lock-release.bats` da 10 de 10;
    - con el `qmd_index.sh` de `origin/main`, caen L1, L2, L3, L4, L7 y G1 con la misma firma de T013.
  - Registrar.
- [ ] T023 [US3] Ejecutar el catálogo de mutaciones de `contracts/host-oracle.md` §3 contra la implementación real (SC-002). Se corre con `<scratchpad>/044/mutate_044.py`:
  - **Dónde se aplica**: sobre copias aisladas de los archivos que lee el oráculo (`tests/helper.bash`, `tests/qmd-lock-release.bats`, `tests/fixtures/qmd-lock/` y `scripts/lib/qmd_index.sh`), nunca sobre el árbol de trabajo, y como usuario no root.
  - **Cómo se aplica**: el corredor aplica cada mutación, corre solo `tests/qmd-lock-release.bats` y restaura. Exige que el texto a mutar aparezca exactamente las veces previstas; si no, la mutación se declara rota y no corre.
  - **M0**: el archivo final contra el `qmd_index.sh` de `origin/main`. Caen L1, L2, L3, L4, L7 y G1, y pasan L5, L6, L8 y G2: es el verde de las cuatro que nacen verdes contra el código actual.
  - **M1 a M9**, en bash 5.x y en 3.2 en el host, y otra vez en la pata Linux de T022. Cada una cae por las pruebas de su fila. M5, M7 y la falta de `2>/dev/null || true` solo las caza G1, por diseño. La diferencia de M5 con el arreglo final es la de una señal al subshell, y la mide T025.
  - **Una que sobreviva**: se endurece la prueba, con su ROJO visto antes, o se declara equivalente con la razón. Las nuevas se suman desde M10.
  - Registrar la tabla: mutación, pruebas que cayeron y bash.
- [ ] T024 [US3] Revisión independiente de solo lectura (agente `code-reviewer`; si el operador lo pide, un workflow de lentes con escépticos), antes de las corridas en contenedor y del gate. Cubre el diff de `scripts/lib/qmd_index.sh`, las dos fixtures, `tests/qmd-lock-release.bats` y los documentos de T018 a T021:
  - **Durante la revisión** no se corren `bats` ni `docker` dentro de los agentes.
  - **Cada hallazgo** se clasifica, y los que correspondan se corrigen con su ROJO y su VERDE.
  - **Lo que se busca a propósito**:
    - pruebas que pasan en vacío, como un sondeo sobre otro archivo, un `_watchdogs` que no prueba que el `timeout` falso se usó o una precondición que no se afirma;
    - un sondeo tomado tarde, o después de una aserción lenta;
    - el poder discriminante de L8, que ninguna mutación del catálogo pone en rojo;
    - procesos o descriptores que quedan vivos tras la prueba, incluido el 3 de bats;
    - una diferencia de semántica entre el `flock` en perl y el de util-linux;
    - la fragilidad de la extracción de `_fn_body` en G1;
    - el `set -e` de bats con `$(...)` y `grep -c`, y el `PATH` frente al `bin` que antepone `install_qmd_stub`;
    - la hermeticidad: el `timeout` o `gtimeout` del host, un host con `flock`, root, la arquitectura;
    - aserciones intermedias muertas en bash 3.2;
    - que el comentario del `flock -u 9` diga la verdad;
    - que ninguna función que corre bajo la sección tenga un `exit`, que saltaría el último paso (`contracts/lock-release.md` C3).
  - Registrar.
- [ ] T025 [US3] Confirmación con el `timeout` real (etapa 6 de `contracts/evidence-protocol.md`; SC-001 y SC-004; sin COMPUERTA, son contenedores desechables `--rm` con imágenes en caché; se avisa antes de empezar):
  - **La huella**: antes de empezar, la huella sha256 de los archivos modificados o nuevos del árbol. Debe ser la misma en T026 y en T027.
  - **Las herramientas**: `<scratchpad>/044/cont.py` y `cont_inside.sh`, de la Fase 0, con dos variantes. La actual es el `scripts/lib` de `origin/main` (`<scratchpad>/044/lib-current`, regenerado desde `git show`). La final es una copia del `scripts/lib` del árbol.
  - **Las imágenes**: `alpine:3.24.1` (BusyBox 1.37.0), `alpine:3.20` (1.36.1) y `ubuntu:24.04` (GNU), con `bash`, `jq`, `flock` y `yq-go`.
  - **Los casos**: el setup, el reindex y el reindex con migración, 3 repeticiones cada uno, y el perdedor con el lock tomado.
  - **El caso nuevo de SC-004**: un motor que hace `exec sleep 30` en `update`, con `QMD_CMD_TIMEOUT=2`.
    - Se registra el código de `_qmd_run "$pkg" update` y los sondeos tras un setup que cae por ese tope.
    - Lo esperado es 143 en BusyBox y 124 en GNU, el mismo en las dos variantes.
  - **El caso de la señal** (`research.md` M8; caso borde del spec), solo en BusyBox, que es la imagen de producción:
    - un motor que, en `update`, anota `$PPID` y hace `exec sleep 30`. BusyBox `timeout` hace `exec` del comando en su propio proceso, así que `$PPID` es el subshell de la sección; la herramienta lo confirma con `/proc/$PPID/comm` (`bash`);
    - se manda SIGTERM a ese PID y, 0,5 s después, se registra si el motor sigue vivo (`kill -0`) y si un `flock -n` obtiene el lock;
    - lo esperado es el lock tomado mientras viva el motor, con la variante actual y con la final. Con la variante descartada del `trap` (`<scratchpad>/044/lib-unlock`), medida como referencia, el lock queda libre;
    - después se mata el motor y se comprueba que el lock quedó libre.
  - **Lo esperado con la variante final**: 0 sondeos en todas las celdas, y el perdedor con rc 0 y `already running`. Con la actual, 10 sondeos en BusyBox y 0 en GNU.
  - Registrar la tabla.
- [ ] T026 [US3] COMPUERTA (Docker, unos 20 a 35 minutos más la reconstrucción de `agent-admin:qmd-real` y `agent-admin:qmd-embed`): el DOCKER_E2E local de qmd sobre el árbol de T025, en arm64 (etapa 7; FR-008 y FR-009):
  - **La orden**: `DOCKER_E2E=1 QMD_EMBED_E2E=1 QMD_E2E_MODELS_DIR="$HOME/.cache/agentic-qmd-e2e/models-041" bats --tap tests/docker-e2e-qmd.bats`, con una marca de tiempo por línea. La salida pasa por un bucle que lee todo y antepone `date +%s`; ahí la tubería es segura porque el consumidor no cierra antes.
  - **Lo esperado**: `ok` en las cinco pruebas del archivo (la 12 a la 16 en la numeración del nightly), y `qmd real (041)` con sus ocho marcas en orden.
  - **Lo que se registra**: la duración, el pico de memoria, el costo de reconstruir las imágenes y si el segundo tick de la prueba 13 reportó `reindex lock busy`, con los dueños que nombró. Se espera que no aparezcan dueños `timeout 900 .../qmd`; es una observación (SC-005), no una aserción.
  - **Ante un rojo**: uno del arnés, acotado, se corrige aquí; uno del producto detiene la secuencia y se avisa al operador.
- [ ] T027 [US3] Gate completo sobre un árbol congelado (etapa 5; SC-003):
  - **La huella**: la misma de T025, comprobada antes, entre las dos corridas y después; `git status` y `HEAD` sin cambios.
  - **Las corridas**: `bats tests/` en bash 5.x y `PATH=/bin:$PATH bats tests/` en 3.2.57, en secuencia, unos 36 minutos.
  - **Lo esperado**: la línea base de T003 más 10, con 0 `not ok`, la salida de error vacía y las mismas saltadas que en T003, porque las pruebas nuevas no saltan en macOS.
  - **Las verificaciones**:
    - `shellcheck` con el comando de la CI en 0;
    - `git diff --stat origin/main` limitado a `scripts/lib/qmd_index.sh`, `tests/qmd-lock-release.bats`, `tests/fixtures/qmd-lock/`, `VERSION`, `CHANGELOG.md`, `CLAUDE.md`, `README.md`, los documentos de `docs/` que haya cambiado T021 y `specs/044-qmd-lock-fd-leak/`;
    - la comprobación estructural de T014, repetida sobre el árbol congelado.
  - **Que no quede nada**: tras las corridas, ningún `sleep` de vigilante falso vivo.
  - Registrar.
- [ ] T028 [US3] COMPUERTA (commits locales): dos commits sobre la rama, en español, ASCII, en imperativo, sin atribución y con la identidad por variables de entorno:
  - **El commit 1, `docs:`**: `CLAUDE.md`, la documentación de T021 si cambió y lo que cambió en `specs/044-qmd-lock-fd-leak/` desde T002, entre ello las marcas y el Registro de este archivo.
  - **El commit 2, `fix:`**: `scripts/lib/qmd_index.sh`, `tests/qmd-lock-release.bats`, `tests/fixtures/qmd-lock/timeout`, `tests/fixtures/qmd-lock/flock`, `CHANGELOG.md` y `VERSION`, juntos porque el oráculo y el arreglo se prueban entre sí.
  - **Los modos** (`git ls-files -s`): las dos fixtures en 100755, y el resto de los archivos existentes con su modo de siempre.
  - **Ninguno deja la suite en rojo**, comprobado en un worktree desechable del scratchpad por commit, que se quita al terminar:
    - el commit 1 con `tests/qmd-index.bats` en verde;
    - el commit 2 con `tests/qmd-lock-release.bats` en 10 de 10 y `tests/version-stamp.bats` en verde.
  - Sin push.
- [ ] T029 [US3] COMPUERTA (push): empujar `044-qmd-lock-fd-leak` por HTTPS con el helper de `gh` y sin force, con `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher.git 044-qmd-lock-fd-leak`.
  - Verificar con `git ls-remote`, por el mismo camino, que la cabeza remota es la local.
  - El push de una rama sin PR no dispara `test.yml` ni `shellcheck.yml`.
- [ ] T030 [US3] COMPUERTA (dispatch, FR-009): `gh workflow run docker-e2e.yml --ref 044-qmd-lock-fd-leak`. Seguir la corrida con un monitor del scratchpad y, al terminar, descargar el log.
  - **Antes de buscar nada en el log**, comprobar que trae `e2e summary:` y `GNU bash, version` (`gh run view <id> --log`; con `gh api .../jobs/<id>/logs` hace falta `--allow-escape-sequences`).
  - **Lo que se registra**:
    - el identificador, la rama y el commit;
    - `started_at` y `completed_at` del job por la API de jobs, la duración y el margen frente a 45 minutos;
    - la línea TAP de la prueba 16 (`ok` ejecutada, no saltada) y sus ocho marcas;
    - `e2e summary:`, con `total=49 executed=49 skipped=0 failed=0` como esperado;
    - si apareció `reindex lock busy` en el segundo tick de la prueba 13, y quién tenía el lock.
  - **Ante un rojo**: se clasifica como del arnés, del producto o de infraestructura, con su fragmento de log, antes de seguir.
- [ ] T031 [P] [US3] COMPUERTA (issue; sale del equipo): proponer al operador un issue propio para el hallazgo lateral de `research.md` D5. La migración manual corre sin el lock:
  - en docker, `docker/scripts/heartbeatctl:1157-1194`;
  - en local, `scripts/agentctl:1703-1709` y `modules/local-qmd-reindex.sh.tpl:54-61`;
  - contra lo que dice el comentario de `scripts/lib/qmd_index.sh:336-340`.

  Va con la lectura de código y sin arreglo en esta feature (Out of Scope). Se puede hacer en cualquier momento después de T002.

---

## Phase 7: Cierre

- [ ] T032 COMPUERTA (commit y push): rebasar sobre `origin/main` si se movió. Después, verificar `VERSION` a mano contra `origin/main`: git no avisa cuando dos ramas escriben el mismo número.
  - **El ajuste**: las cifras reales de T025, T026 y T030 entran en `CHANGELOG.md`, `CLAUDE.md` y el Registro.
  - **Las verificaciones**: un byte audit de los archivos tocados, `tests/qmd-lock-release.bats` y `tests/version-stamp.bats` en los dos bash, y un commit `docs:` empujado por el camino de T029.
- [ ] T033 COMPUERTA (PR): abrir el PR contra `main` con la tabla de evidencia de T013, T022, T023, T025, T026, T027 y T030, y `Closes #116` solo si están registradas T013, T025 y T030; si falta una, se omite.
  - **Antes de abrirlo**: `git diff --stat origin/main -- docker modules setup.sh .github` debe estar vacío (FR-012).
  - **Lo que debe mostrar la CI**: el esperado vigente (T003 más 10) en los dos brazos de bash, con las 2 saltadas más que trae un PR frente a `main` (las dos pruebas `037 claude-md.tpl`).
  - **Si un brazo cae solo en la CI**: reproducirlo en local, con SIGPIPE ignorada y con la pata Linux de T022, antes de tocar nada. El arreglo pasa por la COMPUERTA de commit y push.
- [ ] T034 COMPUERTA (merge del operador): no se propone antes de que termine la décima noche de T046 de 043 (hacia el 11-11-2026). Después del merge, verificar en `origin/main`:
  - el árbol igual al de la cabeza validada;
  - `VERSION` en 0.30.0;
  - las dos líneas `flock -u 9` finales presentes, y ningún `trap` en las secciones;
  - #116 cerrado por el PR; si no, COMPUERTA para cerrarlo con la evidencia.
- [ ] T035 COMPUERTA: registrar las cinco primeras nocturnas después del merge (FR-010, SC-005, SC-006). De cada una:
  - el run, la duración del job por la API de jobs y el margen frente a 45 minutos;
  - la línea TAP de la prueba 16 y `e2e summary:`;
  - si el segundo tick de la prueba 13 reportó `reindex lock busy` y con qué dueños, cada dueño clasificado;
  - la clasificación de cualquier rojo.

  Es una observación y no la demostración, que son T013, T022, T023 y T025. Los apuntes van a un PR de documentos aparte, como el T046 de 043. Un dueño que no sea el cron, el vigilante de archivos ni el setup se avisa al operador antes de seguir.
- [ ] T036 COMPUERTA: limpieza, con confirmación del operador para lo que salga de la sesión:
  - los worktrees desechables del scratchpad (`git worktree remove` y `git worktree prune`);
  - ofrecer quitar las etiquetas de imagen que dejó T026; el caché de build se conserva;
  - borrar la rama `044-qmd-lock-fd-leak`, remota y local, y su worktree solo cuando el operador lo pida, tras el merge y el registro de las noches.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**:
  - T001 y T002 primero; T002 antes de cualquier otro commit.
  - T003 dura unos 36 minutos y corre sobre una copia aislada, así que T004 y la escritura de T005 a T012 pueden avanzar mientras tanto, sin correr `bats` en el worktree.
- **Foundational (Phase 2)**: T005 y T006 en paralelo, T007 después y T008 al final. Bloquea todas las historias.
- **US1 (Phase 3)**: después de la fase 2. Es el MVP.
  - T009 a T012 (las pruebas) y T013 (el registro del ROJO) antes de T014 (el arreglo) y T015 (el punto de control).
  - Todo es el mismo archivo de pruebas, así que va en orden.
- **US2 (Phase 4)**: después de US1, porque L8 se escribe con el arreglo puesto y T017 lo exige. Su verde contra el código actual lo da M0 en T023.
- **Polish (Phase 5)**: después de US2. T018 a T021 son paralelas entre sí.
- **US3 (Phase 6)**: después de Polish, en este orden:
  - T022 antes de T023, porque las mutaciones también corren en la pata Linux;
  - T024 después de T023;
  - T025 y T026 sobre el árbol que deja la revisión, y T027 después;
  - T028, T029 y T030, cada una con su compuerta y en ese orden;
  - T031 en cualquier momento después de T002.
- **Cierre (Phase 7)**: después de T030. T034 a T036 solo existen después del merge.

### Within Each User Story

- El ROJO se registra antes de cada VERDE. Las pruebas que nacen verdes lo dicen en su tarea, y M0 o las mutaciones las ponen a prueba.
- Las tareas sobre `tests/qmd-lock-release.bats` van en orden.
- Cada punto de control corre en bash 5.x y en 3.2, en forma secuencial.

### Parallel Opportunities

- T003 (la línea base, en su copia aislada) con T004 y con la escritura de T005 a T012.
- T005 y T006 (fixtures distintas).
- T018, T019, T020 y T021 (documentos distintos).
- T031 (el issue lateral), en cualquier momento después de T002.
- Las corridas en contenedor (T022, T025 y T026) no se solapan entre sí ni con un gate: comparten Docker Desktop y la CPU del Mac, y en 027 dos suites de bats a la vez dieron rojos que no existían.

---

## Parallel Example: Foundational y Polish

```bash
# Mientras T003 corre en su copia aislada:
Task: "T005 Fixture timeout con la forma de BusyBox en tests/fixtures/qmd-lock/timeout"
Task: "T006 Fixture flock en perl en tests/fixtures/qmd-lock/flock"

# Después del punto de control de T017, en paralelo y en archivos distintos:
Task: "T018 Entrada de CHANGELOG.md"
Task: "T019 VERSION 0.30.0"
Task: "T020 Viñeta y bloque de 044 en CLAUDE.md"
Task: "T021 Revisión de docs/ que nombran el lock"
# Después, en serie: T022 (pata Linux), T023 (mutaciones), T024 (revisión), T025 (contenedor), T026 (DOCKER_E2E), T027 (gate), T028 a T030 (commits, push y dispatch).
```

---

## Implementation Strategy

### MVP primero (US1)

1. Setup y Foundational: la línea base, las fixtures y G2 en verde.
2. US1: las seis pruebas en ROJO, L5 y L6, el arreglo de dos líneas y el punto de control en VERDE.
3. **Validar**: `tests/qmd-lock-release.bats` en 9 de 9 en los dos bash. Desde aquí, el defecto de #116 está cubierto en el host. La confirmación con el BusyBox real llega en US3.

### Entrega incremental

1. US2: L8 y la suite de qmd sin cambios, con `shellcheck`.
2. Polish: CHANGELOG, `VERSION` y `CLAUDE.md`.
3. US3: la pata Linux, las mutaciones, la revisión, el `timeout` real en contenedor, el DOCKER_E2E, el gate, los commits, el push y la corrida manual de CI.
4. Cierre: PR, merge del operador (no antes del 11-11-2026), las cinco noches y la limpieza.

Todo se mergea en un solo PR, y solo después de la evidencia: ninguna fase intermedia se publica sola.

---

## Notes

- **[P]**: archivos distintos y sin dependencias abiertas.
- No hay commits hasta T002, ni push hasta T029. La regla genérica de la plantilla («commit after each task») no aplica en este repositorio.
- **Aserciones intermedias muertas**: ningún `[[ ]]` ni `!` intermedio en las pruebas nuevas.
  - Se usan `[ ]`, `grep -q`, `case` o `run`, y un negativo se expresa como `if comando; then false; fi`.
  - Un `[[ ]]` es letra muerta solo en bash 3.2; un `!`, en los dos.
  - `grep -c` sale con 1 cuando cuenta 0: dentro de `$(...)` va con `|| true`, para que el `set -e` de bats no aborte antes de la aserción.
- **El canal de bats**: un proceso en segundo plano que conserva el descriptor 3 demora el reporte de la prueba. Lo cierran el vigilante falso, el dueño externo de L5 y cualquier proceso que una prueba deje vivo, y el `teardown` los mata.
- **Hermeticidad**: las pruebas nuevas no pueden depender del sistema del host.
  - El `timeout` falso va siempre primero en el `PATH`, aunque el host tenga uno.
  - El `flock` en perl solo se instala si el host no tiene `flock`.
  - La CI corre ubuntu amd64 (util-linux) y macOS arm64 (perl), y las mutaciones corren como no root.
- **Git y GitHub**:
  - Los pushes van por HTTPS con el helper de `gh`, y los commits con la identidad por variables de entorno.
  - No se usa `git stash` sin etiqueta, porque la pila se comparte con los demás worktrees.
  - Tras cualquier rebase, `VERSION` se verifica a mano contra `origin/main`.
- **Logs de CI**: se descargan con `gh run view <id> --log` y se comprueba que traen `GNU bash, version` o `e2e summary:` antes de contar nada. Un log vacío cuenta cero en silencio.
- **Harness de la sesión**: los comandos compuestos o calculados se rechazan. Se usan rutas literales y scripts del scratchpad (`python3 ruta`), que salen con el código del comando que miden.
- **Carga y contención**: no se corren dos suites de bats a la vez. Un rojo se vuelve a medir en aislamiento, y se nombra su mecanismo antes de llamarlo flake.
- **Hallazgos al generar las tareas (07-11-2026)**, ya corregidos en los artefactos:
  - **H1**: M9 de `contracts/host-oracle.md` decía «`exit 0` en la rama del perdedor», que es equivalente: `qmd_reindex` devuelve 0 con 91 y con 0. Se reemplazó por «quitar el `exit 91`», con el que el perdedor sigue a la sección sin el lock y L5 lo caza porque el motor se llama.
  - **H2**: el contrato del oráculo y `research.md` D1 decían que las pruebas existentes guardan el tope. `QMD_CMD_TIMEOUT` y `QMD_INSTALL_TIMEOUT` no aparecen en `tests/`. SC-004 se mide con el `timeout` real en la etapa 6 (T025), con un motor colgado. Se corrigieron `contracts/host-oracle.md` §1, `research.md` D1, `contracts/evidence-protocol.md` (etapa 6) y `quickstart.md` V4. No se agrega una prueba versionada: el arreglo no toca `_qmd_run` (I5).
  - **H3**: el `timeout` falso de la Fase 0 dejaba al vigilante con el descriptor 3 de bats, lo que demora el reporte, y con un `sleep` hijo, así que un `kill` al PID registrado no soltaba el descriptor 9. La fixture cierra el 3, termina en `exec sleep` y registra su PID en `FAKE_TIMEOUT_PIDFILE`. Se corrigió `contracts/host-oracle.md` §1.
  - **H4**: `contracts/evidence-protocol.md` ponía el gate (5) antes del contenedor (6) y del DOCKER_E2E (7). Se agregó la nota de orden: 6 y 7 primero, como en 043.
  - **H5** (superado por el análisis): M5 era un `trap ... RETURN`, y se midió que es observable, porque un `trap` de `RETURN` armado en el subshell no se dispara al volver una función (`<scratchpad>/044/return_trap.sh`, bash 3.2.57 y 5.3.15). Con el arreglo revisado, M5 es el `trap ... EXIT` descartado, y la medición queda en `research.md` M8 como dato.
  - **H6**: L8 no tiene ninguna mutación en el catálogo que la ponga en rojo. Guarda FR-004 como regresión, y T024 revisa su poder discriminante. Si la revisión encuentra una mutación que debería cazar, se suma desde M10.
- **Hallazgos de `/speckit-analyze` (07-11-2026)**: 14 hallazgos (0 CRITICAL, 2 ALTA, 3 MEDIA y 9 BAJA). El operador aprobó remediarlos todos y tomó dos decisiones, registradas en la sesión de Clarifications del 07-11-2026 del spec:
  - **F1 (ALTA)**: medido en bash 3.2.57 y 5.3.15 (`research.md` M8), el `trap ... EXIT` soltaba el lock ante un SIGTERM al subshell con un qmd hijo vivo, lo que contradecía el caso borde del spec. **Decisión**: un `flock -u 9` como último paso de cada sección, medido con 0 sondeos con las secciones reales (M9). Cambiaron D1, el contrato `lock-release.md` (C1 a C3 e I6), G1, M4, M5 y M7, el modelo de datos, el quickstart y T001, T011, T014, T018, T020 y T025, que ahora mide también la señal en BusyBox.
  - **E1 (ALTA)**: SC-004 y la prueba independiente de US2 pedían pruebas nuevas y una medición en el host para el tope. **Decisión**: se ajusta el spec. El tope se mide con el `timeout` real en contenedor (T025), con una comprobación estructural del diff (T014 y T027), y se mantienen las 10 pruebas.
  - **E2 (MEDIA)**: `QMD_INSTALL_TIMEOUT=0` no tenía tarea. Lo cubre la comprobación estructural: `_qmd_ensure_prefix` es idéntica a `origin/main`.
  - **E3 (MEDIA)**: SC-006 prometía medir los saltos del cron y del vigilante de archivos, y no se puede: el workspace del e2e se borra en el `teardown` y el vigilante descarta su salida. Se reescribió para lo medible, los cuatro sitios manuales del e2e, y declara lo demás sin medir.
  - **F2 (MEDIA)**: SC-002 y el principio III del plan decían que caen las 10 pruebas; ahora nombran las seis que caen y las cuatro que nacen verdes.
  - **BAJA**: B1 (el 137 de US2, que no se puede dar sin `-k`); F3 (el comentario admitido en I2 y en el plan); F4 (la condición de `Closes #116`, alineada entre el protocolo y T033); F5 (la lista de archivos permitidos en el diff de T027 y de la etapa 5); C1 (T008 ya no atribuye a la duración el cierre del descriptor 3, que mide T022); F6 (M0 en el catálogo); C2 (el pendiente 3 de research, cerrado); C3 (perl documentado como dependencia de prueba, en T020); B2 (las cinco primeras noches, fijadas en FR-010 y SC-005).
  - **Además**, al verificar las anclas se corrigieron las líneas del perdedor en T001, que son `:477` y `:562` y no `:476` y `:561`.
- **Cifras de partida** (después del análisis): 10 pruebas nuevas, el control M0 más 9 mutaciones (M1 a M9), 3 historias, FR-001 a FR-014 y SC-001 a SC-006. Esperado de la suite del host: la línea base de T003 más 10 por bash (1894 + 10 = 1904 si `origin/main` sigue en `8cb45e4`). El resumen del nightly sigue en `total=49`.

### Registro (se completa durante la implementación)

- **Punto de partida (T001, 07-11-2026, solo lecturas)**:
  - **El remoto**: `git ls-remote` por HTTPS con el helper de `gh` da `refs/heads/main` en `8cb45e47ba6f87e4c849a34d80008181b994c6e6`, es decir `8cb45e4`, sin cambios. `git show origin/main:VERSION` da 0.29.0.
  - **Los PR abiertos**: `gh pr list --state open` no devuelve ninguno.
  - **El estado local**: `git status --short` muestra solo `.specify/feature.json` modificado (`M`) y `specs/044-qmd-lock-fd-leak/` sin rastrear (`??`).
  - **Las anclas** (`<scratchpad>/044/scan_anchors.py`): las líneas del perdedor aparecen una sola vez, en `:477` (setup) y `:562` (reindex). Les siguen la llamada de la sección (`:478` y `:563`) y el cierre del subshell `) 9>"$lock" || rc=$?` (`:479` y `:564`). Las ramas sin `flock` están en `:486` y `:571`. El archivo tiene 0 apariciones de la palabra de la regla I6. Ninguna de las ocho funciones que corren bajo el lock tiene un `exit` (`_qmd_setup_locked`, `_qmd_reindex_locked`, `qmd_migrate_collection`, `_qmd_embed_until_complete`, `_qmd_pending_count`, `_qmd_run`, `_qmd_ensure_prefix`, `_qmd_swap_sqlite_vec`), lo que confirma C3.
  - **Los archivos de ignorar**: `.gitignore` existe y trae `.DS_Store`, `*.tmp`, `*.swp` y `/.state/`. No se crea `.dockerignore` ni se agregan patrones (stack de shell; la feature no toca `docker/`).
  - **La identidad**: el autor de `8cb45e4` y de `ef2f4cf` es `Rodrigo Andres Hinojosa Acuña <rodrigo.hinojosa.developer@gmail.com>`; el `user.email` del repo es otro (`rodrigo.hinojosa@cencosud.cl`), así que T002 y T028 usan las cuatro variables de entorno.
- **Línea base (T003)**: Pendiente.
- **Docker y modelos (T004)**: Pendiente.
- **Arnés (T008)**: Pendiente.
- **ROJO y VERDE (T013, T015, T016, T017)**: Pendiente.
- **Documentos (T018 a T021)**: Pendiente.
- **Pata Linux (T022)**: Pendiente.
- **Mutaciones (T023)**: Pendiente.
- **Revisión independiente (T024)**: Pendiente.
- **Confirmación con el `timeout` real (T025)**: Pendiente.
- **DOCKER_E2E local (T026)**: Pendiente.
- **Gate (T027)**: Pendiente.
- **Commits, push y CI (T028 a T030)**: Pendiente.
- **Issue lateral (T031)**: Pendiente.
- **PR, merge y noches (T033 a T035)**: Pendiente.
