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

- [ ] T001 [P] Medir la línea base en una copia aislada de `main`@`13cafc3` (por ejemplo `git worktree add` en el scratchpad): `bats tests/` en bash 5.x y después `PATH=/bin:$PATH bats tests/` en 3.2.57, secuencial y sin otra carga en el Mac. Esperado: **1817 ok y 0 not ok** en cada uno. Anotar conteos, saltos y duraciones en Notes. Conviene lanzarla primero y no ejecutar T007, T011 ni otro gate mientras corre (un rojo por contención se re-mide aislado antes de nombrarlo).
- [ ] T002 Verificar prerrequisitos y alcance en el árbol de trabajo: `bats`, `yq` v4, `jq`, `perl`, `shellcheck` y `gh` presentes; `git fetch origin` y `VERSION` 0.28.0 igual a `origin/main`; `.specify/feature.json` apunta a `specs/040-nightly-red-alert`; los `--help` de `gh issue list|create|comment|edit|reopen|close` y de `gh label create` siguen mostrando las banderas de research R8. Anotar en Notes.

---

## Phase 2: Foundational (bloquea todas las historias)

**Purpose**: el instrumento de medición del oráculo. Estas tareas pasan hoy y prueban que el oráculo puede fallar.

- [ ] T003 [P] Crear en `tests/fixtures/nightly-alert/` los ejemplos de `toJSON(steps)`: `steps-green.json`, `steps-suite-red.json` (`run_suite` con `outcome: failure`), `steps-verify-red.json` (`verify_deps` con `failure`; los pasos siguientes ausentes), `steps-cancelled.json` y `steps-invalid.txt` (texto que no es JSON). Forma: un objeto por id de paso con `outputs`, `outcome` y `conclusion`; los ids son los de `contracts/alert-workflow.md` sección 2 (`checkout`, `install_yq`, `install_bats`, `verify_deps`, `run_suite`, `simulate`).
- [ ] T004 [P] Crear en `tests/fixtures/nightly-alert/` los TAP: `tap-25-failures.tap` (25 `not ok` y algunos `ok`), `tap-long-names.tap` (nombres de más de 120 caracteres) y `tap-hostile.tap` (nombres con `@usuario`, `#12`, comillas invertidas, `~~~`, `<!--`, `-->` y un carácter de control). Los TAP de `tests/fixtures/ci/` (`tap-mixed`, `tap-failing`, `tap-all-skip`, `tap-empty`) se reutilizan sin copiarlos.
- [ ] T005 [P] Crear el `gh` falso `tests/fixtures/nightly-alert/gh` (bash, ejecutable) según `contracts/alert-oracle.md` sección 1: estado en `$FAKE_GH_STATE` (obligatoria: sin ella sale con 99) con `issues.json`, `labels.txt` y `calls.log`; **lista blanca de banderas** idéntica a research R8 (`issue list --label --state --limit --json`; `issue create --title --label --assignee --body-file`; `issue comment --body-file`; `issue edit --body-file`; `issue reopen --comment`; `issue close --reason --comment`; `label create --color --description`); cualquier otra bandera o subcomando sale con 64 y escribe `UNSUPPORTED` en `calls.log`; `issue list --json` filtra por etiqueta y estado, ordena por número descendente, aplica `--limit` y proyecta solo los campos pedidos, sin `--jq`; falla inyectable con `FAKE_GH_FAIL` (lista separada por comas de `list`, `label`, `create`, `create_assignee`, `edit`, `comment`, `reopen`, `close`); una línea por llamada en `calls.log` (`verbo<TAB>argumentos`).
- [ ] T006 Crear `tests/nightly-alert.bats` (FR-014: el oráculo ejecuta el texto real de la lógica de aviso contra un sustituto del servicio de issues de GitHub y cubre los nueve casos): cabecera con los contratos que cumple, `load helper`, `bats_require_minimum_version 1.5.0`, `setup`/`teardown` con directorio temporal y `FAKE_GH_STATE`, y los helpers copiados de `tests/ci-workflows.bats` con un comentario que apunta a su origen (`_has`, `_lacks`, extracción de un `run:` con `yq`) más los propios: `_seed_issue NUMERO ESTADO MARCADOR_ESTADO TOTAL [ETIQUETA]`, `_calls`, `_mutating_calls` (verbos `create`, `edit`, `comment`, `reopen`, `close`, `label-create`) y el arnés `_notify`/`_collect`, que ejecuta `"$BASH" .github/scripts/nightly-alert.sh <subcomando>` con el entorno por defecto de `data-model.md` sección 1 (`EVENT=schedule`, `RUN_RESULT=failure`, `FAILED_STEP=run_suite`, `SUMMARY`, `FAILED_TESTS`, `RUN_ID`, `RUN_ATTEMPT`, `RUN_URL`, `ASSIGNEE`, `GH_TOKEN`, `GH_REPO`), con el falso al frente del `PATH` con la disposición de SIGPIPE que pida `SIGPIPE_MODE` (`ignore` por defecto, que es la que el script hereda en el runner de GitHub, o `default`), fijada con `perl` justo antes de lanzarlo, con `NIGHTLY_ALERT_NOW` fijo por defecto (`1792497600`, `1792584000` y `1792670400` son el 20, 21 y 22-10-2026 a las 12:00 UTC) y con las rutas bajo prueba tomadas de `ALERT_SCRIPT` y `ALERT_WORKFLOW` (por defecto `.github/scripts/nightly-alert.sh` y `.github/workflows/docker-e2e.yml` del repositorio), de modo que cada mutación se aplique a una copia sin tocar el árbol. Reglas del archivo: bash 3.2 y 5.x (sin `mapfile`, arreglos asociativos ni `${v,,}`), nunca `productor | head` ni `| grep -q` sobre `$output`, negativos con `_lacks` o `run …; [ "$status" -ne 0 ]`, y ningún `[[ ]]` intermedio. Incluir **N00**: el falso llamado directo registra la llamada, rechaza una bandera desconocida y exige `FAKE_GH_STATE`. N00 es la **calibración del instrumento**: su capacidad de fallar se demuestra rompiendo el falso una vez (por ejemplo, haciendo que acepte cualquier bandera) y anotándolo en Notes.
- [ ] T007 Checkpoint de la fundación: `bats tests/nightly-alert.bats` deja N00 en verde en bash 5.x y en 3.2.57 (secuencial). Anotar en Notes.

