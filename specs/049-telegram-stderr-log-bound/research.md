# Research: Log de stderr del canal de Telegram acotado y sin bucle de EPIPE

**Feature**: 049-telegram-stderr-log-bound | **Fecha**: 2026-11-23

Mediciones hechas en esta Mac: bun 1.3.12 (la imagen fija `BUN_VERSION=1.3.14`, `docker/Dockerfile:141`), Darwin 25.3.0 arm64. Las sondas viven en el scratchpad de la sesión y no se versionan. Lo que se mide en un contenedor real queda para el DOCKER_E2E de la feature (D8).

## Mediciones

### M1. Cómo informa bun una escritura a un stderr cerrado

Sonda: `bun t.ts 2>&1 >/dev/null | true`, es decir, stderr conectado a un pipe cuyo lector ya salió.

- `process.stderr.write('hello\n')` **no lanza**: devuelve `false`.
- El error llega **asíncrono**, como `uncaughtException` con `code=EPIPE` y la pila `write (unknown) / writeFast (internal:fs/streams:345:38) / … / processTicksAndRejections`. Es la misma forma de las tres líneas de pila del log de donna.
- Si se pasa un callback a `write`, lo recibe con `err.code === 'EPIPE'`.
- Si hay un listener `process.stderr.on('error', …)`, el error llega a ese listener (`code=EPIPE`, `syscall=write`) y **no** se convierte en `uncaughtException`: `n=0` contra `n=1` sin listener.
- El proceso no muere por SIGPIPE: sigue vivo al final de cada sonda.

**Consecuencia**: envolver la escritura original en un `try` no corta nada, porque el error no es síncrono. El corte tiene que escuchar el evento `error` del stream.

### M2. El bucle, reproducido con el parche v1 real

Sonda: el `STDERR_HOOK` actual, extraído del patcher, más el manejador del plugin del vendor copiado de `server.ts:85-87` (`process.stderr.write(\`telegram channel: uncaught exception: ${err}\n\`)`), más una escritura inicial y un `process.exit` a los 1,2 s.

- El `process.exit` **nunca se ejecutó**: el bucle no deja correr a los timers. El canal queda vivo pero sin atender, lo que coincide con un agente que no responde y no se reinicia.
- En unos 120 s, hasta que se detuvo a mano, el log creció a **1.282.285.620 bytes**, unos 10 MB/s.
- Cada vuelta deja el bloque `[ts] [uncaught] Error: EPIPE…`, que es la pila escrita por el manejador del parche directo al archivo, más `telegram channel: uncaught exception: Error: EPIPE: broken pipe, write`, que escribe el manejador del vendor a través de la captura. Es la firma del archivo de donna.

**Consecuencia**: el mecanismo del issue #139 queda confirmado, sin depender de qué cerró el pipe. A ese ritmo, 26,7 GB son unos 45 min de bucle.

### M3. El arreglo prototipo corta el bucle

Sonda: el prototipo v2 (listener de `error`, bandera de reenvío y aviso único) con el mismo manejador del vendor.

- El log terminó con 112 bytes: `first line`, una línea `[…] [stderr-closed] EPIPE - forwarding to stderr stopped, log only` y `later line`.
- El timer de 1,2 s corrió y el proceso salió normal.

### M4. Rotación: tope, costo y escritores concurrentes

- **Tope**: 100.000 escrituras de 48 bytes con umbral 100.000 dejaron `86.632 + 100.048 + 100.048 = 286.728` bytes en total. Cada generación supera el umbral por exactamente una escritura, y la línea más reciente quedó en el archivo actual.
- **Costo**: 100.000 escrituras tardaron 2.810 ms con v2 (un `statSync` por escritura) contra 2.888 ms con v1. La diferencia queda dentro del ruido.
- **Concurrencia**: un bucle de shell con 3.000 `printf >> log` en paralelo con la ráfaga terminó con rc 0 y **cero** líneas malformadas en las tres generaciones. Sus líneas cayeron en generaciones que después se descartaron, lo cual es correcto: la ráfaga escribió 4,8 MB.

### M5. Archivo heredado mucho mayor que el umbral

Sonda: un log de 50.009 bytes que termina en `TAILMARK`, con umbral 1.000, y una escritura nueva.

