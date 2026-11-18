# Modelo de datos y transiciones de 047

**Date**: 2026-11-17
**Contracts**: [veredicto](contracts/health-verdict.md), [avisos](contracts/notice-state.md).

## 1. Snapshot de observación

Datos efímeros, reconstruidos en cada evaluación; no se guardan tokens ni journal:

| Campo | Dominio | Semántica |
| --- | --- | --- |
| `health` | OK / WARN / DEGRADED | Máximo de las comprobaciones; códigos 0/1/2 |
| `reason_codes` | lista de enums cerrados | Unidad, login, journal, conexión, QMD/grafo; nunca texto externo |
| `auth_class` | renewable / renewal_expiring / renewal_expired / login_lost / incomplete | Resultado de la forma observada del login |
| `renewal_remaining_ms` | entero o null | Solo si la fecha fue verificable |
| `connection` | present / absent / unknown | Señal de red de la unidad, no conversación comprobada |
| `unit_invocation` | identificador o null | Solo durante la observación; permite descartar reinicios |
| `notice_identity` | NONE / WARN_EXPIRY / DEGRADED | DEGRADED si salud 2; WARN_EXPIRY si no hay D y vence renovación; NONE en el resto |

Un WARN de conexión o QMD, sin vencimiento de renovación, tiene identidad NONE. `reason_codes` se renderiza con mensajes del catálogo, no interpolando entradas del journal.

## 2. Registro durable

Ruta `.state/local-healthcheck.json`; archivo regular privado de hasta 16384 bytes. El lock `.state/.local-healthcheck.lock` no se renombra ni se borra durante operación.

Ejemplo estructural, con datos ficticios:

```json
{
  "schema": 1,
  "identity": "NONE",
  "event_version": 7,
  "episode": {"id": 4, "notified": true},
  "pending": {
    "version": 7,
    "kind": "RECOVERY",
    "phase": "inflight",
    "attempted_at_s": 1800000000,
    "clock_seen_s": 1800000000,
    "retry_remaining_s": 1800
  }
}
```

- `schema`: exactamente 1; claves cerradas y tipos validados antes de usar el archivo.
- `identity`: última identidad reconciliada bajo lock; no el último texto emitido.
- `event_version`: entero no negativo <=9007199254740990; aumenta en cada cambio de identidad. Al alcanzar el límite, suspender avisos y diagnosticar, sin wrap ni reset que repita un evento.
- `episode`: null o `{id, notified}`. id es la versión que lo abrió; `notified` indica al menos un aviso de alarma/recuperación parcial confirmado durablemente.
- `pending`: null o aviso vigente. `version` coincide con el evento vigente. `kind` es WARN_EXPIRY, DEGRADED, RECOVERY_WARN o RECOVERY; `phase` es ready, inflight o pending. No se conserva payload, destino o respuesta cruda.
- `attempted_at_s`: null si no hubo intento; entero epoch seconds si se reservó uno.
- `clock_seen_s`: entero epoch seconds; máximo de reloj ya contabilizado para ese aviso, que nunca disminuye mientras siga vigente.
- `retry_remaining_s`: entero entre 0 y 1800. Ready nace en cero. Inflight y pending con intento tienen reserva persistida.

Invariantes entre campos, además de tipos/rangos:

- Toda identidad W/D requiere episode no null, con id entero positivo <=event_version. pending.version, si existe, debe ser exactamente event_version.
- DEGRADED solo admite pending.kind DEGRADED; WARN_EXPIRY admite WARN_EXPIRY o RECOVERY_WARN. Una alarma sin pending requiere notified=true, porque ya se confirmó su aviso.
- NONE admite episode=null/pending=null, o episode.notified=true con pending.kind RECOVERY. RECOVERY y RECOVERY_WARN siempre requieren notified=true.
- Ready exige attempted_at_s=null y retry_remaining_s=0. Inflight/pending exigen attempted_at_s entero no negativo <=clock_seen_s; clock_seen_s es no negativo y no supera el entero seguro. Las fechas de intento se expresan en segundos, sin conversiones heurísticas.
- Toda combinación incompatible es state_reset: descartar el pendiente incoherente, reconstruir primera observación actual y guardarla antes de red. No reproducir instrucciones/payloads del archivo. Tras corrupción no se reconstruye un historial de entregas que ya no existe; el reset se diagnostica.

Estado inicial: identity NONE, event_version 0, episode null y pending null. Ausente/inválido se informa como primera observación; el envío solo puede empezar tras guardar estado válido. Si el archivo o lock es un tipo inesperado, o no puede persistirse, suspender avisos sin ejecutar su contenido ni alterar la salud.

Un checkpoint existente y válido se sincroniza (archivo y directorio) bajo lock antes de adoptar sus confirmaciones o decidir por sus pendientes. Así, un rename visible cuyo flush falló en la ejecución anterior puede acreditarse ahora; si la barrera de sincronización falla, no se adopta como confirmado ni se envía. Tiene tope de 5 s dentro del presupuesto compartido de avisos.

## 3. Episodio de notificación

Un episodio puede abarcar varios cambios de salud. Se cierra solo cuando la identidad es NONE y:

- no hubo ningún aviso confirmado: cierre silencioso; o
- se confirmó durablemente el aviso de recuperación.

