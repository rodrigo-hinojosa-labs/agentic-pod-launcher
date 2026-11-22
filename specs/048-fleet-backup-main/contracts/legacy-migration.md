# Contract L: borrado verificado de la rama heredada `backup/<unidad>`

Corre al final de cada ciclo de una unidad con destino `repo`, después de un `ok` o de un `no-change` con su directorio en `main`.

## L1. Condiciones, todas obligatorias

1. `refs/heads/backup/<u>` aparece en el archivo de heads del ciclo.
2. El subárbol `.agent-backup/<u>` de la punta remota de `main`, leído en este ciclo después del empuje (o en el paso 3 de M2 si fue `no-change`), es igual a `state.last_tree`.
3. La marca de la rama (`backup/<u>:.agentic-pod-backup.json`, un `fetch --depth 1 --filter=blob:none` de la rama más la lectura de ese blob) existe y nombra a este agente y a esta unidad.

## L2. Acción y registro

- Si se cumplen: `push origin :refs/heads/backup/<u>` (sin otra rama en el mismo empuje). Éxito: `legacy_branch: "deleted <ISO>"`, línea `backup-<u>: legacy branch backup/<u> deleted (its backup is in main)`, y la caché `<u>-repo` se conserva (es la caché local del camino main; ajuste de la implementación). Fallo del empuje: `legacy_branch: "kept: delete-failed"`, se reintenta el próximo ciclo.
- Si falla la condición 2: `kept: not-verified` (sin línea en stdout; queda en `backup-status`).
- Si falla la condición 3: `kept: no-mark` o `kept: other-agent`, con una línea en stderr. Una rama así nunca se borra, en ningún ciclo.
- Sin rama: `legacy_branch: "none"`.

## L3. Invariantes que prueban los tests

- L-I1: en ninguna secuencia de prueba se borra `backup/<u>` antes de que su directorio esté en `main` con el árbol verificado (SC-008).
- L-I2: una rama sin marca o con la marca de otro agente o de otra unidad sobrevive a 10 ciclos.
- L-I3: el borrado nunca va acompañado de otra referencia en el mismo empuje.
- L-I4: borrar la rama de una unidad no afecta las ramas de las otras unidades (cada una decide por su cuenta).
