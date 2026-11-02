# Research (Fase 0): los tests e2e de qmd dejan de caer por la carrera del `.reindex.lock`

**Feature**: `043-e2e-lock-race-hardening` | **Fecha**: 31-10-2026 | **Spec**: [spec.md](spec.md)

Todo lo de esta página es una medición (comando o corrida citados), una lectura de código (archivo y línea de `cd8b74f`) o una decisión con su razón. Lo inferido va marcado. Los números de línea son los de `cd8b74f`, antes de la implementación.

## Mediciones

### M1. Herramientas de la imagen para listar quién tiene un archivo abierto

Contenedor desechable `alpine:3.24.1` (arm64, busybox 1.37.0), con `apk add flock` como hace `docker/Dockerfile:45`, probado como usuario 1000 (script `probe_lock.sh` del scratchpad, no versionado).

- `busybox --list` trae `ps`, `fuser`, `lsof`, `timeout`, `nohup`, `setsid`, `readlink`, `pgrep` y `flock`; en el `PATH` del usuario 1000, `ps`, `fuser`, `lsof`, `timeout`, `nohup`, `setsid` y `pgrep` resuelven a `/bin` o `/usr/bin` (applets de busybox) y `flock` a `/usr/bin/flock`.
- `apk add flock` deja `/usr/bin/flock` de **util-linux 2.42.3** (reemplaza al applet de busybox). La lista de paquetes de la imagen (`docker/Dockerfile:27-47`) tiene `flock`, `busybox-extras` e `inotify-tools`, y **no** tiene `procps`, `lsof` ni `psmisc`: `ps` y `fuser` son los de busybox.
- `ps w` (busybox) imprime `PID USER TIME COMMAND`; `fuser /ruta` imprime los pid y sale con 0 sobre procesos propios.
- `/proc/<pid>/fd` es legible por el usuario 1000 para sus propios procesos: `readlink` y `ls -l` muestran `9 -> /ruta/del/lock`. Para un proceso de root (`/proc/1/fd`) da `Permission denied`: la sonda debe tolerarlo.
- `/proc/locks` salió vacío en esta VM (no sirve como fuente).

### M2. Retener el lock desde fuera del producto, y cómo se suelta

Mismo contenedor, usuario 1000, archivo `/tmp/q/.reindex.lock`:

- **A.** `docker exec -u 1000:1000 C sh -c 'nohup sh -c "exec 9>LOCK; flock 9; sleep 14" >/dev/null 2>&1 &'`: el exec vuelve en 0 s con rc 0 y el retenedor sobrevive. Mientras vive, el idioma del producto (`( if ! flock -n 9; then echo "already running"; exit 91; fi; echo ran ) 9>LOCK`) imprime `already running` y sale con 91; pasados los 14 s imprime `ran` con rc 0. El retenedor visible en `ps w` era `sleep 14` (busybox ash reemplaza el `sh -c` por su último comando), que conserva el descriptor 9.
- **B.** `docker exec -d` (desacoplado) se comporta igual: vuelve en 0 s, retiene 8 s y el lock queda libre después.
- **C.** Un descendiente que hereda el descriptor 9 **sigue reteniendo el lock cuando el subshell que lo tomó ya terminó**: el subshell salió con rc 0 y el intento siguiente vio `already running (held by the orphan)`; el escaneo de `/proc/*/fd` lo nombró (`pid 199 fd 9 -> LOCK cmd=[sleep 6 ]`). Es el mecanismo del segundo candidato del #112, reproducido; no prueba que haya sido el dueño de esa noche.

### M3. Costo de un `docker exec`

Tres `docker exec ... true` seguidos midieron menos de 1 s cada uno (resolución de segundos), así que un reintento por `exec` cada 2 s no agrega carga apreciable.

### M4. Por dónde sale el aviso del lock y qué devuelve el reindex manual

- `_qmd_log` escribe a **stderr** (`scripts/lib/qmd_index.sh:45`: `echo "[qmd] $*" >&2`). El reindex que pierde el lock escribe `[qmd] reindex: already running — skip` y la función devuelve 0 (`:561-566`); `cmd_qmd_reindex` de `heartbeatctl` (`:1102-1130`) devuelve ese 0. **El salto solo se distingue por el texto**, no por el estado de salida.
- La fase 041 ya captura stdout y stderr juntos en `/tmp/qmd-reindex.out` dentro del contenedor y los reimprime (`tests/docker-e2e-qmd.bats:875`); con `run` de bats, `$output` también junta los dos flujos. El bucle de la prueba 13 hoy descarta la salida (`>/dev/null 2>&1`, `:495`).

