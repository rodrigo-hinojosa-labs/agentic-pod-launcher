# Contrato: el oráculo del host (`tests/qmd-sqlite-vec.bats`)

**Feature**: 042-qmd-sqlite-vec-x64 | **Spec**: [../spec.md](../spec.md) (FR-007, SC-003, SC-006) | **Función**: [swap-sqlite-vec.md](swap-sqlite-vec.md)

El oráculo se amplía en el archivo existente (`tests/qmd-sqlite-vec.bats`, hoy 7 pruebas: cinco de la función y dos de guarda de versiones) a **21 pruebas**: las cinco de la función, adaptadas a un seam de arquitectura y con tres reforzadas (E1, E3 y E5), más 14 nuevas (11 del diseño, N1 a N11, y 3 que sumó la revisión independiente de T020, N12 a N14) y las dos guardas sin cambio; la revisión independiente, en sus tres pasadas, además endureció E1, E2, E4, N1, N4, N5, N8, N11 y N14, volvió a reforzar E3 y E5 y reescribió N13. Corre sin Docker, en bash 5.x y 3.2, y no depende de la arquitectura del host: la CI lo ejecuta en ubuntu amd64 y en macOS arm64.

## 1. Preparación (`setup`)

El `setup()` actual deja un prefijo falso con el paquete `sqlite-vec-linux-arm64` y un `vec0.so` falso con el contenido `GLIBC-PREBUILT`, un cargador musl falso (`QMD_MUSL_LOADER`) y una build horneada falsa con el contenido `MUSL-BUILD` (`QMD_VEC0_MUSL_SO`). Se agrega una línea: `export QMD_MACHINE_ARCH=aarch64`, para que las cinco pruebas existentes, que usan la disposición arm64, valgan en cualquier host (research D4).

Ayudas nuevas dentro del archivo (no se versionan aparte):

- `_mk_pkg SUFIJO`: crea `node_modules/sqlite-vec-linux-SUFIJO/vec0.so` con el contenido `GLIBC-PREBUILT-SUFIJO`, para distinguir cuál paquete quedó tocado.
- `_fake_uname VALOR`: escribe en el directorio temporal un ejecutable `uname` que anota cada invocación en `$TMP_TEST_DIR/uname.calls`, imprime `VALOR` para `-m` y delega en el `uname` real para cualquier otra opción (el real se resuelve con `command -v` antes de alterar el `PATH`), y lo antepone al `PATH`. Es lo que ejerce el camino de producción, sin el seam, y su archivo de anotaciones permite afirmar que en glibc la función no lo llama (N6).
- `_failing_uname`: escribe un `uname` que no imprime nada y sale con 1 (un binario roto) y lo antepone al `PATH`; con el modo estricto de los llamadores prueba que el reemplazo no aborta (N13).
- `teardown`: `teardown_tmp_dir`, como los demás archivos de prueba del repositorio; N8 restaura sus modos en línea, así que borrar el árbol siempre funciona.

## 2. Pruebas

Las existentes conservan su cuerpo salvo lo indicado. Las aserciones siguen la regla de CLAUDE.md sobre aserciones intermedias muertas: nada de `[[ ]]` ni `!` a mitad de una prueba; se usan `[ ]`, `grep -q` o `run`.

