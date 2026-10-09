---

description: "Task list for 039-fix-nightly-e2e-sigpipe"
---

# Tasks: El nightly de docker-e2e ejecuta la suite de verdad

**Input**: `specs/039-fix-nightly-e2e-sigpipe/` (plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md)

**Prerequisites**: rama `039-fix-nightly-e2e-sigpipe` desde `main` en `da22a06` (VERSION 0.28.0, 038 ya mergeada). Al generar estas tareas Docker Desktop está apagado y ningún push está autorizado: ver las COMPUERTAS.

**Tests**: obligatorios (Constitución III, test-first). Cada tarea de implementación tiene antes su tarea RED; se confirma que el test falla por la razón correcta antes de tocar un workflow, y se confirma GREEN después. El oráculo y sus fixtures se escriben y se ven en rojo antes de modificar `docker-e2e.yml` o `test.yml`.

**Organización**: por historia de usuario. US1 (el nightly llega a ejecutar la suite) es el MVP. US2 (el oráculo permanente y la auditoría) depende de US1 solo para R3. US3 (rojos reales) depende de la primera corrida real. **Todo lo local se hace sin Docker ni push; las COMPUERTAS esperan al operador.**

## Format: `[ID] [P?] [Story] Description`

- **[P]**: paralelizable (archivo distinto, sin dependencia de una tarea incompleta).
- **[Story]**: US1 a US3 según spec.md.
- **COMPUERTA**: tarea que requiere confirmación explícita del operador y no se ejecuta sola (push, `workflow_dispatch`, arrancar Docker Desktop, commit y PR).
- Rutas relativas a la raíz del repo. Contratos: `WSO` = `contracts/workflow-step-oracle.md`, `SS` = `contracts/suite-step.md`, `CLS` = `contracts/e2e-classification.md`. Decisiones de Fase 0: `D1` a `D10` de `research.md`.

## Reglas transversales (aplican a toda tarea)

- bash 3.2 a 5.x: sin `mapfile`, sin arreglos asociativos, sin `${var,,}`. Todo helper de test debe correr bajo `/bin/bash` 3.2.57 y bajo bash 5.x.
- Nunca `producer | head` ni `producer | grep -q` bajo `pipefail`: es la regla que esta feature hace cumplir, así que tampoco se rompe en su propio código. Aserciones sobre `$output` con `grep -q … <<< "$output"` (sin pipe); un `[[ ]]` intermedio no falla en bats, así que va al final o se usa `grep`/`[ ]`.
- Negativos en bats al final del test, o como `run …; [ "$status" -ne 0 ]`.
- Payloads por archivo, nunca por argv ni por el entorno (límite de 128 KiB por string en Linux).
- Auditoría de bytes tras cada edición de `.md`, `.yml`, `.bats` o fixture: `LC_ALL=C grep -c $'\xcc\x80'` en 0 y UTF-8 válido.
- Suites dual bash siempre secuenciales, nunca concurrentes (la contención produce rojos falsos).
- **No tocar `docker/`, `scripts/`, `modules/` ni `setup.sh`** (FR-015, SC-008). Si una tarea parece exigirlo, detenerse y registrarlo como defecto de producto (se escala, no se corrige aquí).
- Los nombres de los pasos `Verify deps + docker` y `Run docker-e2e suite` NO cambian: el oráculo los selecciona por nombre.
- El hook `speckit.agent-context.update` no se ejecuta (borra el bloque SPECKIT de `CLAUDE.md`).

---

## Phase 1: Setup

**Purpose**: base verificada y fixtures congelados antes de escribir el arnés.

- [X] T001 Verificar la base sin volver a correr la suite completa: `git log --oneline -1 origin/main` debe ser `da22a06` o un descendiente (si main avanzó, `git rebase origin/main` y repetir la verificación), y `git show origin/main:VERSION` debe ser igual a `cat VERSION` (0.28.0). Anotar en las Notes de `specs/039-fix-nightly-e2e-sigpipe/tasks.md` la línea base: la CI de `main` sobre `da22a06` dio verde (bats en ubuntu con bash 5.x y en macOS con bash 3.2, y shellcheck) y el gate local de 038 midió 1803 de 1803 en ambos bash sobre un árbol idéntico. El gate final de esta feature espera **1817** (1803 más los 14 tests de `tests/ci-workflows.bats`). No se repiten los 22 minutos por brazo porque no hay cambios de código desde esa medición.
- [X] T002 [P] Congelar el defecto: crear `tests/fixtures/ci/step-verify-with-defect.sh` con el texto verbatim del `run:` del paso `Verify deps + docker` tal como estaba en `da22a06`: `git show da22a06:.github/workflows/docker-e2e.yml | yq '.jobs.e2e.steps[] | select(.name == "Verify deps + docker") | .run' > tests/fixtures/ci/step-verify-with-defect.sh`. Comprobar que tiene 11 líneas, que empieza con `set -euo pipefail`, que contiene `docker info | head -10` (`grep -F`) y que es byte-idéntico (`cmp`) a la extracción del workflow actual, que aún no se arregló. Es la prueba de que el arnés puede fallar (WSO O2).
- [X] T003 [P] Crear los cuatro fixtures TAP en `tests/fixtures/ci/` (SS §7): `tap-all-skip.tap` (`1..3` y tres líneas `ok N x # skip motivo`, dos con `set DOCKER_E2E=1 to run` y una con `docker daemon not reachable`), `tap-empty.tap` (solo `1..0`), `tap-mixed.tap` (`1..3`, dos `ok` y un `ok 3 c # skip reason`) y `tap-failing.tap` (`1..2`, un `ok 1 a`, un `not ok 2 b` y una línea `# (in test file x.bats, line 5)`). S5 no necesita archivo: es un `bats` falso sin salida.
- [X] T004 [P] Crear los fixtures del ratchet en `tests/fixtures/ci/` (WSO §5): `ratchet-bad.yml`, un workflow mínimo (`name`, `on: workflow_dispatch`, un job con `runs-on`) con un paso por cada consumidor prohibido y el nombre del paso igual al patrón (`head -1`, `head -n 3`, `grep -q`, `grep -m1`, `sed 1q`, `sed -n 1q`, `awk exit`); y `ratchet-good.yml` con pasos que usan `| xargs echo`, `| tee /dev/null`, `| sort`, `| wc -c`, `| grep x` sin `-q` y `true || echo y`. Ambos deben parsear con `yq '.' <archivo>`.

---

## Phase 2: Foundational (bloqueante para todas las historias)

**Purpose**: el arnés (extracción, stubs, ejecución, detector) con sus propios tests, que pasan hoy y prueban que el arnés puede fallar.

**CRITICAL**: ninguna historia empieza antes de cerrar esta fase.

