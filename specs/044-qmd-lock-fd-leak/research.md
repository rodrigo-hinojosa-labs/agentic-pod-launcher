# Research: Las secciones con lock de qmd sueltan `.reindex.lock` en cuanto terminan

**Feature**: `044-qmd-lock-fd-leak` | **Fecha**: 2026-11-06 | **Spec**: [spec.md](spec.md)

La Fase 0 midió en el host (macOS, bash 3.2.57 y 5.3.15) y en contenedores desechables `--rm` (Docker Desktop 29.8.0, aarch64): `alpine:3.24.1` con BusyBox 1.37.0, `alpine:3.20` con BusyBox 1.36.1 y `ubuntu:24.04` con GNU coreutils. Las herramientas quedaron en `scratchpad/044/` y no se versionan:

- `proto.py` y `proto_run.sh`: las secciones reales de una copia de `scripts/lib` por variante;
- `cont.py` y `cont_inside.sh`: los contenedores;
- `fakebin/`: el `flock` y el `timeout` falsos;
- `term_trap.sh` y `term_trap.py`, `proto_trailing.py` y `return_trap.sh`: las mediciones del análisis del 07-11-2026 (M8 y M9).

Las salidas están en `scratchpad/044/cont-*.txt`. La variante «actual» es el código de `origin/main` (`8cb45e4`).

## Mediciones

### M1. El defecto, con el BusyBox real y las secciones reales del producto

**Método**: en cada contenedor se instaló `bash`, `jq`, `flock` (util-linux) y `yq-go`. Después se corrieron las secciones reales de `scripts/lib/qmd_index.sh` con el motor falso de las pruebas (`tests/helper.bash::install_qmd_stub`) y el `timeout` y el `flock` de la imagen. Al terminar cada sección, se contaron los sondeos de 100 ms (`flock -n "$lock" true`) hasta obtener el lock.

| Sección | BusyBox 1.37.0 | BusyBox 1.36.1 |
| --- | --- | --- |
| setup del primer arranque (3 llamadas a qmd) | 10 sondeos | 10 sondeos |
| reindex con el vault cambiado (2 llamadas) | 10 sondeos | 10 sondeos |
| reindex con la migración de 037 pendiente (7 llamadas) | 10 sondeos | 10 sondeos |
| una sección que encuentra el lock tomado | se salta con rc 0 y `already running` | igual |

Con la sección mínima del issue, el resultado se repite 3 de 3 veces en las dos versiones: 10 sondeos sin arreglo y 0 con cualquiera de las dos variantes de M4. Esto confirma el issue #116 con el código del producto, no solo con el caso mínimo.

### M2. El vigilante de BusyBox suelta la salida estándar y conserva el descriptor del lock

**Método**: mientras vive el vigilante de una sección mínima, se leyó `readlink /proc/<pid>/fd/{0,1,2,9}`.

**Resultado** (1.37.0 y 1.36.1): los descriptores 0, 1 y 2 apuntan a `/dev/null` y el 9 apunta al archivo del lock. El vigilante, entonces, no cuelga ningún pipe de su llamador. Una sustitución `x=$(timeout 900 sh -c 'echo hi')` tarda 0 ms en 3 de 3 repeticiones, en las dos versiones.

**Consecuencia**: queda **refutado** el efecto inferido en el spec, según el cual una llamada dentro de `$(...)` tardaría cerca de 1 s más (`qmd_index.sh:612,630`). El único costo es el lock. También explica por qué, en las nocturnas, el dueño del `embed` del tick anterior seguía vivo aunque esa llamada corre dentro de `$(...)`: la sustitución no lo espera.

### M3. El `timeout` de GNU (modo local en Linux) no deja vigilante

**Método**: la misma sección mínima en `ubuntu:24.04`, con el `timeout` de coreutils y el `flock` de util-linux.

**Resultado**: 0 sondeos en 3 de 3 repeticiones sin ningún arreglo, y ningún proceso `timeout` vivo después de la sección. La sustitución de comando tarda de 2 a 4 ms.

**Consecuencia**: hoy el modo local en Linux no tiene el defecto. El arreglo debe ser inocuo ahí, y M4 lo mide: 0 sondeos con las dos variantes.

### M4. Dos variantes del arreglo, medidas

- **`unlock`**: al ganar el lock, cada una de las dos secciones arma `trap 'flock -u 9 2>/dev/null || true' EXIT`. El subshell suelta el lock explícitamente al salir, por cualquier camino. El lock de `flock(2)` pertenece a la descripción de archivo abierta, que el vigilante comparte, así que `flock -u` lo libera aunque el vigilante siga vivo con el descriptor abierto.
- **`closefd`**: `9>&-` en la llamada de `_qmd_run` (`$_to "$prefix/node_modules/.bin/qmd" "$@" 9>&-`) y en el `bun install` de `_qmd_ensure_prefix`. Los procesos lanzados no heredan el descriptor.

