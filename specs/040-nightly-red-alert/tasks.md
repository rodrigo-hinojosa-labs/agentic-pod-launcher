---

description: "Task list for 040-nightly-red-alert"
---

# Tasks: Una noche en rojo del nightly le llega a alguien

**Input**: Design documents from `/specs/040-nightly-red-alert/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (alert-workflow, alert-script, notice-format, alert-oracle), quickstart.md

**Tests**: OBLIGATORIOS y primero (constitución III): el oráculo `tests/nightly-alert.bats`, su `gh` falso y sus fixtures se escriben y se ven en ROJO antes de crear `.github/scripts/nightly-alert.sh` y antes de tocar `.github/workflows/docker-e2e.yml`.

**Organization**: por historia de usuario, pero **ordenadas por dependencia sobre los dos archivos que comparten todas** (el script y el workflow), no por prioridad: US1 y US2 son P1 y van primero; US3 y US4 (P2) extienden el mismo script. Dentro de un mismo archivo no hay `[P]`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: archivos distintos y sin dependencia de una tarea incompleta (fixtures, el `gh` falso, documentos, la línea base en una copia aislada).
- **[Story]**: US1 a US4; las fases de Setup, Foundational, Polish y Compuertas no llevan historia.
- **COMPUERTA**: requiere la confirmación explícita del operador, cada una por separado, y NO se ejecuta sola: commit, push, cada `workflow_dispatch`, el PR y el merge.
- Rutas desde la raíz del repositorio. Gate dual de bash: `bats tests/` y después `PATH=/bin:$PATH bats tests/` (3.2.57), **secuencial, nunca concurrente**; un rojo de contención se re-mide aislado antes de nombrarlo.
- Alcance fijo (FR-017): NO tocar `docker/`, `scripts/`, `modules/` ni `setup.sh`, ni el texto de los pasos `Verify deps + docker` y `Run docker-e2e suite` (O1 a O5 y S1 a S6 de 039 deben seguir verdes sin editarse).

## Phase 1: Setup

**Purpose**: línea base y prerrequisitos.

- [X] T001 [P] Medir la línea base en una copia aislada de `main`@`13cafc3` (por ejemplo `git worktree add` en el scratchpad): `bats tests/` en bash 5.x y después `PATH=/bin:$PATH bats tests/` en 3.2.57, secuencial y sin otra carga en el Mac. Esperado: **1817 ok y 0 not ok** en cada uno. Anotar conteos, saltos y duraciones en Notes. Conviene lanzarla primero y no ejecutar T007, T011 ni otro gate mientras corre (un rojo por contención se re-mide aislado antes de nombrarlo).
- [X] T002 Verificar prerrequisitos y alcance en el árbol de trabajo: `bats`, `yq` v4, `jq`, `perl`, `shellcheck` y `gh` presentes; `git fetch origin` y `VERSION` 0.28.0 igual a `origin/main`; `.specify/feature.json` apunta a `specs/040-nightly-red-alert`; los `--help` de `gh issue list|create|comment|edit|reopen|close` y de `gh label create` siguen mostrando las banderas de research R8. Anotar en Notes.

---

## Phase 2: Foundational (bloquea todas las historias)

**Purpose**: el instrumento de medición del oráculo. Estas tareas pasan hoy y prueban que el oráculo puede fallar.

- [X] T003 [P] Crear en `tests/fixtures/nightly-alert/` los ejemplos de `toJSON(steps)`: `steps-green.json`, `steps-suite-red.json` (`run_suite` con `outcome: failure`), `steps-verify-red.json` (`verify_deps` con `failure`; los pasos siguientes ausentes), `steps-cancelled.json` y `steps-invalid.txt` (texto que no es JSON). Forma: un objeto por id de paso con `outputs`, `outcome` y `conclusion`; los ids son los de `contracts/alert-workflow.md` sección 2 (`checkout`, `install_yq`, `install_bats`, `verify_deps`, `run_suite`, `simulate`).
- [X] T004 [P] (desviación anotada en Notes: `tap-hostile.tap` no se versiona, se genera en tiempo de ejecución) Crear en `tests/fixtures/nightly-alert/` los TAP: `tap-25-failures.tap` (25 `not ok` y algunos `ok`), `tap-long-names.tap` (nombres de más de 120 caracteres) y `tap-hostile.tap` (nombres con `@usuario`, `#12`, comillas invertidas, `~~~`, `<!--`, `-->` y un carácter de control). Los TAP de `tests/fixtures/ci/` (`tap-mixed`, `tap-failing`, `tap-all-skip`, `tap-empty`) se reutilizan sin copiarlos.
- [X] T005 [P] Crear el `gh` falso `tests/fixtures/nightly-alert/gh` (bash, ejecutable) según `contracts/alert-oracle.md` sección 1: estado en `$FAKE_GH_STATE` (obligatoria: sin ella sale con 99) con `issues.json`, `labels.txt` y `calls.log`; **lista blanca de banderas** idéntica a research R8 (`issue list --label --state --limit --json`; `issue create --title --label --assignee --body-file`; `issue comment --body-file`; `issue edit --body-file`; `issue reopen --comment`; `issue close --reason --comment`; `label create --color --description`); cualquier otra bandera o subcomando sale con 64 y escribe `UNSUPPORTED` en `calls.log`; `issue list --json` filtra por etiqueta y estado, ordena por número descendente, aplica `--limit` y proyecta solo los campos pedidos, sin `--jq`; falla inyectable con `FAKE_GH_FAIL` (lista separada por comas de `list`, `label`, `create`, `create_assignee`, `edit`, `comment`, `reopen`, `close`); una línea por llamada en `calls.log` (`verbo<TAB>argumentos`).
- [X] T006 Crear `tests/nightly-alert.bats` (FR-014: el oráculo ejecuta el texto real de la lógica de aviso contra un sustituto del servicio de issues de GitHub y cubre los nueve casos): cabecera con los contratos que cumple, `load helper`, `bats_require_minimum_version 1.5.0`, `setup`/`teardown` con directorio temporal y `FAKE_GH_STATE`, y los helpers copiados de `tests/ci-workflows.bats` con un comentario que apunta a su origen (`_has`, `_lacks`, extracción de un `run:` con `yq`) más los propios: `_seed_issue NUMERO ESTADO MARCADOR_ESTADO TOTAL [ETIQUETA]`, `_calls`, `_mutating_calls` (verbos `create`, `edit`, `comment`, `reopen`, `close`, `label-create`) y el arnés `_notify`/`_collect`, que ejecuta `"$BASH" .github/scripts/nightly-alert.sh <subcomando>` con el entorno por defecto de `data-model.md` sección 1 (`EVENT=schedule`, `RUN_RESULT=failure`, `FAILED_STEP=run_suite`, `SUMMARY`, `FAILED_TESTS`, `RUN_ID`, `RUN_ATTEMPT`, `RUN_URL`, `ASSIGNEE`, `GH_TOKEN`, `GH_REPO`), con el falso al frente del `PATH` con la disposición de SIGPIPE que pida `SIGPIPE_MODE` (`ignore` por defecto, que es la que el script hereda en el runner de GitHub, o `default`), fijada con `perl` justo antes de lanzarlo, con `NIGHTLY_ALERT_NOW` fijo por defecto (`1792497600`, `1792584000` y `1792670400` son el 20, 21 y 22-10-2026 a las 12:00 UTC) y con las rutas bajo prueba tomadas de `ALERT_SCRIPT` y `ALERT_WORKFLOW` (por defecto `.github/scripts/nightly-alert.sh` y `.github/workflows/docker-e2e.yml` del repositorio), de modo que cada mutación se aplique a una copia sin tocar el árbol. Reglas del archivo: bash 3.2 y 5.x (sin `mapfile`, arreglos asociativos ni `${v,,}`), nunca `productor | head` ni `| grep -q` sobre `$output`, negativos con `_lacks` o `run …; [ "$status" -ne 0 ]`, y ningún `[[ ]]` intermedio. Incluir **N00**: el falso llamado directo registra la llamada, rechaza una bandera desconocida y exige `FAKE_GH_STATE`. N00 es la **calibración del instrumento**: su capacidad de fallar se demuestra rompiendo el falso una vez (por ejemplo, haciendo que acepte cualquier bandera) y anotándolo en Notes.
- [X] T007 Checkpoint de la fundación: `bats tests/nightly-alert.bats` deja N00 en verde en bash 5.x y en 3.2.57 (secuencial). Anotar en Notes.

**Checkpoint**: el instrumento funciona; las historias pueden empezar.

---

## Phase 3: User Story 1 - Una noche en rojo deja un aviso que se ve sin abrir Actions (Priority: P1) — MVP

**Goal**: ante una corrida programada en rojo, el aviso aparece con enlace, paso fallido, resumen y tests fallidos; `collect` entrega esos datos.

**Independent Test**: `bats tests/nightly-alert.bats` con N01, N02 y N18 a N20 en verde; la parte real se prueba en E1 (compuerta).

### Tests for User Story 1 (escribirlos primero y verlos fallar)