- [X] T005 (FR-007) Crear `tests/ci-workflows.bats` con el arnés **dentro** del archivo (no en `tests/helper.bash`): cabecera que cite WSO y SS, `load helper`, `WF="$REPO_ROOT/.github/workflows"`, `FIX="$REPO_ROOT/tests/fixtures/ci"`, y un `setup()` que haga `setup_tmp_dir`, cree `$TMP_TEST_DIR/run/tests`, `$TMP_TEST_DIR/stubs`, un `docker-e2e-x.bats` y un `other.bats` vacíos en `run/tests` y llame `_make_stubs`; `teardown()` con `teardown_tmp_dir`. Funciones, todas bash 3.2: `_extract_run FILE JOB NAME` (imprime el `run:`; falla con mensaje a stderr si el paso coincide un número de veces distinto de 1 o el texto está vacío; usa `NAME="$name" yq … select(.name == strenv(NAME))`, con el `PATH` normal y nunca el de los stubs); `_extract_env FILE JOB NAME VAR`; `_make_stubs DIR` (stubs de `bats`, `yq`, `jq`, `git`, `tmux` que imprimen `<herramienta> stub 1.0`, y el `docker` de WSO §3 con `--version`, `compose version`, `info` en dos tandas con `echo` por línea y pausa de `${STUB_INFO_DELAY:-0.3}` s, `info --format` que renderiza los cinco campos (el servidor vale `27.5.1`, distinto a propósito del cliente `28.0.4`; se renderiza con `t=${t//'{{.Campo}}'/valor}`, verificado en bash 3.2.57 y 5.3.15, y ningún valor lleva `&`, la trampa de 023) y falla con `template parsing error` si queda un `{{`, el modo `STUB_DOCKER_DOWN=1`, y que registre en `$STUB_LOG` las líneas `info-chunk client 14` e `info-chunk server 40`); `_run_step SCRIPTFILE [VAR=val…]` (agrega al final una copia con la línea centinela `echo __ORACLE_REACHED_END__`, ejecuta `bash -e` en `$TMP_TEST_DIR/run` con `PATH="$TMP_TEST_DIR/stubs:$PATH"` y deja `$status` y `$output`); `_ratchet_scan YAML…` (con `yq -o=json '.'` y `jq`, imprime `archivo<TAB>paso<TAB>línea` por cada pipe cuyo consumidor sea `head`, `grep` con `q` o `-m`, `sed` con `-n…q` o `Nq`, o `awk` con `exit`; ignora comentarios y `||`; siempre código 0).
- [X] T006 Test O1 en `tests/ci-workflows.bats` (WSO §4): `_extract_run "$WF/docker-e2e.yml" e2e "Verify deps + docker"` coincide una vez, no está vacío y contiene `docker`; y, al final del mismo test, el caso negativo `run _extract_run … "no existe"; [ "$status" -ne 0 ]`, que prueba que la extracción puede fallar. Pasa hoy.
- [X] T007 Test O5 en `tests/ci-workflows.bats`: autochequeo del stub. Ejecutar `docker info` del stub solo, con `STUB_LOG` apuntando a un archivo temporal: la salida tiene 54 líneas, el log registra `info-chunk client 14` y luego `info-chunk server 40` en ese orden, 14 es mayor que 10, y el archivo del stub contiene un `sleep`. Evita que un stub debilitado deje el oráculo en vacío. Pasa hoy.
- [X] T008 Test O2 en `tests/ci-workflows.bats` (WSO O2, SC-003, la prueba de que el oráculo puede fallar): `_run_step "$FIX/step-verify-with-defect.sh"` termina con estado **141** y la salida **no** contiene `__ORACLE_REACHED_END__`. Pasa hoy porque el fixture conserva el defecto; si el arnés dejara de detectarlo, este test se pone rojo (FR-008).
- [X] T009 Tests R1 y R2 en `tests/ci-workflows.bats` (WSO §5), prueba del detector: R1, `_ratchet_scan "$FIX/ratchet-bad.yml"` marca los siete pasos prohibidos (siete líneas, una con el nombre de cada paso); R2, `_ratchet_scan "$FIX/ratchet-good.yml"` no imprime nada (aserción al final: `[ -z "$output" ]`). Pasan hoy.
- [X] T010 (FR-009) Checkpoint: `bats tests/ci-workflows.bats` y `PATH=/bin:$PATH bats tests/ci-workflows.bats`, secuenciales: **5 de 5** (O1, O2, O5, R1, R2) en ambos bash. Auditoría de bytes de los archivos nuevos. Anotar en Notes.

**Checkpoint**: el arnés está probado; las historias pueden empezar.

---

## Phase 3: User Story 1 - El nightly llega a ejecutar la suite (Priority: P1) MVP

**Goal**: el paso de verificación termina en verde mostrando versiones, servidor y arquitectura; el paso de la suite deja un resumen, propaga el código de `bats` y termina en rojo si no se ejecutó ningún e2e.

**Independent Test**: `bats tests/ci-workflows.bats` con O3 y S1 a S6 en verde; la corrida real (T020) muestra el paso de la suite arrancado.

### RED (antes de tocar el workflow)

- [X] T011 [US1] Test O3 en `tests/ci-workflows.bats` (WSO O3): `_run_step` sobre el `run:` real de `docker-e2e.yml` (`e2e` / `Verify deps + docker`) con Docker sano: estado 0, `__ORACLE_REACHED_END__` presente, y la salida contiene `Docker version`, `Docker Compose version`, los tokens `server=27.5.1` (el servidor del stub vale distinto que el cliente `28.0.4` a propósito: con el mismo valor `docker --version` bastaría y la aserción sería vacua) y `arch=x86_64`. **Debe fallar hoy** con estado 141 (FR-001, FR-002).
- [X] T012 [US1] Test O4 en `tests/ci-workflows.bats` (WSO O4): el mismo paso con `STUB_DOCKER_DOWN=1` termina con estado distinto de 0, sin centinela, y con el mensaje `Cannot connect to the Docker daemon` en la salida. Pasa hoy: es la **guarda de FR-003** que impide arreglar el 141 silenciando el fallo (por ejemplo con `|| true`).
- [X] T013 [US1] Tests S1 a S5 en `tests/ci-workflows.bats` (SS §7; FR-004, FR-005, FR-006, SC-007): cada uno extrae el `run:` del paso `Run docker-e2e suite`, crea un segundo directorio de stubs con un `bats` falso que registra sus argumentos en `$FAKE_ARGS`, imprime `$FAKE_TAP` y sale con `$FAKE_RC` (puesto antes que el stub trivial en el `PATH`), y afirma: **S1** `tap-all-skip.tap` con código 0, el paso termina en 1, el resumen dice `executed=0` y aparece `::error::`; **S2** `tap-empty.tap` con 0, termina en 1; **S3** `tap-mixed.tap` con 0, termina en 0, el resumen es `total=3 executed=2 skipped=1 failed=0` y `$FAKE_ARGS` contiene `--tap` y `tests/docker-e2e-x.bats` pero no `tests/other.bats` (FR-004: el glob toma todos los e2e y solo ellos); **S4** `tap-failing.tap` con 1, termina en 1 y el resumen dice `failed=1`; **S5** sin salida y con 127, termina en 127. S1 a S4 **deben fallar hoy** (el paso actual no imprime resumen ni guarda el verde vacío); S5 pasa hoy y es guarda.
- [X] T014 [US1] Test S6 en `tests/ci-workflows.bats` (SS §1, FR-004): `_extract_env "$WF/docker-e2e.yml" e2e "Run docker-e2e suite" DOCKER_E2E` es exactamente `1`. Pasa hoy: es guarda contra perder la variable.
- [X] T015 [US1] Checkpoint RED: correr `tests/ci-workflows.bats` y confirmar que fallan **exactamente** O3, S1, S2, S3 y S4 (5 `not ok`) y pasan O1, O2, O4, O5, S5, S6, R1 y R2 (8 `ok`); cada rojo por la razón correcta (O3 por estado 141, no por un error del arnés; S1 y S2 por estado 0 en vez de 1; S3 y S4 por falta de la línea de resumen). Anotar la lista y los motivos en Notes: es la evidencia de RED.

### GREEN

- [X] T016 [US1] En `.github/workflows/docker-e2e.yml`, paso `Verify deps + docker`: reemplazar el `run:` por el texto de D3, sin pipes. Tras `set -euo pipefail`, definir `first_line() { local v; v=$("$@"); printf '%s\n' "${v%%$'\n'*}"; }` y usar `first_line bash --version`; mantener `bats --version`, `yq --version`, `jq --version`, `git --version`, `tmux -V`, `docker --version` y `docker compose version`; y cerrar con `docker info --format 'server={{.ServerVersion}} os={{.OperatingSystem}} arch={{.Architecture}} cgroup={{.CgroupVersion}} storage={{.Driver}}'`. No cambiar el nombre del paso. Verificado en M3 y M4: rc 0 con Docker sano, rc 1 con Docker caído, en bash 3.2.57 y 5.3.15.
- [X] T017 [US1] (FR-004, FR-005, FR-006) En el mismo workflow, paso `Run docker-e2e suite`: reemplazar el `run:` por el texto de referencia de SS §2 (`tee e2e.tap`, conteos con `grep -c … || true`, línea `e2e summary:`, `[ "$rc" -eq 0 ] || exit "$rc"` y la guarda de `executed` igual a 0 con `::error::`), conservando `env: DOCKER_E2E: '1'` y el nombre del paso. Mismo archivo que T016: secuencial.
- [X] T018 [US1] (FR-009) Checkpoint GREEN: `tests/ci-workflows.bats` en bash 5.x y luego con `PATH=/bin:$PATH` (3.2.57): **13 de 13** (O1, O2, O3, O4, O5, S1 a S6, R1, R2; R3 llega con US2). Confirmar que O3 y S1 a S4 pasaron de rojo a verde y anotarlo en Notes.
- [X] T019 [US1] Invariantes del workflow tras la edición: `yq '.' .github/workflows/docker-e2e.yml > /dev/null` parsea; `yq '.jobs.e2e.steps | length'` sigue en 5 (el `Checkout` es un paso `uses:`; los pasos con `run:` son 4: `yq '[.jobs.e2e.steps[] | select(.run != null)] | length'`); `yq '.permissions'` sigue en `contents: read`; `yq '.jobs.e2e."timeout-minutes"'` sigue en 30; `grep -c '\${{' .github/workflows/docker-e2e.yml` no aumentó respecto de `git show origin/main:.github/workflows/docker-e2e.yml` (la plantilla `{{.ServerVersion}}` no lleva `$`, así que no es una expresión de Actions).
- [X] T020 [US1] **COMPUERTA** (requiere confirmación explícita del operador, pedida para este alcance: pushes normales, sin `--force`, de la rama `039-fix-nightly-e2e-sigpipe` y despachos del workflow sobre ella hasta cerrar T034; cualquier otra cosa se vuelve a consultar): corrida de evidencia (FR-014, SC-001). (a) Con staging archivo por archivo (nunca `git add -A`) crear el commit local con mensaje ASCII; (b) empujar la rama por HTTPS con el helper de `gh` (`git -c credential.helper='' -c credential.helper='!gh auth git-credential' push https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher.git 039-fix-nightly-e2e-sigpipe:039-fix-nightly-e2e-sigpipe`; el token ya tiene el scope `workflow`); (c) `gh workflow run docker-e2e.yml --ref 039-fix-nightly-e2e-sigpipe` y `gh run watch`; (d) registrar en Notes el `run_id`, que el paso de verificación terminó en verde con las versiones y la arquitectura del runner, que el paso de la suite arrancó, la línea `e2e summary:` y la duración. Si el Docker real rechaza un campo de la plantilla de `--format` (riesgo declarado en D3), el paso falla fuerte aquí: corregir la plantilla, volver a correr el oráculo y re-despachar.