| Id | Prueba | Qué afirma |
| --- | --- | --- |
| E1 | swap replaces the glibc prebuilt with the musl build on musl + artifact present | **reforzada**: disposición arm64 (`QMD_MACHINE_ARCH=aarch64`); además del contenido `MUSL-BUILD`, la salida es exactamente `[qmd] sqlite-vec: swapped glibc prebuilt for musl build`, la línea de hoy y nada más (FR-002; la revisión cambió el `grep` por una igualdad) |
| E2 | swap is a no-op on glibc (musl loader absent) | **reforzada** (tercera pasada): además de rc 0 y del archivo sin cambio, la salida es vacía; en verde contra el código original |
| E3 | swap on musl with the baked artifact absent logs + continues (fail-silent), prebuilt untouched | **reforzada**: la línea L-ABS entera y sola, por igualdad exacta (`[qmd] sqlite-vec: musl build absent (<ruta de la build ausente>) <raya larga> vector embed unavailable, lexical index intact`; FR-002: la línea de 017 no cambia, y la raya larga se arma con `printf` para que el archivo siga siendo ASCII donde importa), con el prefijo sin ningún cambio (`find` antes y después); y una segunda vuelta en amd64 (`x86_64`, el paquete x64 y la build ausente: la imagen sin toolchain que corre la rotura inducida de US3) con la misma línea y el paquete sin tocar. La vuelta arm64 es verde contra el código original; la de amd64 cae contra `origin/main`, donde ese caso era mudo |
| E4 | swap is idempotent (second call is a no-op, content stays the musl build) | **reforzada** (tercera pasada): la segunda llamada, además de rc 0 y del contenido `MUSL-BUILD`, no imprime nada (I3); en verde contra el código original; la prueba M7 |
| E5 | swap with no sqlite-vec package at all logs that none was found (renombrada; antes: swap is a no-op when the sqlite-vec package dir is absent) | **reforzada**: además de rc 0, el log contiene `no sqlite-vec-linux-arm64 package`, `found: none` y el cierre `vector embed unavailable, lexical index intact`; una segunda vuelta con la build horneada también ausente afirma que D3 se decide antes que D4 (sigue diciendo el paquete y no `musl build absent`) |
| N1 | x64 layout (the one measured in run 39069243972): the x64 package is swapped | con `QMD_MACHINE_ARCH=x86_64` y solo el paquete x64, el `vec0.so` queda con `MUSL-BUILD`, el log trae L-OK y el único archivo del prefijo es ese `vec0.so` (I2: ninguna copia ni respaldo de más); el `vec0.so` empieza en solo lectura (un caché de paquetes puede dejarlo así) y la copia lo reemplaza igual (`cp -f`) |
| N2 | both packages present: only the one of the machine's architecture is swapped | dos vueltas (`x86_64` y `aarch64`), cada una con el prefijo reconstruido y los dos paquetes en glibc (`GLIBC-PREBUILT-x64` y `GLIBC-PREBUILT-arm64`): el de la arquitectura queda con `MUSL-BUILD` y el otro conserva su contenido |
| N3 | architecture names: x86_64 and amd64 select x64, aarch64 and arm64 select arm64 | un bucle por los cuatro nombres; cada vuelta reconstruye el prefijo con los dos paquetes en glibc (si no, tras el primer reemplazo las vueltas siguientes pasarían en vacío) y afirma el contenido de cada paquete: el esperado con `MUSL-BUILD` y el otro con el suyo glibc |
| N4 | only a foreign package present: logs what it found and touches nothing | con `x86_64` y solo el paquete arm64: rc 0, la línea L-PKG entera y sola, por igualdad exacta (`[qmd] sqlite-vec: no sqlite-vec-linux-x64 package in the managed prefix (found: sqlite-vec-linux-arm64) - vector embed unavailable, lexical index intact`), solo ASCII (sin raya larga ni secuencias de color, sección 5 del contrato), el `vec0.so` ajeno no cambia y el árbol del prefijo es idéntico antes y después (I2) |
| N5 | unsupported architecture: logs it and touches nothing | con ocho respuestas de arquitectura (`riscv64`, vacío, `armv7l`, `aarch64_be`, `x86`, `amd`, `i686` y `X86_64`: las dos primeras de siempre y las demás son nombres que un glob de prefijo aceptaría, un aarch64 big-endian, un userland de 32 bits y la grafía en mayúsculas): rc 0, la línea L-ARCH entera y sola, por igualdad exacta y con la arquitectura cruda entre comillas simples (`[qmd] sqlite-vec: no musl build for machine architecture '<arq>' (supported: x86_64, aarch64) - vector embed unavailable, lexical index intact`), solo ASCII, el árbol del prefijo idéntico antes y después y el `vec0.so` del paquete sin cambio; es una rama defensiva (la imagen solo se construye en x86_64 y aarch64) |
| N6 | glibc with the x64 layout is a no-op, silent and does not ask uname | sin cargador musl, con el paquete x64, `QMD_MACHINE_ARCH` sin definir y `_fake_uname x86_64`: rc 0, salida vacía, archivo sin cambio y `uname.calls` ausente o vacío (I4: en glibc la función no bifurca `uname`) |
| N7 | x64 swap is idempotent and the second run prints nothing | con `x86_64` y el paquete x64: tras la primera llamada el `vec0.so` tiene `MUSL-BUILD` y el log trae la línea L-OK; la segunda llamada tiene rc 0, salida vacía y el mismo contenido (sin la afirmación de la primera, contra el código original las dos llamadas son mudas y la prueba pasaría en vacío) |
| N8 | a failing copy logs "swap failed" and still returns 0 | con `x86_64` y el paquete x64 (la disposición de la corrida 39069243972 de 041, no la de la prueba E1), con el `vec0.so` en solo lectura y su directorio sin escritura, la salida estándar capturada sola y la de error en un archivo: rc 0, salida estándar vacía (es la rama D7, que N12 no alcanza como root), la línea L-CP entera y sola en la salida de error, por igualdad exacta (`[qmd] sqlite-vec: swap failed (cp) <raya larga> vector embed may be unavailable`; la queja propia de `cp` no se filtra, I6), y el archivo conserva su contenido; con los modos de vuelta, la llamada siguiente reintenta y reemplaza (la falla no deja marca); los modos se restauran en línea, justo después de la llamada y antes de las aserciones; se salta si la prueba corre como root (root ignora los modos) |
| N9 | without the seam, the architecture comes from uname -m (x86_64) | con `QMD_MACHINE_ARCH` sin definir y un `uname` falso que imprime `x86_64`: se reemplaza el paquete x64 |
| N10 | without the seam, the architecture comes from uname -m (aarch64) | igual con `aarch64`: se reemplaza el paquete arm64 |
| N11 | the upgrade checklist names both package layouts | el ítem «017 swap path» de `docs/qmd-upgrade-checklist.md` (de su primera línea al ítem siguiente; la nota 017 del principio del archivo también nombra los dos paquetes y por eso no basta mirar el documento entero) contiene `sqlite-vec-linux-x64`, `sqlite-vec-linux-arm64` y la regla de nombre `sqlite-vec-${os}-${arch}` |
| N12 | the log goes to stderr only: stdout stays empty in every branch | (de la revisión) en D6, D3, D4 y D2 la salida estándar, capturada sola con la de error en un archivo, está vacía y el archivo trae la línea de la rama; el servidor MCP de qmd corre la función en su propio proceso y su salida estándar es el canal del protocolo; D7, la copia fallida, se cubre en N8 porque necesita un usuario sin privilegios |
| N13 | the swap always hands control back to a strict-mode caller, with its variables untouched | (de la revisión) para cada rama (glibc, arquitectura no soportada, paquete ausente, build ausente, ya reemplazado, reemplazado, copia fallida (si no es root) y `uname` roto, esta última con la queja `uname: boom` por la salida de error), un hijo con `set -euo pipefail` que carga la biblioteca, fija `arch`, `suffix`, `target`, `dir` y `found` en `S` y llama a la función llega a su `echo` con rc 0 y los cinco valores intactos (I5; la función los declara locales); en la rama del `uname` roto el hijo imprime exactamente dos líneas, la L-ARCH con `''` y la de cierre, y nada de la queja (I6; la rama vacía de N5 pasa por el seam y nunca llega a `uname`) |
| N14 | a package directory without its vec0.so counts as missing, and found: lists the package directories only | (de la revisión) con `x86_64`, el paquete arm64 completo, un directorio `sqlite-vec-linux-x64` vacío y lo demás de un prefijo real que no debe entrar en la lista (el paquete envoltorio `sqlite-vec`, un `@tobilu/qmd` ajeno y un archivo regular `sqlite-vec-linux-stray`): una sola línea con `no sqlite-vec-linux-x64 package` y `(found: sqlite-vec-linux-arm64 sqlite-vec-linux-x64)` (nombres sin ruta, separados por un espacio, en orden del glob, sin las entradas ajenas), no se crea ningún `vec0.so` en el directorio vacío y el paquete arm64 no cambia (D3 mira el archivo, no el directorio) |
| G1 | qmd pin default is the known-good 2.5.3 | sin cambio |
| G2 | Dockerfile pins SQLITE_VEC_VERSION to the known-good 0.1.9 (paired with qmd 2.5.3) | sin cambio |

