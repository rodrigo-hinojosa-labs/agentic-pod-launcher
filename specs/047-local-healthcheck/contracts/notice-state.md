# Contrato: registro y entrega de avisos locales

**Date**: 2026-11-17
**Requirements**: FR-011 a FR-019; SC-005 a SC-007.
**Model**: [schema y transiciones](../data-model.md).

## N1. Configuración y secreto

Mantener 021 H1-H6: leer las dos claves de aviso con env_file_get, desde el archivo legacy cuando es legible y, si no, desde el archivo del workspace. Un legacy presente pero ilegible no bloquea el fallback existente. No source, eval ni EnvironmentFile nuevo. Ninguna clave ajena se incorpora al transporte.

Sin configuración completa no hay intento de red; el diagnóstico se emite normalmente y el registro previo se conserva. Al configurarse de nuevo se reconcilia el estado actual, sin reproducir transiciones intermedias.

El token nunca aparece en argv, entorno del hijo, log, JSON durable o evidencia. La URL de la API se forma solo para la configuración de curl por stdin. Escapar valores conforme a curl config; rechazar controles o formas que no puedan serializarse con seguridad. No imprimir URL, cuerpo, descripción de la API ni stderr crudo. Los tests usan valores ficticios y un receptor local/spy; ninguna credencial real.

## N2. Exclusión y observación

- Estado y lock directamente bajo la .state existente, con umask 077; estado <=16 KiB, schema y tipos cerrados.
- `flock -n` sobre descriptor 9 y archivo estable `.local-healthcheck.lock`; no unlink del lock ni fallback sin exclusión.
- Adquirir antes de observar para el envío. Si está ocupado, observar salud por separado, no enviar ni modificar estado y emitir diagnóstico notify_busy.
- Si falta flock, sync seguro, jq para el registro, directorio persistible o archivo válido recuperable, suspender avisos y conservar la salud calculada. No usar mkdir-lock con recuperación especulativa de PID.
- Los comandos flock de adquisición/liberación conservan fd9; los hijos de observación, persistencia y transporte lo cierran. La transacción libera explícitamente al terminar; los temporales se limpian en todas las salidas. No un trap que suelte el lock mientras aún corre un envío síncrono sin reserva.

## N3. Commit durable

Dentro del lock:

1. Temporal único en el mismo directorio, con 0600.
2. Escribir y validar JSON, tamaño, schema, enums y rangos.
3. GNU `sync TEMP` y comprobación de rc.
4. `mv TEMP STATE`, mismo filesystem, y comprobación de rc.
5. GNU `sync STATE_DIR` y comprobación de rc.

Todos los comandos potencialmente bloqueantes respetan el deadline compartido del commit (5 s). No usar sync global/-f. Un fallo de cualquiera de los pasos no acredita persistencia, aun si el rename ya ocurrió: suspender el envío, conservar salud y señalar state_failure. El siguiente proceso revalida lo que sí haya quedado legible. No depender de set -e, ni capturar `$?` después de negar el comando.

Los tests sintéticos inyectan timeout y sync estrictos desde su PATH privado. El doble de timeout ejecuta el hijo, respeta las formas GNU usadas por el producto, aplica TERM/KILL y lo recoge; rechaza argumentos no previstos. El doble de sync valida archivo/directorio y orden, registra retornos y permite fallas por operación; no llama al sync global del host. N30/N31 verifican estos controles con casos satisfactorios y fallidos. No se depende de coreutils instalado en el Mac. El gate Linux utiliza timeout/sync reales, incluido flush de archivo y directorio; los dobles del host no acreditan durabilidad física.

Antes de adoptar un checkpoint válido ya visible, sincronizar archivo y directorio bajo lock con tope compartido de 5 s. Esto cubre el rename de una confirmación cuyo flush final pudo haber fallado antes. Si esta barrera falla, cero envíos y sin adoptar esa confirmación. La barrera se descuenta de los mismos 30 s de avisos, no crea presupuesto adicional. Un registro semánticamente inválido sigue el reset del modelo, sin usar su pendiente.

## N4. Transiciones y obsolescencia

Aplicar la tabla de data-model.md, con versión nueva por transición. Deduplicar por evento persistido, no por texto ni por “DEGRADED enviado alguna vez”.