**Checkpoint**: US1 completa y, tras T020, validada en un runner real.

---

## Phase 4: User Story 2 - La regresión no puede volver sin que la suite del host la note (Priority: P1)

**Goal**: el oráculo es permanente y cubre la clase en todos los workflows; la auditoría de FR-010 queda con disposición escrita.

**Independent Test**: R3 en verde y las mutaciones M1 y M7 en rojo.

- [X] T021 [US2] RED, test R3 en `tests/ci-workflows.bats` (WSO §5): primero comprueba que el barrido no es vacío (`$WF` contiene al menos 3 archivos `.yml` y `yq '[.jobs[].steps[] | select(.run != null)] | length'` da al menos 1 en cada uno) y después que `_ratchet_scan "$WF"/*.yml` no imprime nada (aserción al final: `[ -z "$output" ]`; si falla, el mensaje muestra los infractores). **Debe fallar hoy**: tras T016 `docker-e2e.yml` ya está limpio y quedan los dos `| head -1` de `test.yml`.
- [X] T022 [US2] Checkpoint RED: correr R3 y confirmar que su salida lista **exactamente** dos líneas, ambas del paso `Verify deps + pin the bash target (025/023: never run an assumed version)` de `test.yml`. Anotar la salida en Notes.
- [X] T023 [US2] En `.github/workflows/test.yml`, paso `Verify deps + pin the bash target (025/023: never run an assumed version)`: tras `set -euo pipefail` definir `first_line() { local v; v=$("$@"); printf '%s\n' "${v%%$'\n'*}"; }` y reemplazar `bash --version | head -1` por `first_line bash --version` y `/bin/bash --version | head -1` por `first_line /bin/bash --version`. No tocar nada más: las expresiones `${{ runner.os }}`, el orden de los pasos y la matriz de 025 quedan idénticos. Es un archivo distinto de T016 y T017: puede ir en paralelo con ellos una vez escrito T021.
- [X] T024 [US2] (FR-009) Checkpoint GREEN: R3 en verde y `tests/ci-workflows.bats` **14 de 14** en bash 5.x y con `PATH=/bin:$PATH`. Comprobar que `yq '.' .github/workflows/test.yml > /dev/null` parsea y que la lista de nombres de pasos (`yq '.jobs.bats.steps[].name' .github/workflows/test.yml`) es idéntica a la de `git show origin/main:.github/workflows/test.yml`.
- [X] T025 [P] [US2] Registrar en Notes la auditoría de FR-010 y SC-005 con su disposición final, tomando como fuente la tabla de D5 de `research.md` y confirmándola tras T016 y T023: 14 pasos `run:`, 5 pipes reales, 4 con consumidor que cierra antes (todos `| head`, uno fallaba y tres eran seguros por construcción) **eliminados**, `| xargs shellcheck` seguro, y los scripts de los e2e sin hallazgos. Dejar escrito que el conteo ingenuo de `|` incluye falsos positivos de `||`.

**Checkpoint**: US2 completa; el ratchet y el oráculo vigilan todos los workflows.

---

## Phase 5: User Story 3 - Los rojos reales dejan de estar escondidos (Priority: P2)

**Goal**: cada e2e que falle queda clasificado y con disposición; E1 y E3 de 031 corregidos.

**Independent Test**: tras la corrida real, la tabla de Notes tiene el 100% de los rojos con tipo, evidencia y disposición, y `docker-e2e-askq-guard.bats` da 3 de 3.

**Camino por Docker local (T026 a T030) y camino por CI**: si el operador no autoriza arrancar Docker, T026, T027 y T030 se omiten y la demostración rojo a verde de E1 y E3 sale de CI: el RED es la corrida de T020 (que corre con E1 y E3 sin corregir) y el GREEN es la re-despachada tras T028 y T029.

- [ ] T026 [US3] **COMPUERTA** (requiere confirmación explícita del operador): arrancar Docker Desktop (hoy apagado; el Mac tiene carga ~9 por aplicaciones del usuario, así que se avisa antes). `open -a Docker` y esperar hasta que `docker info >/dev/null 2>&1` responda; anotar la versión de Docker en Notes.
- [ ] T027 [US3] RED local de E1 y E3 (requiere T026): con el archivo **sin modificar**, `DOCKER_E2E=1 bats --tap tests/docker-e2e-askq-guard.bats` debe dar `1..3` con E1 y E3 en `not ok` y E1b en `ok`. Guardar la salida de los dos fallos en Notes y confirmar con ella las causas de D7 (E1: `jq` sin `~/.claude/settings.json`; E3: `test -n "$server"` falla). Si la causa real difiere, corregir D7 en `research.md` antes de seguir.
- [X] T028 [US3] E1 en `tests/docker-e2e-askq-guard.bats`: dentro del script del contenedor del test `pre_install_askq_hook registers PreToolUse+AskUserQuestion…`, agregar `mkdir -p "$HOME/.claude"` justo después de `set -e` y antes de invocar el instalador, con un comentario que diga que el arranque real ya creó `~/.claude` antes de `pre_install_askq_hook` y que `--entrypoint sh` se lo salta. No cambiar las aserciones ni el nombre del test (FR-012: arreglo acotado al test).
- [X] T029 [US3] E3 en el mismo archivo (después de T028): auto-sembrado con el patrón de `tests/docker-e2e-voice.bats`. En `setup()`, tras el scaffold, `mkdir -p "$E2E_AGENT_DIR/.e2e"`, copiar `tests/fixtures/telegram-server-pristine.ts` allí y escribir `$E2E_AGENT_DIR/.e2e/seed.sh` (`#!/bin/sh`, `set -e`, crear `$HOME/.claude/plugins/cache/claude-plugins-official/telegram/0.0.6`, copiar el fixture a `server.ts`, ejecutar `python3 /opt/agent-admin/scripts/apply_telegram_typing_patch.py <server.ts> > /tmp/patch.log 2>&1` y hacer `echo` de la ruta). El cuerpo de E3 pasa a `server=$(sh /workspace/.e2e/seed.sh)` y conserva las tres aserciones (`typing refresh patch v6`, `askq-guard give-up delivery patch v1` y la cadena en español con `menú`). Mantener la disciplina de comillas simples de ese archivo: ninguna variable de shell interpolada dentro de los `-c '…'`.
- [ ] T030 [US3] GREEN local de E1 y E3 (requiere T026): `DOCKER_E2E=1 bats --tap tests/docker-e2e-askq-guard.bats` da **3 de 3** `ok`, sin saltos. Anotar en Notes el cambio de 1 de 3 a 3 de 3 (FR-012, R4 de CLS). Correr también `bats tests/ci-workflows.bats` para confirmar que nada del oráculo se movió.
- [X] T031 [US3] Depende de T020, la compuerta; solo lee los logs de GitHub: clasificar la primera corrida real (FR-011, SC-004, SC-006). Con `gh run view <run_id> --log | grep -E 'e2e summary|^not ok|# skip|::error::'` construir en Notes un bullet **"Primera corrida real del nightly"** con el formato de CLS §2: primera línea con `run_id` y la línea `e2e summary:`, y una fila por cada test que no terminó verde con test, archivo, estado, causa (mecanismo nombrado), tipo (arnés, producto o entorno), evidencia (`run_id` y fragmento del log) y disposición. La causa de cada rojo se mide, no se supone. Un test intermitente no se etiqueta "flake" sin repeticiones (R6 de CLS).
- [ ] T032 [US3] Aplicar las disposiciones de T031, una por fila (FR-012, FR-013; reglas R2 a R5 de CLS). **Corregido**: solo si la causa ya estaba diagnosticada o el arreglo queda acotado al test o a su arnés, sin tocar producción, y se verifica en una re-despachada. **Aislado**: un `skip "<causa> (seguimiento: <referencia>)"` en el propio test, condicionado al entorno cuando el tipo sea entorno (por ejemplo `[ "$(uname -m)" = "x86_64" ] && skip …`), que debe aparecer en el TAP como `# skip <motivo>` y tener seguimiento concreto. **Escalado**: un defecto de producto se registra y no se esconde con un salto ni se corrige aquí. Anotar cada seguimiento en Notes.
- [X] T033 [US3] **COMPUERTA** (dentro del alcance autorizado en T020: push normal de la rama y re-despacho): tiempo (FR-016, SC-009). Si una corrida terminó `timed_out`, subir `timeout-minutes` de 30 a 60 en `.github/workflows/docker-e2e.yml`, actualizar la expectativa de T019, re-despachar y anotar la duración medida. No dividir la suite en jobs paralelos salvo evidencia de que 60 minutos no bastan; en ese caso se decide con el operador. Si la primera corrida cupo en los 30 minutos, anotar "N/A" con la duración medida.
- [ ] T034 [US3] **COMPUERTA** (dentro del alcance autorizado en T020: push normal de la rama y re-despacho): corrida de cierre. Una corrida real en la que **todos** los e2e están contabilizados (verde, rojo clasificado con disposición, o salto visible con motivo): anotar su `run_id` en Notes. Cierra SC-001, SC-004, SC-006 y SC-009. Si queda un rojo sin clasificar, volver a T031.
- [ ] T035 [US3] **COMPUERTA** (opcional; requiere T026 y confirmación del operador): línea base local arm64 de los 48 e2e, secuencial y fuera de horas de uso: `DOCKER_E2E=1 bats --tap --timing tests/docker-e2e-*.bats > /tmp/e2e-local.tap 2>&1` (30 a 90 minutos). Compararla con la clasificación de CI para atribuir rojos a la arquitectura (amd64 contra arm64) y anotar el resultado en Notes. No bloquea nada: es solo un comparador.