**ROJO esperado antes del arreglo** (la función sin cambiar y el seam ignorado): E3 (su vuelta amd64), E5, N1, N2, N3, N4, N5, N7, N8, N9, N11, N12, N13 y N14 (14 pruebas; medido contra `origin/main` en bash 5.3.15 y 3.2.57 con `scratchpad/042/red_check_042.py` y el oráculo final; con el oráculo de 18 pruebas del diseño eran 10, E5, N1 a N5, N7, N8, N9 y N11, también medido). La vuelta amd64 de E3 y N12 a N14 son de la revisión independiente y caen contra `origin/main` porque fijan las líneas nuevas. Los refuerzos de la revisión sobre el código ya arreglado (E1 exacta, E3 completa, N1, N4, N5, N8 y N11 acotada) tienen además su ROJO en una mutación que sobrevivía al oráculo anterior (M16 a M50, abajo). **Nacen verdes a propósito** N6 y N10, que guardan comportamiento actual (la salida temprana en glibc y la arquitectura arm64 por defecto): a N6 la prueban M6 y M14, y a N10 la prueba M9a; una prueba que nace verde solo vale si su mutación la hace caer. E1 reforzada (con la línea exacta), E2 y E4 (que afirman ahora también el silencio) y la vuelta arm64 de E3 siguen en verde contra el código original: guardan el comportamiento de hoy en arm64 (FR-002), y a E1 la prueban M13a y M29 y a la vuelta arm64 de E3 M13b, M31, M32 y M33. N6 y E2 se solapan a propósito: E2 cubre la disposición arm64 en glibc y N6 la x64, además de que la función no llame a `uname` ahí.

