# Contrato: el oráculo del host

**Feature**: `043-e2e-lock-race-hardening` | **Cubre**: FR-010 y la parte de prueba de FR-001 a FR-009 | **Spec**: [../spec.md](../spec.md) | **Ayudante**: [reindex-wait.md](reindex-wait.md) | **Sonda**: [lock-owner-dump.md](lock-owner-dump.md)

Una prueba que no puede fallar no es evidencia: cada prueba de esta página tiene al menos una mutación que la pone en rojo (sección 5). El oráculo corre en el host, sin Docker, en bash 5.x y en 3.2, en ubuntu amd64 y en macOS arm64 (CI), y sigue las reglas de `tests/qmd-embed-nightly.bats:17-26`: sin `mapfile`, sin arreglos asociativos, sin `${v,,}`, aserciones por `[ ]`, `grep -q` o `case` y nunca por un `[[ ]]` o un `!` intermedios, sin `producer | grep -q`, y nada grande por argv ni por el entorno.

## 1. Archivos

| Archivo | Cambio | Contenido |
| --- | --- | --- |
| `tests/qmd-e2e-lock.bats` | nuevo | las 26 pruebas de esta página |
| `tests/helper-qmd-e2e.bash` | nuevo | el ayudante (lo escribe la implementación después de las pruebas) |
| `tests/qmd-embed-nightly.bats` | enmienda de P1 | la fase `reindex` de 041 pasa a exigir la llamada al ayudante (sección 4) |
| `tests/docker-e2e-qmd.bats` | edición | los cuatro sitios, `_embed_failure_state` y el `load` del ayudante |

## 2. El arnés del archivo nuevo

- **Exec falso** (`fake_exec`): sigue un plan en archivos del directorio temporal. Clasifica cada llamada por su texto: la que trae `heartbeatctl qmd-reindex` es un intento, la que trae `/proc` es la sonda del dueño y la que trae `vault_hash` es la comprobación del efecto. Los intentos consumen una cola de respuestas de la forma `ESTADO` y `SALIDA`; la sonda y el efecto devuelven una respuesta fija. Registra cada llamada en un archivo, guarda los argumentos de cada intento (para que L1 compare la orden entera, I13) y **falla la prueba si hay más de 500 intentos** (un ayudante sin plazo no cuelga el oráculo).
- **Exec real del efecto** (`real_effect_exec`, solo X6, desde la revisión T033): corre el mismo script que el ayudante manda al contenedor, con `bash -c` en vez de `bash -lc` (un perfil de login no es hermético en un host), la librería del repo (`QMD_E2E_LIB_DIR`), un archivo de estado temporal (`QMD_INDEX_STATE_FILE`, la costura del producto) y un vault temporal (`QMD_VAULT_DIR`). El hash esperado lo calcula `vault_hash` de `scripts/lib/backup_vault.sh` sobre el mismo directorio, como el producto.
- **Reloj falso**: `_qmd_e2e_now` lee un contador de archivo y `_qmd_e2e_sleep` lo avanza lo que se le pide y lo registra; el ayudante se carga con `load helper-qmd-e2e` y las dos funciones se redefinen después en la prueba (una función redefinida después de `source` se respeta en bash 3.2 y 5.x).
- **fd 3**: cada llamada al ayudante se hace con `3>"$TMP_TEST_DIR/fd3.txt"`, de modo que los reportes se afirman como texto; la salida estándar va a otro archivo y se afirma vacía (I10).
- **Retorno**: `qmd_e2e_reindex_wait ... || rc=$?` y `qmd_e2e_reindex_effect ... || rc=$?`, porque un retorno distinto de 0 aborta una prueba de bats. Es el mismo contexto en que los llaman los sitios (una lista `||` o la condición de un `if`), donde bash no aplica errexit dentro de la función; probarlos en otro contexto dejaría pasar un defecto que solo aparece en el contenedor (medido en bash 3.2.57 y 5.3.15 en el análisis del 31-10-2026).

## 3. Las pruebas

### L: la espera (`qmd_e2e_reindex_wait`)

