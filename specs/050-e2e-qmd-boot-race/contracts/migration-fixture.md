# Contrato del fixture y de la prueba de migración

**Sujeto**: el único bloque titulado `qmd e2e (037): a legacy vault-root collection migrates to wiki/-only on the first reindex tick` de `tests/docker-e2e-qmd.bats`. Identificarlo por título, no por el ordinal histórico 13.

## F1. Preparación anterior al contenedor

1. Conservar el motor QMD falso en su prefijo gestionado y su manifest/hash, para no instalar paquetes ni cargar modelos.
2. Preparar índice y marcador de setup, dejando ausente el marcador de colección. Preparar una página fija bajo `wiki/`.
3. Usar `0 0 31 2 *` solo en el `agent.yml` de este fixture. No cambiar el cron del producto ni el de otros escenarios.
4. Todo lo anterior sucede antes de `docker compose up -d`.

No se reutilizan workspaces de corridas previas. No se carga el estado ni el vault de un agente real.

## F2. Precondición y atribución

Antes del primer reindex, una inspección como `agent` debe probar los tres hechos del estado heredado y emitir `LEGACY_PENDING` solo si se cumplen. Se exige rc 0 y texto exacto. Comprobar también que no hubo `collection remove/add` antes del tick; un registro todavía inexistente equivale a cero llamadas, no a una inspección exitosa de cualquier otro tipo.

La prueba no exige que el proceso de setup aún no haya corrido. La prueba normal no instala gates ni envuelve al supervisor. No se hacen escrituras al vault tras el boot.

## F3. Primer tick y observación

- Una llamada lógica `qmd_e2e_reindex_wait in_container "test 13 tick 1"`; validar su retorno y `REINDEX_STATUS`.
- La llamada y sus dos guardias van antes del bucle de lectura.
- Conservar el presupuesto de 45 s de observación y `|| true` en la lectura de `engine-calls.log`; las vueltas no lanzan otro reindex. Calcular el deadline de observación después de aceptar tick 1, para que la espera del lock no consuma el tiempo destinado a leer el log. Los valores de ambos presupuestos no cambian.
- La evidencia debe tener un remove y un add, no solo una primera ocurrencia. El add debe usar `wiki/**/*.md`; remove precede al add y el add a cleanup.
- Exigir `.qmd-collection-wiki` presente y `.migration=done`, con rc de inspección y contenido validados por separado.

## F4. Segundo tick

Conservar la llamada por el ayudante, la validación de retorno y `REINDEX_STATUS`. Comparar el conteo de operaciones de colección posterior con el de tick 1 y validar el rc de esa inspección. Si no corrió, no demuestra idempotencia.

## F5. Aserciones y diagnóstico

Todas las aserciones del bloque deben poder detener Bats en 3.2 y 5.x. Se sustituyen las dos `[[ ... ]]` actuales por `[ ]` y se exige el status de cada inspección requerida. No se introducen pipes con un lector que cierre antes de consumir todo el texto.

Se conserva el diagnóstico de teardown de 043, los reportes de lock y los topes del ayudante. El cambio no añade una prueba Docker ni modifica la imagen, el supervisor, `qmd_index.sh`, `heartbeatctl`, el watcher o el ayudante compartido de locks.

## F6. Guardias de integración

B2 de `tests/qmd-e2e-lock.bats` debe seguir exigiendo dos llamadas al ayudante, guardias, lectura tolerante, plazo de 45 s y diagnóstico anterior al teardown. Además exige que tick 1 y sus guardias precedan al `while`. Se actualiza su comentario sobre la función del bucle, sin aflojar sus otras comprobaciones.

La preparación y las aserciones se cubrirán ejecutando secciones del bloque real en el host: [host-oracle.md](host-oracle.md). El estado y las transiciones están en [data-model.md](../data-model.md).