**Checkpoint**: US3 completa; el nightly pasó de ciego a una señal con cada rojo explicado.

---

## Phase 6: Polish & Cross-Cutting

**Purpose**: documentación, mutaciones, gates y cierre.

- [ ] T036 [P] `CHANGELOG.md` (redactar en paralelo y **cerrar tras T034**: la entrada afirma E1 y E3 corregidos, que solo se verifican en T030 o en la corrida de T034): entrada bajo `## [Unreleased]`, en el estilo (inglés) de las entradas vecinas, que diga: el nightly `docker-e2e` abortaba a los pocos segundos en el paso de verificación por SIGPIPE (`docker info | head -10` bajo `pipefail`) y no ejecutaba ningún e2e; el paso ahora no usa pipe y muestra versión de servidor y arquitectura; el paso de la suite imprime un resumen y termina en rojo si no se ejecutó ningún e2e; `tests/ci-workflows.bats` ejecuta los pasos reales contra un `docker` falso y un ratchet prohíbe los consumidores que cierran el pipe antes de tiempo en los workflows; E1 y E3 de 031 corregidos. Dejar escrito **sin cambio de runtime y sin bump de `VERSION`** (precedente 019 y 025).
- [ ] T037 [P] `CLAUDE.md`, a mano (redactar en paralelo y **cerrar tras T034**: el estado final incluye la clasificación y la corrida de cierre): llevar la entrada de 039 a su estado final y agregar un viñeta en "Common gotchas", después de la de `PRODUCER | grep -q`, sobre los `run:` de workflows: un `| head` bajo `pipefail` falla con 141 cuando el productor escribe tras el cierre (`docker info` lo hacía siempre), el shell por defecto de Actions es `bash -e {0}` sin `pipefail` salvo que el script lo active, y `tests/ci-workflows.bats` ejecuta el paso real y barre los workflows. No tocar el resto del bloque SPECKIT ni sus marcadores; nunca ejecutar el hook de contexto de agente.
- [X] T038 Mutación M1 (quickstart §2, SC-003): sobre una copia de seguridad de `.github/workflows/docker-e2e.yml` (`cp` a `/tmp`), reintroducir `docker info | head -10` en el paso de verificación y correr `tests/ci-workflows.bats`: deben ponerse rojos **O3** (estado 141) y **R3**. Restaurar con `cp` y confirmar con `cmp`. Anotar el resultado en Notes.
- [X] T039 Mutación M2: reemplazar la línea de `docker info --format …` por la misma con `|| true` al final: debe ponerse rojo **O4** (con Docker caído el paso ya no falla). Restaurar y anotar.
- [X] T040 Mutación M3, en dos corridas: quitar `arch={{.Architecture}}` de la plantilla de `--format` y, tras restaurar, quitar `server={{.ServerVersion}}`: en **ambas** debe ponerse rojo **O3** (faltan `arch=x86_64` o `server=27.5.1` en la salida; la segunda es la que cierra C1, porque con el servidor igual al cliente habría sobrevivido). Restaurar y anotar.
- [X] T041 Mutación M4 (SC-007): quitar de la suite la guarda `if [ "$executed" -eq 0 ]` (el bloque completo): deben ponerse rojos **S1** y **S2**. Restaurar y anotar.
- [X] T042 Mutación M5: quitar `DOCKER_E2E: '1'` del `env:` del paso de la suite: debe ponerse rojo **S6**. Restaurar y anotar.
- [X] T043 Mutación M6: reemplazar `exit "$rc"` por `exit 0` en el paso de la suite: deben ponerse rojos **S4** y **S5**. Y, en corridas aparte, estrechar el glob a `tests/docker-e2e-smoke.bats`, ensancharlo a `tests/*.bats` y quitar `--tap`: en cada una debe ponerse rojo **S3** (FR-004). Restaurar tras cada una y anotar.
- [X] T044 Mutación M7: agregar `| head -1` a cualquier línea con un comando de un paso de `.github/workflows/test.yml` (sobre una copia de seguridad): debe ponerse rojo **R3**. Restaurar y anotar. **Si alguna de M1 a M7 sobrevive** (ningún test se pone rojo), endurecer el oráculo antes de seguir y registrarlo, como en 033 y 034. Las siete tocan los mismos archivos: secuenciales, nunca en paralelo.
- [ ] T045 Auditoría de bytes de todo lo creado o editado (`tests/ci-workflows.bats`, `tests/fixtures/ci/*`, `tests/docker-e2e-askq-guard.bats`, los dos workflows, `CHANGELOG.md`, `CLAUDE.md` y los `.md` de la feature): `LC_ALL=C grep -c $'\xcc\x80'` en 0 y `iconv -f UTF-8 -t UTF-8` sin error; los fixtures y los workflows, además, en ASCII salvo los textos que ya traigan acentos.
- [X] T046 (FR-009) Gates finales: `bats tests/` en bash 5.x y luego `PATH=/bin:$PATH bats tests/` en 3.2.57, secuenciales; esperado **1817 ok y 0 not ok** en ambos (1803 más 14), con los saltos de siempre; y `shellcheck -S error -e SC1090,SC1091` con el comando **exacto** del job de CI (`find` más `xargs`, ver `quickstart.md` §3) en rc 0 y sin salida. Anotar conteos y duraciones en Notes.
- [X] T047 Alcance acotado (FR-015, SC-008): `git diff --stat origin/main..HEAD -- docker scripts modules setup.sh` debe estar vacío; `yq '.permissions' .github/workflows/docker-e2e.yml` sigue en `contents: read`; `git diff origin/main..HEAD -- .github/workflows > /tmp/wf.diff` y `grep -c 'secrets\.' /tmp/wf.diff` da 0 (sin secretos nuevos, SC-008; sin pipe); tras `git fetch origin`, `git show origin/main:VERSION` es igual a `cat VERSION`. Si `main` avanzó, rebasar y **volver a verificar `VERSION` a mano** (la lección de 023: git no avisa de ese conflicto semántico).
- [ ] T048 **COMPUERTA** (requiere confirmación explícita del operador): commit final y PR. Staging archivo por archivo (nunca `git add -A`), commits adicionales a los de T020 con mensaje ASCII, push con el helper de `gh`, y `gh pr create` contra `main` con un cuerpo que incluya la tabla de gates (T046), el resumen de la clasificación (T031) con el `run_id` de la corrida de cierre (T034), las mutaciones (T038 a T044) y los pendientes. El PR no se mergea antes de T034.
- [ ] T049 **COMPUERTA** (posterior al merge; requiere esperar tres noches): SC-002. Registrar en Notes los ids de las tres corridas nocturnas siguientes y comprobar que ninguna aborta en el paso de verificación: `for id in …; do gh run view "$id" --log | grep -c 'exit code 141'; done` debe dar 0 en cada una. Un rojo por otra causa es válido y debe estar clasificado en la tabla de T031.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (T001-T004)**: T001 primero (verifica la base); T002, T003 y T004 en paralelo entre sí (archivos distintos).
- **Foundational (T005-T010)**: después de T002 a T004 (los tests O2, R1 y R2 usan los fixtures). Bloquea todas las historias.
- **US1 (T011-T020)**: después de Foundational. T020 es una COMPUERTA.
- **US2 (T021-T025)**: después de Foundational; R3 (T021) solo queda en verde tras T016 (arreglo de `docker-e2e.yml`) y T023 (arreglo de `test.yml`).
- **US3 (T026-T035)**: T028 y T029 pueden escribirse en cualquier momento (no necesitan Docker), pero su demostración exige T026 o la corrida de CI; T031 depende de T020; T033 a T035 dependen de las COMPUERTAS.
- **Polish (T036-T049)**: después de las historias que se entreguen. Las mutaciones (T038-T044) después de US1 y US2. T036 y T037 se cierran tras T034; T048 después de T046 y T047; T049 solo tras el merge.

