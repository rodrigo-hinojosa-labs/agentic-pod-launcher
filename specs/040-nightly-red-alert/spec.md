# Feature Specification: Una noche en rojo del nightly le llega a alguien

**Feature Branch**: `040-nightly-red-alert`

**Created**: 2026-10-12

**Status**: Draft

**Input**: El job nocturno `docker-e2e` estuvo en rojo en las 155 corridas programadas anteriores a 039 (07-05 a 09-10-2026) y ningún aviso lo hizo notar: se descubrió al revisar la CI después de un merge. 039 hizo que el semáforo signifique algo, pero un semáforo solo sirve si alguien lo mira. Esta feature hace que una noche en rojo deje un aviso visible fuera de la pestaña Actions de GitHub, que una racha de rojos sea un solo aviso, que el aviso se apague solo cuando vuelve el verde y que el aviso jamás cambie el veredicto de la corrida.

## Contexto

**Qué dejó hecho 039.** El workflow `docker-e2e (nightly)` corre por `schedule` y por `workflow_dispatch` en `ubuntu-latest`, con `permissions: contents: read`, sin secretos y con un tope de 30 minutos por job. Desde el merge de 039 (PR #102, 09-10-2026) ejecuta de verdad los 48 e2e en unos 15 minutos, y una corrida en la que no se ejecutó ningún test sale en rojo. Las tres corridas programadas siguientes pasaron 48 de 48: runs 38047040835 (10-10-2026), 38135162982 (11-10) y 38252436900 (12-10), todas sobre `13cafc3`.

**Lo que 039 no resolvió, medido el 12-10-2026 con la API de GitHub.** El historial del workflow expone 158 corridas programadas, de la primera registrada (07-05-2026) a la del 12-10-2026: **155 terminaron en rojo y 3 en verde, y las 3 verdes son las posteriores a 039.** La primera corrida registrada ya estaba en rojo, así que mientras duró el defecto el nightly no pasó nunca. La causa (`exit 141`, SIGPIPE) está medida para las corridas de 30-09 a 07-10-2026 y para una nota de CI del 26-07-2026; en las demás solo consta la conclusión. El rojo se descubrió al revisar la CI después del merge de 038, no por un aviso, y 039 dejó "notificaciones o alertas de un nightly rojo" fuera de alcance. Un semáforo que significa algo solo sirve si alguien lo mira.

**Cómo llega hoy un rojo.** Solo entrando a la pestaña Actions o, quizá, por las notificaciones nativas de GitHub. **Medido el 14-10-2026 en la corrida real E1 (run 38497730831):** GitHub sí crea la notificación de la asignación del issue (`reason: assign` en la bandeja web, 21 segundos después de crearlo), pero al operador no le llegó nada donde mira, y esperaba Telegram, que GitHub no usa; no se sabe si su correo o la aplicación móvil de GitHub están activos para esta organización (la API no expone esas preferencias). Por eso el aviso por issue se complementa con un empuje por Telegram (clarificado el 14-10-2026).

**Cuándo corre.** El cron declara `0 5 * * *`, pero las 158 corridas programadas empezaron entre las 05:30Z y las 17:17Z (las 20 más recientes, entre las 09:46Z y las 12:58Z). El aviso no puede depender de una hora fija.

**Entorno.** El repositorio es público y tiene Issues habilitados; empujar cambios a `.github/workflows/` exige el scope `workflow` del token de `gh`, que ya lo tiene. Como el repositorio es público, lo que el aviso contenga puede leerlo cualquiera.

## Clarifications

### Session 2026-10-12

- Q: ¿Por qué canal debe llegar el aviso de una noche en rojo? → A: Un issue del propio repositorio. No necesita secretos nuevos y la ampliación de permisos queda acotada al job que publica el aviso. Telegram u otro canal quedan descartados. *(Superada en este punto el 14-10-2026: la medición M8 mostró que la premisa de la segunda respuesta no se cumple para este operador y Telegram se agregó como empuje; ver la sesión de esa fecha.)*
- Q: ¿Cómo se asegura que el issue le llegue de forma activa al mantenedor y no quede solo en la lista de Issues? → A: Asignándolo al mantenedor: GitHub notifica a la persona asignada aunque no vigile el repositorio. Que la notificación llega se mide con una corrida real de prueba.
- Q: ¿Qué debe hacer una corrida manual (`workflow_dispatch`) con el issue cuando termina en rojo o en verde? → A: Nada: solo las corridas programadas abren, actualizan o cierran el issue. Consecuencia: como las corridas programadas solo ocurren sobre la rama por defecto, la evidencia real de FR-016 usa un aviso de ensayo separado del real, activado de forma explícita por la corrida manual.
- Q: Si alguien cierra el issue a mano mientras el nightly sigue en rojo, ¿qué debe pasar en la noche siguiente? → A: Se reabre ese mismo issue con un comentario que dice que la noche sigue en rojo y enlaza la corrida. Un issue cerrado por el propio mecanismo tras un verde pertenece a una racha terminada: la racha siguiente abre uno nuevo. Consecuencia: un verde posterior a un cierre manual también termina esa racha y deja el issue como historial (análisis del 12-10-2026).

### Session 2026-10-14

- Q: Tras la medición M8 de la corrida real E1 (run 38497730831, issue #106: GitHub creó la notificación de la asignación, `reason: assign` en la bandeja web a los 21 segundos, pero al operador no le llegó nada donde mira y esperaba Telegram), ¿cómo se resuelve el empuje del aviso? → A: El issue sigue siendo el estado y el historial de la racha, y se agrega un empuje por Telegram desde el job que lo publica (decidido por el operador el 14-10-2026). Enmienda FR-012, FR-013, SC-007 y SC-009 y obliga a repetir los ensayos E1 a E6, porque la evidencia vale para el texto que se mergea. La respuesta del 12-10-2026 que descartaba Telegram por exigir secretos queda superada: su premisa (que GitHub notifica de forma activa al asignado) se midió y no se cumplió para este operador.
- Q: ¿Qué bot envía el mensaje? → A: Un bot nuevo creado solo para la CI, con su token y el chat id como dos secretos de repositorio que pone el operador; rotarlo no toca a ningún agente.
- Q: ¿Con qué frecuencia debe enviar el empuje por Telegram durante una racha de noches en rojo? → A: Un mensaje por cada corrida programada en rojo (primera noche, noches siguientes y reapertura de un cierre manual) y otro cuando vuelve el verde. Va en paralelo al issue, que ya recibe un comentario por noche, y no necesita contadores. Costo aceptado: un mensaje diario mientras siga en rojo.
- Q: ¿Qué debe decir el mensaje de Telegram de una noche en rojo? → A: Conciso y con enlaces: texto plano de hasta 6 líneas (FR-022 fija el rango: de 2 a 6 según los datos, de 4 a 6 en los casos normales) con el estado (rojo, sigue en rojo con el número de noche, o verde), el paso que falló, la línea de resumen de la suite y los enlaces a la corrida y al issue. Sin nombres de tests: el detalle vive en el issue, y así el saneo del texto del log sigue en un solo lugar.
- Q: ¿Los mensajes de Telegram deben sonar o ir en silencio? → A: Los de noche en rojo y de reapertura suenan normal; el de recuperación va en silencio (la opción silenciosa de Telegram), porque el nightly puede empezar entre las 02:30 y las 14:17 hora de Santiago y una buena noticia no necesita despertar a nadie.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Una noche en rojo deja un aviso que se ve sin abrir Actions (Priority: P1)

Como mantenedor del launcher, quiero que cuando el nightly programado termine en rojo aparezca un aviso en un lugar donde yo ya miro, con lo mínimo para actuar, para enterarme el mismo día y no meses después por casualidad.

**Why this priority**: Es el valor central y la brecha que dejó 039: el nightly ya significa algo, pero hubo 155 noches seguidas en rojo sin que ningún aviso lo hiciera notar. Sin esto, la próxima regresión repite el mismo silencio.

**Independent Test**: Provocar un fallo en una corrida manual de ensayo sobre la rama de la feature, con un mecanismo explícito y revertible, y comprobar que aparece el aviso de ensayo con los cuatro elementos mínimos; el caso "rojo nuevo" del oráculo del host pasa.

**Acceptance Scenarios**:

1. **Given** una corrida programada cuya suite termina con al menos un test fallido, **When** la corrida concluye, **Then** existe un aviso fuera de Actions con el enlace a la corrida, el paso que falló, la línea de resumen de la suite (`e2e summary:`) y los nombres de los tests que fallaron.
2. **Given** una corrida programada que falla antes de llegar a la suite (instalación o verificación del entorno), **When** concluye, **Then** el aviso aparece igual, nombra el paso que falló y dice que no hay resumen de la suite, en vez de omitirlo o inventarlo.
3. **Given** una corrida programada que termina en rojo porque no se ejecutó ningún e2e (la guarda de verde vacío de 039) o porque agotó el tiempo del job, **When** concluye, **Then** avisa igual que cualquier otro rojo.
4. **Given** una corrida programada en rojo y los dos secretos del empuje definidos, **When** concluye, **Then** el mantenedor recibe en Telegram un mensaje de texto plano con el estado, el paso que falló, la línea de resumen de la suite y los enlaces a la corrida y al issue, sin haber abierto Actions ni Issues (FR-020, FR-022, SC-009).
5. **Given** una corrida programada en rojo sin los secretos del empuje, **When** concluye, **Then** el issue se publica igual y el log lleva un `::warning::` que dice que el empuje se omitió por falta de secretos (FR-021).

---

### User Story 2 - El aviso no puede cambiar el veredicto de la noche ni esconder su causa (Priority: P1)

Como mantenedor, quiero que la lógica de aviso sea incapaz de volver roja una noche verde o de tapar por qué una noche roja lo es, para que el color del nightly siga diciendo solo lo que dijo la suite.

**Why this priority**: Un aviso que pudiera romper el nightly repetiría por otra vía el defecto que corrigió 039: un paso de diagnóstico decidiendo el color. Es el mismo criterio que la constitución impone a los notificadores del heartbeat (principio IV: un notificador no puede tumbar lo que notifica).

**Independent Test**: Forzar que el mecanismo de aviso falle (permiso denegado, servicio caído) en una corrida verde y en una roja: la conclusión de cada una es la que dio la suite y el log dice que el aviso no pudo entregarse.

**Acceptance Scenarios**:

1. **Given** una corrida programada en verde, **When** el mecanismo de aviso falla, **Then** la corrida sigue en verde y el log dice que el aviso no pudo entregarse.
2. **Given** una corrida programada en rojo, **When** el mecanismo de aviso falla, **Then** la corrida sigue en rojo, el primer fallo de la corrida sigue siendo el paso de la suite que falló y el log dice que el aviso no pudo entregarse.
3. **Given** una corrida en rojo cuyo aviso se entregó, **When** se lee el log de la corrida, **Then** la causa del rojo se identifica igual que antes: el aviso agrega información y nunca reemplaza la del log.
4. **Given** una corrida en rojo en la que Telegram no responde o rechaza el mensaje, **When** concluye, **Then** el issue ya está publicado, la corrida conserva su color y el log lleva un `::warning::` con el motivo y sin el token (FR-009, FR-021).

---

### User Story 3 - Una racha de rojos es un solo aviso y se apaga sola con el verde (Priority: P2)

Como mantenedor, quiero que las noches rojas consecutivas actualicen el mismo aviso y que el aviso se resuelva solo cuando el nightly vuelve a verde, para que un aviso abierto signifique "hoy está en rojo" y pueda confiar en él sin cruzar datos con Actions.

**Why this priority**: Sin esto el aviso funciona pero se degrada: 155 noches rojas habrían sido 155 avisos que nadie lee, y un aviso que nunca se cierra deja de significar algo. Es lo que mantiene la señal útil con el tiempo.

**Independent Test**: Con un sustituto del servicio de issues de GitHub, simular tres noches rojas y una verde: queda un solo aviso con las tres noches y termina cerrado; en el repositorio real, la corrida verde posterior a la inducida lo resuelve.

**Acceptance Scenarios**:

1. **Given** un aviso abierto por una noche roja, **When** la siguiente corrida programada también termina en rojo, **Then** no se crea otro aviso y el abierto registra la nueva noche (enlace y fecha).
2. **Given** un aviso abierto, **When** una corrida programada termina en verde, **Then** el issue queda cerrado, con un comentario que enlaza a la corrida verde.
3. **Given** que no hay aviso abierto, **When** una corrida programada termina en verde, **Then** no se crea ni se modifica nada.
4. **Given** un issue que una persona cerró a mano mientras el nightly sigue en rojo, **When** llega la siguiente noche en rojo, **Then** se reabre ese mismo issue con un comentario que enlaza la corrida, en vez de tragarse el rojo en silencio o abrir otro.
5. **Given** un issue que el propio mecanismo cerró tras un verde, **When** llega una noche en rojo, **Then** se abre un issue nuevo para la nueva racha y el anterior queda cerrado como historial.
6. **Given** un issue que una persona cerró a mano durante una racha, **When** una corrida programada termina en verde y después llega una noche en rojo, **Then** el verde deja ese issue como historial (su marcador pasa a resuelto, sin reabrirlo ni comentarlo) y la noche en rojo abre un issue nuevo en vez de reabrir el viejo.
7. **Given** una corrida cancelada, **When** concluye, **Then** no crea, actualiza ni resuelve avisos: una cancelación no dice nada sobre el estado del nightly.
8. **Given** un aviso abierto, **When** una corrida programada termina en verde, **Then** además de cerrar el issue el mantenedor recibe un mensaje de recuperación en silencio que dice cuántas noches duró la racha; y **Given** una noche en rojo cuyo issue no cambia (la noche ya estaba registrada), **Then** no se envía otro mensaje (FR-020, FR-023).

---

### User Story 4 - La suite del host impide que el aviso se vuelva mudo sin que nadie lo note (Priority: P2)

Como mantenedor, quiero que la suite que ya corre en cada PR ejecute la lógica real del aviso contra un sustituto del servicio y falle si deja de comportarse, para que una edición del workflow no apague el aviso en silencio: un sistema de alertas que falla sin avisar es peor que no tenerlo.

**Why this priority**: Es la lección de 025 y 039: un chequeo que no puede fallar no es evidencia. Es el seguro que mantiene vivas las historias 1 a 3 cuando alguien edite el workflow.

**Independent Test**: `bats tests/` en el host, sin Docker ni red, contiene los casos nuevos; con el aviso retirado o roto por una mutación, al menos un caso cae.

**Acceptance Scenarios**:

1. **Given** el workflow con la lógica de aviso, **When** corre la suite del host, **Then** ejecuta el texto real de esa lógica contra un sustituto del servicio de issues de GitHub y verifica, como mínimo, rojo nuevo, rojo repetido, verde tras rojo, verde sin aviso previo, aviso que falla, corrida cancelada, cierre manual (que reabre), corrida manual (que no mueve el aviso real) y nueva racha tras un verde (que abre un issue nuevo), más el empuje por Telegram contra un sustituto del servicio: cada mensaje de FR-020, la omisión sin secretos, el fallo de Telegram y que el token nunca aparezca (FR-014, SC-010).
2. **Given** que se retira o se rompe cualquiera de las condiciones que el oráculo protege, **When** corre la suite del host, **Then** al menos un test cae.
3. **Given** que el oráculo no logra localizar o ejecutar la lógica del aviso, **When** corre, **Then** falla: nunca pasa en vacío.
4. **Given** bash 3.2, bash 5.x y runners que entregan SIGPIPE ignorada, **When** corre la suite, **Then** el oráculo pasa en todos.

---

### Edge Cases

- **Corrida manual (`workflow_dispatch`)**: una persona la lanzó a propósito y ya la está mirando, así que no mueve el issue (FR-011). Costo aceptado: tras arreglar un rojo, el issue sigue abierto hasta la siguiente noche en verde o hasta que alguien lo cierre.
- **Aviso de ensayo**: el aviso de ensayo (FR-016) nunca se mezcla con el real: tiene otra identidad, un ensayo no actualiza ni cierra el issue real y el real no cierra el de ensayo.
- **Rojo que viene de antes de la suite**: no hay `e2e summary:` ni tests fallidos; el aviso lo dice (escenario 2 de la historia 1).
- **Muchos tests fallidos**: la lista se acota en cantidad y se informa el total, para no exceder los límites del medio de aviso.
- **Racha larga**: 155 noches rojas seguidas ya ocurrieron. El aviso de una racha larga conserva el total acumulado y las noches más recientes, no una línea por cada noche desde el principio.
- **Contenido ajeno al aviso**: nombres de test u otro texto del log que parezcan menciones, enlaces o formato no deben notificar a terceros ni alterar el aviso; el contenido es texto inerte. Como el repositorio es público, el aviso solo lleva información que ya es pública.
- **El servicio de issues de GitHub no responde o rechaza el permiso**: ver la historia 2; el fallo es visible en el log y no cambia el color de la corrida.
- **Asignación imposible**: si el usuario a asignar no existe o no tiene acceso, el aviso se publica igual sin asignar y el log lo dice; un rojo no se pierde por una asignación fallida.
- **Dos corridas muy cercanas (programada y manual)**: el grupo de concurrencia existente las serializa sin cancelar; el estado final del aviso debe ser el mismo en cualquiera de los dos órdenes.
- **Secretos del empuje ausentes** (el operador aún no los definió, un fork, un secreto borrado por error): el empuje se omite con un `::warning::` visible y el issue se publica igual; el aviso nunca depende de que existan (FR-021).
- **No se pudo consultar el issue en una noche en rojo** (falla, respuesta que no es una lista o llamada que no responde dentro de su tope de tiempo): el empuje se envía igual, solo con el enlace de la corrida y sin número de noche (FR-020); en verde no se envía nada.
- **Telegram no responde o rechaza el mensaje**: queda un `::warning::` con el motivo y sin el token; el issue ya está publicado y la corrida conserva su color (FR-009, FR-021).
- **Re-ejecución de la misma corrida** (el operador relanza el job `alert`): el empuje sigue a la acción sobre el issue, así que la segunda ejecución, que no cambia el issue porque la noche ya estaba registrada, no envía un segundo mensaje. Costo aceptado: si el primer envío falló, no se reintenta con la re-ejecución (el issue conserva la noche).
- **Un nightly que no llega a arrancar** (cola atascada, workflow deshabilitado por inactividad del repositorio): ningún paso del propio job puede avisarlo. Es una limitación declarada, no una promesa; una vigilancia externa de "esta noche no corrió" queda como seguimiento.
- **Rojos transitorios** (red, descarga de un modelo): abren un aviso que se resuelve la noche siguiente. Es el costo aceptado de no etiquetar nada como "flake" sin medirlo con repeticiones (R6 de 039); el aviso lleva el detalle para que quien lo lea decida.
- **Primer rojo tras un aviso resuelto por un verde, o tras un verde que siguió a un cierre manual**: es otra racha y abre un issue nuevo; el historial de la racha anterior queda en el issue cerrado. Distinguirlo de un cierre manual a mitad de racha (que se reabre) es parte del contrato y del oráculo.
- **Tiempo agotado frente a cancelación**: FR-001 cuenta el tiempo agotado como rojo y FR-007 ignora las cancelaciones; si la plataforma reportara un job que agota su tope como "cancelado", FR-007 se tragaría un rojo real. El plan MUST medir cómo se reporta un tiempo agotado y fijar la regla sin tragarlo. Si la medición muestra que se reporta como cancelado, FR-007 se enmienda con esa salvedad (tarea T082) antes de implementar la regla.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Cuando una corrida programada del nightly concluye en rojo (tests fallidos, verde vacío, fallo en un paso previo a la suite o tiempo agotado), el sistema MUST dejar un aviso visible fuera de la pestaña de ejecuciones, sin que nadie tenga que abrirla.
- **FR-002**: El aviso MUST contener, como mínimo: el enlace a la corrida, el paso que falló, la línea de resumen de la suite cuando exista y los nombres de los tests que fallaron. Si el rojo viene de antes de la suite, MUST decir que no hay resumen en vez de omitirlo.
- **FR-003**: La lista de tests fallidos MUST estar acotada en cantidad, con el total informado, y el aviso de una racha larga MUST seguir siendo legible: conserva el total acumulado de noches y el detalle de las más recientes.
- **FR-004**: El contenido del aviso MUST ser texto inerte: lo que digan los nombres de test u otro texto del log no puede notificar a terceros ni alterar el formato del aviso, y el aviso MUST NOT incluir secretos, variables de entorno ni salida cruda del log más allá de los campos de FR-002. Como el repositorio es público, MUST contener solo información que ya es pública. Lo mismo vale para el mensaje de Telegram (FR-022).
- **FR-005**: Las corridas programadas consecutivas en rojo MUST actualizar el aviso abierto de la racha, agregando la nueva noche (enlace y fecha), y MUST NOT crear un segundo aviso abierto.
- **FR-006**: Cuando una corrida programada concluye en verde y existe un aviso abierto, el sistema MUST cerrar el issue con un comentario que enlace a la corrida verde. Con verde y sin aviso abierto, MUST NOT crear ni modificar nada.
- **FR-007**: Una corrida cancelada MUST NOT crear, actualizar ni resolver avisos.
- **FR-008**: Si una persona cierra el issue a mano mientras el nightly sigue en rojo, la siguiente noche en rojo MUST reabrir ese mismo issue con un comentario que diga que la noche sigue en rojo y enlace la corrida (clarificado el 12-10-2026), en vez de abrir otro o quedarse callada. Un issue cerrado por el propio mecanismo tras un verde pertenece a una racha terminada: la racha siguiente MUST abrir uno nuevo y no reabrir el anterior. Un verde que llega después de un cierre manual también termina esa racha: MUST dejar ese issue como historial (reescribir su marcador a resuelto, sin reabrirlo ni comentarlo), para que el rojo siguiente abra uno nuevo en vez de reabrir uno viejo.
- **FR-009**: El mecanismo de aviso MUST NOT poder cambiar la conclusión de la corrida: verde sigue verde y rojo sigue rojo aunque el aviso falle, y la falla del aviso MUST quedar visible en el log con un mensaje que lo diga. Vale para cada canal por separado: que falle el empuje por Telegram no impide el issue ni cambia la conclusión, y que falle el issue no impide el empuje.
- **FR-010**: El paso de aviso MUST NOT ocultar la causa de un rojo: el paso de la suite que falló sigue siendo el primer fallo identificable de la corrida.
- **FR-011**: Una corrida manual (`workflow_dispatch`) MUST NOT abrir, actualizar ni cerrar el issue de la racha, termine en rojo o en verde (clarificado el 12-10-2026): solo las corridas programadas mueven el aviso. La única excepción es una corrida manual de ensayo, pedida de forma explícita, que publica en un aviso de ensayo distinto del real (FR-016).
- **FR-012**: El aviso MUST ser un issue del propio repositorio (clarificado el 12-10-2026), que lleva el estado y el historial de la racha, y MUST ir acompañado de un empuje por Telegram (FR-020 y FR-021; clarificado el 14-10-2026 tras la medición M8: GitHub creó la notificación de la asignación pero no llegó a ningún canal que el operador mire). El issue no necesita secretos y su ampliación de permisos queda acotada al job que lo publica (FR-013); el empuje necesita los dos secretos de FR-021.
- **FR-013**: La feature MUST NOT ampliar los permisos del workflow más allá de escribir issues (el único permiso nuevo), MUST acotar ese permiso al job que publica el aviso y justificarlo por escrito, y MUST NOT agregar secretos salvo los dos del empuje por Telegram (FR-021), que se declaran por nombre y solo los lee el paso que publica. Ese job lista además `contents: read`, que el workflow ya concede, solo para el checkout que trae el script; el job de la suite conserva `contents: read`, no recibe secretos y nada más.
- **FR-014**: La suite del host (`bats tests/`, sin Docker ni red) MUST incluir un oráculo que ejecute el texto real de la lógica de aviso contra un sustituto del servicio de issues de GitHub y cubra, como mínimo: rojo nuevo, rojo repetido, verde tras rojo, verde sin aviso previo, aviso que falla, corrida cancelada, cierre manual (que reabre), corrida manual (que no mueve el aviso real) y nueva racha tras un verde (que abre un issue nuevo). Cubre además el empuje por Telegram contra un sustituto del servicio: el mensaje de cada caso de FR-020, la omisión con secretos ausentes, el fallo de Telegram sin cambiar el veredicto ni impedir el issue, y que el token no aparezca en ningún log ni en los argumentos de un proceso.
- **FR-015**: El oráculo MUST demostrarse rojo antes de la implementación y verde después, MUST ponerse rojo ante cada mutación de las condiciones que protege (las define el plan), MUST NOT poder pasar en vacío y MUST pasar en bash 3.2 y 5.x y con las señales que heredan los runners de GitHub.
- **FR-016**: Debe existir evidencia real de al menos una corrida de `workflow_dispatch` sobre la rama de la feature, con su identificador, en la que un fallo inducido por un mecanismo explícito y revertible produjo el aviso de ensayo (separado del real, porque las corridas manuales no mueven el real: FR-011), y de la corrida en verde siguiente que lo resolvió. El fallo inducido MUST NOT existir en main ni dejar el workflow de main en rojo. Esa evidencia incluye el mensaje de Telegram recibido por el operador (SC-009).
- **FR-017**: Esta feature MUST NOT modificar `docker/`, `scripts/`, `modules/` ni `setup.sh`, ni el contenido ni la semántica de los e2e.
- **FR-018**: La documentación del repositorio (la entrada de CHANGELOG y la nota en `CLAUDE.md`) MUST declarar qué cubre el aviso y qué no; en particular, que no detecta un nightly que no llega a arrancar.
- **FR-019**: El issue MUST quedar asignado al mantenedor del repositorio (clarificado el 12-10-2026), de modo que GitHub le notifique de forma activa aunque no vigile el repositorio. El usuario asignado es un dato no secreto del workflow. Si la asignación falla, el aviso se publica igual sin asignar y el log lo dice (FR-009).
- **FR-020**: Además del issue, el sistema MUST enviar un mensaje de empuje por Telegram al mantenedor por cada corrida programada en rojo (primera noche de la racha, noches siguientes y reapertura de un cierre manual) y uno de recuperación cuando la primera corrida programada en verde cierra un aviso abierto, y solo cuando el aviso quedó cerrado: si la noche verde no pudo cerrarlo, la verde siguiente lo cierra y envía el mensaje una sola vez (clarificado el 14-10-2026; el matiz del cierre incompleto, de la auditoría del mismo día). El empuje sigue a la acción sobre el issue: una corrida que no cambia nada en él (la noche ya estaba registrada, una cancelación, una corrida manual normal, un verde sin aviso abierto, o un verde sobre un aviso que una persona cerró a mano) MUST NOT enviar mensaje. Una corrida manual de ensayo MUST enviar el mensaje con el prefijo `[ensayo]`, para poder comprobar la entrega real (FR-016, SC-009). El empuje se envía después de la acción sobre el issue y, en una noche en rojo, si esta falla se envía igual con el enlace de la corrida. Si en una noche en rojo ni siquiera se pudo consultar el estado del issue, el empuje se envía igual como rojo, solo con el enlace de la corrida: un rojo no se pierde porque GitHub falle ni porque no responda (cada llamada a `gh` tiene un tope de tiempo); en una noche en verde sin ese dato no se envía nada, porque no se sabe si hay una racha que cerrar.
- **FR-021**: El empuje MUST usar dos secretos de repositorio, `TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID`, de un bot creado solo para la CI (clarificado el 14-10-2026), que pone el operador. Solo el paso que publica el aviso los lee. El token MUST NOT imprimirse en ningún log ni viajar por los argumentos de un proceso, y cualquier mensaje de error que lo contenga MUST redactarse antes de mostrarse. Si alguno de los dos no está definido, el empuje se omite con una anotación `::warning::` visible y el issue se publica igual (FR-009). Telegram caído o que rechaza el mensaje (token o chat id inválido, límite de frecuencia, tiempo agotado) MUST dejar un `::warning::` con el motivo sin el token y no reintentar más de lo que el plan fije.
- **FR-022**: El mensaje de empuje MUST ser texto plano de ASCII imprimible, sin formato que Telegram interprete, de 2 a 6 líneas (de 4 a 6 en los casos normales: el mínimo de 2 es el rojo del que no se pudo consultar el issue ni hay paso ni resumen), y MUST contener: el estado (rojo, sigue en rojo con el número de noche de la racha, o verde con el total de noches de la racha que cierra), el paso que falló cuando exista, la línea de resumen de la suite cuando exista, el enlace a la corrida y el enlace al issue (o solo el de la corrida si el issue no pudo publicarse). MUST NOT incluir nombres de tests (el detalle vive en el issue), secretos ni variables de entorno, y todo texto que venga del log MUST pasar por el mismo saneo que el cuerpo del issue (FR-004; clarificado el 14-10-2026). El mensaje de ensayo lleva el prefijo `[ensayo]`.
- **FR-023**: Los mensajes de noche en rojo y de reapertura MUST notificar con sonido normal; el de recuperación MUST enviarse en silencio (sin sonido ni vibración, con la opción que Telegram ofrece para enviar un mensaje sin notificar), porque no requiere atención inmediata (clarificado el 14-10-2026).

### Key Entities

- **Corrida programada**: una ejecución del nightly disparada por el calendario, con su identificador, el commit sobre el que corre, su conclusión (éxito, fallo, cancelada) y, cuando llegó a la suite, la línea de resumen y los tests fallidos.
- **Corrida manual**: una ejecución disparada a mano. No mueve el aviso real (FR-011); solo una corrida manual de ensayo, pedida de forma explícita, publica en un aviso de ensayo separado (FR-016).
- **Racha de rojos**: la secuencia de corridas programadas consecutivas en rojo, desde la primera hasta la siguiente en verde. Una racha tiene como máximo un aviso abierto: un aviso cerrado a mano a mitad de racha se reabre si el rojo sigue, y todo aviso cerrado (por el mecanismo o a mano) queda como historial en cuanto una noche verde termina su racha.
- **Empuje por Telegram**: el mensaje que el job de aviso envía al chat del mantenedor por cada acción sobre el issue que corresponde a una noche en rojo o a una recuperación (FR-020). No guarda estado: sigue al issue. Sus dos secretos son datos del repositorio, no del código (FR-021).
- **Aviso de nightly en rojo**: lo que representa una racha ante una persona. Es un issue del repositorio asignado al mantenedor, con un estado (abierto o cerrado), el total de noches de la racha, el detalle de las más recientes (enlace y fecha de cada una), el primer paso que falló, la línea de resumen y los tests fallidos de la última noche.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Tras una corrida programada en rojo, el aviso existe y contiene los elementos de FR-002, y el mensaje de Telegram se envió (FR-020), dentro de los 10 minutos siguientes al fin de la corrida.
- **SC-002**: En una racha simulada de tres o más noches rojas hay exactamente un aviso abierto y registra todas las noches.
- **SC-003**: La primera noche en verde posterior a una racha deja 0 avisos abiertos de esa racha.
- **SC-004**: En el 100 % de los casos del oráculo en que el aviso falla, con corrida verde y con corrida roja, la conclusión de la corrida es la que dio la suite: 0 veredictos alterados.
- **SC-005**: El oráculo del host cubre los nueve casos de FR-014 y cada mutación que defina el plan hace caer al menos un test (0 mutaciones sobrevivientes), en bash 3.2 y en bash 5.x.
- **SC-006**: Existe al menos una corrida real de ensayo con fallo inducido que produjo el aviso de ensayo y una corrida en verde posterior que lo cerró, con sus identificadores registrados en las Notes de la feature.
- **SC-007**: Cero líneas de diff en `docker/`, `scripts/`, `modules/` y `setup.sh`; exactamente dos referencias a secretos en el workflow (`TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID`), ambas en el paso que publica el aviso y ninguna en el job de la suite; los permisos nuevos son exactamente los declarados (clarificado el 14-10-2026; antes decía cero secretos).
- **SC-008**: La duración de la suite en una corrida verde no aumenta más de 1 minuto respecto de los unos 15 minutos medidos, y el job sigue cabiendo con holgura en su tope de 30 minutos.
- **SC-009**: En la corrida real de FR-016, el mantenedor confirma haber recibido el mensaje de Telegram sin haber abierto la pestaña Issues ni Actions (clarificado el 14-10-2026; la primera versión de este criterio pedía la notificación del issue y la medición M8 mostró que no era el canal que el operador mira). La notificación nativa de GitHub, si llega, es un extra que no se exige.
- **SC-010**: En el 100 % de los casos del oráculo, el valor de `TELEGRAM_BOT_TOKEN` (un valor centinela reconocible) aparece 0 veces en la salida del script, en el cuerpo y los comentarios del issue, en las anotaciones del log y en los argumentos ni el entorno de `curl` y de `gh`, los únicos procesos que reciben datos del aviso (el token solo se usa dentro del propio shell y del archivo de configuración que lee `curl`), incluidos los casos en que Telegram falla o cita el token en su respuesta (clarificado el 14-10-2026; el alcance a `curl` y `gh` lo precisó la auditoría de consistencia del mismo día).

## Assumptions

- El destinatario del aviso es el mantenedor del repositorio (hoy una persona).
- "Rojo" es cualquier conclusión de una corrida programada que no sea éxito ni cancelación (fallo o tiempo agotado). Una corrida que no llega a arrancar no genera aviso: es una limitación declarada.
- No se asume que las notificaciones nativas de GitHub lleguen al operador: se midió el 14-10-2026 (E1) que GitHub las crea en la bandeja web pero que al operador no le llegó nada donde mira. El issue se sigue asignando al mantenedor (FR-019) como extra y el canal que se exige es Telegram (FR-020 y SC-009). El operador crea el bot de la CI y define los dos secretos del repositorio (FR-021); el agente nunca ve sus valores.
- Antes de repetir E1 el operador crea el bot y define los dos secretos; sin ellos, E1 solo puede probar la omisión con advertencia (FR-021) y no la entrega. Los runners de GitHub traen `curl`.
- Quien puede escribir en el repositorio puede, modificando un workflow, hacer que este lea los secretos: el empuje es tan seguro como el acceso de escritura al repositorio, que hoy es del operador.
- Las corridas programadas solo ocurren sobre la rama por defecto, así que ninguna corrida programada puede demostrar el aviso desde una rama de trabajo: la evidencia real (FR-016) sale de una corrida manual de ensayo con aviso separado.
- El historial de 158 corridas es lo que expone hoy la API de GitHub y podría no ser todo el historial del workflow; la cifra de 155 rojas consecutivas es un mínimo medido.
- Sin bump de `VERSION` (precedente 019, 025 y 039: cambios de CI y de tests sin efecto de runtime) y con entrada de CHANGELOG; el plan lo confirma contra `origin/main` a mano.
- Test-first con el gate dual de bash 3.2 y 5.x, secuencial y nunca concurrente, y `shellcheck` con el comando exacto del job de CI. La línea base esperada es 1817 ok y 0 not ok en ambos bash (la CI de main sobre `13cafc3` está en verde); el plan la mide en local y le suma los tests nuevos.
- Un paso de workflow es shell: aplican las reglas de `CLAUDE.md` "Common gotchas" (pipes que cierran antes de que el productor termine bajo `pipefail`, SIGPIPE ignorada en los runners, `[[ ]]` intermedio muerto en bash 3.2, cargas grandes por argv o entorno).
- Empujar la rama, lanzar un `workflow_dispatch`, abrir un PR y cualquier otra acción sobre GitHub requieren confirmación explícita del operador; el plan no las da por hechas.
- Es la primera feature con spec-kit 1.1.2: el plan anota cualquier diferencia de comportamiento de los skills que se note.

## Out of Scope

- Cambiar los e2e o el contenido de la suite. Que el nightly ejercite el embed de qmd es otra feature (041).
- Tocar `docker/`, `scripts/`, `modules/` o `setup.sh`.
- Mover el horario del cron o investigar por qué GitHub lo atrasa entre 30 minutos y 12 horas según las 158 corridas medidas (se puede anotar como observación).
- Avisos sobre los workflows `tests` y `shellcheck`.
- Detectar un nightly que no llega a arrancar (cola atascada, workflow deshabilitado por inactividad): limitación declarada; una vigilancia externa de "esta noche no corrió" queda como seguimiento.
- Clasificar los rojos o decidir si son defectos de arnés o de producto (contrato `e2e-classification` de 039): el aviso informa, no diagnostica.
- Avisos periódicos de "todo bien".
- Otros canales además del issue y Telegram (correo, Slack, un bot de más de un destinatario). Telegram entró el 14-10-2026 como empuje, después de medir que la notificación nativa de GitHub no llegó al operador; la respuesta del 12-10-2026 que lo descartaba queda superada (ver Clarifications).
- Mejorar la entrega de las notificaciones nativas de GitHub (preferencias de correo o de la aplicación móvil): es configuración de la cuenta del operador y no cambia el código.