**Checkpoint**: el instrumento funciona; las historias pueden empezar.

---

## Phase 3: User Story 1 - Una noche en rojo deja un aviso que se ve sin abrir Actions (Priority: P1) — MVP

**Goal**: ante una corrida programada en rojo, el aviso aparece con enlace, paso fallido, resumen y tests fallidos; `collect` entrega esos datos.

**Independent Test**: `bats tests/nightly-alert.bats` con N01, N02 y N18 a N20 en verde; la parte real se prueba en E1 (compuerta).

### Tests for User Story 1 (escribirlos primero y verlos fallar)

- [ ] T008 [US1] Escribir **N01** en `tests/nightly-alert.bats`: rojo nuevo (`EVENT=schedule`, `RUN_RESULT=failure`, sin issues) crea la etiqueta `nightly-red` y el issue con título `docker-e2e nightly en rojo`, etiqueta, asignado `ASSIGNEE` y cuerpo cuya primera línea es `<!-- nightly-red:v1 state=open total=1 first=YYYY-MM-DD -->` (la que corresponde a `NIGHTLY_ALERT_NOW=1792497600`: `2026-10-20`, y `20-10-2026` en el texto de la fila), con el enlace de la corrida, el paso fallido, la línea de resumen y los nombres de los tests dentro de un bloque `~~~text` (FR-001, FR-002, FR-019, SC-001).
- [ ] T009 [US1] Escribir **N02** en el mismo archivo: rojo sin resumen (`FAILED_STEP=verify_deps`, `SUMMARY` y `FAILED_TESTS` vacíos) deja un cuerpo con `no disponible` en el resumen y `ninguno informado` en los tests, y nombra el paso (US1, escenario 2).
- [ ] T010 [US1] Escribir **N18, N19 y N20** en el mismo archivo. N18: `collect` con los ejemplos de `toJSON(steps)` (suite roja, verificación roja, todo verde, `cancelled`, JSON inválido) entrega `failed_step` correcto o vacío. N19, **paridad**: extraer con `yq` el `run:` real del paso `Run docker-e2e suite` de `.github/workflows/docker-e2e.yml`, ejecutarlo con un `bats` falso que imprima cada TAP (`tap-mixed`, `tap-failing`, `tap-all-skip`, `tap-empty`) y exigir que el `summary` de `collect` sea idéntico a la cadena que sigue a `e2e summary: ` (R2). N20: nombres con caracteres especiales no rompen el formato de `GITHUB_OUTPUT` (delimitador aleatorio).
- [ ] T011 [US1] **Ver el ROJO** (FR-015: rojo antes de la implementación): `bats tests/nightly-alert.bats` deja N01, N02 y N18 a N20 en `not ok` con un mensaje que dice que el script no existe (guardia de no-vacuidad 2 de `alert-oracle.md`) y N00 en verde. Anotar la evidencia en Notes.

