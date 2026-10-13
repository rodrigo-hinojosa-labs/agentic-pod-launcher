# Feature Specification: Una noche en rojo del nightly le llega a alguien

**Feature Branch**: `040-nightly-red-alert`

**Created**: 2026-10-12

**Status**: Draft

**Input**: El job nocturno `docker-e2e` estuvo en rojo en las 155 corridas programadas anteriores a 039 (07-05 a 09-10-2026) y ningún aviso lo hizo notar: se descubrió al revisar la CI después de un merge. 039 hizo que el semáforo signifique algo, pero un semáforo solo sirve si alguien lo mira. Esta feature hace que una noche en rojo deje un aviso visible fuera de la pestaña Actions de GitHub, que una racha de rojos sea un solo aviso, que el aviso se apague solo cuando vuelve el verde y que el aviso jamás cambie el veredicto de la corrida.

## Contexto

**Qué dejó hecho 039.** El workflow `docker-e2e (nightly)` corre por `schedule` y por `workflow_dispatch` en `ubuntu-latest`, con `permissions: contents: read`, sin secretos y con un tope de 30 minutos por job. Desde el merge de 039 (PR #102, 09-10-2026) ejecuta de verdad los 48 e2e en unos 15 minutos, y una corrida en la que no se ejecutó ningún test sale en rojo. Las tres corridas programadas siguientes pasaron 48 de 48: runs 38047040835 (10-10-2026), 38135162982 (11-10) y 38252436900 (12-10), todas sobre `13cafc3`.

**Lo que 039 no resolvió, medido el 12-10-2026 con la API de GitHub.** El historial del workflow expone 158 corridas programadas, de la primera registrada (07-05-2026) a la del 12-10-2026: **155 terminaron en rojo y 3 en verde, y las 3 verdes son las posteriores a 039.** La primera corrida registrada ya estaba en rojo, así que mientras duró el defecto el nightly no pasó nunca. La causa (`exit 141`, SIGPIPE) está medida para las corridas de 30-09 a 07-10-2026 y para una nota de CI del 26-07-2026; en las demás solo consta la conclusión. El rojo se descubrió al revisar la CI después del merge de 038, no por un aviso, y 039 dejó "notificaciones o alertas de un nightly rojo" fuera de alcance. Un semáforo que significa algo solo sirve si alguien lo mira.

**Cómo llega hoy un rojo.** Solo entrando a la pestaña Actions o, quizá, por las notificaciones nativas de GitHub: **no está medido si esas notificaciones le llegan al operador** ni si las lee. Esta feature no las da por hechas ni las reemplaza.

**Cuándo corre.** El cron declara `0 5 * * *`, pero las 158 corridas programadas empezaron entre las 05:30Z y las 17:17Z (las 20 más recientes, entre las 09:46Z y las 12:58Z). El aviso no puede depender de una hora fija.

**Entorno.** El repositorio es público y tiene Issues habilitados; empujar cambios a `.github/workflows/` exige el scope `workflow` del token de `gh`, que ya lo tiene. Como el repositorio es público, lo que el aviso contenga puede leerlo cualquiera.

## Clarifications

### Session 2026-10-12

- Q: ¿Por qué canal debe llegar el aviso de una noche en rojo? → A: Un issue del propio repositorio. No necesita secretos nuevos y la ampliación de permisos queda acotada al job que publica el aviso. Telegram u otro canal quedan descartados.
- Q: ¿Cómo se asegura que el issue le llegue de forma activa al mantenedor y no quede solo en la lista de Issues? → A: Asignándolo al mantenedor: GitHub notifica a la persona asignada aunque no vigile el repositorio. Que la notificación llega se mide con una corrida real de prueba.
- Q: ¿Qué debe hacer una corrida manual (`workflow_dispatch`) con el issue cuando termina en rojo o en verde? → A: Nada: solo las corridas programadas abren, actualizan o cierran el issue. Consecuencia: como las corridas programadas solo ocurren sobre la rama por defecto, la evidencia real de FR-016 usa un aviso de ensayo separado del real, activado de forma explícita por la corrida manual.
- Q: Si alguien cierra el issue a mano mientras el nightly sigue en rojo, ¿qué debe pasar en la noche siguiente? → A: Se reabre ese mismo issue con un comentario que dice que la noche sigue en rojo y enlaza la corrida. Un issue cerrado por el propio mecanismo tras un verde pertenece a una racha terminada: la racha siguiente abre uno nuevo. Consecuencia: un verde posterior a un cierre manual también termina esa racha y deja el issue como historial (análisis del 12-10-2026).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Una noche en rojo deja un aviso que se ve sin abrir Actions (Priority: P1)

Como mantenedor del launcher, quiero que cuando el nightly programado termine en rojo aparezca un aviso en un lugar donde yo ya miro, con lo mínimo para actuar, para enterarme el mismo día y no meses después por casualidad.

**Why this priority**: Es el valor central y la brecha que dejó 039: el nightly ya significa algo, pero hubo 155 noches seguidas en rojo sin que ningún aviso lo hiciera notar. Sin esto, la próxima regresión repite el mismo silencio.

**Independent Test**: Provocar un fallo en una corrida manual de ensayo sobre la rama de la feature, con un mecanismo explícito y revertible, y comprobar que aparece el aviso de ensayo con los cuatro elementos mínimos; el caso "rojo nuevo" del oráculo del host pasa.

**Acceptance Scenarios**:

1. **Given** una corrida programada cuya suite termina con al menos un test fallido, **When** la corrida concluye, **Then** existe un aviso fuera de Actions con el enlace a la corrida, el paso que falló, la línea de resumen de la suite (`e2e summary:`) y los nombres de los tests que fallaron.
2. **Given** una corrida programada que falla antes de llegar a la suite (instalación o verificación del entorno), **When** concluye, **Then** el aviso aparece igual, nombra el paso que falló y dice que no hay resumen de la suite, en vez de omitirlo o inventarlo.
3. **Given** una corrida programada que termina en rojo porque no se ejecutó ningún e2e (la guarda de verde vacío de 039) o porque agotó el tiempo del job, **When** concluye, **Then** avisa igual que cualquier otro rojo.

---

### User Story 2 - El aviso no puede cambiar el veredicto de la noche ni esconder su causa (Priority: P1)

Como mantenedor, quiero que la lógica de aviso sea incapaz de volver roja una noche verde o de tapar por qué una noche roja lo es, para que el color del nightly siga diciendo solo lo que dijo la suite.

**Why this priority**: Un aviso que pudiera romper el nightly repetiría por otra vía el defecto que corrigió 039: un paso de diagnóstico decidiendo el color. Es el mismo criterio que la constitución impone a los notificadores del heartbeat (principio IV: un notificador no puede tumbar lo que notifica).

**Independent Test**: Forzar que el mecanismo de aviso falle (permiso denegado, servicio caído) en una corrida verde y en una roja: la conclusión de cada una es la que dio la suite y el log dice que el aviso no pudo entregarse.

**Acceptance Scenarios**:

1. **Given** una corrida programada en verde, **When** el mecanismo de aviso falla, **Then** la corrida sigue en verde y el log dice que el aviso no pudo entregarse.
2. **Given** una corrida programada en rojo, **When** el mecanismo de aviso falla, **Then** la corrida sigue en rojo, el primer fallo de la corrida sigue siendo el paso de la suite que falló y el log dice que el aviso no pudo entregarse.
3. **Given** una corrida en rojo cuyo aviso se entregó, **When** se lee el log de la corrida, **Then** la causa del rojo se identifica igual que antes: el aviso agrega información y nunca reemplaza la del log.

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
6. **Given** un issue que el propio mecanismo cerró tras un verde, **When** llega una noche en rojo, **Then** se abre un issue nuevo para la nueva racha y el anterior queda cerrado como historial.
7. **Given** un issue que una persona cerró a mano durante una racha, **When** una corrida programada termina en verde y después llega una noche en rojo, **Then** el verde deja ese issue como historial (su marcador pasa a resuelto, sin reabrirlo ni comentarlo) y la noche en rojo abre un issue nuevo en vez de reabrir el viejo.
5. **Given** una corrida cancelada, **When** concluye, **Then** no crea, actualiza ni resuelve avisos: una cancelación no dice nada sobre el estado del nightly.

---

### User Story 4 - La suite del host impide que el aviso se vuelva mudo sin que nadie lo note (Priority: P2)

Como mantenedor, quiero que la suite que ya corre en cada PR ejecute la lógica real del aviso contra un sustituto del servicio y falle si deja de comportarse, para que una edición del workflow no apague el aviso en silencio: un sistema de alertas que falla sin avisar es peor que no tenerlo.

**Why this priority**: Es la lección de 025 y 039: un chequeo que no puede fallar no es evidencia. Es el seguro que mantiene vivas las historias 1 a 3 cuando alguien edite el workflow.

**Independent Test**: `bats tests/` en el host, sin Docker ni red, contiene los casos nuevos; con el aviso retirado o roto por una mutación, al menos un caso cae.

**Acceptance Scenarios**:

1. **Given** el workflow con la lógica de aviso, **When** corre la suite del host, **Then** ejecuta el texto real de esa lógica contra un sustituto del servicio de issues de GitHub y verifica, como mínimo, rojo nuevo, rojo repetido, verde tras rojo, verde sin aviso previo, aviso que falla, corrida cancelada, cierre manual (que reabre), corrida manual (que no mueve el aviso real) y nueva racha tras un verde (que abre un issue nuevo).
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
- **Un nightly que no llega a arrancar** (cola atascada, workflow deshabilitado por inactividad del repositorio): ningún paso del propio job puede avisarlo. Es una limitación declarada, no una promesa; una vigilancia externa de "esta noche no corrió" queda como seguimiento.
- **Rojos transitorios** (red, descarga de un modelo): abren un aviso que se resuelve la noche siguiente. Es el costo aceptado de no etiquetar nada como "flake" sin medirlo con repeticiones (R6 de 039); el aviso lleva el detalle para que quien lo lea decida.
- **Primer rojo tras un aviso resuelto por un verde, o tras un verde que siguió a un cierre manual**: es otra racha y abre un issue nuevo; el historial de la racha anterior queda en el issue cerrado. Distinguirlo de un cierre manual a mitad de racha (que se reabre) es parte del contrato y del oráculo.
- **Tiempo agotado frente a cancelación**: FR-001 cuenta el tiempo agotado como rojo y FR-007 ignora las cancelaciones; si la plataforma reportara un job que agota su tope como "cancelado", FR-007 se tragaría un rojo real. El plan MUST medir cómo se reporta un tiempo agotado y fijar la regla sin tragarlo. Si la medición muestra que se reporta como cancelado, FR-007 se enmienda con esa salvedad (tarea T082) antes de implementar la regla.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Cuando una corrida programada del nightly concluye en rojo (tests fallidos, verde vacío, fallo en un paso previo a la suite o tiempo agotado), el sistema MUST dejar un aviso visible fuera de la pestaña de ejecuciones, sin que nadie tenga que abrirla.
- **FR-002**: El aviso MUST contener, como mínimo: el enlace a la corrida, el paso que falló, la línea de resumen de la suite cuando exista y los nombres de los tests que fallaron. Si el rojo viene de antes de la suite, MUST decir que no hay resumen en vez de omitirlo.
- **FR-003**: La lista de tests fallidos MUST estar acotada en cantidad, con el total informado, y el aviso de una racha larga MUST seguir siendo legible: conserva el total acumulado de noches y el detalle de las más recientes.
- **FR-004**: El contenido del aviso MUST ser texto inerte: lo que digan los nombres de test u otro texto del log no puede notificar a terceros ni alterar el formato del aviso, y el aviso MUST NOT incluir secretos, variables de entorno ni salida cruda del log más allá de los campos de FR-002. Como el repositorio es público, MUST contener solo información que ya es pública.
- **FR-005**: Las corridas programadas consecutivas en rojo MUST actualizar el aviso abierto de la racha, agregando la nueva noche (enlace y fecha), y MUST NOT crear un segundo aviso abierto.
- **FR-006**: Cuando una corrida programada concluye en verde y existe un aviso abierto, el sistema MUST cerrar el issue con un comentario que enlace a la corrida verde. Con verde y sin aviso abierto, MUST NOT crear ni modificar nada.
- **FR-007**: Una corrida cancelada MUST NOT crear, actualizar ni resolver avisos.
- **FR-008**: Si una persona cierra el issue a mano mientras el nightly sigue en rojo, la siguiente noche en rojo MUST reabrir ese mismo issue con un comentario que diga que la noche sigue en rojo y enlace la corrida (clarificado el 12-10-2026), en vez de abrir otro o quedarse callada. Un issue cerrado por el propio mecanismo tras un verde pertenece a una racha terminada: la racha siguiente MUST abrir uno nuevo y no reabrir el anterior. Un verde que llega después de un cierre manual también termina esa racha: MUST dejar ese issue como historial (reescribir su marcador a resuelto, sin reabrirlo ni comentarlo), para que el rojo siguiente abra uno nuevo en vez de reabrir uno viejo.
- **FR-009**: El mecanismo de aviso MUST NOT poder cambiar la conclusión de la corrida: verde sigue verde y rojo sigue rojo aunque el aviso falle, y la falla del aviso MUST quedar visible en el log con un mensaje que lo diga.
- **FR-010**: El paso de aviso MUST NOT ocultar la causa de un rojo: el paso de la suite que falló sigue siendo el primer fallo identificable de la corrida.
- **FR-011**: Una corrida manual (`workflow_dispatch`) MUST NOT abrir, actualizar ni cerrar el issue de la racha, termine en rojo o en verde (clarificado el 12-10-2026): solo las corridas programadas mueven el aviso. La única excepción es una corrida manual de ensayo, pedida de forma explícita, que publica en un aviso de ensayo distinto del real (FR-016).
- **FR-012**: El aviso MUST ser un issue del propio repositorio (clarificado el 12-10-2026), visible fuera de la pestaña de ejecuciones, sin secretos nuevos y con la ampliación de permisos acotada al job que lo publica (FR-013).
- **FR-013**: La feature MUST NOT ampliar los permisos del workflow más allá de escribir issues (el único permiso nuevo), MUST acotar ese permiso al job que publica el aviso y justificarlo por escrito, y MUST NOT agregar secretos. Ese job lista además `contents: read`, que el workflow ya concede, solo para el checkout que trae el script; el job de la suite conserva `contents: read` y nada más.
- **FR-014**: La suite del host (`bats tests/`, sin Docker ni red) MUST incluir un oráculo que ejecute el texto real de la lógica de aviso contra un sustituto del servicio de issues de GitHub y cubra, como mínimo: rojo nuevo, rojo repetido, verde tras rojo, verde sin aviso previo, aviso que falla, corrida cancelada, cierre manual (que reabre), corrida manual (que no mueve el aviso real) y nueva racha tras un verde (que abre un issue nuevo).
- **FR-015**: El oráculo MUST demostrarse rojo antes de la implementación y verde después, MUST ponerse rojo ante cada mutación de las condiciones que protege (las define el plan), MUST NOT poder pasar en vacío y MUST pasar en bash 3.2 y 5.x y con las señales que heredan los runners de GitHub.
- **FR-016**: Debe existir evidencia real de al menos una corrida de `workflow_dispatch` sobre la rama de la feature, con su identificador, en la que un fallo inducido por un mecanismo explícito y revertible produjo el aviso de ensayo (separado del real, porque las corridas manuales no mueven el real: FR-011), y de la corrida en verde siguiente que lo resolvió. El fallo inducido MUST NOT existir en main ni dejar el workflow de main en rojo.
- **FR-017**: Esta feature MUST NOT modificar `docker/`, `scripts/`, `modules/` ni `setup.sh`, ni el contenido ni la semántica de los e2e.
- **FR-018**: La documentación del repositorio (la entrada de CHANGELOG y la nota en `CLAUDE.md`) MUST declarar qué cubre el aviso y qué no; en particular, que no detecta un nightly que no llega a arrancar.
- **FR-019**: El issue MUST quedar asignado al mantenedor del repositorio (clarificado el 12-10-2026), de modo que GitHub le notifique de forma activa aunque no vigile el repositorio. El usuario asignado es un dato no secreto del workflow. Si la asignación falla, el aviso se publica igual sin asignar y el log lo dice (FR-009).

### Key Entities

- **Corrida programada**: una ejecución del nightly disparada por el calendario, con su identificador, el commit sobre el que corre, su conclusión (éxito, fallo, cancelada) y, cuando llegó a la suite, la línea de resumen y los tests fallidos.
- **Corrida manual**: una ejecución disparada a mano. No mueve el aviso real (FR-011); solo una corrida manual de ensayo, pedida de forma explícita, publica en un aviso de ensayo separado (FR-016).
- **Racha de rojos**: la secuencia de corridas programadas consecutivas en rojo, desde la primera hasta la siguiente en verde. Una racha tiene como máximo un aviso abierto: un aviso cerrado a mano a mitad de racha se reabre si el rojo sigue, y todo aviso cerrado (por el mecanismo o a mano) queda como historial en cuanto una noche verde termina su racha.
- **Aviso de nightly en rojo**: lo que representa una racha ante una persona. Es un issue del repositorio asignado al mantenedor, con un estado (abierto o cerrado), el total de noches de la racha, el detalle de las más recientes (enlace y fecha de cada una), el primer paso que falló, la línea de resumen y los tests fallidos de la última noche.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Tras una corrida programada en rojo, el aviso existe y contiene los elementos de FR-002 dentro de los 10 minutos siguientes al fin de la corrida.
- **SC-002**: En una racha simulada de tres o más noches rojas hay exactamente un aviso abierto y registra todas las noches.
- **SC-003**: La primera noche en verde posterior a una racha deja 0 avisos abiertos de esa racha.
- **SC-004**: En el 100 % de los casos del oráculo en que el aviso falla, con corrida verde y con corrida roja, la conclusión de la corrida es la que dio la suite: 0 veredictos alterados.
- **SC-005**: El oráculo del host cubre los nueve casos de FR-014 y cada mutación que defina el plan hace caer al menos un test (0 mutaciones sobrevivientes), en bash 3.2 y en bash 5.x.
- **SC-006**: Existe al menos una corrida real de ensayo con fallo inducido que produjo el aviso de ensayo y una corrida en verde posterior que lo cerró, con sus identificadores registrados en las Notes de la feature.
- **SC-007**: Cero líneas de diff en `docker/`, `scripts/`, `modules/` y `setup.sh`; cero secretos nuevos salvo los que el canal elegido exija y el plan liste; los permisos nuevos son exactamente los declarados.
- **SC-008**: La duración de la suite en una corrida verde no aumenta más de 1 minuto respecto de los unos 15 minutos medidos, y el job sigue cabiendo con holgura en su tope de 30 minutos.
- **SC-009**: En la corrida real de FR-016, el mantenedor confirma haber recibido la notificación del issue (correo, web o móvil) sin haber abierto la pestaña Issues ni Actions.

## Assumptions

- El destinatario del aviso es el mantenedor del repositorio (hoy una persona).
- "Rojo" es cualquier conclusión de una corrida programada que no sea éxito ni cancelación (fallo o tiempo agotado). Una corrida que no llega a arrancar no genera aviso: es una limitación declarada.
- No se asume que las notificaciones nativas de GitHub lleguen al operador: no está medido. Como el aviso es un issue, que le llegue de forma activa depende de cómo se designa a su destinatario: se asigna al mantenedor (FR-019) y que la notificación llega se mide en la corrida real (SC-009).
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
- Un canal distinto del issue (Telegram u otro): descartado en clarify el 12-10-2026 por exigir secretos nuevos.
