---

description: "Tareas de 041-nightly-qmd-embed: el nightly de docker-e2e ejercita el embed real de qmd"
---

# Tasks: El nightly de docker-e2e ejercita el embed real de qmd

**Input**: `specs/041-nightly-qmd-embed/` ([spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [quickstart.md](quickstart.md), [contracts/](contracts/))

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: obligatorios y primero (Principio III; FR-016 y FR-017). Cada test se escribe y se ve en ROJO antes de su implementación, en bash 5.x y en 3.2.

**Organization**: por historia, en orden de **dependencia** sobre los mismos archivos y no de prioridad (precedente de 040):

```text
US2 (P1) → US3 (P2) → US1 (P1) → US4 (P2) → US5 (P2)
```

- US2 va primero porque crea el test que las demás completan.
- US3 va antes que US1 porque la puerta del nightly solo se abre cuando ya existe la obtención de los modelos.

**Compuertas**: cada commit, push, `workflow_dispatch`, issue, PR y merge exige la confirmación explícita del operador, y está marcado COMPUERTA. Nada se commitea antes de T028. No existe ningún hook de contexto de agente que ejecutar (`hooks: {}`).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: se puede hacer en paralelo (archivos distintos, sin dependencia de una tarea abierta)
- **[Story]**: la historia del spec a la que sirve la tarea (US1 a US5)
- Las rutas son relativas a la raíz del worktree `.claude/worktrees/041-nightly-qmd-embed`.

---

## Phase 1: Setup

**Purpose**: medir la línea base y preparar el `curl` falso.

- [X] T001 Medir la línea base de la suite del host en una copia aislada del árbol actual, para que ninguna edición en paralelo la contamine:
  - correr `bats tests/` en bash 5.x y después con `PATH=/bin:$PATH` (bash 3.2.57), en forma secuencial;
  - registrar en las Notes de `specs/041-nightly-qmd-embed/tasks.md` ok, not ok, saltados y duración de cada corrida;
  - registrar el esperado final: línea base más 37 (los 36 del oráculo y el test e2e 041, que en el host sale saltado).

  Antes de medir, revisar `ps` por procesos `bats` ajenos. Si aparece un rojo, se vuelve a medir en aislamiento antes de nombrarlo.
- [X] T002 [P] Crear `tests/fixtures/qmd-e2e/fake-curl` (bash 3.2, ASCII, modo 100755) según `specs/041-nightly-qmd-embed/contracts/host-oracle.md` §2:
  - lee `--output`, `--max-time` y la URL (el argumento que empieza con `http`);
  - aplica el plan de `FAKE_CURL_PLAN`, con líneas `<subcadena de la URL>|<número de llamada para esa URL>|<acción>`. Las acciones son `ok:<archivo>` (copia e imprime `200`), `fail:<rc>`, `pfail:<rc>` (como `fail`, pero deja unos bytes en `--output`: una transferencia cortada a medias), `grow:<archivo>` (copia y agrega un byte), `shrink:<archivo>` (copia y quita el último byte), `flip:<archivo>` (copia y cambia un byte, mismo tamaño) y `hang:<s>` (deja un parcial en `--output`, duerme `min(s, --max-time)` con `/bin/sleep`, el real, y sale con 28). Sin acción que coincida, sale con 7;
  - cuenta las llamadas por URL en un archivo de estado junto a `FAKE_CURL_LOG`;
  - registra cada llamada en `FAKE_CURL_LOG`: una línea por argumento y una línea `---`.

---

## Phase 2: Foundational

**Purpose**: el arnés del oráculo y el asistente común del e2e, que necesitan todas las historias.

**CRITICAL**: ninguna historia empieza antes de cerrar esta fase.

- [X] T003 [P] Crear `tests/qmd-embed-nightly.bats` con el arnés y todavía sin tests (`specs/041-nightly-qmd-embed/contracts/host-oracle.md` §1 y §2). Contiene:
  - `load helper` y `bats_require_minimum_version 1.5.0`;
  - `_has` y `_lacks`;
  - `_step_n FILE JOB NAME` y `_step_get FILE JOB NAME EXPR`, que exige exactamente una coincidencia, como `_extract_run` de 039;
  - `_sha256_file`;
  - `_mk_fake_models` (sin parámetros; fija `SRV`, `M1_FILE`, `M2_FILE`, `M1_BYTES`, `M2_BYTES`, `M1_SHA`, `M2_SHA` y `TABLE`): dos archivos chicos con su sha256 y una tabla `name|repo|file|local_name|bytes|sha256`, con nombres locales que cumplen la regla de data-model §1;
  - `_run_fetch`, que ejecuta `.github/scripts/fetch-qmd-models.sh` con `run --separate-stderr`, un `GITHUB_ENV` temporal, el `curl` falso copiado como `curl` al frente del `PATH` (salvo en F11, que usa el real), un `sleep` falso que registra su argumento en `FAKE_SLEEP_LOG` y vuelve en el acto, y las costuras de los tests. Después de cada ejecución afirma que stdout y stderr son ASCII;
  - `_http_up` y `_http_down`, que levantan `python3 -m http.server --bind 127.0.0.1` en un puerto libre, con los descriptores 3 y 4 cerrados;
  - `_k_stubs`: un `docker` y un `curl` que registran la llamada y salen con 99.

  Verificar que `bats tests/qmd-embed-nightly.bats` termina con rc 0 en los dos bash.
- [X] T004 [P] En `tests/docker-e2e-qmd.bats`, extraer el armado del workspace del test `qmd real (016)` a `_qmd_real_ws DIR NAME IMAGE_TAG` (`specs/041-nightly-qmd-embed/contracts/embed-test.md` §1) y usarlo en ese test sin cambiar ninguna aserción. La versión de qmd de su `agent.yml` sale de `qmd_pkg` (cargando `scripts/lib/qmd_index.sh` en un subshell), no del literal `2.5.3`. Verificar con `bash -n` y que `bats tests/docker-e2e-qmd.bats` sin `DOCKER_E2E` da `1..4` con los cuatro saltados, en los dos bash.

**Checkpoint**: el arnés carga y el e2e se salta limpio sin Docker.

---

## Phase 3: User Story 2 - La cobertura es honesta (Priority: P1), MVP

**Goal**: cuando la fase del embed no corre, la salida lo dice como un salto con motivo y el resumen lo cuenta. `qmd real (016)` conserva su fase A y su detección RED.

**Independent Test**: en el host y sin Docker, K1 a K4. Con la puerta cerrada el TAP trae `# skip` con su motivo y no hay ninguna llamada a `docker` ni a `curl`. Con la puerta abierta y sin modelos, el test falla y nombra `QMD_E2E_MODELS_DIR`.

- [X] T005 [US2] ROJO: escribir K1, K2, K3 y K4 en `tests/qmd-embed-nightly.bats` (`specs/041-nightly-qmd-embed/contracts/host-oracle.md` §3 K). Usan bats anidado sobre `tests/docker-e2e-qmd.bats -f 'qmd real \(041\)'`, con `DOCKER_E2E=1` y los stubs de `_k_stubs`. Correr y registrar en las Notes que los cuatro están en ROJO: K1 a K3 porque el test 041 no existe, y K4 porque el test 016 todavía contiene `QMD_EMBED_E2E`.
- [X] T006 [US2] En `tests/docker-e2e-qmd.bats`:
  - crear el test `qmd real (041): embed phase - setup, models, vector extension, reindex, semantic search, MCP` justo después del 016;
  - sus primeras instrucciones son la puerta, con los tres mensajes literales de `specs/041-nightly-qmd-embed/contracts/embed-test.md` §3.1, en ASCII;
  - su workspace es `_qmd_real_ws "$TMP_TEST_DIR/agent-qmd-embed" qmd-embed agent-admin:qmd-embed`;
  - mover a él el bloque `if [ "${QMD_EMBED_E2E:-0}" = "1" ]` del test 016 sin cambiar sus aserciones (las correcciones son de US3 y US1);
  - quitar el bloque del 016, dejando intactos su nombre y las aserciones de la fase A y del RED;
  - actualizar el comentario de cabecera del archivo.

  K1 a K4 pasan a VERDE.
- [X] T007 [US2] Punto de control en bash 5.x y en 3.2: K1 a K4 en verde; `bats tests/docker-e2e-qmd.bats` sin `DOCKER_E2E` con `1..5` y los cinco saltados; `bats tests/ci-workflows.bats` en 14 de 14 sin editarse. Registrar en las Notes.

**Checkpoint**: el nightly ya no puede dar un verde que esconda el embed. La fase se reporta como ejecutada o como saltada con motivo.

---

## Phase 4: User Story 3 - Una falla de infraestructura no se confunde con una regresión (Priority: P2)

**Goal**: los modelos se obtienen y se verifican en un paso propio con reintentos acotados. Si la obtención falla, la noche queda roja en `fetch_models` y la suite corre igual.

**Independent Test**: en el host, F1 a F5, F8 a F13, G2 y W1, W2, W3, W5, W7 y W8. En CI, la corrida E3 (T034).

- [X] T008 [US3] ROJO: escribir en `tests/qmd-embed-nightly.bats` los tests F1, F2, F3, F4, F5, F8, F9, F10, F11, F12, F13, G2, W1, W2, W3, W5, W7 y W8 (`specs/041-nightly-qmd-embed/contracts/host-oracle.md` §3). W2 y W3 usan los sha256 de research M13. F3 afirma las esperas por defecto en `FAKE_SLEEP_LOG`, F5 el cambio en origen con una sola llamada, F13 el `--max-time` por defecto, y W1 y W5 la ausencia de `continue-on-error`. Correr y registrar en las Notes el ROJO de cada uno.

  W3 y W7 nacen verdes a propósito, porque vigilan que algo no cambie. Los prueban las mutaciones M4 y M6.
- [X] T009 [US3] Crear `.github/scripts/fetch-qmd-models.sh` (modo 100755) según `specs/041-nightly-qmd-embed/contracts/fetch-models-script.md` §1 a §6. Quedan fuera el interruptor de defecto (T015) y `QMD_MODELS_QMD_VERSION` (T020). Incluye:
  - la tabla con los valores literales de data-model §1:
    - `embed|ggml-org/embeddinggemma-300M-GGUF|embeddinggemma-300M-Q8_0.gguf|hf_ggml-org_embeddinggemma-300M-Q8_0.gguf|333590944|b5ce9d77a3fc4b3b39ccb5643c36777911cc4eb46a66962eadfa3f5f60490d63`
    - `expand|tobil/qmd-query-expansion-1.7B-gguf|qmd-query-expansion-1.7B-q4_k_m.gguf|hf_tobil_qmd-query-expansion-1.7B-q4_k_m.gguf|1282438912|000dfb1c06efa6a049e9f64ba921c3740e2454f62abab6fa10e77bd30bb2bcc0`
  - la validación de `QMD_MODELS_BASE_URL`: solo exactamente `https://huggingface.co` o `http://127.0.0.1:<1 a 5 dígitos>`;
  - la validación de `QMD_MODELS_TABLE`: solo con una base local;
  - los valores por defecto: `QMD_FETCH_ATTEMPTS` 3 (de 1 a 5), `QMD_FETCH_BACKOFF_S` `10 30` y `QMD_FETCH_BUDGET_S` 480 (de 1 a 3600);
  - el ciclo de descarga: `.part`, tamaño con `wc -c`, sha256 con `sha256sum` o `shasum -a 256`, y `mv -f` al aceptar. Un tamaño distinto es un intento fallido; el mismo tamaño con otro sha256 es `drift`, sin más intentos;
  - el presupuesto, que también recorta el `--max-time` de cada intento;
  - las salidas `ok`, `failed`, `drift` y `misconfigured` en `$GITHUB_ENV`, con los textos de data-model §2;
  - las líneas de log literales de §4 y §5, todo en ASCII.

  F1 a F5, F8 a F13, G2 y W8 (el script nace con modo 100755) pasan a VERDE.
- [X] T010 [US3] En `.github/workflows/docker-e2e.yml` (`specs/041-nightly-qmd-embed/contracts/workflow-delta.md` §2):
  - agregar `id: verify_deps` a `Verify deps + docker`;
  - agregar el paso `Fetch the qmd models`, con `id: fetch_models`, `run: .github/scripts/fetch-qmd-models.sh` y su comentario, entre la verificación y la suite. Todavía sin `env`: el interruptor es de T016;
  - agregar al paso de la suite `if: ${{ !cancelled() && steps.verify_deps.outcome == 'success' }}` y su línea de comentario. Todavía sin `QMD_EMBED_E2E`: también es de T016.

  W1, W2 y W5 pasan a VERDE, y W3, W7 y W8 siguen en verde. El `run:` de los dos pasos de 039 no cambia.
- [X] T011 [US3] En el test 041 de `tests/docker-e2e-qmd.bats`:
  - definir `_embed_phase`, que imprime `# qmd embed phase: <nombre>` por el descriptor 3;
  - implementar la fase `models-seed` (`specs/041-nightly-qmd-embed/contracts/embed-test.md` §3.2, paso 1): siembra con `ln` o `cp` de los `*.gguf` de `QMD_E2E_MODELS_DIR` en `.state/.cache/qmd/models/`, registro de los inodos con `ls -i` y creación de `DIR/.e2e/seed-marker` después de sembrar;
  - implementar la fase `models-untouched` (paso 8): exactamente los archivos sembrados, con cualquier extensión, con el mismo inodo, y `find <archivo> -newer DIR/.e2e/seed-marker` sin salida. El mensaje de falla es `qmd downloaded or rewrote a model inside the container`.

  Verificar `bash -n`, K1 a K4 en verde y los cinco saltados sin `DOCKER_E2E`.
- [X] T012 [US3] Punto de control en bash 5.x y en 3.2: los 18 tests de T008 en verde, K1 a K4 en verde, `bats tests/ci-workflows.bats` en 14 de 14 y `shellcheck -S error -e SC1090,SC1091 .github/scripts/fetch-qmd-models.sh` en rc 0. Registrar en las Notes.

**Checkpoint**: la obtención es atribuible, acotada e íntegra, y la suite corre aunque falle.

---

## Phase 5: User Story 1 - Una regresión del embed vuelve roja la noche y el log dice qué fase falló (Priority: P1)

**Goal**: el nightly ejecuta la fase del embed. Una regresión deja la noche en rojo y la última marca nombra la fase. Un defecto de producto abierto apaga la fase con un salto que lo nombra.

**Independent Test**: en el host, V1 a V6, P1, W4, W6, F6 y F7. En CI, E1 (T030) y, si E1 es verde, E4 (T035).

- [X] T013 [US1] ROJO: escribir en `tests/qmd-embed-nightly.bats` V1 a V6 (ejecutados con `sh`), P1 (con las anclas por fase y la ausencia de `sqlite-vec-linux-arm64`), W4, W6, F6 y F7 (con sus dos piernas) (`specs/041-nightly-qmd-embed/contracts/host-oracle.md` §3). Correr y registrar en las Notes el ROJO de cada uno.
- [X] T014 [P] [US1] Crear `tests/fixtures/qmd-e2e/vec0-libc.sh` (`#!/bin/sh`, POSIX, ASCII, modo 100755; se invoca con `sh`) según `specs/041-nightly-qmd-embed/contracts/embed-test.md` §4:
  - `MUSL <ruta>` con rc 0;
  - `GLIBC <ruta>` con rc 1, usando `grep -q 'GLIBC_'` sobre el archivo, sin tubería;
  - `ABSENT` con rc 2;
  - `AMBIGUOUS <n>` con rc 3;
  - `usage: vec0-libc.sh PREFIX` con rc 64.

  V1 a V6 pasan a VERDE.
- [X] T015 [P] [US1] En `.github/scripts/fetch-qmd-models.sh`, implementar el interruptor `QMD_EMBED_DEFECT` (`specs/041-nightly-qmd-embed/contracts/fetch-models-script.md` §3 y §4, paso 2):
  - un valor no vacío que empieza con `#<dígitos>` seguido de un espacio, o con `https://github.com/<dueño>/<repo>/issues/<dígitos>`, da `defect`: rc 0, `QMD_EMBED_SKIP_REASON=fase del embed apagada por defecto abierto: <valor>` y `::warning::`;
  - cualquier otro valor no vacío da `misconfigured`, con rc 1, y también un valor que no sea ASCII imprimible de una sola línea;
  - en los dos casos, cero llamadas a curl.

  F6 y F7 pasan a VERDE.
- [X] T016 [P] [US1] En `.github/workflows/docker-e2e.yml` (`specs/041-nightly-qmd-embed/contracts/workflow-delta.md` §2):
  - agregar `env: QMD_EMBED_DEFECT: ''` con su comentario en `Fetch the qmd models`;
  - agregar `QMD_EMBED_E2E: '1'` en el `env` de la suite, junto a `DOCKER_E2E: '1'`.

  W4 y W6 pasan a VERDE; W1 a W3, W5, W7 y W8 siguen en verde; `bats tests/ci-workflows.bats` en 14 de 14.
- [X] T017 [US1] En `tests/docker-e2e-qmd.bats` (`specs/041-nightly-qmd-embed/contracts/embed-test.md` §1, §3.2 y §3.3):
  - `_qmd_real_ws` copia `tests/fixtures/qmd-e2e/vec0-libc.sh` a `DIR/.e2e/`;
  - fase `boot`: con `docker compose exec -T -u agent`, `CI` vacía y `XDG_CACHE_HOME` vacía o igual a `$HOME/.cache`. Si no, falla nombrando la variable;
  - fase `setup`: plazo `QMD_E2E_SETUP_DEADLINE_S` (entero de 1 a 3600; por defecto 600) y sondeo cada 5 s. `docker compose logs --no-color` se vuelca a `$D/.e2e/compose.log` y se busca con `grep` sobre el archivo, sin tubería. Falla en el acto, nombrando el paso, ante `[qmd] setup: '<paso>' failed` o `[qmd] install: bun install failed`;
  - fase `vector-extension`: reemplaza la aserción de la línea 690 por `sh /workspace/.e2e/vec0-libc.sh "$HOME/.cache/qmd/pkg"` (busybox), que debe dar `MUSL` con rc 0; el cuerpo ya no contiene `sqlite-vec-linux-arm64`;
  - marcas de `reindex`, `semantic-search` y `mcp`, sin tocar sus aserciones. Cada marca va antes de su ancla y la ancla antes de la marca siguiente (`contracts/host-oracle.md`, P1);
  - antes de bajar el proyecto, la línea `# qmd embed resources: disk_free_kb=<n> mem_peak_bytes=<n o unknown>` por el descriptor 3, con `df -Pk` del workspace y el `memory.peak` del cgroup del contenedor; no es una aserción;
  - quitar el volcado ad hoc del ciclo del centinela y agregar al `teardown` un volcado único de `docker compose logs --tail=150`, cuando `BATS_TEST_COMPLETED` está vacío y existe `$TMP_TEST_DIR/agent-qmd-embed/docker-compose.yml`.

  P1 pasa a VERDE.
- [X] T018 [US1] Punto de control en bash 5.x y en 3.2: los 33 tests escritos hasta aquí en verde (todos menos G1 y G3), los cinco saltados de `tests/docker-e2e-qmd.bats` sin `DOCKER_E2E` y `bats tests/ci-workflows.bats` en 14 de 14. Registrar en las Notes.

**Checkpoint**: la fase del embed queda activa en el nightly, con ocho fases nombradas, salida anticipada del setup y una comprobación de la extensión vectorial que no depende de la arquitectura.

---

## Phase 6: User Story 4 - El costo queda acotado y medido (Priority: P2)

**Goal**: la identidad de los modelos tiene una sola fuente, con un guard ligado al pin de qmd. El costo se mide en cada corrida: el log de F1 y el presupuesto de F10, ya cubiertos en US3.

**Independent Test**: en el host, G1 y G3. En CI, la medición de E1 (T030).

- [X] T019 [US4] ROJO: escribir G1 y G3 en `tests/qmd-embed-nightly.bats`. G1 carga `scripts/lib/qmd_index.sh` como `tests/qmd-version-guard.bats`, compara la versión por defecto de `qmd_pkg` con `QMD_MODELS_QMD_VERSION` del script y afirma que `_qmd_real_ws` no escribe la versión como literal. G3 busca `.github/scripts/fetch-qmd-models.sh` y `QMD_E2E_MODELS_DIR` en `docs/qmd-upgrade-checklist.md`. Correr y registrar el ROJO.
- [X] T020 [US4] Agregar `QMD_MODELS_QMD_VERSION=2.5.3` junto a la tabla de `.github/scripts/fetch-qmd-models.sh`, con un comentario que diga que la vigila G1. En `docs/qmd-upgrade-checklist.md`:
  - agregar un paso: al subir qmd, revisar la tabla de modelos del nightly (repos, archivos, nombres locales, bytes, sha256 y `QMD_MODELS_QMD_VERSION`);
  - reescribir el ítem del DOCKER_E2E (hoy líneas 105 a 110): la fase del embed vive en `qmd real (041)` y se corre con la receta de dos comandos de `specs/041-nightly-qmd-embed/quickstart.md` §4 (primero `fetch-qmd-models.sh`, después `QMD_EMBED_E2E=1` con `QMD_E2E_MODELS_DIR`).

  G1 y G3 pasan a VERDE.
- [X] T021 [US4] Punto de control en bash 5.x y en 3.2: los 35 tests de `tests/qmd-embed-nightly.bats` en verde (al cierre de US4; P2 llegó en la segunda revisión y hoy el total es 36). Registrar en las Notes.

**Checkpoint**: oráculo completo, 35 de 35 al cierre de US4 (P2 llegó en la segunda revisión: hoy son 36).

---

## Phase 7: Polish (local; sin compuertas salvo T026 y la descarga de yq de T027)

**Purpose**: documentación, mutaciones, revisión independiente y gate completo antes de salir del host.

- [X] T022 [P] Borrador de la entrada de `CHANGELOG.md` (FR-021, SC-010), sin bump de `VERSION`. Debe decir:
  - qué cubre el nightly desde 041: la fase del embed, o el salto con defecto si E1 lo confirma;
  - el paso de obtención y sus pins, los ~1,6 GB por noche sin cache y el trato de un modelo cambiado en origen (sin reintento, con su motivo);
  - la corrección de la aserción de la línea 690 y la verificación de la variable `CI`;
  - que en local `QMD_EMBED_E2E=1` ahora exige `QMD_E2E_MODELS_DIR` (primero el script de obtención);
  - los conteos: 49 e2e en 13 archivos y la suite del host en la línea base más 37;
  - que `QMD_E2E_MODEL_CACHE`, mencionada en la entrada de 016, nunca existió en el código. Esa entrada no se reescribe.
- [X] T023 [P] En `CLAUDE.md`, a mano:
  - actualizar la entrada de 041 del bloque SPECKIT con el estado de la implementación y los conteos (49 e2e; host = línea base más 37);
  - corregir en «Common gotchas» la frase que dice que `qmd real (016)` pasa sin ejercer el embed;
  - agregar viñetas para el modo CI de qmd (`llm.js:384`), la expansión que carga `vsearch` y el reemplazo de `sqlite-vec` que solo conoce arm64, mientras siga así.
- [X] T024 Ejecutar las mutaciones M1 a M101 de `specs/041-nightly-qmd-embed/quickstart.md` §3 contra la implementación, en bash 5.x y en 3.2, sobre copias o revirtiendo cada una. Registrar en las Notes el test que cae con cada mutación y comprobar que cada uno de los 36 tests cae con al menos una. Si alguna sobrevive, endurecer el oráculo y repetir antes de seguir.
- [X] T025 Revisión independiente de solo lectura (agente `code-reviewer`) antes del gate completo, sobre `.github/scripts/fetch-qmd-models.sh`, `.github/workflows/docker-e2e.yml`, `tests/docker-e2e-qmd.bats`, `tests/qmd-embed-nightly.bats` y `tests/fixtures/qmd-e2e/`. Clasificar cada hallazgo y corregir los que correspondan, con su ROJO y su VERDE.
- [X] T026 COMPUERTA (Docker Desktop y ~1,6 GB de disco del operador): DOCKER_E2E local en arm64 según `specs/041-nightly-qmd-embed/quickstart.md` §4. Es opcional en este punto y **obligatoria antes de T038 si E1 (T030) no llega a la fase `models-untouched`** (FR-020, decisión del 16-10-2026); en ese caso corre después de T030. Esperado: 016 y 041 en verde, con las ocho marcas en orden y la línea `# qmd embed resources:`. Registrar en las Notes qué fases ejecutó. Un rojo de arnés acotado se corrige aquí (FR-015).
- [X] T027 Gate completo según `specs/041-nightly-qmd-embed/quickstart.md` §2 y §7. Registrar en las Notes:
  - `bats tests/` secuencial en bash 5.x y después en 3.2, con el esperado de T001 más 37;
  - `tests/qmd-embed-nightly.bats` con la SIGPIPE ignorada, como la entrega el runner (`perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats …`), en los dos bash;
  - paridad de los tests W y de `tests/ci-workflows.bats` con yq v4.44.3. COMPUERTA: bajar el binario de la release oficial, verificar su checksum y ejecutarlo pide el visto bueno del operador, salvo que ya exista uno verificado;
  - shellcheck con el comando exacto de la CI en rc 0;
  - `git diff --stat origin/main -- docker scripts modules setup.sh` vacío;
  - `VERSION` igual a `git show origin/main:VERSION`;
  - el script y los fixtures en ASCII;
  - cero marcas combinantes en `specs/041-nightly-qmd-embed/`.

---

## Phase 8: User Story 5 - Evidencia real de que el embed corre en el runner y de que una rotura lo pone en rojo (Priority: P2)

**Goal**: corridas reales, con sus identificadores, que muestren la fase ejecutada en el runner, la falla de obtención atribuida y una rotura inducida en rojo. También la decisión de FR-013 y FR-014 antes del merge.

**Independent Test**: los identificadores, la clasificación y la duración de cada corrida, en las Notes.

- [X] T028 [US5] COMPUERTA: commits locales, con mensajes en español, ASCII, en imperativo y sin atribución:
  1. los artefactos de spec-kit de `specs/041-nightly-qmd-embed/` y `.specify/feature.json`;
  2. la implementación (`.github/`, `tests/` y `docs/qmd-upgrade-checklist.md`);
  3. `CHANGELOG.md` y `CLAUDE.md`.

  Después, verificar con `git ls-files -s` el modo `100755` de `.github/scripts/fetch-qmd-models.sh`, `tests/fixtures/qmd-e2e/fake-curl` y `tests/fixtures/qmd-e2e/vec0-libc.sh`, y que W8 pase con el archivo ya versionado.
- [X] T029 [US5] COMPUERTA: push de la rama `041-nightly-qmd-embed` por HTTPS con el helper de `gh`, con los commits de T028 sobre `.github/`, `tests/`, `docs/qmd-upgrade-checklist.md` y `specs/041-nightly-qmd-embed/`.
- [X] T030 [US5] COMPUERTA: E1, `gh workflow run docker-e2e.yml --ref 041-nightly-qmd-embed`.
  - Descargar el log y comprobar que trae `GNU bash, version` antes de buscar nada en él.
  - Registrar en las Notes lo de data-model §6: identificador, commit y arquitectura; la duración del job `e2e` con su `started_at` y su `completed_at` (`gh api repos/<dueño>/<repo>/actions/runs/<id>/jobs`), no la de la corrida, y su margen; la duración de cada fase con las marcas de tiempo del log (la de `setup` incluye la compilación); por modelo, bytes, intentos y segundos; `free_kb` antes y después; la línea `# qmd embed resources:`; las marcas de fase; la línea TAP del test 041 y la `e2e summary:`.
  - Clasificar el resultado, con su fragmento de log.
  - Si E1 no llega a la fase `models-untouched`, T026 pasa a ser obligatoria antes de T038; registrarlo en las Notes.
- [x] T031 [US5] Solo si E1 muestra un defecto de arnés acotado al test (FR-015) (NO APLICÓ: E1 mostró un defecto de producto, #107, y ninguno de arnés): corregirlo en `tests/docker-e2e-qmd.bats`, con su ROJO y su VERDE en el host cuando se pueda; repetir de T027 lo que corresponda y repetir E1 (COMPUERTA de commit, push y dispatch).
- [X] T032 [US5] Solo si E1 muestra un defecto de producto (FR-014):
  1. COMPUERTA: el operador abre el issue de seguimiento. Su cuerpo registra lo que hay que hacer al cerrarlo: vaciar `QMD_EMBED_DEFECT`, correr E1 con la fase activa y la rotura inducida de E4 (FR-020; `specs/041-nightly-qmd-embed/data-model.md` §3);
  2. fijar `QMD_EMBED_DEFECT: '#<n> <motivo en ASCII>'` en `.github/workflows/docker-e2e.yml` (W6 debe seguir en verde);
  3. COMPUERTA: commit, push y E2 por dispatch. Esperado: `# skip fase del embed apagada por defecto abierto: #<n> …` y el job verde si nada más falla. Registrar en las Notes.
- [x] T033 [US5] Solo si E1 deja menos de 5 minutos de margen (FR-013; research D16) (NO APLICÓ en 041: E1 cayó en `setup` y no midió el margen con la fase activa; lo midió 042, que subió el tope a 45 en el PR #113, mergeado el 29-10-2026): subir `timeout-minutes` en `.github/workflows/docker-e2e.yml`, en un commit aparte (`specs/041-nightly-qmd-embed/contracts/workflow-delta.md` §1), y volver a medir (COMPUERTAS de commit, push y dispatch). Compartir el prefijo compilado entre 016 y 041 no entra aquí: es una mejora posterior medida (research D8, decisión del 16-10-2026). Registrar cada medición.
- [X] T034 [US5] COMPUERTA: E3 en una rama de ensayo que no se mergea, con el `file` del modelo de embeddings de la tabla de `.github/scripts/fetch-qmd-models.sh` cambiado por uno inexistente. Esperado: `fetch_models` en rojo tras tres intentos, la suite corre, el test 041 sale saltado con «no se pudieron obtener…» y el job queda rojo. Registrar en las Notes y borrar la rama de ensayo (COMPUERTA).
- [x] T035 [US5] Solo si E1 fue verde (NO APLICÓ: E1 fue rojo por un defecto de producto, #107; la rotura inducida la hizo 042, T031, en una rama de ensayo ya borrada): COMPUERTA para E4, en una rama de ensayo que no se mergea y que cambia `tests/docker-e2e-qmd.bats` para construir la imagen del test 041 con `--build-arg QMD_NATIVE_TOOLCHAIN=0`. Esperado: rojo con la última marca en `setup` o en `vector-extension`. Registrar en las Notes y borrar la rama de ensayo (COMPUERTA).
- [X] T036 [US5] Ajustar `CHANGELOG.md` y `CLAUDE.md` al resultado real de E1 a E4 y de T026 (embed activo, o apagado con el defecto `#<n>`, y qué fases se verificaron solo en arm64) y registrar en las Notes la decisión de FR-013. COMPUERTA de commit y push.

---

## Phase 9: Cierre

**Purpose**: rebase sobre 040 si corresponde, PR, merge y las noches posteriores.

- [x] T037 Solo si 040 mergea antes que 041 (NO APLICÓ: 041 mergeó primero, el 19-10-2026, y 040 sigue sin mergear al 29-10-2026):
  - rebasar sobre `main` y resolver los conflictos previsibles sin perder ninguna entrada: `.specify/feature.json`, las dos entradas de `CHANGELOG.md` en `[Unreleased]`, el bloque SPECKIT de `CLAUDE.md` y el `id: verify_deps` que agregan las dos ramas (`specs/041-nightly-qmd-embed/contracts/workflow-delta.md` §3);
  - aplicar la forma combinada de `specs/041-nightly-qmd-embed/contracts/workflow-delta.md` §3 en `.github/workflows/docker-e2e.yml`: `if: ${{ !inputs.alert_trial }}` en `fetch_models` y el `if:` combinado en la suite;
  - enmendar de forma explícita `tests/nightly-alert.bats:1419` y `:1952`, y W1 y W5 de `tests/qmd-embed-nightly.bats`;
  - verificar `VERSION` contra `origin/main` a mano (lección de 023);
  - medir de nuevo la línea base sobre el `main` rebasado, en copia aislada y en los dos bash, como T001; desde aquí, el esperado es esa línea base más 37;
  - repetir T027 con ese esperado y un dispatch de confirmación (COMPUERTA), porque la evidencia debe corresponder al texto que se mergea.
- [x] T038 COMPUERTA: abrir el PR contra `main` con el resumen, los identificadores de E1 a E4, el resultado de T026 cuando fue obligatoria, y las decisiones de FR-013 y FR-014, tomados de las Notes de `specs/041-nightly-qmd-embed/tasks.md`. Requisito previo: T026 en verde si E1 no llegó a `models-untouched`. La CI debe mostrar el esperado vigente (T001 más 37, o la línea base de T037 más 37) en los dos brazos de bash. Si un brazo cae solo en la CI, reproducirlo en local (SIGPIPE ignorada; bats de Homebrew en macOS) antes de tocar nada, y el arreglo pasa por la COMPUERTA de commit y push. HECHA el 17-10-2026: PR #108 abierto contra `main` (<https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/pull/108>), con las Notes como cuerpo; la CI del PR dio verde: `shellcheck` en 18 s y `tests` con `1..1854`, 1854 ok y 0 not ok en ubuntu con bash 5.2.21 (9 min 13 s) y en macOS con bash 3.2.57 (22 min 7 s).
- [x] T039 COMPUERTA: merge del PR de T038 por el operador. Después, verificar que el `.github/workflows/docker-e2e.yml` y el `.github/scripts/fetch-qmd-models.sh` de `origin/main` son los validados, y que `VERSION` en `origin/main` no cambió. Si 040 sigue sin mergear, dejar en la memoria del proyecto las enmiendas inversas que tocarán a 040 (W1 y W5 de 041; `:1419` y `:1952` de `tests/nightly-alert.bats`) y avisarle al operador para las Notes de 040. HECHA el 19-10-2026: el operador mergeó #108 a las 03:05:18Z (00:05 -03) como el squash `0fc08a8`, junto con #104 y #105; `origin/main` trae el `.github/workflows/docker-e2e.yml` y el `.github/scripts/fetch-qmd-models.sh` validados y `VERSION` no cambió (0.28.0). 040 sigue sin mergear: las enmiendas inversas que le tocan al rebasar están en `specs/041-nightly-qmd-embed/contracts/workflow-delta.md` §3.
- [x] T040 Después del merge (SC-007), registrar en las Notes de `specs/041-nightly-qmd-embed/tasks.md` las tres nocturnas siguientes: identificador, duración del job, margen, línea TAP del test 041 y `e2e summary:`. Cada una debe ejecutar la fase del embed, o tenerla apagada por un defecto abierto y registrado, y terminar con al menos 5 minutos de margen. Si alguna queda con menos margen o con tiempo agotado, se reabre FR-013: subir el tope en un PR aparte en `.github/workflows/docker-e2e.yml` y volver a medir (COMPUERTA). HECHA el 29-10-2026: las seis nocturnas posteriores al merge, con la fase apagada por #107, están en las Notes; ninguna quedó con menos margen ni con tiempo agotado.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: sin dependencias. T001 es largo (unos 20 min por bash) y corre sobre una copia aislada, así que T002 a T004 pueden avanzar mientras tanto.
- **Foundational (Phase 2)**: T003 y T004 se escriben en paralelo con T002; los tests que usan el `curl` falso (desde T008) necesitan T002 terminado. La fase bloquea todas las historias.
- **US2 (Phase 3)**: después de la fase 2. Es el MVP.
- **US3 (Phase 4)**: después de US2, porque siembra los modelos dentro del test 041 que crea T006.
- **US1 (Phase 5)**: después de US3. La puerta del nightly (T016) solo se abre cuando existe la obtención, y el interruptor de defecto (T015) vive en el script de T009.
- **US4 (Phase 6)**: después de US3 (el script) y de US1 (el oráculo de 33 tests en verde).
- **Polish (Phase 7)**: después de US4. T026 puede correr después de T030, cuando E1 la vuelve obligatoria.
- **US5 (Phase 8)**: después de Polish. Todo lo que sale del host pasa por compuertas.
- **Cierre (Phase 9)**: después de US5.

### Within Each User Story

- El ROJO se registra antes de cada VERDE.
- Las tareas sobre el mismo archivo van en orden.
- Cada punto de control corre en bash 5.x y en 3.2, secuencial.

### Parallel Opportunities

- T002, T003 y T004, en archivos distintos, mientras T001 mide la línea base en su copia aislada.
- T014, T015 y T016 (fixture, script y workflow), después del ROJO de T013.
- T022 y T023 (CHANGELOG y CLAUDE.md).

---

## Parallel Example: User Story 1

```bash
# Después del ROJO de T013, en paralelo y en archivos distintos:
Task: "T014 Crear tests/fixtures/qmd-e2e/vec0-libc.sh (V1 a V6)"
Task: "T015 Interruptor QMD_EMBED_DEFECT en .github/scripts/fetch-qmd-models.sh (F6 y F7)"
Task: "T016 QMD_EMBED_DEFECT y QMD_EMBED_E2E en .github/workflows/docker-e2e.yml (W4 y W6)"
# Después, en serie: T017 (tests/docker-e2e-qmd.bats) y el punto de control T018.
```

---

## Implementation Strategy

### MVP primero (US2)

1. Setup y Foundational.
2. US2: el test 041 existe, salta con motivo antes de tocar Docker y el 016 conserva su fase A y su RED.
3. Validar con K1 a K4. Desde aquí el nightly ya no puede esconder el embed detrás de un verde.

### Entrega incremental

1. US3: obtención atribuible, acotada e íntegra.
2. US1: la fase activa en el nightly, con sus ocho fases y el interruptor de defecto.
3. US4: el guard de la identidad de los modelos.
4. Polish y gate local.
5. US5: la evidencia real, que decide FR-013 y FR-014.
6. Cierre.

Todo se mergea en un solo PR, y solo después de la evidencia: ninguna fase intermedia se publica sola.

---

## Notes

- **[P]**: archivos distintos y sin dependencias abiertas.
- No hay commits hasta T028, ni push hasta T029. La regla genérica de la plantilla («commit after each task») no aplica en este repositorio.
- Toda aserción nueva sobre `$output` evita tuberías con un consumidor que cierre antes (gotcha de `CLAUDE.md`). Ningún `[[ ]]` intermedio ni `!` intermedio. Las aserciones del Tier 2 que se mueven sin cambios (FR-002) conservan su forma `echo` seguido de `grep -q`: son seguras porque `echo` es un builtin que escribe una sola vez, menos de 64 KiB, y bats no activa `pipefail`.
- Las cargas grandes viajan por archivo, nunca por `argv` ni por el entorno.

### Registro (se completa durante la implementación)

- **T001, línea base** (16-10-2026, copia aislada: worktree limpio de `main@13cafc3` en el scratchpad, `bats --tap tests/`, secuencial, stderr vacío): **bash 5.3.15 (Bats 1.13.0): 1817 ok / 0 not ok / 54 saltados, 17 min 44 s**; **bash 3.2.57: 1817 ok / 0 not ok / 55 saltados, 19 min 49 s** (el brazo 3.2 salta un test más que el 5.x). El esperado final de la suite completa es la línea base más 36, o sea **1853 ok / 0 not ok en ambos**, con 55 saltados en bash 5.x y 56 en 3.2 (el e2e 041 suma un salto).
- **ROJO y VERDE por historia (T005 a T021)**, todos con la suite del host sin Docker:
  - **US2** (T005 a T007). ROJO de T005: K1 a K3 porque el test 041 no existía (el bats anidado respondía `1..0`) y K4 porque el cuerpo del 016 todavía contenía `QMD_EMBED_E2E`. VERDE tras T006: K1 a K4 en bash 5.x y 3.2; `tests/docker-e2e-qmd.bats` sin `DOCKER_E2E` da `1..5` con los cinco saltados; `tests/ci-workflows.bats` 14 de 14 sin editarse. **Hallazgo de T006:** un bats que lanza otro bats por `PATH` encuentra primero el script interno de su `libexec` (el bats en ejecución antepone ese directorio) y muere con `bats_readlinkf: orden no encontrada`; el arnés busca el lanzador saltándose `BATS_LIBEXEC` (`_real_bats`).
  - **US3** (T008 a T012). ROJO de T008: fallan 16 (F1 a F5, F8 a F13, G2, W1, W2, W5 y W8; las del script con rc 127, las de G2 y W8 por el archivo ausente) y nacen verdes W3 y W7, como se declaró. VERDE: 22 de 22 en ambos bash; shellcheck con el comando de la CI en rc 0. **Hallazgo de T009:** G2 quitaba `-GGUF` solo en mayúsculas y el repo de expansión termina en `-gguf`; la regla real (`parseModelUri.js`, `doesFilenameMatchExactModelName`) ignora la caja, y el que estaba mal era el test.
  - **US1** (T013 a T018). ROJO de T013: fallan V1 a V6 (el archivo no existía, rc 127), P1 (solo dos marcas y la aserción vieja de la ruta arm64 todavía dentro del test), W4, W6, F6 y F7. **Hallazgo de ese ROJO:** `_calls http` pedía la palabra "http" dos veces por línea y daba cero aunque hubiera llamadas, de modo que "cero llamadas a curl" de F6 a F9 no podía fallar (M12 habría sobrevivido); se reemplazó por `_ncalls`, que cuenta los separadores del registro y se calibra con F3 (3 llamadas). VERDE tras T014 a T017: 33 de 33 en ambos bash.
  - **US4** (T019 a T021). ROJO de T019: G1 (el script no registraba `QMD_MODELS_QMD_VERSION`) y G3 (la checklist no mencionaba el script). VERDE tras T020: **35 de 35** en bash 5.x y 3.2, más `tests/qmd-version-guard.bats` 3 de 3.
  - **Paridad con el yq de la CI** (v4.44.3, compilado a mano en el scratchpad durante 040, sin descarga): W1 a W8, G1 a G3 y P1 (12 de 12) y `tests/ci-workflows.bats` (14 de 14), en bash 5.x y 3.2.
- **Tests que nacen verdes a propósito**: W3 y W7, que vigilan que algo no cambie. Los prueban M4 y M6 (T024).
- **Análisis (16-10-2026)**: 28 hallazgos (0 CRITICAL, 2 HIGH, 10 MEDIUM y 16 LOW), todos remediados con la aprobación del operador. Sus tres decisiones están en spec.md, Clarifications del 16-10-2026: FR-013 sube el tope primero; un cambio del modelo en origen no se reintenta; T026 es obligatoria si E1 no llega a `models-untouched`. El conteo de tests no cambió (35, suite = línea base más 36); las mutaciones pasaron de 27 a 47.
- **Mutaciones M1 a M47 (T024, 16-10-2026, ronda 1)**: **47 de 47 cazadas, en bash 5.x y en 3.2, ninguna sobrevivió.** Cada una se aplicó sobre una copia aislada del árbol (nunca sobre el árbol de trabajo) y se corrió solo el test que debía caerse; se revisó además que cayera por la aserción prevista y no por un error del arnés. Mutación → test que la caza: M1→W4, M2→W5, M3→W1, M4→W3, M5→W2, M6→W7, M7→W6, M8→F2, M9→F3, M10→F4, M11→F5, M12→F6, M13→F8, M14→F9, M15→F10, M16→F13, M17→F3, M18→F1, M19→V2, M20→V4, M21→K1, M22→K2, M23→K3, M24→K4, M25→G1, M26→G2, M27→P1, M28→P1, M29→P1, M30→W8, M31→F1, M32→F7, M33→F11, M34→V1, M35→V3, M36→V5, M37→V6, M38→G3, M39→W1, M40→W5, M41→F3, M42→F13, M43→F1, M44→G1, M45→F5, M46→F7, M47→F12. Cada uno de los 35 tests cae con al menos una (comprobado con el script de auditoría). Dos defectos que las mutaciones habrían encontrado se corrigieron antes, al ver los ROJOS (el contador vacuo `_calls http`, y la regla de mayúsculas de G2).
- **Ensayo en seco del test 041 sin Docker** (extra, no forma parte de las tareas; herramienta del scratchpad, no versionada): un `docker` falso emula el contenedor sobre el host y corre el cuerpo real del test 041. Escenario `ok`: las ocho marcas en orden, la línea `# qmd embed resources:` y `ok 1`, en bash 5.x y 3.2. Nueve escenarios de falla con la última marca y el mensaje esperados: el log del contenedor dice que el setup falló (sale al instante, nombrando el paso), el setup no termina y no dice nada (sale por el plazo), extensión glibc, extensión ausente, modelo reescrito, archivo parcial junto a los modelos, `CI` con valor, `XDG_CACHE_HOME` distinto y firma de BUG-4 en el MCP; en todos los fallos el teardown vuelca el log del contenedor una vez y baja el proyecto. No sustituye a T026: valida el flujo del test, no a Docker ni a qmd.
- **Paridad con bats 1.11.0** (la versión que la CI instala en Linux; clon superficial del tag `v1.11.0` en el scratchpad, revisado antes de ejecutarlo: `bin/bats` estándar, `bats-exec-test` idéntico al leído en la investigación, sin llamadas de red) con el yq 4.44.3 y bash 5.3.15: oráculo 35 de 35, `qmd real` saltados 5 de 5 y `tests/ci-workflows.bats` 14 de 14. Con la señal SIGPIPE ignorada, como la entrega el runner: oráculo 35 de 35 en bash 5.x y en 3.2.
- **Revisión independiente (T025, 16-10-2026)**: agente `code-reviewer` de solo lectura, que trabajó sobre una copia del árbol y aplicó unas 45 mutaciones propias. **3 ALTA, 6 MEDIA y 11 BAJA; ningún defecto de lógica en `fetch-qmd-models.sh`** (se comporta igual en bash 3.2.57 y 5.3.15, no imprime bytes no ASCII, shellcheck limpio incluso a `-S style`), pero un oráculo que dejaba pasar mutaciones plausibles y un cuerpo del test e2e que habría fallado con un producto sano. Clasificación y qué se hizo (todo con su ROJO visto antes: las 22 mutaciones derivadas sobrevivían, 0 cazadas, y tras el arreglo caen las 22):
  - **C1, ALTA, CONFIRMADA leyendo el código** (`qmd_index.sh:350` y `:479`, esqueleto con `wiki/` solo con `.gitkeep`): el documento del Tier 2 viejo se escribía en la raíz del vault, que la colección de qmd dejó de cubrir en 037 (máscara `wiki/**/*.md`). Con un producto sano el `vsearch` no podía devolverlo y el setup del primer arranque no tenía nada que embeber; E1 se habría puesto rojo en `semantic-search` por el arnés y la falla se habría podido leer como defecto de producto. Nadie ejecutaba ese Tier 2 desde 037. **Arreglo:** el vault se siembra ANTES del primer arranque (esqueleto más `wiki/concepts/computadores.md`, como el e2e de PARA) y la página del `reindex` va bajo `wiki/concepts/`; P1 vigila ambas rutas. Es un defecto de arnés de FR-015 (se agregó esa salvedad a FR-002); su verificación con una corrida real queda para T026 o E1.
  - **C2, ALTA, CONFIRMADA por mutación:** F8 pasaba también la tabla alternativa, y el segundo chequeo rechazaba lo mismo, así que se podía borrar la validación de la base (M48) o el chequeo de dígitos del puerto (M49, que es el que cierra el truco `http://127.0.0.1:@a.io`, cuyo host sería `a.io`) sin que cayera nada. **Arreglo:** F8 sin tabla, con ese valor en la lista y el motivo debe nombrar `QMD_MODELS_BASE_URL`.
  - **C3, ALTA, CONFIRMADA por experimento:** el guard contra saltos de línea (única barrera contra inyectar variables en `$GITHUB_ENV` con un valor de `QMD_EMBED_DEFECT` como `'#123 x'` más un salto y `INJECTED=1`) no tenía test (M50). **Arreglo:** F7 con valores con LF, LF más `::warning::` y CR, y la aserción de que `$GITHUB_ENV` queda con exactamente una línea.
  - **W1:** el fake nunca dejaba un parcial, así que «ningún `.part`» era vacuo (M51). **Arreglo:** acciones `pfail:` y `hang:` que dejan un parcial; y en el script, un `trap` de salida que borra los `.part` por cualquier camino (también ante SIGTERM) en lugar de tres limpiezas a mano en las ramas de falla, que eran redundantes entre sí.
  - **W2:** la espera nunca se recortaba al presupuesto restante en ningún test (M52). **Arreglo:** segunda pierna de F10 (presupuesto de 5 s y esperas por defecto: cada espera registrada debe ser menor o igual a 5; no se afirma el valor exacto porque el reloj corre en segundos enteros).
  - **W3:** P1 comprobaba el comando de cada fase pero no que su resultado se afirmara: se podían borrar `grep -qi 'gato'`, la comprobación de `MUSL`, la de `pending` o el `false` de `models-untouched` (M57 a M60), y la ayuda `_embed_phase` no la ejercía nadie (M61). **Arreglo:** P1 exige las aserciones de cada fase, el `false` tras el informe de falla y que la ayuda imprima por el descriptor 3 (research D17). Queda sin cubrir la aserción neutralizada (un `if false`), que solo muestran los ensayos reales y E4.
  - **W4:** F4 solo probaba cuerpos más largos (M53). **Arreglo:** acción `shrink:` y pierna de cuerpo más corto.
  - **W5:** un bloque `permissions` a nivel del job (M54) y `continue-on-error` en `Verify deps + docker` (M55, que dejaba la noche verde sin tests con Docker caído) pasaban todo. **Arreglo:** W7 y W2.
  - **W6:** la perilla `QMD_MODELS_DIR`, que usa la receta de la checklist, no tenía test (M56). **Arreglo:** pierna de F1; el contrato la llama también perilla del operador.
  - **BAJAS atendidas:** L1 (la línea vacua de F12, quitada), L2 (comentario de `HAVE_MODEL`: ahora solo prueba que el contenedor ve los modelos sembrados), L4 (K1 y K2 con la puerta en `0` y vacía, M63 y M64), L5 (comprobación de `curl` y de `mkdir`, motivo de solo espacios, longitud de la suma de la tabla y tabla mal formada con tests, M66 a M72), L6 (`elapsed_s` entero y suma observada real, M70 y M71), L7 (la biblioteca musl que menciona `GLIBC` sin guion bajo, M65; la receta de la checklist en G3), L8 (los contratos decían «en una variable» y «por stderr» donde el código usa un archivo y el descriptor 3, y prometían un archivo de tests en ASCII que lleva `─` en los encabezados: corregidos), L11 (W6 se calibra con una muestra buena y una mala).
  - **No se hizo, con razón:** L3 (un contenedor en crash-loop gasta los 600 s del plazo sin detectarse; el teardown vuelca el log y D16 acota el plazo con la medición de E1), L10 (`timeout-minutes` en `fetch_models`: el presupuesto del script y el tope del job ya lo acotan), L9 (que el runner aplique `$GITHUB_ENV` de un paso que sale con 1 es un supuesto de plataforma; lo verifica E3, y si no se cumpliera el test 041 saldría `not ok` con un mensaje que nombra `QMD_E2E_MODELS_DIR`, no un salto).
  - **Propuesta pendiente del operador:** llevar al repositorio el ensayo con `docker` falso (hoy en el scratchpad) cerraría también la clase «aserción neutralizada», a costa de un fixture, unos diez tests y todos los conteos (research D17).
- **Mutaciones M48 a M73 (T024, ronda 2)**: tras reforzar el oráculo, **73 de 73 cazadas en bash 5.x y 3.2** (ronda completa con el árbol reforzado), cada una por la aserción prevista (M48 a M73 son las 26 que salieron de la revisión y de sus arreglos; ver `quickstart.md` §3).
- **Segunda revisión (T025, ronda 2, 16-10-2026)**: con ultracode activo, un workflow de solo lectura de cinco lentes (`wf_96bc6ba6-92f`: realidad del runner, deriva entre artefactos, seguridad e integridad, modos de falla y atribución, semántica de shell) y dos escépticos por hallazgo (alcanzabilidad; impacto y arreglo): 49 agentes, 13 min, unos 7,4 M de tokens. **22 hallazgos, ninguno ALTA**: los buscadores marcaron 5 MEDIA y los escépticos bajaron casi todas a BAJA; RR-4 y SEC-1 quedaron con un escéptico que los refutó y otro que los confirmó como BAJA. Clasificación y qué se hizo:
  - **Arreglados, con su ROJO visto antes** (el oráculo se reforzó primero: F9, F10, F12, P1 y el nuevo P2 cayeron contra el código viejo, y W6 se demostró con el valor `'#12   '` en el workflow, que el patrón viejo dejaba pasar y el nuevo no):
    - RR-1 y FM-2: `vsearch` y el reindex no tenían tope propio, y un cuelgue cancelaba el job a los 30 min (sin fase, sin `e2e summary:`, y 33 de los 49 e2e corren después de este archivo). Ahora van acotados dentro del contenedor (`timeout -k 10 600` y `timeout -k 10 300`, salida a un archivo) y fallan como su fase. **Medido en busybox 1.37 (research M15):** un `timeout` a secas solo envía TERM y un hijo que lo ignora lo bloquea mientras viva; el rc es 143 tras TERM y 137 tras KILL, no 124.
    - FM-3, RR-3 y FM-4: el rojo más probable de E1 (el paquete x64 es glibc) se atribuía a `setup` sin la prueba de la extensión. `_embed_failure_state`, llamado desde el `teardown`, deja disco libre, `docker inspect` (OOM, código de salida, reinicios) y, desde dentro, `uname -m`, el veredicto de `vec0-libc.sh`, los paquetes `sqlite-vec-linux-*` y los contadores del cgroup.
    - FM-1: el cron `*/5` abría una ventana de unos 6 a 10 s (cerca de un 3 % por noche; inferido, no medido) en que tomaba el lock y el reindex manual salía con 0 sin escribir nada: un rojo falso que dispara el aviso de 040. El workspace de los tests reales programa el cron el 31 de febrero.
    - FM-5, FM-6, SH-1, SH-2 y SH-3: el presupuesto agotado pisaba la causa del último intento; `QMD_MODELS_DIR` se culpaba aunque nadie lo definió; un `GITHUB_ENV` no escribible dejaba el paso en verde y el rojo caía en la suite; un plazo o un tamaño con cero a la izquierda se leían como octal; el informe de `models-untouched` dejaba líneas sin `#` en el flujo TAP.
    - DR-1 a DR-7: conteos y descripciones que habían quedado atrás (CLAUDE.md sin el 49; tasks.md con los helpers y las acciones del arnés de antes de la primera revisión; 26 donde eran 22; rangos de research y la colisión de `M<n>`; el formato del interruptor entre data-model y W6; el contrato que decía que 016 usa `vec0-libc.sh`; notas caducas del checklist).
  - **Aceptados, con su razón:** RR-2 (el margen de los 30 min lo decide FR-013 con la medición de E1; se agregó a quickstart §5 y a D18 la opción, que decide el operador, de correr E1 desde un commit de ensayo con `timeout-minutes: 45`); RR-4 (los saltos del setup sin reintento son inalcanzables en este arnés; research D11); SEC-1 (el enlace duro lo detecta `models-untouched` y en el nightly es efímero); FM-7 (un modelo reemplazado con otro tamaño se reintenta como una descarga cortada; queda como límite conocido en el contrato).
  - **Un defecto propio que apareció al arreglar:** la pierna nueva de F12 cayó en esta Mac porque el bash de Homebrew traduce sus propios mensajes («línea») aun desde `env -i` (gettext consulta el idioma del sistema). El script fija `LC_ALL=C` (research M15 y D18).
  - **Conteos:** el oráculo pasa de 35 a 36 tests (P2); el esperado de la suite del host, de 1853 a **1854** (línea base 1817 más 37: los 36 del oráculo y el e2e 041, que en el host sale saltado); las mutaciones, de 73 a 94 (M74 a M94). Tests con texto cambiado: W6, F9, F10, F12 y P1.
- **Mutaciones M74 a M94 (T024, ronda 3, 16-10-2026)**: tras la segunda revisión, la campaña completa sobre el árbol final dio **94 de 94 cazadas en bash 5.x y 3.2, ninguna sobrevivió** (corrida de ~25 min, cada mutación sobre una copia aislada). La primera pasada de los tests nuevos dejó pasar tres: **M79** (el informe de `models-untouched` vuelve a un `echo` sin `#`: P1 exigía al menos un uso de `_embed_note` y quedaban dos), **M83** (la sonda de dentro del contenedor pierde su protección contra fallos: P2 exigía tres `|| true` y quedaban tres de cuatro) y **M94** (el script deja de fijar `LC_ALL=C`: la pierna de comportamiento solo muerde donde bash traduce sus mensajes, así que caía en bash 5.3 de Homebrew, en esta Mac en español, y no en el 3.2 de Apple ni caería en la CI en inglés). Se endurecieron antes de seguir: P1 exige los tres usos, P2 exige la protección en la línea de cada sonda, y F12 agrega la aserción sobre las dos líneas del script que fijan el idioma. Las otras 18 (M74 a M78, M80 a M82, M84 a M93) cayeron por la aserción prevista. M1 a M73 se repitieron en la misma campaña y siguen cazadas.
- **Tercera revisión (T025, ronda 3, 16-10-2026)**: la misma técnica, más estrecha: solo lo que cambió la segunda revisión (workflow `wf_5d3c4ca1-dc7`: tres lentes de solo lectura, el script, el cuerpo del e2e y la deriva documental, y un escéptico por hallazgo; 14 agentes). **11 hallazgos, todos confirmados por su escéptico: 1 MEDIA y 10 BAJAS, ninguna ALTA.** Clasificación y qué se hizo:
  - **Arreglados en el código, con su ROJO visto antes** (el oráculo se reforzó primero: F12, P1, P2 y G3 cayeron contra el código de la segunda revisión):
    - TE-1 (MEDIA): las fases `reindex` y `semantic-search` solo imprimían su salida cuando el comando no terminaba; cualquier otro fallo (un rc 91, un `stalled`, un `pending` distinto de 0, un segfault de `vsearch`) caía en una aserción muda, y el estado al fallar no leía los archivos donde esa salida queda. En una primera corrida real (E1) una falla así habría dejado una aserción muda y el log del contenedor, sin su causa, y el workspace ya no existe cuando termina el job. Ahora el estado al fallar vuelca `qmd-index.json` y las últimas 40 líneas de `qmd-reindex.out` y de `vsearch.out` (M95 a M97).
    - TE-2: el informe de un plazo vencido mostraba el comienzo de la salida (`${output:0:400}`) y no decía cuánto corrió el comando, así que un 137 inmediato por OOM se leía como un cuelgue. Ahora dice el rc, los segundos (`SECONDS - t0`) y las últimas 12 líneas con `_embed_tail`, que usa `tail`: el corte `${x: -N}` que sugería el hallazgo da una cadena vacía cuando la salida es más corta que N (medido en bash 3.2 y 5.x) (M99 y M100).
    - TS-1 y TD-5: la rama del defecto abierto ignoraba el estado de su escritura en `$GITHUB_ENV` y el paso terminaba en verde sin su razón, contra lo que el contrato afirmaba sin excepción (reproducido por el escéptico: rc 0 y un `Is a directory` de bash en stderr). Las dos ramas pasan ahora por `emit_env_or_stop`, cuyo error es `no se pudo escribir <CLAVE> en GITHUB_ENV (paso fetch_models)`, y ese texto entró a la tabla de data-model §2 (M98).
    - TD-1: la checklist mandaba buscar `# --- state at the failure ---` y el test imprime `# --- state at the failure: disk, container verdict, vector extension ---`; una búsqueda del texto citado no lo encontraba y quien lee un rojo concluía que el volcado no se había impreso. Ahora cita el prefijo real y G3 lo ata al archivo del test (M101).
  - **Arreglados en los documentos:** TD-2 (la fila de P2 tenía una celda de más bajo una tabla de dos columnas y su sección no decía que cubre la evidencia al fallar), TD-3 (T024 decía 35 tests donde son 36, con el rango de mutaciones de otra ronda), TD-4 (la entrada de CLAUDE.md nombraba solo a M79 y M83 entre las mutaciones que sobrevivieron a la primera versión de los tests nuevos, y faltaba M94; además mezclaba conteos de épocas distintas sin rotularlos), TD-6 (FR-004 prometía un plazo propio para «una fase que no termina» y solo lo tienen las que ejecutan qmd y el setup; los pasos sin plazo propio quedan declarados en el spec, en el contrato y en D18) y TD-7 (el CHANGELOG decía que el cron «took the lock» donde solo lo infiere).
  - **Aceptado, con su razón:** TS-2 (si el primer modelo se baja bien pero consume todo el presupuesto, el segundo no llega a intentarse y su motivo es `budget (<N>s)` sin `tras:`; la causa, un enlace lento, la muestra el `elapsed_s=` de la línea `ok` del primero; queda como límite conocido del contrato del script).
  - **Conteos:** el oráculo sigue en 36 tests (cambian el texto de F12, G3, P1 y P2; ninguno es nuevo), el esperado de la suite del host sigue en 1854, y las mutaciones pasan de 94 a 101 (M95 a M101); M31, M47, M76, M77, M83 y M86 se apuntaron de nuevo a los textos que el arreglo cambió.
- **Mutaciones M95 a M101 (T024, ronda 4, 16-10-2026)**: tras la tercera revisión, la campaña completa sobre el árbol final dio **101 de 101 cazadas en bash 5.x y 3.2, ninguna sobrevivió** (cada mutación sobre una copia aislada). Se comprobó además con el resultado de la campaña que cada uno de los 36 tests es el que atrapa al menos una mutación (P1 atrapa 19, P2 10, F12 5 y G3 2). Las siete nuevas cayeron por la aserción prevista: M95 a M97 por P2, M98 por F12, M99 y M100 por P1 y M101 por G3. M31, M47, M76, M77, M83 y M86 se apuntaron de nuevo a los textos que cambió el arreglo (`emit_env_or_stop`, el informe con `_embed_tail` y la protección `|| true` de la sonda de dentro del contenedor) y siguen cazadas; M1 a M94 se repitieron en la misma campaña.
- **DOCKER_E2E local (T026, 17-10-2026, de 02:36 a 02:48, Mac arm64 con Docker Desktop 29.8.0 y bash 5.3.15)**: **verde a la primera, sin ningún arreglo de arnés.** Primero `QMD_MODELS_DIR=~/.cache/agentic-qmd-e2e/models-041 .github/scripts/fetch-qmd-models.sh` contra Hugging Face de verdad, la primera ejecución real del script: los dos modelos verificados por tamaño y sha256 con `attempts=1` (embeddings 36 s, expansión 155 s; 191 s y 1.616.029.856 bytes en total). Después `DOCKER_E2E=1 QMD_EMBED_E2E=1 QMD_E2E_MODELS_DIR=… bats --tap tests/docker-e2e-qmd.bats -f 'qmd real'`: `ok 1 qmd real (016)` y `ok 2 qmd real (041)`, rc 0, 8 min 42 s entre los dos, con las ocho marcas en orden (`models-seed`, `boot`, `setup`, `vector-extension`, `reindex`, `semantic-search`, `mcp`, `models-untouched`) y la línea `# qmd embed resources: disk_free_kb=42402276 mem_peak_bytes=4622278656` (4,3 GiB de pico de memoria del contenedor). **Lo que esta corrida confirma, ya medido en un contenedor real:** el cuerpo del test 041 corre de punta a punta; el vault sembrado antes del primer arranque, con la página bajo `wiki/` (el arreglo de C1), deja el reindex en `pending` 0 y hace que `vsearch` encuentre el documento; qmd usa los modelos sembrados con el nombre `hf_<usuario>_<archivo>` sin descargar ni reescribir ninguno (`models-untouched` en verde); y el reindex y la búsqueda terminan dentro de sus plazos de 600 y 300 s. **Lo que NO prueba:** nada sobre amd64 (la pregunta de `_qmd_swap_sqlite_vec` con la disposición x64 sigue abierta hasta E1); la imagen salió de la caché de capas de Docker (el `agent-admin:qmd-embed` de hace dos semanas), así que el build de la imagen no se midió; y ni el estado al fallar ni los plazos que vencen se ejercieron con un contenedor real (solo con el `docker` falso). No quedaron residuos: ningún contenedor `qmd`; las imágenes de prueba siguen en el Docker del operador (`agent-admin:qmd-real` nueva, las demás de hace dos semanas) y los modelos en `~/.cache/agentic-qmd-e2e/models-041`.
- **Gate completo (T027), ronda 1, sobre el árbol de la primera revisión (16-10-2026)**: sobre el árbol real congelado (huella sha256 `af9a9a70…` de los 21 archivos modificados o nuevos, idéntica antes, entre las dos corridas y después; `git status` y `HEAD` sin cambios), `bats --tap tests/` secuencial con stderr vacío: **bash 5.3.15 (Bats 1.13.0): 1853 ok / 0 not ok / 55 saltados, plan `1..1853`, 19 min 45 s; bash 3.2.57: 1853 ok / 0 not ok / 56 saltados, plan `1..1853`, 20 min 39 s**. Es la línea base del árbol anterior a la segunda revisión, no el gate final: sus cambios lo invalidan, y T027 se repite sobre el árbol final con el esperado nuevo (1854).
- **Gate completo (T027), ronda final, sobre el árbol final (16-10-2026)**: sobre el árbol real congelado (huella sha256 de los 21 archivos modificados o nuevos, `854e2087241a…`, idéntica antes, entre las dos corridas y después; `git status` y `HEAD` sin cambios), `bats --tap tests/` secuencial y con stderr vacío. **bash 5.3.15 (Bats 1.13.0): 1854 ok / 0 not ok / 55 saltados, plan `1..1854`, 19 min 10 s. bash 3.2.57: 1854 ok / 0 not ok / 56 saltados, plan `1..1854`, 20 min 58 s.** Esperado: 1854 = 1817 de T001 más 37 (los 36 del oráculo y el e2e 041, que en el host sale saltado: los 54 y 55 saltados de la línea base pasan a 55 y 56). Además, con `verify_all.sh` del scratchpad sobre el mismo árbol, antes del gate: oráculo 36 de 36 y `tests/ci-workflows.bats` 14 de 14 en los dos bash; oráculo más `ci-workflows` (50 de 50) con el yq v4.44.3 de la CI (el binario compilado en local para 040: no se descargó nada), con la SIGPIPE ignorada como la entrega el runner y con bats 1.11.0 (la versión de la CI Linux), en los dos bash; `tests/docker-e2e-qmd.bats` carga y salta limpio sin `DOCKER_E2E` (5 tests); shellcheck con el comando exacto de la CI en rc 0 (51 archivos, el script de obtención incluido; limpio también a severidad `style`); el ensayo en seco del test 041 contra el `docker` falso da `ok` con las ocho marcas en orden en los dos bash y, en los escenarios de falla, imprime el bloque del estado al fallar; PyYAML confirma la estructura del workflow, con los dos `run:` congelados idénticos a `HEAD`. Comprobaciones finales: `git diff --stat HEAD -- docker scripts modules setup.sh VERSION` vacío; `origin/main` sigue en `13cafc3` (el mismo `HEAD` de la rama, con `VERSION` 0.28.0, sin cambio); el script y los dos fixtures solo con ASCII; cero marcas combinantes en `specs/041-nightly-qmd-embed/` y en los archivos editados, y ningún símbolo de clase emoji nuevo respecto de `HEAD` (las marcas de verificación y símbolos parecidos que hay en `CHANGELOG.md`, `CLAUDE.md` y `tests/docker-e2e-qmd.bats` ya estaban).
- **Decisiones del operador sobre el orden de las compuertas (16-10-2026, AskUserQuestion, las cuatro con la opción recomendada)**: (1) hacer los tres commits locales de T028 cuando el gate cerrara en verde; (2) correr T026 (DOCKER_E2E local en arm64) antes de lanzar E1; (3) lanzar E1 desde una rama de ensayo con `timeout-minutes: 45`, para medir la duración completa en una sola corrida, y mantener 30 en la rama del PR hasta decidir T033 con el número (el push y el `workflow_dispatch` se vuelven a pedir en su momento); (4) no versionar en 041 el ensayo con `docker` falso: se decide después de T026 y E1, en un PR aparte si hace falta.
- **Commits locales (T028, 16-10-2026)**: tres commits sobre `13cafc3`, en español, ASCII y sin atribución: los artefactos de spec-kit y `.specify/feature.json`; la implementación (`.github/`, `tests/` y `docs/qmd-upgrade-checklist.md`); y `CHANGELOG.md` con `CLAUDE.md`. Con los archivos ya en el índice, `git ls-files -s` mostró el modo `100755` en `.github/scripts/fetch-qmd-models.sh`, `tests/fixtures/qmd-e2e/fake-curl` y `tests/fixtures/qmd-e2e/vec0-libc.sh`, y W8 pasó en bash 5.x y 3.2 con el script ya versionado. Sin push.
- **Evidencia E1 (T030, 17-10-2026)**: corrida **39069243972**, `workflow_dispatch` sobre la rama de ensayo `041-e1-ensayo-45min`, commit `e4a4f9400b34a3addb1349f60011615ba2fd2437` (los cuatro commits de la rama de 041 y el que sube el tope a 45 min; `041-nightly-qmd-embed` seguía sin empujarse en ese momento: se empujó después, para E2). Log completo descargado y comprobado (546 líneas, trae `GNU bash, version 5.2.21`). **Resultado: rojo de producto en amd64, en la fase `setup`; 48 de 49 e2e en verde.**
  - **Entorno** (lo imprime el paso de 039): `server=28.0.4 os=Ubuntu 24.04.5 LTS arch=x86_64 cgroup=2 storage=overlay2`, Docker Compose v2.38.2, bats 1.11.0, bash 5.2.21, imagen del runner `ubuntu-24.04` 20261012.334.1.
  - **Job `docker e2e suite (DOCKER_E2E=1)`** (API de jobs, no las fechas de la corrida): `started_at` 21:02:31Z, `completed_at` 21:23:50Z, **21 min 19 s**. Margen frente al tope: 8 min 41 s si fuera de 30 min y 23 min 41 s con los 45 de la rama de ensayo. **Es la duración de una corrida roja que se detuvo en `setup`; no es la de una corrida verde** (ver FR-013 más abajo). Pasos: `Verify deps + docker` 2 s, `Fetch the qmd models` 40 s, `Run docker-e2e suite` 20 min 29 s (21:03:18Z a 21:23:47Z).
  - **Obtención de los modelos** (`fetch_models`, en verde a la primera): `hf_ggml-org_embeddinggemma-300M-Q8_0.gguf` 333.590.944 bytes, 1 intento, 8 s; `hf_tobil_qmd-query-expansion-1.7B-q4_k_m.gguf` 1.282.438.912 bytes, 1 intento, 32 s; total 1.616.029.856 bytes en 40 s (unos 40 MB/s); `free_kb` 89.938.996 antes y 88.360.832 después. En el Mac había tomado 191 s.
  - **TAP**: `1..49`; `ok 15 qmd real (016): native deps compile with toolchain; RED without it (SC-003)` (232,6 s, en amd64) y `not ok 16 qmd real (041): embed phase - setup, models, vector extension, reindex, semantic search, MCP` (374,8 s; línea 836 del test, el `false` que sigue al informe de la falla del setup). `e2e summary: total=49 executed=49 skipped=0 failed=1` y el paso termina con rc 1. Los otros 47 pasan, entre ellos el 12 (el del vigilante de inotify que fallaba en 039) y los dos de qmd 037.
  - **Fases del test 041** (marcas con su hora): `models-seed` 21:13:49,996Z (9 ms), `boot` 21:13:50,005Z (1,5 s: las capas de la imagen salieron todas de la caché que dejó el test 016 en el mismo job), `setup` 21:13:51,483Z, que terminó **en rojo a los 369 s** (informe a las 21:20:00,808Z; por diseño del test incluye la compilación nativa de llama.cpp en su propio directorio de estado y el intento de `embed`). **No se imprimieron** `vector-extension`, `reindex`, `semantic-search`, `mcp` ni `models-untouched`, ni la línea `# qmd embed resources:` (se emite al final).
  - **Clasificación: rojo de producto, amd64.** Fragmento que lo prueba, del log del contenedor: `[qmd] setup: 'embed' failed/timed out: ... sqlite-vec extension is unavailable. Error loading shared library /home/agent/.cache/qmd/pkg/node_modules/sqlite-vec-linux-x64/vec0.so.so: No such file or directory` (el `.so.so` es el segundo intento de SQLite al cargar la extensión, no un archivo ausente), y el estado al fallar, volcado desde dentro del contenedor: `x86_64` y `GLIBC /home/agent/.cache/qmd/pkg/node_modules/sqlite-vec-linux-x64/vec0.so` (159.816 bytes: el prebuilt glibc del paquete x64, dentro de un contenedor Alpine/musl). Causa, leída en el código antes de E1 y ahora medida: `_qmd_swap_sqlite_vec` (`scripts/lib/qmd_index.sh:130`) solo apunta a `sqlite-vec-linux-arm64/vec0.so` y, con el paquete x64, sale por `[ -e "$target" ] || return 0` sin hacer nada ni avisar. Descartados por el mismo volcado: no es memoria (`oom=false exit=0 restarts=0`, los seis contadores de `memory.events` en 0, `memory.peak` 3.420.876.800 bytes = 3,19 GiB), ni disco (82.435.460 KB libres), ni red o modelos (la obtención y `models-seed` pasaron), ni el arnés (las marcas, el plazo de 600 s, el volcado y el informe se comportaron como se diseñaron). `qmd-index.json`, `qmd-reindex.out` y `vsearch.out` no existen porque las fases que los escriben no se alcanzaron.
  - **Qué prueba E1 y qué no.** Prueba, en amd64 y en un runner real: el paso `fetch_models` (40 s, tamaño y sha256 verificados por el script), el paso de `$GITHUB_ENV` hacia la suite (`QMD_E2E_MODELS_DIR` aparece en el `env:` del paso de la suite), las fases `models-seed` y `boot`, el rojo atribuido a la fase `setup` con su volcado de estado (la primera vez que `_embed_failure_state` corre en un contenedor real) y que el test 016 pasa en amd64. **No prueba** nada de las cinco fases siguientes en amd64 (siguen verificadas solo en arm64 por T026) ni la duración de una corrida verde.
  - **Rama de ensayo**: `041-e1-ensayo-45min` se borró el 17-10-2026 (remota y local) con el visto bueno del operador. Su único commit propio era `e4a4f9400b34a3addb1349f60011615ba2fd2437` (solo `timeout-minutes: 30` a `45`) y el tope de 45 min no hizo falta: el job duró 21 min 19 s. La corrida 39069243972 y su log siguen consultables.
  - **E2, E3 y E4**: E2 hecha y en verde (issue #107 abierto e interruptor fijado el 17-10-2026; ver su viñeta más abajo); E3 hecha, con el resultado esperado (ver su viñeta más abajo); **E4 no aplica** (T035 es solo si E1 fue verde; el rojo real de E1 ya muestra lo que E4 quería mostrar: una rotura pone el job en rojo, el TAP trae `not ok` con la última marca en `setup` y el volcado dice por qué). **T031 no aplica** (E1 no mostró ningún defecto de arnés).
- **Evidencia E2 (T032 y T029, 17-10-2026)**: corrida **39081039747**, `workflow_dispatch` sobre `041-nightly-qmd-embed`, commit `239ac2fd8c0fa5fe2452d75a46dd646c1d665c2f` (seis commits sobre `13cafc3`; primer push de la rama, por HTTPS con el helper de gh, con el visto bueno del operador). Log descargado y comprobado (290 líneas, trae `GNU bash, version 5.2.21`). **Resultado: verde, con la fase del embed apagada por el defecto #107, como se esperaba.**
  - **Job** (API de jobs): `started_at` 23:58:46Z del 17-10, `completed_at` 00:10:38Z del 18-10, **11 min 52 s**; margen de **18 min 8 s** frente a los 30 min del PR. Pasos: `Fetch the qmd models` en menos de 1 s (no descarga nada), suite 11 min 45 s (23:58:51Z a 00:10:36Z). Es más corto que los 13 a 15 min de las nocturnas de 039; coincide con que `qmd real (016)` ya no lleva el embed (183 s aquí, contra 288,5 s medidos antes) y con que el test 041 sale saltado, aunque una sola corrida no separa eso de la variación entre runners.
  - **Lo que muestra el log**: el paso `fetch_models` emite `##[warning]fase del embed apagada por defecto abierto: #107 sqlite-vec x64 sin reemplazo musl, el embed falla en amd64`; la suite recibe `QMD_EMBED_SKIP_REASON` con ese texto y no recibe `QMD_E2E_MODELS_DIR`; el TAP trae `ok 16 qmd real (041): embed phase - setup, models, vector extension, reindex, semantic search, MCP # skip fase del embed apagada por defecto abierto: #107 sqlite-vec x64 sin reemplazo musl, el embed falla en amd64`, sin ninguna marca `# qmd embed phase:`; y `e2e summary: total=49 executed=48 skipped=1 failed=0`. Los otros 48 e2e pasan en amd64.
  - **Qué prueba**: el interruptor funciona de punta a punta en un runner real (el defecto queda nombrado en la anotación, en el TAP y en el resumen; el job queda en verde; no se descarga nada) y el job con la fase apagada deja un margen amplio. **No prueba** la obtención fallida (E3) ni nada de la fase activa en amd64, que cierra #107.
- **Evidencia E3 (T034, 17-10-2026 a las 22:22 hora de Santiago, 01:22Z del 18)**: corrida **39086250738**, `workflow_dispatch` sobre la rama de ensayo `041-e3-ensayo-descarga`, commit `085370cd39e7c02953f0677577d4aff6829cfcbb` (dos líneas sobre `239ac2f`: `QMD_EMBED_DEFECT` vuelve a vacío, porque con el defecto puesto el paso sale antes de descargar, y el `file` del modelo de embeddings pasa a `embeddinggemma-300M-Q8_0-e3-no-existe.gguf`). Log descargado y comprobado (trae `GNU bash, version 5.2.21`). **Resultado: rojo atribuido a `fetch_models`, como se esperaba; el resto de la suite corrió y el test 041 salió saltado con el motivo.**
  - **Job**: `started_at` 01:22:35Z, `completed_at` 01:38:30Z, **15 min 55 s**, conclusión `failure`. `Fetch the qmd models` en rojo a los 40 s (01:22:40Z a 01:23:20Z); `Run docker-e2e suite` en verde, 15 min 8 s (01:23:20Z a 01:38:28Z).
  - **Lo que muestra el log**: tres intentos con `curl exit 22 (http 404)` (a las 01:22:40Z, 01:22:50Z y 01:23:20Z: las esperas de 10 y 30 s), `##[error]no se pudieron obtener los modelos de qmd (embed: curl exit 22 (http 404); paso fetch_models)` y `Process completed with exit code 1`. El paso de la suite corrió a pesar del rojo (su `!cancelled()`) y recibió `QMD_EMBED_SKIP_REASON` con ese mismo texto: **el runner aplica lo que un paso escribió en `$GITHUB_ENV` aunque ese paso termine con 1** (el supuesto de plataforma del residuo L9, que hasta ahora solo se había razonado, ahora medido). El TAP trae `ok 16 qmd real (041): … # skip no se pudieron obtener los modelos de qmd (embed: curl exit 22 (http 404); paso fetch_models)` y el resumen `e2e summary: total=49 executed=48 skipped=1 failed=0`. El segundo modelo no se intentó (el primero falló).
  - **Qué prueba**: la atribución de una falla de obtención en un runner real: el paso rojo es `fetch_models`, el test del embed no se vuelve rojo ni se confunde con una regresión, el resto de la suite corre y la tabla de esperas es la prevista.
  - **Observación para FR-013**: los mismos 48 e2e tardaron 11 min 45 s en E2 y 15 min 8 s en E3 (+29 %), sin cambio alguno en la suite: la variación entre runners es grande y el margen con la fase activa no se puede decidir con una sola corrida (queda para el arreglo de #107).
  - **Rama de ensayo**: `041-e3-ensayo-descarga` borrada el 17-10-2026 (remota, local y el worktree desechable), con el visto bueno del operador.
- **Decisiones de FR-013 y FR-014**:
  - **FR-014**: E1 confirma con medición el defecto de producto que hasta ahora era una inferencia. Rige la decisión del operador del 14-10-2026 (la opción recomendada): apagar la fase con un salto explícito que nombra el defecto y su seguimiento. **Issue de seguimiento abierto el 17-10-2026 con el visto bueno del operador: [#107](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/issues/107)**, con la evidencia de E1, la causa, el alcance del arreglo y cinco obligaciones de cierre (vaciar `QMD_EMBED_DEFECT`; correr con la fase activa; medir el margen y subir el tope primero si queda bajo 5 minutos; repetir la rotura inducida de E4; registrar los resultados en el PR del arreglo). Interruptor fijado en `.github/workflows/docker-e2e.yml`: `QMD_EMBED_DEFECT: '#107 sqlite-vec x64 sin reemplazo musl, el embed falla en amd64'` (W6 sigue en verde; la re-validación completa de ese árbol dio 15 de 15 PASS, con el oráculo en 36 de 36 en los dos bash). El defecto afecta solo a amd64 (los agentes desplegados corren aarch64, donde el reemplazo funciona según el DOCKER_E2E de 017 y T026); el arreglo vive en `scripts/lib/qmd_index.sh` y su espejo de `docker/`, fuera del alcance de 041.
  - **FR-013**: no se puede decidir con E1 y queda diferida. El job rojo duró 21 min 19 s con 8 min 41 s de margen, pero se detuvo en `setup`: faltan por medir en amd64 el `embed` que termina, el reindex (acotado a 600 s), la búsqueda (300 s), el MCP y `models-untouched`. Con la fase apagada por el defecto el job no descarga los modelos ni ejecuta el embed, y E2 lo midió: 11 min 52 s, o sea 18 min 8 s de margen contra los 30 min, así que el tope del PR no se toca. La medición con la fase activa, y la decisión de subir el tope primero si el margen queda bajo 5 minutos, pasan a la feature que arregle el producto, y el cuerpo del issue lo registra como obligación de cierre (FR-020). E3 sumó una observación: los mismos 48 e2e tardaron 11 min 45 s en E2 y 15 min 8 s en E3, una variación de 29 % entre runners, así que con la fase activa hará falta más de una medición.
- **Rebase sobre 040 y enmiendas (T037)**: No aplicó. 041 mergeó antes que 040 (PR #108, 19-10-2026); 040 sigue sin mergear al 29-10-2026 (`origin/main` no trae ningún commit suyo) y es 040 quien rebasa, con las enmiendas inversas de `specs/041-nightly-qmd-embed/contracts/workflow-delta.md` §3.
- **Noches posteriores al merge (T040, revisadas el 29-10-2026)**: seis nocturnas programadas sobre `0fc08a8`, con la fase apagada por #107 (`QMD_EMBED_DEFECT`), antes de que 042 la reactivara con su merge del 25-10-2026. Todas muestran en la línea TAP `ok 16 qmd real (041): ... # skip fase del embed apagada por defecto abierto: #107 sqlite-vec x64 sin reemplazo musl, el embed falla en amd64` y en el resumen `e2e summary: total=49 executed=48 skipped=1` (con `failed=0`, salvo la del 20-10). Los datos salen de `gh run list`, de la API de jobs (`started_at` y `completed_at` del job) y de los logs de cada corrida; el margen es 1800 s menos la duración del job.

  | Noche | Run | Job | Margen | Resultado |
  | --- | --- | --- | --- | --- |
  | 19-10 | 39238878067 | 14 min 58 s | 15 min 2 s | verde |
  | 20-10 | 39404141011 | 15 min 42 s | 14 min 18 s | roja: `not ok 17 E2E: scaffold + build + up + healthcheck` (ajena a la fase y al margen; `failed=1`) |
  | 21-10 | 39581040837 | 15 min 32 s | 14 min 28 s | verde |
  | 22-10 | 39759491063 | 12 min 45 s | 17 min 15 s | verde |
  | 23-10 | 39935068174 | 11 min 32 s | 18 min 28 s | verde |
  | 24-10 | 40081692223 | 12 min 35 s | 17 min 25 s | verde |

  Las tres nocturnas siguientes al merge de 041 (19, 20 y 21-10) cumplen lo que pide T040: la fase apagada por un defecto abierto y registrado (#107) y un margen de al menos 14 min 18 s. La del 20-10 terminó en rojo por el test 17, que no tiene que ver con la fase ni con el margen; las tres verdes seguidas son las del 21, 22 y 23-10, y la del 24-10 también. Ninguna quedó con menos margen ni con tiempo agotado, así que FR-013 no se reabre por esto. Desde la noche del 25-10-2026, con #107 cerrado por el PR #110 de 042, el salto ya no aparece y la fase corre: esas noches se registran en `specs/042-qmd-sqlite-vec-x64/tasks.md` (T035).

### Observaciones

- `CLAUDE.md` está versionado y `git status` sí muestra sus cambios (verificado el 15-10-2026). La viñeta de «Common gotchas» que dice lo contrario es inexacta. Se corrige en un PR de documentación aparte, con visto bueno del operador; no es parte de 041.
