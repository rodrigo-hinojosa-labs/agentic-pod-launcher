# Contrato: la espera del reindex manual (`tests/helper-qmd-e2e.bash`)

**Feature**: `043-e2e-lock-race-hardening` | **Cubre**: FR-001 a FR-008 | **Spec**: [../spec.md](../spec.md) | **Datos**: [../data-model.md](../data-model.md)

El ayudante es un archivo de bash que `tests/docker-e2e-qmd.bats` carga con `load helper-qmd-e2e` (después de `load helper`) y que `tests/qmd-e2e-lock.bats` carga para ejercitarlo en el host. No toca el producto. Lo escriben primero las pruebas (el ROJO es que el archivo no existe) y después el archivo.

## 1. Interfaz

| Función | Argumentos | Efecto | Retorno |
| --- | --- | --- | --- |
| `qmd_e2e_reindex_wait` | `EXEC_FN SITIO` | lanza el reindex manual a través de `EXEC_FN`, reintenta solo mientras el lock esté ocupado y deja las variables `REINDEX_*` | 0 el reindex corrió; 1 lock ocupado al vencer el plazo; 3 un intento excedió su tope |
| `qmd_e2e_reindex_effect` | `EXEC_FN SITIO` | comprueba el efecto sobre el estado del índice (tabla 3 del modelo de datos) | 0 el efecto está; 1 no está (imprimió R-EFFECT) |
| `qmd_e2e_lock_owners` | `EXEC_FN` | imprime las líneas de la sonda del dueño (tabla de líneas del modelo de datos) | siempre 0 |
| `_qmd_e2e_lock_wait_s` | ninguno | imprime el plazo efectivo en segundos (normaliza `QMD_E2E_REINDEX_LOCK_WAIT_S`) | siempre 0 |
| `_qmd_e2e_now` | ninguno | imprime los segundos de época (`date +%s`); costura de prueba | 0 |
| `_qmd_e2e_sleep` | `SEGUNDOS` | `sleep "$1"`; costura de prueba | 0 |
| `_qmd_e2e_note` | `LINEA...` | escribe cada argumento como comentario TAP por fd 3 (una almohadilla y tres espacios antes de la línea) | 0 |

`EXEC_FN` es el nombre de una función que ejecuta sus argumentos dentro del contenedor como `agent` (`in_container` en las pruebas 12 y 13, `inc` en la prueba 041); el ayudante la invoca como `"$EXEC_FN" sh -c '...'` o `"$EXEC_FN" bash -lc '...'`. `SITIO` es la etiqueta de los reportes: `reindex phase`, `test 12 phase 3`, `test 13 tick 1`, `test 13 tick 2`.

Variables que `qmd_e2e_reindex_wait` deja al sitio: `REINDEX_STATUS`, `REINDEX_OUTPUT`, `REINDEX_ATTEMPTS` y `REINDEX_WAITED_S`. El sitio las usa y no `$status` ni `$output`, que el siguiente `run` pisa. `REINDEX_WAITED_S` es el comienzo del último intento menos el del primero (0 con el lock libre). Un intento que pierde el lock sale con estado 0, porque el producto devuelve 0: `REINDEX_STATUS` en 0 no prueba que el reindex corrió, lo prueba el retorno 0 del ayudante.

**Contexto de llamada.** Los sitios y el oráculo llaman a las dos funciones en el mismo contexto: dentro de una lista `||` o en la condición de un `if`, donde bash no aplica errexit dentro de la función. El ayudante no depende de `set -e` y maneja cada falla con un `if` o un `|| true` explícitos.

Constantes del archivo: `QMD_E2E_LOCK_BUSY_MARK='already running'`, la cadencia de 2 s y el tope de 600 s dentro de la orden del intento. Solo `QMD_E2E_REINDEX_LOCK_WAIT_S` se lee del entorno.

## 2. La orden de cada intento

Idéntica a la que usa hoy la fase 041 (`tests/docker-e2e-qmd.bats:875`), ejecutada con `run "$EXEC_FN" sh -c '...'`:

```text
timeout -k 10 600 /usr/local/bin/heartbeatctl qmd-reindex > /tmp/qmd-reindex.out 2>&1; rc=$?; cat /tmp/qmd-reindex.out; exit $rc
```

El archivo del contenedor se reescribe en cada intento y su contenido se reimprime, de modo que `$output` es siempre el del intento que acaba de correr. En busybox 1.37 el estado es 143 tras TERM y 137 tras KILL, nunca 124 (medido en 041); los tres se tratan como tope excedido.

## 3. Reglas de decisión tras cada intento

| Resultado del intento | Acción | Retorno |
| --- | --- | --- |
| `status` en 124, 137 o 143 | fin, sin reintento; deja `REINDEX_*` | 3 |
| la salida contiene `already running` | ocupado (regla de la espera) | según el plazo |
| cualquier otro resultado: `status` 0 con o sin estado malo, `status` distinto de 0, un `docker compose exec` que falla sin salida | el reindex corrió o falló por otra causa; fin, sin reintento; deja `REINDEX_*` para que el sitio juzgue | 0 |

Regla de la espera, cuando un intento quedó ocupado:

1. La primera vez en esta espera: ejecutar la sonda del dueño y escribir R-BUSY. La sonda no puede cambiar el retorno.
2. El tiempo transcurrido es `_qmd_e2e_now` menos el comienzo del primer intento. Si es mayor o igual al plazo: escribir R-EXPIRED (con esa cifra, la salida del último intento y la sonda) y retornar 1.
3. Si no: `_qmd_e2e_sleep 2` y nuevo intento.

Con el lock libre, el primer intento retorna 0 sin dormir ni correr la sonda (`REINDEX_ATTEMPTS` 1, `REINDEX_WAITED_S` 0).