| Id | Qué prueba | Requisito |
| --- | --- | --- |
| L1 | lock libre: un intento, retorno 0, `REINDEX_ATTEMPTS` 1, `REINDEX_WAITED_S` 0, ninguna espera, ninguna llamada a la sonda, nada por stdout, y la orden que recibió el exec es exactamente la de `reindex-wait.md` sección 2 (el tope `timeout -k 10 600` y la salida reescrita con `>` en `/tmp/qmd-reindex.out`) | FR-001, FR-003, FR-005, I2, I10, I13 |
| L2 | ocupado dos veces y libre a la tercera: tres intentos, dos esperas de exactamente 2 s, retorno 0, `REINDEX_WAITED_S` 4, `REINDEX_OUTPUT` es el del tercer intento, la sonda corrió una vez | FR-001, I1, I7 |
| L3 | nunca se libera con el plazo en 6 s: retorno 1 al cuarto intento (tiempos 0, 2, 4 y 6), tres esperas; el reporte nombra el lock, `6 s`, `4 attempts`, la salida del último intento y las líneas de la sonda; la sonda corrió dos veces | FR-004, I6, I7 |
| L4 | un reindex que falla por otra causa (estado 5, salida `boom`, sin `already running`): un intento, retorno 0, `REINDEX_STATUS` 5, `REINDEX_OUTPUT` `boom`, ninguna espera | FR-001, I1, I4 |
| L5 | los estados 124, 137 y 143 retornan 3 en el primer intento, sin espera ni reintento | FR-005, I5 |
| L6 | el plazo efectivo para sin definir, vacío, `abc`, `99999`, `0`, `3601`, `08`, `7` y `3600` (tabla de `reindex-wait.md` sección 4) | FR-005, I8 |
| L7 | una sonda que falla (el exec devuelve 1 sin salida) no cambia el retorno ni el conteo de intentos | I7 |
| L8 | un exec que falla sin salida (estado 1, vacío) no se lee como ocupado: un intento, retorno 0, `REINDEX_STATUS` 1 | FR-001, I1 |
| L9 | la salida de un intento no arrastra la del anterior: tras un intento ocupado y uno bueno, `REINDEX_OUTPUT` es exactamente la del segundo (y por eso no contiene `already running`; la revisión T033 quitó el negativo, que no podía fallar después de la igualdad) | I3 |
| L10 | el tiempo y la espera solo pasan por las costuras: con un `date` y un `sleep` falsos en el `PATH` que registran su uso, tras una espera con intentos ocupados los dos registros están vacíos | I9 |

### X: el efecto (`qmd_e2e_reindex_effect`)

| Id | Qué prueba | Requisito |
| --- | --- | --- |
| X1 | `indexed`, `pending` 0 y hash igual al del vault: retorno 0 | FR-002 |
| X2 | `skipped`, `pending` 0 y hash igual: retorno 0 (otro reindex legítimo hizo el trabajo) | FR-002 |
| X3 | hash distinto del vault: retorno 1 y el reporte nombra los dos hashes; un hash que no se pudo leer (`-` en uno de los dos o en ambos) falla como tal, con `the hash could not be read`, y dos `-` no cuentan como iguales (revisión T033, H2) | FR-002, FR-004 |
| X4 | `error`, `partial` y `stalled`: retorno 1 y el reporte nombra el estado | FR-002 |
| X5 | `pending` 3 y `pending` ausente: retorno 1 | FR-002 |
| X6 | la lectura del efecto corre de verdad en el host, con el exec real del efecto (sección 2): el archivo de estado ausente da retorno 1 con `qmd-index.json is absent` y sin ningún texto de `jq`; el índice del vault (estado `indexed`, `pending` 0 y el hash de `vault_hash`) pasa; `pending` 3 falla nombrándolo, lo que fija el orden de los campos de la línea `STATE`; y una página escrita después del índice falla con los dos hashes, lo que prueba que el hash del vault se calcula y no se copia del estado (revisión T033, H3: antes X6 usaba el exec falso y el script nunca corría fuera del contenedor) | FR-002, FR-004 |

### O: la sonda del dueño

| Id | Qué prueba | Requisito |
| --- | --- | --- |
| O1 | solo en Linux (se salta en macOS con su motivo): con un proceso real que tiene el archivo del lock abierto en el descriptor 9, la salida trae `pid N fd 9 cmd=[` con su pid; y con un segundo retenedor (`perl`) cuya línea de comando trae un salto de línea, la salida lo nombra, cada renglón es un dueño (`pid ...`) y su comando no pasa de 120 caracteres (agregado en T035: la sonda derramaba en varias líneas el script del `sh -c` del retenedor); los procesos se lanzan con fd 3 y 4 cerrados y se matan en `teardown` | FR-009, SC-008 |
| O2 | sin retenedor: en Linux dice `none found` con el archivo presente y `lock file absent` sin él; en macOS dice `no /proc here`; en los dos casos el estado de salida es 0 | FR-009 |

