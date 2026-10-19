---

description: "Tareas de 042-qmd-sqlite-vec-x64: el embed de qmd funciona en la imagen docker sobre amd64 y el nightly vuelve a ejercitarlo"
---

# Tasks: El embed de qmd funciona en la imagen docker sobre amd64 y el nightly vuelve a ejercitarlo

**Input**: `specs/042-qmd-sqlite-vec-x64/` ([spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [quickstart.md](quickstart.md), [contracts/](contracts/))

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: obligatorios y primero (Principio III; FR-007). Cada test se escribe y se ve en ROJO antes de su implementación, en bash 5.x y en 3.2. Salvo N6 y N10, que nacen verdes a propósito y los prueban M6 y M14 (N6) y M9a (N10), y E1 y E3 reforzadas, que ya estaban en verde y las prueban M13a y M13b.

**Organization**: por historia, en orden de **dependencia** sobre la misma función y el mismo archivo de pruebas, y no de prioridad (precedente de 040 y 041):

```text
US1 (P1) → US2 (P1) → US3 (P2)
```

- US1 va primero porque cambia el destino del reemplazo; US2 le agrega el rastro en el log a los caminos que quedan callados.
- US3 va al final porque necesita el arreglo; el PR #108 (041) ya está en `main` (squash `0fc08a8`, 19-10-2026).

**Orden de las pruebas dentro de una historia**: N7 y N8 se escriben en US1 (no en US2) porque describen el camino x64 completo y solo se ven en ROJO contra el código original; si se escribieran después de US1 nacerían verdes.

**Compuertas**: cada commit, push, `workflow_dispatch`, creación o borrado de una rama remota, issue, PR y merge exige la confirmación explícita del operador, CADA VEZ, y está marcado COMPUERTA. Nada se commitea antes de T002. No existe ningún hook de contexto de agente que ejecutar (`hooks: {}`). El PR #108 (041) ya está mergeado en `main` (squash `0fc08a8`, 19-10-2026): la implementación no espera nada de él y T001 solo deja registrada la verificación. T021 no lleva COMPUERTA: corre en contenedores desechables (`--rm`), baja unos pocos MB (la imagen `alpine:3.24.1` de cada arquitectura, la amalgamación publicada de `sqlite-vec` que descarga el propio `docker/scripts/build-sqlite-vec.sh`, los paquetes `build-base`, `bash` y `sqlite`, y el `sqlite-dev` que ese script instala por su cuenta) y dura un par de minutos; la imagen base no trae `bash`, que `scripts/lib/qmd_index.sh` necesita, así que T021 lo instala. T022 sí lleva COMPUERTA porque ocupa Docker Desktop unos 9 minutos con la imagen servida desde la caché de capas (T026 de 041 no midió el build de la imagen; T015 cambia `docker/scripts/build-sqlite-vec.sh`, copiado en `docker/Dockerfile:64`, y las capas desde esa línea se reconstruyen en T022, con un costo no medido), usa 1,6 GB de modelos y llega a unos 4,3 GiB de memoria (T026 de 041).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: se puede hacer en paralelo (archivos distintos, sin dependencia de una tarea abierta)
- **[Story]**: la historia del spec a la que sirve la tarea (US1 a US3)
- Las rutas son relativas a la raíz del worktree `.claude/worktrees/042-qmd-sqlite-vec-x64`.
- Las herramientas de medición y de auditoría viven en el scratchpad de la sesión y no se versionan.

---

## Phase 1: Setup

**Purpose**: confirmar que 041 está en `main`, rebasar, y medir la línea base antes de tocar nada.

- [x] T001 Verificar, solo con lecturas, que el PR #108 (041) está mergeado y registrar en las Notes de `specs/042-qmd-sqlite-vec-x64/tasks.md`: el commit de merge en `origin/main`, `git show origin/main:VERSION` y si `origin/main` trae `tests/qmd-embed-nightly.bats` y `.github/scripts/fetch-qmd-models.sh`. Si el PR no está mergeado, **detenerse y avisar al operador**: ninguna tarea posterior corre antes. Las lecturas pasan por `gh` o por `git ls-remote` y `git fetch` con el helper de `gh` por HTTPS (el remoto `origin` es SSH y pertenece a otra cuenta). HECHA el 19-10-2026: el PR #108 está mergeado (squash `0fc08a8` en `origin/main`, después de los PR #104 y #105, que solo tocan documentos); `VERSION` en `origin/main` da 0.28.0; `origin/main` trae `tests/qmd-embed-nightly.bats` y `.github/scripts/fetch-qmd-models.sh`; el detalle está en el Registro.
- [ ] T002 COMPUERTA (commit local): commitear los artefactos de spec-kit de esta rama (`specs/042-qmd-sqlite-vec-x64/**` y `.specify/feature.json`) con un mensaje en español, ASCII, en imperativo, sin atribución y con la identidad personal (Rodrigo Andres Hinojosa Acuña, `rodrigo.hinojosa.developer@gmail.com`, por variables de entorno `GIT_AUTHOR_*` y `GIT_COMMITTER_*`). Sin push.
- [ ] T003 Rebasar la rama sobre `origin/main` ya con 041 (sin push):
  - resolver `.specify/feature.json` quedándose con `specs/042-qmd-sqlite-vec-x64`; no hay otros conflictos mientras esta rama solo lleve `specs/` (los de `CHANGELOG.md`, `CLAUDE.md` y `docs/qmd-upgrade-checklist.md` se evitan editándolos después del rebase);
  - verificar que el árbol rebasado conserva `specs/041-nightly-qmd-embed/`, el workflow con `QMD_EMBED_DEFECT: '#107 ...'` y `tests/qmd-embed-nightly.bats`;
  - verificar `VERSION` contra `git show origin/main:VERSION` A MANO (git no avisa cuando dos ramas escriben el mismo número: lección de 023); registrar el valor.
- [ ] T004 Medir la línea base de la suite del host en una copia aislada de `origin/main` (un `git worktree add --detach` en el scratchpad, que se quita con `git worktree remove` y `git worktree prune` al terminar, para no dejar el registro huérfano que dejó 041):
  - correr `bats --tap tests/` en bash 5.x y después con `PATH=/bin:$PATH` (bash 3.2.57), en forma secuencial, con la salida de error vacía;
  - correr también `bats --tap tests/qmd-sqlite-vec.bats` en los dos bash y comprobar las 7 pruebas actuales;
  - registrar en las Notes ok, not ok, saltados y duración de cada corrida;
  - registrar el esperado final: **línea base medida + 11** (las 11 pruebas nuevas de `contracts/host-oracle.md` §2).

  Antes de medir, revisar `ps` por procesos `bats` ajenos. Si aparece un rojo, se vuelve a medir en aislamiento antes de nombrarlo.
- [ ] T005 [P] Comprobar que siguen los dos modelos de 041 para V3: `~/.cache/agentic-qmd-e2e/models-041` con 2 archivos y 1.616.029.856 bytes en total (tamaño y sha256 de cada uno, con la tabla de `.github/scripts/fetch-qmd-models.sh`). Si faltan, COMPUERTA: obtenerlos con `QMD_MODELS_DIR=<dir> .github/scripts/fetch-qmd-models.sh` descarga unos 1,6 GB del origen y pide el visto bueno del operador.

---

## Phase 2: Foundational

**Purpose**: el seam de arquitectura y las ayudas del oráculo, que necesitan todas las historias.

**CRITICAL**: ninguna historia empieza antes de cerrar esta fase.

- [ ] T006 En `tests/qmd-sqlite-vec.bats` (`contracts/host-oracle.md` §1), sin cambiar ninguna prueba existente:
  - agregar al `setup()` la línea `export QMD_MACHINE_ARCH=aarch64`, para que las cinco pruebas actuales (disposición arm64) valgan en cualquier host;
  - agregar `_mk_pkg SUFIJO`, que crea `node_modules/sqlite-vec-linux-SUFIJO/vec0.so` bajo `$PREFIX` con el contenido `GLIBC-PREBUILT-SUFIJO` (para distinguir cuál paquete quedó tocado);
  - agregar `_fake_uname VALOR`, que escribe en el directorio temporal un ejecutable `uname` que anota cada invocación en `$TMP_TEST_DIR/uname.calls`, imprime `VALOR` cuando se le pasa `-m` y delega en el `uname` real para cualquier otra opción (resolver el real con `command -v` antes de alterar el `PATH`), y lo antepone al `PATH`; el archivo de anotaciones permite afirmar que en glibc la función no llama a `uname` (N6).

  Verificar que el archivo carga y que las 7 pruebas siguen en verde en los dos bash, porque la función actual ignora el seam.

**Checkpoint**: el oráculo conserva su verde con el seam puesto y las ayudas disponibles.

---

## Phase 3: User Story 1 - Quien corre el agente en x86_64 tiene búsqueda semántica, como en arm64 (Priority: P1), MVP

**Goal**: en una máquina musl x86_64 el reemplazo actúa sobre el paquete `sqlite-vec-linux-x64`; en arm64 todo queda como hoy; en glibc no hace nada (FR-001 a FR-004 y FR-006).

**Independent Test**: en el host y sin Docker, N1, N2, N3, N6 a N10 y las cinco pruebas existentes en verde en los dos bash; en V2 (T021), la función real en un Alpine amd64 carga la extensión.

- [ ] T007 [US1] ROJO: escribir N1, N2 y N3 en `tests/qmd-sqlite-vec.bats` (`contracts/host-oracle.md` §2). N1: con `QMD_MACHINE_ARCH=x86_64` y solo el paquete x64 (la disposición que midió la corrida E1 de 041, no la de la prueba E1 de este archivo, que usa el paquete arm64), el `vec0.so` queda con `MUSL-BUILD` y el log trae la línea L-OK. N2: con los dos paquetes presentes, solo se reemplaza el de la arquitectura de la máquina (con `x86_64`, el x64; con `aarch64`, el arm64) y el otro conserva su contenido; son dos vueltas y cada una reconstruye el prefijo (`rm -rf "$PREFIX/node_modules"`, `_mk_pkg x64` y `_mk_pkg arm64`), porque tras el primer reemplazo el paquete queda en musl y la vuelta siguiente pasaría en vacío. N3: un bucle por los cuatro nombres, que también reconstruye el prefijo en cada vuelta y afirma el contenido de cada paquete por separado (el esperado con `MUSL-BUILD`, el otro con su `GLIBC-PREBUILT-<sufijo>`); el mapa es **`x86_64` y `amd64` dan `x64`; `aarch64` y `arm64` dan `arm64`**. Correr en bash 5.x y 3.2 y registrar en las Notes que las tres están en ROJO.
- [ ] T008 [US1] ROJO: escribir N7 y N8 en `tests/qmd-sqlite-vec.bats`. N7: con `x86_64` y el paquete x64, tras la primera llamada el `vec0.so` tiene `MUSL-BUILD` y el log trae la línea L-OK (`swapped glibc prebuilt for musl build`); la segunda llamada tiene rc 0, salida vacía y el mismo contenido. Sin la afirmación de la primera, contra el código original las dos llamadas son mudas y la prueba pasaría en vacío. N8: con `x86_64`, el prefijo solo con el paquete x64, su `vec0.so` en solo lectura (modo 444) y su directorio sin escritura (modo 555), la función devuelve 0, el log contiene `swap failed (cp)` y el archivo conserva su contenido; se salta (`skip`) si `id -u` es 0, porque root ignora los modos. El archivo de pruebas no tiene `teardown` y no se agrega uno: los modos se restauran en línea con `chmod`, justo después de la llamada y antes de las aserciones, para que un fallo de aserción no deje un directorio que no se pueda borrar. Registrar el ROJO de las dos en las Notes (contra el código original, las dos fallan porque el paquete x64 nunca se toca).
- [ ] T009 [US1] ROJO: escribir N6, N9 y N10 y reforzar E1 y E3 en `tests/qmd-sqlite-vec.bats`. N6: sin cargador musl, con el paquete x64, con `QMD_MACHINE_ARCH` sin definir (`unset`) y `_fake_uname x86_64`, la función devuelve 0, no imprime nada, no cambia el archivo y `uname.calls` no existe o está vacío (nace verde a propósito: guarda la salida temprana en glibc y que la función no llame a `uname` ahí, invariante I4; la prueban M6 y M14; se solapa a propósito con E2, que cubre la disposición arm64 en glibc). N9: con `QMD_MACHINE_ARCH` sin definir (`unset`) y `_fake_uname x86_64`, se reemplaza el paquete x64 (ejerce el camino de producción, sin el seam). N10: igual con `_fake_uname aarch64` y el paquete arm64 (nace verde a propósito: guarda la ruta por defecto y la prueba M9a). E1 reforzada: además del contenido `MUSL-BUILD`, el log trae `swapped glibc prebuilt for musl build` (la línea de hoy, FR-002; está en verde contra el código original y la prueba M13a). E3 reforzada: además de `unavailable`, el log trae `musl build absent` (L-ABS; `unavailable` también lo traen L-PKG, L-ARCH y L-CP, y sola ya no identifica la rama; en verde contra el código original, y la prueba M13b). Registrar en las Notes: N9 en ROJO; N6, N10, E1 reforzada y E3 reforzada en verde, con la razón.
- [ ] T010 [US1] Implementar en `scripts/lib/qmd_index.sh`, en `_qmd_swap_sqlite_vec` (líneas 122 a 144, con su comentario de cabecera de las líneas 122 a 127) y en el comentario que antecede a `QMD_VEC0_MUSL_SO` (líneas 105 a 111; la 107 nombra solo el paquete arm64 y la 108 solo su cargador, `ld-linux-aarch64.so.1`):
  - mantener la guarda de musl como primera instrucción y consultar la arquitectura **después** de ella (la función no bifurca `uname` en glibc: invariante I4 de `contracts/swap-sqlite-vec.md`);
  - la arquitectura es `$QMD_MACHINE_ARCH` si la variable está definida (aun vacía; se prueba con `${QMD_MACHINE_ARCH+x}`, como `QMD_MUSL_LOADER`) y, si no, la salida de `uname -m`; la asignación va separada de `local` para no enmascarar el estado y tolera el fallo de `uname` (`arch=$(uname -m 2>/dev/null || true)`), porque bajo `set -e` un `uname` que falla abortaría al llamador y el contrato promete estado 0 (I5); un `uname` que falla deja la arquitectura vacía y cae en la rama «no soportada»;
  - el mapa es el de T007; cualquier otro valor, o vacío, sale con `return 0` sin hacer nada (la línea de log de esta rama la agrega US2);
  - el destino es `$prefix/node_modules/sqlite-vec-linux-<sufijo>/vec0.so`; si no existe, `return 0` sin hacer nada (la línea de log la agrega US2);
  - el resto queda igual: la build ausente, el `cmp -s`, el `cp -f` y las tres líneas de log existentes, con su texto sin cambio (FR-002);
  - documentar `QMD_MACHINE_ARCH` en el comentario junto a `QMD_MUSL_LOADER` como seam de pruebas, no como perilla del operador;
  - solo constructos de bash 3.2 (`case`, glob; nada de `${x,,}`).
- [ ] T011 [US1] Punto de control en bash 5.x y en 3.2: las cinco pruebas existentes, N1 a N3 y N6 a N10 en VERDE (13 pruebas de la función más G1 y G2: 15 de 15 en este punto, con E5 todavía en su forma original); `bats tests/qmd-index.bats tests/qmd-setup.bats` sin cambios de resultado; `shellcheck -S error -e SC1090,SC1091 scripts/lib/qmd_index.sh` (las opciones del paso `Run shellcheck` de `.github/workflows/shellcheck.yml`; el paso completo, que recorre todo el árbol con `find ... | xargs`, se corre en T023), rc 0. Registrar en las Notes.

**Checkpoint**: el reemplazo ya funciona para las dos arquitecturas y el oráculo lo prueba sin Docker. Los caminos que no pueden reemplazar siguen callados (US2).

---

## Phase 4: User Story 2 - Un reemplazo imposible deja rastro y no tumba nada (Priority: P1)

**Goal**: cuando no hay nada que reemplazar el log lo dice, con la arquitectura esperada y los paquetes que había, y la función sigue devolviendo 0 (FR-004 y FR-005, SC-003).

**Independent Test**: en el host, E5 reforzada, N4 y N5 en verde; con prefijos falsos el log nombra la causa y, cuando la causa es el paquete, los paquetes presentes, sin una segunda corrida.

- [ ] T012 [US2] ROJO: en `tests/qmd-sqlite-vec.bats`, reforzar E5 (la prueba "swap is a no-op when the sqlite-vec package dir is absent": nuevo nombre "swap with no sqlite-vec package at all logs that none was found") para que, además del rc 0, afirme que el log contiene `no sqlite-vec-linux-arm64 package` y `found: none`; y escribir N4 y N5 (`contracts/host-oracle.md` §2). N4: con `x86_64` y solo el paquete arm64, rc 0, una sola línea de log (`[ "${#lines[@]}" -eq 1 ]`) que contiene `no sqlite-vec-linux-x64 package` y `found: sqlite-vec-linux-arm64`, y el `vec0.so` ajeno no cambia. N5: con `riscv64` y con vacío (seam definido y vacío), rc 0, una sola línea de log que contiene `no musl build for machine architecture` y la arquitectura cruda (`'riscv64'` o `''`), y ningún archivo cambia; es una rama defensiva (la imagen solo se construye en x86_64 y aarch64) y la prueba existe para que, si alguna vez ocurre, no sea otro camino callado. La exigencia de una sola línea guarda la invariante I6 y la prueba M15. Registrar en las Notes que las tres están en ROJO en bash 5.x y 3.2.
- [ ] T013 [US2] Implementar en `scripts/lib/qmd_index.sh` las dos líneas nuevas, con el texto exacto de `contracts/swap-sqlite-vec.md` §5 (una línea, ASCII, sin color, por `_qmd_log`) y sin tocar las tres existentes:
  - **L-PKG**, en la rama "falta el paquete de la arquitectura": `sqlite-vec: no sqlite-vec-linux-<sufijo> package in the managed prefix (found: <lista>) - vector embed unavailable, lexical index intact`, donde `<lista>` son los nombres (sin ruta) de los directorios `node_modules/sqlite-vec-linux-*` que existen, separados por un espacio y en el orden del glob, o `none` si no hay ninguno; recorrer con un glob que ignore lo que no sea directorio (sin `nullglob` ni `ls`);
  - **L-ARCH**, en la rama "arquitectura no soportada": `sqlite-vec: no musl build for machine architecture '<arch>' (supported: x86_64, aarch64) - vector embed unavailable, lexical index intact`, con `<arch>` el valor crudo, entre comillas simples (vacío se ve `''`);
  - ambas ramas siguen saliendo con `return 0`; a lo sumo una línea por llamada (invariante I6).
- [ ] T014 [US2] Punto de control en bash 5.x y en 3.2: E5 reforzada, N4 y N5 en VERDE y el resto sin regresiones (el archivo completo: 17 de 17, a falta de N11); ejecutar a mano la función bajo `set -euo pipefail` en un shell nuevo para cada fila D1 a D7 de `data-model.md` §5, más la fila «`uname` falla» (un `uname` falso en el `PATH` que sale con 1 sin imprimir nada, con el seam sin definir: debe dar la línea L-ARCH con `''`, estado 0 y nada por la salida estándar), y comprobar que ninguna aborta al llamador y que ninguna imprime por la salida estándar; `shellcheck` rc 0. Registrar en las Notes.

**Checkpoint**: el reemplazo funciona para amd64 y arm64, y cada camino que no puede reemplazar lo dice. El producto está arreglado; falta la documentación, la evidencia con contenedor real y la reactivación del nightly.

---

## Phase 5: Polish (local; sin compuertas salvo T022)

**Purpose**: documentación, versión, mutaciones, revisión independiente y verificación con contenedor antes de salir del host.

- [ ] T015 [P] ROJO y VERDE de N11 y de los documentos (FR-012):
  - escribir N11 en `tests/qmd-sqlite-vec.bats` (`contracts/host-oracle.md` §2): `docs/qmd-upgrade-checklist.md` contiene `sqlite-vec-linux-x64`, `sqlite-vec-linux-arm64` y la regla de nombre `sqlite-vec-${plataforma}-${arquitectura}`; correr y registrar el ROJO;
  - en `docs/qmd-upgrade-checklist.md`: la nota de la línea 32 y el ítem "017 swap path" (líneas 66 a 69; la 69 es la frase final del ítem) pasan a nombrar los dos paquetes y la regla, y piden verificar al subir qmd o sqlite-vec que `getLoadablePath()` siga armando `sqlite-vec-${plataforma}-${arquitectura}` y que el reemplazo cubra las arquitecturas que el paquete publique;
  - en `docs/architecture.md` (línea 336) y `docs/vault.md` (línea 539): una frase que diga que el reemplazo actúa sobre el paquete de la arquitectura de la máquina (x64 o arm64) y que, cuando no hay nada que reemplazar, el log lo dice; además, en `docs/vault.md` el párrafo de las líneas 540 a 541 y el paso 3 del diagnóstico (líneas 697 a 699) atan hoy `vector embed unavailable, lexical index intact` a una sola causa (el artefacto horneado ausente: reconstruir la imagen con `QMD_NATIVE_TOOLCHAIN=1`); como L-PKG y L-ARCH comparten ese cierre, se reescriben para distinguir las causas por el comienzo de la línea (`musl build absent`, `no sqlite-vec-linux-<sufijo> package`, `no musl build for machine architecture`); `docs/adding-an-mcp.md` solo cita la función y no cambia;
  - en el comentario de cabecera de `docker/scripts/build-sqlite-vec.sh` (líneas 5 y 6, que dicen «The npm prebuilt (node_modules/sqlite-vec-linux-arm64/vec0.so) is a GLIBC binary (needs ld-linux-aarch64.so.1 + fortified __memcpy_chk/__fread_chk@GLIBC_2.17)»): nombrar los dos paquetes (`sqlite-vec-linux-x64` y `sqlite-vec-linux-arm64`) y dejar el cargador y los símbolos GLIBC como propios de cada arquitectura (en arm64, `ld-linux-aarch64.so.1`), sin tocar una sola línea ejecutable;
  - verificar N11 en VERDE y que la parte de `docker/` no cambió ninguna línea que no sea comentario (revisión de privilegios, Principio II).
- [ ] T016 [P] Borrador de la entrada de `CHANGELOG.md` (FR-012), con `VERSION` 0.28.0 a 0.29.0: el defecto (#107, la corrida 39069243972, el síntoma y la causa), el arreglo (el mapa de arquitectura, el seam `QMD_MACHINE_ARCH`, las dos líneas de log nuevas), lo que no cambia (arm64, glibc, versiones de qmd y sqlite-vec, la base Alpine), la verificación (las 11 pruebas nuevas, el humo local en amd64 y en arm64, el DOCKER_E2E) y qué falta (la evidencia de CI de US3, que se completa en T032).
- [ ] T017 [P] En `CLAUDE.md`, a mano (FR-012): la viñeta "`_qmd_swap_sqlite_vec` only knows the arm64 layout" pasa a decir que el reemplazo elige el paquete por arquitectura y deja rastro cuando no hay nada que reemplazar, con #107 y la corrida de la que salió; en la viñeta larga del nightly («A workflow `run:` is shell too...»), la oración final conserva el mecanismo del salto por defecto abierto y pierde «today `#107`, see the `_qmd_swap_sqlite_vec` bullet below»; el bloque de 041 registra que mergeó (PR #108, squash `0fc08a8`, 19-10-2026) y que el arreglo de #107 lo hace 042; agregar una entrada de 042 en el bloque de características con el estado y los conteos (18 pruebas en `tests/qmd-sqlite-vec.bats`; host = línea base medida + 11). Las cifras de la evidencia de CI se agregan en T032.
- [ ] T018 Subir `VERSION` de 0.28.0 a 0.29.0 (MINOR, la práctica para las features que tocan código de runtime), **verificando antes `git show origin/main:VERSION` a mano** y que ningún otro PR haya tomado el número; registrar ambos valores en las Notes. Revisar que `git grep -n 0.28.0` no deje ninguna referencia viva que deba cambiar con la versión (excluyendo CHANGELOG y las specs históricas): al 18-10-2026 los aciertos son `VERSION` y referencias históricas («anteriores a 0.28.0», «desde 0.28.0») en `README.md` (403, 411 y 419), `docs/architecture.md` (197), `docs/vault.md` (757) y `CLAUDE.md`; solo cambia el archivo `VERSION`, las demás no se «actualizan».
- [ ] T019 Ejecutar el catálogo de mutaciones M1 a M15 de `contracts/host-oracle.md` §3 (M9 y M13 en variantes, M9a y M9b, M13a, M13b y M13c: 18 corridas por bash) contra la implementación real, en bash 5.x y en 3.2, **sobre copias aisladas** de `scripts/lib/qmd_index.sh` y de la documentación (nunca sobre el árbol de trabajo; un script del scratchpad aplica cada una, corre solo `tests/qmd-sqlite-vec.bats` y restaura), **como usuario no root** (`id -u` distinto de 0: N8 se salta como root y M8 sobreviviría por una razón ajena a la prueba). Registrar en las Notes el test que cae con cada mutación, comprobar que cae por la aserción prevista y no por un error del arnés, y que cada una de las 11 pruebas nuevas, y también E1 y E3 reforzadas, cae con al menos una. Si alguna sobrevive, endurecer el oráculo y repetir antes de seguir.
- [ ] T020 Revisión independiente de solo lectura (agente `code-reviewer`) antes del gate completo, sobre `scripts/lib/qmd_index.sh`, `tests/qmd-sqlite-vec.bats`, la documentación editada y el comentario de `docker/scripts/build-sqlite-vec.sh`. Clasificar cada hallazgo y corregir los que correspondan, con su ROJO y su VERDE; las mutaciones nuevas que salgan se suman al catálogo como M16 en adelante. Buscar a propósito: pruebas que pasan en vacío, aserciones intermedias muertas, el estado de salida bajo `set -e`, y toda suposición sobre la arquitectura del host.
- [ ] T021 Humo local V2, amd64 emulado y pata arm64 nativa (`quickstart.md` V2), con una herramienta del scratchpad (`scratchpad/042/swap_smoke.sh`, no versionada) que acepta la plataforma y qué versión de la biblioteca cargar:
  - **ROJO**: con la biblioteca de `origin/main` (extraída con `git archive` a un directorio temporal, con sus bibliotecas hermanas), en un contenedor desechable `alpine:3.24.1` `--platform linux/amd64` con el repositorio y el paquete `sqlite-vec-linux-x64@0.1.9` publicado montados de solo lectura, hornear la build con `docker/scripts/build-sqlite-vec.sh`, armar el prefijo con el binario glibc, llamar a `_qmd_swap_sqlite_vec` y cargar la extensión con `sqlite3`: la función no cambia nada y la carga falla con `__memcpy_chk: symbol not found`;
  - **VERDE** (los paquetes que baja el contenedor incluyen `bash`, que la biblioteca necesita y la imagen base no trae): con la biblioteca de esta rama, la salida de error trae `swapped glibc prebuilt for musl build`, la carga devuelve `v0.1.9` y una segunda llamada no imprime nada; con solo el paquete arm64 en el prefijo la función dice `no sqlite-vec-linux-x64 package` y `found: sqlite-vec-linux-arm64`;
  - **Pata arm64 (FR-002, SC-002)**: el mismo script con `--platform linux/arm64` (nativo en este Mac, sin emulación), el paquete `sqlite-vec-linux-arm64@0.1.9` y, uno tras otro, la biblioteca de `origin/main` y la de esta rama: las dos deben dejar el `vec0.so` del paquete idéntico a la build horneada (`cmp -s`), imprimir la misma línea `swapped glibc prebuilt for musl build` y callar en la segunda llamada. Es la evidencia, con la función real, de que arm64 queda igual que hoy (T022 no la ve: el test 041 solo vuelca el log del contenedor cuando falla);
  - registrar en las Notes los tiempos y los resultados; recordar el residuo (la variante `linux/amd64` de `alpine:3.24.1` queda en el Docker del Mac y se ofrece quitarla en T036). Los contenedores son desechables (`--rm`); no tocar ningún otro contenedor ni imagen.
- [ ] T022 COMPUERTA (Docker Desktop y unos 9 minutos del operador): DOCKER_E2E local en arm64, `quickstart.md` V3, con `DOCKER_E2E=1 QMD_EMBED_E2E=1 QMD_E2E_MODELS_DIR=$HOME/.cache/agentic-qmd-e2e/models-041 bats --tap tests/docker-e2e-qmd.bats -f 'qmd real'`. Esperado: `qmd real (016)` y `qmd real (041)` en verde con las ocho marcas en orden y la línea `# qmd embed resources:`, como T026 de 041 (8 min 42 s, 4,3 GiB de pico). Registrar en las Notes. El test 041 solo vuelca el log del contenedor cuando falla (su `teardown`), así que en una corrida verde no se ve la línea `swapped glibc prebuilt for musl build` de arm64: esa parte de SC-002 la guardan E1 en el host (M13a) y la pata arm64 del humo de T021; aquí se comprueba el efecto (la fase `vector-extension` verifica con `vec0-libc.sh` que el `vec0.so` del paquete sea el musl). Un rojo de arnés acotado se corrige aquí; uno de producto detiene la secuencia (FR-013).
- [ ] T023 Gate completo (`quickstart.md` V7) sobre un árbol congelado (huella sha256 de los archivos modificados o nuevos, igual antes, entre las dos corridas y después; `git status` y `HEAD` sin cambios). Registrar en las Notes:
  - `bats --tap tests/` secuencial en bash 5.x y después en 3.2, con la salida de error vacía y el esperado de T004 + 11;
  - `tests/qmd-sqlite-vec.bats` con la señal SIGPIPE ignorada, como la entrega el runner (`perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats ...`), en los dos bash, y con bats 1.11.0 (la versión de la CI en Linux; clonar el tag en el scratchpad y revisarlo antes de ejecutarlo);
  - shellcheck con el comando exacto del paso `Run shellcheck` de `.github/workflows/shellcheck.yml` en rc 0;
  - `git diff --stat origin/main -- docker scripts modules setup.sh .github` solo con `scripts/lib/qmd_index.sh` y el comentario de `docker/scripts/build-sqlite-vec.sh`, y sin ninguna diferencia bajo `.github` en este punto (FR-014: ningún job ni matriz de arm64; el workflow solo cambia en T024 y, si T029 lo exige, en `timeout-minutes`);
  - `VERSION` igual a `git show origin/main:VERSION` más el bump de T018;
  - cero marcas combinantes en `specs/042-qmd-sqlite-vec-x64/` y en los archivos editados, y ningún símbolo nuevo respecto de `HEAD` (auditar con `scratchpad/042/byte_audit_042.py` y `plan_consistency.py`).

---

## Phase 6: User Story 3 - El nightly vuelve a ejercitar el embed, con el margen del tope medido (Priority: P2)

**Goal**: con el arreglo, el interruptor vacío y 041 en `main`, `qmd real (041)` pasa en amd64 con sus ocho marcas; la duración y el margen del job quedan medidos en al menos 3 corridas; una rotura inducida deja el job en rojo con la fase nombrada (FR-008 a FR-011 y FR-013, SC-001, SC-004, SC-005).

**Independent Test**: tres corridas por `workflow_dispatch` de la rama con el texto final, con `ok N qmd real (041)` ejecutado y `e2e summary:` sin fallas; una rama de ensayo con la imagen del test construida sin toolchain, en rojo con la última marca en `setup` o `vector-extension`.

- [ ] T024 [US3] Vaciar el interruptor (sin ROJO previo: ningún test del host cae con el valor encendido, porque W6 acepta el vacío y el formato registrado; la evidencia del cambio es el salto que desaparece en las corridas de T027): en `.github/workflows/docker-e2e.yml`, paso `Fetch the qmd models` (id `fetch_models`), dejar `QMD_EMBED_DEFECT: ''` (línea 80 en `origin/main` `0fc08a8`; la clave debe seguir presente porque W6 exige `has("QMD_EMBED_DEFECT")`) y quitar las tres líneas de comentario 77 a 79 (de `On since 17-10-2026 ...` a `... before closing it.`); las líneas 75 y 76, que explican el formato, se quedan; no tocar ningún `run:` (W2 y W3 guardan por sha256 los de `Verify deps + docker` y `Run docker-e2e suite`, y W1 el de la obtención). Correr `tests/qmd-embed-nightly.bats` (36 de 36), `tests/ci-workflows.bats` (14 de 14) y `tests/qmd-sqlite-vec.bats` en los dos bash y registrar en las Notes que estaban en verde antes y después.
- [ ] T025 [US3] COMPUERTA (commits locales): tres commits sobre la rama, con mensajes en español, ASCII, en imperativo y sin atribución, con la identidad personal, y verificando con `git ls-files -s` que el modo de los archivos no cambió: (1) la documentación, `CHANGELOG.md`, `CLAUDE.md` y `VERSION`, incluidos el comentario de `docker/scripts/build-sqlite-vec.sh`, la checklist que guarda N11 y los cambios de `specs/042-qmd-sqlite-vec-x64/` posteriores al commit de T002 (las marcas y el Registro de este archivo); (2) el arreglo y todas sus pruebas (`scripts/lib/qmd_index.sh` y `tests/qmd-sqlite-vec.bats`, N11 incluida, que ya encuentra la checklist actualizada del commit 1); (3) el interruptor vacío de T024. El orden evita un commit intermedio con la suite roja (N11 sin su documento), que complicaría `git bisect`: comprobar con `bats tests/qmd-sqlite-vec.bats` en un worktree desechable del scratchpad (`git worktree add --detach` por commit, que se quita al terminar) que cada uno de los tres queda en verde. Sin push.
- [ ] T026 [US3] COMPUERTA (push): empujar la rama `042-qmd-sqlite-vec-x64` por HTTPS con el helper de `gh`, con los commits de T002, T003 y T025 (el push publica `scripts/lib/qmd_index.sh`, `tests/qmd-sqlite-vec.bats` y `.github/workflows/docker-e2e.yml` con el interruptor vacío). Verificar que la cabeza del remoto coincide con la local.
- [ ] T027 [US3] COMPUERTA (dispatch): lanzar `gh workflow run docker-e2e.yml --ref 042-qmd-sqlite-vec-x64` (corrida 1) y seguirla con un monitor del scratchpad. Al terminar, descargar el log y **comprobar que trae `GNU bash, version` antes de buscar nada en él** (con `gh api .../jobs/<id>/logs` hace falta `--allow-escape-sequences`); registrar en las Notes lo de `contracts/nightly-reactivation.md` §3: identificador, rama y commit, `started_at` y `completed_at` del job por la API de jobs, duración, margen frente a los 30 minutos, duración de `setup`, la línea TAP del test 041 y el `e2e summary:`. Esperado: `ok N qmd real (041)` ejecutado (no saltado) con las ocho marcas, y `e2e summary:` sin fallas. Clasificar cualquier rojo (producto, arnés o infraestructura) con su fragmento de log antes de seguir. Regla para el de producto: si el log del contenedor dice `musl build absent` (la build horneada no existe en la imagen amd64), es el supuesto 2 del spec y se corrige en esta feature (el Dockerfile o `docker/scripts/build-sqlite-vec.sh`, con la revisión de privilegios del Principio II, su ROJO en el humo de T021 y una corrida nueva); cualquier otra causa de producto sigue FR-013 (T030).
- [ ] T028 [US3] COMPUERTA (dispatch): lanzar las corridas 2 y 3 de `.github/workflows/docker-e2e.yml` con el mismo texto y registrarlas igual en las Notes de `specs/042-qmd-sqlite-vec-x64/tasks.md`. Calcular el mínimo, el máximo y el margen mínimo de las tres.
- [ ] T029 [US3] Solo si el margen mínimo de T028 es menor de 5 minutos (FR-010; `contracts/nightly-reactivation.md` §3): subir `timeout-minutes` del job `e2e` (propuesta: 45) en `.github/workflows/docker-e2e.yml`, en un commit aparte (COMPUERTA de commit, push y dispatch), y volver a medir con otras 3 corridas. Compartir el prefijo compilado entre `qmd real (016)` y `qmd real (041)` no entra aquí. Registrar cada medición.
- [ ] T030 [US3] Solo si una corrida destapa otro defecto de producto en amd64, distinto de la build musl ausente que T027 manda corregir aquí (FR-013; por ejemplo, las opciones de compilación de llama.cpp pensadas para ARM): detener la secuencia, COMPUERTA: el operador abre un issue nuevo con la evidencia y las obligaciones de cierre; fijar `QMD_EMBED_DEFECT: '#<n> <motivo en ASCII>'` en `.github/workflows/docker-e2e.yml` (W6 de `tests/qmd-embed-nightly.bats` debe seguir en verde), COMPUERTA de commit, push y dispatch para ver el salto con el nuevo motivo, y avisar al operador. Ese defecto no se mezcla con este arreglo.
- [ ] T031 [US3] COMPUERTA (rama de ensayo): la rotura inducida (`contracts/nightly-reactivation.md` §4). En una rama de ensayo desde la punta final, que no se mergea, cambiar UNA línea de `tests/docker-e2e-qmd.bats` en un worktree desechable del scratchpad (para no tocar el árbol principal): el test `qmd real (041)` (línea 753 en `origin/main` `0fc08a8`) construye su imagen con `(cd "$D" && docker compose build)` (línea 802, sin `--build-arg`; la 803 hace `docker compose up -d` con la imagen recién construida) y esa línea pasa a `(cd "$D" && docker compose build --build-arg QMD_NATIVE_TOOLCHAIN=0)`, que es el mecanismo de la pata RED de `qmd real (016)` (línea 728). El compose del test lo renderiza `_qmd_real_ws` (líneas 640 a 688) con `QMD_NATIVE_TOOLCHAIN: "1"` en `build.args` (`modules/docker-compose.yml.tpl:26`); el flag de la línea de comandos lo anula, y `docker/Dockerfile` (`ARG QMD_NATIVE_TOOLCHAIN=1`, línea 56; bloque de las líneas 65 a 69) deja de instalar build-base y cmake, de compilar `bigstack.so` y de hornear el `vec0.so` musl. No tocar `_qmd_real_ws` ni la plantilla: los comparte `qmd real (016)`, cuya build VERDE (línea 698) necesita la toolchain. La fase `setup` espera `.qmd-setup-ok` hasta `QMD_E2E_SETUP_DEADLINE_S` (600 s por defecto, línea 825) y sale antes si el log del contenedor trae `[qmd] setup: '...' failed|timed out` o `[qmd] install: bun install failed` (línea 833); si ninguna aparece, el job puede acercarse al tope de 30 min (la rama de ensayo de E1 usó 45). Empujarla y lanzar el workflow. Esperado: job en rojo, `not ok N qmd real (041)`, última marca `# qmd embed phase:` en `setup` o `vector-extension` y el resto de la suite en verde. Registrar en las Notes y, con la confirmación del operador, borrar la rama (remota y local) y el worktree.
- [ ] T032 [US3] Ajustar `CHANGELOG.md` y `CLAUDE.md` al resultado real de T021 a T031 (las cifras del humo, el DOCKER_E2E arm64, las tres o más corridas, el margen, la decisión sobre el tope, la rotura inducida) y registrar en las Notes la decisión de FR-010. COMPUERTA de commit y push.

**Checkpoint**: el nightly vuelve a ejecutar la fase en amd64 con la duración y el margen medidos; el interruptor queda vacío.

---

## Phase 7: Cierre

**Purpose**: PR, merge, noches posteriores y limpieza.

- [ ] T033 COMPUERTA: abrir el PR contra `main` con el resumen, los identificadores de las corridas (V2 a V5), el resultado de V3, la medición del tope y las decisiones de FR-010 y FR-013, tomados de las Notes de `specs/042-qmd-sqlite-vec-x64/tasks.md`. `Closes #107` solo si están cumplidas y registradas las cinco obligaciones del issue (el interruptor vacío, la corrida con la fase activa en verde en amd64 con sus ocho marcas, la duración y el margen medidos, la rotura inducida en rojo con la fase nombrada y los resultados registrados). Antes de abrirlo, `git diff --stat origin/main -- .github` debe mostrar solo `.github/workflows/docker-e2e.yml` (el interruptor vacío y, si T029 lo aplicó, `timeout-minutes`) y ningún job ni matriz nuevos (FR-014). La CI debe mostrar el esperado vigente (T004 + 11) en los dos brazos de bash; si un brazo cae solo en la CI, reproducirlo en local (SIGPIPE ignorada; bats de Homebrew en macOS) antes de tocar nada, y el arreglo pasa por la COMPUERTA de commit y push.
- [ ] T034 COMPUERTA: merge del PR de T033 por el operador. Después, verificar que el `.github/workflows/docker-e2e.yml` de `origin/main` trae el interruptor vacío, que `scripts/lib/qmd_index.sh` es el validado y que `VERSION` es 0.29.0; y que #107 quedó cerrado por el PR (si no, COMPUERTA: cerrarlo con la evidencia).
- [ ] T035 COMPUERTA: después del merge (SC-001), registrar en las Notes de `specs/042-qmd-sqlite-vec-x64/tasks.md` las tres nocturnas siguientes: identificador, duración del job, margen, línea TAP del test 041 y `e2e summary:`. Cada una debe ejecutar la fase (no saltarla) y terminar con al menos 5 minutos de margen. Los apuntes van a un PR de documentos aparte, como en 039 (PR #105) y como prevé 041 en su T040, todavía pendiente; si alguna cae por la fase, se reabre #107 y se aplica FR-013 o FR-010 según la causa.
- [ ] T036 Limpieza, con confirmación del operador para lo que salga de la sesión: borrar las ramas de ensayo que queden (remotas y locales) y los worktrees desechables; ofrecer quitar la variante `linux/amd64` de `alpine:3.24.1` que dejó la Fase 0 en el Docker del Mac y, si el operador lo pide, los modelos de `~/.cache/agentic-qmd-e2e/models-041` (1,6 GB) y las imágenes de prueba de T022; borrar la rama `042-qmd-sqlite-vec-x64` solo cuando el operador lo pida tras el merge.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: T001 ya está cerrada (el PR #108 mergeó, squash `0fc08a8`). T002 antes de T003 (el rebase necesita el commit). T004 es largo (unos 20 min por bash) y corre sobre una copia aislada, así que T005 puede avanzar mientras tanto.
- **Foundational (Phase 2)**: T006 después de T003. La fase bloquea todas las historias.
- **US1 (Phase 3)**: después de la fase 2. Es el MVP: T007 a T009 (ROJO) antes de T010 (implementación) y T011 (punto de control).
- **US2 (Phase 4)**: después de US1, porque agrega líneas de log a las ramas que US1 dejó con `return 0`.
- **Polish (Phase 5)**: después de US2. T015, T016 y T017 son paralelas entre sí; T019 (mutaciones) y T020 (revisión) antes de T021 a T023; T023 es el gate y va último.
- **US3 (Phase 6)**: después de Polish. T024 a T026 preparan; T027 a T028 miden; T029 y T030 solo si se cumple su condición; T031 y T032 cierran. Todo lo que sale del host pasa por compuertas.
- **Cierre (Phase 7)**: después de US3. T035 solo existe después del merge.

### Within Each User Story

- El ROJO se registra antes de cada VERDE; las pruebas que nacen verdes a propósito (N6, N10) y la reforzada que ya estaba en verde (E1) se registran con su razón y su mutación.
- Las tareas sobre el mismo archivo van en orden (casi todo el código y las pruebas viven en `scripts/lib/qmd_index.sh` y `tests/qmd-sqlite-vec.bats`).
- Cada punto de control corre en bash 5.x y en 3.2, secuencial.

### Parallel Opportunities

- T004 (línea base en su copia aislada) con T005.
- T015, T016 y T017 (documentos distintos).
- Las corridas de T027 y T028 no se pueden solapar: el workflow usa un grupo de concurrencia (`docker-e2e`, `cancel-in-progress: false`) y se encolarían; se lanzan en serie.

---

## Parallel Example: Polish

```bash
# Después del VERDE de T014, en paralelo y en archivos distintos:
Task: "T015 N11 y los documentos (tests/qmd-sqlite-vec.bats, docs/qmd-upgrade-checklist.md, docs/architecture.md, docs/vault.md, docker/scripts/build-sqlite-vec.sh)"
Task: "T016 Borrador de la entrada de CHANGELOG.md"
Task: "T017 Viñetas de CLAUDE.md"
# Después, en serie: T018 (VERSION), T019 (mutaciones), T020 (revisión), T021 (humo local), T022 (DOCKER_E2E arm64), T023 (gate).
```

---

## Implementation Strategy

### MVP primero (US1)

1. Setup y Foundational (con #108 ya en `main`).
2. US1: las pruebas en ROJO, el destino por arquitectura y el punto de control en VERDE.
3. Validar con N1 a N3 y N6 a N10 y, con Docker, con el humo V2. Desde aquí el producto ya funciona en amd64; falta que deje rastro y que el nightly lo vuelva a ejercitar.

### Entrega incremental

1. US2: las dos líneas de log (el próximo defecto de esta clase no necesita una corrida de CI para descubrirse).
2. Polish y gate local.
3. US3: la evidencia real, que decide FR-010 y FR-013.
4. Cierre.

Todo se mergea en un solo PR, y solo después de la evidencia: ninguna fase intermedia se publica sola.

---

## Notes

- **[P]**: archivos distintos y sin dependencias abiertas.
- No hay commits hasta T002, ni push hasta T026. La regla genérica de la plantilla («commit after each task») no aplica en este repositorio.
- **Aserciones intermedias muertas**: ningún `[[ ]]` ni `!` intermedio en las pruebas nuevas; se usan `[ ]`, `grep -q` o `run`, y un negativo se expresa como `if comando; then false; fi`. Un `[[ ]]` es letra muerta solo en bash 3.2; un `!` lo es en ambos.
- **Cargas grandes por archivo**, nunca por `argv` ni por el entorno (límite por cadena de 128 KiB en Linux). Las pruebas nuevas manejan archivos de unos bytes.
- **Hermeticidad**: ninguna prueba nueva puede depender de la arquitectura del host (la CI corre ubuntu amd64 y macOS arm64) ni de ser root (N8 se salta como root). Las mutaciones de T019 corren como no root.
- **Git y GitHub**: los pushes son por HTTPS con el helper de `gh`; los commits llevan la identidad personal; el remoto `origin` es SSH y pertenece a otra cuenta. Una rama de ensayo se crea en un worktree desechable del scratchpad y se borra al terminar, con la confirmación del operador.
- **Logs de CI**: descargar con `gh run view <id> --log` y comprobar que trae `GNU bash, version` antes de contar nada; con `gh api .../jobs/<id>/logs` hace falta `--allow-escape-sequences` (un log vacío cuenta cero en silencio).
- **VERSION**: tras cualquier rebase, verificarla contra `origin/main` a mano.
- **Harness de la sesión**: los comandos compuestos o calculados se rechazan en la sesión aislada; usar rutas literales y scripts del scratchpad. No usar `git stash` sin etiqueta (la pila se comparte con los demás worktrees).
- **Análisis (18-10-2026)**: `/speckit-analyze` (solo lectura) halló 16 hallazgos (0 críticos, 1 ALTA, 5 MEDIA y 10 BAJAS) y el operador aprobó remediarlos todos en los documentos, sin tocar código. F1 acotó FR-005 y SC-003 (la lista de paquetes se exige solo cuando la causa es el paquete, L-PKG) y dejó la decisión en las Clarifications del spec. C1 y C2 endurecieron N7, N2 y N3 (la primera llamada se afirma y el prefijo se reconstruye en cada vuelta). C3 separó M9 en M9a y M9b. E1 reforzó E1 con la línea de log y sumó M13. E2 sumó M14 y M15 y las aserciones de N6 (un `uname` falso que anota sus llamadas), N4 y N5 (una sola línea). F2 fijó la regla de la build musl ausente (se corrige en esta feature) frente a otro defecto (FR-013). F3 reordenó los commits de T025. E3 y C7 completaron el chequeo de alcance de T023 y T033 y el párrafo de compuertas. C4 hizo que `uname` pueda fallar sin abortar al llamador. C5, C6, B1, A1 y F4 son precisiones de redacción. El catálogo pasa a M1 a M15 (las mutaciones de las revisiones empiezan en M16); los demás conteos no cambian: 36 tareas, 18 pruebas (11 nuevas), V1 a V7 y D1 a D11. Dos ajustes propios, no pedidos por el análisis: la línea de log de arm64 se verifica con una pata arm64 del humo (T021) porque el test 041 no vuelca el log del contenedor en una corrida verde y T022 no la ve, y los códigos L-PKG y L-ARCH reemplazaron las etiquetas N1 y N2 de los logs en `data-model.md` y `research.md`, que se confundían con las pruebas N1 y N2.
- **Verificación posterior al merge de #108 (19-10-2026)**: un workflow de solo lectura (cinco agentes, uno por grupo de artefactos, y un escéptico por discrepancia) contrastó cada afirmación sobre el repositorio con `origin/main` (`0fc08a8`): 462 afirmaciones revisadas y 54 discrepancias, sin ninguna refutada entre los veredictos que ya habían llegado al aplicar esta ronda. Corregido: lo que seguía tratando el PR #108 como pendiente (spec, plan, research, quickstart y tasks); los rangos de líneas (la función ocupa 128 a 144, no 105 a 144; el ítem «017 swap path» ocupa 66 a 69; los pasajes de `docs/vault.md` de las líneas 540 a 541 y 697 a 699 también dependen del cierre del log); que el `vec0.so` musl horneado en la imagen amd64 ya está medido por `qmd real (016)` (`tests/docker-e2e-qmd.bats:705-706`); que `e2e summary:` solo trae conteos (FR-009); que el prefijo lo instala `bun install` y no npm; que `unavailable` ya no identifica la rama L-ABS (E3 reforzada y M13b) ni el texto de L-CP (M13c); el criterio de «falta el paquete» (el archivo `vec0.so`, no el directorio); que solo `start_services.sh` corre bajo `set -e`; los nombres exactos de las pruebas; T024 sin ROJO posible (W6 acepta el vacío) y T031 con su mecanismo exacto (la línea 802 de `tests/docker-e2e-qmd.bats`). M13 pasó a tres variantes (M13a, M13b y M13c) y el catálogo sigue siendo M1 a M15. Los escépticos que faltaban al aplicar esta ronda se leen después; sus correcciones, si hay, entran en el commit de documentos (T025).

### Registro (se completa durante la implementación)

- **Verificación del merge de #108 (T001, 19-10-2026)**: el operador mergeó tres PR el 19-10-2026 entre 03:04:43Z y 03:05:18Z: #104 (docs, `1b8e4d0`), #105 (docs, `9a163b3`) y #108 (041, `0fc08a8`). `origin/main` = `0fc08a8`, historia lineal `13cafc3` > `1b8e4d0` > `9a163b3` > `0fc08a8` (`13cafc3` es ancestro, el rebase es directo); `VERSION` 0.28.0 (041 no la sube); trae `.github/scripts/fetch-qmd-models.sh`, `tests/qmd-embed-nightly.bats`, `tests/fixtures/qmd-e2e/{fake-curl,vec0-libc.sh}` y `specs/041-nightly-qmd-embed`. Entre `13cafc3` y `0fc08a8` cambiaron, en las rutas que usa 042, solo los archivos de 041 (`.github/scripts/fetch-qmd-models.sh`, `.github/workflows/docker-e2e.yml`, `.specify/feature.json`, `CHANGELOG.md`, `CLAUDE.md`, `docs/qmd-upgrade-checklist.md`, `tests/docker-e2e-qmd.bats` y los fixtures y el oráculo de 041); `scripts/lib/qmd_index.sh`, `tests/qmd-sqlite-vec.bats` y `docker/scripts/build-sqlite-vec.sh` no cambiaron. La primera nocturna sobre `0fc08a8` aún no corría a las 03:25Z.
- **Modelos para V3 (T005, 19-10-2026)**: `~/.cache/agentic-qmd-e2e/models-041` tiene los dos archivos con el tamaño (333.590.944 y 1.282.438.912 bytes, 1.616.029.856 en total) y el sha256 de la tabla de `.github/scripts/fetch-qmd-models.sh` en `origin/main`.
- **Línea base (T004)**: bash 5.3.15 (bats 1.13.0) sobre `origin/main` = `0fc08a8` en una copia aislada: `1..1854`, 1854 ok, 0 not ok, 55 saltados, salida de error vacía, 22 min 4 s (19-10-2026, carga del Mac entre 10 y 16); bash 3.2: Pendiente (el primer intento falló por un error del script de medición, el `PATH` sin comillas; se repite).
- **ROJO y VERDE por historia (T007 a T014)**: Pendiente.
- **Mutaciones M1 a M15 (T019)**: Pendiente.
- **Revisión independiente (T020)**: Pendiente.
- **Humo local V2, amd64 y su pata arm64 (T021)**: Pendiente.
- **DOCKER_E2E arm64 local V3 (T022)**: Pendiente.
- **Gate completo (T023)**: Pendiente.
- **Evidencia V4 (T027 y T028) y medición del tope (T029)**: Pendiente.
- **Rotura inducida V5 (T031)**: Pendiente.
- **Decisiones de FR-010 y FR-013**: Pendiente.
- **PR y merge (T033 y T034)**: Pendiente.
- **Noches posteriores al merge (T035)**: Pendiente.