### Implementation for User Story 1

- [ ] T012 [US1] Crear `.github/scripts/nightly-alert.sh` (ejecutable, `#!/usr/bin/env bash`, solo ASCII): despacho de subcomandos (`collect`, `simulate`, `notify`; desconocido o ausente: uso en `stderr` y salida 2), funciones `say_notice` y `warn` que imprimen `::notice::nightly-alert: …` y `::warning::nightly-alert: …`, `mktemp -d` con `trap … EXIT`, y **sin `set -e`**. Reglas: bash 3.2 y 5.x, ningún pipe cuyo consumidor cierre antes que el productor, cargas por archivo.
- [ ] T013 [US1] Implementar `collect` en el script según `contracts/alert-script.md` sección 2: `failed_step` (primer id de `STEPS_JSON` con `outcome` `failure` o `cancelled`, vacío si ninguno o si no es JSON), `summary` con las tres cuentas del paso de la suite (`^(ok|not ok) [0-9]+`, `^ok [0-9]+ .*# skip`, `^not ok [0-9]+`; `executed = total - skipped`) y `failed_tests` con los nombres de `not ok N <nombre>`, uno por línea; salida a `$GITHUB_OUTPUT` (o a `stdout`), las de varias líneas con delimitador aleatorio. La cota de 20 nombres y de 120 caracteres se agrega en US4 con su RED. N18 a N20 en verde.
- [ ] T014 [US1] Implementar en `notify` el camino **rojo nuevo** (modo `real`, clase `red`, sin aviso previo): `gh issue list --label nightly-red --state all --limit 1 --json number,state,body,url`; `gh label create nightly-red --color D93F0B --description "…"` ignorando el error si ya existe; cuerpo según `contracts/notice-format.md` sección 3 en un archivo temporal (marcador `<!-- nightly-red:v1 state=open total=N first=YYYY-MM-DD -->`, con "`total` es un entero positivo" y "`first` es una fecha ISO en UTC"; fechas del texto en `DD-MM-YYYY`); `gh issue create --title "docker-e2e nightly en rojo" --label nightly-red --assignee "$ASSIGNEE" --body-file …`; saneo mínimo del texto del log (quita caracteres de control; el endurecimiento completo es de US4). La fecha de la noche sale de `NIGHTLY_ALERT_NOW` si está definida (se formatea con `date -u -d @N` y, si falla, con `date -u -r N`) y del reloj si no. Texto del aviso solo en ASCII. N01 y N02 en verde (FR-012: el canal es un issue del propio repositorio).
- [ ] T015 [US1] GREEN de la historia: N00, N01, N02 y N18 a N20 en verde en bash 5.x y en 3.2.57, secuencial; `shellcheck -S error -e SC1090,SC1091` sobre `.github/scripts/nightly-alert.sh` en rc 0. Anotar en Notes.

**Checkpoint**: US1 funciona con el `gh` falso; aún no hay workflow.

---

## Phase 4: User Story 2 - El aviso no puede cambiar el veredicto de la noche ni esconder su causa (Priority: P1)

**Goal**: ninguna falla del aviso toca el color de la corrida; el job `alert` queda cableado con los permisos mínimos.

**Independent Test**: N12 y las pruebas estructurales N23 a N28, N30 y N31 en verde; en real, E1.

### Tests for User Story 2 (escribirlos primero y verlos fallar)