### Dependencias dentro de las historias

- RED antes de GREEN, siempre: T011→T016, T013→T017, T014→T017, T021→T023.
- Mismo archivo, secuencial: `tests/ci-workflows.bats` (T005→T006→T007→T008→T009→T011→T012→T013→T014→T021); `.github/workflows/docker-e2e.yml` (T016→T017→T033→T038 a T043); `.github/workflows/test.yml` (T023→T044); `tests/docker-e2e-askq-guard.bats` (T028→T029).
- El checkpoint RED (T015) antes de T016; el checkpoint RED de R3 (T022) antes de T023.

### COMPUERTAS (nada de esto corre sin confirmación del operador)

| Compuerta | Tareas que dependen | Qué se autoriza |
|-----------|---------------------|-----------------|
| Push de la rama y `workflow_dispatch` | T020, T033, T034 (T031 solo lee los logs que estas generan) | Commit local, pushes normales (sin `--force`) de la rama `039-fix-nightly-e2e-sigpipe` por HTTPS con el helper de `gh`, y despachos del workflow sobre ella hasta cerrar T034; el token ya tiene el scope `workflow`. Un `--force`, un push a otra rama o cualquier otra acción se vuelve a consultar |
| Docker Desktop local | T026, T027, T030, T035 | Arrancar Docker Desktop (hoy apagado, Mac cargado) para verificar E1 y E3 y, opcional, medir la línea base local |
| Commit final y PR | T048 | Commits adicionales, push y `gh pr create` |
| Tiempo (esperar noches) | T049 | Observar tres nocturnas tras el merge |

### Parallel Opportunities

- Setup: T002, T003 y T004 en paralelo.
- US1 GREEN y US2 GREEN: T023 (`test.yml`) en paralelo con T016 y T017 (`docker-e2e.yml`) una vez escrito T021.
- US3: T028 y T029 (`tests/docker-e2e-askq-guard.bats`) en paralelo con cualquier tarea de otro archivo; entre sí son secuenciales.
- Polish: T036 y T037 en paralelo; T025 en paralelo con T036 y T037.

---

## Parallel Example: Setup y primeras ediciones

```bash
# Setup en paralelo (archivos distintos):
T002 tests/fixtures/ci/step-verify-with-defect.sh
T003 tests/fixtures/ci/tap-*.tap
T004 tests/fixtures/ci/ratchet-bad.yml  tests/fixtures/ci/ratchet-good.yml

# GREEN en paralelo, una vez escritos T011, T013 y T021 (RED confirmado en T015 y T022):
T016+T017 .github/workflows/docker-e2e.yml   # secuenciales entre si
T023      .github/workflows/test.yml
```

---

## Implementation Strategy

### MVP (US1)

1. Setup y Foundational: el arnés queda probado y se ve que puede fallar (O2) antes de usarlo.
2. US1: RED visible (O3, S1 a S4), luego el arreglo del paso de verificación y la reestructuración del paso de la suite. Con eso el nightly ya no puede morir por el pipe ni dar un verde vacío.
3. Validar en un runner real (T020, COMPUERTA) antes de seguir con la triage.

### Entrega incremental

1. US2: el oráculo se vuelve permanente (R3 y el ratchet) y la auditoría queda escrita.
2. US3: clasificar los rojos reales de la primera corrida y tratar cada uno; E1 y E3 ya tienen causa fundada.
3. Polish: mutaciones, gates dual y PR. Si la triage de US3 se alarga, la política clarificada permite aislar con seguimiento lo que exceda un arreglo acotado, en vez de bloquear el PR.

---

## Notes

Estado al 05-10-2026: tareas generadas, ninguna ejecutada. Spec clarificado el 05-10-2026 (dos preguntas, ambas con la opción recomendada) y plan completo con mediciones M1 a M8 en `research.md`.

- **Compuertas abiertas al generar las tareas**: ningún push autorizado; Docker Desktop apagado y el Mac con carga ~9 por aplicaciones del usuario; el token de `gh` ya tiene el scope `workflow`. Hasta que el operador las abra, solo se hace lo local (T001 a T019, T021 a T025, T028, T029 y T038 a T047; T036 y T037 se redactan en local y se cierran tras T034).
- **Pregunta (c) de Fase 0** (cuántos e2e fallan realmente): sin medir. Se mide por CI en la primera corrida real (T031) y, opcionalmente, en local (T035).
- **Cobertura reducida por diseño, no es un salto**: `qmd real (016)` corre su Tier A y pasa sin ejercer el embed si falta `QMD_EMBED_E2E=1`; no aparece como `# skip`. Cambiarlo queda fuera de alcance.
- **Riesgo declarado (D3)**: los nombres de campo de `docker info --format` se validan contra el stub, no contra un Docker real; la validación real es T020.
- A completar durante la implementación, con fecha: evidencia RED (T015, T022), cambio de 1 de 3 a 3 de 3 en `docker-e2e-askq-guard.bats` (T030), tabla de la primera corrida real (T031), disposiciones y seguimientos (T032), duración medida (T033), corrida de cierre (T034), mutaciones (T038 a T044), gates (T046), las tres nocturnas posteriores al merge (T049).

### Implementación local (08-10-2026)

Hecho el 08-10-2026 con la rama en el commit `182f99b` (spec-kit) sobre `da22a06`. Al redactar esta sección las compuertas seguían cerradas: nada se había empujado, no se había despachado ningún workflow y no se había corrido ningún e2e en Docker (la apertura de T020 está en la sección siguiente).