- [X] T008 [US1] Escribir **N01** en `tests/nightly-alert.bats`: rojo nuevo (`EVENT=schedule`, `RUN_RESULT=failure`, sin issues) crea la etiqueta `nightly-red` y el issue con título `docker-e2e nightly en rojo`, etiqueta, asignado `ASSIGNEE` y cuerpo cuya primera línea es `<!-- nightly-red:v1 state=open total=1 first=YYYY-MM-DD -->` (la que corresponde a `NIGHTLY_ALERT_NOW=1792497600`: `2026-10-20`, y `20-10-2026` en el texto de la fila), con el enlace de la corrida, el paso fallido, la línea de resumen y los nombres de los tests dentro de un bloque `~~~text` (FR-001, FR-002, FR-019, SC-001).
- [X] T009 [US1] Escribir **N02** en el mismo archivo: rojo sin resumen (`FAILED_STEP=verify_deps`, `SUMMARY` y `FAILED_TESTS` vacíos) deja un cuerpo con `no disponible` en el resumen y `ninguno informado` en los tests, y nombra el paso (US1, escenario 2).
- [X] T010 [US1] Escribir **N18, N19 y N20** en el mismo archivo. N18: `collect` con los ejemplos de `toJSON(steps)` (suite roja, verificación roja, todo verde, `cancelled`, JSON inválido) entrega `failed_step` correcto o vacío. N19, **paridad**: extraer con `yq` el `run:` real del paso `Run docker-e2e suite` de `.github/workflows/docker-e2e.yml`, ejecutarlo con un `bats` falso que imprima cada TAP (`tap-mixed`, `tap-failing`, `tap-all-skip`, `tap-empty`) y exigir que el `summary` de `collect` sea idéntico a la cadena que sigue a `e2e summary: ` (R2). N20: nombres con caracteres especiales no rompen el formato de `GITHUB_OUTPUT` (delimitador aleatorio).
- [X] T011 [US1] **Ver el ROJO** (FR-015: rojo antes de la implementación): `bats tests/nightly-alert.bats` deja N01, N02 y N18 a N20 en `not ok` con un mensaje que dice que el script no existe (guardia de no-vacuidad 2 de `alert-oracle.md`) y N00 en verde. Anotar la evidencia en Notes.

### Implementation for User Story 1

- [X] T012 [US1] Crear `.github/scripts/nightly-alert.sh` (ejecutable, `#!/usr/bin/env bash`, solo ASCII): despacho de subcomandos (`collect`, `simulate`, `notify`; desconocido o ausente: uso en `stderr` y salida 2), funciones `say_notice` y `warn` que imprimen `::notice::nightly-alert: …` y `::warning::nightly-alert: …`, `mktemp -d` con `trap … EXIT`, y **sin `set -e`**. Reglas: bash 3.2 y 5.x, ningún pipe cuyo consumidor cierre antes que el productor, cargas por archivo.
- [X] T013 [US1] Implementar `collect` en el script según `contracts/alert-script.md` sección 2: `failed_step` (primer id de `STEPS_JSON` con `outcome` `failure` o `cancelled`, vacío si ninguno o si no es JSON), `summary` con las tres cuentas del paso de la suite (`^(ok|not ok) [0-9]+`, `^ok [0-9]+ .*# skip`, `^not ok [0-9]+`; `executed = total - skipped`) y `failed_tests` con los nombres de `not ok N <nombre>`, uno por línea; salida a `$GITHUB_OUTPUT` (o a `stdout`), las de varias líneas con delimitador aleatorio. La cota de 20 nombres y de 120 caracteres se agrega en US4 con su RED. N18 a N20 en verde.
- [X] T014 [US1] Implementar en `notify` el camino **rojo nuevo** (modo `real`, clase `red`, sin aviso previo): `gh issue list --label nightly-red --state all --limit 1 --json number,state,body,url`; `gh label create nightly-red --color D93F0B --description "…"` ignorando el error si ya existe; cuerpo según `contracts/notice-format.md` sección 3 en un archivo temporal (marcador `<!-- nightly-red:v1 state=open total=N first=YYYY-MM-DD -->`, con "`total` es un entero positivo" y "`first` es una fecha ISO en UTC"; fechas del texto en `DD-MM-YYYY`); `gh issue create --title "docker-e2e nightly en rojo" --label nightly-red --assignee "$ASSIGNEE" --body-file …`; saneo mínimo del texto del log (quita caracteres de control; el endurecimiento completo es de US4). La fecha de la noche sale de `NIGHTLY_ALERT_NOW` si está definida (se formatea con `date -u -d @N` y, si falla, con `date -u -r N`) y del reloj si no. Texto del aviso solo en ASCII. N01 y N02 en verde (FR-012: el canal es un issue del propio repositorio).
- [X] T015 [US1] GREEN de la historia: N00, N01, N02 y N18 a N20 en verde en bash 5.x y en 3.2.57, secuencial; `shellcheck -S error -e SC1090,SC1091` sobre `.github/scripts/nightly-alert.sh` en rc 0. Anotar en Notes.

**Checkpoint**: US1 funciona con el `gh` falso; aún no hay workflow.

---

## Phase 4: User Story 2 - El aviso no puede cambiar el veredicto de la noche ni esconder su causa (Priority: P1)

**Goal**: ninguna falla del aviso toca el color de la corrida; el job `alert` queda cableado con los permisos mínimos.

**Independent Test**: N12 y las pruebas estructurales N23 a N28, N30 y N31 en verde; en real, E1.

### Tests for User Story 2 (escribirlos primero y verlos fallar)

- [X] T016 [US2] Escribir **N12** en `tests/nightly-alert.bats`: con cada llamada a `gh` fallando por turnos (`FAKE_GH_FAIL=list`, `label`, `create`, `edit`, `comment`, `close`, `reopen`) `notify` sale con 0 y escribe `::warning::nightly-alert:`; con `create_assignee` el aviso se crea igual **sin** asignado y se anota (FR-009, FR-019, SC-004).
- [X] T017 [US2] Escribir las estructurales sobre `.github/workflows/docker-e2e.yml` con `yq`, cada una asertando también la presencia de lo que protege (para que no nazcan verdes por vacuidad); **N23 y N26 fijan además FR-010**: el job `alert` es aparte y depende de `e2e`, así que el primer fallo identificable de la corrida sigue siendo el paso de la suite: **N23** (AW-1: job `alert` con `needs: e2e`, el `if` literal de `contracts/alert-workflow.md` sección 3 y `timeout-minutes: 5`), **N24** (AW-2: `permissions` del job `alert` exactamente `contents: read` e `issues: write`), **N25** (AW-3: el nivel del workflow y el job `e2e` no tienen `issues` y solo `contents: read`), **N26** (AW-4: el paso `Publish the nightly notice` lleva `continue-on-error: true` y llama al script con `notify`), **N27** (AW-5: cero `secrets.` en el archivo; nace verde por ser un ratchet y su capacidad de fallar se demuestra con la mutación M2), **N28** (AW-6: las entradas `alert_trial` boolean `false` y `trial_outcome` choice `red|green|timeout` por defecto `red`), **N30** (AW-8: `collect` es el último paso con `if: ${{ always() }}`, las tres salidas del job apuntan a `steps.collect.outputs.*` y todos los pasos tienen `id`) y **N31** (AW-9: el script existe, es ejecutable y empieza con `#!/usr/bin/env bash`).
- [X] T018 [US2] **Ver el ROJO**: N12 y N23, N24, N26, N28, N30, N31 en `not ok` (el job y los ids no existen); anotar cuáles nacen verdes (solo N27, que es un ratchet y cuyo cazador es la variante (b) de M2; N25 asierta la presencia del job `alert` y nace en ROJO).

### Implementation for User Story 2

- [X] T019 [US2] En el script, el manejo de fallas de `contracts/alert-script.md` sección 4: función que envuelve cada llamada a `gh` (captura código y salida, anota `::warning::nightly-alert: no se pudo <accion>: <estado>` y devuelve), una falla en `list` termina `notify` con aviso y salida 0, el reintento sin `--assignee` cuando falla la asignación, y salida 0 al final de `collect` y `notify`. N12 en verde.
- [X] T020 [US2] Editar `.github/workflows/docker-e2e.yml` según `contracts/alert-workflow.md`: ids legibles en los pasos del job `e2e` (`checkout`, `install_yq`, `install_bats`, `verify_deps`, `run_suite`) **sin cambiar nombres ni texto**; paso final `collect` (`id: collect`, `if: ${{ always() }}`, `env: STEPS_JSON: ${{ toJSON(steps) }}`, `run: .github/scripts/nightly-alert.sh collect`); `outputs` del job (`failed_step`, `summary`, `failed_tests`); las entradas `alert_trial` y `trial_outcome` de `workflow_dispatch`; y el job `alert` completo de la sección 3 (checkout, paso `notify` con `continue-on-error: true` y el entorno por variables, nunca interpolado en `run:`). No tocar `Verify deps + docker` ni `Run docker-e2e suite`.
- [X] T021 [US2] GREEN de la historia en ambos bash (secuencial) (desviación anotada en Notes: las piernas de N12 que fallan `edit`, `comment`, `reopen` y `close` necesitan los flujos de US3, así que N12 completo queda verde en T033; aquí pasan sus piernas `list`, `label`, `create` y `create_assignee`): N23, N24, N25, N26, N27, N28, N30 y N31 en verde; y los **14 tests de `tests/ci-workflows.bats`** (O1 a O5, S1 a S6, R1 a R3) siguen verdes **sin editarse** (R3 ya barre los pasos nuevos). Anotar en Notes.

**Checkpoint**: US1 y US2 (los dos P1): el aviso existe, no puede romper la noche y el workflow está cableado.

---

## Phase 5: User Story 3 - Una racha de rojos es un solo aviso y se apaga sola con el verde (Priority: P2)

**Goal**: actualizar, cerrar, reabrir y separar rachas; las corridas manuales y canceladas no mueven nada; el ensayo no toca el aviso real.