| Variante | 1.37.0, secciones reales | 1.36.1, secciones reales | GNU | Host bash 3.2 / 5.3 con el `timeout` falso |
| --- | --- | --- | --- | --- |
| actual | 10 / 10 / 10 | 10 / 10 / 10 | 0 | 13 / 13 / 13 (vigilante falso de 1,5 s) |
| `unlock` | 0 / 0 / 0 | 0 / 0 / 0 | 0 | 0 / 0 / 0 |
| `closefd` | 0 / 0 / 0 | 0 / 0 / 0 | 0 | 0 / 0 / 0 |

Cada celda lista los sondeos tras el setup, el reindex y el reindex con migración. Las dos variantes conservan la semántica: una sección que encuentra el lock tomado se salta con rc 0 y `already running`, en todos los entornos.

M4 es la medición de la Fase 0. El análisis del 07-11-2026 descartó `unlock` por M8, y la variante final, el `flock -u 9` como último paso, está medida en M9.

### M5. El oráculo del host puede reproducir el defecto sin Docker

**Problema**: el host de desarrollo (macOS) no tiene `flock` ni `timeout`. Las pruebas de lock existentes se saltan ahí, con «flock not available on host», y solo corren en el brazo ubuntu de la CI.

**Método**: dos falsos en el `PATH` (`scratchpad/044/fakebin/`).

- **`flock` en perl**: hace la misma llamada `flock(2)` sobre el mismo descriptor. Cubre `-n FD`, `-u FD` y `-n ARCHIVO COMANDO`, porque `open($fh, '>&=', 9)` toma el descriptor heredado sin duplicarlo. perl está en macOS y en los dos runners de la CI, y el arnés de `tests/ci-workflows.bats` ya lo usa.
- **`timeout` falso con la forma de BusyBox**: el comando conserva el PID del llamador (`exec`) y un hijo vigilante, con la salida estándar en `/dev/null` (M2), conserva los demás descriptores heredados durante `FAKE_TIMEOUT_LINGER` segundos.

**Resultado**: con las secciones reales en bash 3.2.57 y 5.3.15, la variante actual da 13 a 14 sondeos (vigilante de 1,5 s) y las dos variantes dan 0. El ROJO y el VERDE del oráculo se pueden ver en el Mac del operador, sin Docker y en los dos bash. Una primera versión del `timeout` falso dejaba al vigilante con la salida del llamador. Esa versión hacía que el `$(...)` de `embed` lo esperara y escondía el defecto en el reindex (0 sondeos). La corrigió M2, y desde entonces el falso imita a BusyBox también en eso.

### M6. Inventario de los procesos que corren bajo el lock (FR-006)

Leído en `scripts/lib/qmd_index.sh` (`origin/main`):

| Dentro de | Proceso | Pasa por `timeout` | Puede durar más que la sección |
| --- | --- | --- | --- |
| setup y reindex | cada llamada a qmd, con `_qmd_run` (`:272`, `:282-283`) | sí (900 s) | sí: el vigilante de BusyBox (M1) |
| setup y reindex, si cambió el manifiesto | `bun install` y su build nativo (`:240-243`) | sí (3600 s) | sí: el vigilante; los nietos del build son de vida corta (inferido, no medido) |
| setup y reindex | `_qmd_swap_sqlite_vec`: `cp`, `uname` | no | no: síncronos |
| reindex | `vault_hash` (`find`, `sha256sum`), `jq`, `date`, `grep`, `head`, `mkdir`, `printf` | no | no: síncronos |

Ningún proceso de la sección se lanza en segundo plano (`&`), según una búsqueda en `qmd_index.sh`. Lo único que sobrevive a la sección son los vigilantes del `timeout` y, en teoría, un descendiente que un comando de qmd o de bun dejara corriendo. Hoy no consta ninguno.

### M7. Ninguna otra sección del repo tiene el defecto

Leído en código: las otras secciones con `flock` son la de `scripts/lib/wiki_graph.sh:368-393` y las de `docker/scripts/lib/state.sh:55,75,102`. Ninguna lanza procesos con `timeout` ni en segundo plano dentro del lock. Ningún script de `scripts/lib/` ni de `docker/scripts/` arma un `trap` que pudiera chocar con el de `unlock`.

### M8. Un `trap ... EXIT` suelta el lock ante un SIGTERM al subshell, con el hijo vivo (análisis del 07-11-2026)

