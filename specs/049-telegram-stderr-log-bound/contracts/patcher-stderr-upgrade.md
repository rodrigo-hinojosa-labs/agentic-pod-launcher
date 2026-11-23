# Contrato: cascada del grupo stderr en el patcher

**Alcance**: `docker/scripts/apply_telegram_typing_patch.py`, código horneado en la imagen y ejecutado en cada arranque por `start_services.sh::apply_plugin_patches`.

## P1. Constantes

- `MARKER_STDERR_V1 = "agentic-pod-launcher: stderr-capture patch v1"`, congelado.
- `MARKER_STDERR = "agentic-pod-launcher: stderr-capture patch v2"`.
- `STDERR_HOOK_V1`: el bloque v1 **tal como quedó en disco** con el patcher de `main` (`9a0b93e`): la constante de entonces con cada `\n` de las líneas `[uncaught]` y `[unhandled]` convertido en un salto real por la plantilla de `re.subn` (research D4b). No se edita nunca más.
- `STDERR_HOOK`: el bloque v2 de `stderr-hook-v2.md`.
- `ALL_MARKERS` mantiene siete entradas, con `MARKER_STDERR` (v2) en el lugar que hoy ocupa el v1. `--list-markers` imprime v2.

## P2. `upgrade_stderr_v1_to_v2(src) -> (src, applied)`

1. Si `MARKER_STDERR_V1` no está en `src`, devuelve `(src, False)`.
1b. Si `MARKER_STDERR` (v2) también está, es un rollback y vuelta: el patcher 0.34.0 apiló `"\n" + STDERR_HOOK_V1` encima de v2. Si eso aparece exactamente una vez, lo quita y devuelve `(src, True)`. Si no, emite el WARN `stderr v1→v2 upgrade: v1 block stacked on v2 not found exactly once (edited out-of-band?) — leaving both in place` y devuelve `(src, False)`.
2. Si `src.count(STDERR_HOOK_V1) != 1`, emite el WARN `stderr v1→v2 upgrade: v1 block not found exactly once (edited out-of-band?) — leaving v1 in place` y devuelve `(src, False)`.
3. Si no, devuelve `(src.replace(STDERR_HOOK_V1, STDERR_HOOK, 1), True)`.

Usa `str.replace`, nunca una expresión regular (034 D14).

## P3. `apply_stderr(src)`

Si `MARKER_STDERR` o `MARKER_STDERR_V1` está en `src`, devuelve `(src, False)`. Si no, inserta `STDERR_HOOK` antes de `\nconst TOKEN = ` con el mismo ancla y el mismo WARN de hoy.

El reemplazo de `re.subn` se pasa como función (`lambda`), no como string: el bloque v2 contiene barras invertidas (032).

## P4. `main()`

`upgrade_stderr_v1_to_v2` corre inmediatamente antes de `apply_stderr`. Su resultado entra en la condición de "sin cambios" y en la lista de partes aplicadas del log final, con la etiqueta `stderr-upgrade-v1→v2`, en el molde de `typing-upgrade-v1→v2` y `voice-upgrade-v2→v3`.

## P5. Garantías

| Partida | Resultado |
| --- | --- |
| prístino | v2 instalada; el archivo es idéntico al de la fila siguiente |
| dorado 0.34.0 (v1 intacta) | v2; idéntico a la fila anterior |
| v2 | sin cambios; log `no changes to <path>: all patch groups already present` |
| v1 editada | WARN de P2; grupo stderr en v1; el resto de los grupos, sin cambios |
| sin ancla `const TOKEN =` | WARN de hoy; ningún grupo stderr |

## Oráculos (host, `tests/apply-telegram-patches.bats`)

| Id | Comprueba |
| --- | --- |
| S1 | prístino → contiene el marcador v2 exactamente una vez, cero v1, y el literal de la ruta `'/workspace/scripts/heartbeat/logs/telegram-mcp-stderr.log'` aparece dentro del bloque v2 (FR-014) |
| S2 | `sha(nuevo(dorado)) == sha(nuevo(prístino))` |
| S3 | `nuevo(prístino)` con `STDERR_HOOK` reemplazado por `STDERR_HOOK_V1` es byte por byte igual al dorado (FR-013) |
| S4 | fidelidad de la gemela: `STDERR_HOOK_V1` está contenido en el dorado |
| S5 | idempotencia: dos pasadas sobre prístino, dorado y v2 dan el mismo archivo que una; la segunda imprime `all patch groups already present` |
| S6 | v1 editada (un byte cambiado dentro del bloque) → WARN de P2, marcador v1 intacto, cero v2, y los demás marcadores presentes |
| S7 | `--list-markers` imprime siete líneas y la de stderr es v2 |
| S8 | escapes (034 G15 y G16): cada `\n` esperado del bloque aparece como dos bytes `\` y `n` en la salida, y la salida no tiene bytes de control fuera de tab y LF |
| S10 | rollback y vuelta: prístino, patcher nuevo, patcher de `9a0b93e` (apila v1) y patcher nuevo deja un solo v2, cero v1, y el archivo es byte por byte igual al de una instalación fresca |
| S9 | parse: con bun presente, la salida parcheada pasa `bun build --no-bundle <archivo> --outfile <temporal>` (la opción existe en bun 1.3.12, verificado con `bun build --help` el 23-11-2026); sin bun, se salta con motivo |