**Independent Test**: N03 a N11, N13 y N16 en verde con el `gh` falso; en real, E2 a E6.

### Tests for User Story 3 (escribirlos primero y verlos fallar)

- [X] T022 [US3] Escribir **N03** (rojo repetido: con un aviso abierto no se crea otro, `total` +1, fila y comentario nuevos) y **N04** (tres corridas rojas con `RUN_ID` distintos dejan un solo aviso con `total=3` y tres filas; SC-002; cada corrida con su `NIGHTLY_ALERT_NOW` de `1792497600`, `1792584000` y `1792670400`, así que las filas llevan `20-10-2026`, `21-10-2026` y `22-10-2026` y el marcador conserva `first=2026-10-20`) en `tests/nightly-alert.bats`.
- [X] T023 [US3] Escribir **N05** (verde tras rojo: marcador `state=resolved`, comentario con el enlace de la corrida verde y cierre con `--reason completed`; SC-003) y **N06** (verde sin aviso previo, o con el último en `resolved`: cero llamadas mutantes).
- [X] T024 [US3] Escribir **N07** (FR-007: `cancelled`, `skipped` y un valor desconocido: cero llamadas mutantes y el valor recibido aparece en la anotación `::notice::`) y **N08** (`workflow_dispatch` sin ensayo, en rojo y en verde: cero llamadas, ni siquiera `list`, y la anotación de "sin accion").
- [X] T025 [US3] Escribir **N09** (último aviso `CLOSED` con `state=open` y rojo: se reabre con `reopen --comment`, `total` +1, no se crea otro) y **N10**, con dos piernas: (a) último aviso `CLOSED` con `state=resolved` y rojo: se crea uno nuevo y el anterior no se toca; (b) último aviso `CLOSED` con `state=open` (cerrado a mano) y **verde**: solo se reescribe su marcador a `state=resolved` con `edit` (sin reabrir, comentar ni cerrar) y el rojo siguiente crea uno nuevo sin reabrir el viejo (hallazgo I1 del análisis).
- [X] T026 [US3] Escribir **N11** (ensayo aislado: con un aviso real abierto, `EVENT=workflow_dispatch` y `TRIAL=true` en rojo crea el aviso de ensayo con la etiqueta `nightly-red-trial` y el título `[ensayo] docker-e2e nightly en rojo` sin tocar el real; un ensayo en verde cierra solo el de ensayo), **N13** (idempotencia: el mismo `RUN_ID` dos veces, en rojo y en verde, no cambia nada la segunda vez) y **N16** (marcador ausente o inválido: se comenta y se reabre si hacía falta, **sin reescribir el cuerpo**, con `::warning::`).
- [X] T027 [US3] **Ver el ROJO**: todos los de T022 a T026 en `not ok` (el script solo sabe crear); anotar.

### Implementation for User Story 3 (sobre el mismo script, en este orden)

- [X] T028 [US3] En `notify`, la decisión de modo y clase (`data-model.md` secciones 1 y 5): `schedule` es modo `real`; `workflow_dispatch` con `TRIAL=true` es `trial`; cualquier otra combinación no hace nada (ni `list`) y lo anota; `success` es `green`, `failure` es `red`, `cancelled`, `skipped` u otro valor es `none` y se anota el valor recibido (regla por defecto de research R7). N07 y N08 en verde.
- [X] T029 [US3] En `notify`, **rojo con aviso abierto**: no sumar si el cuerpo ya tiene `[run <RUN_ID>](` (idempotencia: "una fila se identifica por el id de la corrida; repetir el id no suma la noche"); si no, `total` +1, fila nueva, cuerpo reescrito (`gh issue edit --body-file`) y un comentario de una línea (`contracts/notice-format.md` sección 4). N03, N04 y la parte roja de N13 en verde.
- [X] T030 [US3] En `notify`, **verde con aviso abierto**: reescribir el marcador a `state=resolved`, comentar con el enlace de la corrida verde y cerrar con `gh issue close N --reason completed`; **verde sin aviso abierto**: no hacer nada; cerrar un aviso ya cerrado no hace nada; **verde con el último aviso cerrado a mano (`state=open`)**: solo `gh issue edit N --body-file …` con el marcador en `state=resolved`, sin reabrir, comentar ni cerrar. N05, N06, la parte verde de N13 y la pierna (b) de N10 en verde.
- [X] T031 [US3] En `notify`, **rojo con el último aviso cerrado**: `state=open` es un cierre manual, así que `gh issue reopen N --comment …` y sumar la noche; `state=resolved` es otra racha, así que se crea uno nuevo sin tocar el anterior; marcador ausente o inválido se trata como `state=open` sin reescribir el cuerpo y con advertencia (`notice-format.md` sección 2). N09, la pierna (a) de N10 y N16 en verde.
- [X] T032 [US3] En `notify`, la identidad por modo: etiqueta, color, descripción y título del modo `trial` (`nightly-red-trial`, `FBCA04`, `[ensayo] docker-e2e nightly en rojo`); un modo nunca lee ni escribe issues con la etiqueta del otro. N11 en verde.
- [X] T033 [US3] GREEN de la historia en ambos bash (secuencial): N03 a N11, N12 (completo), N13 y N16 en verde junto con todo lo anterior; `shellcheck` del script en rc 0. Anotar.

**Checkpoint**: el ciclo completo de una racha funciona contra el `gh` falso.

---

## Phase 6: User Story 4 - La suite del host impide que el aviso se vuelva mudo sin que nadie lo note (Priority: P2)

**Goal**: cotas, texto inerte, independencia de SIGPIPE, higiene del script, la mecánica del ensayo en el workflow y las mutaciones que prueban que el oráculo puede fallar.

**Independent Test**: N14, N15, N17, N21, N22 y N29 en verde, y 0 mutaciones sobrevivientes.

### Tests for User Story 4 (escribirlos primero y verlos fallar)

- [X] T034 [US4] Escribir **N14** (cotas, FR-003) en `tests/nightly-alert.bats`: con `tap-25-failures.tap` el `failed_tests` de `collect` trae 20 nombres y la línea `... y 5 mas`; con `tap-long-names.tap` cada nombre queda en 120 caracteres como máximo con `...`; en `notify`, una racha con `total` 155 muestra 10 filas de detalle, conserva el total en el marcador y el cuerpo mide menos de 60.000 caracteres ("si pasara, se recortan primero las filas de detalle").
- [X] T035 [US4] Escribir **N15** (texto inerte, FR-004) con `tap-hostile.tap`: ningún nombre conserva comillas invertidas ni `~~~`, `<!--` y `-->` quedan neutralizados, los nombres van dentro del bloque `~~~text` íntegro, el marcador de la primera línea queda intacto y ningún carácter de control llega al cuerpo; y **N17** (independencia de SIGPIPE): el caso N03 ejecutado con `SIGPIPE_MODE=ignore` y con `SIGPIPE_MODE=default` da el mismo estado final, la misma salida (incluida `stderr`) y el mismo código, y una **sonda** del propio arnés (`yes` hacia `head -1`, mirando `PIPESTATUS`) demuestra que cada modo aplica de verdad su disposición (141 en `default`, otro valor en `ignore`): sin la sonda el test podría pasar sin que la señal llegue al script.
- [X] T036 [US4] Escribir **N21** (`simulate`: `red` sale con 1 y deja un `e2e.tap` con un `not ok`; `green` sale con 0 y deja un TAP sin fallos; `timeout` duerme `TRIAL_TIMEOUT_SLEEP` segundos y sale con 0; un argumento desconocido sale con 2) y **N29** (AW-7: `run_suite` lleva `if: ${{ !inputs.alert_trial }}`, el paso `simulate` lleva `if: ${{ inputs.alert_trial }}` y `TRIAL_OUTCOME: ${{ inputs.trial_outcome }}`, y `timeout-minutes` del job `e2e` es exactamente `${{ (inputs.alert_trial && inputs.trial_outcome == 'timeout') && 1 || 30 }}`).
- [X] T037 [US4] Escribir **N22** (higiene del script): `bash -n` sin errores, shebang, bit de ejecución, solo ASCII, sin construcciones de bash 4 (`mapfile`, `declare -A`, `${…,,}`, `${…^^}`, `coproc`, `local -n`), y sin ningún pipe cuyo consumidor cierre antes que el productor (`head`, `grep` con `-q` o `-m`, `sed` con `Nq`, `awk` con `exit`: las mismas reglas del ratchet de 039); N17 y N22 nacen verdes por ser guardas y su capacidad de fallar se demuestra con las dos variantes de M19: la (a), `| head -1`, cae en N22; la (b), un pipe que lee una línea y cierra con una carga de más de 64 KiB, solo se nota si la disposición de SIGPIPE cambia el resultado, así que cae en N17.
- [X] T038 [US4] **Ver el ROJO**: N14, N15, N21 y N29 en `not ok`; anotar cuáles nacen verdes (N17, N22) y por qué.

### Implementation for User Story 4