- `.1` quedó con exactamente 1.000 bytes, terminados en `TAILMARK`.
- El archivo actual quedó solo con la línea nueva (9 bytes).
- La lectura es posicionada: solo se leen los últimos `umbral` bytes, sin recorrer el archivo. Para el caso de donna eso significa leer 10 MB de 26 GB.

### M6. Quién más usa el archivo (lectura de código)

- `modules/stop-hook.sh.tpl:32` y `modules/askq-guard.sh.tpl:44` anexan a la misma ruta (`REPLY_GUARD_STDERR_LOG`), abriendo y cerrando el archivo en cada línea.
- `scripts/agentctl:1041` (`logs --stderr`) hace `tail` de la ruta.
- `scripts/agentctl:799` le pregunta al patcher sus marcadores con `--list-markers`, así que un marcador nuevo llega al doctor sin duplicar el literal (036).
- El parche se ancla antes de `const TOKEN =`, y los manejadores del vendor (`server.ts:82-87`) se registran después. Los del parche corren primero.

## Decisiones

### D1. Cortar el reenvío con un listener de `error` en `process.stderr`

- **Decisión**: el parche registra `process.stderr.on('error', …)`. Si el código indica un destino cerrado (`EPIPE`, `ERR_STREAM_DESTROYED`, `ERR_STREAM_WRITE_AFTER_END`, `EBADF`), apaga una bandera de reenvío y deja una sola línea de aviso. Con la bandera apagada, la escritura reemplazada anexa al archivo, no llama a la escritura original, devuelve `true` y, si recibió un callback, lo invoca en un microtask. Cualquier otro error del stream se registra en una línea `[stderr-error]` y no corta el reenvío.
- **Por qué**: es la única vía que ve el error en bun (M1). Además evita que el error llegue a ser `uncaughtException`, de modo que el manejador del vendor ni siquiera corre: el bucle no arranca.
- **También**: se conserva un `try` alrededor de la escritura original para un runtime que lance de forma síncrona. Un error síncrono de destino cerrado corta igual; cualquier otro se relanza, como en v1.
- **Alternativas descartadas**:
  - Solo un `try`/`catch`: no ve el error (M1).
  - Detectar EPIPE dentro del manejador `uncaughtException` del parche: no distingue un EPIPE de stderr de uno de un socket, y deja correr una vuelta del manejador del vendor.
  - Reintentar después de un tiempo: un stderr cerrado no se reabre en la vida del proceso.

### D2. La rotación la hace el propio parche, al escribir

- **Decisión**: antes de cada anexo, `statSync` del archivo. Si mide al menos el umbral, se rota:
  1. `rename .1 → .2`, que reemplaza la `.2` anterior;
  2. si el archivo mide menos de dos umbrales, `rename actual → .1`;
  3. si mide dos umbrales o más, se leen sus últimos `umbral` bytes a `.1.tmp`, después `rename .1.tmp → .1` y `unlink` del actual.

  Toda falla se traga. La escritura original a stderr ocurre igual.
- **Por qué**: no suma procesos, cron ni servicios. El costo medido es despreciable (M4) y respeta FR-003 y FR-004 (M4, M5). Los anexos con `O_APPEND` por ruta, del plugin o de los hooks, sobreviven al `rename` sin corromper líneas.
- **Alternativas descartadas**:
  - Rotar desde el heartbeat o el cron: el bucle de M2 escribe 10 MB/s y un cron de minutos dejaría pasar cientos de MB.
  - Recortar solo al arrancar: no acota un proceso que vive semanas.
  - Comprimir generaciones, como `runs.jsonl`: suma código en el plugin para ahorrar unos 20 MB.

### D3. Umbral ajustable por `TELEGRAM_STDERR_LOG_MAX_BYTES`

- **Decisión**: variable del `.env` del workspace, leída por el parche con `process.env`. Un entero positivo se usa tal cual; cualquier otro valor da 10.485.760.
- **Por qué**: es la perilla de `TELEGRAM_TYPING_MAX_MS` (CLAUDE.md, *Telegram plugin patch*). Llega al proceso del canal por el `env_file` de compose y sobrevive a `--regenerate`, porque el `.env` no es un archivo derivado.
- **Alternativa descartada**: un campo en `agent.yml`. Exigiría render, backfill y esquema para un valor que casi nadie va a tocar. Se puede promover después, como hizo 036 con `CHANNEL_HEALTH_TIMEOUT`.