### B: los cuerpos de los sitios (se leen del archivo, como P1 y P2)

| Id | Qué prueba | Requisito |
| --- | --- | --- |
| B1 | la fase `reindex` de 041 (entre `_embed_phase reindex` y `_embed_phase semantic-search`) llama a `qmd_e2e_reindex_wait inc` y evalúa `qmd_e2e_reindex_effect inc` en la condición de un `if` (`if ! qmd_e2e_reindex_effect inc`), conserva `gatos.md`, la rama del tope (`qmd-reindex did not finish`, `SECONDS - t0`) y una línea `false` sangrada tras cada reporte (tres: el tope, el retorno 1 y el efecto no cumplido), y **no** contiene la aserción `grep -qE` sobre `ok` o `indexed` ni `heartbeatctl qmd-reindex` | FR-001, FR-002, FR-005, FR-008 |
| B2 | la prueba 13 llama dos veces a `qmd_e2e_reindex_wait in_container`; la llamada del bucle guarda el retorno en `rc1` y el bucle termina en `false` con 1 o 3 (el bloque se exige entero, con su `false`), y también con un `REINDEX_STATUS` distinto de 0, después de `_qmd_e2e_note` con el estado y la salida (revisión T033, H4 y H7); la del segundo tick lo guarda en `rc2` y el cuerpo exige `[ "$rc2" -eq 0 ]` y `REINDEX_STATUS` 0 antes de comparar conteos (un intento que perdió el lock también sale con estado 0: solo el retorno prueba que el tick corrió); la lectura de `engine-calls.log` termina en `\|\| true`; no contiene `heartbeatctl qmd-reindex`; y `teardown` vuelca los logs del contenedor de la prueba 13 cuando la prueba falla (`BATS_TEST_COMPLETED` vacío), antes de `docker compose down` | FR-006, FR-007, FR-008 |
| B3 | la fase 3 de la prueba 12 declara `local rc3=0`, llama a `qmd_e2e_reindex_wait in_container` con el retorno en `rc3`, exige `[ "$rc3" -eq 0 ]` y `REINDEX_STATUS` 0, conserva línea por línea las dos lecturas del estado (`jq -r .last_status` y `jq -r .runs`) y la comprobación de cada una (`grep -qE '^(indexed\|skipped)$'` y `[ "$runs_after_cron" -ge 1 ]`; revisión T033, H4: antes bastaba que aparecieran las palabras) y no contiene `heartbeatctl qmd-reindex` | FR-008 |
| B4 | `_embed_failure_state` trae el encabezado del dueño, `QMD_E2E_LOCK_OWNERS_SH` y `head -n 3` de `qmd-setup.err`, cada sonda nueva con su `\|\| true`, y conserva primero el encabezado que cita la checklist | FR-009 |
| B5 | ninguna línea que no sea comentario de `tests/docker-e2e-qmd.bats` contiene `heartbeatctl qmd-reindex`: la única llamada vive en el ayudante | FR-008 |
| B6 | el e2e carga el ayudante una sola vez, después de `load helper` | FR-008 |

### D: guardias

| Id | Qué prueba | Requisito |
| --- | --- | --- |
| D1 | la cadena de `QMD_E2E_LOCK_BUSY_MARK` es la que el producto escribe: el prefijo `reindex:` seguido de ella aparece literal en `scripts/lib/qmd_index.sh` | I12 |
| D2 | el ayudante pasa `bash -n` y no contiene `[[`, `mapfile`, `readarray`, `declare -A`, `local -n`, la tubería con `&`, una tubería hacia `grep -q`, `coproc`, la minúscula o mayúscula por expansión (`${...,,}` y `${...^^}`) ni una negación `!` como comando; y la sonda no contiene `flock` ni abre el archivo del lock (`>"$lock"`, `> "$lock"`, `9>`), porque tomarlo un instante podría hacer perder el lock a la corrida que observa (revisión T033, H5) | I11, `lock-owner-dump.md` §1 |