- [X] T039 [US4] En el script, las cotas: en `collect` y en el cuerpo de `notify`, "hasta 20 nombres de test" con la línea final `... y N mas`, cada nombre de "máximo 120 caracteres, recortado con `...`", 10 filas de detalle de noches y el cuerpo por debajo de 60.000 caracteres recortando primero las filas. N14 en verde.
- [X] T040 [US4] En el script, el saneo completo del texto del log (`contracts/notice-format.md` sección 6): quitar caracteres de control salvo el salto de línea que separa nombres, cambiar comillas invertidas y virgulillas por apóstrofos, neutralizar `<!--` y `-->` (a `<!-` y `->`), recortar cada línea a 120 caracteres; nombres dentro de `~~~text`; el paso fallido y el resumen entre comillas invertidas tras el saneo; el marcador se arma solo con valores propios del script. N15 en verde.
- [X] T041 [US4] En el script, el subcomando `simulate` (`contracts/alert-script.md` sección 3): `red` escribe `e2e.tap` con `1..4`, tres `ok` y `not ok 4 trial: induced failure` y sale con 1; `green` escribe cuatro `ok` y sale con 0; `timeout` escribe `1..1` y duerme `TRIAL_TIMEOUT_SLEEP` segundos (120 por defecto). N21 en verde.
- [X] T042 [US4] Editar `.github/workflows/docker-e2e.yml`: `if: ${{ !inputs.alert_trial }}` en `run_suite` (sin tocar su `run:` ni su `env: DOCKER_E2E: '1'`), el paso `simulate` con su `if`, su entorno `TRIAL_OUTCOME` y `run: .github/scripts/nightly-alert.sh simulate "$TRIAL_OUTCOME"` (antes de `collect`), y el literal de `timeout-minutes` del job `e2e`. N29 en verde, y los 14 tests de `tests/ci-workflows.bats` siguen verdes sin editarse.
- [X] T043 [US4] GREEN de la historia y del oráculo completo, secuencial: `bats tests/nightly-alert.bats` en bash 5.x y en 3.2.57 (N17 ya cubre las dos disposiciones de SIGPIPE dentro del test) y, como pasada de paridad con el runner, con el proceso de bats bajo SIGPIPE ignorada (`perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats tests/nightly-alert.bats`, que cubre el resto del archivo); los 32 tests (N00 a N31) en verde (FR-015: verde después, en bash 3.2 y 5.x y con las señales que heredan los runners). Anotar en Notes.

---

## Phase 7: Mutaciones (SC-005)

**Purpose**: demostrar que el oráculo puede fallar. Cada tarea aplica la mutación a una **copia** y apunta `ALERT_SCRIPT` o `ALERT_WORKFLOW` a ella (los tests no leen otra ruta; si algo obligara a mutar en el lugar, se restaura con `cmp` contra una copia previa), ejecuta el test cazador de la tabla de `quickstart.md` sección 3 y exige que **caiga**. Una mutación que sobrevive obliga a endurecer el oráculo (RED y después GREEN) antes de seguir. Secuencial; ninguna lleva `[P]`.

- [X] T044 M1: quitar `always()` del `if` del job `alert` en una copia del workflow. Cae **N23**.
- [X] T045 M2: dos variantes sobre una copia del workflow: (a) agregar `issues: write` a los `permissions` del workflow, cae **N25**; (b) agregar una referencia a `secrets.TOKEN`, cae **N27** (prueba que el ratchet puede fallar).
- [X] T046 M3: quitar `continue-on-error: true` del paso `Publish the nightly notice`. Cae **N26**.
- [X] T047 M4: hacer que `notify` salga con el código del último `gh` fallido. Cae **N12**.
- [X] T048 M5: crear el aviso sin `--assignee`. Cae **N01**.
- [X] T049 M6: tratar `cancelled` como rojo. Cae **N07**.
- [X] T050 M7: dejar que una corrida manual normal abra el aviso. Cae **N08**.
- [X] T051 M8: en un rojo repetido crear un segundo issue. Caen **N03** y **N04**.
- [X] T052 M9: en verde no cerrar el aviso. Cae **N05**.
- [X] T053 M10: en verde sin aviso previo crear o comentar algo. Cae **N06**.
- [X] T054 M11: en un cierre manual crear uno nuevo en vez de reabrir. Cae **N09**.
- [X] T055 M12, dos variantes: (a) cerrar por verde sin escribir `state=resolved`; (b) un verde sobre un aviso cerrado a mano que no reescribe el marcador. Cae **N10** (la pierna (a) la primera, la (b) la segunda).
- [X] T056 M13: quitar la cota de 20 nombres. Cae **N14**.
- [X] T057 M14: no sanear comillas invertidas ni `~~~`. Cae **N15**.
- [X] T058 M15: hacer que `collect` calcule `executed` igual que `total`. Cae **N19**.
- [X] T059 M16: quitar la guarda de idempotencia (`[run <id>](`). Cae **N13**.
- [X] T060 M17: que el modo ensayo use la etiqueta del aviso real. Cae **N11**.
- [X] T061 M18: quitar el `if` de ensayo de `run_suite` en una copia del workflow. Cae **N29**.
- [X] T062 M19, dos variantes: (a) introducir `| head -1` en el script, cae **N22**; (b) introducir un pipe que lee una línea y cierra, con una carga de más de 64 KiB, cae **N17**.
- [X] T063 M20: cambiar el literal de `timeout-minutes` del job `e2e`. Cae **N29**.
- [X] T064 Resumen: registrar en Notes la tabla M1 a M20 con el test que cayó en bash 5.x y en 3.2.57 y confirmar **0 sobrevivientes** (FR-015, SC-005; son 20 mutaciones y M2, M12 y M19 tienen dos variantes cada una); verificar con `cmp` que el árbol de trabajo quedó idéntico al previo a las mutaciones.

---

## Phase 8: Polish y gates locales

- [X] T065 [P] `CHANGELOG.md`: entrada que diga qué cubre el aviso y qué no (FR-018): no detecta un nightly que no llega a arrancar, la rama `schedule` de la condición solo la ejercen el oráculo y la primera noche roja real, y el aviso complementa y no reemplaza las notificaciones nativas de GitHub. **Sin bump de `VERSION`.**
- [X] T066 [P] `CLAUDE.md`: ajustar la entrada de 040 del bloque SPECKIT al estado implementado (número de tests, resultados, hallazgos) y agregar en "Common gotchas" una viñeta solo si algo nuevo se aprendió (por ejemplo, que la conclusión de una corrida es la peor de las de sus jobs, así que un job de aviso debe ser a prueba de fallas). Se versiona con `git add -f`. No ejecutar ningún hook de contexto de agente (no existe).
- [X] T067 Verificar `VERSION` a mano contra `origin/main` (`git fetch origin` y `git show origin/main:VERSION`): 0.28.0 en ambos, sin bump.
- [X] T068 Escaneo de bytes de todos los archivos tocados o nuevos (UTF-8 válido, 0 marcas combinantes, 0 bytes de control, NFC) y verificar que el script, el `gh` falso, los fixtures y `tests/nightly-alert.bats` son solo ASCII.
- [X] T069 Gate completo, un bash tras otro: `bats tests/` y después `PATH=/bin:$PATH bats tests/` (3.2.57). Esperado: **1849 ok y 0 not ok** en cada uno (1817 más los 32 tests nuevos, N00 a N31). Un rojo de contención se re-mide aislado antes de nombrarlo (regla R6 de 039). Anotar conteos, saltos y duraciones.
- [X] T070 `shellcheck -S error -e SC1090,SC1091` con el comando **exacto** del job de CI (`find` más `xargs`, `quickstart.md` sección 2.4): rc 0 y sin salida; confirmar que `./.github/scripts/nightly-alert.sh` está en la lista que lintea.
- [X] T071 Alcance y secretos (SC-007; FR-017: ni `docker/`, ni `scripts/`, ni `modules/`, ni `setup.sh`): `git diff origin/main -- docker scripts modules setup.sh | wc -l` da 0; `grep -c 'secrets\.' .github/workflows/docker-e2e.yml` da 0; `git diff origin/main -- tests/ci-workflows.bats` vacío (los tests de 039 no se editaron); los únicos permisos nuevos son `issues: write` en el job `alert`.
- [X] T072 Ejecutar la validación local de `quickstart.md` sección 2 completa y anotar el resultado en Notes.

**Checkpoint**: todo lo local está hecho y verde; lo que sigue exige al operador.

---

## Phase 9: Compuertas (el operador decide cada una)

**Ninguna de estas tareas se ejecuta sola.** Cada una pide su confirmación explícita antes de correr.

