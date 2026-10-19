# Contrato: el oráculo del host (`tests/qmd-sqlite-vec.bats`)

**Feature**: 042-qmd-sqlite-vec-x64 | **Spec**: [../spec.md](../spec.md) (FR-007, SC-003, SC-006) | **Función**: [swap-sqlite-vec.md](swap-sqlite-vec.md)

El oráculo se amplía en el archivo existente (`tests/qmd-sqlite-vec.bats`, hoy 7 pruebas: cinco de la función y dos de guarda de versiones) a **18 pruebas**: las cinco de la función, adaptadas a un seam de arquitectura y con tres reforzadas (E1, E3 y E5), más 11 nuevas y las dos guardas sin cambio. Corre sin Docker, en bash 5.x y 3.2, y no depende de la arquitectura del host: la CI lo ejecuta en ubuntu amd64 y en macOS arm64.

## 1. Preparación (`setup`)

El `setup()` actual deja un prefijo falso con el paquete `sqlite-vec-linux-arm64` y un `vec0.so` falso con el contenido `GLIBC-PREBUILT`, un cargador musl falso (`QMD_MUSL_LOADER`) y una build horneada falsa con el contenido `MUSL-BUILD` (`QMD_VEC0_MUSL_SO`). Se agrega una línea: `export QMD_MACHINE_ARCH=aarch64`, para que las cinco pruebas existentes, que usan la disposición arm64, valgan en cualquier host (research D4).

Ayudas nuevas dentro del archivo (no se versionan aparte):

- `_mk_pkg SUFIJO`: crea `node_modules/sqlite-vec-linux-SUFIJO/vec0.so` con el contenido `GLIBC-PREBUILT-SUFIJO`, para distinguir cuál paquete quedó tocado.
- `_fake_uname VALOR`: escribe en el directorio temporal un ejecutable `uname` que anota cada invocación en `$TMP_TEST_DIR/uname.calls`, imprime `VALOR` para `-m` y delega en el `uname` real para cualquier otra opción (el real se resuelve con `command -v` antes de alterar el `PATH`), y lo antepone al `PATH`. Es lo que ejerce el camino de producción, sin el seam, y su archivo de anotaciones permite afirmar que en glibc la función no lo llama (N6).

## 2. Pruebas

Las existentes conservan su cuerpo salvo lo indicado. Las aserciones siguen la regla de CLAUDE.md sobre aserciones intermedias muertas: nada de `[[ ]]` ni `!` a mitad de una prueba; se usan `[ ]`, `grep -q` o `run`.