**Método** (`scratchpad/044/term_trap.sh`, con el `flock` en perl): una sección mínima toma el lock en el descriptor 9 y lanza un hijo largo (`sleep 4.37`, en el papel de un qmd que trabaja). A los 0,5 s se manda SIGTERM al subshell, no al hijo. Después se mira si el hijo sigue vivo y si un `flock -n` obtiene el lock. Hay tres variantes: la actual, la de D1 original (`trap 'flock -u 9 ...' EXIT`) y la final (`flock -u 9` como último paso, M9).

| Variante | bash 3.2.57 | bash 5.3.15 |
| --- | --- | --- |
| actual | hijo vivo, lock **tomado** | hijo vivo, lock **tomado** (en una corrida el hijo ya no estaba y el lock quedó libre) |
| `trap ... EXIT` | hijo vivo, lock **libre**; el `trap` se disparó con la señal | lock **libre** en las dos corridas |
| `flock -u 9` al final | hijo vivo, lock **tomado** | hijo vivo, lock **tomado** |

**Consecuencia**: con el `trap`, una señal al subshell suelta el lock mientras el qmd hijo sigue escribiendo el índice, y un segundo reindex podría correr al mismo tiempo. Hoy no pasa: el hijo conserva el descriptor 9 y el lock lo protege hasta que termina. Eso contradecía el caso borde del spec («el arreglo no puede empeorarlo»).

Un ejemplo de cómo se llega ahí es `pkill -f heartbeatctl`, que alcanza al subshell porque un fork tiene la misma línea de comando que su padre, pero no al `qmd embed` hijo (inferido, sin medir en el producto). La variación de bash 5.3 en la fila actual es un artefacto de la sección mínima: su último comando es el `sleep`, que bash puede ejecutar con `exec` en lugar del subshell. En el producto, el último comando es una función, así que no aplica.

Como medición aparte (`return_trap.sh`), un `trap ... RETURN` armado en el subshell no se dispara al volver una función, en los dos bash.

### M9. El `flock -u 9` como último paso de la sección, con las secciones reales (análisis del 07-11-2026)

**Método**: `scratchpad/044/proto_trailing.py` copia `scripts/lib`, agrega `flock -u 9 2>/dev/null || true` después de la llamada a `_qmd_setup_locked` y a `_qmd_reindex_locked` dentro de cada subshell, y corre `proto_run.sh` con el motor falso y el `timeout` falso.

**Resultado**, idéntico en bash 3.2.57 y 5.3.15:
- 0 sondeos tras el setup (3 llamadas), el reindex (2) y el reindex con migración (7);
- el perdedor con el lock tomado se salta con rc 0.

En BusyBox real la confirma T025. Que dé lo mismo que el `trap` (M4) es una inferencia: es el mismo `flock -u 9` sobre la misma descripción, solo que en otro momento.

## Decisiones

### D1. El arreglo: cada sección suelta el lock con un `flock -u 9` explícito como último paso

- **Decisión** (revisada por el análisis del 07-11-2026, con la decisión del operador): en `qmd_setup_if_needed` y en `qmd_reindex`, dentro del subshell, inmediatamente después de la llamada a `_qmd_setup_locked` o a `_qmd_reindex_locked`, va `flock -u 9 2>/dev/null || true`. No hay `trap`. Nada más cambia: ni `_qmd_run`, ni `_qmd_ensure_prefix`, ni los llamadores.
- **Por qué**:
  - **Cubre FR-006 completo por construcción.** Suelta el lock de la descripción que comparten todos los descendientes de la sección, cualquiera sea su número y su vida. También cubre un proceso que se agregue en el futuro, sin depender del inventario de M6.
  - **No empeora la sección que muere por una señal** (M8). Si el subshell recibe SIGTERM o SIGKILL, el `flock -u 9` no corre y el lock queda como hoy, protegiendo a un qmd hijo que siga trabajando.
  - **No toca el camino de cada llamada**, así que FR-003 y FR-004 (el tope, las salidas, los códigos y el log) se conservan sin cambio de código. Las pruebas existentes de `_qmd_run` y de los llamadores guardan las salidas y los códigos. El tope no tiene ninguna prueba en `tests/` (búsqueda del 07-11-2026), así que SC-004 se mide con el `timeout` real en la etapa 6 del protocolo de evidencia.
  - **No acopla `_qmd_run`**, que es genérica y también corre fuera del lock (la migración manual, M7 del spec), al número de descriptor de sus llamadores.
  - **El último paso corre en todo camino sin señal.** Las funciones de la sección vuelven con `return`, también tras un paso fallido. Ninguna de las que corren bajo el lock tiene un `exit` (leído el 07-11-2026). El `set -e` de un llamador no alcanza al subshell, que está a la izquierda de `|| rc=$?`. Un `exit` futuro dejaría ese camino como hoy, sin empeorarlo (contrato `lock-release.md` C3).
