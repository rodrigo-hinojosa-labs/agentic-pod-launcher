# Contrato: el oráculo del host

**Archivo nuevo**: `tests/qmd-lock-release.bats`, con 10 pruebas.
**Fixtures nuevas**: `tests/fixtures/qmd-lock/timeout` (bash) y `tests/fixtures/qmd-lock/flock` (perl).
**Origen**: spec FR-007 y SC-002; `research.md` M5 y D2.
**Esperado de la suite del host**: la línea base medida más 10 (1894 + 10 = 1904 si la línea base da 1894).

## 1. Las fixtures

- **`timeout` falso con la forma de BusyBox** (M2, M5): acepta y descarta `-k N`, `-s SIG` y la duración. Lanza un vigilante en segundo plano, `( exec </dev/null >/dev/null 2>&1 3>&-; exec sleep "$FAKE_TIMEOUT_LINGER" ) &`, que conserva todo descriptor heredado salvo 0, 1, 2 y 3, y hace `exec "$@"`.
  - Cierra también el 3 porque es el canal de bats: un proceso que lo conserva demora el reporte de la prueba. El defecto vive en el 9, que conserva.
  - Termina en `exec sleep`, así el PID del vigilante es el del proceso que conserva el descriptor. Si `FAKE_TIMEOUT_PIDFILE` tiene valor, agrega ese PID al archivo, y el `teardown` de cada prueba mata los PID listados (el vigilante no es hijo de la prueba, así que `wait` no lo alcanza).
  - Si `FAKE_TIMEOUT_ONLY` tiene valor, solo deja vigilante cuando el primer argumento del comando termina en ese nombre (`bun` para L4).
  - Con `FAKE_TIMEOUT_LINGER=0` no deja vigilante.
  - No aplica ningún tope. Ninguna prueba existente cubre el tope: `QMD_CMD_TIMEOUT` y `QMD_INSTALL_TIMEOUT` no aparecen en `tests/` (búsqueda del 07-11-2026). Como el arreglo no toca `_qmd_run` (contrato `lock-release.md`, I5), SC-004 se mide con el `timeout` real en la etapa 6 de `evidence-protocol.md` y no con esta fixture.
- **`flock` falso en perl** (M5): `-n`/`-x FD`, `-u FD` y `-n ARCHIVO COMANDO...`, con `flock(2)` sobre el descriptor heredado (`open($fh, '>&=', FD)`).
  - Solo se instala en el `PATH` de la prueba si el host no tiene `flock`. Si lo tiene (Linux), la prueba usa el de util-linux.
- **El vigilante de las pruebas** dura `FAKE_TIMEOUT_LINGER=3` s. El sondeo se hace una sola vez, inmediatamente después de que vuelve la función. Ese margen hace que la prueba caiga de forma determinista con el código actual y no dependa del reloj con el arreglo.
- **El motor** es el de siempre (`tests/helper.bash::install_qmd_stub`). La prueba lo envuelve cuando necesita observar algo desde dentro de la sección (L6).

Cada prueba mata en `teardown` los vigilantes que dejó (por `FAKE_TIMEOUT_PIDFILE`) y el dueño externo de L5, para no dejar procesos vivos ni descriptores abiertos sobre el directorio temporal.

## 2. Las pruebas

| ID | Qué afirma | Requisito | ROJO esperado contra `origin/main` |
| --- | --- | --- | --- |
| **L1** | Tras `qmd_setup_if_needed` sobre un caché nuevo (`collection add`, `update`, `embed`), un `flock -n "$lock" true` inmediato sale con 0 | FR-001, US1-2 | Sí: el vigilante tiene el lock |
| **L2** | Tras `qmd_reindex` con el vault cambiado, el `flock -n` inmediato sale con 0, y el reindex dejó `indexed` | FR-001, US1-1 | Sí |
| **L3** | Tras `qmd_reindex` con la migración de 037 pendiente, el `flock -n` inmediato sale con 0, y la migración corrió (las siete llamadas del motor) | FR-001, US1-3 | Sí |
| **L4** | Con el vigilante solo en `bun` (`FAKE_TIMEOUT_ONLY=bun`) y el `.installed-hash` quitado, para que el setup corra `bun install`, el `flock -n` inmediato tras el setup sale con 0 | FR-006 | Sí: lo retiene el vigilante del `bun install` |
| **L5** | Con un dueño externo que tiene el lock, `qmd_reindex` sale con 0, escribe `already running — skip`, no llama al motor y el lock del dueño sigue tomado después (un `flock -n` falla) | FR-002, US1-4 | No: guarda la semántica (nace verde) |
| **L6** | Durante la sección, el motor envuelto intenta un `flock -n` sobre el archivo del lock desde una descripción nueva, y falla porque la sección lo tiene. Cada llamada lo registra | FR-002 | No: nace verde y caza M4 |
| **L7** | Si un paso falla y la sección vuelve antes (`update` falla en el setup: «retry next boot»), el `flock -n` inmediato sale con 0 | FR-001, C2 | Sí |
| **L8** | Con el `timeout` falso, `qmd_reindex` devuelve 0 y el archivo de estado queda igual que sin vigilante: `last_status`, `pending` y `hash` | FR-004 | No: nace verde |
| **G1** | Guardia estructural, en cada una de las dos funciones: la línea `flock -u 9 2>/dev/null \|\| true` aparece una sola vez; va después de la primera llamada a la función de la sección posterior a la línea `if ! flock -n 9; then ... exit 91; fi` y antes de la línea que cierra el subshell (`) 9>"$lock" \|\| rc=$?`); y la función no tiene ningún `trap` | contrato `lock-release.md`, I1, I3 e I6 | Sí: la línea no existe |
| **G2** | Autotest del arnés: con el `timeout` falso, una sección mínima escrita en la prueba (sin `flock -u 9`) deja el lock tomado (el `flock -n` inmediato falla), y con `FAKE_TIMEOUT_LINGER=0` lo deja libre | FR-007 | No: prueba que el arnés puede producir el ROJO |

