# Feature Specification: Los tests e2e de qmd dejan de caer por la carrera del `.reindex.lock`

**Feature Branch**: `043-e2e-lock-race-hardening`

**Created**: 2026-10-29

**Status**: Draft

**Input**: Dos pruebas de `tests/docker-e2e-qmd.bats` suponen que `.reindex.lock` está libre cuando lanzan un reindex manual y se rompen cuando no lo está: la fase `reindex` de `qmd real (041)` (noche roja del 29-10-2026, issue #112) y el bucle de la prueba 13 de 037 (issue #109). El operador quiere (1) que la fase espere y reintente de forma acotada y afirme el efecto del reindex, (2) que el bucle de la prueba 13 no aborte cuando `engine-calls.log` todavía no existe, (3) que, si igual falla, el estado al fallar diga quién tiene el lock, y (4) un oráculo del host que ate esos cuerpos al reintento, con la corrección demostrada por una falla inyectada. Es una feature solo de pruebas: no cambia el producto ni `VERSION`.

## Contexto

**El defecto, medido.** La nocturna del 29-10-2026 (run 40865079036, sobre `157941b`, issue #112) fue la primera noche roja desde que la fase del embed volvió a ejecutarse con el arreglo de 042 (#107 se cerró con el PR #110). Cayó `qmd real (041)` en la fase `reindex`; las otras 48 pruebas pasaron. El log del job da la cronología: la fase `setup` duró de las 11:33:47,9Z a las 11:38:33,5Z (285,6 s); la marca `reindex` salió a las 11:38:33,6Z; el test empezó a volcar su estado de falla a las 11:38:33,9Z, unos 0,3 s después. En ese instante el reindex manual del test (`heartbeatctl qmd-reindex`) ya había escrito `[qmd] reindex: already running — skip` y había salido con 0; `qmd-index.json` no existía y falló la aserción de `tests/docker-e2e-qmd.bats:882` (`echo "$output" | grep -qE 'ok|indexed'`, sobre la salida de `jq -r .last_status` del archivo de estado). El estado al fallar descartó memoria (`oom=false`, contadores en 0), disco (82 GB libres) y red, y mostró `MUSL .../sqlite-vec-linux-x64/vec0.so`: el arreglo de 042 había funcionado en esa corrida.

**Perder la carrera no es un defecto del producto.** `qmd_reindex` toma un `flock -n` (no bloqueante) sobre `$cache_root/.reindex.lock` dentro de un subshell que tiene el lock en el descriptor 9; quien no lo obtiene escribe `already running — skip`, sale del subshell con 91 y la función devuelve 0 a propósito, para que ni el cron ni el vigilante puedan tumbar nada (`scripts/lib/qmd_index.sh:545-573`, la salida en `:561-566`). `qmd_setup_if_needed` hace lo mismo (`:453-488`) y el reindex manual entra por `docker/scripts/heartbeatctl:1102-1130`. El lock lo comparten, entonces, el setup del primer arranque, el reindex manual, el del cron y el del vigilante de archivos.

**Por qué la fase cae.** La fase supone el lock libre apenas aparece el sentinel del setup (comentario de `tests/docker-e2e-qmd.bats:862-866`), lanza el reindex manual una sola vez (`:874-880`) y afirma sobre el estado que deja esa misma corrida (`:881-887`). Si esa única corrida pierde el lock, no hay estado que afirmar.

**Quién tenía el lock: no se sabe.** El estado al fallar no lista procesos. Dos candidatos por lectura del código, sin medir: (a) el reindex del vigilante (`scripts/qmd_watch.sh` lanza `heartbeatctl qmd-reindex` con la salida descartada, 15 s después del último evento del vault: `:20`, `:52-59`), que habría necesitado un evento en el vault unos 15 s antes del fallo; (b) un descendiente del setup que heredó el descriptor 9 y vivió unos instantes más que el sentinel (ningún código cierra ese descriptor para los procesos que arranca dentro del tramo con lock). La cronología hace poco probable que el dueño fuera el propio subshell del setup: el sentinel es lo último que escribe (`qmd_index.sh:537-539`, y el subshell termina enseguida) y lo detectó un sondeo de unos 5 s de período (`tests/docker-e2e-qmd.bats:830-839`) unas décimas de segundo antes del reindex manual. Descartados por lectura: el cron de reindex (el workspace de qmd real lo programa el 31 de febrero, `:645-666`, y el oráculo P2 de 041 lo guarda), la propia llamada manual, un reindex de arranque posterior al setup (`docker/scripts/start_services.sh` solo despacha el setup, `:183-188`) y el cron del wiki-graph (`20 */6 * * *`, `docker/scripts/heartbeatctl:388`), cuyo minuto 20 no coincide con la hora del fallo (11:38Z).

**El mismo supuesto en otros sitios.** (a) La prueba 13 de 037 (`:400-528`) tiene un bucle de reintento de 45 s (`:493-499`) que existe justamente para absorber esta carrera (comentario de `:486-492`), pero su línea `calls=$(in_container sh -c 'cat "$HOME/.cache/qmd/engine-calls.log" 2>/dev/null')` (`:496`) sale con 1 si el archivo aún no existe y, dentro de `$(...)` bajo el errexit de bats, aborta la prueba en la primera vuelta (issue #109; inferido por lectura, sin un volcado del contenedor que lo confirme). (b) El segundo tick de esa prueba (`:522-527`) comprueba que no hay una segunda migración; si pierde el lock tampoco la hay, y pasa en vacío. (c) La fase 3 de la prueba 12 (`:264-276`) lanza un reindex manual y afirma `indexed` o `skipped` sobre el archivo de estado, sin reintento: si pierde el lock siendo el primer reindex, el archivo no existe (el setup no lo escribe). Los tres comparten la misma premisa: «el lock está libre ahora».

**Una segunda carrera en la prueba 13, fuera de alcance.** Por lectura de `qmd_index.sh:463-540`, con `index.sqlite` presembrado y sin `.qmd-setup-ok`, el setup de arranque de esa prueba no se salta: toma el lock, corre `update` y `embed` contra el motor falso y escribe el sentinel, así que es el dueño probable del lock cuando la prueba 13 pierde la carrera. La aserción de `:483-484` (`[[ ... SKIPPED ]]`, viva en bash 5) pasa solo si se evalúa antes de que ese refresco termine, y el comentario de `:394-396` dice que el setup se salta. No está medido: la prueba pasó 27 de 28 corridas, y la que cayó lo hizo en `:496`. Lo encontró el análisis del 31-10-2026; por decisión del operador queda declarado y fuera de esta feature, con un issue aparte que se propone con COMPUERTA.

**Por qué importa ahora.** Desde 042 la fase corre cada noche. Una de las cinco primeras cayó por esto y exigió una revisión completa de las cinco noches (29-10-2026). Hasta que esta feature llegue, cualquier noche puede salir roja por la misma carrera, y un rojo del arnés le quita al verde del nightly parte de su significado.

**Qué dejaron pendiente 041 y 042.** La política de FR-013 (un defecto que no es del producto se registra aparte y no se mezcla con la feature en curso) dejó dos issues: #109 (24-10-2026, la prueba 13) y #112 (29-10-2026, la fase `reindex`). El volcado opcional de `head -n 3` de `qmd-setup.err` en el estado al fallar quedó sin aplicar en 042 porque tocaba un archivo de 041 (`specs/042-qmd-sqlite-vec-x64/spec.md`, Assumptions). Esta feature es el lugar de los dos.

**Lo que no se sabe todavía**, y que el plan y la implementación responderán: (a) quién tenía el lock en la noche roja (la corrección no depende de saberlo, pero el estado al fallar de FR-009 lo mostrará si vuelve a pasar); (b) qué herramientas de diagnóstico trae el busybox de la imagen, que ya respondió la Fase 0 del plan (`research.md` M1: `ps`, `fuser` y `lsof` de busybox están, y el usuario `agent` lee `/proc/<pid>/fd` de sus propios procesos, mientras que los de root dan `Permission denied`); (c) cuánto cuesta reconstruir las imágenes de prueba en el DOCKER_E2E local, porque la limpieza T036 del 29-10-2026 (registrada en el PR #115) quitó las etiquetas `agent-admin:qmd-real` y `agent-admin:qmd-embed` y conservó el caché de build.

### Estado de cada afirmación

| Afirmación | Estado | Fuente |
| --- | --- | --- |
| La fase `reindex` de `qmd real (041)` cayó en la noche del 29-10 porque el reindex manual perdió el lock | Medido | run 40865079036 (log del job y estado al fallar); issue #112 |
| La marca `reindex` salió a las 11:38:33,6Z y el test falló unos 0,3 s después; `setup` duró 285,6 s | Medido | log del run 40865079036 |
| Perder el lock devuelve 0 con `already running — skip`, por diseño | Leído en código | `qmd_index.sh:545-573`; `heartbeatctl:1102-1130` |
| La fase lanza un solo reindex manual y afirma sobre el estado de esa corrida | Leído en código | `docker-e2e-qmd.bats:874-887` |
| Ningún código cierra el descriptor 9 para los procesos hijos del tramo con lock | Verificado con una búsqueda de `9>&-` en los cuatro archivos que manejan el lock | `qmd_index.sh`, `qmd_watch.sh`, `heartbeatctl`, `start_services.sh` |
| El vigilante lanza el reindex 15 s después del último evento del vault, con la salida descartada | Leído en código | `qmd_watch.sh:20,52-59,70`; `start_services.sh:225` |
| El cron de reindex del workspace de qmd real no puede tomar el lock | Leído en código y guardado por un test | `docker-e2e-qmd.bats:645-666`; P2 de `qmd-embed-nightly.bats:937-985` |
| Quién tenía el lock en la noche roja | **No identificado** | el estado al fallar no lista procesos |
| El dueño no fue el propio subshell del setup, salvo que un descendiente heredara el descriptor | Inferido de la cronología y de la lectura | log del run; `qmd_index.sh:474-480,537-539`; `docker-e2e-qmd.bats:830-839` |
| El reindex del vigilante (disparado por la escritura de `gatos.md`) puede adelantarse al manual, indexar la página y dejar al manual con `skipped`; solo pasa si el lock se suelta poco antes de que el vigilante dispare, porque ese reindex es uno solo y no reintenta | Inferido por lectura; sin medir; la aceptación de `skipped` la prueba X2 en el host | `qmd_index.sh:689-693`; `qmd_watch.sh:51-60`; `docker-e2e-qmd.bats:867` |
| La prueba 13 aborta en la primera vuelta si `engine-calls.log` aún no existe | Inferido por lectura (el `cat` sale con 1 dentro de `$(...)`, bajo el errexit de bats); sin volcado del contenedor que lo confirme | `docker-e2e-qmd.bats:493-499`; run 40043000392; issue #109 |
| El segundo tick de la prueba 13 pasa en vacío si pierde el lock | Inferido por lectura | `docker-e2e-qmd.bats:522-527` |
| En la prueba 13 el setup de arranque no se salta: refresca el índice (`update` y `embed` contra el motor falso) bajo el lock y escribe `.qmd-setup-ok`, y la aserción de `:483-484` depende de que eso no haya terminado | Leído en código; sin medir; fuera de alcance (issue aparte) | `qmd_index.sh:463-540`; `docker-e2e-qmd.bats:394-396,483-484` |
| La fase 3 de la prueba 12 supone el lock libre | Leído en código; no hay falla registrada por esto | `docker-e2e-qmd.bats:264-276` |
| Frecuencia de la fase `reindex`: 1 de 5 nocturnas con la fase activa, 0 de 3 corridas manuales en CI y 0 de 2 locales en arm64 (T026 de 041, T022 de 042) | Medido, con muestras chicas | Registro de `specs/042-qmd-sqlite-vec-x64/tasks.md`; T026 de `specs/041-nightly-qmd-embed/tasks.md` |
| Frecuencia de la prueba 13: 1 falla en 28 corridas que ejecutaron la suite (20 anteriores a 042, las 3 manuales de 042 y las 5 nocturnas del 25 al 29-10) | Medido | Registro de `specs/042-qmd-sqlite-vec-x64/tasks.md` |
| Estados que el reindex deja en `last_status`: `indexed`, `skipped`, `partial`, `stalled` y `error` | Leído en código | `qmd_index.sh:635-710` |
| `ps`, `fuser` y `lsof` (busybox) existen en la imagen, y el usuario `agent` lee `/proc/<pid>/fd` de sus propios procesos (los de root dan `Permission denied`) | Medido (Fase 0 del plan: contenedor desechable `alpine:3.24.1`, usuario 1000) | `research.md` M1 |
| Línea base de CI de la suite del host en `cd8b74f`: 1868 en cada brazo (49 y 56 saltadas) | Medido | run 40988591966 |
| El DOCKER_E2E local debe reconstruir las imágenes de prueba (T036 quitó sus etiquetas el 29-10-2026); el costo no está medido | Medido (T036); costo del rebuild no medido | PR #115; `specs/042-qmd-sqlite-vec-x64/tasks.md` (Registro, T036) |

## Clarifications

### Session 2026-10-29

- Q: ¿Incluimos también la fase 3 de la prueba 12 (que supone el lock libre y no tiene falla registrada) en el endurecimiento, además de la fase `reindex` de 041 y la prueba 13? → A: Sí, todos los sitios. Toda llamada manual a `heartbeatctl qmd-reindex` de los e2e de qmd que afirme el efecto de un reindex espera al lock con el mismo comportamiento (mismo plazo, mismo criterio de reintento, mismo reporte); el segundo tick de la prueba 13 ya estaba en FR-007 por ser la misma prueba. Es la misma causa y el mismo arreglo, y la fase 3 de la prueba 12 cae igual que la 041 si pierde el lock siendo su primer reindex (no hay `qmd-index.json` previo).
- Q: ¿Exigimos corridas manuales del workflow en CI antes de abrir el PR, o bastan la inyección y el DOCKER_E2E locales más las nocturnas siguientes al merge? → A: Una corrida manual en CI (respondida el 31-10-2026, dos días después de abrirse la sesión). Antes de abrir el PR se hace un `workflow_dispatch` sobre la rama, con COMPUERTA de push y de dispatch, y el job debe terminar en verde con la fase activa; no son tres como en 042, porque tres corridas no distinguen una carrera de una en cinco (con esa tasa, tres limpias ocurren el 51 % de las veces aunque nada se hubiera arreglado) y 042 las necesitaba para medir el tope de tiempo, que aquí no cambia. La prueba determinista sigue siendo la inyección (SC-001); la corrida valida los cuerpos nuevos en el runner real (amd64), que el PR no ejercita porque solo corre la suite del host.

### Session 2026-10-31 (`/speckit-analyze`)

- Q: ¿Cómo se demuestra SC-008, que el estado al fallar de la prueba 16 nombra al dueño del lock, si ninguna corrida de la inyección forzaba un rojo de esa prueba con el cuerpo nuevo? → A: Con una corrida más de la inyección: la fase `reindex` de la 041 con el cuerpo nuevo, `QMD_E2E_REINDEX_LOCK_WAIT_S=6` y el lock retenido 600 s, que falla a propósito con R-EXPIRED y ejecuta de verdad el bloque nuevo de `_embed_failure_state` (unos 8 a 10 minutos más de Docker).
- Q: ¿Se exige evidencia en contenedor del caso en que otro reindex se adelanta y el manual deja `skipped`? → A: No. Lo prueba X2 en el host, y el texto se corrigió: el vigilante dispara un solo reindex unos 15 s después del último evento y no reintenta, así que con el lock retenido 20 s su reindex también pierde y esa corrida no puede mostrarlo.
- Q: ¿Qué se hace con la segunda carrera de arranque de la prueba 13 (`:483-484`, que depende de que el setup no haya escrito todavía `.qmd-setup-ok`)? → A: Se declara (Contexto, Out of Scope y la regla de corrida concluyente de la inyección) y va a un issue aparte, que se propone con COMPUERTA; esta feature no la corrige.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - La fase `reindex` de `qmd real (041)` espera al lock y afirma el efecto (Priority: P1)

Como mantenedor, quiero que el reindex manual de la fase `reindex` espere, de forma acotada, a que otro proceso legítimo suelte el lock y vuelva a intentar, y que la fase afirme lo que el reindex dejó hecho y no el estado de su propia corrida, para que una noche solo salga roja por un defecto del producto o por un plazo vencido de verdad, y no por perder una carrera del arnés.

**Why this priority**: Es la falla medida del 29-10 (una noche de cinco). Hasta que se corrija, cualquier noche puede salir roja por esto, y cada noche roja le cuesta al mantenedor un análisis completo y resta valor al verde.

**Independent Test**: En un contenedor real, retener `.reindex.lock` con un `flock` en segundo plano unos segundos antes del reindex manual de la fase. Sin el arreglo la fase cae con `already running` (ROJO); con el arreglo espera, reintenta y pasa (VERDE). Con la retención más larga que el plazo, la fase cae nombrando el lock.

**Acceptance Scenarios**:

1. **Given** el setup terminado y el lock retenido unos segundos por otro proceso, **When** la fase lanza el reindex manual, **Then** reintenta mientras la salida diga `already running`, dentro del plazo, y cuando el reindex corre afirma su efecto y `pending` en 0 (FR-001, FR-002).
2. **Given** que otro reindex legítimo (el del vigilante, disparado por la escritura de `gatos.md`, o el del cron) toma el lock después de esa escritura e indexa la página antes de que el reintento del manual lo consiga, **When** el reindex manual corre al fin y deja `skipped` con `pending` en 0, **Then** la fase pasa, porque el efecto está hecho (FR-002).
3. **Given** el lock libre, **When** corre la fase, **Then** lanza un solo intento y no agrega espera (FR-003).
4. **Given** el lock retenido más allá del plazo, **When** el plazo vence, **Then** la fase falla y su reporte nombra el lock, cuánto esperó, cuántos intentos hizo y la salida del último (FR-004).
5. **Given** un reindex que no pierde el lock pero falla (estado `error`, `partial` o `stalled`, o un rc distinto de 0), **When** la fase lo lee, **Then** falla de inmediato, sin reintentar (FR-001, FR-002).
6. **Given** un reindex que se cuelga, **When** pasan 600 s, **Then** el tope de 041 sigue cortándolo y nombrando la fase (FR-005).

---

### User Story 2 - Las pruebas 13 y 12 reintentan de verdad y ningún tick pasa en vacío (Priority: P1)

Como mantenedor, quiero que el bucle de reintento de la prueba 13 no aborte cuando `engine-calls.log` todavía no existe, que su segundo tick no pueda pasar por haber perdido el lock y que la fase 3 de la prueba 12 espere al lock como la fase `reindex`, para que ninguna prueba de qmd falle por perder una carrera del arnés.

**Why this priority**: Es el issue #109 (una falla en 28 corridas, con la misma causa) y el mismo supuesto en la fase 3 de la prueba 12, que no tiene falla registrada pero cae igual si pierde el lock siendo su primer reindex (no hay `qmd-index.json` previo). Es chico y barato, y el bucle de la prueba 13 existe justamente para absorber esta carrera pero se rompe en el caso del archivo ausente. Es P1 porque comparte causa y arreglo con la historia 1.

**Independent Test**: En el host, el oráculo de FR-010 lee los cuerpos y exige las propiedades. Con Docker, retener el lock antes del primer reindex manual de cada prueba: las dos pasan en vez de abortar o de leer un estado que no existe.

**Acceptance Scenarios**:

1. **Given** que `engine-calls.log` no existe en la primera vuelta del bucle, **When** el bucle lee el log, **Then** la vuelta no aborta y reintenta hasta el plazo de 45 s (FR-006).
2. **Given** una falla en cualquier punto de la prueba 13, **When** la prueba termina, **Then** el log del contenedor queda volcado en el reporte (FR-006).
3. **Given** que el segundo tick pierde el lock, **When** la prueba comprueba que no hubo una segunda migración, **Then** falla o reintenta en vez de pasar (FR-007).
4. **Given** el lock retenido unos segundos cuando la fase 3 de la prueba 12 lanza su reindex manual, **When** corre, **Then** espera y reintenta como la fase `reindex`, y afirma `indexed` o `skipped` sobre el archivo de estado solo cuando el reindex realmente corrió (FR-008).

---

### User Story 3 - Si igual falla por el lock, el reporte dice quién lo tenía (Priority: P2)

Como mantenedor, quiero que el estado que el test 041 vuelca al fallar nombre los procesos y descriptores que tienen abierto `.reindex.lock` y las primeras líneas de `qmd-setup.err`, para identificar al dueño la próxima vez, porque hoy no se sabe quién fue y el workspace desaparece al terminar el job.

**Why this priority**: Sin el dueño no se distingue un retenedor transitorio e inocuo (el vigilante) de un defecto del producto (un descriptor que se filtra a un huérfano): el reintento de la historia 1 lo oculta, pero no lo explica. Es P2 porque la corrección de las historias 1 y 2 no depende de saberlo.

**Independent Test**: En un contenedor, retener el lock con un proceso conocido y correr la sonda del estado al fallar: la salida nombra ese proceso (pid y comando) o dice qué herramienta falta.

**Acceptance Scenarios**:

1. **Given** un lock retenido por un proceso conocido, **When** se imprime el estado al fallar, **Then** la salida muestra ese proceso con su pid y su comando (FR-009).
2. **Given** que alguna herramienta de diagnóstico no existe en la imagen, **When** se imprime el estado, **Then** lo dice y el resto del volcado sigue (FR-009).
3. **Given** una falla del test 041 que no tiene que ver con el lock, **When** se imprime el estado, **Then** el volcado no la convierte en otra falla: cada sonda tolera su propia falla (FR-009).

---

### User Story 4 - La corrección se demuestra con una falla inyectada y se vigila en las noches siguientes (Priority: P2)

Como mantenedor, quiero ver el ROJO y el VERDE de la corrección con el lock retenido a propósito, un oráculo del host que impida que el reintento se debilite sin que ninguna prueba lo note, y las noches siguientes registradas, porque una carrera que ocurre una de cada cinco noches no se demuestra esperando.

**Why this priority**: Es lo que convierte la corrección en evidencia y la deja protegida. Depende de las historias 1 a 3, y por eso es P2.

**Independent Test**: El oráculo del host falla contra los cuerpos actuales y pasa tras la corrección; la falla inyectada da ROJO sin el arreglo y VERDE con él en un contenedor local.

**Acceptance Scenarios**:

1. **Given** los cuerpos actuales de la fase `reindex`, de la prueba 13 y de la fase 3 de la prueba 12, **When** corre el oráculo del host nuevo, **Then** falla, y pasa una vez aplicada la corrección (FR-010).
2. **Given** cada mutación del catálogo (quitar el reintento, hacerlo sin límite, aflojar la afirmación a cualquier estado, quitar el `|| true` de la lectura del log, quitar el volcado del dueño, quitar la exigencia de que el tick corrió), **When** corre el oráculo, **Then** cae en bash 5.x y en 3.2 (FR-010).
3. **Given** la falla inyectada (lock retenido) en un contenedor local, **When** corre la fase sin el arreglo y con él, **Then** da ROJO y VERDE (FR-011, SC-001).
4. **Given** la rama con la corrección, **When** se lanza el workflow a mano sobre ella antes de abrir el PR, **Then** el job termina en verde con `ok 16 qmd real (041)` ejecutado y no saltado y con `e2e summary:` sin fallas (FR-011).
5. **Given** las noches posteriores al merge, **When** se leen, **Then** quedan registradas con su veredicto, y ninguna cae por el lock sin que su reporte nombre al dueño (SC-007).

---

### Edge Cases

- **El reindex del vigilante se adelanta.** La fase escribe `gatos.md` justo antes del reindex manual y el vigilante dispara un solo reindex unos 15 s después del último evento, con la salida descartada y sin reintento (`qmd_watch.sh:51-60`). Se adelanta solo si el lock se suelta poco antes de que dispare y el reintento siguiente del manual llega cuando el del vigilante ya lo tomó; si el lock sigue tomado en ese momento, el del vigilante también pierde. Cuando se adelanta, indexa la página y deja `indexed`; el manual, al correr después, encuentra el vault sin cambios y completamente embebido y deja `skipped` (`qmd_index.sh:689-693`). Una corrección que siga exigiendo `indexed` convertiría esa corrida sana en roja: la afirmación es sobre el efecto (FR-002).
- **Un lock que nunca se suelta** (un descendiente huérfano con el descriptor 9): la fase falla al vencer el plazo, con el dueño en el reporte. Eso ya no es un defecto del arnés sino un hallazgo del producto, y se registra aparte (FR-013).
- **Un reindex que falla por otra causa** (`error`, `partial`, `stalled`, un rc distinto de 0, el tope de 600 s): no se reintenta. Solo `already running` se reintenta.
- **La salida de un intento no se confunde con la del anterior**: cada intento lee su propia salida (la fase deja la salida en `/tmp/qmd-reindex.out` y debe reescribirla en cada intento).
- **Con el lock libre la duración de la fase no cambia**: un solo intento, sin espera previa ni sondeos que tomen el lock (un sondeo que lo toma un instante puede hacer perder la carrera a otro proceso, incluido el reindex del vigilante).
- **El peor caso** suma el plazo de espera y un reindex acotado a 600 s: cabe en el tope de 45 minutos del job con las duraciones medidas de 17 min 48 s a 26 min 59 s (la nocturna del 31-10-2026, run 41194270915, la más lenta hasta hoy).
- **`docker compose exec` sale con 1 si el contenedor no responde**: eso no es `already running` y no debe tratarse como tal.
- **Aserciones intermedias muertas en bats**: `[[ ]]` es letra muerta en bash 3.2 y `! cmd` en los dos bash; toda aserción nueva va como `[ ]`, `grep -q` o `if cmd; then false; fi` (CLAUDE.md, sección de gotchas).
- **Plazos desde variables de entorno**: un valor con cero a la izquierda (`08`) es octal para `$(( ))` salvo que se normalice con `10#`, como ya hace `QMD_E2E_SETUP_DEADLINE_S` (`tests/docker-e2e-qmd.bats:825-829`).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: La fase `reindex` de `qmd real (041)` MUST esperar y reintentar el reindex manual mientras su salida diga `already running`, dentro de un plazo acotado, y MUST NOT reintentar ninguna otra falla (estado `error`, `partial` o `stalled`, rc distinto de 0, tope de 600 s).
- **FR-002**: Tras un reindex que realmente corrió, la fase MUST afirmar el efecto y no el estado de su propia corrida: `qmd-index.json` existe, `pending` es 0 y la página nueva quedó indexada. MUST aceptar que otro reindex legítimo (el del vigilante) haya hecho el trabajo mientras esperaba, o sea un `skipped` con `pending` en 0 cuando la página ya está indexada, y MUST seguir rechazando `error`, `partial`, `stalled` y la ausencia del archivo de estado. Cómo se comprueba que la página quedó indexada lo decide el plan; el oráculo de FR-010 debe fallar si la afirmación se debilita a «cualquier estado».
- **FR-003**: Con el lock libre, la fase MUST comportarse y durar lo mismo que hoy: un solo intento, sin espera añadida.
- **FR-004**: Si el reindex no corrió dentro del plazo, la fase MUST fallar con un reporte que nombre la causa (el lock ocupado), diga cuánto esperó y cuántos intentos hizo y muestre la salida del último, en lugar de un error de `jq` o de `grep`.
- **FR-005**: El tope de 600 s por intento (`timeout -k 10 600`) y el reporte de plazo vencido (rc 124, 137 o 143) MUST conservarse. El plazo de espera por el lock MUST ser independiente de ese tope, estar acotado y poder sobrescribirse con una variable de entorno de valor por defecto declarado, para ejercitar su vencimiento en segundos; el peor caso sumado MUST caber en el tope de 45 minutos del job.
- **FR-006**: El bucle de la prueba 13 de 037 MUST NOT abortar cuando `engine-calls.log` aún no existe en una vuelta: MUST reintentar hasta su plazo, y ante cualquier falla de la prueba MUST volcar los logs del contenedor (issue #109).
- **FR-007**: El segundo tick de la prueba 13 MUST NOT poder pasar en vacío por haber perdido el lock: la comprobación de que no hubo una segunda migración MUST exigir que el tick corrió.
- **FR-008**: El endurecimiento MUST cubrir todos los sitios de los e2e de qmd que suponen el lock libre (decisión del operador del 29-10-2026): la fase `reindex` de `qmd real (041)`, el bucle y el segundo tick de la prueba 13 y la fase 3 de la prueba 12, con el mismo comportamiento en todos (mismo plazo, mismo criterio de reintento, mismo reporte); el plan elige el mecanismo. Cada llamada manual a `heartbeatctl qmd-reindex` de los e2e MUST quedar clasificada en el plan: las que afirman el efecto de un reindex esperan al lock, y las que ya toleran el salto no se tocan.
- **FR-009**: El estado que `qmd real (041)` vuelca al fallar (`_embed_failure_state`) MUST incluir los procesos y descriptores que tienen abierto `.reindex.lock`, o decir qué herramienta de diagnóstico falta en la imagen, y las tres primeras líneas de `qmd-setup.err` (la primera línea del reemplazo de sqlite-vec de 042 queda al comienzo de ese archivo y la cola de 500 bytes que llega al log la empuja fuera). Cada sonda MUST tolerar su propia falla, de modo que ninguna convierta el rojo que reporta en otro.
- **FR-010**: Un oráculo del host, en el molde de `tests/qmd-embed-nightly.bats` (que ata el cuerpo de un test e2e a sus comprobaciones leyendo el archivo), MUST atar el cuerpo de la fase `reindex`, el de la prueba 13 y el de la fase 3 de la prueba 12 a FR-001 a FR-009 (cada uno a lo que le corresponde), nacer con su ROJO visto contra los cuerpos actuales (principio III: test-first) y llevar un catálogo de mutaciones que caiga entero en bash 5.x y en 3.2.
- **FR-011**: La corrección MUST demostrarse con una falla inyectada en un contenedor real (el lock retenido con un `flock` en segundo plano antes del reindex manual: ROJO sin el arreglo y VERDE con él, con una retención más corta y otra más larga que el debounce del vigilante) y con el DOCKER_E2E local en arm64 de `qmd real (016)`, `qmd real (041)` y las pruebas 12 y 13 en verde. Además, antes de abrir el PR MUST hacerse una corrida manual del workflow sobre la rama (COMPUERTA de push y de dispatch; decisión del operador): el job debe terminar en verde con la fase activa (`ok 16 qmd real (041)` ejecutado y no saltado) y con `e2e summary:` sin fallas, y quedar registrada con su identificador, su duración y su margen frente al tope; un rojo ajeno a esta feature se clasifica antes de seguir, como en 042. No se exigen tres corridas: ninguna cantidad de corridas demuestra una carrera de una en cinco, y eso lo hace la inyección.
- **FR-012**: La feature MUST NOT cambiar el producto: `git diff origin/main -- docker scripts modules setup.sh` MUST quedar vacío y `VERSION` MUST seguir igual (verificado contra `origin/main` a mano tras cualquier rebase). MUST llevar una entrada de CHANGELOG sin bump de `VERSION` (práctica de 025, 039, 041 y #113), el bloque de la feature en CLAUDE.md y, si el estado al fallar gana un encabezado que la checklist de upgrade nombra, `docs/qmd-upgrade-checklist.md` al día.
- **FR-013**: Si un reporte de FR-004 o de FR-009 muestra un lock que no se suelta o un descendiente que lo retiene, MUST aplicarse la política de 041 y 042: se registra en un issue aparte con la evidencia, y no se corrige en esta feature (el `flock -n` que se salta con rc 0 es una decisión de diseño del producto y se queda).

### Key Entities

- **`.reindex.lock`**: archivo de lock no bloqueante (`flock -n`, descriptor 9) que comparten el setup del primer arranque, el reindex manual, el del cron y el del vigilante de archivos; quien no lo obtiene se salta la vuelta con rc 0.
- **Reindex manual**: `heartbeatctl qmd-reindex`, el mismo comando que ejecuta la línea de cron; es lo que lanzan las pruebas.
- **Estado del índice** (`qmd-index.json`): lo que deja una corrida del reindex (`last_status`, `pending`, `runs` y el hash del vault); lo escribe `_qmd_reindex_locked` y solo cuando la corrida obtuvo el lock.
- **Estado al fallar** (`_embed_failure_state`): el volcado que `qmd real (041)` imprime cuando falla, con disco, veredicto del contenedor, extensión vectorial y salidas del reindex y de la búsqueda.
- **Oráculo del host de 041** (`tests/qmd-embed-nightly.bats`): las pruebas que leen el cuerpo del test e2e y exigen sus comprobaciones; el molde del oráculo de esta feature.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Con el lock retenido a propósito antes del reindex manual, durante 5 s y durante 20 s (la segunda más larga que el debounce del vigilante, de modo que el reindex de este también encuentra el lock tomado), cada sitio de FR-008 (la fase `reindex` de 041, el primer tick de la prueba 13 y la fase 3 de la prueba 12) pasa en un contenedor real; la misma inyección contra los cuerpos actuales los deja en rojo: con `already running` en la fase `reindex`, y por el archivo de estado o el log del motor aún ausentes en la prueba 12 y en la prueba 13.
- **SC-002**: Con el lock retenido más allá de un plazo corto sobrescrito por la variable de entorno, la fase falla poco después de vencer el plazo (no a los 600 s) y su reporte contiene el lock, la espera, los intentos y la salida del último; ningún reporte es un error de `jq` o de `grep`.
- **SC-003**: Con el lock libre la fase no agrega espera: hace un solo intento, y la prueba 16 sin su fase `setup` (que mide la compilación y no cambia) no tarda más de 5 s por encima de los 16 a 19 s que midieron las nocturnas del 25 al 28-10 (se decide en la corrida manual de CI, el mismo tipo de runner que las nocturnas; el DOCKER_E2E local en arm64 registra su valor como referencia, porque no hay una línea base local de ese tramo).
- **SC-004**: El oráculo del host falla contra los cuerpos actuales y pasa tras la corrección, y cada mutación del catálogo (FR-010) cae en bash 5.x y en 3.2, sin sobrevivientes.
- **SC-005**: La suite del host termina con 0 pruebas fallidas en bash 5.x y en 3.2, con el conteo esperado (la línea base medida en copia aislada, 1868 en la CI de `cd8b74f`, más las pruebas nuevas).
- **SC-006**: El DOCKER_E2E local en arm64 deja en verde `qmd real (016)`, `qmd real (041)` y las pruebas 12 y 13, con las ocho marcas de fase de 041 en orden. Una corrida manual del workflow sobre la rama, en el runner de CI (amd64) y antes del PR, también termina en verde, con `ok 16 qmd real (041)` ejecutado y no saltado y `e2e summary:` sin fallas, registrada con su identificador, su duración y su margen frente al tope de 45 minutos.
- **SC-007**: Las diez nocturnas siguientes al merge quedan registradas en un PR de documentos aparte, como hizo 042 con su T035: ninguna cae por el lock, y si alguna cae, su reporte nombra al dueño (o dice qué herramienta falta) y se clasifica. Diez noches sin falla no demuestran que la carrera desapareció: si la tasa siguiera en una de cada cinco, verlas todas limpias tendría una probabilidad de alrededor del 11 %, y si fuera de una de cada diez, de alrededor del 35 %. La prueba determinista es SC-001; esta es un registro razonable, no una demostración.
- **SC-008**: En una falla forzada por un lock retenido (la fase `reindex` de la prueba 16 con un plazo corto y el lock retenido más allá de él), el estado al fallar muestra al menos un proceso con su pid y su comando, o dice qué sonda no está disponible en la imagen.

## Assumptions

- Defaults declarados, reversibles en un paso: plazo de espera por el lock de 120 s, un reintento cada 2 s (el ritmo del bucle de la prueba 13), y, al vencer el plazo, la fase falla en rojo (un salto con motivo ocultaría un lock que no se suelta, que sería un hallazgo del producto). La variable de entorno que sobrescribe el plazo sigue la convención de `QMD_E2E_SETUP_DEADLINE_S`: segundos enteros de 1 a 3600, normalizados con `10#`.
- Todos los sitios de los e2e de qmd que afirman el efecto de un reindex manual quedan cubiertos (decisión del operador del 29-10-2026); las llamadas que ya toleran el salto (el cron y el vigilante) no se tocan.
- La base es `origin/main` = `cd8b74f` (los merges de #113 y #114 ya están). La línea base de CI de la suite del host es 1868 por brazo; la medida local se toma en copia aislada, en los dos bash y en secuencia, como en 041 y 042.
- El producto y su semántica de lock no cambian: el reindex que pierde el lock se salta con rc 0 a propósito. Las pruebas se adaptan a eso y no al revés.
- El dueño del lock en la noche roja es un proceso legítimo y transitorio (el vigilante) o el residuo de un descendiente del setup; si resultara un lock que nunca se suelta, el reporte de FR-004 y el volcado de FR-009 lo mostrarán y se aplica FR-013.
- La tasa medida (una de cinco noches para la fase; una de 28 corridas para la prueba 13) es una estimación gruesa, con muestras chicas.
- El workspace de los tests de qmd real usa la zona UTC, el debounce por defecto del vigilante (15 s) y el cron de reindex del 31 de febrero (`tests/docker-e2e-qmd.bats:645-666`).
- Hay que reconstruir las imágenes de prueba en el primer DOCKER_E2E local, porque T036 quitó sus etiquetas (el caché de build y los modelos de `~/.cache/agentic-qmd-e2e/models-041` se conservaron); el costo de ese rebuild no está medido.
- El PR #115 (cierre documental de 042, abierto el 29-10-2026) toca `CLAUDE.md` y dos `tasks.md`: un rebase al final es probable, y `VERSION` (0.29.0) no cambia.
- La corrida manual en CI de FR-011 pasa por COMPUERTA (push de la rama y dispatch, con la confirmación explícita del operador cada vez). El push de una rama sin PR no dispara `test.yml` ni `shellcheck.yml` (solo corren en `main` y en PR; registrado en 042), y el workflow `docker-e2e` serializa sus corridas con su propio grupo de concurrencia, sin cancelación.
- Esta feature no tiene bump de `VERSION` porque no toca código de runtime (precedente: 019, 025, 039, 041 y #113).

## Out of Scope

- Cambiar el producto: el `flock -n` que se salta con rc 0, el lock compartido o el cierre del descriptor 9 para los procesos hijos. Si el diagnóstico de FR-009 muestra un defecto, va a un issue aparte (FR-013).
- Excluir `.graph/` del vigilante (la opción T043 de 037) y cualquier otro cambio de `scripts/qmd_watch.sh`.
- Reabrir #107 y cambiar el interruptor `QMD_EMBED_DEFECT` (sigue vacío).
- La cobertura permanente del embed en arm64 dentro del nightly, el prefijo compilado compartido entre los tests 016 y 041, #111 (healthcheck local) y el tope de 30 minutos del job `tests` de `test.yml`.
- Medir la velocidad del embed o la duración de las demás fases de `qmd real (041)`.
- La segunda carrera de arranque de la prueba 13 (la aserción de `:483-484` y el comentario de `:394-396`): se declara en el Contexto y va a un issue aparte, que se propone con COMPUERTA (decisión del operador del 31-10-2026).