- **Alternativa medida y descartada por el análisis**: el `trap 'flock -u 9 2>/dev/null || true' EXIT` armado al ganar el lock, la decisión original de esta fase. Da 0 sondeos (M4) y cubre también un `exit` futuro. Pero se dispara ante un SIGTERM al subshell y suelta el lock con el qmd hijo todavía vivo (M8). Queda como mutación del oráculo (M5 en `contracts/host-oracle.md`), y la caza G1.
- **Alternativa medida y descartada**: `closefd` funciona igual en M1, M3 y M4, pero exige enumerar cada proceso que pueda sobrevivir (M6) y mantener esa lista. Una llamada nueva con un vigilante devolvería el defecto en silencio. Además mete el descriptor 9 del llamador dentro de una función genérica. Queda como mutación del oráculo (M6 en `contracts/host-oracle.md`): solo cubre lo que nombra, y la prueba del `bun install` la caza.
- **Alternativas no medidas y descartadas**: pasar las secciones a la forma de comando (`flock -n -o "$lock" ...`, que cierra el descriptor antes de lanzar el comando) obliga a reescribir las dos secciones y su manejo de errores. Reemplazar el `timeout` de BusyBox por otro (coreutils en la imagen) agrega un paquete y deja intacto el riesgo de cualquier otro descendiente. Las dos cuestan más y protegen menos que soltar el lock explícitamente.

### D2. El oráculo del host usa el `timeout` falso siempre y el `flock` real cuando existe

- **Decisión**: las pruebas nuevas ponen primero en el `PATH` un directorio de fixtures versionado (`tests/fixtures/qmd-lock/`):
  - siempre el `timeout` falso de M5;
  - el `flock` falso en perl solo si el host no tiene `flock`, como pasa en macOS. En Linux, en el brazo ubuntu de la CI y en la pata Linux, usan el de util-linux.
- **Por qué**: así el ROJO y el VERDE se ven en los dos bash del Mac y en los dos brazos de la CI. Donde existe el `flock` real, la prueba lo usa. El `timeout` falso es determinista, lo que no puede ser el de BusyBox.
- **Alternativa descartada**: saltar las pruebas sin `flock`, como las de lock existentes. El brazo macOS de la CI y el gate local en bash 3.2 no las verían nunca.

### D3. La confirmación en contenedor es evidencia local registrada; el DOCKER_E2E y la CI son la integración

- **Decisión**: la medición de M1 se repite sobre el árbol final con la variante elegida, en BusyBox 1.37.0 y 1.36.1 (SC-001, FR-008). Se hace con la herramienta del scratchpad y se registra en tasks.md, sin versionarla, como la inyección de 043.
- **Lo que no cambia**: el DOCKER_E2E de `tests/docker-e2e-qmd.bats` (con COMPUERTA) y la corrida manual de CI (FR-009) corren sin tocar los e2e ni el ayudante de 043 (FR-011).
- **Lo que se espera**: que el R-BUSY del segundo tick de la prueba 13 deje de aparecer, como observación y no como aserción. Una aserción nueva de lock libre dentro del e2e chocaría con los otros dueños legítimos del lock, el vigilante de archivos y el cron.

### D4. Versión, CHANGELOG y documentación

- **Versión y CHANGELOG**: `VERSION` pasa de 0.29.0 a 0.30.0 con un bump MINOR, verificado a mano contra `origin/main` antes de subirlo y tras cualquier rebase. El CHANGELOG lleva una entrada `### Fixed` con la medición.
- **CLAUDE.md**: la viñeta de 043 en Common gotchas cambia «el dueño medido es el vigilante del `timeout`» por el estado nuevo. El bloque de la feature se escribe a mano.
- **Checklist de upgrade**: `docs/qmd-upgrade-checklist.md` se revisa por si nombra la contención.

### D5. El hallazgo lateral de la migración manual sin lock queda fuera

Leído en código (spec, Contexto). Se propone un issue propio con COMPUERTA. El arreglo no lo empeora: la migración manual no toma el lock y no pasa por las dos secciones.

## Pendientes que resuelve la implementación

1. La línea base de la suite del host en una copia aislada de `origin/main` (`8cb45e4`), en los dos bash. Lo esperado es 1894: la CI de `main` en `ef2f4cf` dio 1894 por brazo y #119 solo tocó documentos.
2. El costo de reconstruir las imágenes de prueba para el DOCKER_E2E: `qmd-real` y `qmd-embed` se quitaron el 02-11-2026, y el caché de build se conservó.
3. **Cerrado por el análisis (07-11-2026)**: si algún comando de qmd o de bun deja descendientes vivos después de terminar (M6, inferido que no). Con D1 no cambia el resultado: el `flock -u 9` suelta el lock de la descripción, viva quien viva con el descriptor. Por eso no se mide.
