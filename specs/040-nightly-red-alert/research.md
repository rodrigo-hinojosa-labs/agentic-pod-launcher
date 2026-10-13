# Research: Una noche en rojo del nightly le llega a alguien

Fase 0 de `/speckit-plan` para `specs/040-nightly-red-alert/spec.md`. Cada decisión lleva su razón y las alternativas descartadas; lo medido dice cómo y cuándo (12-10-2026, en el Mac con `gh` 2.102.0 contra el repositorio `rodrigo-hinojosa-labs/agentic-pod-launcher`) y lo que necesita una compuerta del operador queda marcado como **[COMPUERTA]**.

## Resumen de mediciones

| Id | Qué se midió | Resultado | Cómo |
|---|---|---|---|
| M1 | Subcomandos y banderas de `gh issue` | Existen todos los que usa el script (R8) | `gh issue <sub> --help` en 2.102.0 |
| M2 | Campos JSON de `gh issue list` | `number state stateReason title body labels assignees createdAt updatedAt closedAt comments url` | `gh issue list --json` |
| M3 | ¿Es asignable el mantenedor? | Sí: `GET /repos/{r}/assignees/rodrigo-hinojosa` responde 204 | `gh api -i` |
| M4 | Propietario del repositorio y permisos por defecto del token | Organización `rodrigo-hinojosa-labs`; `default_workflow_permissions: read` | `gh api repos/{r}` y `actions/permissions/workflow` |
| M5 | ¿Hay en el historial algún job reportado como `timed_out` o por tiempo agotado? | No hay muestra: 18 corridas `cancelled` en `tests` y `shellcheck` (cancelación por `concurrency`, 16 y 2) y ninguna `timed_out`, 417 corridas leídas | API de corridas, 5 páginas |
| M6 | Historial del nightly | 158 corridas programadas: 155 rojas y 3 verdes; inicio entre 05:30Z y 17:17Z | paginación completa (spec, Contexto) |
| M7 | Cómo reporta la plataforma un job que agota `timeout-minutes` | **[COMPUERTA]** sin medir; se mide con `trial_outcome=timeout` (R7) | corrida de ensayo |
| M8 | ¿Le llega de verdad la notificación al asignado cuando el issue lo crea el token del workflow? | **[COMPUERTA]** sin medir; la confirma el mantenedor (SC-009) | corrida de ensayo, confirmación humana |
| M9 | ¿Acepta el token del workflow crear etiquetas e issues con `issues: write` en esta organización? | **[COMPUERTA]** sin medir; la política de la organización podría limitarlo | corrida de ensayo |

## R1. Dónde vive la lógica del aviso

**Decisión**: un job aparte, `alert`, con `needs: e2e` e `if: always() && (...)`, y la lógica en un script, `.github/scripts/nightly-alert.sh`, que el job invoca con el entorno ya resuelto. El job lista `permissions: {contents: read, issues: write}`; el job `e2e` y el workflow conservan `contents: read`.

**Razón**:
- El permiso `issues: write` queda fuera del job que ejecuta el código de los tests (`e2e`), que es lo que pide FR-013.
- Un archivo `.sh` bajo `.github/` entra en el `find` del job `shellcheck` de CI (excluye solo `./.git`, `./scripts/vendor` y `./tests`); un `run:` embebido en YAML no se lintea.
- Un script se ejecuta en la suite del host con un `gh` falso, varias veces y con estado, que es lo que exige FR-014.
- Va fuera de `scripts/` porque FR-017 prohíbe tocar esa ruta.
- **FR-013 no necesita enmienda**: el único permiso nuevo es `issues: write`. `contents: read` ya es el del workflow, y al fijar `permissions` en un job hay que repetirlo para poder hacer el checkout que trae el script.

**Alternativas descartadas**:
- Un paso final en el job `e2e`: le daría `issues: write` al job que corre los tests (rechazado por FR-013).
- Un `run:` embebido de unas 60 líneas, como en 039: sin lint de CI y más difícil de probar con casos de varias ramas.
- Un workflow reutilizable (`workflow_call`): más superficie y más archivos que probar para el mismo resultado.

## R2. Cómo pasan los datos de la suite al aviso sin tocar el paso de la suite

**Decisión**: un paso final del job `e2e`, `collect` (`if: always()`, id `collect`), que llama a `nightly-alert.sh collect` y publica tres salidas del job: `failed_step`, `summary` y `failed_tests`. El paso fallido sale de `toJSON(steps)` (el primer id cuyo `outcome` es `failure` o `cancelled`; se pasa por una variable de entorno); el resumen y los nombres salen de `e2e.tap`. Los pasos del job ganan un `id` con un nombre legible (`verify_deps`, `run_suite`…) y no cambian de nombre ni de texto.

