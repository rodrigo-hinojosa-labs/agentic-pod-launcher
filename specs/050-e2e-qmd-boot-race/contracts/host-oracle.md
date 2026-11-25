# Contrato del oráculo host y de sus controles negativos

## Superficie nueva propuesta

Se implementará `tests/qmd-e2e-boot-race.bats`, con un ayudante propio `tests/helper-qmd-e2e-boot-race.bash`. No se modifica el ayudante compartido `tests/helper-qmd-e2e.bash`.

Costura de prueba: `QMD_BOOT_RACE_E2E_FILE`, con valor por defecto `tests/docker-e2e-qmd.bats` resuelto desde la raíz. Solo la suite nueva la consume; permite probar copias mutadas sin editar la rama activa. El archivo debe existir y contener exactamente un sujeto válido.

## H0. Ejecución del código real de la prueba

- Extraer por título único y anclas únicas de sección. Se añadirán comentarios delimitadores `# 050:<section>:begin` y `# 050:<section>:end` en el bloque existente, para `fixture`, `precondition`, `tick1`, `observe` y `verify`. La delimitación no cambia el comportamiento del e2e.
- La sección `fixture` comprende el estado presembrado y el calendario efectivo; se ejecuta en un scratch propio. Para calendario puede extraerse el YAML real del bloque y comprobar su valor renderizado, sin reconstruir un YAML ideal en el oráculo.
- Las secciones restantes se ejecutan como sentencias directas de un único test Bats hijo, con fakes de `in_container`, del ayudante de reindex, reloj y espera. Las expectativas de los fakes se basan en las señales externas del [contrato de fixture](migration-fixture.md), no en una copia de las aserciones ideales.
- Los delimitadores son comentarios y cada sección debe ser no vacía. La extracción falla ante título o ancla ausente, duplicado, orden invertido o sección omitida. Una guardia comprueba que ninguna aserción del tramo desde la precondición al fin del test queda fuera de las secciones ejecutadas.
- El hijo debe usar el mismo bash y Bats que el padre; registrar y verificar las versiones. Buscar el launcher exterior, evitando el `bats` interno de `BATS_LIBEXEC`, como hace el precedente 041. Lanzarlo con `env -i` y una whitelist explícita de PATH, HOME/TMPDIR propios y las variables mínimas del caso; no heredar los `BATS_*` del proceso padre ni otras variables del operador. El PATH conserva deliberadamente el bash bajo prueba.
- El padre exige TAP `1..1`, el retorno previsto y exactamente un resultado que no sea skip. Cada negativo conductual acredita la línea o condición esperada de la aserción que falló, además del registro de respuestas consumidas por los fakes. Una excepción inesperada del arnés, un comando inexistente, un fake incompleto o un hijo que no arrancó no valen como detección de una regresión. Los rechazos estructurales esperados de H00/M18 se clasifican por separado según la sección de mutaciones; no se presentan como ejecución de una aserción del e2e.
- No ejecutar las secciones como una función bajo `run`, `if` o `||`, ni envolver el test hijo completo en un contexto que suprima errexit. El padre puede usar `run` sobre el proceso Bats hijo.
- Payload y código pasan por archivos, no por argumentos o variables enormes. No hay red, Docker ni esperas reales largas. Procesos hijos, si los hubiera, se retiran en teardown y cierran fd 3/4 al desacoplarse.

## Casos propuestos

Cada fila es una prueba host; los controles parametrizados de una fila deben verificar todos sus resultados, sin abortar silenciosamente después del primero. Diseño inicial: 15 pruebas nuevas. El conteo final se confirmará al implementar; el esperado de regresión es la base medida más el número realmente agregado.

| ID | Escenario y criterio |
| --- | --- |
| H00 | Autotest: sujeto y secciones únicos; rechazar extracción rota, hijo saltado, TAP vacío, intérprete distinto y fallo del arnés. |
| H01 | Ejecutar preparación real: índice y setup presentes, colección ausente, wiki presembrada y calendario imposible antes del up; la función real de setup no invoca el motor en ese estado. |
| H02 | Precondición válida pasa; índice o setup ausente, colección ya migrada y replace previo fallan. |
| H03 | Inspección inicial con texto correcto y rc 7 falla. |
| H04 | Retorno 1/3 del ayudante o `REINDEX_STATUS=7` de tick 1 fallan. |
| H05 | Primera lectura sin log y siguiente lectura válida pasan, con un solo tick efectivo antes de observar y dos en total; una espera de tick 1 que avanza el reloj más de 45 s no vence el deadline de observación, que se calcula después. |
| H06 | Log que nunca llega u omite migración falla al vencer el reloj falso, sin relanzar tick 1. |
| H07 | Una migración válida, confirmación y segundo tick sin cambios pasan. |
| H08 | Falta de remove, add con máscara correcta o cleanup falla. |
| H09 | Operaciones desordenadas y duplicación de remove/add fallan. |
| H10 | Confirmación ausente falla aunque el estado final diga `done`. |
| H11 | Estado final diferente de `done`, o inspección final con texto correcto y rc 7, fallan. |
| H12 | Retorno o status inválido de tick 2, o rc inválido de su inspección, fallan. |
| H13 | Tick 2 con nuevas operaciones de colección falla. |
| H14 | Guardias de cableado: sin `[[ ]]` ni negaciones intermedias en el sujeto; tick 1 antes del bucle; sin nuevos topes ni llamadas bare a reindex; B2 conserva sus guardias. |

