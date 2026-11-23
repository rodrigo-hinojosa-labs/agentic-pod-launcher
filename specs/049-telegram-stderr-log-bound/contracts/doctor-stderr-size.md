# Contrato: tamaño del log en `agentctl doctor` (modo docker)

**Alcance**: `scripts/agentctl::cmd_doctor`, que corre en el host, dentro del workspace.

## D1. Fuente

- Archivo: `${WORKSPACE}/scripts/heartbeat/logs/telegram-mcp-stderr.log`, leído por el bind mount con el mismo `WORKSPACE` que usa `_doctor_check_plugin_failures`. Sin `docker exec`.
- Tamaño: un helper nuevo, `_file_size PATH`, que prueba `stat -c %s` y después `stat -f %z`, el orden de `_file_mode` (lección 021: `stat -f` en Linux significa sistema de archivos).

## D2. Salida

| Caso | Línea |
| --- | --- |
| el archivo no existe | ninguna |
| `_file_size` no devuelve un entero | ninguna (no se avisa sin dato) |
| tamaño `<= 104857600` | `_doctor_pass "Telegram stderr log: <N> MiB"` |
| tamaño `> 104857600` | `_doctor_warn "Telegram stderr log is <N> MiB (rotation not active?)" "Rebuild the image so the stderr-capture patch v2 applies, then empty it: docker exec -u agent <agent> truncate -s 0 /workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log"` |

`<N>` es el tamaño en MiB, redondeado hacia abajo.

El umbral de alarma es fijo, sin perilla.

## D3. Restricciones

- Nunca lee ni imprime contenido del log.
- Solo en `cmd_doctor` (modo docker). `cmd_local_doctor` no gana la línea, porque el modo local no tiene canal.
- Ubicación: después de la asignación `WORKSPACE=$(_resolve_workspace "$agent")` (`scripts/agentctl`, cerca de la línea 855), junto a la llamada `_doctor_check_plugin_failures "$WORKSPACE"` (cerca de la línea 898). **No** dentro del bloque de parches del plugin (cerca de la línea 785): ahí `WORKSPACE` todavía no está asignado, y ese bloque solo corre cuando `notifications.channel` vale `telegram` (cerca de la línea 716), que es el notificador del heartbeat y no la presencia del plugin. La única condición de la línea es que el archivo exista.
- Cuenta en `_doctor_warn_count` como cualquier otro WARN.

## Oráculos (host, `tests/agentctl-doctor-telegram-patches.bats`)

El arnés es el de ese archivo, que ya lleva al doctor docker hasta los chequeos del plugin con un `docker` falso (molde `tests/agentctl-doctor-claude-oauth.bats`). Al menos una prueba usa un `agent.yml` con un notificador distinto de `telegram`, para que la ubicación quede probada.

| Id | Comprueba |
| --- | --- |
| A1 | sin archivo → la salida no contiene `Telegram stderr log` |
| A2 | archivo de 5 MiB → `✓ Telegram stderr log: 5 MiB`, sin WARN |
| A3 | archivo disperso de 101 MiB (`dd seek`, sin escribir datos) → WARN con `101 MiB` y el comando `truncate -s 0`; con `notifications.channel` distinto de `telegram` |
| A4 | el contenido del archivo es un centinela; ninguna línea de la salida lo contiene |
| A5 | `_file_size` devuelve el mismo número en macOS (BSD) y en Linux (GNU); lo cubren los dos brazos de la CI |