Reglas del repo para las aserciones:

- Ninguna aserción intermedia es `[[ ]]` ni `!` (las dos son letra muerta en bash 3.2). Se usa `[ ]`, `grep -q` o `if cmd; then false; fi`.
- Ningún payload grande pasa por `argv` ni por el entorno.
- Las pruebas no dependen del `timeout` ni del `flock` del host salvo lo dicho en el punto 1.

## 3. Catálogo de mutaciones

Cada mutación se aplica a una copia aislada del árbol y se corre en bash 3.2.57 y en 5.x. Las que tocan el `flock` real se corren además en una pata Linux (`ubuntu:24.04`, no root, util-linux). Se espera que todas caigan, por la prueba indicada.

| ID | Mutación | Debe caer |
| --- | --- | --- |
| M0 | Control, no mutación: el archivo de pruebas final contra el `qmd_index.sh` de `origin/main` | L1, L2, L3, L4, L7 y G1; y L5, L6, L8 y G2 pasan |
| M1 | Quitar el `flock -u 9` final del setup | L1, L4, L7, G1 |
| M2 | Quitar el `flock -u 9` final del reindex | L2, L3, G1 |
| M3 | Soltar otro descriptor (`flock -u 8`) | L1 a L4, L7 |
| M4 | Mover el `flock -u 9` antes de la llamada a la función de la sección (justo después de ganar el lock) | L6, G1 |
| M5 | Reemplazar el `flock -u 9` final por `trap 'flock -u 9 2>/dev/null \|\| true' EXIT` armado al ganar el lock (el diseño que descartó M8 de `research.md`) | G1 |
| M6 | Reemplazar el arreglo por `9>&-` solo en la llamada de `_qmd_run` (la alternativa `closefd` sin el `bun install`) | L4, G1 |
| M7 | Agregar el `flock -u 9` también en la rama del perdedor, antes del `exit 91` | G1 |
| M8 | Que el `timeout` falso no deje vigilante (romper la fixture) | G2 |
| M9 | Quitar el `exit 91` de la rama del perdedor: escribe `already running — skip` y sigue a la sección sin el lock | L5 |
| M10 | Un comando después del `flock -u 9` del setup (ya no es el último del subshell) | G1 |
| M11 | Un `trap` en medio de una línea, tras la llamada de la sección del setup | G1 |
| M12 | Que el `timeout` falso ignore `FAKE_TIMEOUT_LINGER=0` (deje siempre un vigilante) | G2, L8 |

Algunas mutaciones no cambian nada que el oráculo pueda observar, y por eso las caza G1, que exige la línea exacta, su lugar y la ausencia de `trap`:

- **Quitar `2>/dev/null` o `|| true`** no cambia nada mientras `flock -u` no falle, así que no entra al catálogo; lo guarda G1.
- **M7**: un perdedor que suelta su propia descripción no toca el lock del ganador.
- **M5**: su diferencia con el diseño final es la de una señal al subshell (M8). Esa diferencia se mide con el BusyBox real en la etapa 6 de `evidence-protocol.md`, no en el host.

Historia del catálogo:

- La revisión independiente (T024, 08-11-2026) no encontró defectos de producto. Se atendió así: **G1** exige además que el `flock -u 9` sea de verdad el último comando (la línea siguiente es la que cierra el subshell) y busca `trap` como palabra en cualquier posición del código, no solo al inicio de línea (M10 y M11). **L8** es una guardia de equivalencia, no un detector del arreglo: el vigilante no cambia nada fuera del lock, así que solo las mutaciones del arnés la ponen en rojo (M8 y M12). Ahora afirma que el `timeout` falso se usó en cada corrida (0 vigilantes sin él, 2 con él en la rama de éxito, 1 en la de error) y compara también la rama de error (`update` falla una vez, `last_status=error`). Los sondeos negativos (G2, L5) exigen el código 1, el de conflicto de los dos `flock`, para no pasar por un `flock` ausente o un archivo que no abre. El `teardown` solo mata un PID que siga siendo un `sleep`.
- G1 se endureció al correr el catálogo (08-11-2026): M7 sobrevivió a la primera versión porque el `flock -u 9` del perdedor iba en la misma línea que el `if`, fuera del conteo de línea exacta. G1 cuenta ahora también cualquier línea de código, sin comentarios, que contenga `flock -u` en cada una de las dos funciones y exige exactamente 1. Con eso M7 cae en G1.

- M9 se corrigió al generar las tareas (07-11-2026): la primera redacción, `exit 0` en la rama del perdedor, era equivalente, porque la función devuelve 0 con 91 y con 0.
- El catálogo del plan tomaba el `trap` como arreglo, y su M5 era un `trap ... RETURN`. El análisis del 07-11-2026 lo rehízo para el `flock -u 9` final y agregó el control M0.

Si durante la implementación alguna mutación sobrevive, se endurece la prueba con su ROJO visto antes, o se declara equivalente con la razón, y se registra.