- WARN_EXPIRY y DEGRADED pueden abrir episodio.
- Recuperación exige `episode.notified=true`; si nunca hubo confirmación, cancelar el pendiente y cerrar sin aviso.
- D→W con episodio notificado genera un solo RECOVERY_WARN y conserva el episodio abierto; sin confirmación anterior genera WARN_EXPIRY, sin presentarlo como recuperación.
- NONE con recuperación pendiente conserva el episodio hasta confirmar. Una nueva alarma cancela la recuperación obsoleta pero conserva su deuda: no reiniciar notified a false.
- Cada intento construye el texto desde el snapshot vigente bajo lock. Una recuperación parcial menciona los WARN restantes y no anuncia OK.

La obsolescencia se refiere a cambios observados al reconciliar; el healthcheck no puede garantizar que el agente no cambie después del snapshot y antes de recibir el mensaje.

## N5. Reserva, red y confirmación

Un aviso elegible necesita dos commits:

1. Antes de red: reconciliar y guardar inflight, momento del intento y reserva de 1800 s. Si no se acredita ese commit, cero llamadas al receptor.
2. Después de una respuesta válida: guardar el cambio de confirmación que retira pending y actualiza/cierra el episodio.

Confirmación válida: curl rc0, HTTP 200 y JSON `ok=true`; además, el commit final debe ser durable. Un HTTP correcto por sí solo no basta. JSON inválido, `ok=false`, timeout o falta de respuesta conservan pendiente no confirmado.

Si el proceso cae entre red y el rename final, inflight se recupera como entrega incierta. Tras un rename final con flush no acreditado puede verse el checkpoint nuevo: solo se adopta después de la barrera de N3; tras un reinicio también podría recuperarse el anterior. Incluso si el receptor recibió el mensaje, puede haber duplicado remoto si solo queda inflight. Estos casos y la respuesta perdida están fuera de una garantía exactly-once. No se marcan como entregados para ocultar el problema.

Un solo intento por evaluación; sin retries internos de curl. Parámetros de diseño: `-q` primero, connect-timeout 5 s, max-time 15 s y retry 0. Límite externo: 18 s más 2 s hasta KILL, con recolección del hijo. Stdin lleva la configuración; stdout de transporte se captura en temporal 0600 y se extraen solo HTTP/ok para decidir, sin publicarlo.

El presupuesto conjunto de avisos nace una vez al terminar la observación: `notice_deadline=min(observation_end+30 s,global_deadline)` según H5. Incluye adopción, reserva, red y commit final; cada commit/barrera se acota además a 5 s desde su inicio, sin extender el plazo de fase/global. El controller no inicia llamadas sin tiempo restante y descuenta también TERM/KILL y recolección de ese remanente. Si el presupuesto se consume tras reservar o enviar, el aviso conserva su condición incierta. El diagnóstico de salud no cambia.

## N6. Tiempo, reinicios y nuevas transiciones

La cuenta regresiva del modelo se actualiza y persiste antes de enviar. El primer healthcheck elegible ocurre a partir de treinta minutos contabilizados desde el último intento. Un retroceso aporta cero tiempo, no baja clock_seen_s y puede demorar conservadoramente. Al corregirse el reloj, solo cuenta lo que supera el máximo ya observado; no se da doble crédito. La reserva y ese máximo sobreviven a reiniciar servicio/host. Los saltos hacia delante dependen del reloj del host según el modelo.

Una transición nueva cancela el pendiente obsoleto y su primer aviso elegible no hereda la espera. Una resolución sin aviso previo confirmado no genera recuperación aunque existiera un pendiente en espera. La reentrada a D sí tiene versión nueva.

## N7. Diagnóstico de transporte

En stderr, prefijo `agent-<name> healthcheck notify:` y un código de catálogo:

```text
not_configured | notify_busy | state_reset | state_unavailable |
state_failure | transport_unavailable | timeout | curl_failure |
http_failure | invalid_response | api_failure | delivery_uncertain |
retry_pending | clock_reversed | confirmed | budget_exhausted
```

not_configured es silencioso por defecto; no agrega una advertencia de salud. Los detalles permitidos son tipo de evento, versión y espera numérica. No se persiste stderr externo ni se copia una respuesta del proveedor al diagnóstico. Las confirmaciones son de entrega a la API, nunca de lectura humana.