**Razón**: los tests S1 a S6 de 039 ejecutan el texto del paso `Run docker-e2e suite` tal cual; no tocar ese texto los deja valiendo sin reabrirlos. No hay acciones nuevas (`upload-artifact`/`download-artifact`) ni el permiso `actions: read`. Las salidas del job están disponibles para un job dependiente con `if: always()` aunque el job termine en rojo.

**Riesgo y cobertura**: `collect` recalcula `total/executed/skipped/failed` con los mismos tres patrones del paso de la suite; una prueba de **paridad** ejecuta el paso real de la suite (con un `bats` falso) y `collect` sobre el mismo TAP y exige la misma cadena. Si el paso de la suite no llegó a correr, no hay `e2e.tap` y el aviso dice "sin resumen" (US1, escenario 2).

**Alternativas descartadas**: subir `e2e.tap` como artefacto (dos acciones de terceros nuevas y más superficie); la API de jobs (`actions: read`, un permiso nuevo); hacer que el paso de la suite escriba a `$GITHUB_OUTPUT` (cambia el texto congelado de 039 y obliga a reabrir S1 a S6).

## R3. Dónde va el oráculo y qué cubre

**Decisión**: archivo nuevo `tests/nightly-alert.bats` con fixtures en `tests/fixtures/nightly-alert/` (el `gh` falso con estado, ejemplos de `toJSON(steps)` y TAP). No se edita `tests/ci-workflows.bats`: el barrido R3 de 039 ya revisa todos los `run:` de todos los workflows, así que los nuevos pasos entran solos al ratchet.

**Razón**: separa el oráculo de 040 del de 039 y evita reabrir un archivo cuyos 14 tests están congelados por sus mutaciones. Los helpers que necesita (`_has`, `_lacks`, extraer un `run:` con `yq`, ejecutar con SIGPIPE restablecido) se copian con un comentario que apunta a su origen; mover los de 039 a `helper.bash` cambiaría una superficie compartida por toda la suite.

**Cobertura**: los nueve casos de FR-014 (rojo nuevo, rojo repetido, verde tras rojo, verde sin aviso previo, aviso que falla, cancelada, cierre manual que reabre, corrida manual que no mueve el real, nueva racha tras un verde), más estructura del workflow, cotas, texto inerte, idempotencia, paridad con la suite, independencia de SIGPIPE y el barrido de consumidores que cierran el pipe antes de tiempo sobre el propio script. Detalle en `contracts/alert-oracle.md`.

**Lista blanca de banderas**: el `gh` falso solo acepta las banderas que M1 verificó en el `gh` real; una bandera inventada hace fallar el test, así que el oráculo no puede aprobar un script que el `gh` real rechazaría.

## R4. Identidad del issue de la racha y cómo distinguir quién lo cerró

**Decisión**: la identidad es una **etiqueta** (`nightly-red`; `nightly-red-trial` en el ensayo) más un título fijo. El script toma el issue más reciente con esa etiqueta, de cualquier estado: `gh issue list --label L --state all --limit 1 --json number,state,body,url`. La primera línea del cuerpo es un marcador legible por máquina: `<!-- nightly-red:v1 state=open|resolved total=N first=YYYY-MM-DD -->`. Cuando el mecanismo cierra el issue tras un verde, reescribe el marcador con `state=resolved` antes de cerrar; si una persona lo cierra, el marcador sigue en `state=open`.

**Razón**: un issue cerrado con `state=open` es un cierre manual a mitad de racha (se reabre, FR-008) y uno cerrado con `state=resolved` pertenece a una racha terminada (la siguiente abre uno nuevo). El marcador viaja con el issue y no necesita más llamadas a la API.

**Alternativas descartadas**: `stateReason` (una persona también puede cerrar como "completed", así que no distingue); el evento de cierre de la línea de tiempo (llamadas extra y permisos de lectura de eventos); un comentario marcador (obliga a listar comentarios en cada corrida); buscar por título solamente (frágil ante ediciones).

## R5. Cotas

**Decisión**: hasta 20 nombres de test por aviso, cada uno recortado a 120 caracteres con `...`, y si hay más se agrega `... y N mas` (sin tilde: el cuerpo es ASCII); hasta 10 filas de detalle de noches en el cuerpo; el total acumulado va en el marcador; si el cuerpo superara los 60.000 caracteres se recortan primero las filas de detalle. Un comentario por noche (una línea) avisa de la noche nueva.

**Razón**: la API limita el cuerpo y los comentarios a 65.536 caracteres (límite documentado, no medido aquí); 20 nombres de 120 caracteres son unos 2,4 KB, lejos del tope; con 155 noches seguidas, 155 filas habrían sido ilegibles (FR-003).