- **Línea base (T001)**: tras `git fetch`, `origin/main` sigue en `da22a06` (0.28.0) y `VERSION` coincide. La CI de `main` sobre ese commit dio verde (bats en ubuntu con bash 5.x, en macOS con bash 3.2, y shellcheck); el gate local de 038 midió 1803 de 1803 en ambos bash sobre un árbol idéntico. Esperado final: **1817** (1803 más los 14 de `tests/ci-workflows.bats`; el gate preliminar de T046 arrancó con el plan `1..1817`).
- **El nightly desde el spec (medido el 08-10-2026 con `gh run list`)**: las 8 corridas que lista `gh`, del 30-09 al 07-10-2026, terminan en `failure`. Las tres que no estaban medidas (36706081124 del 30-09, 37459497257 del 06-10 y 37615490227 del 07-10) mueren en el paso `Verify deps + docker` con `Process completed with exit code 141`, a los 6, 9 y 6 s. Son ocho noches seguidas sin un solo e2e ejecutado. Las cinco corridas del spec (01 a 05-10) siguen siendo las medidas con detalle; estas tres solo confirman el mismo paso y el mismo código.
- **Fixtures y arnés (T002 a T010)**: `tests/fixtures/ci/step-verify-with-defect.sh` (11 líneas, empieza con `set -euo pipefail`, contiene `docker info | head -10` una vez, `cmp` idéntico a la extracción del workflow de entonces y al prototipo medido en Fase 0), cuatro TAP y dos workflows de ratchet. El arnés vive dentro de `tests/ci-workflows.bats`. Checkpoint T010: **5 de 5** (O1, O2, O5, R1, R2) en bash 5.3.15 y en bash 3.2.57. O2 se reforzó respecto del contrato: además del estado 141 y la ausencia del centinela, exige `client line 10` y no `client line 11` en la salida, lo que ata el 141 a `head -10` y no a otra causa.
- **Evidencia RED (T015)**: con los 13 tests escritos y el workflow sin tocar, fallan **exactamente** O3, S1, S2, S3 y S4 (5 `not ok`) y pasan O1, O2, O4, O5, S5, S6, R1 y R2 (8 `ok`), idéntico en bash 5.3.15 y en 3.2.57. Motivos: **O3** estado 141 (la salida termina en `client line 10`: `head` cerró y `docker info` murió); **S1 y S2** estado 0 en vez de 1 (el verde vacío es real: con todo saltado o `1..0` el paso actual llega a su último comando); **S3 y S4** falta la línea `e2e summary:`. S5 (127), S6 (`DOCKER_E2E` igual a `1`) y O4 (Docker caído sigue fallando) pasan hoy: son las guardas.
- **GREEN (T016 a T018)**: con `docker-e2e.yml` corregido, O3 y S1 a S4 pasan a verde. Con R3 ya escrito, el resultado fue 13 `ok` y R3 en rojo, como estaba previsto.
- **R3 en rojo (T021, T022)**: tras T016 y T017, R3 lista **exactamente dos líneas**, ambas del paso `Verify deps + pin the bash target (025/023: never run an assumed version)` de `test.yml` (`bash --version | head -1` y `/bin/bash --version | head -1`). Antes de T016 el barrido mostraba cuatro (esas dos más `bash --version | head -1` y `docker info | head -10` de `docker-e2e.yml`): coincide con la auditoría de D5.
- **GREEN final del oráculo (T023, T024)**: **14 de 14** en bash 5.3.15 y en 3.2.57, sin avisos de bats. `test.yml` parsea y sus 9 nombres de pasos son idénticos a los de `origin/main`.
- **Invariantes de `docker-e2e.yml` (T019)**: parsea; 5 pasos y 4 con `run:`; `permissions` sigue en `contents: read`; `timeout-minutes` sigue en 30; las expresiones `${{` pasan de 0 a 0.
- **Comprobaciones contra un motor real, solo lectura (extra, 08-10-2026)**: Docker Desktop 29.8.0 acepta los cinco campos de la plantilla (`server=29.8.0 os=Docker Desktop arch=aarch64 cgroup=2 storage=overlayfs`), y el paso corregido, extraído del workflow y ejecutado tal cual contra ese motor, termina en 0 con bash 5.3.15 y con 3.2.57. El defecto contra el mismo motor (`set -euo pipefail; docker info | head -10`) dio 141 en 1 de 5 corridas: el daemon local responde rápido, así que la carrera casi no se da; en el runner el log muestra 141 siempre. Esto reduce el riesgo declarado en D3 pero no lo elimina (el runner trae Docker 28.0.4): la validación real sigue siendo T020.
- **Auditoría de FR-010 y SC-005 (T025)**: 14 pasos `run:` en los tres workflows (`docker-e2e.yml` 4, `shellcheck.yml` 2, `test.yml` 8); ninguno fija `shell:`, así que rige `bash -e {0}` sin `pipefail`, que solo activa el script (10 de 14 lo hacen). Cinco pipes reales: `docker info | head -10` (**defecto, fallaba siempre; eliminado**), `bash --version | head -1` en `docker-e2e.yml` y las dos de `test.yml` (`bash --version | head -1` y `/bin/bash --version | head -1`), seguras por construcción del productor (escribe de una vez y `head` nunca cierra con algo pendiente) pero **eliminadas igual** con `first_line`, para que el ratchet no necesite excepciones; y `{ find; printf; } | xargs shellcheck` (el consumidor lee hasta EOF; seguro, el ratchet no lo marca). Los scripts de los e2e no tienen hallazgos: la única mención de `pipefail` en ellos es un comentario de `docker-e2e-postlogin.bats` que documenta el patrón evitado, y los bloques de `docker-e2e-warm-cache.bats` no tienen consumidor que cierre antes. Una búsqueda ingenua de `|` cuenta además las líneas `brew list ... || brew install ...`, que son `||`. Disposición final: 4 corregidos, 1 seguro justificado, 0 pendientes; R3 lo vigila.
- **E1 y E3 de 031 (T028, T029)**: editados en `tests/docker-e2e-askq-guard.bats` sin cambiar nombres ni aserciones. E1 crea `$HOME/.claude` antes del instalador; E3 se auto-siembra con el fixture `telegram-server-pristine.ts` y el parcheador de la imagen, como `docker-e2e-voice.bats`. **Demostración de la causa en el host, sin Docker**: (E3) el parcheador real aplicado a una copia del fixture pristine produce las tres cadenas que el test busca (`typing refresh patch v6`, `askq-guard give-up delivery patch v1`, `bloqueada en un menú interactivo`), así que lo único que faltaba era el plugin; (E1) el instalador con un `HOME` temporal sin `.claude` no escribe nada (sale 0, fail-silent) y el `jq` del test aborta con 2, y con `mkdir -p` registra `[{"matcher":"AskUserQuestion",...}]`. Sin `DOCKER_E2E` el archivo parsea y salta limpio los 3 tests. **La demostración rojo a verde dentro de la imagen sigue pendiente** (T027 y T030 exigen la compuerta de Docker, o la corrida de CI de T020 y su re-despacho).
- **Mutaciones (T038 a T044), corridas contra la implementación real, una a la vez y con restauración verificada byte a byte**:

  | Mutación | Cazada por | Previsto |
  |----------|------------|----------|
  | M1 reintroducir `docker info \| head -10` en la verificación | O3 y R3 | O3 y R3 |
  | M2 `docker info --format ... \|\| true` | O4 | O4 |
  | M3a quitar `arch=` de la plantilla | O3 | O3 |
  | M3b quitar `server=` de la plantilla (la que cierra C1) | O3 | O3 |
  | M4 quitar la guarda `executed -eq 0` | S1 y S2 | S1 y S2 |
  | M5 quitar `DOCKER_E2E` del `env:` | S6 | S6 |
  | M6 `exit "$rc"` por `exit 0` | S4 y S5 | S4 y S5 |
  | M6b glob estrecho `tests/docker-e2e-smoke.bats` | S3 | S3 |
  | M6c glob ancho `tests/*.bats` | S3 | S3 |
  | M6d quitar `--tap` | S3 | S3 |
  | M7 agregar `\| head -1` en `test.yml` | R3 | R3 |
  | M8 `bash --version \| head -1` en `docker-e2e.yml` (propia) | R3, y solo R3: el ratchet es una capa distinta de la ejecución | R3 |
  | M9 quitar `set -euo pipefail` de la suite (propia) | S4 y S5 | S4 y S5 |
  | M10 quitar `\|\| true` del `grep -c` de `total` (propia) | S2 y S5 | S2 |

  Las 14 mutaciones fueron cazadas por los tests previstos (M10 además por S5, que tampoco produce salida) y ninguna sobrevivió, así que no hizo falta endurecer el oráculo. M2 a M10 se aplicaron con un controlador que se niega a aplicar una mutación cuyo blanco no coincide exactamente una vez; M1 se aplicó con una variante de ese controlador.
- **Auditoría de bytes (T045, primera pasada)**: sin marcas combinantes, sin bytes de control y UTF-8 válido en `tests/ci-workflows.bats`, `tests/docker-e2e-askq-guard.bats`, los dos workflows y todos los fixtures. Solo hay no-ASCII donde ya lo había (el guion largo de un comentario de `docker-e2e.yml` y las líneas de `test.yml`) y en los separadores de sección de los comentarios de `tests/ci-workflows.bats`, el mismo estilo que el resto de `tests/`. Se repite al cerrar T036 y T037.
- **Alcance (T047, sobre el árbol de trabajo; se repite sobre `HEAD` en T048)**: `git diff --stat origin/main -- docker scripts modules setup.sh` vacío; `permissions` en `contents: read`; cero apariciones de `secrets.` en el diff de los workflows; `VERSION` igual a `origin/main` (0.28.0).
- **Hallazgos de implementación**: (1) el hook `protect-secrets` bloqueó dos comandos propios porque un texto contenía la forma de acceso a una clave de objeto que su patrón toma por un archivo de secretos (falso positivo): se reescribieron sin esa construcción en vez de rodear el hook. (2) bats 1.13 avisa (BW01) cuando un `run` termina en 127; S5 lo espera a propósito, así que `_run_step` acepta un `-N` inicial y el archivo exige `bats_require_minimum_version 1.5.0` (CI instala bats 1.11). (3) La carga del Mac bajó de 15,3 a ~6,6 entre la consulta de estado y el inicio del gate preliminar.

### Gates finales y apertura de la compuerta T020 (08-10-2026)

- **T046, gate completo y secuencial** sobre el árbol de trabajo de la rama (HEAD `182f99b` más los cambios locales de esta feature), de 15:49 a 16:30, con el Mac a carga entre 6 y 14 por aplicaciones del usuario:

  | Brazo | Resultado | Duración |
  |-------|-----------|----------|
  | `shellcheck -S error -e SC1090,SC1091`, comando exacto del job de CI | rc 0, sin salida | segundos |
  | `bats --tap tests/` con bash 5.3.15 | plan `1..1817`, **1817 ok, 0 not ok**, 54 saltos, stderr vacío | 1186 s |
  | `PATH=/bin:$PATH bats --tap tests/` con bash 3.2.57 | plan `1..1817`, **1817 ok, 0 not ok**, 55 saltos, stderr vacío | 1281 s |

  Los saltos de siempre: en bash 5.x son 48 e2e sin `DOCKER_E2E` más 6 por `flock` o `timeout` ausentes en el host; en 3.2 hay uno más, el test de `qmd_watch` que exige que `read -t` devuelva más de 128, algo que bash 3.2 no cumple y que el propio test declara. Los 14 tests de `tests/ci-workflows.bats` (puestos 385 a 398 del plan) pasaron sin saltos en los dos brazos. Los dos brazos listan los mismos 1817 nombres de test.