H01 puede usar `tests/helper.bash` y la biblioteca real de QMD con su motor stub. Es diferente del replay: prueba el significado del fixture. Una guardia de posición confirma que su preparación y el YAML inspeccionado son los que usa el e2e antes del up.

## Mutaciones mínimas

Se aplican solo sobre copias aisladas y cada reemplazo exige exactamente una coincidencia. Cada mutante debe fallar por su caso, con el arnés sano. CTRL debe pasar antes y después. No se atribuye un rojo de parser a una aserción conductual.

Cada resultado distingue captura conductual, rechazo estructural esperado y error inesperado del arnés. M18 requiere un rechazo estructural esperado del extractor, con el motivo de sección ausente/vacía/duplicada acreditado y CTRL sano; ese resultado satisface M18, pero no demuestra una aserción ejecutada. Cualquier rechazo por otra causa sigue siendo un error del arnés e invalida la medición. Las guardias de forma también se identifican explícitamente, por ejemplo M03/M04 bajo bash 5.x.

B2 conserva su función de regresión del candidato sano: lee el archivo del checkout y no consume `QMD_BOOT_RACE_E2E_FILE`. Se ejecuta como control separado, no como detector de las copias mutadas. M14 se atribuye a H05/H06/H14 del oráculo nuevo sobre la copia; no se agrega una costura a la suite de locks.

| ID | Mutación | Detector |
| --- | --- | --- |
| M01 | Quitar el marcador de setup de la preparación | H01; Docker early |
| M02 | Sembrar también el marcador de colección | H01 ejecuta el fixture mutado; H02 prueba la precondición migrada de forma independiente |
| M03 | Volver a `[[ ]]` en precondición | H02 en 3.2; H14 en ambos |
| M04 | Volver a `[[ ]]` en confirmación | H10 en 3.2; H14 en ambos |
| M05 | Quitar status de inspección inicial | H03 |
| M06 | Quitar status de inspección final | H11 |
| M07 | Quitar comparación de orden | H09 |
| M08 | Quitar el conteo exacto de remove de tick 1, conservando add y máscara | H08/H09 |
| M09 | Quitar confirmación | H10 |
| M10 | Quitar comparación con `done` | H11 |
| M11 | Quitar comparación de conteos tras tick 2 | H13 |
| M12a/M12b | Quitar retorno/status del ayudante de tick 1, por separado | H04 |
| M13a/M13b | Quitar retorno/status del ayudante de tick 2, por separado | H12 |
| M14 | Volver a lanzar tick 1 dentro del bucle | H05/H06/H14 sobre la copia mutada |
| M15 | Restaurar calendario `*/5` | H01/H14 |
| M16 | Quitar tolerancia del log inexistente | H05 |
| M17 | Quitar status de inspección de tick 2 | H12 |
| M18 | Vaciar o duplicar una sección extraída | H00: rechazo estructural esperado del extractor, con motivo acreditado |

M03/M04 son equivalentes por efecto bajo bash 5.x: sus aserciones siguen fallando allí. La detección conductual pertinente es la de bash 3.2; la guardia textual aporta protección de forma en ambos. Esta distinción se deja escrita en el Registro.

Precisiones medidas el 24-11-2026: M02 cambia la preparación física, que ejecuta H01; H02 conserva sus propias respuestas controladas y no se atribuye la captura de ese fixture. M08 aplica una variante representativa a la comparación de remove; no acredita mutaciones separadas de los otros dos conteos.

## Límites de la cobertura

El replay prueba las aserciones reales con respuestas controladas. La prueba de fixture usa el setup real, pero no el boot real del supervisor. Ninguna de las dos sustituye la [matriz Docker y la CI](evidence-protocol.md). No se modifica código de producto para facilitar estos oráculos.