### D4. Grupo stderr en v2, con cascada desde v1 y gemela congelada

- **Decisión**: `MARKER_STDERR` pasa a `stderr-capture patch v2` y se agrega `MARKER_STDERR_V1`. `STDERR_HOOK_V1` es una copia congelada, byte a byte, del literal de hoy. `upgrade_stderr_v1_to_v2` hace un solo `str.replace` y es todo o nada con la regla `work.count(old) != 1`. `apply_stderr` instala v2 en un archivo prístino y no toca un archivo que tenga v1 o v2. La cascada corre en `main()` justo antes de `apply_stderr`. `ALL_MARKERS` lista el marcador v2.
- **Por qué**: es el molde probado de typing (cinco saltos) y de voz (033 y 034). Un plugin con v1 editada a mano queda en v1 y funcional, con un WARN (FR-012).
- **Oráculo**: un fixture dorado `tests/fixtures/telegram-server-patched-v034.ts`, generado UNA vez con el patcher de `main` (`9a0b93e`) sobre `tests/fixtures/telegram-server-pristine.ts`. Es exactamente el estado de los plugins de la flota hoy. Tres comprobaciones:
  - `nuevo(dorado) == nuevo(prístino)` (FR-011);
  - `nuevo(prístino)` con v2 reemplazada por v1 `== dorado`, que prueba que nada fuera del grupo cambió (FR-013);
  - `STDERR_HOOK_V1` está contenido en el dorado, que protege la gemela de un error de copia (lección 033: un oráculo tautológico no ve ese error).
- **Dorado generado (23-11-2026, T002)**: `tests/fixtures/telegram-server-patched-v034.ts`, 32.882 bytes, sha256 `96263610ff43119497655a5ca8ef9ec7d4901affc171fd1183fa3dd5d45b8ac3`. Viene de `git show 9a0b93e:docker/scripts/apply_telegram_typing_patch.py` aplicado a una copia de `tests/fixtures/telegram-server-pristine.ts` (sha256 `c587aad8…9a07f`). Tiene los siete grupos: typing v6, offset, pending, stderr v1, primary, askq y voice v3.

### D4b. La gemela v1 es la forma en disco, no la constante (medido en T002)

- **Hallazgo**: el `apply_stderr` de `main` pasa `"\n" + STDERR_HOOK + r"\1"` como **plantilla** de `re.subn`, y `re` convierte cada `\n` de dos caracteres en un salto de línea real. En los plugins de la flota, las líneas `[uncaught]` y `[unhandled]` del bloque v1 tienen un salto real dentro del template literal (líneas 21 y 22 del dorado). Es la misma clase de defecto de 032 (D14 de 034). En JS es inocuo: el template literal admite el salto y la salida es la misma.
- **Medido**: sobre el dorado, `src.count(STDERR_HOOK)` da **0** y `src.count(STDERR_HOOK.replace("\\n", "\n"))` da **1**.
- **Decisión**: `STDERR_HOOK_V1` se define con la forma en disco, con saltos reales en esas dos líneas. Una copia literal de la constante habría dejado a los tres agentes en v1 para siempre, sin ningún WARN que lo explicara: el upgrade solo vería "bloque no encontrado". S4 (la gemela está contenida en el dorado) es el oráculo que atrapa ese error. El bloque v2 se inserta con un reemplazo `lambda`, así que queda tal cual en el archivo.

### D5. Regla de escapes de Python (034, D14)

- **Decisión**: cada barra invertida que debe llegar al TS va doblada en el literal Python. El hook nuevo solo tiene `\n` dentro de template literals.
- **Oráculos**: un `grep -F` de cada `\n` literal esperado en la salida parcheada, y cero bytes de control en esa salida (G15 y G16 de 034).
- **Por qué**: un `\n` sin doblar se convierte en un salto de línea real dentro de un template literal. Para el TS es válido y para bun también, así que el error no se vería en ninguna parte.

### D6. Pruebas de comportamiento bajo bun en el host, sin cambiar la CI