Total: 10 + 6 + 2 + 6 + 2 = **26 pruebas nuevas**. La suite del host debe terminar con la línea base medida más 26 en cada bash (1868 + 26 = 1894 si `origin/main` sigue en `cd8b74f`; la cifra final la fija `tasks.md`).

## 4. Enmienda de P1 (`tests/qmd-embed-nightly.bats:855-935`)

Solo cambia lo que P1 exige de la fase `reindex`. Las ocho marcas, su orden y las anclas de las otras siete fases no cambian.

| Hoy exige | Pasa a exigir |
| --- | --- |
| ancla `heartbeatctl qmd-reindex` | ancla `qmd_e2e_reindex_wait` |
| la aserción `grep -qE` sobre `ok` o `indexed` | `qmd_e2e_reindex_effect` (y la ausencia de esa aserción) |
| `timeout -k 10 600` | nada en P1: el tope vive en la orden del ayudante, que L1 compara entera (I13); B1 exige la rama del retorno 3 |
| `qmd-reindex did not finish`, `SECONDS - t0`, `[ "$output" = "0" ]` | lo mismo (se conservan en la fase) |
| una línea `false` sangrada tras el reporte | lo mismo |

P2 no cambia de contenido (la sonda nueva cumple su regla de `\|\| true`), G3 tampoco (el encabezado citado se conserva) y K1 a K4 tampoco (cargan el archivo completo, y `load helper-qmd-e2e` se resuelve desde `tests/`).

La enmienda repite en P1 parte de lo que exige B1 (`gatos.md`, `qmd-reindex did not finish`, `SECONDS - t0`, `[ "$output" = "0" ]` y las líneas `false`). Es a propósito: P1 cuida el esqueleto de las ocho fases y B1 el detalle de la fase `reindex`, así que un cambio de esa fase toca los dos oráculos.

## 5. Catálogo de mutaciones

Cada mutación se aplica sobre una copia aislada de los archivos que lee el oráculo, nunca sobre el árbol de trabajo, como usuario no root, y exige que el texto a mutar aparezca exactamente una vez (si no, la mutación se declara rota y no corre). Se corre en los dos bash.

| Id | Mutación | La cazan |
| --- | --- | --- |
| M1 | `already running` deja de reintentarse (se lee como «corrió») | L2, L3, L9 |
| M2 | se reintenta cualquier estado distinto de 0 | L4, L8 |
| M3 | se reintentan 124, 137 y 143 | L5 |
| M4 | sin plazo (espera sin límite) | L3 |
| M5 | el plazo compara con `>` en vez de `>=` | L3 |
| M6 | cadencia 0 (sin espera) | L2 |
| M7 | cadencia 1 en vez de 2 | L2 |
| M8 | espera antes del primer intento | L1 |
| M9 | la sonda corre en cada intento ocupado | L2, L7 |
| M10 | una sonda que falla cambia el retorno | L7 |
| M11 | la sonda no corre al vencer el plazo | L3 |
| M12 | se lee la salida del primer intento en vez de la del último | L2, L9 |
| M13 | las salidas de los intentos se concatenan | L9 |
| M14 | `REINDEX_STATUS` se fuerza a 0 | L4 |
| M15 | un exec que falla sin salida se lee como ocupado | L8 |
| M16 | el tiempo se lee con `date` directo | L10 |
| M17 | se quita el `10#` de la normalización | L6 |
| M18 | se ignora `QMD_E2E_REINDEX_LOCK_WAIT_S` | L3, L6 |
| M19 | el efecto acepta cualquier estado | X4 |
| M20 | el efecto ignora el hash | X3 |
| M21 | el efecto ignora `pending` | X5 |
| M22 | el efecto rechaza `skipped` | X2 |
| M23 | el archivo ausente se reporta como un error de `jq` | X6 |
| M24 | la fase 041 vuelve a su aserción `grep -qE` sobre `ok` o `indexed` | B1 |
| M25 | la fase 041 no llama a `qmd_e2e_reindex_effect` | B1 |
| M26 | la lectura de `engine-calls.log` de la prueba 13 pierde su `\|\| true` | B2 |
| M27 | el segundo tick de la prueba 13 vuelve a la llamada pelada | B2, B5 |
| M28 | la fase 3 de la prueba 12 vuelve a la llamada pelada | B3, B5 |
| M29 | el estado al fallar pierde la sonda del dueño | B4 |
| M30 | una sonda nueva del estado al fallar pierde su `\|\| true` | B4 |
| M31 | el producto cambia el texto `already running` | D1 |
| M32 | el ayudante usa un constructo de bash 4 | D2 |
| M33 | el ayudante escribe por stdout | L1, L2 |
| M34 | el e2e deja de cargar el ayudante | B6 |
| M37 | la orden del intento pierde `timeout -k 10 600` | L1 |
| M38 | la orden del intento agrega con `>>` en vez de reescribir con `>` | L1 |
| M39 | el segundo tick de la prueba 13 deja de exigir su retorno (`\|\| true` en vez de `\|\| rc2=$?` y su comprobación) | B2 |
| M40 | la fase 3 de la prueba 12 deja de exigir su retorno | B3 |
| M41 | `teardown` pierde el volcado de logs de la prueba 13 | B2 |