### M5. El estado que deja el reindex y cómo se comprueba su efecto

- `qmd-index.json` lo escribe `qmd_write_state` (`qmd_index.sh:414-447`) con `hash`, `last_run`, `last_status`, `runs`, `collection_layout`, `migration` y, si se conoce, `pending`. `last_status` toma `indexed` (`:640`, `:646`), `skipped` (`:691`), `partial` (`:659`), `stalled` (`:651`) o `error` (`:386`, `:391`, `:635`, `:710`).
- `skipped` solo se escribe cuando el hash del vault es el último registrado **y** `pending` es 0 (`:689-693`): es decir, una corrida que encontró el vault ya indexado por completo.
- `vault_hash` (`scripts/lib/backup_vault.sh:97-110`) es un sha256 sobre los nombres y el contenido de los archivos `.md` del vault, así que los JSON de `.graph/` no lo mueven. Por eso «la página nueva quedó indexada» se comprueba sin llamar a qmd: el `hash` del estado es igual al `vault_hash` del vault de ahora, `pending` es 0 y el estado es `indexed` o `skipped`.
- `vault_hash` usa constructos de bash (`read -d ''`, sustitución de procesos): se invoca dentro del contenedor con `bash -lc '. /opt/agent-admin/scripts/lib/qmd_index.sh; vault_hash ...'`, como ya hacen otras fases (`tests/docker-e2e-qmd.bats:896`).

### M6. Los cuatro sitios, sus envoltorios de exec y qué afirman

| Sitio | Líneas | Envoltorio | Qué hace hoy |
| --- | --- | --- | --- |
| Fase `reindex` de `qmd real (041)` | `docker-e2e-qmd.bats:861-887` | `inc` (`:804`) | escribe `gatos.md`, un solo reindex con `timeout -k 10 600`, afirma `last_status` con `grep -qE 'ok\|indexed'` y `pending` 0 |
| Prueba 13, bucle | `:493-499` | `in_container` (`:479`) | reintenta 45 s, pero `calls=$(... cat engine-calls.log 2>/dev/null)` (`:496`) sale con 1 si el archivo no existe y aborta bajo el errexit de bats |
| Prueba 13, segundo tick | `:522-527` | `in_container` | `[ "$status" -eq 0 ]` y que el conteo de `collection` no cambie: pasa en vacío si pierde el lock |
| Fase 3 de la prueba 12 | `:264-276` | `in_container` (`:189`) | un reindex, `[ "$status" -eq 0 ]`, `last_status` en `indexed` o `skipped` y `runs` >= 1 sobre `qmd-index.json`, que antes de ese reindex no existe |

### M7. Cuánto duran hoy las fases posteriores a `setup` (umbral de SC-003)

La prueba 16 menos su fase `setup`: 18,0 s (25-10), 16,0 s (26-10), 18,5 s (27-10), 16,4 s (28-10) y 16,1 s (30-10, run 41046834462: 395,2 s menos 379,1 s). Rango medido de 16,0 a 18,5 s; con 5 s de holgura, el umbral de SC-003 es **24 s**. En esa corrida del 30-10 la fase `reindex` duró 2,7 s. Fuentes: Registro de `specs/042-qmd-sqlite-vec-x64/tasks.md` y el log del run 41046834462.

### M8. Línea base de la suite del host