- **Decisión**: una suite nueva, `tests/telegram-stderr-hook.bats`, extrae el hook v2 del patcher y lo corre con bun contra un log en un directorio temporal. La ruta de producción se sustituye en el texto extraído; el producto no gana una variable de ruta. Cubre el bucle con el manejador del vendor (ROJO con v1, VERDE con v2), el aviso único, el tope, el archivo heredado, la escritura sana byte a byte y el escritor concurrente.
- **Sin bun en el host**: la suite se salta con un motivo explícito. Los runners de la CI no traen bun, así que en la CI se ejecutan solo las pruebas del patcher y del doctor. El comportamiento se prueba en el gate local, en ambos bash, y en el DOCKER_E2E (D8), con el bun 1.3.14 de la imagen.
- **Alternativa descartada por ahora**: instalar un bun fijado en los dos brazos de la CI. Sumaría una dependencia a la CI y minutos al brazo macOS, que ya va con 15 min de margen (048). Si el operador quiere ver estas pruebas en cada PR, se agrega en un PR propio.

### D7. Aviso de tamaño en el doctor, leído desde el host

- **Decisión**: `cmd_doctor`, en modo docker, lee el tamaño de `<workspace>/scripts/heartbeat/logs/telegram-mcp-stderr.log` por el bind mount, con un helper portátil `_file_size` (`stat -c %s` primero y `stat -f %z` después, el orden de `_file_mode`, lección 021). El doctor muestra:
  - PASS informativo hasta 100 MiB, con el tamaño en MiB;
  - WARN sobre 100 MiB, con la acción sugerida;
  - nada si el archivo no existe.

  Nunca abre el contenido. La línea va junto a `_doctor_check_plugin_failures "$WORKSPACE"`, no dentro del bloque de parches de Telegram, que corre antes de asignar `WORKSPACE` y solo cuando el notificador del heartbeat es `telegram` (corrección del análisis del 23-11-2026; detalle en `contracts/doctor-stderr-size.md` §D3).
- **Por qué**: `_doctor_check_plugin_failures` ya lee estado del workspace desde el host, sin `docker exec`. 100 MiB solo se alcanzan si la rotación no está activa: más de tres veces el tope total de FR-003.

### D8. DOCKER_E2E auto-sembrado

- **Decisión**: un archivo nuevo, `tests/docker-e2e-stderr-log.bats`, en el molde de `docker-e2e-voice.bats`:
  - copia el fixture dorado al path del caché del plugin;
  - corre el patcher de la imagen;
  - comprueba v2 y que v1 no quedó;
  - corre con el bun de la imagen una versión reducida de las pruebas de comportamiento (bucle cortado y tope), con stderr a un pipe cerrado;
  - corre el patcher dos veces y comprueba la línea `no changes … all patch groups already present`.
- **Por qué**: el patcher está horneado en la imagen (FR-016), y bun 1.3.14 sobre musl es lo que corre en la flota.

### D9. Versión

`VERSION` 0.34.0 → 0.35.0 (MINOR, por un cambio de comportamiento en código horneado; precedentes 029, 033 y 034), con entrada en CHANGELOG. Hay que verificar `origin/main:VERSION` a mano antes del bump (lección 023).

## Riesgos

- **Error de sintaxis en el TS del hook**: el canal entra en flap al arrancar. Mitigaciones: las pruebas bajo bun ejecutan el texto exacto del hook, el DOCKER_E2E carga el `server.ts` parcheado con `bun build --no-bundle` o una carga equivalente, y el despliegue empieza por cbum, como canario.
- **Que bun 1.3.14 en musl informe distinto que 1.3.12 en macOS**: lo comprueba el DOCKER_E2E antes del PR.
- **Rollback a una imagen anterior** (corregido por la revisión independiente, 23-11-2026): el patcher viejo busca solo el marcador v1. Sobre un archivo v2 **apila** un bloque v1 encima, porque el ancla `const TOKEN =` sigue ahí. Mientras el agente queda en la imagen vieja, las dos capturas conviven: el log no tiene tope, cada línea se registra dos veces y el doctor de US4 lo avisa. Al volver a la imagen nueva, la cascada quita el v1 apilado y el archivo queda idéntico a una instalación fresca (S10). Sin esa rama, lo habría convertido en un segundo v2 y cada línea quedaría duplicada para siempre.