- **Una edición durante el gate, cerrada**: `tests/ci-workflows.bats` se editó a las 15:56:47 (texto de la cabecera y una aserción de R1 sobre YAML no parseable), siete minutos después de iniciar el gate (15:49:22). El brazo de bash 5.x pudo ejecutar la versión anterior del archivo, porque el TAP no lo distingue; el de 3.2, que arrancó a las 16:09:21, ejecutó la nueva. Los otros archivos tocados durante el gate (`CHANGELOG.md`, `CLAUDE.md` y este `tasks.md`) no los lee ningún test: en `tests/` no hay menciones de `CHANGELOG` y las de `CLAUDE.md` son fixtures y el esqueleto del vault, no el de la raíz del repositorio. Se cerró volviendo a correr ese único archivo con el gate ya terminado: **14 de 14** en bash 5.3.15 y en 3.2.57, 0 saltos, stderr vacío.
- **Paridad Linux, autorizada solo para el oráculo**: contenedor `ubuntu:24.04` (aarch64, Docker Desktop 29.8.0) con bats 1.11.0, yq v4.44.3, jq 1.7 y bash 5.2.21, usuario no root y el repositorio montado en solo lectura: **14 de 14**, 0 saltos. Se descargó la imagen base pública `ubuntu:24.04`; no se construyó ninguna imagen del proyecto ni se corrió ningún e2e. Es aarch64 y el runner de CI es amd64, que solo se verá en la corrida real.
- **Auditoría de bytes (T045, segunda pasada, con Python para no depender del locale)**: sin marcas combinantes, sin bytes de control y UTF-8 válido en `tests/ci-workflows.bats`, `tests/docker-e2e-askq-guard.bats`, los dos workflows, `CHANGELOG.md`, `CLAUDE.md`, este archivo y los siete fixtures. Los dos workflows no ganaron ningún carácter no ASCII (0 de 36 líneas agregadas); los fixtures son ASCII puro; `tests/ci-workflows.bats` solo trae los separadores de sección. T045 sigue abierta hasta cerrar T036 y T037, que vuelven a editar `CHANGELOG.md` y `CLAUDE.md`.
- **Apertura de T020**: con T046 en verde y la paridad hecha se cumplió la condición de la autorización del operador (08-10-2026: dos commits locales y dos corridas, pushes normales de esta rama sin `--force` y despachos de este workflow, nada más). El commit 1 lleva los workflows, el oráculo, los fixtures y estas notas, **sin** el arreglo de E1 y E3 (`tests/docker-e2e-askq-guard.bats`), para que la primera corrida real muestre ese rojo en amd64; el commit 2 lo corrige y su re-despacho muestra el verde. Base verificada con `git fetch` a las 16:26: `origin/main` sigue en `da22a06` y `VERSION` en 0.28.0.

### Primera corrida real del nightly (08-10-2026)

- **T020, evidencia**: el commit 1 (`a111361`) se empujó a `039-fix-nightly-e2e-sigpipe` por HTTPS con el helper de `gh`, sin `--force`, y a las 16:49 (hora de Santiago) se despachó `docker-e2e.yml` sobre esa rama: **run_id 37834784760** (`workflow_dispatch`, ubuntu-latest, amd64). La rama no tiene PR.
  - Paso `Verify deps + docker`: **verde en 5 s**; antes moría con 141 entre 6 y 13 s. Imprime bash 5.2.21, bats 1.11.0, yq v4.44.3, jq 1.7, git 2.55.0, tmux 3.4, Docker 28.0.4, Compose v2.38.2 y `server=28.0.4 os=Ubuntu 24.04.5 LTS arch=x86_64 cgroup=2 storage=overlay2`. El Docker real del runner acepta los cinco campos de la plantilla de `--format`: el riesgo declarado en D3 queda cerrado.
  - Paso `Run docker-e2e suite`: **arrancó y corrió 15 min 40 s** (el job completo, 15 min 52 s, con tope de 30). Terminó con `e2e summary: total=48 executed=48 skipped=0 failed=3` y salida 1. No hizo falta subir `timeout-minutes` (FR-016), y la guarda de verde vacío no intervino: los 48 tests corrieron y los tres rojos son de tests reales.

Corrida: run 37834784760 (workflow_dispatch, 039-fix-nightly-e2e-sigpipe, a111361) — e2e summary: total=48 executed=48 skipped=0 failed=3

| Test | Archivo | Estado | Causa | Tipo | Evidencia | Disposición | Seguimiento |
|------|---------|--------|-------|------|-----------|-------------|-------------|
| E2E 031: pre_install_askq_hook registers PreToolUse+AskUserQuestion in settings.json at boot (puesto 1, E1) | docker-e2e-askq-guard.bats | not ok | El arnés invoca el instalador con `--entrypoint sh`, que salta `start_services.sh`; `$HOME/.claude` no existe, el instalador fail-silent no escribe `settings.json` y el `jq` siguiente aborta. Es la causa fundada el 05-10-2026 por lectura de código, ahora confirmada por el log. | arnés | run 37834784760: "install-askq-guard-hook.sh: line 29: /home/agent/.claude/settings.json: No such file or directory" y "jq: error: Could not open file /home/agent/.claude/settings.json" | corregido en el commit 2 (crear `$HOME/.claude` antes del instalador); por verificar con el run en verde (R4) | T028, T030 |
| E2E 031: the patched plugin server.ts carries typing v6 + the askq give-up hunk (puesto 3, E3) | docker-e2e-askq-guard.bats | not ok | La imagen no trae el plugin de Telegram (se instala tras el login) y el test lo busca con `find`. Causa fundada el 05-10-2026, confirmada por el log. | arnés | run 37834784760: "find: /home/agent/.claude/plugins/cache/claude-plugins-official/telegram: No such file or directory" | corregido en el commit 2 (auto-sembrar el fixture como `docker-e2e-voice.bats`); por verificar con el run en verde (R4) | T029, T030 |
| qmd e2e: first-boot setup, watcher+cron wiring, reindex on vault change, caps intact (puesto 12) | docker-e2e-qmd.bats | not ok | **Sin diagnosticar.** Falla la aserción de la línea 240, exigida solo en Linux: tras escribir `watch-note.md`, el contador `runs` de `qmd-index.json` no superó en 60 s el valor posterior al reindex manual (1), así que el vigilante de inotify no produjo un reindex visible. Las fases 1 a 3 del mismo test pasaron (setup, vigilante vivo, línea de cron, reindex manual). No hay causa medida: el test no vuelca nada del contenedor al fallar en esa fase y `start_services.sh` lanza el vigilante con `>/dev/null 2>&1`, que descarta sus propios logs. En macOS esa aserción es blanda (`\|\| echo note`), así que ninguna corrida local pudo exigirla. Intermitencia sin medir (R6). | por determinar | run 37834784760: "# (in test file tests/docker-e2e-qmd.bats, line 240)  `[ "$watcher_fired" -eq 1 ]' failed" | por determinar (R2: si resulta ser de producto, se escala y no se corrige aquí) | por abrir |

Verificación de R1: tres filas = `failed=3`. Los otros 45 tests pasaron en amd64. T031 y T032 siguen abiertas: faltan la causa del tercer rojo y la verificación de los dos primeros con la corrida de cierre (T034).

### Segunda corrida real del nightly (08-10-2026)