- [ ] T016 [US2] Escribir **N12** en `tests/nightly-alert.bats`: con cada llamada a `gh` fallando por turnos (`FAKE_GH_FAIL=list`, `label`, `create`, `edit`, `comment`, `close`, `reopen`) `notify` sale con 0 y escribe `::warning::nightly-alert:`; con `create_assignee` el aviso se crea igual **sin** asignado y se anota (FR-009, FR-019, SC-004).
- [ ] T017 [US2] Escribir las estructurales sobre `.github/workflows/docker-e2e.yml` con `yq`, cada una asertando también la presencia de lo que protege (para que no nazcan verdes por vacuidad); **N23 y N26 fijan además FR-010**: el job `alert` es aparte y depende de `e2e`, así que el primer fallo identificable de la corrida sigue siendo el paso de la suite: **N23** (AW-1: job `alert` con `needs: e2e`, el `if` literal de `contracts/alert-workflow.md` sección 3 y `timeout-minutes: 5`), **N24** (AW-2: `permissions` del job `alert` exactamente `contents: read` e `issues: write`), **N25** (AW-3: el nivel del workflow y el job `e2e` no tienen `issues` y solo `contents: read`), **N26** (AW-4: el paso `Publish the nightly notice` lleva `continue-on-error: true` y llama al script con `notify`), **N27** (AW-5: cero `secrets.` en el archivo; nace verde por ser un ratchet y su capacidad de fallar se demuestra con la mutación M2), **N28** (AW-6: las entradas `alert_trial` boolean `false` y `trial_outcome` choice `red|green|timeout` por defecto `red`), **N30** (AW-8: `collect` es el último paso con `if: ${{ always() }}`, las tres salidas del job apuntan a `steps.collect.outputs.*` y todos los pasos tienen `id`) y **N31** (AW-9: el script existe, es ejecutable y empieza con `#!/usr/bin/env bash`).
- [ ] T018 [US2] **Ver el ROJO**: N12 y N23, N24, N26, N28, N30, N31 en `not ok` (el job y los ids no existen); anotar cuáles nacen verdes (solo N27, que es un ratchet y cuyo cazador es la variante (b) de M2; N25 asierta la presencia del job `alert` y nace en ROJO).

### Implementation for User Story 2

- [ ] T019 [US2] En el script, el manejo de fallas de `contracts/alert-script.md` sección 4: función que envuelve cada llamada a `gh` (captura código y salida, anota `::warning::nightly-alert: no se pudo <accion>: <estado>` y devuelve), una falla en `list` termina `notify` con aviso y salida 0, el reintento sin `--assignee` cuando falla la asignación, y salida 0 al final de `collect` y `notify`. N12 en verde.
- [ ] T020 [US2] Editar `.github/workflows/docker-e2e.yml` según `contracts/alert-workflow.md`: ids legibles en los pasos del job `e2e` (`checkout`, `install_yq`, `install_bats`, `verify_deps`, `run_suite`) **sin cambiar nombres ni texto**; paso final `collect` (`id: collect`, `if: ${{ always() }}`, `env: STEPS_JSON: ${{ toJSON(steps) }}`, `run: .github/scripts/nightly-alert.sh collect`); `outputs` del job (`failed_step`, `summary`, `failed_tests`); las entradas `alert_trial` y `trial_outcome` de `workflow_dispatch`; y el job `alert` completo de la sección 3 (checkout, paso `notify` con `continue-on-error: true` y el entorno por variables, nunca interpolado en `run:`). No tocar `Verify deps + docker` ni `Run docker-e2e suite`.
- [ ] T021 [US2] GREEN de la historia en ambos bash (secuencial): N12, N23, N24, N25, N26, N27, N28, N30 y N31 en verde; y los **14 tests de `tests/ci-workflows.bats`** (O1 a O5, S1 a S6, R1 a R3) siguen verdes **sin editarse** (R3 ya barre los pasos nuevos). Anotar en Notes.

**Checkpoint**: US1 y US2 (los dos P1): el aviso existe, no puede romper la noche y el workflow está cableado.

---

## Phase 5: User Story 3 - Una racha de rojos es un solo aviso y se apaga sola con el verde (Priority: P2)

**Goal**: actualizar, cerrar, reabrir y separar rachas; las corridas manuales y canceladas no mueven nada; el ensayo no toca el aviso real.

**Independent Test**: N03 a N11, N13 y N16 en verde con el `gh` falso; en real, E2 a E6.

### Tests for User Story 3 (escribirlos primero y verlos fallar)

