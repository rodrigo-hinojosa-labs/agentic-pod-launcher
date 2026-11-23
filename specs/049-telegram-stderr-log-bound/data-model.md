# Data Model: Log de stderr del canal de Telegram acotado

**Feature**: 049-telegram-stderr-log-bound | **Fecha**: 2026-11-23

No hay base de datos ni esquema nuevo. Las entidades son archivos del workspace y estado en memoria del proceso del canal.

## 1. Log de stderr del canal

| Campo | Valor |
| --- | --- |
| Ruta en el contenedor | `/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log` (sin cambios, FR-014) |
| Ruta en el host | `<workspace>/scripts/heartbeat/logs/telegram-mcp-stderr.log`, por el bind mount |
| Escritores | el plugin parcheado (proceso del canal, usuario `agent`), `scripts/hooks/stop-redeliver.sh` (028), `scripts/hooks/askq-guard.sh` (031) |
| Lectores | `agentctl logs --stderr`, `agentctl doctor` (solo el tamaño) |
| Forma de escritura | anexo por ruta en cada escritura: el archivo se abre, se anexa y se cierra |
| Formato | texto libre, sin cambios respecto de v1, más dos tipos de línea nuevos (§4) |

**Invariante**: el tamaño del archivo actual es menor que `umbral + tamaño de la última escritura`.

## 2. Generaciones anteriores

| Nombre | Contenido | Cota |
| --- | --- | --- |
| `<ruta>.1` | lo que había en el archivo actual al rotar por última vez, o el tramo final de un archivo heredado | menor que `umbral + una escritura`, o exactamente `umbral` en el caso del heredado |
| `<ruta>.2` | la `.1` anterior | la misma |
| `<ruta>.1.tmp` | transitorio, solo durante el recorte de un heredado | se renombra a `.1` en la misma rotación; si queda huérfano por una caída, la siguiente rotación de un heredado lo sobrescribe |

No existe `.3`: al rotar, la `.2` se reemplaza (FR-002).

**Invariante (FR-003)**: `actual + .1 + .2 < 3 × umbral + 3 × máximo de una escritura`.

### Transiciones de rotación

Se evalúan antes de cada anexo del plugin, nunca en los hooks de shell:

```text
tamaño(actual) <  U            -> no rota; anexa
U <= tamaño(actual) < 2U       -> .1 -> .2 ; actual -> .1 ; anexa (crea actual)
tamaño(actual) >= 2U           -> .1 -> .2 ; tramo final de U bytes -> .1.tmp -> .1 ; borra actual ; anexa
cualquier paso falla           -> se traga; anexa si puede; reenvía a stderr igual
```

`U` es el umbral de rotación (§3).

## 3. Umbral de rotación

| Campo | Valor |
| --- | --- |
| Fuente | `TELEGRAM_STDERR_LOG_MAX_BYTES` en el entorno del proceso del canal, que viene del `.env` del workspace por el `env_file` de compose |
| Por defecto | `10485760` (10 MiB) |
| Validación | solo dígitos (`/^[0-9]+$/`), con un entero seguro `> 0`. Ausente, vacío, cero, negativo, no numérico o con sufijo (`10M`, `1e7`, que `Number.parseInt` leería como 10 y 1) usa el valor por defecto (FR-005; endurecido por la revisión independiente) |
| Momento de lectura | una vez, al cargar el módulo; un cambio pide reiniciar el canal |

## 4. Estado de reenvío (por proceso)

| Estado | Significado | Transición |
| --- | --- | --- |
| `activo` | cada escritura va al log y a la escritura original | estado inicial |
| `cortado` | cada escritura va solo al log; la escritura reemplazada devuelve `true` e invoca su callback, si lo hay, en un microtask | `activo → cortado` cuando el stream emite `error`, o la escritura original lanza, con un código de destino cerrado |

No hay transición de vuelta (FR-006).

**Códigos de destino cerrado**: `EPIPE`, `ERR_STREAM_DESTROYED`, `ERR_STREAM_WRITE_AFTER_END`, `EBADF`.

### Líneas nuevas que puede escribir el parche

| Línea | Cuándo | Cuántas |
| --- | --- | --- |
| `[<ISO-8601>] [stderr-closed] <code> - forwarding to stderr stopped, log only` | al pasar a `cortado` | una por proceso (FR-007) |
| `[<ISO-8601>] [stderr-error] <code o texto>` | un `error` del stream con otro código | una por evento; no cambia el estado |

Las líneas `[uncaught]` y `[unhandled]` de v1 se conservan con el mismo formato y ahora pasan por la misma rotación.

## 5. Versión del grupo de captura en `server.ts`

| Estado del archivo | Marcador presente | Qué hace el patcher nuevo |
| --- | --- | --- |
| prístino | ninguno | instala v2 |
| v1 intacta | `stderr-capture patch v1` y el bloque `STDERR_HOOK_V1` exacto | reemplaza el bloque por v2 |
| v1 editada | `stderr-capture patch v1`, pero el bloque no coincide exactamente una vez | WARN, deja v1 y aplica el resto de los grupos |
| v2 | `stderr-capture patch v2` | nada |

## 6. Aviso del doctor

| Tamaño del archivo actual | Salida |
| --- | --- |
| no existe | ninguna línea |
| `<= 104857600` (100 MiB) | `✓ Telegram stderr log: <N> MiB` |
| `> 104857600` | `⚠` WARN `Telegram stderr log is <N> MiB (rotation not active?)`, con la acción: actualizar la imagen y vaciar el log |

`<N>` es el tamaño en MiB redondeado hacia abajo. Textos literales en `contracts/doctor-stderr-size.md` §D2.

El doctor solo consulta el tamaño (`stat`), nunca el contenido. Mide solo el archivo actual: las generaciones están acotadas por construcción.