- [ ] T073 **COMPUERTA** Commit(s) local(es): staging archivo por archivo (nunca `git add -A`; `git add -f CLAUDE.md`), mensajes en ASCII, sin atribución automática. Propuesta de agrupación: (1) spec, plan y tasks de 040 con `.specify/feature.json`; (2) oráculo, fixtures, script y workflow; (3) CHANGELOG y CLAUDE.md.
- [ ] T074 **COMPUERTA** Push de la rama `040-nightly-red-alert` por HTTPS con el helper de `gh` (`git -c credential.helper='' -c credential.helper='!gh auth git-credential' push https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher.git 040-nightly-red-alert:040-nightly-red-alert`); sin `--force`. El token ya tiene el scope `workflow`.
- [ ] T075 **COMPUERTA** **E1 + medición M9 + M8 (SC-009; FR-016: primera evidencia real, y FR-010: el primer fallo identificable de la corrida es el paso simulado, no el aviso)**: `gh workflow run docker-e2e.yml --ref 040-nightly-red-alert -f alert_trial=true -f trial_outcome=red`. Esperado: issue `[ensayo] docker-e2e nightly en rojo` creado, etiqueta `nightly-red-trial`, asignado al mantenedor, `total=1`; job `e2e` en rojo y job `alert` en verde. **El mantenedor confirma que le llegó la notificación sin abrir Issues ni Actions.** Si el token no puede crear etiquetas o issues (política de la organización, M9) o la notificación no llega (M8), **se detiene la secuencia y se vuelve al operador**: cambia el diseño (permiso de la organización o volver a `/speckit-clarify`). Bajar los logs con `--allow-escape-sequences`. Anotar id de corrida, número de issue y conclusiones.
- [ ] T076 **COMPUERTA** **E2**: ensayo `red` otra vez. Esperado: el mismo issue, `total=2`, un comentario nuevo y ningún issue nuevo (FR-005, SC-002).
- [ ] T077 **COMPUERTA** **E3**: el mantenedor cierra a mano el issue de ensayo y se lanza ensayo `red`. Esperado: el mismo issue se reabre con comentario y `total=3` (FR-008).
- [ ] T078 **COMPUERTA** **E4**: ensayo `green`. Esperado: marcador `resolved`, comentario de cierre, issue cerrado y corrida completa en verde (FR-006, SC-003).
- [ ] T079 **COMPUERTA** **E5**: ensayo `red`. Esperado: un issue **nuevo** (otra racha) y el anterior sigue cerrado (FR-008).
- [ ] T080 **COMPUERTA** **E6**: ensayo `green`. Esperado: el issue nuevo se cierra.
- [ ] T081 **COMPUERTA** **E7 (medición M7)**: ensayo `timeout`. Registrar con qué valor entrega la plataforma `needs.e2e.result` (la primera anotación `::notice::` del log de `notify` lo muestra), la conclusión del job `e2e` y qué hizo el script; decide la regla de research R7. Comprobar además si el paso `collect` (`always()`) alcanza a correr después del tiempo agotado y si las salidas del job `e2e` llegan al job `alert` (la regla de R7 necesitaría la hora de inicio como salida; si el tiempo agotado mata el job antes de producir salidas, esa regla no llegaría).
- [ ] T082 Condicional a T081, **solo si la plataforma reportó el tiempo agotado como `cancelled`**: escribir primero el test en ROJO (cancelación con el job `e2e` cerca de su tope cuenta como rojo; el resto sigue sin acción), implementar la regla en `notify`, **enmendar FR-007** (spec: FR-007 y el borde "Tiempo agotado frente a cancelación"; `data-model.md` clase `none`; `alert-script.md`; el caso N07, que pasa a distinguir la cancelación por tiempo agotado) y, si el tiempo transcurrido exige `actions: read`, **enmendar también FR-013**; todo dicho en spec, plan y Notes antes de usarlo. La repetición de T081 es una **COMPUERTA** y, como cambia el script o el workflow, obliga a repetir E1 a E6 o a justificar por escrito que el cambio no toca esos caminos. Si fue `failure`, marcar esta tarea como no aplicable con la evidencia.
- [ ] T083 **COMPUERTA** **E8**: corrida manual **normal** sobre la rama (`gh workflow run docker-e2e.yml --ref 040-nightly-red-alert`, unos 15 minutos). Esperado: 48 de 48 en verde, `e2e summary: total=48 executed=48 skipped=0 failed=0`, el job `alert` omitido, las salidas de `collect` presentes, ningún cambio en ningún issue y una duración dentro del +1 minuto sobre los ~15 medidos (FR-011, SC-008).
- [ ] T084 Registrar en las Notes de este archivo la clasificación y los identificadores reales (ids de corrida, números de issue, conclusiones por job, la confirmación humana de la notificación y el valor de M7), actualizar CHANGELOG y CLAUDE.md con los resultados reales, cerrar cualquier issue de ensayo que quede abierto (**COMPUERTA**: es una acción sobre GitHub) y dejar la etiqueta `nightly-red-trial` (SC-006). **La evidencia vale para el texto que se mergea**: anotar el commit con el que se lanzó E1 y exigir que `git diff <ese commit>..HEAD -- .github/workflows/docker-e2e.yml .github/scripts/nightly-alert.sh` salga vacío; si no, repetir E1 a E6 o justificar por escrito que el cambio no toca esos caminos. Cada commit de esta tarea es una **COMPUERTA** aparte.
- [ ] T085 **COMPUERTA** PR contra `main` con un cuerpo que incluya la tabla de gates (T069 y T070), las mutaciones (T064), la evidencia real (T075 a T083) y lo que el aviso no cubre; la CI del PR repite la matriz (bats en ubuntu con bash 5.x, en macOS con bash 3.2, y `shellcheck`) y debe dar 1849 ok en ambos brazos. Si algún brazo falla, leer el log antes de nombrar la causa y consultar antes de empujar de nuevo.
- [ ] T086 **COMPUERTA** Merge por el operador. Después, limpieza local solo con su confirmación (ramas mergeadas).
- [ ] T087 **COMPUERTA** (posterior al merge, como T049 de 039) Registrar el resultado del job `alert` en la **primera nocturna programada posterior al merge**: en una noche verde el job debe terminar en éxito sin crear ni cambiar ningún issue (`gh issue list --label nightly-red --state all` igual que antes); anotar el id de la corrida y, si la noche fue roja, el aviso real que produjo. Es la única prueba en vivo de la rama `schedule` de la condición. Confirmar además que la corrida programada **arrancó** y terminó bien: la expresión de `timeout-minutes` debe evaluar a 30 sin que `inputs` esté definido, un supuesto que ninguna corrida manual ejerce; si la corrida no arrancó o falló por el workflow, revertir el PR y consultar al operador.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (1)**: sin dependencias; T001 es independiente (copia aislada) y puede correr mientras se escribe, pero no junto a otro gate.
- **Foundational (2)**: depende de Setup y **bloquea** todas las historias. T003, T004 y T005 son archivos distintos ([P]); T006 depende de T005; T007 cierra la fase.
- **US1 (3) → US2 (4) → US3 (5) → US4 (6)**: el orden es de **dependencia sobre los mismos archivos** (el script y el workflow), no solo de prioridad. US2 necesita el script de US1; US3 y US4 extienden el mismo script y, US4, el workflow.
- **Mutaciones (7)**: requieren las cuatro historias en verde.
- **Polish y gates locales (8)**: requieren las mutaciones cerradas.
- **Compuertas (9)**: requieren Polish; cada una pide confirmación; T075 a T083 requieren T074.

### Dependencias dentro de una historia

- Los tests de la historia se escriben y se ven en ROJO **antes** de su implementación (T011, T018, T027, T038).
- En el script: T012 → T013 → T014 → T019 → T028 → T029 → T030 → T031 → T032 → T039 → T040 → T041, todas sobre el mismo archivo (sin `[P]`).
- En el workflow: T020 → T042 (mismo archivo).
- En el archivo de tests: todas las tareas de escritura de tests comparten `tests/nightly-alert.bats` (sin `[P]`).

### Oportunidades de paralelismo

```text
Fundación:    T003, T004, T005 (tres archivos de fixtures distintos) y T001 (copia aislada, fuera del árbol)
Polish:       T065 (CHANGELOG.md) y T066 (CLAUDE.md)
Todo lo demás es secuencial por compartir archivo o por ser un gate dual.
```

---

## Implementation Strategy

### MVP primero (US1 y US2, los dos P1)

1. Setup y Fundación (T001 a T007).
2. US1 (T008 a T015): el aviso y su contenido, con el `gh` falso.
3. US2 (T016 a T021): a prueba de fallas y cableado del workflow con permisos mínimos. **Detenerse y validar**: sin US2 el aviso podría volver roja una noche verde, peor que no tener aviso.
4. La validación real del MVP es E1 y E2 (compuertas).

### Entrega incremental

1. US3 (T022 a T033): racha, cierre por verde, cierre manual, manuales, canceladas, ensayo aislado.
2. US4 (T034 a T043) y mutaciones (T044 a T064): el oráculo queda protegido.
3. Polish (T065 a T072), después las compuertas (T073 a T087).

### Una sola persona

Una sola persona hace todo en este orden; las compuertas son del operador. Las 20 mutaciones son secuenciales por tocar copias del mismo script y del mismo workflow.

---

## Notes

- [P] = archivos distintos y sin dependencia incompleta; no hay otra forma de paralelismo en esta feature.
- Mapa de historias: las pruebas estructurales del workflow N27, N28, N30 y N31 van en US2 (no en US4) porque T020 introduce las entradas de `workflow_dispatch`, el cableado de `collect` y la referencia al script; solo N29 (la mecánica del ensayo) queda en US4.
- Análisis del 12-10-2026 (`/speckit-analyze`): 0 críticos, 3 HIGH (I1 racha cerrada a mano que un verde no resuelve, I2 T082 frente a FR-007, U1 N17 vacío), 4 MEDIUM (U2, U3, A1, I3) y 8 LOW, todos remediados en spec, plan, contratos y tasks el mismo día con la aprobación del operador; conteos intactos (32 tests, 20 mutaciones, 87 tareas, 1849).
- Cada historia debe poder demostrarse sola contra el `gh` falso antes de pasar a la siguiente.
- Verificar que los tests fallan antes de implementar; un test que nace verde se anota y su capacidad de fallar se demuestra con su mutación.
- Los conteos esperados: 32 tests nuevos (N00 a N31) y 1849 en total (1817 de la línea base de `main` más los nuevos); 20 mutaciones.
- A completar durante la implementación, con fecha: línea base (T001), prerrequisitos (T002), evidencia ROJO de cada historia (T011, T018, T027, T038), GREEN de cada historia (T015, T021, T033, T043), tabla de mutaciones (T064), gates (T069 a T072), y desde T075 los ids de corrida, números de issue, conclusiones por job, la confirmación humana de la notificación, el valor de M7 y el resultado del job `alert` en la primera nocturna posterior al merge (T087).