| Id | Prueba | Qué afirma |
| --- | --- | --- |
| E1 | swap replaces the glibc prebuilt with the musl build on musl + artifact present | **reforzada**: disposición arm64 (`QMD_MACHINE_ARCH=aarch64`); además del contenido `MUSL-BUILD`, el log contiene `swapped glibc prebuilt for musl build`, la línea de hoy (FR-002) |
| E2 | swap is a no-op on glibc (musl loader absent) | sin cambio |
| E3 | swap on musl with the baked artifact absent logs + continues (fail-silent), prebuilt untouched | **reforzada**: además de `unavailable`, el log contiene `musl build absent` (L-ABS; la palabra `unavailable` también la traen L-PKG, L-ARCH y L-CP, y sola ya no identifica la rama D4); en verde contra el código original |
| E4 | swap is idempotent (second call is a no-op, content stays the musl build) | sin cambio |
| E5 | swap with no sqlite-vec package at all logs that none was found (renombrada; antes: swap is a no-op when the sqlite-vec package dir is absent) | **reforzada**: además de rc 0, el log contiene `no sqlite-vec-linux-arm64 package` y `found: none` |
| N1 | x64 layout (the one measured in run 39069243972): the x64 package is swapped | con `QMD_MACHINE_ARCH=x86_64` y solo el paquete x64, el `vec0.so` queda con `MUSL-BUILD` y el log trae L-OK |
| N2 | both packages present: only the one of the machine's architecture is swapped | dos vueltas (`x86_64` y `aarch64`), cada una con el prefijo reconstruido y los dos paquetes en glibc (`GLIBC-PREBUILT-x64` y `GLIBC-PREBUILT-arm64`): el de la arquitectura queda con `MUSL-BUILD` y el otro conserva su contenido |
| N3 | architecture names: x86_64 and amd64 select x64, aarch64 and arm64 select arm64 | un bucle por los cuatro nombres; cada vuelta reconstruye el prefijo con los dos paquetes en glibc (si no, tras el primer reemplazo las vueltas siguientes pasarían en vacío) y afirma el contenido de cada paquete: el esperado con `MUSL-BUILD` y el otro con el suyo glibc |
| N4 | only a foreign package present: logs what it found and touches nothing | con `x86_64` y solo el paquete arm64: rc 0, una sola línea de log (`${#lines[@]}` igual a 1) que contiene `no sqlite-vec-linux-x64 package` y `found: sqlite-vec-linux-arm64`, y el `vec0.so` ajeno no cambia |
| N5 | unsupported architecture: logs it and touches nothing | con `riscv64` y con vacío (seam definido y vacío): rc 0, una sola línea de log que contiene `no musl build for machine architecture` y la arquitectura cruda (`'riscv64'` o `''`), ningún archivo cambia; es una rama defensiva (la imagen solo se construye en x86_64 y aarch64) |
| N6 | glibc with the x64 layout is a no-op, silent and does not ask uname | sin cargador musl, con el paquete x64, `QMD_MACHINE_ARCH` sin definir y `_fake_uname x86_64`: rc 0, salida vacía, archivo sin cambio y `uname.calls` ausente o vacío (I4: en glibc la función no bifurca `uname`) |
| N7 | x64 swap is idempotent and the second run prints nothing | con `x86_64` y el paquete x64: tras la primera llamada el `vec0.so` tiene `MUSL-BUILD` y el log trae la línea L-OK; la segunda llamada tiene rc 0, salida vacía y el mismo contenido (sin la afirmación de la primera, contra el código original las dos llamadas son mudas y la prueba pasaría en vacío) |
| N8 | a failing copy logs "swap failed" and still returns 0 | con `x86_64` y el paquete x64 (la disposición de la corrida 39069243972 de 041, no la de la prueba E1), con el `vec0.so` en solo lectura y su directorio sin escritura: rc 0, el log contiene `swap failed (cp)` y el archivo conserva su contenido; los modos se restauran en línea, justo después de la llamada y antes de las aserciones; se salta si la prueba corre como root (root ignora los modos) |
| N9 | without the seam, the architecture comes from uname -m (x86_64) | con `QMD_MACHINE_ARCH` sin definir y un `uname` falso que imprime `x86_64`: se reemplaza el paquete x64 |
| N10 | without the seam, the architecture comes from uname -m (aarch64) | igual con `aarch64`: se reemplaza el paquete arm64 |
| N11 | the upgrade checklist names both package layouts | `docs/qmd-upgrade-checklist.md` contiene `sqlite-vec-linux-x64`, `sqlite-vec-linux-arm64` y la regla de nombre `sqlite-vec-${plataforma}-${arquitectura}` |
| G1 | qmd pin default is the known-good 2.5.3 | sin cambio |
| G2 | Dockerfile pins SQLITE_VEC_VERSION to the known-good 0.1.9 (paired with qmd 2.5.3) | sin cambio |

**ROJO esperado antes del arreglo** (la función sin cambiar y el seam ignorado): E5, N1, N2, N3, N4, N5, N7, N8, N9 y N11 (10 pruebas). **Nacen verdes a propósito** N6 y N10, que guardan comportamiento actual (la salida temprana en glibc y la arquitectura arm64 por defecto): a N6 la prueban M6 y M14, y a N10 la prueba M9a; una prueba que nace verde solo vale si su mutación la hace caer. E1 y E3 reforzadas (con la línea del log) y E2 y E4 siguen en verde contra el código original: guardan el comportamiento de hoy en arm64 (FR-002), y a E1 la prueban M13a y a E3 M13b. N6 y E2 se solapan a propósito: E2 cubre la disposición arm64 en glibc y N6 la x64, además de que la función no llame a `uname` ahí.

