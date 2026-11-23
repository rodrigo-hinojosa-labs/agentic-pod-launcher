# Contrato: captura de stderr v2 (código que corre dentro del plugin)

**Alcance**: el texto que el patcher inserta en `server.ts` antes de `const TOKEN =`. Corre como `agent`, dentro del proceso del canal. Sustituye por completo al bloque v1.

## C1. Marcador

La primera línea del bloque es `// agentic-pod-launcher: stderr-capture patch v2`. El literal `stderr-capture patch v1` no aparece en ninguna parte del archivo parcheado.

## C2. Constantes de módulo

| Constante | Valor |
| --- | --- |
| ruta del log | `'/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log'`, el mismo literal de v1 |
| umbral | `TELEGRAM_STDERR_LOG_MAX_BYTES` si son solo dígitos (`/^[0-9]+$/`) y forman un entero seguro `> 0`; si no, `10485760` |
| códigos de destino cerrado | `EPIPE`, `ERR_STREAM_DESTROYED`, `ERR_STREAM_WRITE_AFTER_END`, `EBADF` |

## C3. Anexo con rotación

Una sola función de anexo, usada por la escritura reemplazada, por los manejadores `uncaughtException` y `unhandledRejection` y por las líneas de aviso.

1. Crea el directorio del log si falta.
2. Rota según la tabla de `data-model.md` §2.
3. Anexa el dato con `appendFileSync`: un string tal cual; cualquier otro chunk, como `Buffer.from(chunk)`. Es la misma conversión que v1.

Toda la función está dentro de un `try` que traga cualquier error (FR-010).

## C4. Escritura reemplazada

`process.stderr.write = (chunk, ...rest) => …`:

1. Anexa el chunk (C3).
2. Si el reenvío está cortado: devuelve `true` y, si el último argumento de `rest` es una función, la invoca con `queueMicrotask` sin argumentos. No llama a la escritura original.
3. Si está activo: devuelve `_origWrite(chunk, ...rest)`. Si eso lanza un error con código de destino cerrado, corta (C5) y devuelve `true`. Cualquier otro error se relanza, como en v1.

Con un stderr sano, lo que llega al log y a stderr es byte por byte lo de v1 (FR-009), y el valor de retorno es el de la escritura original.

## C5. Corte

- `process.stderr.on('error', e => …)`: si `e.code` es de destino cerrado, corta; si no, anexa `[<ISO>] [stderr-error] <e.code || e>` y no cambia el estado.
- Cortar es idempotente. La primera vez cambia el estado a `cortado` y anexa `[<ISO>] [stderr-closed] <code> - forwarding to stderr stopped, log only`. Las siguientes no hacen nada (FR-007).

## C6. Manejadores de proceso

Se conservan los dos de v1 con su formato: `[<ISO>] [uncaught] <stack o error>` y `[<ISO>] [unhandled] <razón>`. Ahora anexan por C3.

## C7. Envoltura

Todo el bloque va dentro de `try { … } catch {}`, como en v1. Si algo falla al instalarse, el plugin sigue con su stderr original.

## C8. Lo que el bloque NO hace

- No cambia la ruta, el formato ni el contenido de las líneas existentes.
- No toca los manejadores del vendor ni ningún otro grupo de parches.
- No crea procesos, timers ni archivos fuera de la ruta del log y sus generaciones (`.1`, `.2` y `.1.tmp`).
- No escribe la ruta del log ni su contenido a ningún otro destino.

## Oráculos (bajo bun, `tests/telegram-stderr-hook.bats`)

| Id | Comprueba |
| --- | --- |
| H1 | bucle: hook + manejador del vendor + stderr a un pipe cerrado. Con v1, en 1 s el log pasa de 1 MB y el timer de salida no corre (ROJO). Con v2, el log tiene una sola línea `[stderr-closed] EPIPE`, cero líneas `uncaught exception: Error: EPIPE` y el timer corre (VERDE). El arnés mata a bun por su PID y comprueba que murió (ver `tasks.md` T005) |
| H2 | después del corte, N escrituras dejan N líneas en el log, ninguna línea de aviso más y **cero llamadas a la escritura original**. El driver instala, antes del hook, un espía que envuelve la escritura real de `process.stderr` y cuenta llamadas; el hook lo captura como `_origWrite`. El contador se pone en cero al ver la línea `[stderr-closed]` y se escribe a un archivo lateral con `writeFileSync` al salir |
| H2a | ráfaga: N escrituras en un mismo tick contra el pipe cerrado, antes de que llegue el primer error asíncrono, dejan exactamente una línea `[stderr-closed]` |
| H2b | la guarda de una vez: dos `error` de destino cerrado emitidos a mano (EPIPE y ERR_STREAM_DESTROYED) dejan exactamente una línea `[stderr-closed]`, con el código del primero, y la escritura siguiente va solo al log. Existe porque bun 1.3.12 emite un único `error` por stream aunque fallen 50 escrituras (medido el 23-11-2026), así que H2a no ve una guarda ausente (M3 sobrevivió a H2a) |
| H3 | stderr sano: el log y el stderr capturado son byte por byte iguales a los de v1 con las mismas escrituras |
| H4 | tope: con U = 100000 y 100.000 escrituras, `actual + .1 + .2 < 3U + 3 × escritura`, la última línea escrita está en el archivo actual, y los únicos archivos del directorio que empiezan con el nombre del log son el actual, `.1` y `.2` |
| H5 | heredado: un archivo de 50 U que termina en un marcador deja `.1` de U bytes terminada en el marcador, y el archivo actual queda solo con la escritura nueva |
| H6 | umbral inválido (`0`, `-5`, `abc`, vacío, `10M`, `1e7`) se comporta exactamente como 10485760: 9.830.400 bytes, entre 9 y 10 MiB, sin rotar |
| H5b | si la copia del tramo final no se puede escribir (`.1.tmp` imposible; ENOSPC en producción), el heredado se borra igual y el actual queda solo con la escritura nueva |
| H7 | escritor de shell concurrente: rc 0 en el shell y cero líneas malformadas en las generaciones |
| H8 | directorio del log sin permiso de escritura: la escritura original a stderr ocurre igual y el proceso no cae |
| H9 | un `error` del stream con otro código (por ejemplo `EAGAIN`) deja una línea `[stderr-error]` y el reenvío sigue activo |
| H10 | dos procesos bun con el hook escriben en paralelo al mismo log con un umbral chico (U = 20000): los dos salen con 0, ninguna línea queda malformada en las generaciones y el total respeta la cota de H4 más una escritura por proceso |