### Registro de la implementación (13-10-2026)

Orden real de trabajo: mientras corría la línea base T001 (que no admite otro `bats`) se escribieron, sin ejecutarlos, el `gh` falso, los fixtures y los **32 tests de las cuatro historias** (`bats --count` = 32); ningún test se ejecutó hasta que terminó T001. El script y la edición del workflow NO existían a propósito: el ROJO de cada historia se capturó con el script ausente (US1) o con la implementación de la historia anterior (US2 a US4), y el script se escribió por etapas, una historia a la vez.

- **T001, línea base** (copia aislada de `main`@`13cafc3` en el scratchpad, secuencial, sin otra corrida de `bats`; el Mac tenía carga de unos 12 a 17 por apps del usuario): bash 5.3.15 con bats 1.13.0: **1817 ok, 0 not ok, 54 saltados (1763 ejecutados), rc 0, 23 min 11 s** (03:24:28Z a 03:47:39Z, 13-10-2026). bash 3.2.57 (`PATH=/bin:$PATH`): **1817 ok, 0 not ok, 55 saltados (1762 ejecutados), rc 0, 22 min 11 s** (03:47:39Z a 04:09:50Z); `stderr` vacío en ambos. El salto extra de 3.2 es el esperado `qmd_watch fires exactly one reindex via the debounce-quiet (timeout) path` (`read -t` devuelve 1 y no >128 en bash 3.2), el único que difiere entre los dos conjuntos de saltados.
- **T002, prerrequisitos**: `bats` 1.13.0, `yq` v4.52.5, `jq` 1.7.1-apple, `perl`, `shellcheck` 0.11.0 y `gh` 2.102.0 presentes; `git fetch origin` deja `origin/main` en `13cafc3` con `VERSION` 0.28.0, igual que el árbol local; `.specify/feature.json` apunta a `specs/040-nightly-red-alert`; los `--help` de `gh issue list|create|comment|edit|reopen|close` y de `gh label create` muestran las 15 banderas de research R8 (la comprobación se hizo con argumentos explícitos: una primera pasada con `$sub` sin comillas en zsh reportó falsos FALTA, el mismo tropiezo ya anotado en la memoria).
- **T003 y T004, fixtures**: `steps-green.json`, `steps-suite-red.json`, `steps-verify-red.json`, `steps-cancelled.json`, `steps-invalid.txt`, `tap-25-failures.tap` (`1..30`, 5 ok y 25 `not ok`) y `tap-long-names.tap` (nombres de 300 caracteres). **Desviación respecto de T004: `tap-hostile.tap` no se versiona.** El TAP con comillas invertidas, `~~~`, `<!--`, `-->`, `@usuario`, `#12` y caracteres de control se genera con `printf` dentro de N15 y N20, porque un fixture con bytes de control haría fallar el escaneo de bytes de T068 (0 bytes de control en los archivos tocados) y obligaría a una excepción. Los TAP de `tests/fixtures/ci/` se reutilizaron sin copiarlos.
- **T005 y T006, instrumento**: el `gh` falso (`tests/fixtures/nightly-alert/gh`, bash 3.2, solo ASCII, `shellcheck -S warning` limpio) exige además `GH_TOKEN` y `GH_REPO` (exit 4), como el `gh` real en Actions, y **el script nunca pasa `--repo`**. `tests/nightly-alert.bats` carga `helper`, usa `env -i` (el script recibe solo lo que el job le pasa), fija SIGPIPE con una única definición `SIGPIPE_PERL` que comparten el arnés y la sonda de N17, y un `_gho_parse` que reproduce el parser de `GITHUB_OUTPUT` del runner (`=` o `<<` según cuál aparezca primero) para que N18 a N20 afirmen sobre las salidas realmente parseadas.
- **T007, N00 y su calibración**: N00 en verde en bash 5.3.15 y en 3.2.57. Su capacidad de fallar se demostró **rompiendo el falso dos veces** y restaurándolo con `cmp` byte a byte: (1) aceptando `--jq` en `issue list`, N00 cae en la línea `run -64 _fake issue list ... --jq` con "expected exit code 64, got 0"; (2) dejando de exigir `FAKE_GH_STATE`, cae en `run -99 env -i ...` con "expected exit code 99, got 0".
- **T011, ROJO de US1** (script ausente): `bats -f '^N(00|01|02|18|19|20) '` en bash 5.3.15 y en 3.2.57: N00 `ok` y N01, N02, N18, N19 y N20 `not ok`, los cinco con el mensaje de la guardia de no-vacuidad 2 del contrato ("the script under test does not exist: .../.github/scripts/nightly-alert.sh").
- **T012 a T015, GREEN de US1**: el script creado en su forma mínima de la historia (despacho, `say_notice`/`warn`, `mktemp -d` con `trap EXIT`, `collect` completo sin cotas, `notify` solo en el camino rojo-nuevo, saneo solo de caracteres de control). N00, N01, N02 y N18 a N20 en verde en bash 5.3.15 y en 3.2.57 (`1..6`, 6 ok); `shellcheck -S error -e SC1090,SC1091` rc 0 (también limpio a nivel `warning`). Una corrida manual del script contra el `gh` falso produjo el cuerpo esperado y las tres llamadas `list`, `label-create`, `create`.
- **T018, ROJO de US2** (script de US1 presente; workflow sin tocar): `bats -f '^N(12|23|24|25|26|27|28|30|31) '` en bash 5.3.15: N12, N23, N24, N25, N26, N28, N30 y N31 `not ok`; **N27 nace verde**, como estaba previsto (es un ratchet: cuenta `secrets.` en un workflow que hoy no tiene ninguna; su cazador es la variante (b) de M2). N12 caía en la pierna `create_assignee` (línea 544, no existía el reintento sin asignado); N25 cae en su guardia de presencia del job `alert`.
- **T019 a T021, GREEN de US2**: manejo de fallas en el script (`create_notice` con el reintento sin `--assignee` y la advertencia "el aviso se creo sin asignado", `ensure_label` que solo avisa con `::notice::` si la etiqueta no se pudo crear, porque un error ahí se vuelve a ver en la llamada siguiente) y edición del workflow: ids `checkout`, `install_yq`, `install_bats`, `verify_deps`, `run_suite`; paso final `collect` (`if: ${{ always() }}`); `outputs` del job; entradas `alert_trial` y `trial_outcome`; job `alert` completo. `git diff` del workflow: **75 inserciones y 0 borrados**; el `run:` de `Verify deps + docker` y el de `Run docker-e2e suite` tienen el mismo sha256 que en `HEAD`. N23, N24, N25, N26, N27, N28, N30 y N31 en verde en bash 5.3.15 y en 3.2.57, y **los 14 tests de `tests/ci-workflows.bats` (O1 a O5, S1 a S6, R1 a R3) siguen verdes en ambos sin editarse** (`git diff -- tests/ci-workflows.bats` vacío; R3 ya barre los pasos nuevos). Dos hallazgos de implementación: (1) **desviación de checkpoint de N12**: sus piernas que hacen fallar `edit`, `comment`, `reopen` y `close` ejercen flujos que solo existen con US3, así que N12 completo queda verde en T033; al cierre de US2 pasan sus piernas `list`, `label`, `create` y `create_assignee` y el test se detiene en la pierna `edit` (línea 556, "no hay `::warning::` porque todavía no se intenta el `edit`"); (2) **el paso `collect` también lleva `continue-on-error: true`** (no estaba en el contrato): el script sale siempre 0, pero un paso que ni siquiera arranca (por ejemplo, un bit ejecutable perdido en el commit) volvería roja una noche verde, que es justo lo que FR-009 prohíbe; N30 ahora lo exige y T045 gana una mutación propia fuera de la tabla (quitar ese `continue-on-error`).
- **T027, ROJO de US3** (script con solo el camino rojo-nuevo y el manejo de fallas de US2): `bats -f '^N(03|04|05|06|07|08|09|10|11|13|16) '` en bash 5.3.15: **los 11 `not ok`**. Cada uno cae donde debía: N03 y N04 (el script crea un issue en vez de actualizar), N05 a N08 y N11 (sin decisión de modo ni de clase: una verde, una cancelada o una manual también creaban), N09 (sin reapertura), N10 (cae en la pierna (b): el verde sobre un aviso cerrado a mano no escribe nada), N13 (la segunda corrida repite) y N16 (sin advertencia de marcador). La pierna (a) de N10 que había entonces, con un aviso cerrado sembrado, **nació verde** porque "siempre crea" la satisface; se reescribió después de esta captura como el ciclo completo por el propio script (rojo, verde, rojo), cuyo cazador es M12(a).
- **T028 a T033, GREEN de US3**: el script gana la decisión de modo y clase (`schedule` es `real`; `workflow_dispatch` con `TRIAL=true` es `trial`; el resto, `ninguno`; `success` es verde, `failure` rojo, lo demás ni uno ni otro y se anota el valor), la tabla de decisión completa (crea, actualiza, reabre, cierra y el caso de solo-marcador del verde sobre un aviso cerrado a mano), la lectura del marcador con la expresión de NF y la identidad por modo (etiqueta, color, descripción y título del ensayo). Las filas viejas solo se arrastran si tienen exactamente la forma que el script escribe. `label create` se llama solo cuando no hay aviso previo. N03 a N11, **N12 completo**, N13 y N16 en verde y, con ellos, los 26 tests de las tres historias, en bash 5.3.15 y en 3.2.57 (`1..26`, 26 ok); `shellcheck -S error -e SC1090,SC1091` rc 0 y limpio también a nivel `warning`. Decisión de diseño que el contrato no fijaba: un verde sobre un aviso abierto cuyo marcador no parsea lo cierra con un comentario y no reescribe el cuerpo (se avisa con `::warning::`); los cuerpos con marcador inválido no tienen fila contra la cual comparar, así que reejecutar ese job puede repetir el comentario de la noche (limitación ya anotada en `alert-script.md`). Aún sin cota de filas (10) ni saneo completo ni `simulate`: son de US4.
- **T038, ROJO de US4** (script con la historia 3 y sin cotas, saneo completo ni `simulate`; workflow sin el `if` de ensayo, sin el paso `simulate` ni el literal del tope): `bats -f '^N(14|15|17|21|22|29) '` en bash 5.3.15: **N14, N15, N21 y N29 `not ok`** (N14 sin la cota de 20 nombres; N15 con bytes de control y no ASCII en el cuerpo; N21 con `simulate` desconocido, sale 2 y no 1; N29 sin el `if` de `run_suite`). **N17 y N22 nacen verdes, como estaba previsto**: son guardas, y su capacidad de fallar se demuestra con las dos variantes de M19 (T062). La captura encontró un defecto del arnés: `_alert simulate red` pasaba `red` a `env` como si fuera un comando (aviso BW01 de bats, código 127); `_alert` ahora separa los argumentos `VAR=valor`, que van al entorno, de los demás, que van al script tras el subcomando, y se volvieron a correr los 26 tests de US1 a US3 (26 ok) antes de recapturar el rojo.
- **T039 a T043, GREEN de US4 y del oráculo completo**: `limit_names` (hasta 20 nombres, cada uno saneado y cortado a 120 caracteres con `...`, y la línea `... y N mas` con el resto; la comparten `collect` y `notify`, que reconoce la línea que `collect` ya dejó), 10 filas de detalle (la noche nueva más las 9 más recientes de antes), `san` completo (control fuera, no ASCII a `?`, comillas invertidas y virgulillas a apóstrofos, `<!--` y `-->` neutralizados en un ciclo hasta que no quede ninguno, corte a 120), el paso fallido restringido a `[A-Za-z0-9_-]`, el encabezado `Tests que fallaron (N)` con el total real (nombres más resto) y `simulate red|green|timeout` (sale 1, 0 o duerme `TRIAL_TIMEOUT_SLEEP`, 120 s por defecto; desconocido sale 2). Workflow: `if: ${{ !inputs.alert_trial }}` en `run_suite` (su `run:` y su `env` intactos), paso `simulate` entre la suite y `collect`, y `timeout-minutes: ${{ (inputs.alert_trial && inputs.trial_outcome == 'timeout') && 1 || 30 }}`. **Los 32 tests (N00 a N31) en verde: bash 5.3.15 (32 ok), bash 3.2.57 (32 ok) y con el propio proceso de bats bajo SIGPIPE ignorada, en ambos (32 ok cada uno)**; `shellcheck -S error -e SC1090,SC1091` rc 0, limpio también a nivel `warning`. El tope de 60.000 caracteres del cuerpo (NF sección 5) **no tiene rama de recorte**: el cuerpo está acotado por construcción (10 filas de unos 120 caracteres, 20 nombres de 120, texto fijo), así que una rama que nunca se ejecuta no se escribió; N14 afirma `< 60000` y además `< 8000`, que es lo que sí puede romperse. El tope de 20 nombres y el de 10 filas se ejercen con 25 fallos y una racha de 155 noches (N14).