- **T020, re-despacho**: el commit 2 (`fad0b7b`) se empujó (`a111361..fad0b7b`, push normal por HTTPS con el helper de `gh`, sin `--force`) y a las 22:05 (hora de Santiago) se despachó `docker-e2e.yml` sobre la rama: **run_id 37868087664** (`workflow_dispatch`, ubuntu-latest, amd64, sha `fad0b7b`). La rama sigue sin PR. Con este despacho quedaron usadas las dos corridas que autorizó el operador; una tercera, o cualquier otro push, se vuelve a consultar.
- **Resultado**: `Verify deps + docker` verde en 1 s. `Run docker-e2e suite` de 01:06:03Z a 01:22:30Z: **16 min 27 s** (la primera corrida, 15 min 40 s). `e2e summary: total=48 executed=48 skipped=0 failed=1` y salida 1. Pasan de 45 a 47 verdes.
- **T033, N/A**: las dos corridas caben en el tope de 30 minutos (15:40 y 16:27, algo más de la mitad), así que no se sube `timeout-minutes` (FR-016). Son dos mediciones; la variación entre ellas fue de 47 s.
- **R4 cumplido para E1 y E3**: en esta corrida, sobre el mismo tipo de runner (amd64) donde fallaron, pasan `ok 1 E2E 031: pre_install_askq_hook registers PreToolUse+AskUserQuestion in settings.json at boot` y `ok 3 E2E 031: the patched plugin server.ts carries typing v6 + the askq give-up hunk` (E2 seguía verde). RED en el run 37834784760 y GREEN en el 37868087664; entre ambos cambian el arreglo de `tests/docker-e2e-askq-guard.bats` y el volcado de `docker-e2e-qmd.bats`, que solo corre cuando falla esa aserción. `docker-e2e-askq-guard.bats` pasa de 1 de 3 a **3 de 3** (puestos 1 a 3 de la suite). Se cumple así el camino por CI previsto para US3: T026, T027 y T030 (Docker local) se omiten, porque el RED y el GREEN salen de estas dos corridas; Docker local no se arrancó.
- **Causa del rojo de qmd (puesto 12), medida con el volcado del run 37868087664** (alta confianza; la confirmación definitiva es un run en verde con la corrección). Falla la misma aserción de antes (`[ "$watcher_fired" -eq 1 ]`, ahora en la línea 273 por las líneas agregadas). Lo que mostró el volcado, en el orden en que se descartan las hipótesis:
  - **El vigilante vive y inotify funciona.** Procesos: `bash /opt/agent-admin/scripts/qmd_watch.sh` (pid 1001, el del pidfile) y su `inotifywait -r -m -q -e modify,create,delete,move /home/agent/.vault` (pid 1049); límites de inotify en 655360 watches y 1280 instancias. La sonda cruda de `inotifywait` vio `CREATE probe-note.md` por una escritura hecha dentro del contenedor. Quedan descartados un vigilante muerto, un límite agotado y un montaje que no entrega eventos.
  - **El vigilante nunca lanzó un reindex.** `qmd-index.json` no cambió en los 60 s ni en los 45 s extra (`runs` 1, `last_run` `2026-10-09T01:12:06Z`, `pending` 0) y `engine-calls.log` trae exactamente dos pares `update` y `embed`: el del setup (con `collection add`) y uno de reindex.
  - **Ese único estado lo escribió la fase 3 del propio test.** `_qmd_setup_locked` no llama a `qmd_write_state` (`scripts/lib/qmd_index.sh`), y un `qmd-reindex` manual sin estado previo hace `update`, `embed` y escribe `runs` 1, `indexed`, `pending` 0, campo por campo lo que muestra el volcado. La fase 3 terminó, entonces, a las 01:12:06Z.
  - **El vigilante nació 15 s después.** El log del contenedor dice `[2026-10-09 01:12:21] [start_services] qmd watcher started (pid 1001)`. `main()` de `docker/scripts/start_services.sh` llama a `qmd_watch_start` recién cuando `start_initial_session` volvió, y esa llamada incluye el registro del marketplace (de 01:12:06 a 01:12:18: 12 s hasta el aviso `official marketplace registration failed or timed out`) y el lanzamiento de `claude`.
  - **Conclusión**: el test escribió `watch-note.md` unos segundos después de las 01:12:06, del orden de 12 s antes de que existiera el vigilante (la hora exacta de la escritura no consta: el log de bats se imprime al terminar el test; la acota el estado más tres `exec`). inotify no repite eventos anteriores al `watch` y nadie volvió a escribir en el vault, así que no había nada que detectar. El test competía contra el arranque: con el stub del motor las fases 1 a 3 terminan en segundos y el vigilante tarda unas decenas de segundos en el runner.
  - **Por qué la fase 2 ("vigilante vivo") no lo detuvo**: pasó sin ningún vigilante en marcha. Medido con bats real: un `[[ ]]` intermedio falso hace fallar el test en bash 5.3.15 (y no en 3.2); el runner trae 5.2.21, que no se midió, pero lo esperable es que se comporte igual. Entonces `pgrep -f qmd_watch.sh` devolvió algo, y lo más probable es que haya sido el propio `sh -c` que lleva la orden, que nombra el script en su `argv`. **Eso último es inferencia**: en macOS el mismo experimento no encuentra al padre (el pgrep de BSD lo excluye) y busybox no se midió.
- **Tipo: arnés**; R2 no se activa. **Lo que el volcado no demuestra** es que el vigilante reaccione a una escritura hecha después de arrancar: la sonda midió el kernel, no al vigilante (su escritura ocurrió al final y los logs se imprimieron antes de que venciera el debounce de 15 s). Por eso la disposición no puede darse por "corregido" hasta ver un run en verde, y por eso el volcado ahora espera 20 s tras la sonda y vuelve a imprimir `qmd-index.json` y `engine-calls.log`: si un rojo futuro llega con el vigilante vivo desde antes de la escritura, esas líneas separan "no reacciona" (producto, R2) de "carrera".
- **Observación de producto, sin tocar (FR-015)**: el vigilante empieza a cubrir el vault cuando termina el arranque de la sesión inicial (31 s después de `docker compose up` en este runner, 12 de ellos por el registro del marketplace). Un cambio anterior espera al cron de respaldo `*/5`, que `start_services.sh:192-194` declara como backstop. Es una característica de diseño acotada, no un defecto. Si el operador quiere que el vigilante arranque antes, es otra feature.
- **Corrección preparada, en el árbol de trabajo y sin commit ni corrida**: en `tests/docker-e2e-qmd.bats`, la fase 2 sondea hasta 120 s la vida real del vigilante (pidfile con `kill -0` más `inotifywait` en `ps`, con el corchete que impide que la orden se encuentre a sí misma), vuelca los logs del contenedor si no aparece y deja 2 s de margen para que `inotifywait -r` arme sus watches; el volcado gana la espera posterior a la sonda. Ninguna aserción ni nombre de test cambia. Validado en el host sin Docker: el archivo carga y salta limpio en bash 5.x y 3.2, el control de flujo del sondeo (éxito en el intento 3, y timeout con volcado) corrió con un `in_container` simulado en ambos bash, las 27 líneas agregadas son ASCII y no hay marcas combinantes ni bytes de control. **No demostrado**: la combinación de comandos de busybox dentro de la imagen (cada uno aparece funcionando en el volcado, pero juntos nunca corrieron).
- **Riesgo a declarar**: las fases 4.5, 4.6 y 5 de ese mismo test (cron de wiki-graph, paridad entre modos, mínimos privilegios) nunca se ejecutaron en el runner, porque el test aborta antes. En arm64 local pasaron cuando se corrió `DOCKER_E2E` por 037 y no dependen del vigilante, pero una corrida más podría destapar otro rojo detrás de este.
- **Hallazgo de proceso**: un `[[ ]]` intermedio falso no hace fallar un test bats en bash 3.2 pero sí en 5.3.15 (medido con dos tests mínimos y bats real). El mismo test es más estricto en el brazo ubuntu que en el macOS de CI.

Corrida: run 37868087664 (workflow_dispatch, 039-fix-nightly-e2e-sigpipe, fad0b7b) — e2e summary: total=48 executed=48 skipped=0 failed=1

| Test | Archivo | Estado | Causa | Tipo | Evidencia | Disposición | Seguimiento |
|------|---------|--------|-------|------|-----------|-------------|-------------|
| qmd e2e: first-boot setup, watcher+cron wiring, reindex on vault change, caps intact (puesto 12) | docker-e2e-qmd.bats | not ok | Carrera del test con el arranque: escribe `watch-note.md` del orden de 12 s antes de que `start_services.sh` lance el vigilante (lo lanza al volver `start_initial_session`, tras el registro del marketplace), y la verificación de "vigilante vivo" de la fase 2 pasó sin vigilante. inotify no repite eventos previos al `watch`. | arnés | run 37868087664: `"runs": 1`, `"last_run": "2026-10-09T01:12:06Z"`, dos pares `update`/`embed`, `[2026-10-09 01:12:21] [start_services] qmd watcher started (pid 1001)` y, en la sonda cruda, `CREATE probe-note.md` | corregido, por verificar con un run en verde (R4): corrección preparada en el árbol, sin commit | T032 |

Verificación de R1: una fila = `failed=1`; los otros 47 pasaron. Las dos filas rojas de E1 y E3 de la primera corrida quedan **corregidas** (R4: run 37868087664 en verde) y la fila de qmd de la primera tabla se reemplaza por la de esta. T031 queda cerrada: las tres filas tienen causa medida, tipo, evidencia y disposición. T032 y T034 siguen abiertas por qmd: todavía no hay una corrida en la que todos los e2e estén contabilizados con su disposición aplicada.