- [ ] T022 [US3] Escribir **N03** (rojo repetido: con un aviso abierto no se crea otro, `total` +1, fila y comentario nuevos) y **N04** (tres corridas rojas con `RUN_ID` distintos dejan un solo aviso con `total=3` y tres filas; SC-002; cada corrida con su `NIGHTLY_ALERT_NOW` de `1792497600`, `1792584000` y `1792670400`, así que las filas llevan `20-10-2026`, `21-10-2026` y `22-10-2026` y el marcador conserva `first=2026-10-20`) en `tests/nightly-alert.bats`.
- [ ] T023 [US3] Escribir **N05** (verde tras rojo: marcador `state=resolved`, comentario con el enlace de la corrida verde y cierre con `--reason completed`; SC-003) y **N06** (verde sin aviso previo, o con el último en `resolved`: cero llamadas mutantes).
- [ ] T024 [US3] Escribir **N07** (FR-007: `cancelled`, `skipped` y un valor desconocido: cero llamadas mutantes y el valor recibido aparece en la anotación `::notice::`) y **N08** (`workflow_dispatch` sin ensayo, en rojo y en verde: cero llamadas, ni siquiera `list`, y la anotación de "sin accion").
- [ ] T025 [US3] Escribir **N09** (último aviso `CLOSED` con `state=open` y rojo: se reabre con `reopen --comment`, `total` +1, no se crea otro) y **N10**, con dos piernas: (a) último aviso `CLOSED` con `state=resolved` y rojo: se crea uno nuevo y el anterior no se toca; (b) último aviso `CLOSED` con `state=open` (cerrado a mano) y **verde**: solo se reescribe su marcador a `state=resolved` con `edit` (sin reabrir, comentar ni cerrar) y el rojo siguiente crea uno nuevo sin reabrir el viejo (hallazgo I1 del análisis).
- [ ] T026 [US3] Escribir **N11** (ensayo aislado: con un aviso real abierto, `EVENT=workflow_dispatch` y `TRIAL=true` en rojo crea el aviso de ensayo con la etiqueta `nightly-red-trial` y el título `[ensayo] docker-e2e nightly en rojo` sin tocar el real; un ensayo en verde cierra solo el de ensayo), **N13** (idempotencia: el mismo `RUN_ID` dos veces, en rojo y en verde, no cambia nada la segunda vez) y **N16** (marcador ausente o inválido: se comenta y se reabre si hacía falta, **sin reescribir el cuerpo**, con `::warning::`).
- [ ] T027 [US3] **Ver el ROJO**: todos los de T022 a T026 en `not ok` (el script solo sabe crear); anotar.

### Implementation for User Story 3 (sobre el mismo script, en este orden)

- [ ] T028 [US3] En `notify`, la decisión de modo y clase (`data-model.md` secciones 1 y 5): `schedule` es modo `real`; `workflow_dispatch` con `TRIAL=true` es `trial`; cualquier otra combinación no hace nada (ni `list`) y lo anota; `success` es `green`, `failure` es `red`, `cancelled`, `skipped` u otro valor es `none` y se anota el valor recibido (regla por defecto de research R7). N07 y N08 en verde.
- [ ] T029 [US3] En `notify`, **rojo con aviso abierto**: no sumar si el cuerpo ya tiene `[run <RUN_ID>](` (idempotencia: "una fila se identifica por el id de la corrida; repetir el id no suma la noche"); si no, `total` +1, fila nueva, cuerpo reescrito (`gh issue edit --body-file`) y un comentario de una línea (`contracts/notice-format.md` sección 4). N03, N04 y la parte roja de N13 en verde.
- [ ] T030 [US3] En `notify`, **verde con aviso abierto**: reescribir el marcador a `state=resolved`, comentar con el enlace de la corrida verde y cerrar con `gh issue close N --reason completed`; **verde sin aviso abierto**: no hacer nada; cerrar un aviso ya cerrado no hace nada; **verde con el último aviso cerrado a mano (`state=open`)**: solo `gh issue edit N --body-file …` con el marcador en `state=resolved`, sin reabrir, comentar ni cerrar. N05, N06, la parte verde de N13 y la pierna (b) de N10 en verde.
- [ ] T031 [US3] En `notify`, **rojo con el último aviso cerrado**: `state=open` es un cierre manual, así que `gh issue reopen N --comment …` y sumar la noche; `state=resolved` es otra racha, así que se crea uno nuevo sin tocar el anterior; marcador ausente o inválido se trata como `state=open` sin reescribir el cuerpo y con advertencia (`notice-format.md` sección 2). N09, la pierna (a) de N10 y N16 en verde.
- [ ] T032 [US3] En `notify`, la identidad por modo: etiqueta, color, descripción y título del modo `trial` (`nightly-red-trial`, `FBCA04`, `[ensayo] docker-e2e nightly en rojo`); un modo nunca lee ni escribe issues con la etiqueta del otro. N11 en verde.
- [ ] T033 [US3] GREEN de la historia en ambos bash (secuencial): N03 a N11, N13 y N16 en verde junto con todo lo anterior; `shellcheck` del script en rc 0. Anotar.