### Tabla de mutaciones (T044 a T064, 13-10-2026)

Cada mutación se aplicó a una **copia** del script o del workflow (`ALERT_SCRIPT` o `ALERT_WORKFLOW` apuntando a ella; el árbol de trabajo no se tocó), se corrió el archivo completo (32 tests) en bash 5.3.15 y después en 3.2.57, secuencial, y se anotó qué tests cayeron. "Cazador" es el test que la tabla de `quickstart.md` nombra; "además" son otros tests que también cayeron. Resultado: **las 20 mutaciones (22 variantes, porque M2, M12 y M19 tienen dos) cayeron en el test previsto, en los dos bash; 0 sobrevivientes.** Al terminar, `cmp` confirma que el script, el workflow, `tests/nightly-alert.bats`, el `gh` falso y `tests/ci-workflows.bats` son idénticos a la copia tomada antes de empezar.

| Id | Mutación | Cazador | Cayó en bash 5.x y en 3.2.57 (idéntico) | Además |
|---|---|---|---|---|
| M1 | quitar `always()` del `if` del job `alert` | N23 | N23 | ninguno |
| M2a | `issues: write` al nivel del workflow | N25 | N25 | ninguno |
| M2b | una referencia a `secrets.TOKEN` | N27 | N27 | ninguno (prueba que el ratchet puede fallar) |
| M3 | quitar `continue-on-error` del paso que publica | N26 | N26 | ninguno |
| M4 | `notify` sale con el código del último `gh` fallido | N12 | N12 | ninguno |
| M5 | crear el aviso sin `--assignee` | N01 | N01 | N12 |
| M6 | tratar `cancelled` como rojo | N07 | N07 | ninguno |
| M7 | una corrida manual normal abre el aviso | N08 | N08 | N11 |
| M8 | un rojo repetido crea un segundo issue | N03, N04 | N03 N04 | N11 N12 N14 N16 |
| M9 | en verde no se cierra el aviso | N05 | N05 | N10 N11 N12 N13 N16 |
| M10 | en verde sin aviso previo se crea uno | N06 | N06 | ninguno |
| M11 | cierre manual: crea uno nuevo en vez de reabrir | N09 | N09 | N12 N16 |
| M12a | cerrar por verde escribiendo `state=open` | N10 | N10 | N05 N13 |
| M12b | un verde sobre un aviso cerrado a mano no reescribe el marcador | N10 | N10 | ninguno |
| M13 | quitar la cota de 20 nombres | N14 | N14 | ninguno |
| M14 | no sanear comillas invertidas ni `~~~` | N15 | N15 | ninguno |
| M15 | `collect` cuenta `executed` igual que `total` | N19 | N19 | ninguno |
| M16 | quitar la guarda de idempotencia (`[run <id>](`) | N13 | N13 | ninguno |
| M17 | el ensayo usa la etiqueta del aviso real | N11 | N11 | ninguno |
| M18 | `run_suite` pierde su `if` de ensayo | N29 | N29 | ninguno |
| M19a | `\| head -1` en el script | N22 | N22 | ninguno |
| M19b | un pipe que lee una línea y cierra con un productor externo (`yes`) | N17 | N17 | ninguno |
| M20 | cambiar el literal de `timeout-minutes` | N29 | N29 | ninguno |
| M21 (extra, fuera de la tabla) | quitar `continue-on-error` del paso `collect` | N30 | N30 | ninguno |
| M22 (extra) | quitar el filtro de la URL de la corrida | N15 | N15 | ninguno |
| M23 (extra) | quitar la normalización CRLF del cuerpo leído | N03 | N03 | ninguno |
| M24 (extra, revisión) | `RUN_RESULT: ${{ job.status }}` en vez de `needs.e2e.result` | N26 | N26 | ninguno |
| M25 (extra, revisión) | `ASSIGNEE` vacío | N26 | N26 | ninguno |
| M26 (extra, revisión) | typo en la salida `failed_tests` que lee el job `alert` | N26 | N26 | ninguno |
| M27 (extra, revisión) | quitar `continue-on-error` del `Checkout` del job `alert` | N26 | N26 | ninguno |
| M28 (extra, revisión) | quitar el `timeout-minutes: 3` del paso que publica | N26 | N26 | ninguno |
| M29 (extra, revisión) | `notify` deja de reconocer la línea `... y N mas` de `collect` | N14 | N14 | ninguno |
| M30 (extra, revisión) | leer el total del marcador sin pasarlo a decimal (`08`) | N03 | N03 | ninguno |
| M31 (extra, revisión) | cerrar el aviso aunque falle la reescritura del marcador | N12 | N12 | ninguno |
| M33 (extra, revisión; M32 queda sin usar) | una llamada a `gh` que el `gh` real rechazaría | N03 | N03 N04 N09 N11 N12 N14 N16 N17 | los demás de la lista |

Hallazgo de las mutaciones (M19b): la primera versión de M19b usaba el `printf` interno de bash (`printf '%070000d\n%070000d\n' 0 0 | { read -r _first; }`) y **sobrevivió en bash 3.2.57** aunque cayó en 5.3.15. No era una debilidad de N17, que detecta cualquier diferencia visible entre las dos disposiciones de SIGPIPE: el `printf` interno de bash 3.2 no informa los errores de escritura, así que con SIGPIPE ignorada calla igual que cuando el proceso muere de la señal, y el comportamiento es equivalente (un mutante equivalente en 3.2). La variante vigente de M19b usa un productor **externo** (`yes | { read -r _first; }`), cuyo error de escritura con SIGPIPE ignorada (`Broken pipe` por `stderr`) es visible en los dos bash, y cae en N17 en ambos. La variante con `printf` se conserva como M19c, informativa: cae en 5.x y es equivalente en 3.2.

### Revisión independiente (13-10-2026)