Conteos: 7 pruebas existentes + 14 nuevas = **21** (11 del diseño y 3 de la revisión). La suite completa del host pasa a ser la base de `main` más 14. 041 ya mergeó (PR #108, `0fc08a8`) y con ese commit la base es 1854 (1817 + 37 de 041; medida en una copia aislada de `origin/main`: 1854 ok y 0 not ok en bash 5.3.15 y en 3.2.57), así que el esperado es 1854 + 14 = **1868**.

## 3. Catálogo de mutaciones

Cada mutación se aplica sobre una copia aislada del árbol (de `scripts/lib/qmd_index.sh`, o de `docs/qmd-upgrade-checklist.md` en el caso de M12, con sus variantes, y de M28; `load_lib` y N11 leen `$REPO_ROOT`, que sale de la ubicación de `tests/helper.bash`), nunca sobre el árbol de trabajo, y se corre solo el archivo de pruebas; debe caer por la aserción prevista y no por un error del arnés. El catálogo se ejecuta contra la implementación real, en bash 5.x y 3.2, y una mutación que sobreviva endurece el oráculo antes de seguir.

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
| M12-arm64 | se quita de la checklist toda mención del paquete arm64 (variante de M12) | N11 |
| M12-osarch | se quita de la checklist toda mención de la regla `sqlite-vec-${os}-${arch}` (variante de M12) | N11 |
| M13a | se cambia el texto de la línea L-OK (la que arm64 imprime hoy) | E1, N1 |
| M13b | se cambia el texto de la línea L-ABS (`musl build absent`) | E3 |
| M13c | se cambia el texto de la línea L-CP (`swap failed (cp)`) | N8 |
| M14 | se consulta `uname -m` antes de la guarda de musl (viola I4) | N6 |
| M15 | la rama L-PKG escribe su línea dos veces (viola I6) | N4, N14 |
| M15b | la rama L-ARCH escribe su línea dos veces (viola I6; variante de M15) | N5 |
| M16 | la lista `found:` se une con coma en vez de un espacio | N14 |
| M17 | la falta del paquete se decide por el directorio y no por el archivo `vec0.so` (D3; `cp` crearía el archivo) | N14 |
| M18 | `uname -m` que falla aborta al llamador bajo `set -e` (se quita el `\|\| true` de `_qmd_machine_arch`, I5) | N13 |
| M19 | el bucle de `found:` pierde su guarda `-d` (con ningún paquete listaría el patrón literal en vez de `none`) | E5 |
| M20 | `found:` lista todas las entradas de `node_modules` y no solo las `sqlite-vec-linux-*` | N14 |
| M21 | `found:` lista rutas en vez de nombres | N4, N14 |
| M22 | un `QMD_MACHINE_ARCH` vacío deja de ganarle a `uname` (la prueba del seam mira el valor, `${QMD_MACHINE_ARCH:-}`, en vez de si está definida, `${QMD_MACHINE_ARCH+x}`) | N5 |
| M23 | las cinco líneas `sqlite-vec:` salen por la salida estándar y no por la de error (el canal del protocolo MCP) | N12 |
| M24 | se quita el `2>/dev/null` de la copia y la queja de `cp` se suma a la línea de log (viola I6) | N8 |
| M25 | se deja una copia de respaldo junto al `vec0.so` reemplazado (viola I2) | N1 |
| M26 | D4 (build horneada ausente) se decide antes que D3 (falta el paquete) | E5 |
| M27 | L-PKG y L-ARCH pierden el cierre `vector embed unavailable, lexical index intact` | E5, N4, N5 |
| M28 | el ítem «017 swap path» de la checklist pierde solo la ruta x64 (la nota 017 sigue nombrándola) | N11 |
| M29 | la rama de éxito escribe una segunda línea (viola FR-002 y I6) | E1 |
| M30 | solo la línea de copia fallida sale por la salida estándar (la rama D7, que N12 no alcanza) | N8 |
| M31 | la rama de la build ausente escribe una segunda línea (viola I6) | E3 |
| M32 | L-ABS pierde la ruta de la build ausente | E3 |
| M33 | L-ABS pierde el cierre `, lexical index intact` | E3 |
| M34 | L-CP pierde su cierre `vector embed may be unavailable` | N8 |
| M35 | el glob de `found:` se ensancha a `sqlite-vec*` (entraría el paquete envoltorio) | N14 |
| M36 | L-PKG usa una raya larga en vez del guion ASCII | N4 |
| M37 | D4 (build horneada ausente) solo se decide en arm64; en x64 el flujo cae a la copia | E3 |
| M38 | `found:` acepta cualquier entrada existente, no solo directorios (un archivo regular `sqlite-vec-linux-*`) | N14 |
| M39 | la queja de un `uname` roto se cuela junto a la línea de log (se quita el `2>/dev/null` de `uname -m`; I6) | N13 |
| M40 | la rama del paquete ausente termina el shell del llamador (`exit 0` en vez de `return 0`; I5) | N13 |
| M41 | la rama ya reemplazada termina el shell del llamador (`exit 0` en vez de `return 0`; I5) | N13 |
| M42 | la rama de la arquitectura no soportada sale con estado 1 (I5) | N5, N13 |
| M43 | la rama de la build ausente sale con estado 1 (I5) | E3, N13 |
| M44 | el mapa de arquitectura acepta cualquier nombre que empiece como uno soportado (globs de prefijo) | N5 |
| M45 | la copia pierde `-f` (un prebuilt en solo lectura no se reemplazaría) | N1 |
| M46 | la función deja de declarar locales `arch`, `suffix`, `target`, `dir` y `found` (pisan las del llamador) | N13 |
| M47 | L-ABS usa un guion ASCII donde 017 escribió la raya larga (FR-002) | E3 |
| M48 | L-CP usa un guion ASCII donde 017 escribió la raya larga | N8 |
| M49 | L-PKG pierde su prefijo `sqlite-vec:` (el que `docs/vault.md` manda buscar) | N4 |
| M50 | L-ARCH pierde el espacio antes de `(supported:` | N5 |

Cada una de las 14 pruebas nuevas debe caer con al menos una mutación (lo comprueba un script de auditoría del scratchpad, como en 041), y las mutaciones que salgan de las revisiones independientes se suman con numeración continua (M16 en adelante). El catálogo son 56 variantes: las 18 del diseño (15 mutaciones, con M9 y M13 en variantes: M9a y M9b; M13a, M13b y M13c), tres extra (M15b y las dos variantes de M12), las 14 que sumó la primera pasada de la revisión independiente de T020 (M16 a M29; M16, M17, M18, M20 y M23 a M29, 11, sobrevivían al oráculo de 18 pruebas y motivaron N12 a N14 y los refuerzos, y M19, M21 y M22 ya caían), las 9 de la segunda (M30 a M38; las nueve sobrevivían al oráculo de 21 pruebas de la primera pasada y motivaron la vuelta amd64 de E3 y los refuerzos de E3, N4, N5, N8 y N14) y las 12 de la tercera (M39 a M50; diez sobrevivían al oráculo de la segunda pasada, y M42 y M43 ya caían, M43 sin N13; motivaron los refuerzos de E2, E3, E4, N1, N4, N5 y N8 y la reescritura de N13). En total, de las 35 mutaciones que sumó la revisión, 30 sobrevivían al oráculo contra el que se escribieron. Se ejecuta como usuario no root: N8 se salta como root y M8 sobreviviría por una razón ajena a la prueba. El catálogo prueba que cada prueba puede fallar, no cada aserción por separado: por ejemplo, la comprobación de solo ASCII de N5 o las de salida estándar vacía de D3, D4 y D2 en N12 no tienen una mutación propia.

## 4. Paridad y entorno

- bash 5.x y 3.2.57 (`PATH=/bin:$PATH` en macOS), con bats 1.13 local y la versión que instale la CI.
- Con la señal SIGPIPE ignorada, como la entrega el runner de GitHub (`perl -e '$SIG{PIPE}="IGNORE"; exec @ARGV' bats ...`).
- `shellcheck -S error -e SC1090,SC1091 scripts/lib/qmd_index.sh`, las opciones del paso `Run shellcheck` de la CI; ese paso recorre todo el árbol y se corre completo en el gate (los `tests/` no entran).
- La suite completa en los dos bash sobre un árbol congelado, y la CI del PR en sus dos brazos, antes de dar por buena la parte del host.