**Checkpoint**: el ciclo completo de una racha funciona contra el `gh` falso.

---

## Phase 6: User Story 4 - La suite del host impide que el aviso se vuelva mudo sin que nadie lo note (Priority: P2)

**Goal**: cotas, texto inerte, independencia de SIGPIPE, higiene del script, la mecánica del ensayo en el workflow y las mutaciones que prueban que el oráculo puede fallar.

**Independent Test**: N14, N15, N17, N21, N22 y N29 en verde, y 0 mutaciones sobrevivientes.

### Tests for User Story 4 (escribirlos primero y verlos fallar)

- [ ] T034 [US4] Escribir **N14** (cotas, FR-003) en `tests/nightly-alert.bats`: con `tap-25-failures.tap` el `failed_tests` de `collect` trae 20 nombres y la línea `... y 5 mas`; con `tap-long-names.tap` cada nombre queda en 120 caracteres como máximo con `...`; en `notify`, una racha con `total` 155 muestra 10 filas de detalle, conserva el total en el marcador y el cuerpo mide menos de 60.000 caracteres ("si pasara, se recortan primero las filas de detalle").
- [ ] T035 [US4] Escribir **N15** (texto inerte, FR-004) con `tap-hostile.tap`: ningún nombre conserva comillas invertidas ni `~~~`, `<!--` y `-->` quedan neutralizados, los nombres van dentro del bloque `~~~text` íntegro, el marcador de la primera línea queda intacto y ningún carácter de control llega al cuerpo; y **N17** (independencia de SIGPIPE): el caso N03 ejecutado con `SIGPIPE_MODE=ignore` y con `SIGPIPE_MODE=default` da el mismo estado final, la misma salida (incluida `stderr`) y el mismo código, y una **sonda** del propio arnés (`yes` hacia `head -1`, mirando `PIPESTATUS`) demuestra que cada modo aplica de verdad su disposición (141 en `default`, otro valor en `ignore`): sin la sonda el test podría pasar sin que la señal llegue al script.
- [ ] T036 [US4] Escribir **N21** (`simulate`: `red` sale con 1 y deja un `e2e.tap` con un `not ok`; `green` sale con 0 y deja un TAP sin fallos; `timeout` duerme `TRIAL_TIMEOUT_SLEEP` segundos y sale con 0; un argumento desconocido sale con 2) y **N29** (AW-7: `run_suite` lleva `if: ${{ !inputs.alert_trial }}`, el paso `simulate` lleva `if: ${{ inputs.alert_trial }}` y `TRIAL_OUTCOME: ${{ inputs.trial_outcome }}`, y `timeout-minutes` del job `e2e` es exactamente `${{ (inputs.alert_trial && inputs.trial_outcome == 'timeout') && 1 || 30 }}`).
- [ ] T037 [US4] Escribir **N22** (higiene del script): `bash -n` sin errores, shebang, bit de ejecución, solo ASCII, sin construcciones de bash 4 (`mapfile`, `declare -A`, `${…,,}`, `${…^^}`, `coproc`, `local -n`), y sin ningún pipe cuyo consumidor cierre antes que el productor (`head`, `grep` con `-q` o `-m`, `sed` con `Nq`, `awk` con `exit`: las mismas reglas del ratchet de 039); N17 y N22 nacen verdes por ser guardas y su capacidad de fallar se demuestra con las dos variantes de M19: la (a), `| head -1`, cae en N22; la (b), un pipe que lee una línea y cierra con una carga de más de 64 KiB, solo se nota si la disposición de SIGPIPE cambia el resultado, así que cae en N17.
- [ ] T038 [US4] **Ver el ROJO**: N14, N15, N21 y N29 en `not ok`; anotar cuáles nacen verdes (N17, N22) y por qué.

### Implementation for User Story 4