## R6. El mecanismo de ensayo

**Decisión**: dos entradas de `workflow_dispatch` en el mismo workflow: `alert_trial` (booleana, `false` por defecto) y `trial_outcome` (`red`, `green` o `timeout`). Con `alert_trial`, el paso de la suite se salta (`if: ${{ !inputs.alert_trial }}`) y un paso `simulate` produce el resultado pedido: `red` escribe un `e2e.tap` con un fallo y sale con 1; `green` escribe un `e2e.tap` sin fallos; `timeout` duerme más que el tope del job, que en ese caso vale 1 minuto (`timeout-minutes: ${{ (inputs.alert_trial && inputs.trial_outcome == 'timeout') && 1 || 30 }}`; en las corridas programadas y manuales normales `inputs` no define esas claves y el valor es 30). El job `alert` corre en modo ensayo con otra etiqueta y otro título (`[ensayo]`), de modo que **nunca toca el aviso real**. Una corrida manual normal no abre ni mueve nada (FR-011): el job `alert` ni siquiera arranca (`if` del job) y el script, además, lo rechaza por su cuenta.

**Razón**: la evidencia de FR-016 sale del **mismo archivo de workflow que se mergea**, con el mismo `needs`, el mismo `if` y las mismas salidas; una simulación en un workflow aparte no ejercitaría ese cableado. Cada corrida de ensayo dura cerca de un minuto en vez de los 15 de la suite. Por la misma razón, cualquier cambio del script o del workflow posterior a E1 obliga a repetir E1 a E6, o a justificar por escrito que no toca esos caminos. Las corridas programadas solo ocurren sobre la rama por defecto, así que no hay otra forma de demostrar el aviso desde la rama de trabajo.

**Costo declarado**: el workflow de producción carga con tres condicionales de ensayo y dos entradas; se documentan en `contracts/alert-workflow.md` y un test estructural los fija. La rama `schedule` de la condición del job `alert` solo la ejerce el oráculo del host y la primera noche roja real: es una limitación que se declara en la documentación (FR-018).

## R7. Qué cuenta como rojo y cómo se reporta un tiempo agotado

**Decisión (regla por defecto)**: `needs.e2e.result` = `success` es verde; `failure` es rojo; `cancelled` y `skipped` no hacen nada (FR-007), pero el script siempre imprime una anotación con el valor recibido para que el log lo muestre. **[COMPUERTA]** M7 mide en una corrida de ensayo `trial_outcome=timeout` qué valor entrega la plataforma:

- **Si es `failure`**: no hay nada que cambiar; FR-001 y FR-007 son compatibles tal como están.
- **Si es `cancelled`**: FR-007 se tragaría un rojo real. Entonces se agrega una regla (con su test en ROJO antes) que cuenta como rojo una cancelación cuando el job `e2e` consumió casi todo su tope. El tiempo transcurrido se obtiene del propio job `e2e` (un paso inicial que registra la hora de inicio como salida) y, si la salida no llega porque la plataforma mató el job antes del paso final, de la API de jobs, lo que exigiría `actions: read` y **sí** enmendaría FR-013 (se diría en el plan y en el spec). En esta rama FR-007 también se enmienda, con la salvedad de que una cancelación por tiempo agotado cuenta como rojo (tarea T082).
- Si la plataforma devolviera un valor distinto de los cuatro conocidos, el script lo trata como "sin acción" y lo anota.

**Por qué hasta entonces es seguro**: una cancelación manual de la corrida programada es rarísima; un tiempo agotado que se reportara como cancelado es el caso que importa, y queda medido antes de merge.

## R8. Banderas de `gh` verificadas (M1, gh 2.102.0)

| Uso | Comando y banderas |
|---|---|
| Buscar el último aviso | `gh issue list --label L --state all --limit 1 --json number,state,body,url` |
| Crear | `gh issue create --title T --label L --assignee A --body-file F` |
| Comentar | `gh issue comment N --body-file F` |
| Actualizar el cuerpo | `gh issue edit N --body-file F` |
| Reabrir | `gh issue reopen N --comment C` |
| Cerrar | `gh issue close N --reason completed --comment C` |
| Crear la etiqueta | `gh label create L --color C --description D` (se ignora el error si ya existe) |

Todas existen en 2.102.0 con esas banderas. El script usa `--json` y filtra con `jq` por su cuenta (no usa `--jq`), de modo que el `gh` falso solo debe producir JSON. El token llega en `GH_TOKEN` y el repositorio en `GH_REPO` (no se usa `--repo`). El `gh` del runner no está fijado: una bandera retirada en el futuro la cazaría la evidencia real y la lista blanca del falso se actualiza al subir la versión de referencia.