## 4. El plazo

`_qmd_e2e_lock_wait_s` normaliza `QMD_E2E_REINDEX_LOCK_WAIT_S` como `QMD_E2E_SETUP_DEADLINE_S`: vacío, no numérico o de más de cuatro dígitos dan 120; el valor pasa por `10#`; si queda en 0 o por encima de 3600 da 120. Tabla de verdad que fija el oráculo:

| Valor | Plazo efectivo |
| --- | --- |
| sin definir, vacío, `abc`, `99999`, `0`, `3601` | 120 |
| `08` | 8 |
| `7` | 7 |
| `3600` | 3600 |

El peor caso de la fase 041 es el plazo más un reindex acotado a 600 s; con el plazo por defecto son 12 minutos más que hoy, contra un tope de 45 y jobs de 17 a 27. Con un dueño que no suelta el lock, cada una de las pruebas 12, 13 y 16 espera el plazo y termina (unos 6 minutos en total); los dos casos no se suman en una misma corrida y los dos caben en 45.

## 5. Cómo lo usa cada sitio

| Sitio | Secuencia |
| --- | --- |
| Fase `reindex` de 041 | escribe `gatos.md` (sin cambio); `qmd_e2e_reindex_wait inc "reindex phase" \|\| rc=$?` con `rc` en 0; con 3 imprime el reporte de plazo vencido de 041 (`reindex: qmd-reindex did not finish in 600s ...`, con `REINDEX_STATUS`, `SECONDS - t0`, la espera por el lock en `REINDEX_WAITED_S` y el final de `REINDEX_OUTPUT`) y falla; con 1 falla (el reporte ya salió); con 0 exige `REINDEX_STATUS` igual a 0 y evalúa `qmd_e2e_reindex_effect inc "reindex phase"` en la condición de un `if` que termina en `false`; la afirmación de `pending` en 0 se conserva |
| Prueba 13, bucle | cada vuelta del bucle de 45 s llama al ayudante con el retorno en `rc1` (en 0 al empezar la vuelta), termina en `false` con 1 o 3 y lee `engine-calls.log` con la lectura protegida por un `\|\| true`; el volcado de logs del contenedor ante cualquier falla de la prueba lo hace un bloque de `teardown`, que reemplaza al de `:500-503` |
| Prueba 13, segundo tick | `local rc2=0`; `qmd_e2e_reindex_wait in_container "test 13 tick 2" \|\| rc2=$?`; exige `[ "$rc2" -eq 0 ]` y `REINDEX_STATUS` 0 antes de comparar el conteo de `collection` (el estado solo no prueba que el tick corrió) |
| Fase 3 de la prueba 12 | escribe la nota de cron (sin cambio); `local rc3=0`; `qmd_e2e_reindex_wait in_container "test 12 phase 3" \|\| rc3=$?`; exige `[ "$rc3" -eq 0 ]` y `REINDEX_STATUS` 0; conserva sus afirmaciones de `last_status` (`indexed` o `skipped`) y de `runs` |

Ningún sitio vuelve a llamar a `heartbeatctl qmd-reindex` por su cuenta: la única llamada vive en la orden del ayudante (FR-008).

## 6. Invariantes que el oráculo fija

- **I1**: solo `already running` se reintenta; un `status` distinto de 0 sin ese texto no se reintenta.
- **I2**: con el lock libre hay un solo intento, ninguna espera, ninguna sonda y `REINDEX_WAITED_S` es 0.
- **I3**: la salida de un intento no se concatena con la del anterior.
- **I4**: retornar 0 significa que el último intento no perdió el lock (corrió, o falló por otra causa que el sitio juzga con `REINDEX_STATUS`); el ayudante nunca convierte un reindex fallido en un éxito, y `REINDEX_STATUS` conserva el estado del último intento. Como un intento que pierde el lock también sale con estado 0, los sitios exigen el retorno y no solo el estado.
- **I5**: 124, 137 y 143 retornan 3 sin dormir ni reintentar.
- **I6**: un intento ocupado con tiempo transcurrido mayor o igual al plazo escribe R-EXPIRED y retorna 1; el ayudante nunca retorna 0 sin un intento que no dijo `already running`.
- **I7**: la sonda del dueño corre una vez en la primera contención y una vez al vencer; una sonda que falla o no encuentra nada no cambia el retorno ni agrega líneas que no sean las del caso.
- **I8**: el plazo se normaliza según la tabla de la sección 4.
- **I9**: el tiempo se lee solo por `_qmd_e2e_now` y se duerme solo por `_qmd_e2e_sleep`.
- **I10**: `qmd_e2e_reindex_wait` y `qmd_e2e_reindex_effect` no escriben nada por stdout (solo por fd 3), para no contaminar `run` ni `$(...)` en los sitios. `qmd_e2e_lock_owners` es la excepción: imprime sus líneas por stdout porque su llamador las captura.
- **I11**: sin constructos de bash 4, sin aserciones intermedias muertas (`[[ ]]` o `!`) y sin `producer | grep -q`.
- **I12**: la cadena `already running` del ayudante es la que el producto escribe (`scripts/lib/qmd_index.sh:562`); una prueba compara las dos.
- **I13**: la orden de cada intento es exactamente la de la sección 2 (el tope `timeout -k 10 600` y la salida reescrita con `>` en `/tmp/qmd-reindex.out` y reimpresa); una prueba la compara con la que recibió el exec falso (agregada en el análisis del 31-10-2026).

## 7. Fuera del contrato

El producto (el `flock -n`, su salida con 91, el mensaje), el watcher, el cron y cualquier cambio en `docker/`, `scripts/`, `modules/` o `setup.sh`.
