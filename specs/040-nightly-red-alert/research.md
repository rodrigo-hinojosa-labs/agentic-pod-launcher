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
| M8 | ¿Le llega de verdad la notificación al asignado cuando el issue lo crea el token del workflow? | **MEDIDO el 14-10-2026 (E1, run 38497730831): NO llegó al operador.** GitHub sí la creó (`reason: assign` en la bandeja web, 21 s después de crear el issue #106), pero no apareció donde el operador mira (esperaba Telegram); no se sabe si su correo o la aplicación móvil están activos. Origen de la enmienda 1 (R17 a R24) | corrida de ensayo, confirmación humana y `gh api --method GET notifications` |
| M9 | ¿Acepta el token del workflow crear etiquetas e issues con `issues: write` en esta organización? | **MEDIDO el 14-10-2026 (E1): sí.** La corrida creó la etiqueta `nightly-red-trial` y el issue #106 con el token del workflow | corrida de ensayo |
| M10 | Forma de los errores de la API de Telegram | Con un token falso pero bien formado: HTTP 401 y `{"ok":false,"error_code":401,"description":"Unauthorized"}`; con un token mal formado: HTTP 404 y `{"ok":false,"error_code":404,"description":"Not Found"}`; el POST con `application/x-www-form-urlencoded` llega hasta la comprobación del token | `curl` contra `api.telegram.org` con valores falsos, sin credenciales ni efectos |
| M11 | Qué dice la documentación oficial de Telegram | URL `https://api.telegram.org/bot<token>/METHOD_NAME`; GET y POST; parámetros por query, `application/x-www-form-urlencoded`, JSON o multipart; respuesta con `ok`, `result` o `description` y `error_code`, y a veces `parameters`; ejemplo de token `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`; Bot API 7.0 reemplazó `disable_web_page_preview` por `link_preview_options` en `sendMessage`; límites de la FAQ: cerca de 1 mensaje por segundo por chat, 20 por minuto en un grupo y unos 30 por segundo en difusión, con errores 429 al excederlos. **No verificado en la documentación** (la página es demasiado grande para la herramienta de lectura): la tabla de parámetros de `sendMessage` (`disable_notification`, límite de 4096 caracteres del texto) y `retry_after` | lectura de `core.telegram.org/bots/api`, `/bots/faq` y `/bots/api-changelog` |
| M12 | Orden de `gh issue list --label ... --limit 1` | Con `--label` `gh` usa la API de búsqueda (consulta GraphQL `IssueSearch`, `last: $limit`, sin `sort:`) y en un repositorio público real (`cli/cli`, etiqueta `bug`) devuelve el issue más nuevo primero | consulta de solo lectura del 13-10-2026 |

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

## R17. Por qué un empuje por Telegram (medición M8, enmienda 1)

**Decisión** (operador, AskUserQuestion, 14-10-2026): el issue sigue siendo el estado y el historial de la racha, y el job `alert` envía además un mensaje por Telegram con un bot nuevo solo para la CI.

**Razón**: la premisa del clarify del 12-10-2026 ("GitHub notifica de forma activa al asignado") se midió y no se cumplió para este operador: la notificación existe en la bandeja web de GitHub (21 s después de crear el issue) pero él no la ve; mira Telegram, donde ya vive su flota de agentes. El objetivo de la feature es que un rojo le llegue donde mira; el issue solo no lo logra.

**Alternativas descartadas**: (B) dejar solo el issue y pedirle que active el correo o la aplicación móvil de GitHub para la organización: costo cero de código, pero no hay garantía de que mire esos canales y el riesgo es repetir los 155 rojos sin aviso; se ofreció y no se eligió. (C) esperar a que revise su configuración: aplaza el problema.

**Consecuencia**: cambian FR-012, FR-013, SC-007 y SC-009 y entran FR-020 a FR-023 y SC-010; la evidencia de E1 a E6 se repite sobre el texto que se mergee (regla de T084).

## R18. API de Telegram: qué se usa y qué se verificó

Se usa `POST https://api.telegram.org/bot<token>/sendMessage` con `application/x-www-form-urlencoded` y los campos `chat_id`, `text`, `link_preview_options` (`{"is_disabled":true}`, para que los enlaces de GitHub no agreguen una vista previa; reemplazó a `disable_web_page_preview` en Bot API 7.0) y, solo en la recuperación, `disable_notification=true`. Sin `parse_mode`: el texto es plano y Telegram no interpreta formato, de modo que un nombre o una cadena del log no puede romper el mensaje. Verificado (M10 y M11): forma de la URL, métodos y tipos de contenido, forma de las respuestas, ejemplo de token y límites de frecuencia. **No verificado en la documentación**: el límite de 4096 caracteres y el parámetro `disable_notification`; el mensaje mide menos de 1000 caracteres y la primera entrega real (E1 repetido) confirma que Telegram acepta ambos campos.

**Límites**: el mensaje es de a lo sumo 6 líneas y se envía una vez por noche, muy por debajo del tope de unos 1 mensaje por segundo por chat.

## R19. Cómo se llama a `curl` sin el token en los argumentos

**Decisión**: el script escribe un archivo de configuración de `curl` en su directorio temporal privado (permisos 0600) con `url`, `data-urlencode` (el texto se lee de un archivo con `text@archivo`), `max-time`, `silent`, `show-error`, `output` y `write-out`, y ejecuta `curl -K archivo`. Los argumentos del proceso son solo `-K <ruta>`. El token vive únicamente en ese archivo, que el `trap EXIT` borra.

**Razón**: la petición del operador (el token no viaja por argv: la lista de procesos de la máquina lo mostraría) y la regla de CLAUDE.md de que las cargas no viajan por argumentos. El notificador de heartbeat del repo pasa el token en la URL por argv; aquí se hace mejor porque el runner comparte la máquina con el resto de los pasos.

**Defensa contra inyección en el archivo de configuración**: los dos secretos se validan con una expresión antes de escribirlos: token `^[0-9]{3,20}:[A-Za-z0-9_-]{20,80}$` (más laxo que un token real de 8 a 10 dígitos y 35 caracteres porque la documentación oficial muestra un ejemplo más corto) y chat id `^(-?[0-9]{1,20}|@[A-Za-z0-9_]{5,32})$`. Un valor con comillas, barras invertidas, espacios o saltos de línea no pasa y el empuje se omite con una advertencia que **no** repite el valor.

## R20. Secretos: lectura mínima

El script lee `TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID` una vez en variables del shell y los quita del entorno (`unset`): los procesos hijos que no los necesitan (`gh`, `jq`, `date`) no los heredan. Cualquier texto que se imprima y pudiera contener el token se pasa antes por una redacción que lo reemplaza por `***`. GitHub además enmascara en los logs los valores de los secretos. Alcance del riesgo: quien puede escribir en el repositorio puede, cambiando un workflow, leer los secretos; es igual que cualquier secreto de Actions y hoy ese acceso es del operador. Los secretos no están disponibles para `pull_request` desde forks, y el job `alert` solo corre con `schedule` y `workflow_dispatch`.

## R21. Cuándo y qué se envía

| Acción sobre el issue | Mensaje | Sonido |
|---|---|---|
| crear (primera noche) | `docker-e2e nightly EN ROJO`, noche 1 y fecha de inicio, paso, resumen, corrida y aviso | normal |
| actualizar (noche siguiente) | `docker-e2e nightly SIGUE EN ROJO`, noche N, paso, resumen, corrida y aviso | normal |
| reabrir (cierre manual) | `docker-e2e nightly SIGUE EN ROJO (aviso reabierto)`, noche N, paso, resumen, corrida y aviso | normal |
| cerrar (verde), solo si el aviso quedó cerrado | `docker-e2e nightly VOLVIO A VERDE`, cuántas noches duró la racha y desde cuándo, corrida y aviso | silencio |
| solo reescribir el marcador, o ninguna | nada | |
| no se pudo consultar el issue en un rojo | `docker-e2e nightly EN ROJO`, paso, resumen y solo el enlace de la corrida | normal |

El mensaje de ensayo antepone `[ensayo] ` a la primera línea. Todo es ASCII sin tildes (como el resto de los textos de CI del repositorio), de 2 a 6 líneas según los datos (de 4 a 6 en los casos normales), sin nombres de tests y con el texto del log saneado como el cuerpo del issue. Si el marcador del issue es inválido no se conoce el número de noche y la línea de racha se omite.

## R22. Fallas y reintentos

**Decisión**: un solo intento por mensaje, con `--max-time 15`. Cualquier falla (no hay secretos, formato inválido, `curl` con error, HTTP distinto de 200, `ok` distinto de `true`) deja un `::warning::` con el motivo (el código HTTP y la `description` de Telegram, saneada y sin el token) y el script sigue; el código de salida no cambia.

**Razón**: el empuje se repite cada noche roja (FR-020) y el issue conserva la noche; un segundo intento agrega latencia y casos de prueba para una falla que el siguiente rojo corrige. **Costo aceptado**: relanzar el job `alert` no reenvía un mensaje que falló, porque el issue ya registró la noche y el empuje sigue a la acción sobre el issue; el log de la primera ejecución dice qué pasó.

## R23. El oráculo del empuje

**Decisión**: probar el script con el `curl` **real** contra un servidor HTTP local de la biblioteca estándar de Python (`tests/fixtures/nightly-alert/tg-server.py`, en `127.0.0.1` y un puerto libre, que registra cada petición y responde según un modo: `ok`, `ok-false`, `unauthorized`, `chat-not-found`, `rate-limit`, `server-error`, `hang`), con un `curl` espía delante en el `PATH` (`tests/fixtures/nightly-alert/curl`) que anota los argumentos y delega en el real. Dos costuras de prueba que el workflow no define: `TELEGRAM_API_BASE` (por defecto `https://api.telegram.org`, el mismo mecanismo que `NOTIFY_TELEGRAM_API_BASE` del notificador de heartbeat) y `TELEGRAM_MAX_TIME` (por defecto 15).

**Razón**: lo que un `curl` falso no puede asegurar es justo lo que más puede fallar aquí: la gramática del archivo de configuración, la codificación de `text@archivo` y la lectura de `write-out`. Con el `curl` real contra un servidor local el oráculo comprueba la petición HTTP que de verdad saldría. El espía responde a la pregunta del token en los argumentos. Python 3 ya es una dependencia de la suite (`apply-telegram-patches.bats`) y está en los runners de macOS y de Ubuntu. El `gh` falso gana una anotación `env_leak` para comprobar que el token no llega a los hijos.

**Alternativas descartadas**: un `curl` falso en bash (no ejercita el `curl` real); sustituir la función de envío con un doble dentro del script (el oráculo dejaría de ejecutar el texto real); `nc` o `socat` (no portables entre macOS y Ubuntu).

## R24. Aprovisionamiento: lo que hace el operador y lo que el agente nunca ve

1. En Telegram, con @BotFather, `/newbot`: nombre y usuario del bot nuevo de la CI; BotFather entrega el token (no pegarlo en ningún chat con el agente).
2. Abrir el chat con el bot nuevo y enviarle `/start`: un bot no puede iniciar la conversación.
3. Obtener el chat id con `getUpdates` leyendo el token sin eco (por ejemplo `read -rs T; printf 'url = "https://api.telegram.org/bot%s/getUpdates"\n' "$T" | curl -sS -K - | jq '.result[].message.chat.id'; unset T`: la configuración entra por la entrada estándar, así que el token no queda en la línea de comandos que `ps` muestra, igual que hace el script).
4. Definir los secretos sin que el valor pase por ningún archivo ni por el historial: `gh secret set TELEGRAM_BOT_TOKEN --repo rodrigo-hinojosa-labs/agentic-pod-launcher` y `gh secret set TELEGRAM_CHAT_ID --repo rodrigo-hinojosa-labs/agentic-pod-launcher` (piden el valor por la entrada estándar).
5. Comprobar que existen: `gh secret list --repo rodrigo-hinojosa-labs/agentic-pod-launcher` (solo muestra los nombres).

El agente no lee los valores, no los pide y no los escribe en ningún archivo; solo verifica con `gh secret list` que los nombres existen.

## R25. Tope de tiempo de las llamadas a `gh` (hallazgo de la revisión independiente)

**Hallazgo**: `gh_run` no tenía tope propio. Si `gh` acepta la llamada y no responde, el único límite es el `timeout-minutes: 3` del paso, y el empuje va después de todas las llamadas: la noche roja quedaba sin issue y sin mensaje, el silencio que la feature existe para terminar. FR-020 ("un rojo no se pierde porque GitHub falle") cubría un `gh` que falla, no uno que se cuelga.

**Decisión**: cada llamada a `gh` corre en segundo plano y el script la vigila cada 50 ms; a los `GH_CALL_TIMEOUT` segundos (30 por defecto) la corta con `kill`, y después de `GH_BUDGET` segundos del arranque (100 por defecto) ya no inicia ninguna. El peor caso es ~30 s por llamada con a lo sumo cuatro o cinco llamadas, repartidas dentro de los 100 s de presupuesto, más los 15 s de `curl`: unos 145 s, por debajo de los 180 del paso. Una llamada cortada se trata como cualquier otra falla de `gh` y una noche roja sin `list` entra por el camino `rojo-sin-aviso` ya probado.

**Alternativas descartadas**: `timeout` de coreutils (macOS no lo trae y las pruebas corren allí; ubuntu sí); una trampa de `TERM` que envíe el mensaje mínimo (en bash 3.2 la trampa espera a que termine el proceso en primer plano, y la gracia que da el runner antes de `KILL` no está medida); enviar el empuje antes que el issue (contradice "después de la acción sobre el issue" y no sabría el tipo de mensaje ni la racha).

**Fuera de alcance, declarado**: que una falla del empuje en una noche roja deje solo un `::warning::` en un job verde (token revocado, bot bloqueado) es el estado de la medición M8, y el único rastro está en el log de Actions. FR-021 pide exactamente una advertencia; anotar el motivo en el comentario del issue o en el resumen del paso queda como mejora candidata, no se hace aquí.

## Preguntas que quedan abiertas (todas con compuerta)

1. M7: cómo reporta la plataforma un job que agota su tope (decide R7).
2. ~~M8 y M9~~ **medidas el 14-10-2026** (E1): M9 sí; M8 no llegó, y de ahí la enmienda 1 (R17).
3. M8 repetido para Telegram: que el mantenedor reciba el mensaje de Telegram sin abrir Issues ni Actions (SC-009 reformulado) y que Telegram acepte `disable_notification` y `link_preview_options` (R18). Necesita que el operador cree el bot y los dos secretos (R24).

Ninguna bloquea el oráculo ni el script, que se desarrollan con el `gh` falso (y, para el empuje, con el servidor local de R23); las que quedan se contestan en la secuencia de ensayo de `quickstart.md`.