- [ ] T039 [US4] En el script, las cotas: en `collect` y en el cuerpo de `notify`, "hasta 20 nombres de test" con la línea final `... y N mas`, cada nombre de "máximo 120 caracteres, recortado con `...`", 10 filas de detalle de noches y el cuerpo por debajo de 60.000 caracteres recortando primero las filas. N14 en verde.
- [ ] T040 [US4] En el script, el saneo completo del texto del log (`contracts/notice-format.md` sección 6): quitar caracteres de control salvo el salto de línea que separa nombres, cambiar comillas invertidas y virgulillas por apóstrofos, neutralizar `<!--` y `-->` (a `<!-` y `->`), recortar cada línea a 120 caracteres; nombres dentro de `~~~text`; el paso fallido y el resumen entre comillas invertidas tras el saneo; el marcador se arma solo con valores propios del script. N15 en verde.
- [ ] T041 [US4] En el script, el subcomando `simulate` (`contracts/alert-script.md` sección 3): `red` escribe `e2e.tap` con `1..4`, tres `ok` y `not ok 4 trial: induced failure` y sale con 1; `green` escribe cuatro `ok` y sale con 0; `timeout` escribe `1..1` y duerme `TRIAL_TIMEOUT_SLEEP` segundos (120 por defecto). N21 en verde.
- [ ] T042 [US4] Editar `.github/workflows/docker-e2e.yml`: `if: ${{ !inputs.alert_trial }}` en `run_suite` (sin tocar su `run:` ni su `env: DOCKER_E2E: '1'`), el paso `simulate` con su `if`, su entorno `TRIAL_OUTCOME` y `run: .github/scripts/nightly-alert.sh simulate "$TRIAL_OUTCOME"` (antes de `collect`), y el literal de `timeout-minutes` del job `e2e`. N29 en verde, y los 14 tests de `tests/ci-workflows.bats` siguen verdes sin editarse.
- [ ] T043 [US4] GREEN de la historia y del oráculo completo, secuencial: `bats tests/nightly-alert.bats` en bash 5.x y en 3.2.57 (N17 ya cubre las dos disposiciones de SIGPIPE dentro del test) y, como pasada de paridad con el runner, con el proceso de bats bajo SIGPIPE ignorada (`perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats tests/nightly-alert.bats`, que cubre el resto del archivo); los 32 tests (N00 a N31) en verde (FR-015: verde después, en bash 3.2 y 5.x y con las señales que heredan los runners). Anotar en Notes.

---

## Phase 7: Mutaciones (SC-005)

**Purpose**: demostrar que el oráculo puede fallar. Cada tarea aplica la mutación a una **copia** y apunta `ALERT_SCRIPT` o `ALERT_WORKFLOW` a ella (los tests no leen otra ruta; si algo obligara a mutar en el lugar, se restaura con `cmp` contra una copia previa), ejecuta el test cazador de la tabla de `quickstart.md` sección 3 y exige que **caiga**. Una mutación que sobrevive obliga a endurecer el oráculo (RED y después GREEN) antes de seguir. Secuencial; ninguna lleva `[P]`.

- [ ] T044 M1: quitar `always()` del `if` del job `alert` en una copia del workflow. Cae **N23**.
- [ ] T045 M2: dos variantes sobre una copia del workflow: (a) agregar `issues: write` a los `permissions` del workflow, cae **N25**; (b) agregar una referencia a `secrets.TOKEN`, cae **N27** (prueba que el ratchet puede fallar).
- [ ] T046 M3: quitar `continue-on-error: true` del paso `Publish the nightly notice`. Cae **N26**.
- [ ] T047 M4: hacer que `notify` salga con el código del último `gh` fallido. Cae **N12**.
- [ ] T048 M5: crear el aviso sin `--assignee`. Cae **N01**.
- [ ] T049 M6: tratar `cancelled` como rojo. Cae **N07**.
- [ ] T050 M7: dejar que una corrida manual normal abra el aviso. Cae **N08**.
- [ ] T051 M8: en un rojo repetido crear un segundo issue. Caen **N03** y **N04**.
- [ ] T052 M9: en verde no cerrar el aviso. Cae **N05**.
- [ ] T053 M10: en verde sin aviso previo crear o comentar algo. Cae **N06**.
- [ ] T054 M11: en un cierre manual crear uno nuevo en vez de reabrir. Cae **N09**.
- [ ] T055 M12, dos variantes: (a) cerrar por verde sin escribir `state=resolved`; (b) un verde sobre un aviso cerrado a mano que no reescribe el marcador. Cae **N10** (la pierna (a) la primera, la (b) la segunda).
- [ ] T056 M13: quitar la cota de 20 nombres. Cae **N14**.
- [ ] T057 M14: no sanear comillas invertidas ni `~~~`. Cae **N15**.
- [ ] T058 M15: hacer que `collect` calcule `executed` igual que `total`. Cae **N19**.
- [ ] T059 M16: quitar la guarda de idempotencia (`[run <id>](`). Cae **N13**.
- [ ] T060 M17: que el modo ensayo use la etiqueta del aviso real. Cae **N11**.
- [ ] T061 M18: quitar el `if` de ensayo de `run_suite` en una copia del workflow. Cae **N29**.
- [ ] T062 M19, dos variantes: (a) introducir `| head -1` en el script, cae **N22**; (b) introducir un pipe que lee una línea y cierra, con una carga de más de 64 KiB, cae **N17**.
- [ ] T063 M20: cambiar el literal de `timeout-minutes` del job `e2e`. Cae **N29**.
- [ ] T064 Resumen: registrar en Notes la tabla M1 a M20 con el test que cayó en bash 5.x y en 3.2.57 y confirmar **0 sobrevivientes** (FR-015, SC-005; son 20 mutaciones y M2, M12 y M19 tienen dos variantes cada una); verificar con `cmp` que el árbol de trabajo quedó idéntico al previo a las mutaciones.