Conteos: 7 pruebas existentes + 11 nuevas = **18**. La suite completa del host pasa a ser la base de `main` más 11. 041 ya mergeó (PR #108, `0fc08a8`) y con ese commit la base es 1854 (1817 + 37 de 041), así que el esperado es 1854 + 11 = 1865; T004 confirma la base midiéndola en una copia aislada de `origin/main` y fija con ella el esperado final.

## 3. Catálogo de mutaciones

Cada mutación se aplica sobre una copia aislada del árbol (de `scripts/lib/qmd_index.sh`, o de `docs/qmd-upgrade-checklist.md` en el caso de M12; `load_lib` y N11 leen `$REPO_ROOT`, que sale de la ubicación de `tests/helper.bash`), nunca sobre el árbol de trabajo, y se corre solo el archivo de pruebas; debe caer por la aserción prevista y no por un error del arnés. El catálogo se ejecuta contra la implementación real, en bash 5.x y 3.2, y una mutación que sobreviva endurece el oráculo antes de seguir.

| Mutación | Qué cambia | La caza |
| --- | --- | --- |
| M1 | el destino vuelve a ser la ruta arm64 fija (el defecto de #107) | N1, N2, N3, N9 |
| M2 | el mapa no reconoce `arm64` (solo `aarch64`) | N3 |
| M3 | el reemplazo recorre todos los `sqlite-vec-linux-*` en vez de solo el de la arquitectura | N2 |
| M4 | se quita la línea L-PKG | N4, E5 |
| M5 | una arquitectura desconocida cae en arm64 en vez de salir | N5 |
| M6 | se quita la guarda de musl | N6 (y E2) |
| M7 | se quita el `cmp -s` (copia siempre y registra siempre) | N7 |
| M8 | una copia fallida se traga sin registrar | N8 |
| M9a | sin seam, la función ignora `uname -m` y toma siempre `x86_64` | N10 |
| M9b | sin seam, la función ignora `uname -m` y toma siempre `aarch64` | N9 |
| M10 | la rama del paquete ausente sale con estado 1 | N4, E5 |
| M11 | la línea L-PKG pierde la lista `found:` | N4, E5 |
| M12 | se quita de la checklist la mención de un paquete (deriva de documento) | N11 |
| M13a | se cambia el texto de la línea L-OK (la que arm64 imprime hoy) | E1, N1 |
| M13b | se cambia el texto de la línea L-ABS (`musl build absent`) | E3 |
| M13c | se cambia el texto de la línea L-CP (`swap failed (cp)`) | N8 |
| M14 | se consulta `uname -m` antes de la guarda de musl (viola I4) | N6 |
| M15 | las ramas L-PKG y L-ARCH escriben su línea dos veces (viola I6) | N4, N5 |

Cada una de las 11 pruebas nuevas debe caer con al menos una mutación (lo comprueba un script de auditoría del scratchpad, como en 041), y las mutaciones que salgan de las revisiones independientes se suman con numeración continua (M16 en adelante). El catálogo son 15 mutaciones, con M9 y M13 en variantes (M9a y M9b; M13a, M13b y M13c: 18 corridas por bash), y se ejecuta como usuario no root: N8 se salta como root y M8 sobreviviría por una razón ajena a la prueba.

## 4. Paridad y entorno

- bash 5.x y 3.2.57 (`PATH=/bin:$PATH` en macOS), con bats 1.13 local y la versión que instale la CI.
- Con la señal SIGPIPE ignorada, como la entrega el runner de GitHub (`perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats ...`).
- `shellcheck -S error -e SC1090,SC1091 scripts/lib/qmd_index.sh`, las opciones del paso `Run shellcheck` de la CI; ese paso recorre todo el árbol y se corre completo en el gate (los `tests/` no entran).
- La suite completa en los dos bash sobre un árbol congelado, y la CI del PR en sus dos brazos, antes de dar por buena la parte del host.