Antes del gate completo se pidió una revisión independiente de solo lectura (agente `code-reviewer`, unos 25 minutos y 53 llamadas a herramientas; ejecutó el script real contra el `gh` falso en bash 3.2.57 y 5.3.15, sin tocar el repositorio ni correr `bats`). Resultado: **0 ALTA, 4 MEDIA, 5 BAJA y 4 puntos no verificables sin corrida real.** La decisión por hallazgo, con el ROJO visto antes del arreglo cuando era un defecto del código (los huecos del oráculo que el código correcto ya satisfacía nacen verdes y se demuestran con su mutación):

| Hallazgo | Decisión | Evidencia |
|---|---|---|
| M1: ningún test protege los valores de `env` del paso que publica (el aviso podía quedar mudo con todo en verde) | arreglado: N26 compara el valor exacto de las 12 variables y que no haya otra | nace verde (el workflow ya era correcto); cazadores M24 (`job.status`), M25 (`ASSIGNEE` vacío) y M26 (typo de la salida) |
| M2: FR-009 no cubre el `Checkout` del job `alert` ni su tope de 5 minutos | arreglado: `Checkout` con `continue-on-error: true` y el paso que publica con `timeout-minutes: 3` (un `gh` colgado termina como paso fallido, que se absorbe, y no como job agotado); N26 lo afirma | ROJO visto en N26 (faltaba el tope); cazadores M27 y M28 |
| M3: un cuerpo con CRLF invalida el marcador | ya arreglado antes del informe (lo hallé al razonar sobre el editor web; el informe lo confirmó ejecutándolo contra el script anterior): se quitan los `\r` del cuerpo leído | N03 con un cuerpo convertido a CRLF; cazador M23 |
| M4: la rama `... y N mas` de `limit_names` no la ejercía ningún test de `notify` | arreglado: N14(d) alimenta `notify` con lo que `collect` produce para 25 fallos | nace verde (el código ya la tenía); cazador M29 |
| B1: `total=08` mata el script con rc 1 (octal inválido) | arreglado: el total tiene a lo sumo 9 dígitos y se lee con `10#` | ROJO visto en N03 (`total=08`); cazador M30 |
| B2: `do_close` no es atómico | (a) arreglado: si el `edit` del marcador falla no se comenta ni se cierra y la noche verde siguiente rehace todo; (b) `close` fallido tras `edit` y comentario correctos: limitación declarada en `alert-script.md` | ROJO visto en N12 (cerraba igual); cazador M31 |
| B3: `RUN_ID` vacío colisiona consigo mismo | **no se cambia**: `github.run_id` siempre existe, así que no se alcanza desde el workflow; no vale una rama de código ni su mutación (M32 queda sin usar) | ninguna |
| B4: la lista blanca del `gh` falso no hace fallar ningún test por sí sola | arreglado: el arnés falla el test si el falso registró `UNSUPPORTED` | cazador M33 |
| B5: las notas que una persona escriba en el cuerpo se pierden la noche siguiente | arreglado como texto: "El cuerpo se regenera cada noche: deja tus notas como comentarios" | ninguna |
| No verificable 1: orden e índice de búsqueda de `gh issue list --label` | **medido** (solo lectura): con `--label`, `gh` 2.102.0 usa la API de búsqueda (consulta GraphQL `IssueSearch`, `last: $limit`, sin `sort:`) y en un repositorio público real (`cli/cli`, etiqueta `bug`, todos los estados) `--limit 1` devolvió el issue **más nuevo** (#14649, 12-10-2026) y `--limit 100` vino en orden descendente; el orden queda medido. No se mide el posible retraso del índice (afectaría a un re-run inmediato del job `alert`) | consulta de solo lectura del 13-10-2026; además `gh issue list --label <inexistente>` devuelve `[]` con rc 0 en el repositorio real |
| No verificable 2: cómo reporta la plataforma un tiempo agotado | E7 (T081); se agrega a T081 comprobar también si `collect` (`always()`) alcanza a correr tras el timeout y si las salidas del job llegan | T081 |
| No verificable 3: asignado y notificación con `GITHUB_TOKEN` | E1 (M8, M9) | T075 |
| No verificable 4: orden de claves de `toJSON(steps)` | solo importa si fallan dos pasos; E1 y E7 lo muestran | T075, T081 |

Las mutaciones extras (M21 a M31 y M33, 12 en total, fuera de las 20 de la tabla) cayeron todas en su test previsto en los dos bash.

### Cierre local (T065 a T072, 13-10-2026)

- **T065 y T066, documentos**: entrada de `CHANGELOG.md` (sin bump de `VERSION`) que dice qué cubre el aviso y qué no (FR-018: un nightly que no arranca, la rama `schedule` de la condición, el complemento de las notificaciones nativas, el texto del log en ASCII; la evidencia real queda declarada como pendiente); entrada de 040 en el bloque SPECKIT de `CLAUDE.md` al estado implementado y dos viñetas nuevas en "Common gotchas" (el `printf` interno de bash es silencioso en 3.2 y habla en 5.x ante SIGPIPE ignorada; un paso que reporta no puede poder fallar la corrida aunque el script salga siempre 0, y `git ls-files -s` debe mostrar `100755` antes de empujar un workflow que ejecuta un script directo). Los contratos (`alert-workflow`, `alert-script`, `notice-format`, `alert-oracle`) y el quickstart se alinearon con lo construido.
- **T067, VERSION**: `git fetch origin` y `git show origin/main:VERSION` dan 0.28.0, igual que el árbol local; sin bump (precedente 019, 025 y 039).
- **T068, escaneo de bytes** (UTF-8 válido, 0 marcas combinantes, 0 bytes de control, NFC) sobre todos los archivos nuevos o tocados: todos limpios; el script, el `gh` falso, los fixtures y `tests/nightly-alert.bats` son solo ASCII; el workflow conserva sus 3 bytes no ASCII de siempre (un guion largo de un comentario previo: 3 en `HEAD` y 3 ahora).
- **T069, gate completo sobre el árbol final** (después de la revisión independiente y de todos los arreglos; secuencial, sin otra corrida de `bats`): bash 5.3.15 con bats 1.13.0: **1849 ok, 0 not ok, 54 saltados, rc 0, 20 min 9 s** (05:33:14Z a 05:53:23Z); bash 3.2.57: **1849 ok, 0 not ok, 55 saltados, rc 0, 20 min 12 s** (05:53:23Z a 06:13:35Z); `stderr` vacío en ambos. 1849 = 1817 de la línea base más los 32 tests nuevos; los saltados son los mismos 54 y 55 de la línea base (el extra de 3.2 es el `qmd_watch` por `read -t`), o sea que ningún test nuevo salta. Una primera pasada de este gate se interrumpió a propósito a los 10 minutos al descubrir un defecto (el CRLF del editor web) y se relanzó completa tras los arreglos; no se mezclan resultados de las dos.
- **T070, shellcheck**: el comando exacto del job de CI (`find` con `-not -path './tests/*'` más `./scripts/agentctl` y `./docker/scripts/heartbeatctl`, a `xargs shellcheck -S error -e SC1090,SC1091`) da rc 0 sobre 51 archivos y la lista incluye `./.github/scripts/nightly-alert.sh`; el script también está limpio a nivel `warning`.
- **T071, alcance y secretos**: `git diff origin/main -- docker scripts modules setup.sh | wc -l` da 0; `grep -c 'secrets\.' .github/workflows/docker-e2e.yml` da 0; `git diff origin/main -- tests/ci-workflows.bats` está vacío; el único permiso nuevo es `issues: write` en el job `alert`. El diff del workflow es de 97 inserciones y 1 borrado (`timeout-minutes: 30`, que pasa a la expresión del ensayo); el `run:` de `Verify deps + docker` y el de `Run docker-e2e suite` tienen el mismo sha256 que en `HEAD`.
- **T072, validación local de `quickstart.md` sección 2**: 2.1 el rojo se vio antes de existir el script (T011) y antes de cada historia; 2.2 el oráculo en verde en bash 5.3.15, en 3.2.57 y con el proceso de bats bajo SIGPIPE ignorada en ambos (32 ok en cada una de las cuatro pasadas); 2.3 el gate completo (T069); 2.4 shellcheck (T070); 2.5 alcance (T071). **Compatibilidad con la versión de `yq` de la CI**: el workflow `test.yml` instala `yq` v4.44.3 y el Mac tiene la v4.52.5, así que las expresiones de las pruebas estructurales (`sort_keys`, `test`, `sub`, cortes, `has`) se corrieron también con una v4.44.3 compilada desde el código (`go install github.com/mikefarah/yq/v4@v4.44.3`, con la verificación de la base de sumas del módulo): `tests/nightly-alert.bats` y `tests/ci-workflows.bats` dan 46 de 46 en bash 5.3.15 y en 3.2.57.
- **Mediciones de solo lectura contra GitHub real** (13-10-2026, `gh` 2.102.0): `gh issue list --label <etiqueta inexistente> --state all --limit 1 --json number,state,body,url` devuelve `[]` con rc 0 en el repositorio real, que hoy no tiene issues ni las etiquetas `nightly-red` y `nightly-red-trial` (solo las nueve por defecto), así que el primer rojo real pasa por la rama "sin aviso previo" y crea la etiqueta; con `--label`, `gh` usa la API de búsqueda (consulta GraphQL `IssueSearch`, `last: $limit`, sin `sort:`) y, en un repositorio público con muchos issues (`cli/cli`, etiqueta `bug`), `--limit 1` devolvió el más nuevo y `--limit 100` vino en orden descendente.