T032 (01-11-2026) agregó M42 a M80, una por cada aserción de B1 a B6 que ninguna mutación anterior ponía en rojo como primera falla (bats se detiene en la primera, así que una mutación que tumba dos aserciones de la misma prueba solo demuestra la primera), más una para X1, que no tenía ninguna, otra para la primera aserción de D1 y otra para la regla de la negación de D2:

| Id | Mutación | La cazan |
| --- | --- | --- |
| M42 | la fase 041 vuelve a la llamada pelada | B1, B5 |
| M43 | la página nueva de la fase 041 queda fuera de `wiki/` (fuera de la colección) | B1 |
| M44 | el reporte del tope de la fase 041 cambia de texto | B1 |
| M45 | el reporte del tope de la fase 041 deja de medir lo que tardó (`SECONDS - t0`) | B1 |
| M46 | la fase 041 deja de exigir `pending` 0 | B1 |
| M47 | la fase 041 ignora el retorno 1 del ayudante y sigue sin `false` | B1 |
| M48 | una llamada pelada vuelve a la fase 041 junto a la del ayudante | B1, B5 |
| M49 | el título de la prueba 041 cambia (B1 no puede pasar en vacío) | B1 |
| M50 | la marca de la fase `reindex` cambia de nombre (ídem) | B1 |
| M51 | el e2e deja de cargar `helper` | B6 |
| M52 | el e2e carga el ayudante antes de `helper` | B6 |
| M53 | el título de la prueba 13 cambia (B2 no puede pasar en vacío) | B2 |
| M54 | el primer tick de la prueba 13 deja de guardar su retorno | B2 |
| M55 | el bucle de la prueba 13 deja de mirar el retorno del primer tick | B2 |
| M56 | el bucle de la prueba 13 lee el log con otra orden (ídem) | B2 |
| M57 | el plazo de 45 s del bucle de la prueba 13 cambia | B2 |
| M58 | el segundo tick de la prueba 13 guarda su retorno pero no lo exige | B2 |
| M59 | el segundo tick de la prueba 13 deja de exigir `REINDEX_STATUS` 0 | B2 |
| M60 | una llamada pelada vuelve a la prueba 13 junto al segundo tick | B2, B5 |
| M61 | `teardown` vuelca los logs de la prueba 13 también cuando pasa | B2 |
| M62 | `teardown` conserva el bloque de la prueba 13 pero pierde sus logs | B2 |
| M63 | `teardown` baja el proyecto antes del volcado de la prueba 13 | B2 |
| M64 | el encabezado de la fase 3 de la prueba 12 cambia (B3 no puede pasar en vacío) | B3 |
| M65 | la fase 3 de la prueba 12 pierde `local rc3=0` | B3 |
| M66 | la fase 3 de la prueba 12 guarda su retorno pero no lo exige | B3 |
| M67 | la fase 3 de la prueba 12 deja de exigir `REINDEX_STATUS` 0 | B3 |
| M68 | la fase 3 de la prueba 12 pierde su aserción sobre `last_status` | B3 |
| M69 | la fase 3 de la prueba 12 pierde su aserción sobre `runs` | B3 |
| M70 | una llamada pelada vuelve a la fase 3 de la prueba 12 junto a la del ayudante | B3, B5 |
| M71 | el ayudante lleva una segunda llamada a `heartbeatctl qmd-reindex` | B5 |
| M72 | la función del estado al fallar cambia de nombre (B4 no puede pasar en vacío) | B4 |
| M73 | el estado al fallar pierde el encabezado del dueño | B4 |
| M74 | la sonda del dueño corre sin `-u agent` (Principio II) | B4 |
| M75 | el estado al fallar pierde `head -n 3` de `qmd-setup.err` | B4 |
| M76 | el encabezado que cita la checklist cambia de texto | B4 |
| M77 | el encabezado del dueño queda antes del que cita la checklist | B4 |
| M78 | el efecto lee la primera línea de la salida en vez de la línea `STATE` | X1 |
| M79 | la marca de ocupado del ayudante se acorta a `already` | D1 |
| M80 | una línea del ayudante empieza con una negación `!` | D2 |