## R9. El aviso no puede cambiar el veredicto (FR-009)

**Decisión**: tres capas. (1) El script nunca sale con error: cada llamada a `gh` pasa por una función que captura el estado y, si falla, imprime `::warning::` y sigue; el final es `exit 0`. (2) El paso `notify` lleva `continue-on-error: true`. (3) El job `alert` tiene `timeout-minutes: 5`.

**Razón**: la conclusión de una corrida es la peor de las de sus jobs; si el job `alert` fallara en una noche verde, la corrida saldría roja por una causa que no es la suite, el mismo defecto que corrigió 039 con otra forma. Un test estructural exige `continue-on-error: true` y otro ejecuta el script con cada llamada a `gh` fallando (casos de FR-009).

**Riesgo asumido**: si el propio job `alert` no llega a arrancar (runner caído), la corrida podría quedar marcada como fallida sin que sea culpa de la suite. Es una limitación remota, declarada, y no se mitiga.

## R10. Idempotencia y reintentos

**Decisión**: cada noche queda registrada con el id de la corrida en su fila del cuerpo (el texto `[run <id>](`). Si el script ve una fila con el mismo id, no suma la noche ni vuelve a comentar. El comentario de cierre por verde y el cambio de marcador también son idempotentes (si el issue ya está cerrado, no hace nada).

**Razón**: Principio IV; reintentar el job `alert` desde la interfaz no debe contar dos veces una noche.

## R11. Concurrencia

El grupo `docker-e2e` (con `cancel-in-progress: false`) ya serializa las corridas completas, incluido su job `alert`; una corrida manual cercana espera a que termine la programada. No se cambia. El resultado del aviso es el mismo en cualquier orden porque cada corrida lee el estado del issue al empezar.

## R12. Permisos del token y de la organización

El repositorio pertenece a una organización y su permiso por defecto del token es `read` (M4); un `permissions` explícito en el job es lo que concede `issues: write`. La política de la organización podría limitarlo: eso solo lo muestra una corrida real (M9, **[COMPUERTA]**). Si falló, el aviso del propio script lo anota y la corrida conserva su color (R9).

## R13. Cobertura del lint

El job `shellcheck` de CI lintea `./.github/scripts/nightly-alert.sh` porque su `find` solo excluye `./.git/*`, `./scripts/vendor/*` y `./tests/*`. El plan lo verifica en local con el comando exacto del job antes de cada commit. Los nuevos `run:` del workflow son de una línea (invocan al script), así que el barrido R3 de 039 los acepta sin excepciones.

## R14. Reglas de shell que el script debe cumplir

Bash 3.2 y 5.x (sin `mapfile`, arreglos asociativos ni `${v,,}`); ningún pipe cuyo consumidor cierre antes que el productor (`head`, `grep -q`/`-m`, `sed Nq`, `awk … exit`), con la misma regla que el ratchet de 039; capturar la salida de `gh` en una variable y decidir con `case`; las cargas grandes por archivo, no por argv ni entorno (el cuerpo del issue va con `--body-file`); `printf` en lugar de `echo` para texto con barras; y un test de independencia de SIGPIPE (N17: el arnés fija la disposición con `SIGPIPE_MODE`, por defecto `ignore` como el runner, y el caso se compara en ambas; la sonda del arnés evita que el test pase sin que la señal llegue al script).

## R15. El texto no es de fiar (FR-004)

Los nombres de test vienen del log y pueden contener `@usuario`, `#123`, comillas invertidas o `-->`. El script los pasa por una función que quita caracteres de control, cambia las comillas invertidas por apóstrofos, neutraliza `<!--` y `-->`, y los coloca **dentro de un bloque de código cercado**, donde GitHub ni menciona ni enlaza. El marcador de la primera línea no se arma jamás con texto del log. Un test con nombres hostiles lo exige.

## R16. Cómo recoger evidencia de las corridas

`gh api repos/<repo>/actions/jobs/<id>/logs` exige `--allow-escape-sequences` en gh 2.102.0; sin ello baja un archivo de 99 bytes y los conteos dan 0 en silencio. Siempre se verifica que el archivo contenga una línea esperada (por ejemplo `nightly-alert`) antes de contar.

## Preguntas que quedan abiertas (todas con compuerta)

1. M7: cómo reporta la plataforma un job que agota su tope (decide R7).
2. M8: si la notificación al asignado le llega al mantenedor sin abrir Issues ni Actions (SC-009).
3. M9: si la organización permite al token del workflow crear etiquetas e issues.

Ninguna bloquea el oráculo ni el script, que se desarrollan con el `gh` falso; las tres se contestan en la secuencia de ensayo de `quickstart.md`.