Por eso una recuperación pendiente no se pierde si vuelve una alarma antes de poder entregarla. Una recuperación parcial D→W no cierra el episodio: todavía existe vencimiento próximo.

Cada transición crea versión nueva incluso si vuelve a una identidad ya observada. No deduplicar por “alguna vez se envió DEGRADED en este episodio”. Los cambios de motivos con la misma identidad no generan otro evento.

## 4. Tabla de reconciliación bajo lock

En todas las transiciones se cancela primero cualquier pendiente obsoleto.

| Antes → ahora | Pendiente nuevo | Episodio |
| --- | --- | --- |
| Primera observación W o D | W o D, ready | Abrir, notified=false |
| NONE → W o D | W o D, ready | Abrir si null; conservar si hay recuperación pendiente y su deuda |
| W → D | DEGRADED, ready | Conservar id/notified |
| D → W, notified=true | RECOVERY_WARN, ready | Conservar; un mensaje de recuperación parcial más vencimiento |
| D → W, notified=false | WARN_EXPIRY, ready | Conservar; no afirmar recuperación |
| W o D → NONE, notified=true | RECOVERY, ready | Conservar hasta confirmación |
| W o D → NONE, notified=false | null | Cerrar sin aviso de recuperación |
| Misma identidad | Pendiente vigente o null | Misma versión; actualizar solo la espera que corresponda |

W abrevia WARN_EXPIRY. La salud final puede ser WARN por otra causa aun con identidad NONE; una recuperación en ese caso es parcial y lo dice.

Confirmación durable de W/D/RECOVERY_WARN: pending=null y notified=true. Confirmación durable de RECOVERY con identidad NONE: pending=null y episode=null.

Secuencia de deuda obligatoria: D confirmado → NONE con recuperación fallida → D sin confirmar → NONE. El último NONE todavía debe recuperar el episodio que sí fue notificado. No se crea un episodio vacío que borre esa deuda.

## 5. Tiempo y reserva de intento

En cada evaluación con pendiente:

1. `delta=max(0, now_s-clock_seen_s)`.
2. `retry_remaining_s=max(0, retry_remaining_s-delta)`.
3. Guardar clock_seen_s=max(clock_seen_s,now_s) y la espera actualizada antes de permitir envío.
4. Si la espera es cero y el aviso sigue vigente, reservar inflight, attempted_at_s=now_s y retry_remaining_s=1800, conservando el máximo clock_seen_s del mismo aviso; commit durable ANTES de red.
5. Fallo conocido conserva pending y su espera; confirmación usa otro commit durable.

Un retroceso del reloj no resta espera, no baja la referencia y se diagnostica. Al corregirse el reloj no se cuenta dos veces el intervalo ya consumido. Caso obligatorio: minutos reales 0/10/15/20/25 con epoch relativo 0/600/300/1200/1500 dejan espera 1800/1200/1200/600/300 s; todavía no corresponde reintentar. Reiniciar no borra la reserva. Un salto hacia delante se interpreta según el reloj del host; el healthcheck no consulta una autoridad de tiempo ni repara el reloj. Los deadlines de una ejecución usan tiempo monotónico, no este reloj epoch.

## 6. Fronteras de fallo

| Momento | Estado recuperable | Conducta siguiente |
| --- | --- | --- |
| Antes de guardar reconciliación | Checkpoint anterior | Reobservar; no hubo envío |
| Commit previo falla | Checkpoint anterior o nuevo válido; escritura no acreditada | Cero red; suspensión visible |
| Inflight guardado, proceso cae antes de red | Inflight | Entrega incierta; esperar el mínimo restante |
| Red falla o JSON/HTTP no confirma | Pending/inflight | Reintento tras reserva; no afirmar entrega |
| API confirma y commit posterior falla/cae antes de rename | Inflight | Entrega incierta; duplicado remoto posible al reintentar |
| API confirma, rename final ocurrió, flush de directorio falla/cae | Checkpoint nuevo visible o checkpoint anterior tras reinicio | Revalidar y sincronizar lo visible antes de adoptarlo; checkpoint nuevo acreditado evita duplicado, anterior inflight conserva incertidumbre |
| Commit final confirmado | Pending null o episodio cerrado | No reenviar el evento confirmado |

“Confirmado” para deduplicación significa ack válido MÁS checkpoint durable. No equivale a lectura humana del mensaje. La ventana red–disco impide exactly-once; no se intenta ocultarla marcando enviado antes de red.

## 7. Concurrencia y configuración

La transacción de avisos observa bajo el lock. Un proceso que no lo consigue realiza su diagnóstico por separado y no modifica el registro ni envía. No se publica una observación vieja que esperaba en una cola de locks.

Sin configuración de notificaciones no hay tráfico ni necesidad de crear el registro. Si ya existe, queda conservado; al volver la configuración se reconcilia con la situación actual y se descartan pendientes obsoletos. No se reproducen todas las transiciones ocurridas durante la desactivación.

Los datos de notificación se leen mediante el parser existente y no forman parte de este schema. La falta de jq impide comprobar el login y genera WARN; la falta de curl, flock o persistencia solo suspende avisos, manteniendo el veredicto ya calculado.