1868 pruebas por brazo en CI sobre `cd8b74f`: run 40988591966 (ubuntu bash 5.2.21 con 49 saltadas y macOS bash 3.2.57 con 56) y run 40991040419 (el PR #115: 51 y 58 saltadas, las mismas 1868). Las saltadas difieren por evento y por plataforma y no cambian el plan. La línea base local se mide en copia aislada, en los dos bash y en secuencia (tarea de `tasks.md`).

### M9. Quién lee el cuerpo del e2e de qmd y qué enmiendas le tocan

- `tests/qmd-embed-nightly.bats` (`E2E_FILE`, `:37`): **P1** (`:855-935`) exige en la fase `reindex` el ancla `heartbeatctl qmd-reindex`, `grep -qE 'ok|indexed'`, `[ "$output" = "0" ]`, `timeout -k 10 600`, `qmd-reindex did not finish`, `SECONDS - t0` y una línea con `false` sangrada con cuatro espacios tras el reporte: **se enmienda** (esos textos pasan al ayudante o se reemplazan). **P2** (`:937-985`) extrae `teardown`, `_embed_failure_state` y `_qmd_real_ws`: no se rompe al agregar sondas, pero su regla «cada sonda tolera su falla» pide `|| true` en las líneas nuevas. **G1** lee `_qmd_real_ws` (sin cambio). **G3** (`:635-649`) exige que la checklist cite un encabezado que el e2e imprime, `# --- state at the failure`: **se conserva**.
- **K1 a K4** (`:221-283`) corren la prueba 041 dentro de un bats anidado con `docker` y `curl` falsos y cargan **todo** el archivo e2e: un `load` nuevo debe resolverse desde `tests/`.
- `tests/qmd-invocation.bats:5` solo lo nombra en un comentario.
- `docs/qmd-upgrade-checklist.md:136` cita el encabezado `# --- state at the failure`; el bloque nuevo del dueño del lock se menciona ahí sin tocar esa cita.

### M10. Cómo se arma el oráculo que lee un cuerpo

P1 y P2 extraen texto con `awk '/^@test "..."/{f=1; next} /^@test /{f=0} f{print}'` (y, para funciones, `awk '/^nombre\(\) \{/{f=1} f{print} f && /^\}/{exit}'`), quitan los comentarios y hacen afirmaciones por subcadena con `_has` y `_lacks` (`case`, sin tubería: la regla de `qmd-embed-nightly.bats:20-23`). Los segmentos por fase se recortan entre dos marcas `_embed_phase`. El oráculo nuevo repite ese molde para los cuatro sitios y la sonda del estado al fallar, y suma pruebas de **comportamiento** del ayudante (decisión D1).

### M11. Qué construye bash 3.2 y qué no, para un ayudante cargable en el host

Reglas que el repositorio ya paga (CLAUDE.md, gotchas, y `qmd-embed-nightly.bats:17-26`): sin `mapfile`, sin arreglos asociativos, sin `${v,,}`, sin `local -n`, sin `|&`; las aserciones intermedias van como `[ ]`, `grep -q` o `if cmd; then false; fi` (en bash 3.2 un `[[ ]]` intermedio es letra muerta y un `! cmd` lo es en los dos); un valor con cero a la izquierda es octal para `$(( ))` salvo que se normalice con `10#` (como en `docker-e2e-qmd.bats:825-829`); `local x=$(cmd)` enmascara el estado de `cmd`; `run` de bats puede usarse dentro de una función llamada desde una prueba.

### M12. Un retenedor disparado por un archivo marcador

Mismo método (script `probe_marker.sh` del scratchpad): `sleep 0.05` (fraccionario) funciona en busybox; un retenedor lanzado con `docker exec -d` que sondea cada 50 ms la aparición de un archivo y entonces toma `flock 9` (bloqueante) y duerme H s **ya tenía el lock en el `exec` siguiente al que creó el marcador** (el idioma del producto vio `already running`, rc 91) y lo soltó a los H s; un `flock` bloqueante lanzado mientras otro proceso retiene el lock se encola y lo toma cuando este lo suelta (su archivo apareció a los 4,5 s y no a los 1,5 s).

## Decisiones

### D1. El mecanismo: un ayudante compartido con pruebas de comportamiento en el host (decisión del operador, 31-10-2026)

**Decisión**: un archivo nuevo `tests/helper-qmd-e2e.bash`, que `tests/docker-e2e-qmd.bats` carga con `load helper-qmd-e2e`, con tres funciones públicas (`qmd_e2e_reindex_wait`, `qmd_e2e_reindex_effect` y la sonda del dueño) y dos costuras de prueba (`_qmd_e2e_now`, `_qmd_e2e_sleep`). Un archivo de pruebas nuevo, `tests/qmd-e2e-lock.bats`, lo ejercita en el host con una función de exec falsa y un reloj falso, y además lee los cuerpos de los sitios (molde de P1 y P2).
**Razón**: son cuatro sitios con tres envoltorios de exec (M6); un oráculo que solo lee texto deja vivos los mutantes de aritmética (cadencia, plazo, normalización), que es lo que pasó en 042 con 30 de 35 mutantes contra el oráculo en que se escribieron. El host puede ejercitar la lógica real sin Docker (principio III).
**Alternativas**: (a) código en cada sitio y solo oráculo de lectura: cuatro copias que se desalinean y mutantes de aritmética vivos; (b) un script POSIX dentro del contenedor, como `vec0-libc.sh`: hay que copiarlo a tres workspaces, el reporte tendría que salir por fd 3 desde fuera de todos modos, y el mismo script correría en dash, ash y bash en modo sh.

### D2. La orden de cada intento no cambia

**Decisión**: cada intento ejecuta, a través del exec del sitio, la misma orden que usa hoy la fase 041: `sh -c 'timeout -k 10 600 /usr/local/bin/heartbeatctl qmd-reindex > /tmp/qmd-reindex.out 2>&1; rc=$?; cat /tmp/qmd-reindex.out; exit $rc'`. El archivo se reescribe en cada intento (`>`) y su salida se reimprime, así que la salida de un intento no se confunde con la anterior.
**Razón**: conserva el tope de 600 s con la semántica de busybox medida en 041 (TERM y luego KILL, rc 143 y 137, nunca 124), el archivo que lee `_embed_failure_state` (`/tmp/qmd-reindex.out`) y la captura de stdout y stderr (M4). Los sitios con el motor falso (pruebas 12 y 13) ganan el mismo tope, inocuo para ellos. Esas dos pruebas se construyen sobre `alpine:3.20` (BusyBox 1.36.1) y no sobre 3.24, así que la revisión independiente (T033, H1) puso en duda que su `timeout` aceptara `-k`. Medido el 01-11-2026 en contenedores desechables: el `timeout` de BusyBox 1.36.1 lo acepta (`Usage: timeout [-s SIG] [-k KILL_SECS] SECS PROG ARGS`), `timeout -k 1 2 true` sale con 0 y la orden completa del ayudante, con un `heartbeatctl` falso, sale con 0 y su salida en las dos bases. Para las pruebas 12 y 13 la orden sí cambia respecto de `cd8b74f`: su llamada pelada pasa a llevar el tope y el archivo de salida.

### D3. El salto se detecta por el texto, no por el estado de salida

**Decisión**: un intento «perdió el lock» si y solo si su salida contiene `already running`. Un rc 124, 137 o 143 es un intento que excedió su tope y no se reintenta; cualquier otro resultado (rc 0 con o sin estado malo, rc distinto de 0, un `docker compose exec` que falla sin salida) es un reindex que corrió o falló por otra causa y vuelve al sitio sin reintento.
**Razón**: el producto devuelve 0 al perder el lock (M4); reintentar solo por el texto garantiza que ninguna otra falla se esconda (FR-001, principio IV).
**Guardia contra deriva**: una prueba del host compara la cadena del ayudante con la del producto (`scripts/lib/qmd_index.sh`, la línea `reindex: already running`); si alguien cambia el texto del producto, el reintento dejaría de dispararse sin que nada lo avise.

### D4. Plazo y cadencia

**Decisión**: plazo de espera de 120 s, reintento cada 2 s fijo (el ritmo del bucle de la prueba 13); el plazo se sobrescribe con `QMD_E2E_REINDEX_LOCK_WAIT_S`, en segundos enteros de 1 a 3600, normalizado como `QMD_E2E_SETUP_DEADLINE_S` (`''`, no numérico o de más de cuatro dígitos dan 120; `10#` evita el octal; fuera de 1 a 3600 da 120). La cadencia no se sobrescribe: las pruebas del host usan el `sleep` falso. La espera se mide con `_qmd_e2e_now` (por defecto `date +%s`); el intento que encuentra el lock ocupado con `transcurrido >= plazo` vence.
**Razón**: son los defaults declarados del spec; una sola variable alcanza para ejercitar el vencimiento en segundos. El peor caso de la fase 041 es 120 s de espera más un reindex acotado a 600 s: 12 minutos más que hoy contra un tope de 45 y jobs de 17 a 27 minutos (FR-005). Con el ayudante en cuatro sitios hay un segundo peor caso, que no se suma al primero en una misma corrida: un dueño que no suelta el lock hace esperar 120 s a cada prueba, que termina al vencer el plazo (unos 6 minutos entre las pruebas 12, 13 y 16). Con la noche más lenta medida (26 min 59 s, la del 31-10-2026, run 41194270915), los dos caben en 45 (precisión del análisis y de T001 del 31-10-2026).

### D5. La afirmación es sobre el efecto

**Decisión**: `qmd_e2e_reindex_effect` (se usa en la fase 041) pide, dentro del contenedor, que `qmd-index.json` exista, que `last_status` sea `indexed` o `skipped`, que `pending` sea 0 y que `hash` sea igual al `vault_hash` del vault de ahora. Si falla, el reporte nombra la condición (archivo ausente, estado, `pending`, o los dos hashes). Las fases 12 y 13 conservan sus afirmaciones propias, porque con el motor falso las comprobaciones de estado y de llamadas ya son las del efecto; solo ganan la garantía de que el reindex corrió.
**Razón**: acepta que el reindex del vigilante se adelantara (deja `skipped` con el hash al día) y sigue rechazando `error`, `partial`, `stalled`, un `pending` distinto de 0, un hash viejo y el archivo ausente (FR-002). No llama a qmd.

### D6. El dueño del lock se nombra en tres momentos

**Decisión**: una sonda de POSIX sh que recorre `/proc/*/fd` con `readlink` y lista `pid`, `fd` y `cmdline` de quien tiene abierto `${QMD_CACHE_HOME:-$HOME/.cache/qmd}/.reindex.lock`, tolerando los procesos que no puede leer, y que dice `none found` o `lock file absent` cuando corresponde. Se ejecuta (1) una vez en la primera contención de cada espera, impresa como comentario TAP, de modo que **una corrida verde que tuvo contención también deja escrito quién la causó**; (2) al vencer el plazo, dentro del reporte; y (3) en `_embed_failure_state`, junto con las tres primeras líneas de `qmd-setup.err`. No toma el lock ni usa `flock -n` para probarlo.
**Razón**: diagnosticar solo al fallar deja sin evidencia el caso más común tras la corrección, el reintento que sí tuvo éxito; así la pregunta abierta del #112 se contesta en la primera contención, no en la primera falla. `ps w` y `fuser` existen (M1) pero `readlink` sobre `/proc` es lo medido (M2) y da el descriptor y el comando.

### D7. La inyección de falla es evidencia local y no se versiona (decisión del operador, 31-10-2026)

**Decisión**: el retenedor (M2) y la herramienta que lo lanza en el momento justo quedan en el scratchpad; sus resultados (ROJO sin el arreglo y VERDE con él, con 5 s y 20 s) van al Registro de `tasks.md`. El nightly sigue en 49 pruebas y con la misma duración.
**Razón**: el camino sin contención corre cada noche y el de contención lo ejercitan las pruebas del host (D1); una prueba e2e permanente agregaría cerca de 1,5 minutos por noche y otro posible flake a un camino que el host ya demuestra.
**Alternativa**: una prueba e2e con el motor falso que retenga el lock 5 s y 20 s antes del reindex manual (el nightly pasaría a 50 pruebas).

### D8. Cómo se dispara la inyección sin carrera propia

**Decisión**: el retenedor espera **dentro del contenedor** a un archivo marcador que el propio test escribe justo antes de su reindex manual, y entonces toma el lock con un `flock` bloqueante y lo retiene H segundos: `gatos.md` en la fase 041 y `cron-note.md` en la fase 3 de la prueba 12. En la prueba 13 no hay marcador: el retenedor se lanza apenas existe el contenedor del test y el primer tick llega cerca de 1 s después. Se lanza con `docker exec -d` y sondea cada 50 ms. El mismo disparo se usa contra el cuerpo actual (ROJO) y contra el nuevo (VERDE).
**Razón**: M12 midió que un retenedor así ya tiene el lock en el `exec` siguiente al que crea el marcador, y que un `flock` bloqueante lanzado mientras otro proceso retiene el lock se encola y lo toma al soltarse. Una retención que empezara después de que el test lanzó su reindex no probaría nada. Cada corrida verifica que el retenedor tomó el lock antes del primer intento (si no, es inconcluyente y se repite).

### D9. Enmiendas a P1 y alcance de las pruebas existentes

**Decisión**: P1 pasa a exigir en la fase `reindex` la llamada a `qmd_e2e_reindex_wait` y a `qmd_e2e_reindex_effect`, la ausencia de `grep -qE 'ok|indexed'` y la rama del tope de 600 s (rc 3 del ayudante) con su reporte y su `false` (el tope mismo vive en la orden del ayudante y lo guarda L1, que compara la orden entera del intento: I13, agregado en el análisis del 31-10-2026); el resto de P1 (las ocho marcas, el orden, las anclas de las otras fases) queda igual. P2 y G3 no cambian de contenido: la sonda nueva cumple su regla de `|| true` y el encabezado citado se conserva. K1 a K4 no cambian.

### D10. Sin prueba e2e nueva, sin producto, sin VERSION

**Decisión**: ninguna prueba e2e nueva (el resumen sigue en `total=49`), `git diff origin/main -- docker scripts modules setup.sh` vacío, `VERSION` en 0.29.0 y una entrada de CHANGELOG (práctica de 025, 039, 041 y #113), el bloque de la feature en CLAUDE.md y una frase en `docs/qmd-upgrade-checklist.md` sobre el bloque del dueño del lock.

### D11. La prueba 13 conserva su bucle acotado

**Decisión**: el bucle de 45 s se mantiene, pero cada vuelta llama al ayudante (con el retorno en `rc1` y un `false` ante el retorno 1 o 3) y lee el log tolerando su ausencia (`|| true`); el volcado de logs de `:500-503`, que solo cubría la salida del bucle, se retira y lo reemplaza un bloque de `teardown` que vuelca los logs del contenedor ante cualquier falla de la prueba. El segundo tick usa el ayudante y exige su retorno 0 (en `rc2`) y estado 0 antes de comparar conteos: un intento que perdió el lock también sale con estado 0, porque el producto devuelve 0, así que ni el estado ni `REINDEX_ATTEMPTS` prueban que el tick corrió (corrección del análisis del 31-10-2026; la primera redacción pedía `REINDEX_ATTEMPTS` >= 1, que se cumple siempre).
**Razón**: diff mínimo sobre una prueba que hoy pasa casi siempre; la garantía de que el tick corrió la da el ayudante.

## Lo que sigue sin saberse

1. **Quién tenía el lock el 29-10.** La corrección no lo necesita; el ayudante lo anotará en la primera contención que vea (D6).
2. **Si el vigilante se adelanta en la práctica.** Es una inferencia de lectura (M5). `qmd_watch.sh:51-60` dispara un solo reindex unos 15 s después del último evento, sin reintento, así que con el lock retenido 20 s ese reindex también pierde: la inyección de SC-001 no puede confirmarlo ni refutarlo (corrección del análisis del 31-10-2026; la primera redacción decía lo contrario). Por decisión del operador no se busca evidencia en contenedor: X2 prueba en el host que la afirmación del efecto acepta `skipped`, y D5 acepta el caso de todos modos.
3. **Cuánto cuesta reconstruir las imágenes de prueba** en el primer DOCKER_E2E local (T036 quitó sus etiquetas el 29-10-2026; el caché de build se conservó).
4. **Cuánto dura cada corrida de inyección contra la fase 041**: es una corrida completa de `qmd real (041)` (de 8 a 10 minutos en este Mac, con la compilación de llama.cpp dentro del setup); cuatro corridas (un ROJO de 20 s, dos VERDES de 5 s y 20 s y el vencimiento con el lock retenido 600 s, que el análisis agregó para SC-008) son unos 40 minutos de Docker.
5. **Con qué frecuencia la segunda carrera de arranque de la prueba 13 hace caer `:483-484`.** Por lectura de `qmd_index.sh:463-540`, el setup de arranque de esa prueba refresca el índice bajo el lock y escribe `.qmd-setup-ok`, y la aserción de `:483-484` pasa solo si se evalúa antes; no está medido. Queda fuera de esta feature y va a un issue aparte (decisión del operador del 31-10-2026).
