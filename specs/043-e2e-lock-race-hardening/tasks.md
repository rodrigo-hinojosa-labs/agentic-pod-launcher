---

description: "Tareas de 043-e2e-lock-race-hardening: los e2e de qmd esperan al .reindex.lock y dejan de caer por la carrera"
---

# Tasks: Los tests e2e de qmd dejan de caer por la carrera del `.reindex.lock`

**Input**: `specs/043-e2e-lock-race-hardening/` ([spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [quickstart.md](quickstart.md), [contracts/](contracts/))

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: obligatorios y primero (Principio III; FR-010). Las 26 pruebas nuevas de `contracts/host-oracle.md` (L1 a L10, X1 a X6, O1, O2, B1 a B6, D1 y D2) y la enmienda de P1 se escriben y se ven en ROJO antes de su implementación, en bash 5.x y en 3.2, y cada una por la razón prevista; ninguna nace en verde a propósito. L, X, O, D1 y D2 caen porque `tests/helper-qmd-e2e.bash` no existe (D1 lee la constante del ayudante: hallazgo H1 de las Notes); B1 a B6 y la P1 enmendada caen por el contenido actual de `tests/docker-e2e-qmd.bats`. Una prueba que no puede fallar no es evidencia: el catálogo de 39 mutaciones en los dos bash (M1 a M34 y M37 a M41, estas cinco del análisis del 31-10-2026), más M35 y M36 en la pata Linux, las pone a prueba en T031 y T032 (SC-004).

**Organization**: por historia, en orden de **dependencia** sobre el mismo ayudante y los mismos archivos de pruebas, y no de prioridad (precedente de 040, 041 y 042):

```text
US1 (P1) -> US2 (P1) -> US3 (P2) -> US4 (P2)
```

- US1 va primero porque crea el ayudante `tests/helper-qmd-e2e.bash`, que usan las demás historias, y migra el sitio de la falla medida (la fase `reindex` de `qmd real (041)`, #112).
- US2 migra los otros tres sitios (el bucle y el segundo tick de la prueba 13 y la fase 3 de la prueba 12) con el ayudante ya probado.
- US3 agrega el dueño del lock al estado al fallar (`_embed_failure_state`).
- US4 es la evidencia: la inyección de falla, el DOCKER_E2E local, el gate completo, la corrida manual de CI y las noches.

**Orden de las pruebas dentro de las historias** (decisiones de este archivo, ver las Notes):

- O1 y O2 son de US3 pero se escriben y se implementan en la fase de US1, porque la sonda del dueño vive en el mismo archivo que la espera y `qmd_e2e_reindex_wait` la llama (R-BUSY). La fase de US3 solo agrega lo que falta: B4 y `_embed_failure_state`.
- B5 se escribe en US2 y no en US1: solo puede pasar cuando los cuatro sitios usan el ayudante, y en US1 dejaría el punto de control en rojo.

**Orden de la evidencia**: las corridas de Docker (T035 a T037) van antes del gate completo (T038), como hizo 042 con su DOCKER_E2E (T022 antes de T023). El cableado real del ayudante (las comillas del `sh -c` a través de `docker compose exec`, `vault_hash` por `bash -lc`) solo se ejercita en un contenedor, y un defecto que aparezca ahí obliga a editar el ayudante y a repetir el gate (unos 40 minutos por los dos bash): con este orden el gate corre una sola vez, sobre el árbol final.

**Compuertas**: cada commit, push, `workflow_dispatch`, creación o borrado de una rama remota, issue, PR y merge exige la confirmación explícita del operador, CADA VEZ, y está marcado COMPUERTA. Las corridas locales que ocupan Docker Desktop (T035, T036 y T037, de unos 20 a 50 minutos cada una, con 4 a 5 GiB de memoria) también la llevan. T027 y T031 no: corren en contenedores desechables `--rm` de unos minutos que solo bajan una imagen base (precedente de T021 de 042), y se avisa antes de empezar. Nada se commitea antes de T002. No existe ningún hook de contexto de agente que ejecutar (`hooks: {}`). No se tocan los worktrees de 040, 041 ni 042, ni los contenedores ni las imágenes del operador que no sean de las pruebas; todo `docker exec` de esta feature pasa por `-u agent` (Principio II). El merge es siempre del operador.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: se puede hacer en paralelo (archivos distintos, sin dependencia de una tarea abierta)
- **[Story]**: la historia del spec a la que sirve la tarea (US1 a US4)
- Las rutas son relativas a la raíz del worktree `.claude/worktrees/043-e2e-lock-race-hardening`.
- Las herramientas de medición, de inyección y de auditoría viven en el scratchpad de la sesión (`scratchpad/043/`) y no se versionan.
- Las pruebas de `tests/docker-e2e-qmd.bats` se nombran como en el spec, con la numeración del nightly: la 12 es `qmd e2e: first-boot...`, la 13 y la 14 son las dos de `qmd e2e (037)`, la 15 es `qmd real (016)` y la 16 es `qmd real (041)`. Corriendo solo ese archivo, bats las numera de 1 a 5.

---

## Phase 1: Setup

**Purpose**: confirmar el punto de partida, medir la línea base y comprobar lo que necesita la evidencia, antes de tocar nada.

- [X] T001 Verificar, solo con lecturas, y registrar en el Registro de este archivo:
  - que `origin/main` sigue en `cd8b74f` (`git rev-parse --short origin/main` y, contra la red, `git -c credential.helper='!gh auth git-credential' ls-remote https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher.git refs/heads/main`; el remoto `origin` es SSH y pertenece a otra cuenta); si se movió, `git fetch` por el mismo camino y anotar qué archivos cambiaron (lo esperable, si #115 mergeó, es `CLAUDE.md` y dos `tasks.md`);
  - `git show origin/main:VERSION` = 0.29.0;
  - el estado del PR #115 (cierre documental de 042) y de cualquier otro PR abierto que toque `tests/docker-e2e-qmd.bats`, `tests/qmd-embed-nightly.bats` o `CLAUDE.md` (`gh pr list --state open`);
  - `git status --short` del worktree: solo `.specify/feature.json` modificado y `specs/043-e2e-lock-race-hardening/` sin rastrear;
  - las nocturnas desde la del 30-10-2026 (`gh run list --workflow docker-e2e.yml --event schedule --limit 5`): si alguna cayó, clasificarla por su log (¿`already running` en la fase `reindex`?, ¿la prueba 13?), porque es dato para el spec; ninguna noche anterior al merge cuenta para SC-007.

  Punto de partida conocido al generar estas tareas (31-10-2026, 02:20): `HEAD` y `origin/main` locales en `cd8b74f`; el PR #115 abierto, con la CI en verde al 30-10; el worktree con solo lo del spec-kit; y ninguna prueba del host lee el `CHANGELOG.md` ni el `CLAUDE.md` de la raíz del repo (un `grep` sobre `tests/` solo encuentra los que generan los scaffolds, los del esqueleto del vault y los de sus fixtures), de modo que editarlos no invalida un gate.
- [ ] T002 COMPUERTA (commit local): commitear los artefactos de spec-kit de esta rama (`specs/043-e2e-lock-race-hardening/**` y `.specify/feature.json`) con un mensaje en español, ASCII, en imperativo, sin atribución y con la identidad personal (Rodrigo Andres Hinojosa Acuña, `rodrigo.hinojosa.developer@gmail.com`, por variables de entorno `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME` y `GIT_COMMITTER_EMAIL`), por ejemplo `docs: agrega los artefactos de spec-kit de 043 (e2e de qmd contra la carrera del lock)`. Antes, auditar los bytes de `specs/043-e2e-lock-race-hardening/` (V8 de `quickstart.md`: `byte_audit_files.py` sobre los archivos nuevos, que `git diff` no ve) y comprobar con `git ls-files -s` (tras el `git add`) que los modos son 100644. Sin push.
- [ ] T003 Medir la línea base de la suite del host en una copia aislada de `origin/main` (un `git worktree add --detach` en el scratchpad, que se quita con `git worktree remove` y `git worktree prune` al terminar, para no dejar un registro huérfano):
  - con un script del scratchpad de rutas literales (el arnés rechaza los comandos compuestos) que sale con el código de bats y no con un 0 fijo (042 perdió así una corrida), correr `bats --tap tests/` en bash 5.x (el `bats` del PATH, `#!/usr/bin/env bash`, que en este Mac resuelve al bash de Homebrew) y después `PATH=/bin:$PATH bats --tap tests/` (bash 3.2.57), en forma secuencial, con la salida de error vacía;
  - antes de medir, revisar `ps` por procesos `bats` ajenos y no correr ningún otro `bats` mientras tanto (en 027 se observaron rojos de latidos al correr dos suites a la vez, que pasaron en aislamiento); un rojo se vuelve a medir en aislamiento antes de nombrarlo;
  - registrar la versión de bats, `1..N`, ok, not ok, saltadas y duración de cada corrida, y que `tests/qmd-embed-nightly.bats` (36 pruebas) y `tests/ci-workflows.bats` (14) están incluidos y en verde; la línea base de la CI de `cd8b74f` es 1868 por brazo (runs 40988591966 y 40991040419) y la de 042 en este Mac dio 55 y 56 saltadas;
  - registrar el esperado final: **línea base medida + 26** (las 26 pruebas nuevas de `contracts/host-oracle.md` §3), con una saltada más en macOS por O1 (SC-005).

  Mientras corre, se pueden escribir archivos del worktree (T006 a T013) pero no correr ningún `bats` allí.
- [ ] T004 [P] Comprobar que siguen los dos modelos de 041 para T035 a T037: `~/.cache/agentic-qmd-e2e/models-041` con 2 archivos (333.590.944 y 1.282.438.912 bytes, 1.616.029.856 en total) y el tamaño y el sha256 de la tabla de `.github/scripts/fetch-qmd-models.sh`. Si faltan, COMPUERTA: obtenerlos con `QMD_MODELS_DIR=<dir> .github/scripts/fetch-qmd-models.sh` descarga unos 1,6 GB y pide el visto bueno del operador.
- [ ] T005 [P] Comprobar, solo con lecturas y consultas por nombre, el estado de Docker para T027, T031 y T035 a T037: Docker Desktop encendido (`docker info --format` con la versión del servidor, la arquitectura, las CPU y la memoria), que las etiquetas `agent-admin:qmd-real` y `agent-admin:qmd-embed` no existen (las quitó T036 de 042 el 29-10-2026; el caché de build se conservó, así que la primera corrida reconstruye y su costo no está medido), que `alpine:3.24.1` está en caché local y el espacio libre en disco. No se toca ningún contenedor ni imagen. Registrar.

---

## Phase 2: Foundational

**Purpose**: el esqueleto del oráculo del host, que necesitan todas las historias.

**CRITICAL**: ninguna historia empieza antes de cerrar esta fase.

- [ ] T006 Crear `tests/qmd-e2e-lock.bats` sin ninguna prueba todavía (`contracts/host-oracle.md` §2), con:
  - una cabecera en el molde de `tests/qmd-embed-nightly.bats:1-26`: qué es, el contrato, por qué existe (la fase `reindex` cayó la noche del 29-10-2026, #112, y el bucle de la prueba 13, #109) y las reglas que cumple: bash 3.2 y 5.x sin `mapfile`, arreglos asociativos ni `${v,,}`; sin red ni Docker; ninguna tubería que pueda cerrarse antes (`producer | grep -q`); un negativo es `_lacks` o `run ...; [ "$status" -ne 0 ]`, nunca un `!` ni un `[[ ]]` intermedios; todo proceso de fondo se lanza con los descriptores 3 y 4 cerrados y muere en `teardown`; nada grande viaja por argv ni por el entorno;
  - `load helper`, `bats_require_minimum_version 1.5.0` y las constantes `E2E_FILE="$REPO_ROOT/tests/docker-e2e-qmd.bats"`, `HELPER_FILE="$REPO_ROOT/tests/helper-qmd-e2e.bash"` y `PRODUCT_LIB="$REPO_ROOT/scripts/lib/qmd_index.sh"`;
  - `setup` (`setup_tmp_dir` y el estado inicial del exec falso y del reloj falso) y `teardown` (mata al retenedor de O1 si existe y llama a `teardown_tmp_dir`);
  - `_has` y `_lacks` (copiados de `tests/qmd-embed-nightly.bats:65-67`);
  - `_use_helper`: ejecuta `load helper-qmd-e2e` y después redefine `_qmd_e2e_now` y `_qmd_e2e_sleep` con el reloj falso (un contador en un archivo: `now` lo imprime y `sleep N` anota N en un registro y se lo suma). **Solo lo llaman las pruebas L, X, O, D1 y D2, nunca `setup`**: así B1 a B6 caen por el contenido del e2e y no por la carga del ayudante (§6);
  - `fake_exec`: clasifica cada llamada por el texto de sus argumentos (`$*`), en este orden: con `heartbeatctl qmd-reindex` es un intento, con `vault_hash` es la comprobación del efecto y con `/proc` es la sonda del dueño. Los intentos consumen respuestas `aN.status` y `aN.out` de un directorio de plan y, cuando la cola se acaba, repiten la última; la sonda y el efecto leen una respuesta fija (`probe.*`, `effect.*`; por defecto la sonda responde `pid 99 fd 9 cmd=[sleep 30 ]`). Cada llamada anota `attempt`, `probe` o `effect` en `calls.log`, y cada intento deja además sus argumentos (`$*`, en una línea) en `attempts.args`, para que L1 compare la orden entera (I13). En el intento 501 escribe `runaway` y responde estado 0 sin `already running`, lo que corta cualquier bucle sin plazo; cada prueba L termina afirmando que no hubo `runaway`. Funciones para armar el plan: `_plan_attempt N ESTADO SALIDA`, `_plan_probe ESTADO SALIDA` y `_plan_effect ESTADO SALIDA`;
  - `_call_wait SITIO` y `_call_effect SITIO`: llaman a `qmd_e2e_reindex_wait fake_exec "$SITIO"` y a `qmd_e2e_reindex_effect fake_exec "$SITIO"` con `3>"$TMP_TEST_DIR/fd3.txt"` y la salida estándar a otro archivo (que cada prueba afirma vacío: I10), capturando el retorno con `|| rc=$?` (un retorno distinto de 0 aborta una prueba de bats). Es el mismo contexto en que los llaman los sitios, una lista `||` o la condición de un `if`, donde bash no aplica errexit dentro de la función (hallazgo U1 del análisis);
  - los extractores de cuerpo para B, en el molde de P1 y P2 (`tests/qmd-embed-nightly.bats:855-985`): el cuerpo de un `@test` por una expresión regular de su nombre, el cuerpo de una función (`^nombre\(\) \{` hasta el `^\}`), la versión sin comentarios y el recorte entre dos marcas `_embed_phase`. Los anclajes son solo ASCII.

  Verificar, en los dos bash, que el archivo carga y cuenta 0 pruebas (`bats --count tests/qmd-e2e-lock.bats` da 0 y `bats` imprime `1..0`).

**Checkpoint**: el arnés carga en bash 5.x y en 3.2 y no se ha escrito ninguna prueba; el ayudante no existe.

---

## Phase 3: User Story 1 - La fase `reindex` de `qmd real (041)` espera al lock y afirma el efecto (Priority: P1), MVP

**Goal**: el reindex manual de la fase espera, acotado a 120 s, a que otro proceso legítimo suelte el lock, reintenta solo ante `already running` y la fase afirma el efecto del reindex y no el estado de su propia corrida (FR-001 a FR-005 y FR-008 para este sitio, SC-003).

**Independent Test**: en el host y sin Docker, L1 a L10, X1 a X6, O1, O2, B1, B6, D1, D2 y la P1 enmendada en verde en los dos bash; en T036, la fase `reindex` pasa con el lock retenido 5 s y 20 s en un contenedor real y cae sin el arreglo.

- [ ] T007 [US1] ROJO: escribir L1 a L5 en `tests/qmd-e2e-lock.bats` (`contracts/host-oracle.md` §3, `contracts/reindex-wait.md` §3). Cada una arma su plan, llama con `_call_wait` y termina afirmando que no hubo `runaway`:
  - L1, lock libre: un solo intento (respuesta `0` con salida `ok`); retorno 0, `REINDEX_ATTEMPTS` 1, `REINDEX_WAITED_S` 0, ninguna espera en el registro del reloj, ninguna llamada de sonda en `calls.log` y nada por la salida estándar; además, la única línea de `attempts.args` es exactamente `sh -c` seguido de la orden de `contracts/reindex-wait.md` §2, con el tope `timeout -k 10 600` y la salida reescrita con `>` en `/tmp/qmd-reindex.out` (FR-001, FR-003, FR-005, I2, I10, I13).
  - L2, ocupado dos veces (`already running`, estado 0) y libre a la tercera: tres intentos, dos esperas de exactamente 2 s, retorno 0, `REINDEX_WAITED_S` 4 (el comienzo del tercer intento menos el del primero), `REINDEX_OUTPUT` es el del tercero, la sonda corrió una vez y fd 3 trae R-BUSY, `reindex lock busy (SITIO): the first attempt lost the lock; owners:`, seguida de las líneas de la sonda (FR-001, I1, I7).
  - L3, ocupado siempre con `QMD_E2E_REINDEX_LOCK_WAIT_S=6`: retorno 1 en el cuarto intento (instantes 0, 2, 4 y 6) y tres esperas; fd 3 trae R-EXPIRED: `reindex (SITIO): the reindex lock stayed busy for 6 s (4 attempts) and the reindex never ran`, `last output of qmd-reindex:` con la salida del último intento y `lock owners at the end of the wait:` con las líneas de la sonda; la sonda corrió dos veces, la primera contención y el vencimiento (FR-004, I6, I7).
  - L4, un reindex que falla por otra causa (estado 5, salida `boom`, sin `already running`): un intento, retorno 0, `REINDEX_STATUS` 5, `REINDEX_OUTPUT` `boom`, ninguna espera (FR-001, I1, I4).
  - L5, los estados 124, 137 y 143 en el primer intento (tres vueltas de la prueba): retorno 3, sin espera y sin reintento (FR-005, I5).
- [ ] T008 [US1] ROJO: escribir L6 a L10 en `tests/qmd-e2e-lock.bats`:
  - L6, el plazo efectivo de `_qmd_e2e_lock_wait_s` para sin definir, vacío, `abc`, `99999`, `0` y `3601` (120), `08` (8), `7` (7) y `3600` (3600); cada caso en un subshell con la variable exportada, no con una asignación prefijada (FR-005, I8).
  - L7, una sonda que falla (el exec falso responde 1 sin salida a la sonda) no cambia el retorno ni la cuenta de intentos, ni en la primera contención ni al vencer (I7).
  - L8, un exec que falla sin salida (estado 1, vacío) no se lee como ocupado: un intento, retorno 0, `REINDEX_STATUS` 1, ninguna espera (FR-001, I1).
  - L9, la salida de un intento no arrastra la del anterior: tras un intento ocupado y uno bueno, `REINDEX_OUTPUT` no contiene `already running` (I3).
  - L10, el tiempo y la espera solo pasan por las costuras: con un `date` y un `sleep` falsos al frente del `PATH` que anotan su uso, tras una espera con intentos ocupados los dos registros están vacíos; si bats llama a `date` o a `sleep` por su cuenta, los falsos anotan solo las llamadas con los argumentos del ayudante (`+%s` y un número) (I9).
- [ ] T009 [US1] ROJO: escribir X1 a X6 en `tests/qmd-e2e-lock.bats` (`contracts/host-oracle.md` §3, `data-model.md` §3), cada una con `_call_effect`. El formato de lo que el ayudante lee del contenedor es el de `data-model.md` §3 (lo fijó esta tarea y el análisis lo llevó al modelo de datos), y T017 lo implementa: una sola línea, `STATE absent` si `qmd-index.json` no existe, o `STATE present ESTADO PENDING HASH_ESTADO HASH_VAULT` con campos sin espacios y `-` para un campo ausente o nulo. El veredicto evalúa en este orden: archivo ausente, estado (`indexed` y `skipped` pasan; `error`, `partial`, `stalled` y cualquier otro fallan nombrando el valor), `pending` (debe ser 0) y hash (debe ser igual al `vault_hash` de ahora). Un fallo imprime R-EFFECT, `reindex effect (SITIO):` más la condición, por fd 3; el texto de las condiciones no es CANON salvo `qmd-index.json is absent`, y las pruebas afirman solo que el reporte nombra el dato:
  - X1, `present indexed 0 H H`: retorno 0. X2, `present skipped 0 H H`: retorno 0 (otro reindex legítimo hizo el trabajo).
  - X3, hash del estado distinto del del vault (con `indexed` y con `skipped`): retorno 1 y el reporte nombra los dos hashes.
  - X4, `error`, `partial` y `stalled`, con `pending` 0 y hashes iguales para aislar la causa: retorno 1 y el reporte nombra el estado.
  - X5, `pending` 3 y `pending` ausente (`-`): retorno 1 y el reporte menciona `pending`.
  - X6, `STATE absent`: retorno 1, el reporte dice `qmd-index.json is absent` y no trae ningún texto de `jq`.
- [ ] T010 [US3] ROJO: escribir O1 y O2 en `tests/qmd-e2e-lock.bats` (`contracts/host-oracle.md` §3, `contracts/lock-owner-dump.md` §1). La sonda se ejecuta en el host con un exec que no usa Docker (`local_exec() { "$@"; }`) y `QMD_CACHE_HOME` apuntando a un directorio del temporal:
  - O1 llama primero a `_use_helper` y después sigue solo en Linux (`[ "$(uname -s)" = "Linux" ] || skip "no /proc on $(uname -s)"`), de modo que en macOS su ROJO es la carga del ayudante, como el de L, X y D (hallazgo A3 del análisis): un proceso real con el archivo del lock abierto en el descriptor 9 (`( exec 9>"$lock"; exec sleep 60 ) 3>&- 4>&- &`, con el pid guardado y esperando hasta unos 2 s a que exista `/proc/$pid/fd/9`); la salida trae `pid $pid fd 9 cmd=[sleep 60`; el proceso muere en `teardown` (FR-009, SC-008).
  - O2, sin retenedor: en Linux dice `none found` con el archivo del lock presente y `lock file absent (RUTA)` sin él; en macOS dice `no /proc here`; en los dos casos el estado de salida es 0 (FR-009).
- [ ] T011 [US1] ROJO: escribir B1, B6, D1 y D2 en `tests/qmd-e2e-lock.bats` (`contracts/host-oracle.md` §3):
  - B1, sobre el cuerpo de `qmd real (041)` sin comentarios, recortado entre `_embed_phase reindex` y `_embed_phase semantic-search`: contiene `qmd_e2e_reindex_wait inc`, `if ! qmd_e2e_reindex_effect inc` (el efecto se evalúa en la condición de un `if`, el mismo contexto que en el oráculo: hallazgo U1 del análisis), `/.vault/wiki/concepts/gatos.md`, `qmd-reindex did not finish`, `SECONDS - t0` y `[ "$output" = "0" ]` (la afirmación de `pending` se conserva) y al menos tres líneas que son solo la palabra `false` sangrada con cuatro espacios (tras el reporte del tope, tras el retorno 1 del ayudante y tras el efecto no cumplido, cuyos reportes ya salieron); no contiene `heartbeatctl qmd-reindex` ni `grep -qE 'ok|indexed'` (FR-001, FR-002, FR-005, FR-008).
  - B6, el e2e carga el ayudante una sola vez y después de `load helper`: `grep -c -x -F -- 'load helper-qmd-e2e'` da 1 y su número de línea es mayor que el de `load helper` (FR-008).
  - D1, tras `_use_helper`, `QMD_E2E_LOCK_BUSY_MARK` es `already running` y `reindex: already running` aparece literal en `$PRODUCT_LIB` (`grep -F -q`): si alguien cambia el texto del producto, el reintento dejaría de dispararse sin aviso (I12).
  - D2, el ayudante pasa `bash -n` y ninguna de sus líneas no comentadas contiene `[[`, `mapfile`, `readarray`, `declare -A`, `local -n`, `|&`, `| grep -q`, `coproc`, `,,}` ni `^^}`, ni empieza, tras la sangría, con `!` como comando (I11).
- [ ] T012 [P] [US1] ROJO: enmendar P1 en `tests/qmd-embed-nightly.bats` (`:855-935`; `contracts/host-oracle.md` §4), solo lo que exige de la fase `reindex`: la quinta ancla (`anchors`, índice 4) pasa de `heartbeatctl qmd-reindex` a `qmd_e2e_reindex_wait`; en el `case` de `reindex)`, `grep -qE 'ok|indexed'` se reemplaza por `_has "$seg" 'qmd_e2e_reindex_effect'` y `_lacks "$seg" "grep -qE 'ok|indexed'"`, y se quita la exigencia de `timeout -k 10 600` (el tope vive ahora en la orden del ayudante, que L1 compara entera: I13; un comentario lo dice y B1 exige la rama del retorno 3); se conservan `gatos.md`, `[ "$output" = "0" ]`, `qmd-reindex did not finish`, `SECONDS - t0` y la línea `false` sangrada. La repetición con B1 es a propósito (hallazgo D1 del análisis): P1 cuida el esqueleto de las ocho fases y B1 el detalle de la fase `reindex`, así que un cambio de esa fase toca los dos oráculos. Las ocho marcas, su orden y las anclas de las otras siete fases no cambian. P2, G3 y K1 a K4 no se tocan.
- [ ] T013 [US1] Registrar el ROJO en el Registro (SC-004), en bash 5.x y en 3.2: `bats tests/qmd-e2e-lock.bats` y `bats tests/qmd-embed-nightly.bats -f 'P1'`. Esperado: de las 22 pruebas escritas hasta aquí, 20 caen porque el ayudante no existe (L1 a L10, X1 a X6, O1, O2, D1 y D2: el mensaje de `load` nombra `helper-qmd-e2e`; O1 también en macOS, porque carga el ayudante antes de su `skip`) y 2 caen por el contenido del e2e (B1 y B6), y la P1 enmendada cae porque entre las marcas `reindex` y `semantic-search` no aparece `qmd_e2e_reindex_wait`. Comprobar que cada rojo es el previsto y no un error del propio arnés (un extractor que no encuentra el cuerpo, un `fake_exec` que clasifica mal); un rojo por una razón equivocada se corrige ahora. Comprobar que P2, G1, G3 y K1 a K4 siguen en verde. El ROJO de comportamiento de O1 y de la rama de `/proc` de O2 no se puede ver en macOS: lo dan M35 y M36 en la pata Linux (T031), donde esas ramas corren por primera vez, ya con el ayudante escrito.
- [ ] T014 [US1] Crear `tests/helper-qmd-e2e.bash`, parte 1 (`contracts/reindex-wait.md` §1 y §4):
  - cabecera: qué es, quién lo carga (`tests/docker-e2e-qmd.bats` con `load helper-qmd-e2e` y `tests/qmd-e2e-lock.bats` desde `_use_helper`), los contratos, y las reglas del archivo: bash 3.2 y 5.x; **sin efectos al cargarse** (solo define funciones y constantes, porque K1 a K4 cargan el e2e entero bajo `env -i`); solo escribe por fd 3 (salvo `qmd_e2e_lock_owners`, que imprime sus líneas por la salida estándar porque su llamador las captura: hallazgo H7); **no depende de `set -e`** (bash no lo aplica dentro de una función llamada en una lista `||` o en un `if`, que es como la llaman los sitios y las pruebas: cada comando que pueda fallar se maneja con un `if` o un `|| true` explícitos y los retornos son explícitos); sin `[[ ]]`, `mapfile`, arreglos asociativos, `local -n`, `|&`, `coproc` ni `${v,,}`; y la medición de busybox 1.37 que justifica el tope (`timeout` a secas envía solo TERM y un hijo que lo ignora bloquea al `timeout` mientras viva; `-k 10` agrega el KILL; el estado es 143 tras TERM y 137 tras KILL, nunca 124), que hoy es un comentario de la fase `reindex` (`tests/docker-e2e-qmd.bats:868-873`);
  - las constantes `QMD_E2E_LOCK_BUSY_MARK='already running'`, la cadencia de 2 s y la orden del intento, idéntica a la de la fase 041 (`timeout -k 10 600 /usr/local/bin/heartbeatctl qmd-reindex > /tmp/qmd-reindex.out 2>&1; rc=$?; cat /tmp/qmd-reindex.out; exit $rc`);
  - `_qmd_e2e_now` (`date +%s`) y `_qmd_e2e_sleep` (`sleep "$1"`), las dos costuras de prueba;
  - `_qmd_e2e_note`: cada argumento, que puede traer varias líneas, sale por fd 3 con una almohadilla y tres espacios delante de cada línea, como `_embed_note` (`tests/docker-e2e-qmd.bats:742`);
  - `_qmd_e2e_lock_wait_s`: normaliza `QMD_E2E_REINDEX_LOCK_WAIT_S` como `QMD_E2E_SETUP_DEADLINE_S` (`tests/docker-e2e-qmd.bats:825-829`): vacío, no numérico o de más de cuatro dígitos dan 120, el valor pasa por `10#` y fuera de 1 a 3600 da 120.

  L6 en verde.
- [ ] T015 [US3] En `tests/helper-qmd-e2e.bash`, parte 2: la sonda del dueño (`contracts/lock-owner-dump.md` §1):
  - `QMD_E2E_LOCK_OWNERS_SH`, una variable con un script de POSIX sh (corre en busybox ash; entre comillas simples, de modo que el script no puede contener comillas simples): el archivo del lock es `${QMD_CACHE_HOME:-$HOME/.cache/qmd}/.reindex.lock`; si `/proc` no es un directorio imprime `no /proc here`; si el archivo no existe imprime `lock file absent (RUTA)`; recorre `/proc/<pid>/fd/*` y, por cada descriptor cuyo `readlink` es la ruta del lock, imprime `pid N fd K cmd=[CMDLINE]` con el `cmdline` (NUL cambiados por espacios) acortado a 120 caracteres; salta en silencio los procesos que no puede leer (los de root dan `Permission denied` como `agent`); si no encontró ninguno imprime `none found`; como mucho 10 líneas, con un contador dentro del bucle y no con `| head` (cerrar el pipe antes es una carrera bajo `pipefail`); estado de salida 0 siempre. No toma el lock, no prueba con `flock -n` (tomarlo un instante puede hacer perder la carrera a otro proceso, incluido el reindex del vigilante), no escribe archivos y no usa `lsof` ni `fuser`;
  - `qmd_e2e_lock_owners EXEC_FN`: ejecuta `"$EXEC_FN" sh -c "$QMD_E2E_LOCK_OWNERS_SH"` con los dos flujos juntos, imprime las líneas por la salida estándar y devuelve siempre 0, aunque el exec falle.

  O1 y O2 en verde (O1 en la pata Linux, T031).
- [ ] T016 [US1] En `tests/helper-qmd-e2e.bash`, parte 3: `qmd_e2e_reindex_wait EXEC_FN SITIO` (`contracts/reindex-wait.md` §1 a §3; `data-model.md` §1.3 y §2):
  - al entrar inicializa `REINDEX_STATUS`, `REINDEX_OUTPUT`, `REINDEX_ATTEMPTS` y `REINDEX_WAITED_S` (globales, sin `local`, para que no queden restos de una espera anterior) y lee `_qmd_e2e_now` como instante del primer intento;
  - cada intento es `run "$EXEC_FN" sh -c "<la orden del intento>"` y deja `status` y `output` en `REINDEX_STATUS` y `REINDEX_OUTPUT` (los sitios usan esas variables y no `$status` ni `$output`, que el siguiente `run` pisa);
  - decisión tras cada intento: estado 124, 137 o 143 retorna 3, sin dormir ni reintentar; la salida contiene `already running` es «ocupado»; cualquier otro resultado (estado 0 con o sin estado malo, estado distinto de 0, un `docker compose exec` que falla sin salida) retorna 0 y el sitio juzga;
  - antes de cada intento lee `_qmd_e2e_now` y deja en `REINDEX_WAITED_S` ese instante menos el del primero (0 con el lock libre, 4 en L2; hallazgo U2 del análisis);
  - ocupado: la primera vez en esta espera captura la sonda con `qmd_e2e_lock_owners` y escribe R-BUSY con `_qmd_e2e_note`; si `_qmd_e2e_now` menos el comienzo del primer intento es mayor o igual al plazo de `_qmd_e2e_lock_wait_s`, escribe R-EXPIRED (con esa cifra, la salida del último intento y una segunda sonda) y retorna 1; si no, `_qmd_e2e_sleep 2` y otro intento;
  - con el lock libre, el primer intento retorna 0 sin dormir ni correr la sonda; la sonda nunca cambia el retorno; el tiempo se lee solo por `_qmd_e2e_now` y se duerme solo por `_qmd_e2e_sleep`; no escribe nada por la salida estándar.

  L1 a L5 y L7 a L10 en verde.
- [ ] T017 [US1] En `tests/helper-qmd-e2e.bash`, parte 4: `qmd_e2e_reindex_effect EXEC_FN SITIO` (`contracts/reindex-wait.md` §1; `data-model.md` §3):
  - pide al contenedor, con `"$EXEC_FN" bash -lc '...'` (`vault_hash` usa constructos de bash), la línea de T009: si `/workspace/scripts/heartbeat/qmd-index.json` no existe imprime `STATE absent`; si existe, carga `/opt/agent-admin/scripts/lib/qmd_index.sh` (como `tests/docker-e2e-qmd.bats:896`) e imprime `STATE present` con `last_status`, `pending` y `hash` leídos con `jq -r` (con `// "-"`) y el `vault_hash` del vault que resuelve el producto, `vault_hash "$(qmd_vault_dir /workspace/agent.yml)"`, el mismo directorio que hashea `_qmd_reindex_locked` (`scripts/lib/qmd_index.sh:684`; hallazgo U5 del análisis); un shell de login puede anteponer ruido, así que el host toma la última línea que empieza con `STATE` seguido de un espacio;
  - decide en el host con la tabla de T009 y escribe R-EFFECT por fd 3 con la condición que falló; retorna 0 o 1; no consulta a qmd.

  X1 a X6, D1 y D2 en verde.
- [ ] T018 [US1] Migrar la fase `reindex` de `qmd real (041)` en `tests/docker-e2e-qmd.bats` (`:861-887` de `cd8b74f`; `contracts/reindex-wait.md` §5):
  - agregar `load helper-qmd-e2e` justo después de `load helper` (`:48`) y actualizar el comentario de cabecera del archivo con una línea sobre el ayudante;
  - reescribir el comentario de la fase (`:862-866`), que dice que el lock está libre al terminar el setup: puede tenerlo el vigilante o un descendiente del setup, y el ayudante espera;
  - conservar la escritura de `gatos.md` (`:867`) y reemplazar `:868-882` (el `run inc sh -c 'timeout ...'`, las comprobaciones de estado y el `jq` con `grep -qE`) por: `local t0=$SECONDS rc=0`, `qmd_e2e_reindex_wait inc "reindex phase" || rc=$?`, una rama `[ "$rc" -eq 3 ]` que imprime el reporte de plazo vencido de 041 (`reindex: qmd-reindex did not finish in 600s (rc $REINDEX_STATUS after $((SECONDS - t0))s, ${REINDEX_WAITED_S}s of them waiting for the lock; ...`, con `_embed_tail "$REINDEX_OUTPUT" 12`; `t0` se toma antes de la espera, así que el mensaje separa la espera del intento: hallazgo U3 del análisis) y termina en `false`, una rama `[ "$rc" -ne 0 ]` que termina en `false` (el reporte R-EXPIRED ya salió), `[ "$REINDEX_STATUS" -eq 0 ]` y `if ! qmd_e2e_reindex_effect inc "reindex phase"; then` con su `false` (el reporte R-EFFECT ya salió; el efecto se evalúa en la condición de un `if`, como en el oráculo: hallazgo U1); cada `false` en una línea propia con cuatro espacios;
  - conservar la afirmación de `pending` en 0 (`:883-887`);
  - no dejar ninguna llamada a `heartbeatctl qmd-reindex` en la fase.

  B1, B6 y la P1 enmendada en verde.
- [ ] T019 [US1] Punto de control en bash 5.x y en 3.2: `bats tests/qmd-e2e-lock.bats` (las 22 pruebas escritas hasta aquí en verde, con O1 saltada en macOS por su motivo), `bats tests/qmd-embed-nightly.bats` (36 de 36, con P1 enmendada, P2, G1, G3 y K1 a K4 en verde: el `load helper-qmd-e2e` se resuelve desde `tests/` y el ayudante no tiene efectos al cargarse), `bash -n tests/helper-qmd-e2e.bash` en los dos bash y `shellcheck` sobre el ayudante como cortesía (la CI excluye `tests/`; registrar los avisos y justificar los que se dejen). Registrar en el Registro.

**Checkpoint**: la fase `reindex` espera y afirma el efecto, el ayudante está probado sin Docker y la P1 enmendada pasa. Los otros tres sitios siguen con la llamada pelada (US2).

---

## Phase 4: User Story 2 - Las pruebas 13 y 12 reintentan de verdad y ningún tick pasa en vacío (Priority: P1)

**Goal**: el bucle de la prueba 13 no aborta con `engine-calls.log` ausente, su segundo tick no puede pasar por haber perdido el lock y la fase 3 de la prueba 12 espera al lock como la fase `reindex`; ante cualquier falla de la prueba 13 se vuelcan los logs del contenedor (FR-006, FR-007 y FR-008).

**Independent Test**: en el host, B2, B3 y B5 en verde y `grep -n 'heartbeatctl qmd-reindex' tests/docker-e2e-qmd.bats` solo en comentarios; en T035, las pruebas 13 y 12 pasan con el lock retenido 5 s y 20 s y caen sin el arreglo.

- [ ] T020 [US2] ROJO: escribir B2, B3 y B5 en `tests/qmd-e2e-lock.bats` (`contracts/host-oracle.md` §3):
  - B2, sobre el cuerpo de la prueba `qmd e2e (037): a legacy vault-root collection migrates...` sin comentarios: dos llamadas a `qmd_e2e_reindex_wait in_container` (`grep -c` da 2); la del bucle captura el retorno en `rc1` (`|| rc1=$?`) y el bucle termina en `false` con 1 o 3; la del segundo tick lo captura en `rc2` (`|| rc2=$?`) y el cuerpo exige `[ "$rc2" -eq 0 ]` y `[ "$REINDEX_STATUS" -eq 0 ]` antes de comparar conteos (un intento que perdió el lock también sale con estado 0, porque el producto devuelve 0: solo el retorno prueba que el tick corrió, hallazgo C2 del análisis); la línea que lee `engine-calls.log` dentro del bucle contiene `|| true`; el bucle conserva su plazo de 45 s; ninguna línea contiene `heartbeatctl qmd-reindex`; y, sobre `teardown()` (decisión H2 de las Notes), un volcado de `docker compose logs` del workspace `agent-qmd-migrate-e2e` condicionado a `BATS_TEST_COMPLETED` vacío y antes de la línea `docker compose down` (FR-006, FR-007, FR-008).
  - B3, sobre la fase 3 de la prueba `qmd e2e: first-boot setup, ...`, recortada con sus propios comentarios de cabecera como límites (`Phase 3: cron-path reindex` y `Phase 4: inotify-under-bind-mount`, antes de quitar los comentarios): contiene `local rc3=0`, `qmd_e2e_reindex_wait in_container`, `|| rc3=$?`, `[ "$rc3" -eq 0 ]`, `[ "$REINDEX_STATUS" -eq 0 ]`, `last_status` y `runs`, y no contiene `heartbeatctl qmd-reindex` (FR-008).
  - B5, ninguna línea de `tests/docker-e2e-qmd.bats` que no sea comentario contiene `heartbeatctl qmd-reindex`, y el ayudante la tiene en una sola línea no comentada: la única llamada vive en el ayudante (FR-008).

  Correr en los dos bash y registrar que las tres caen por el contenido del e2e (B5 con las tres llamadas que quedan fuera de la fase `reindex`).
- [ ] T021 [US2] Migrar la prueba 13 en `tests/docker-e2e-qmd.bats` (`:400-528` de `cd8b74f`), con el menor diff posible (research D11):
  - el bucle de 45 s (`:493-499`) se conserva y cada vuelta llama `qmd_e2e_reindex_wait in_container "test 13 tick 1" || rc1=$?` (con `rc1=0` al empezar la vuelta); con retorno 1 o 3 la prueba termina en `false` (el ayudante ya reportó); luego lee el log con `calls=$(in_container sh -c 'cat "$HOME/.cache/qmd/engine-calls.log" 2>/dev/null' || true)`, que ya no aborta con el archivo ausente (#109), y rompe cuando aparece `collection remove`; `sleep 2`;
  - reescribir el comentario previo (`:486-492`): el ayudante absorbe la pérdida del lock y el bucle externo queda solo para que el log y la llamada de migración aparezcan;
  - retirar el volcado propio del bucle (`:500-503`): lo reemplaza el de `teardown`;
  - el segundo tick (`:522-527`) declara `local rc2=0`, llama `qmd_e2e_reindex_wait in_container "test 13 tick 2" || rc2=$?` y exige `[ "$rc2" -eq 0 ]` y `[ "$REINDEX_STATUS" -eq 0 ]` antes de comparar el conteo de `collection`, de modo que no pueda pasar por haber perdido el lock (FR-007): un intento que perdió el lock también sale con estado 0, así que solo el retorno del ayudante prueba que el tick corrió;
  - en `teardown()` (`:75-97`), junto al bloque del test 041, un bloque equivalente para `$TMP_TEST_DIR/agent-qmd-migrate-e2e/docker-compose.yml` (comprobar que ese es el nombre del archivo que el scaffold deja en el workspace de la prueba): con `BATS_TEST_COMPLETED` vacío vuelca `docker compose logs --tail=100 --no-color` por fd 3 con una almohadilla y un espacio como prefijo, tolerando su falla con `|| true`, y antes de `docker compose down`; P2 sigue exigiendo una sola línea que sea solo `_embed_failure_state` sangrada con cuatro espacios y que su llamada preceda al `down`;
  - actualizar el comentario de `:398-399` (`heartbeatctl qmd-reindex is invoked directly`) para decir que se invoca por `qmd_e2e_reindex_wait`;
  - no tocar nada más de la prueba: tampoco la aserción de `:483-484` ni el comentario de `:394-396`, que la segunda carrera de arranque de esta prueba deja en duda y que quedan fuera de alcance (hallazgo I1 del análisis, decisión del operador del 31-10-2026; issue aparte en T042).
- [ ] T022 [US2] Migrar la fase 3 de la prueba 12 en `tests/docker-e2e-qmd.bats` (`:264-276`): conservar la escritura de `cron-note.md`, reemplazar `run in_container /usr/local/bin/heartbeatctl qmd-reindex` y `[ "$status" -eq 0 ]` por `local rc3=0`, `qmd_e2e_reindex_wait in_container "test 12 phase 3" || rc3=$?`, `[ "$rc3" -eq 0 ]` y `[ "$REINDEX_STATUS" -eq 0 ]` (sin el `local rc3=0`, un retorno 0 deja `rc3` sin asignar y `[ "$rc3" -eq 0 ]` sale con 2, medido en los dos bash: hallazgo I2 del análisis), y conservar las afirmaciones de `last_status` (`indexed` o `skipped`) y de `runs` (>= 1). Registrar la clasificación de FR-008: las cuatro llamadas manuales (`research.md` M6) son las únicas de los e2e, el cron y el vigilante no son llamadas de las pruebas y ninguna ya toleraba el salto.
- [ ] T023 [US2] Punto de control en bash 5.x y en 3.2: B2, B3 y B5 en verde, las 25 pruebas escritas hasta aquí en verde (O1 saltada en macOS), `bats tests/qmd-embed-nightly.bats` en 36 de 36 (P2 incluida, por el bloque nuevo de `teardown`), y `grep -n 'heartbeatctl qmd-reindex' tests/docker-e2e-qmd.bats` solo en comentarios. Registrar en el Registro.

**Checkpoint**: los cuatro sitios usan el ayudante y ninguno hace la llamada pelada. Falta el dueño del lock en el estado al fallar (US3).

---

## Phase 5: User Story 3 - Si igual falla por el lock, el reporte dice quién lo tenía (Priority: P2)

**Goal**: el estado que `qmd real (041)` vuelca al fallar nombra los procesos y descriptores que tienen abierto `.reindex.lock` y las tres primeras líneas de `qmd-setup.err`, y cada sonda tolera su propia falla (FR-009, SC-008).

**Independent Test**: en el host, B4 en verde; en T027, la sonda real, en un contenedor Alpine desechable como usuario 1000, nombra a un retenedor con su pid y su comando; en T035 y T036, R-BUSY lo nombra en el TAP de una corrida con el lock retenido.

- [ ] T024 [US3] ROJO: escribir B4 en `tests/qmd-e2e-lock.bats` (`contracts/host-oracle.md` §3), sobre el cuerpo de `_embed_failure_state` sin comentarios: contiene el encabezado `# --- reindex lock owners (who has .reindex.lock open: pid, fd and command) ---`, `QMD_E2E_LOCK_OWNERS_SH` y `head -n 3` sobre `qmd-setup.err`; la línea que ejecuta la sonda contiene `|| true`; y el encabezado que cita la checklist (`# --- state at the failure: disk, container verdict, vector extension ---`) sigue siendo el primero, antes del del dueño (FR-009). Correr en los dos bash y registrar que cae por el contenido del e2e.
- [ ] T025 [US3] Editar `_embed_failure_state` en `tests/docker-e2e-qmd.bats` (`:57-73`; la función es `:64-73`), sin cambiar el texto ni el lugar del primer encabezado (la checklist de upgrade lo cita y G3 de `tests/qmd-embed-nightly.bats` lo guarda):
  - después de la sonda de contenedor que ya existe, una línea `echo "# --- reindex lock owners (who has .reindex.lock open: pid, fd and command) ---" >&3` y la sonda del dueño: `(cd "$d" && docker compose exec -T -u agent qmd-embed sh -c "$QMD_E2E_LOCK_OWNERS_SH" 2>&1) | sed 's/^/# /' >&3 || true`;
  - dentro de la orden en contenedor que ya existe, una sección `echo "--- qmd-setup.err (first 3 lines)"; head -n 3 "$HOME/.cache/qmd/tmp/qmd-setup.err" 2>&1`, al final, después de `vsearch.out`, para no mover lo que ya se imprime (la ruta sale de `scratch_dir`, `scripts/lib/rag_obs.sh:30-38`; la primera línea del reemplazo de sqlite-vec queda al comienzo de ese archivo y la cola de 500 bytes que llega al log la empuja fuera);
  - actualizar el comentario de cabecera de la función (`:57-63`) con las dos sondas nuevas;
  - cada sonda nueva termina en `|| true` y `teardown` sigue llamando a la función una sola vez y antes de `docker compose down`.
- [ ] T026 [US3] Punto de control en bash 5.x y en 3.2: B4 en verde, las 26 pruebas de `tests/qmd-e2e-lock.bats` en verde (O1 saltada en macOS), y `bats tests/qmd-embed-nightly.bats` en 36 de 36 con P2 (cada sonda tolera su falla), G3 (el encabezado citado por la checklist se conserva) y K1 a K4. Registrar en el Registro.
- [ ] T027 [P] [US3] Humo de la sonda real en busybox (sin COMPUERTA: contenedor desechable de unos minutos que solo usa `alpine:3.24.1`; se avisa antes de empezar): con un contenedor de nombre propio (`docker run -d --name qmd043-probe alpine:3.24.1 sleep 600`, que se quita al final con `docker rm -f`), instalar `flock` como root (`docker exec qmd043-probe apk add --no-cache flock`, el paquete que instala `docker/Dockerfile:45`) y, como usuario 1000 (`docker exec -u 1000:1000`), lanzar un retenedor real, con `QMD_CACHE_HOME=/tmp/qmd` ya creado (`exec 9>/tmp/qmd/.reindex.lock; flock 9; sleep 60`), y correr `sh -c "$QMD_E2E_LOCK_OWNERS_SH"` con la misma `QMD_CACHE_HOME` y el script que sale del ayudante. Esperado: una línea `pid N fd 9 cmd=[sleep 60 ]` con el pid del retenedor; con el retenedor muerto, `none found`; con el archivo borrado, `lock file absent (RUTA)`; estado de salida 0 en los tres casos y ningún texto de `Permission denied`. Es la primera ejecución de la sonda bajo busybox ash y como `agent`. Registrar en el Registro.

**Checkpoint**: el estado al fallar y R-BUSY nombran al dueño del lock; las 26 pruebas del oráculo están en verde en el host.

---

## Phase 6: Polish (local; sin compuertas)

**Purpose**: documentación, pata Linux del oráculo, mutaciones y revisión independiente antes de salir del host.

- [ ] T028 [P] En `docs/qmd-upgrade-checklist.md` (FR-012), en el ítem que cita `# --- state at the failure` (`:122-140` en `cd8b74f`): una frase que diga que el bloque de una corrida roja incluye ahora quién tiene `.reindex.lock` abierto (pid, descriptor y comando) y las tres primeras líneas de `qmd-setup.err`, y que la fase `reindex` espera hasta `QMD_E2E_REINDEX_LOCK_WAIT_S` segundos (120 por defecto) a que el lock se suelte y lo cuenta en el TAP; la cita del encabezado no cambia (G3 la guarda). Correr `tests/qmd-embed-nightly.bats` (G3) en los dos bash.
- [ ] T029 [P] Entrada de `CHANGELOG.md` (FR-012), en inglés como las demás, bajo `## [Unreleased]` / `### Changed`, sin bump de `VERSION` (CI y pruebas solamente, el precedente de 019, 025, 039, 041 y de la entrada del tope de 45 minutos): el defecto (la fase `reindex` de `qmd real (041)` perdió el lock en la nocturna del 29-10-2026, run 40865079036, #112; el bucle de la prueba 13 aborta con `engine-calls.log` ausente, #109), el arreglo (el ayudante `tests/helper-qmd-e2e.bash`, que espera hasta 120 s y reintenta solo `already running`, afirma el efecto sobre el estado del índice y acepta `skipped`, y nombra al dueño del lock en el TAP; la variable `QMD_E2E_REINDEX_LOCK_WAIT_S`), lo que no cambia (el `flock -n` del producto, `docker/`, `scripts/`, `VERSION` 0.29.0, `total=49` del resumen del nightly, el camino sin contención), la verificación (las 26 pruebas nuevas y las 39 mutaciones, y la inyección con el lock retenido, cuyas cifras entran en T043) y el peor caso (120 s de espera más un reindex acotado a 600 s caben en el tope de 45 minutos). Sin marcas de borrador: lo pendiente se redacta como estado y se completa en T043.
- [ ] T030 [P] En `CLAUDE.md`, a mano (FR-012): una entrada de 043 en el bloque de características, arriba de la de 042 y en su estilo, con el origen (#112 y #109), el diseño (ayudante compartido, plazo de 120 s, solo `already running` se reintenta, la afirmación sobre el efecto, el dueño del lock por `/proc/*/fd`), las decisiones del operador (31-10-2026), los conteos (26 pruebas, 39 mutaciones en los dos bash más M35 y M36, host = línea base medida + 26) y el estado; y una viñeta nueva en «Common gotchas»: un `heartbeatctl qmd-reindex` manual en un e2e puede perder `.reindex.lock` y salir con 0 (`already running` por diseño del producto), así que se lanza siempre por `qmd_e2e_reindex_wait` y B5 impide una llamada pelada. No reescribir el texto histórico de 042 (su «Pendiente» queda superado por esta entrada). `CLAUDE.md` está rastreado aunque `.gitignore` lo cubra: `git add CLAUDE.md` funciona, y si `git status` no lo muestra, `git add -f`. Las cifras de la evidencia se agregan en T043.
- [ ] T031 Pata Linux del oráculo (sin COMPUERTA: contenedor desechable `--rm` de unos minutos que baja `ubuntu:24.04` si no está; se avisa antes de empezar): O1 solo corre en Linux y la rama de `/proc` de la sonda no se ejercita en macOS, así que la CI de Linux las vería por primera vez en el PR (la lección de 025 y 039: un contenedor es un oráculo de Linux útil si se parece al runner). Con un script del scratchpad (`scratchpad/043/linux_leg.sh`): `ubuntu:24.04` (bash 5.2.21, el de la CI), como usuario no root (`--user 1000:1000`, `HOME` en un directorio escribible), con una copia del repo que el contenedor no puede escribir, bats 1.11.0 (la versión de la CI en Linux: clonar el tag en el scratchpad y revisarlo antes de ejecutarlo) y con SIGPIPE ignorada, como la entrega el runner (`perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats ...`). Esperado: `tests/qmd-e2e-lock.bats` 26 de 26 con O1 ejecutada de verdad (no saltada) y O2 en su rama de Linux. Correr ahí las dos mutaciones de `contracts/host-oracle.md` §5 que solo pueden caer en Linux: **M35**, la sonda compara el `readlink` contra otra ruta (O1 cae); **M36**, la sonda no distingue el archivo ausente e imprime `none found` (O2 cae). Registrar.
- [ ] T032 Ejecutar el catálogo de mutaciones de `contracts/host-oracle.md` §5 (M1 a M34 y M37 a M41) contra la implementación real (SC-004), en bash 5.x y en 3.2, **sobre copias aisladas** de los archivos que lee el oráculo (`tests/helper.bash`, `tests/helper-qmd-e2e.bash`, `tests/docker-e2e-qmd.bats`, `tests/qmd-e2e-lock.bats` y `scripts/lib/qmd_index.sh`, para M31; nunca sobre el árbol de trabajo; `REPO_ROOT` sale de la ubicación de `tests/helper.bash`), **como usuario no root**, con un corredor del scratchpad (`scratchpad/043/mutate_043.py`) que aplica cada una, corre solo `tests/qmd-e2e-lock.bats` y restaura, y que exige que el texto a mutar aparezca exactamente una vez (si no, la mutación se declara rota y no corre):
  - control sin mutar: 26 de 26 en verde en los dos bash (O1 saltada en macOS);
  - las 39 deben caer en bash 5.x y en 3.2 por las pruebas previstas (la columna «La cazan» de §5) y por su aserción, no por un error del arnés; registrar en el Registro la prueba que cae con cada mutación y, a la inversa, la mutación que hace caer a cada una de las 26 pruebas (cada una necesita al menos una; O1 y O2 las cubren M35 y M36 de T031);
  - toda aserción nueva de B1 a B6 que no tenga mutación (por ejemplo, que la fase 041 ignore el retorno 1 del ayudante y siga sin `false`) se cubre con una mutación nueva desde **M42** (M37 a M41 ya las agregó el análisis);
  - si alguna sobrevive, endurecer el oráculo y repetir antes de seguir.
- [ ] T033 Revisión independiente de solo lectura, en las pasadas que hagan falta (agente `code-reviewer`; si el operador lo pide, un workflow de lentes con escépticos), antes de las corridas de Docker y del gate, sobre `tests/helper-qmd-e2e.bash`, `tests/qmd-e2e-lock.bats`, las ediciones de `tests/docker-e2e-qmd.bats`, la enmienda de P1 y los documentos editados. No se corren `bats` ni `docker` dentro de los agentes mientras se mide algo. Clasificar cada hallazgo y corregir los que correspondan, con su ROJO y su VERDE; las mutaciones nuevas se suman al catálogo desde M42. Buscar a propósito: pruebas que pasan en vacío (una aserción de B que busca un texto presente en otra fase o sitio y no en el recorte), un negativo que no puede fallar, un `$status` o un `$output` que un `run` interno del ayudante pisa antes de que el sitio lo lea, el estado de salida y `set -e` dentro de una función llamada en una lista `||`, `local x=$(cmd)` que enmascara el estado, números con cero a la izquierda en `$(( ))`, `REINDEX_*` sin inicializar en un retorno temprano, un `>&3` fuera de una prueba, una sonda que cambia el rojo que reporta, guardias redundantes que vacían una prueba y toda suposición sobre lo que hay dentro de la imagen.

**Checkpoint**: el oráculo y el ayudante están endurecidos y revisados; la evidencia de Docker corre sobre el árbol final.

---

## Phase 7: User Story 4 - La corrección se demuestra con una falla inyectada y se vigila en las noches siguientes (Priority: P2)

**Goal**: la corrección queda demostrada con el lock retenido a propósito (ROJO sin el arreglo y VERDE con él, con 5 s y 20 s en cada sitio), medida sin contención (SC-003), validada en el runner real con una corrida manual y protegida por el oráculo (FR-010 y FR-011, SC-001 a SC-006 y SC-008).

**Independent Test**: el oráculo del host cae contra los cuerpos actuales y pasa tras la corrección (T013 a T026) y las 39 mutaciones caen (T032); la inyección da ROJO y VERDE en un contenedor local (T035 y T036); la corrida manual del workflow termina en verde con `ok 16 qmd real (041)` ejecutado y no saltado (T041).

- [ ] T034 [P] [US4] Escribir la herramienta de inyección en el scratchpad (`scratchpad/043/`, no versionada; `contracts/evidence-protocol.md` §3 y `research.md` D8):
  - `holder.sh` (POSIX sh, corre dentro del contenedor como `agent`; lo lanza el corredor con `docker exec -d -u agent`): recibe H segundos y, opcionalmente, un archivo marcador que espera con un sondeo de 50 ms (`sleep 0.05`); abre `exec 9>"${QMD_CACHE_HOME:-$HOME/.cache/qmd}/.reindex.lock"`, toma el lock con `flock 9` bloqueante, anota el instante en `/tmp/holder.took`, duerme H y sale; no usa root;
  - `inject.sh SITIO H CUERPO [ESPERA_S]`: arma el árbol (`old`: un `git worktree add --detach` de `origin/main` en el scratchpad, con su `tests/helper.bash`; `new`: este worktree), exporta `DOCKER_E2E=1` (y `QMD_EMBED_E2E=1` con `QMD_E2E_MODELS_DIR` para 041), lanza bats con `-f` en segundo plano y la salida TAP a un archivo (el filtro de bats es una expresión regular: los paréntesis se escapan, p. ej. `-f 'qmd real \(041\)'`, `-f 'qmd e2e \(037\): a legacy'` y `-f 'qmd e2e: first-boot'`), sondea cada 100 ms o menos el contenedor del servicio (por la etiqueta `com.docker.compose.service` del servicio `qmd-embed`, `qmd-migrate-e2e` o `qmd-e2e` y comprobando que `com.docker.compose.project.working_dir` termina en `agent-qmd-embed`, `agent-qmd-migrate-e2e` o `agent-qmd-e2e`, para no confundirse con ningún otro contenedor), lanza el retenedor con el marcador del sitio (`gatos.md` para 041, `cron-note.md` para la prueba 12 y ninguno para la 13, donde el retenedor parte apenas existe el contenedor) y, al terminar bats, imprime el código de bats, el instante en que el retenedor tomó el lock, las líneas R-BUSY o R-EXPIRED del TAP y la línea que falló;
  - una corrida es **conclusiva** solo si el retenedor tenía el lock antes del primer intento del sitio: con el cuerpo nuevo se ve porque el TAP trae R-BUSY con el retenedor nombrado; con el actual, porque la falla trae `already running` o el archivo ausente. Si no, se repite. En la prueba 13, además, el setup de arranque compite con el retenedor por el lock (hallazgo I1 del análisis): si lo toma primero, refresca el índice y escribe `.qmd-setup-ok`, y la prueba puede caer en `:484` antes del primer tick; esa corrida tampoco es concluyente, se repite y se anota el motivo;
  - al terminar, la herramienta comprueba que no quedaron contenedores ni redes de las pruebas (nombres `agent-qmd-*`) y no toca ningún otro.
- [ ] T035 [US4] COMPUERTA (Docker, unos 20 a 30 minutos, con el motor falso): la inyección sobre las pruebas 13 y 12 con la herramienta de T034, una a la vez, nunca en paralelo (cada una usa Docker Desktop entero). La primera corrida reconstruye las imágenes de prueba: registrar cuánto costó. La matriz es la de `contracts/evidence-protocol.md` §3, alineada con SC-001 en el análisis del 31-10-2026 (hallazgos H3 e I3):

  | Sitio | Cuerpo | Retención | Esperado |
  | --- | --- | --- | --- |
  | Prueba 13 | actual | 20 s | ROJO: cae por `engine-calls.log` ausente (#109; confirma o refuta el mecanismo inferido del `cat` que sale con 1) |
  | Prueba 13 | nuevo | 5 s | VERDE, con R-BUSY nombrando al retenedor |
  | Prueba 13 | nuevo | 20 s | VERDE |
  | Prueba 13 | nuevo, con `QMD_E2E_REINDEX_LOCK_WAIT_S=6` | 60 s | ROJO por diseño: falla a los 6 s de espera con R-EXPIRED (lock, 6 s, intentos, última salida y dueño), sin error de `jq` ni de `grep` (SC-002) |
  | Fase 3 de la prueba 12 | actual | 20 s | ROJO: cae porque `qmd-index.json` no existe |
  | Fase 3 de la prueba 12 | nuevo | 5 s | VERDE |
  | Fase 3 de la prueba 12 | nuevo | 20 s | VERDE |

  Registrar por corrida: identificador, instante en que el retenedor tomó el lock, resultado, duración y las líneas de R-BUSY o R-EXPIRED. Si el cableado real del ayudante falla aquí (las comillas del `sh -c` a través de `docker compose exec`, `/tmp/qmd-reindex.out`), corregirlo con su ROJO y su VERDE en el host y repetir T019, T023 y T026 antes de seguir. Un rojo de producto detiene la secuencia (FR-013, T042).
- [ ] T036 [US4] COMPUERTA (Docker, unos 35 a 50 minutos, con qmd real y los modelos de T004): la inyección sobre la fase `reindex` de `qmd real (041)`, con `DOCKER_E2E=1 QMD_EMBED_E2E=1 QMD_E2E_MODELS_DIR=$HOME/.cache/agentic-qmd-e2e/models-041`, una corrida completa de la prueba (de 8 a 10 minutos cada una) a la vez:

  | Cuerpo | Retención | Esperado |
  | --- | --- | --- |
  | actual | 20 s | ROJO en la fase `reindex`, con `already running` en `qmd-reindex.out` y sin `qmd-index.json`, como la nocturna 40865079036 |
  | nuevo | 5 s | VERDE |
  | nuevo | 20 s | VERDE, la retención más larga que el debounce del vigilante (su reindex también encuentra el lock tomado) |
  | nuevo, con `QMD_E2E_REINDEX_LOCK_WAIT_S=6` | 600 s | ROJO por diseño: la fase `reindex` falla a los 6 s de espera con R-EXPIRED, sin error de `jq` ni de `grep`, y el estado al fallar trae el bloque `# --- reindex lock owners (who has .reindex.lock open: pid, fd and command) ---` con el retenedor (pid, descriptor 9 y comando) y la sección `--- qmd-setup.err (first 3 lines)` (SC-002 en la 041 y SC-008; decisión del operador del 31-10-2026) |
  | nuevo (opcional) | 15 s | VERDE; el borde del debounce: si el reindex del vigilante se adelantó y dejó `skipped` (que la afirmación de efecto acepta), se registra; como el vigilante dispara una sola vez y no reintenta, el resultado se decide por milisegundos y no prueba nada si no aparece (hallazgo A1 del análisis) |

  Registrar lo mismo que en T035 y, además, el dueño que nombra R-BUSY (el `sleep` del retenedor con el descriptor 9) y el `qmd-index.json` final. Es la primera vez que `qmd_e2e_reindex_effect` corre en un contenedor real (`vault_hash` por `bash -lc`): un defecto de cableado se corrige como en T035. Con esto quedan cubiertos SC-001, SC-002 (también en la fase 041, con la fila del vencimiento) y SC-008: esa fila es la única corrida que ejecuta de verdad el bloque nuevo de `_embed_failure_state` antes del merge (hallazgo C3 del análisis).
- [ ] T037 [US4] COMPUERTA (Docker, unos 20 a 35 minutos más el costo de reconstruir las imágenes si T035 no las dejó en caché): el DOCKER_E2E local completo del archivo sobre el árbol de trabajo, sin inyección, `DOCKER_E2E=1 QMD_EMBED_E2E=1 QMD_E2E_MODELS_DIR=$HOME/.cache/agentic-qmd-e2e/models-041 bats --tap tests/docker-e2e-qmd.bats` con una marca de tiempo por línea (la salida pasa por un bucle que lee todo y antepone `date +%s`; ahí una tubería es segura porque el consumidor no cierra antes). Esperado: `ok` en las cinco pruebas del archivo (de la 12 a la 16 en la numeración del nightly), la última (`qmd real (041)`) con sus ocho marcas de fase en orden y la línea `# qmd embed resources:`. Registrar la duración, el pico de memoria y, como referencia para SC-003, la duración de `qmd real (041)` menos la de su fase `setup` (entre las marcas `setup` y `vector-extension`): no hay línea base local de ese tramo, porque los 24 s salen de nocturnas amd64, así que SC-003 se decide en T041 (hallazgo A2 del análisis); si la corrida carga con el build en frío de la imagen, anotarlo. Un rojo de arnés acotado se corrige aquí; uno de producto detiene la secuencia (FR-013).
- [ ] T038 [US4] Gate completo sobre un árbol congelado (huella sha256 de los archivos modificados o nuevos, igual antes, entre las dos corridas y después; `git status` y `HEAD` sin cambios). Registrar en el Registro:
  - `bats --tap tests/` secuencial en bash 5.x y después en 3.2, con la salida de error vacía y el esperado de T003 + 26 (SC-005), con las saltadas de la línea base más una en macOS (O1);
  - `tests/qmd-e2e-lock.bats` y `tests/qmd-embed-nightly.bats` con SIGPIPE ignorada (`perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats ...`), en los dos bash y con bats 1.13.0 y 1.11.0 (la versión de la CI en Linux; el tag clonado en el scratchpad y revisado antes de ejecutarlo), más la pata Linux de T031 sobre el árbol final;
  - `shellcheck` con el comando exacto del paso `Run shellcheck` de `.github/workflows/shellcheck.yml` en rc 0, y sobre el ayudante como cortesía;
  - `git diff --stat origin/main -- docker scripts modules setup.sh .github` vacío (FR-012: el producto y el workflow no cambian) y `git diff origin/main --stat` solo con `tests/helper-qmd-e2e.bash`, `tests/qmd-e2e-lock.bats`, `tests/docker-e2e-qmd.bats`, `tests/qmd-embed-nightly.bats`, `docs/qmd-upgrade-checklist.md`, `CHANGELOG.md`, `CLAUDE.md`, `.specify/feature.json` y `specs/043-e2e-lock-race-hardening/`;
  - `VERSION` igual a `git show origin/main:VERSION` (0.29.0), sin bump;
  - cero marcas combinantes, caracteres de control, de formato, de uso privado y emoji en `specs/043-e2e-lock-race-hardening/` y en los archivos nuevos (`byte_audit_files.py`) y en las líneas agregadas a los rastreados (`byte_audit.py origin/main`), y ningún texto fuera de lo que usan los archivos vecinos.
- [ ] T039 [US4] COMPUERTA (commits locales): dos commits sobre la rama, con mensajes en español, ASCII, en imperativo y sin atribución, con la identidad personal por variables de entorno y verificando con `git ls-files -s` que los modos de los archivos existentes no cambiaron: (1) `docs:` la documentación (`CHANGELOG.md`, `CLAUDE.md`, `docs/qmd-upgrade-checklist.md` y los cambios de `specs/043-e2e-lock-race-hardening/` posteriores al commit de T002, entre ellos las marcas y el Registro de este archivo); (2) `test:` el ayudante, `tests/qmd-e2e-lock.bats`, las ediciones de `tests/docker-e2e-qmd.bats` y la enmienda de P1, juntos porque B1 a B6 y P1 leen el e2e. Comprobar en un worktree desechable del scratchpad por commit (`git worktree add --detach`, que se quita al terminar) que ninguno deja la suite en rojo: el commit 1 con `tests/qmd-embed-nightly.bats` en 36 de 36 (P1 sin enmendar todavía), el commit 2 con `tests/qmd-e2e-lock.bats` en 26 de 26 y `tests/qmd-embed-nightly.bats` en 36 de 36. Sin push.
- [ ] T040 [US4] COMPUERTA (push): empujar la rama `043-e2e-lock-race-hardening` por HTTPS con el helper de `gh` y la cuenta personal (la clave SSH de este Mac resuelve a otra cuenta), sin force: `git -c credential.helper='!gh auth git-credential' push https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher.git 043-e2e-lock-race-hardening`. Verificar con `git ls-remote` por el mismo camino que la cabeza del remoto coincide con la local. El push de una rama sin PR no dispara `test.yml` ni `shellcheck.yml` (solo corren en `main` y en PR).
- [ ] T041 [US4] COMPUERTA (dispatch): lanzar `gh workflow run docker-e2e.yml --ref 043-e2e-lock-race-hardening`, seguir la corrida con un monitor del scratchpad y, al terminar, descargar el log y **comprobar que trae `GNU bash, version` antes de buscar nada en él** (`gh run view <id> --log`; con `gh api .../jobs/<id>/logs` hace falta `--allow-escape-sequences`). Registrar (`contracts/evidence-protocol.md` §5): identificador, rama y commit, `started_at` y `completed_at` del job por la API de jobs, duración y margen frente al tope de 45 minutos, la duración de `setup` y la de `qmd real (041)` menos `setup` (de las marcas de tiempo del log; **SC-003**: no pasa de 24 s, de 16,0 a 18,5 s en las nocturnas del 25 al 30-10 más 5 s, y se decide aquí), la línea TAP de la prueba 16 (`ok` ejecutada y no saltada), las ocho marcas de fase, `e2e summary:` (`total=49 executed=49 skipped=0 failed=0`) y si apareció R-BUSY (`reindex lock busy` en el log) y quién tenía el lock. Un rojo se clasifica (arnés, producto o infraestructura) con su fragmento de log antes de seguir, como en 042; uno por el lock aplica T042.
- [ ] T042 [US4] Dos registros aparte, cada uno con su COMPUERTA (abrir un issue sale del equipo): (a) solo si algún reporte (T035, T036, T037, T041 o las noches de T046) muestra un lock que no se suelta o un descendiente que lo retiene (R-EXPIRED sin retenedor conocido, o un dueño que no es el vigilante ni el setup; el retenedor de la fila del vencimiento de T036 es conocido y no cuenta): detener la secuencia (FR-013); el operador abre un issue nuevo con la evidencia (el TAP con el dueño, el estado al fallar y la cronología); no se corrige el producto aquí (el `flock -n` que se salta con rc 0 es una decisión de diseño) y se avisa al operador. (b) Siempre, después de T035: proponer al operador el issue de la segunda carrera de arranque de la prueba 13 (`tests/docker-e2e-qmd.bats:483-484` y el comentario de `:394-396`; hallazgo I1 del análisis, decisión del operador del 31-10-2026), con la lectura de `scripts/lib/qmd_index.sh:463-540` y lo que haya mostrado T035; no se corrige en esta feature.
- [ ] T043 [US4] COMPUERTA (commit y push): rebasar si hace falta y ajustar los documentos al resultado real:
  - si #115 u otro PR mergeó, rebasar la rama sobre `origin/main` (lo probable es un conflicto en `CLAUDE.md`, que se resuelve a mano conservando las dos partes); **verificar `VERSION` contra `git show origin/main:VERSION` a mano** y que el árbol de código de la cabeza rebasada es idéntico al validado (`git diff <cabeza validada> HEAD -- tests docker scripts modules setup.sh .github` vacío); si el rebase reescribe commits ya empujados, el push es `--force-with-lease` y lleva su COMPUERTA;
  - ajustar `CHANGELOG.md` y `CLAUDE.md` a lo medido en T035 a T041 (las corridas de inyección, el DOCKER_E2E, el margen y SC-003, la corrida de CI) y registrar en el Registro la decisión sobre #109 y #112; ningún test del host lee esos dos archivos, así que no invalida el gate de T038;
  - el commit de esos ajustes y de las marcas y el Registro de este archivo, y su push, son la COMPUERTA de esta tarea.

**Checkpoint**: la corrección tiene su ROJO y su VERDE en contenedor, su corrida en el runner real y sus documentos al día.

---

## Phase 8: Cierre

**Purpose**: PR, merge, noches y limpieza.

- [ ] T044 COMPUERTA: abrir el PR contra `main` con la tabla de evidencia (T035 a T038 y T041: identificadores, duración, margen, SC-003, el dueño que nombró R-BUSY), `Closes #109` solo si están registradas la inyección de la prueba 13 (T035) y B2, y `Closes #112` solo si están registradas la inyección de la fase `reindex` (T036) y la corrida de CI (T041); sin la evidencia de uno, se omite su `Closes`. Antes de abrirlo, `git diff --stat origin/main -- docker scripts modules setup.sh .github` debe estar vacío (FR-012). La CI debe mostrar el esperado vigente (T003 + 26, 1894 si `origin/main` sigue en `cd8b74f`) en los dos brazos de bash; si un brazo cae solo en la CI, reproducirlo en local (SIGPIPE ignorada; la pata Linux de T031) antes de tocar nada, y el arreglo pasa por la COMPUERTA de commit y push.
- [ ] T045 COMPUERTA: merge del PR de T044 por el operador. Después, verificar en `origin/main`: que el ayudante, el oráculo y las ediciones de los e2e son los validados (árbol idéntico al de la cabeza, `VERSION` 0.29.0, nada nuevo bajo `docker/`, `scripts/`, `modules/` ni `.github/`) y que #109 y #112 quedaron cerrados por el PR (si no, COMPUERTA: cerrarlos con la evidencia).
- [ ] T046 COMPUERTA: después del merge (SC-007), registrar las diez nocturnas siguientes: identificador, duración del job por la API de jobs, margen frente a los 45 minutos, línea TAP de la prueba 16, `e2e summary:`, si apareció R-BUSY y quién tenía el lock, y la clasificación de cualquier rojo. Los apuntes van a un PR de documentos aparte, como hizo 042 con su T035; diez noches sin falla no demuestran que la carrera desapareció (si la tasa siguiera en una de cada cinco, verlas todas limpias tendría una probabilidad de alrededor del 11 %; si fuera de una de cada diez, de alrededor del 35 %): es un registro, no una demostración, y la demostración es T035 y T036. Si alguna cae por el lock, su reporte nombra al dueño o dice qué herramienta falta, y se aplica T042. Toma al menos diez días.
- [ ] T047 COMPUERTA: limpieza, con confirmación del operador para lo que salga de la sesión: borrar las ramas de ensayo que queden (remotas y locales) y los worktrees desechables del scratchpad (`git worktree remove` y `git worktree prune`); ofrecer quitar las etiquetas de imagen que dejaron T035 a T037 y las imágenes base que bajaron T027 y T031 si no estaban (el caché de build se conserva, como en T036 de 042); borrar la rama `043-e2e-lock-race-hardening` y su worktree solo cuando el operador lo pida, tras el merge y el registro de las noches. Aparte, sin mezclarlo con esta feature, ofrecer las ramas remotas ya mergeadas de otras features (`041-nightly-qmd-embed`, `docs/038-g1-runbook-main`, `docs/039-t049-nightlies`) y la `main` local atrasada.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: T001 y T002 primero (T002 antes de cualquier otro commit). T003 es largo (unos 16 a 24 minutos por bash) y corre sobre una copia aislada, así que T004 y T005 pueden avanzar mientras tanto; entre tanto se pueden escribir archivos (T006 a T013) pero no correr ningún `bats` en el worktree.
- **Foundational (Phase 2)**: T006 después de T001. La fase bloquea todas las historias.
- **US1 (Phase 3)**: después de la fase 2. Es el MVP: T007 a T012 (ROJO) y T013 (registro del ROJO) antes de T014 a T017 (el ayudante, en orden porque es el mismo archivo), T018 (la fase `reindex`) y T019 (punto de control).
- **US2 (Phase 4)**: después de US1, porque usa el ayudante. T020 (ROJO) antes de T021 y T022 (las dos ediciones del mismo e2e, en orden) y T023.
- **US3 (Phase 5)**: T024 y T025 después de US2 (editan el mismo e2e); T027 solo necesita la sonda de T015 y puede correr en paralelo con T024 a T026.
- **Polish (Phase 6)**: después de US3. T028, T029 y T030 son paralelas entre sí; T031 (pata Linux) antes de T032 (mutaciones), porque define M35 y M36; T033 (revisión) después de T032; la evidencia de Docker corre sobre el árbol que deja la revisión.
- **US4 (Phase 7)**: T034 (herramienta) puede avanzar en paralelo con la fase 6. T035, T036 y T037 en serie y después de T033; T038 (gate) después de ellas; T039 a T041 cada una con su compuerta y en ese orden; T042 (a) solo si se cumple su condición y (b) siempre, después de T035; T043 cierra.
- **Cierre (Phase 8)**: después de US4. T045 y T046 solo existen después del merge.

### Within Each User Story

- El ROJO se registra antes de cada VERDE. Ninguna prueba de esta feature nace verde.
- Las tareas sobre el mismo archivo van en orden (casi todo vive en `tests/qmd-e2e-lock.bats`, `tests/helper-qmd-e2e.bash` y `tests/docker-e2e-qmd.bats`).
- Cada punto de control corre en bash 5.x y en 3.2, en forma secuencial.

### Parallel Opportunities

- T003 (línea base en su copia aislada) con T004 y T005.
- T012 (otro archivo) con T007 a T011.
- T027 (humo de la sonda) con T024 a T026.
- T028, T029 y T030 (documentos distintos) y T034 (herramienta del scratchpad).
- Las corridas de Docker T035 a T037 no se solapan: cada una usa unos 4 a 5 GiB de memoria y el workflow serializa sus corridas con un grupo de concurrencia (`docker-e2e`, `cancel-in-progress: false`); se lanzan en serie.

---

## Parallel Example: Polish

```bash
# Después del punto de control de T026, en paralelo y en archivos distintos:
Task: "T028 Una frase en docs/qmd-upgrade-checklist.md"
Task: "T029 Entrada de CHANGELOG.md"
Task: "T030 Entrada y viñeta en CLAUDE.md"
Task: "T034 Herramienta de inyección del scratchpad (no versionada)"
# Después, en serie: T031 (pata Linux), T032 (mutaciones), T033 (revisión), T035 a T037 (Docker), T038 (gate), T039 a T041 (commits, push y dispatch).
```

---

## Implementation Strategy

### MVP primero (US1)

1. Setup y Foundational.
2. US1: las pruebas en ROJO, el ayudante, la fase `reindex` migrada y el punto de control en VERDE.
3. Validar con L1 a L10, X1 a X6, B1, B6, D1, D2 y la P1 enmendada. Desde aquí la falla medida del 29-10 (#112) está cubierta en el host; la demostración en contenedor llega en US4.

### Entrega incremental

1. US2: los otros tres sitios, con B5 como cierre de FR-008.
2. US3: el dueño del lock en el estado al fallar, con el humo de la sonda en busybox.
3. Polish: documentos, la pata Linux, el catálogo de mutaciones y la revisión independiente.
4. US4: la evidencia de Docker (inyección y DOCKER_E2E local), el gate sobre el árbol final, los commits, el push y la corrida manual de CI.
5. Cierre: PR, merge, las diez noches y la limpieza.

Todo se mergea en un solo PR, y solo después de la evidencia: ninguna fase intermedia se publica sola.

---

## Notes

- **[P]**: archivos distintos y sin dependencias abiertas.
- No hay commits hasta T002, ni push hasta T040. La regla genérica de la plantilla («commit after each task») no aplica en este repositorio.
- **Aserciones intermedias muertas**: ningún `[[ ]]` ni `!` intermedio en las pruebas nuevas; se usan `[ ]`, `grep -q`, `case` o `run`, y un negativo se expresa como `_lacks` o `if comando; then false; fi`. Un `[[ ]]` es letra muerta solo en bash 3.2; un `!` lo es en ambos.
- **Cargas grandes por archivo**, nunca por `argv` ni por el entorno (límite por cadena de 128 KiB en Linux). El ayudante y las pruebas manejan cadenas de unos bytes; la salida de un reindex entra por `$output` de `run`, no por la línea de comandos.
- **Hermeticidad**: ninguna prueba nueva puede depender del sistema operativo del host (la CI corre ubuntu amd64 y macOS arm64: O1 se salta con su motivo en macOS y corre en Linux), de ser root, de la arquitectura ni de la red. Las mutaciones de T032 corren como no root.
- **Git y GitHub**: los pushes son por HTTPS con el helper de `gh`; los commits llevan la identidad personal por variables de entorno; el remoto `origin` es SSH y pertenece a otra cuenta. Una rama de ensayo se crea en un worktree desechable del scratchpad y se borra al terminar, con la confirmación del operador. No usar `git stash` sin etiqueta (la pila se comparte con los demás worktrees).
- **Logs de CI**: descargar con `gh run view <id> --log` y comprobar que trae `GNU bash, version` antes de contar nada; con `gh api .../jobs/<id>/logs` hace falta `--allow-escape-sequences` (un log vacío cuenta cero en silencio).
- **VERSION**: tras cualquier rebase, verificarla contra `origin/main` a mano; git no avisa cuando dos ramas escriben el mismo número.
- **Harness de la sesión**: los comandos compuestos o calculados se rechazan en la sesión aislada; usar rutas literales y scripts del scratchpad (`python3 ruta`). Los scripts de medición salen con el código del comando medido.
- **Docker**: todo `docker exec` lleva `-u agent`; las herramientas de T027, T031 y T034 solo tocan contenedores con nombre propio o con las etiquetas de las pruebas, y no el resto de lo que el operador tiene en Docker. Un `docker compose exec` que falla sin salida (estado 1) no es `already running`.
- **Carga y contención**: no correr dos suites de bats a la vez (en 027 dos pruebas de latidos fallaron así y pasaron en aislamiento); un rojo se vuelve a medir en aislamiento y se nombra su mecanismo medido antes de llamarlo flake.
- **Hallazgos al generar las tareas (31-10-2026)**: los siete se corrigieron en los contratos con la remediación de `/speckit-analyze` (31-10-2026), así que hoy este archivo y los contratos dicen lo mismo; se conservan como registro:
  - **H1**: `host-oracle.md` §6 y `quickstart.md` V1 dicen que D1 cae por el contenido del e2e, pero D1 compara la constante del ayudante con el producto, así que su ROJO es la ausencia del ayudante, igual que L, X, O y D2 (T013).
  - **H2**: FR-006 pide volcar los logs del contenedor ante cualquier falla de la prueba 13, y `host-oracle.md` (B2) y `reindex-wait.md` §5 no fijan el mecanismo ni lo afirman. Se fija en una extensión de `teardown()` (cubre un aborto en cualquier línea, que un volcado dentro del cuerpo no cubre) y B2 la afirma, sin prueba nueva (T020 y T021).
  - **H3**: SC-001 pide 5 s y 20 s en cada uno de los tres sitios, y `evidence-protocol.md` §3 usaba 30 s en la prueba 12. La prueba 13 ya estaba completa: la primera redacción de este hallazgo decía que no, por una mala lectura de la tabla (hallazgo I3 del análisis).
  - **H4**: `data-model.md` §3 no fija el formato de la línea `STATE` que el ayudante lee del contenedor ni el texto de las condiciones de R-EFFECT (salvo `qmd-index.json is absent`); T009 lo fija y las pruebas afirman solo que el reporte nombra el dato.
  - **H5**: B5 se escribe en US2 y O1 y O2 (US3) se secuencian en la fase de US1 (ver Organization).
  - **H6**: M35 y M36 solo pueden caer en Linux (O1 se salta en macOS y la rama de `/proc` de la sonda no se ejercita ahí); `host-oracle.md` §5 las anticipa sin decir dónde corren; T031 les da una pata Linux.
  - **H7**: la invariante I10 de `reindex-wait.md` (nada por la salida estándar) vale para `qmd_e2e_reindex_wait` y `qmd_e2e_reindex_effect`; `qmd_e2e_lock_owners` imprime sus líneas por la salida estándar porque su llamador las captura (T014 y T015).
- **Cifras de partida**: 26 pruebas nuevas, 39 mutaciones en los dos bash (M1 a M34 y M37 a M41) más M35 y M36 en la pata Linux, 4 historias, FR-001 a FR-013 y SC-001 a SC-008. Esperado de la suite del host: la línea base medida en T003 más 26 por bash (1868 + 26 = 1894 si `origin/main` sigue en `cd8b74f`); el resumen del nightly sigue en `total=49`.

### Registro (se completa durante la implementación)

- **Punto de partida (T001, 31-10-2026, verificado después de la nocturna de ese día)**:
  - `origin/main` sigue en `cd8b74f`, en local y en remoto (`git ls-remote` por HTTPS da `cd8b74fcf4ce6ee92282ce57250ea72defe99811`), así que no hubo que traer nada; `git show origin/main:VERSION` da 0.29.0.
  - El único PR abierto es el #115 (`docs/042-cierre`, MERGEABLE, actualizado el 30-10-2026). Toca `CLAUDE.md`, `specs/041-nightly-qmd-embed/tasks.md` y `specs/042-qmd-sqlite-vec-x64/tasks.md`, ninguno de los archivos de pruebas de esta feature; el rebase de T043 sigue siendo probable por `CLAUDE.md`.
  - `git status --short`: solo `.specify/feature.json` modificado y `specs/043-e2e-lock-race-hardening/` sin rastrear.
  - Nocturnas desde el 30-10: la del 30-10 (run 41046834462) y la del 31-10 (run 41194270915, sobre `cd8b74f`) en verde, sin rojos que clasificar. La del 31-10 tardó 26 min 59 s (job de 10:48:57Z a 11:15:56Z, margen de 18 min 1 s contra 45), la más lenta medida hasta hoy. El peor caso de FR-005 sigue cabiendo (27 + 12 = 39 min); se actualizaron la cifra del caso borde del spec, D4 de research y la sección 4 de `reindex-wait.md`. Ninguna noche anterior al merge cuenta para SC-007.
  - Archivos de ignorar (paso de `/speckit-implement`): `.gitignore` existe con los patrones universales que importan aquí (`node_modules/`, `.DS_Store`, `*.tmp`, `*.swp`). No se crea `.dockerignore` ni se agregan patrones: la feature es solo de pruebas (FR-012), las imágenes se construyen desde el workspace del scaffold y no desde este repo, y T038 exige un diff limitado a los archivos de la feature. La consulta de otras configuraciones (Node, ESLint, Prettier, Terraform) la bloqueó el hook de secretos por nombrar un archivo de credenciales de npm y no se repitió; el plan declara un stack solo de shell.
  - Identidad para los commits: `Rodrigo Andres Hinojosa Acuña <rodrigo.hinojosa.developer@gmail.com>`, la de los commits de 041 y 042 (`git log --all`); el `user.email` del repo es otro, por eso va por variables de entorno.
- **Modelos y Docker (T004, T005)**: Pendiente.
- **Línea base (T003)**: Pendiente.
- **ROJO y VERDE por historia (T013, T019, T020, T023, T024, T026)**: Pendiente.
- **Clasificación de las llamadas a `heartbeatctl qmd-reindex` (FR-008, T018 y T022)**: Pendiente.
- **Humo de la sonda (T027)**: Pendiente.
- **Pata Linux (T031) y mutaciones (T032)**: Pendiente.
- **Revisión independiente (T033)**: Pendiente.
- **Inyección de falla (T035, T036)**: Pendiente (una fila por corrida: identificador, sitio, cuerpo, retención, instante en que el retenedor tomó el lock, resultado, duración y líneas de R-BUSY o R-EXPIRED).
- **DOCKER_E2E local y SC-003 (T037)**: Pendiente (duración, costo de reconstruir las imágenes, pico de memoria y la prueba 16 sin `setup`).
- **Gate completo (T038)**: Pendiente.
- **Commits y push (T039, T040)**: Pendiente.
- **Corrida de CI (T041)**: Pendiente.
- **Issues #109 y #112, FR-013 y el issue de la segunda carrera de la prueba 13 (T042)**: Pendiente.
- **Rebase y documentos finales (T043)**: Pendiente.
- **PR y merge (T044, T045)**: Pendiente.
- **Noches posteriores (T046)**: Pendiente.
- **Limpieza (T047)**: Pendiente.
- **Análisis (`/speckit-analyze`, 31-10-2026)**: 19 hallazgos (0 CRITICAL, 2 ALTA, 5 MEDIA y 12 BAJA), 21 de 21 requisitos con tarea y ningún conflicto con la constitución. Los dos ALTA eran huecos del oráculo: la orden del intento quedaba sin guardia una vez enmendada P1 (C1), y el retorno del segundo tick también, porque un intento que pierde el lock sale con estado 0 (C2). Cuatro decisiones del operador, todas con la opción recomendada: remediar los 19; demostrar SC-008 con una fila nueva en T036 (vencimiento forzado en la 041 con el lock retenido 600 s); no buscar en contenedor el caso `skipped` (lo prueba X2 en el host, y se corrigió el texto porque con 20 s el vigilante también pierde el lock); y declarar la segunda carrera de arranque de la prueba 13 (`:483-484`) con un issue aparte propuesto en T042. Remediado en el spec, el plan, la investigación, el modelo de datos, el quickstart, los cuatro contratos y este archivo: las pruebas siguen siendo 26 y el catálogo en los dos bash pasa de 34 a 39 mutaciones. Medido en la sesión, en bash 3.2.57 y 5.3.15: `[ "$rc3" -eq 0 ]` con `rc3` sin asignar sale con 2, y una función con un comando fallido sin guardia sigue de largo dentro de una lista `||` y aborta al llamador cuando se la llama suelta.