La revisión independiente de T033 (01-11-2026) agregó M81 a M91, una por cada hallazgo corregido que el host puede ver (H6, la lectura de `cmdline` de un proceso que termina a mitad de la sonda, no tiene mutación: el host no puede provocar esa carrera; se verificó leyendo y con el humo de la sonda en BusyBox 1.37.0 y 1.36.1):

| Id | Mutación | La cazan |
| --- | --- | --- |
| M81 | dos hashes ilegibles (`-`) cuentan como iguales (H2) | X3 |
| M82 | el script del contenedor pierde la guarda del estado ausente (H3) | X6 |
| M83 | el script del contenedor lee `.status` en vez de `.last_status` (H3) | X6 |
| M84 | el script del contenedor invierte el orden de los campos de la línea `STATE` (H3) | X6 |
| M85 | el script del contenedor toma el hash del vault del propio archivo de estado (H3) | X6 (y X1 a X5, porque el exec falso reconoce la lectura del efecto por la palabra `vault_hash`) |
| M86 | el script del contenedor carga la librería desde una ruta equivocada (H3) | X6 |
| M87 | la fase 3 de la prueba 12 lee `last_status` pero ya no lo compara (H4) | B3 |
| M88 | la fase 3 de la prueba 12 lee `runs` pero ya no lo compara (H4) | B3 |
| M89 | la rama del retorno distinto de 0 del primer tick de la prueba 13 termina en `true` (H4) | B2 |
| M90 | la sonda abre el archivo del lock y toma el lock (H5) | D2 |
| M91 | el primer tick de la prueba 13 deja de mirar `REINDEX_STATUS` (H7) | B2 |

Criterio de aceptación (SC-004): **89 de 89 cazadas en bash 5.x y en 3.2** (M1 a M34 y M37 a M91; M37 a M41 las agregó el análisis del 31-10-2026, M42 a M80 T032 y M81 a M91 la revisión de T033), cada prueba nueva cae con al menos una mutación y cada aserción de B1 a B6 es la primera falla de al menos una (B5 con M27, M28, M42, M48, M60, M70 y M71). B6 tenía además una guardia `[ -n "$l2" ]` que ninguna mutación podía poner en rojo como primera falla (con `n` en 1 la línea existe), y T032 la quitó. O1 y O2 caen con M35, M36 y M92, tres mutaciones del script de la sonda (M35 compara el `readlink` con otra ruta; M36 imprime `none found` cuando el archivo del lock no existe; M92, agregada en T035, vuelve a cambiar solo los NUL y deja que un comando de varias líneas se derrame en el reporte), que solo pueden caer en Linux: O1 se salta en macOS y la rama de `/proc` no existe ahí. Corren en la pata Linux (`ubuntu:24.04`, bash 5.2, con `jq` instalado desde T033 porque X6 lo usa, como en los dos brazos de la CI) y quedan fuera del 89 de 89.

## 6. El ROJO que se ve antes de implementar

Las pruebas se escriben primero. Contra el árbol actual: L1 a L10, X1 a X6, O1, O2, D1 y D2 fallan porque `tests/helper-qmd-e2e.bash` no existe (`load` falla; D1 compara la constante del ayudante con el producto, y O1 carga el ayudante antes de su `skip` de Linux, así que en macOS también cae por la carga); B1 a B6 fallan por el contenido actual del e2e (no llama al ayudante y no tiene las sondas). La enmienda de P1 se escribe con ellas y también cae contra el cuerpo actual de la fase. El ROJO de comportamiento de O1 y de la rama de `/proc` de O2 no se ve en macOS: lo dan M35 y M36 en la pata Linux. Se registra qué pruebas caen y por qué razón antes de tocar el e2e (principio III).