---

## Phase 8: Polish y gates locales

- [ ] T065 [P] `CHANGELOG.md`: entrada que diga qué cubre el aviso y qué no (FR-018): no detecta un nightly que no llega a arrancar, la rama `schedule` de la condición solo la ejercen el oráculo y la primera noche roja real, y el aviso complementa y no reemplaza las notificaciones nativas de GitHub. **Sin bump de `VERSION`.**
- [ ] T066 [P] `CLAUDE.md`: ajustar la entrada de 040 del bloque SPECKIT al estado implementado (número de tests, resultados, hallazgos) y agregar en "Common gotchas" una viñeta solo si algo nuevo se aprendió (por ejemplo, que la conclusión de una corrida es la peor de las de sus jobs, así que un job de aviso debe ser a prueba de fallas). Se versiona con `git add -f`. No ejecutar ningún hook de contexto de agente (no existe).
- [ ] T067 Verificar `VERSION` a mano contra `origin/main` (`git fetch origin` y `git show origin/main:VERSION`): 0.28.0 en ambos, sin bump.
- [ ] T068 Escaneo de bytes de todos los archivos tocados o nuevos (UTF-8 válido, 0 marcas combinantes, 0 bytes de control, NFC) y verificar que el script, el `gh` falso, los fixtures y `tests/nightly-alert.bats` son solo ASCII.
- [ ] T069 Gate completo, un bash tras otro: `bats tests/` y después `PATH=/bin:$PATH bats tests/` (3.2.57). Esperado: **1849 ok y 0 not ok** en cada uno (1817 más los 32 tests nuevos, N00 a N31). Un rojo de contención se re-mide aislado antes de nombrarlo (regla R6 de 039). Anotar conteos, saltos y duraciones.
- [ ] T070 `shellcheck -S error -e SC1090,SC1091` con el comando **exacto** del job de CI (`find` más `xargs`, `quickstart.md` sección 2.4): rc 0 y sin salida; confirmar que `./.github/scripts/nightly-alert.sh` está en la lista que lintea.
- [ ] T071 Alcance y secretos (SC-007; FR-017: ni `docker/`, ni `scripts/`, ni `modules/`, ni `setup.sh`): `git diff origin/main -- docker scripts modules setup.sh | wc -l` da 0; `grep -c 'secrets\.' .github/workflows/docker-e2e.yml` da 0; `git diff origin/main -- tests/ci-workflows.bats` vacío (los tests de 039 no se editaron); los únicos permisos nuevos son `issues: write` en el job `alert`.
- [ ] T072 Ejecutar la validación local de `quickstart.md` sección 2 completa y anotar el resultado en Notes.

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
- [ ] T081 **COMPUERTA** **E7 (medición M7)**: ensayo `timeout`. Registrar con qué valor entrega la plataforma `needs.e2e.result` (la primera anotación `::notice::` del log de `notify` lo muestra), la conclusión del job `e2e` y qué hizo el script; decide la regla de research R7.
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
