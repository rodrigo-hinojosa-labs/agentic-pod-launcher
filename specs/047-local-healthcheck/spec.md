# Feature Specification: Healthcheck local sin falsos avisos de login

**Feature Branch**: `047-local-healthcheck`

**Created**: 2026-11-17

**Status**: Draft

**Input**: User description: "Revisemos los issues del repo y corregir, uno a la vez con spec-kit"; selección explícita del issue #111. El operador eligió advertir siete días antes del vencimiento y avisar al entrar en WARN por vencimiento, DEGRADED y recuperación, sin repetir cada tick. Ante una entrega fallida, eligió reintentar cada 30 minutos hasta confirmar el envío.

**Source**: [Issue #111](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/issues/111). La revisión del código y la línea base de esta fase están en [intake.md](intake.md). La evidencia histórica del issue corresponde a un agente y no se generaliza a toda la flota.

El operador necesita distinguir un agente sano de uno que requiere volver a iniciar sesión. El vencimiento rutinario de un token de acceso renovable no debe producir una alarma de login perdido, y una conexión del agente no debe descartarse solo porque pertenece a un proceso de su sesión distinto del principal. Los avisos deben señalar cambios de situación y permitir anticipar la renovación del login.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Distinguir login renovable de login perdido (Priority: P1)

Como operador de un agente local, quiero que el healthcheck conserve un veredicto sano cuando el acceso puede renovarse y detecte una pérdida real del login, para actuar cuando corresponde.

**Why this priority**: el issue registró 309 falsos DEGRADED en 1.672 veredictos y ninguna salida OK; el mismo texto describía tanto el estado renovable como el login perdido.

**Independent Test**: representar un login sano, uno con acceso vencido pero renovable y las formas de pérdida real descritas en el issue. Comprobar el veredicto y su motivo sin usar una cuenta o credenciales reales.

**Acceptance Scenarios**:

1. **Given** un agente activo con señal de conexión, login renovable y vencimiento de renovación a más de siete días, **When** vence únicamente su token de acceso y corre el healthcheck, **Then** el veredicto sigue siendo OK y no anuncia login perdido ni vencimiento próximo.
2. **Given** la forma de pérdida real documentada en #111, con tokens vacíos y fecha de acceso en cero, **When** corre el siguiente healthcheck, **Then** reporta DEGRADED y un motivo que distingue esa pérdida del vencimiento rutinario del acceso.
3. **Given** que venció la posibilidad de renovar el login, aunque el acceso actual todavía no haya terminado, **When** corre el healthcheck, **Then** reporta DEGRADED por renovación vencida, sin afirmar que ya se comprobó la caída de la sesión.
4. **Given** un error reciente de autenticación que exige volver a iniciar sesión, **When** corre el healthcheck, **Then** reporta DEGRADED aunque el archivo local todavía conserve fechas futuras.
5. **Given** un mensaje referido exclusivamente al vencimiento del acceso renovable, **When** no existe otra evidencia de pérdida de autenticación, **Then** ese mensaje no se clasifica por sí solo como login perdido. Un error de autenticación no clasificado conserva el tratamiento conservador existente.

---

### User Story 2 - Reconocer la conexión de la sesión completa (Priority: P1)

Como operador, quiero que el healthcheck considere las conexiones de todos los procesos pertenecientes a la unidad del agente, para que una sesión sana no aparezca desconectada por la distribución interna de sus procesos.

**Why this priority**: el issue documenta que las conexiones pertenecían a un hijo del proceso principal; la comprobación actual no representa esa situación.

**Independent Test**: representar una conexión atribuida al principal, a un hijo, a un descendiente adicional y a un proceso ajeno. Solo las tres primeras satisfacen la señal de conexión del agente.

**Acceptance Scenarios**:

1. **Given** una conexión establecida atribuible a un proceso perteneciente a la unidad del agente, **When** ese proceso no es el principal, **Then** el healthcheck reconoce la señal de conexión sin añadir el falso motivo de ausencia de conexión.
2. **Given** conexiones que pertenecen únicamente a procesos ajenos a esa unidad, **When** corre el healthcheck, **Then** esas conexiones no acreditan conexión del agente.
3. **Given** que no puede verificarse la pertenencia de procesos o sus conexiones, **When** corre el healthcheck, **Then** indica WARN y la limitación concreta, salvo que otra condición requiera DEGRADED.
4. **Given** una unidad inactiva, **When** hay una conexión de un proceso ajeno o una identificación de proceso obsoleta, **Then** el agente sigue en DEGRADED por unidad inactiva.

---

### User Story 3 - Anticipar el vencimiento real de la renovación (Priority: P2)

Como operador, quiero recibir una advertencia siete días antes de que venza la posibilidad de renovar el login, para iniciar sesión de nuevo con tiempo.

**Why this priority**: la advertencia sobre la vida corta del acceso nunca deja de aparecer y no permite anticipar la fecha que requiere intervención.

**Independent Test**: controlar el instante de evaluación y las fechas de renovación, incluidos los límites de siete días y del vencimiento, sin esperar días reales.

**Acceptance Scenarios**:

1. **Given** que falta un plazo positivo de siete días o menos para vencer la renovación, **When** corre el healthcheck, **Then** reporta WARN por ese vencimiento e informa el tiempo restante de forma comprensible.
2. **Given** que faltan más de siete días y las otras condiciones están sanas, **When** corre el healthcheck, **Then** ese vencimiento no añade WARN.
3. **Given** que no puede determinarse una fecha válida de renovación, **When** corre el healthcheck, **Then** informa WARN por verificación incompleta, sin inventar una fecha ni sustituirla por la del token de acceso.
4. **Given** un nuevo login con vencimiento fuera de la ventana, **When** corre el healthcheck, **Then** desaparece la advertencia de vencimiento anterior, respetando cualquier otra condición todavía presente.

---

### User Story 4 - Recibir avisos por cambios de situación (Priority: P2)

Como operador que configuró notificaciones, quiero recibir un aviso al entrar en WARN por vencimiento, otro al entrar en DEGRADED y un aviso de recuperación de un episodio con algún aviso confirmado, sin recibir el mismo aviso en cada ejecución.

**Why this priority**: repetir un diagnóstico cada cinco minutos multiplica el ruido y hace más difícil reconocer una caída real.

**Independent Test**: recorrer secuencias de estados, repeticiones, recuperación, reinicio del healthcheck y fallas de entrega con un receptor de prueba.

**Acceptance Scenarios**:

1. **Given** una primera entrada en WARN por vencimiento, **When** se suceden 30 veredictos iguales, **Then** se confirma un solo aviso de ese episodio.
2. **Given** un episodio en WARN por vencimiento, **When** pasa a DEGRADED y se repite ese veredicto, **Then** se confirma un nuevo aviso por la escalada y no uno por cada repetición.
3. **Given** un episodio con al menos un aviso de WARN por vencimiento o DEGRADED confirmado, **When** se resuelve y tanto la entrega como el registro están disponibles, **Then** se confirma un solo aviso de recuperación. Si quedan advertencias, el mensaje describe una recuperación parcial y no afirma OK.
4. **Given** un aviso ya confirmado, **When** el healthcheck vuelve a ejecutarse o se reinicia el servicio o el host, **Then** el mismo episodio no genera otro aviso confirmado por perder estado en memoria.
5. **Given** un episodio recuperado, **When** ocurre otro episodio posterior, **Then** puede producir su propio aviso.
6. **Given** un receptor de avisos que falla o no responde, **When** corre el healthcheck, **Then** conserva el veredicto de salud, termina de forma acotada y no registra la entrega como confirmada.
7. **Given** un aviso que falló y cuya situación sigue vigente, **When** se evalúa antes de cumplirse 30 minutos desde el último intento, **Then** permanece pendiente sin otro intento; en el primer healthcheck a partir de ese límite se reintenta. El intervalo vuelve a contarse desde cada intento fallido y los reintentos terminan al confirmarse la entrega.
8. **Given** un aviso pendiente de una situación anterior, **When** una nueva transición lo vuelve obsoleto, **Then** no se reintenta el aviso anterior. Si corresponde generar un aviso de la nueva transición, su primer intento no hereda la espera; una recuperación sin avisos previos confirmados no genera otro aviso.
9. **Given** una incidencia y un registro de avisos que no puede guardarse, **When** se repiten las evaluaciones, **Then** no se intenta ningún envío, el veredicto de salud se conserva y se informa la suspensión. Cuando vuelve a poder guardarse el registro, se reevalúa la situación y solo se envían los avisos vigentes que correspondan según sus plazos.
10. **Given** un episodio sin ningún aviso confirmado, **When** se resuelve antes de entregar su aviso pendiente, **Then** se cancela ese pendiente, no se envía recuperación y la resolución queda en el diagnóstico local.

### Edge Cases

- Acceso vencido con renovación vigente; acceso vigente con renovación vencida; fecha exactamente a siete días, exactamente vencida o inválida.
- Datos de otros servicios junto a los del login del agente: no se usa el vencimiento de otro servicio para decidir el suyo.
- Información de autenticación ausente, incompleta, ilegible o con forma desconocida: distinguir falta de evidencia de una pérdida de login comprobada.
- Error de autenticación reciente con fechas locales futuras; error de acceso renovable; error no clasificado.
- Cambio o terminación de procesos durante la consulta; pertenencia desconocida; identificadores parecidos o reutilizados; conexiones exclusivamente ajenas.
- Advertencias de conexión, del vigilante QMD o del grafo wiki junto a un vencimiento: conservar el nivel más grave y los motivos correspondientes.
- Cambios de motivo dentro de un mismo episodio DEGRADED; recuperación parcial; nuevo episodio después de recuperarse; dos evaluaciones simultáneas.
- Estado anterior inexistente o dañado: primera observación con registro válido antes de enviar; si no puede guardarse, envíos suspendidos y diagnóstico visible. Al restablecerse la escritura no se reproducen avisos obsoletos.
- Reloj que retrocede; nueva fecha de vencimiento después de volver a iniciar sesión.
- Notificaciones sin configurar, credenciales de notificación incompletas y entrega fallida o sin confirmación. Si el episodio se resuelve sin avisos confirmados, se cancela el pendiente y no se avisa recuperación; si al menos uno fue confirmado, sí corresponde recuperación.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: El sistema MUST limitar esta mejora al healthcheck del modo local y sus avisos. El modo Docker mantiene su comportamiento y sus artefactos funcionales; se permite únicamente la diferencia de identificación de versión del launcher exigida por su política de publicación.
- **FR-002**: El healthcheck MUST conservar los niveles OK, WARN y DEGRADED y sus códigos de salida 0, 1 y 2. El nivel más grave de las condiciones observadas prevalece; se conservan los motivos relevantes de las comprobaciones existentes.
- **FR-003**: El sistema MUST evaluar la posibilidad de renovar el login del agente y MUST NOT declarar login perdido ni vencimiento próximo únicamente porque venció, o está por vencer, su token de acceso renovable.
- **FR-004**: El sistema MUST distinguir la forma de pérdida real documentada en #111 y la renovación vencida de una renovación todavía válida. La pérdida real y la renovación vencida producen DEGRADED con motivos distintos y precisos.
- **FR-005**: La evidencia reciente y explícita de que se requiere volver a iniciar sesión MUST producir DEGRADED. Un vencimiento de acceso identificado como renovable MUST NOT convertirse por sí solo en pérdida de login; un error de autenticación no clasificado conserva el tratamiento conservador existente.
- **FR-006**: El sistema MUST tomar las fechas del login del agente, sin seleccionar fechas de autenticación de servicios ajenos ni estimarlas desde la fecha del archivo, la frecuencia de uso o una duración fija supuesta.
- **FR-007**: Con renovación vigente y un tiempo restante positivo de siete días o menos, el sistema MUST añadir WARN por vencimiento próximo e informar el tiempo restante. Por encima de siete días no se añade ese motivo; al llegar al vencimiento se aplica FR-004.
- **FR-008**: Si los datos o herramientas no permiten verificar la renovación, el sistema MUST indicar WARN por verificación incompleta, salvo evidencia independiente de DEGRADED. MUST NOT afirmar OK ni inventar una fecha a partir de información insuficiente.
- **FR-009**: La señal de conexión MUST considerar los procesos pertenecientes a la unidad del agente y MUST NOT limitarse a su proceso principal ni aceptar conexiones de procesos ajenos.
- **FR-010**: Ausencia comprobada de la señal de conexión o imposibilidad de verificarla MUST añadir WARN con motivos distinguibles; una unidad inactiva conserva DEGRADED. La señal de red no acredita por sí sola que el operador pueda completar una conversación remota.
- **FR-011**: Las notificaciones MUST seguir siendo opcionales y usar la configuración existente del operador, incluida la precedencia de su configuración de compatibilidad. Ausencia de configuración no impide emitir el diagnóstico.
- **FR-012**: Con entrega configurada, el sistema MUST generar avisos al entrar en WARN por vencimiento, al entrar en DEGRADED y al recuperarse de un episodio que tenga al menos un aviso de WARN por vencimiento o DEGRADED confirmado. Las otras entradas en WARN conservan su diagnóstico sin añadir nuevos tipos de aviso.
- **FR-013**: El sistema MUST NOT repetir un aviso confirmado por ejecuciones con la misma situación, por cambios de texto de su motivo o por reiniciar el healthcheck, servicio o host. Una escalada a DEGRADED y un nuevo episodio posterior a la recuperación sí pueden generar nuevos avisos.
- **FR-014**: Una recuperación MUST describir los problemas todavía presentes; MUST NOT anunciar OK si permanecen advertencias. Si ningún aviso del episodio se confirmó antes de resolverse, MUST cancelar el aviso pendiente y MUST NOT generar aviso de recuperación; la resolución queda en el diagnóstico local. Cuando corresponde avisar, una transición puede consolidar recuperación parcial y advertencia de vencimiento en un solo mensaje.
- **FR-015**: El estado necesario para distinguir episodios y entregas MUST quedar aislado por agente, sobrevivir a las ejecuciones y reinicios, y no contener credenciales ni textos crudos del registro de autenticación. Evaluaciones simultáneas MUST NOT duplicar un envío confirmado del mismo cambio.
- **FR-016**: Si el registro de avisos falta o está dañado, el sistema MUST tratar la evaluación como primera observación y explicar la limitación. MUST disponer de un registro válido y persistible antes de iniciar cualquier envío. Mientras no pueda guardar ese registro, MUST suspender todos los envíos, incluidos reintentos y recuperaciones, conservar el veredicto de salud y mostrar explícitamente la suspensión. Al recuperarse la escritura MUST reevaluar la situación actual y reanudar solo los avisos vigentes, respetando los plazos de FR-018.
- **FR-017**: Un aviso fallido o sin respuesta MUST terminar de forma acotada, MUST NOT alterar el veredicto de salud ni quedar marcado como entrega confirmada. Un aviso pendiente obsoleto MUST NOT anunciar una caída después de que el episodio ya se recuperó.
- **FR-018**: Un aviso fallido todavía vigente MUST reintentarse en el primer healthcheck que ocurra a partir de 30 minutos desde su último intento, y así sucesivamente hasta confirmar la entrega. MUST NOT reintentarse antes del límite ni después de confirmarse. El plazo y la condición de pendiente MUST sobrevivir a reinicios. Una nueva transición MUST cancelar el aviso anterior si lo vuelve obsoleto. Solo si corresponde un nuevo aviso, su primer intento no hereda la espera del anterior; la cancelación no obliga a generar una recuperación excluida por FR-014.
- **FR-019**: El sistema MUST NOT exponer credenciales en argumentos, diagnósticos, estado persistido, pruebas o documentación. La lectura de configuración conserva el contrato de seguridad existente y no ejecuta su contenido.
- **FR-020**: El healthcheck MUST seguir siendo una observación: MUST NOT renovar el login, arrancar o detener servicios, abrir una sesión de modelo, modificar tokens o aplicar reparaciones automáticamente.
- **FR-021**: Los comportamientos MUST poder validarse de forma reproducible con información sintética y sin acceso a credenciales o agentes reales. La validación de la fecha no requiere esperar días reales.
- **FR-022**: El cambio MUST sobrevivir a la regeneración del workspace y conservar la comprobación de unidad activa, los avisos de QMD y del grafo wiki y el aislamiento de configuración de notificaciones ya existente.
- **FR-023**: Antes del merge, la corrección MUST pasar las pruebas automáticas y una integración aislada con un servicio de prueba real en Linux y datos ficticios. La atribución de procesos y conexiones MUST comprobarse con evidencias del servicio real, no únicamente con respuestas simuladas. Este gate MUST NOT necesitar credenciales reales, un agente de la flota ni llamadas al modelo.

### Key Entities *(include if feature involves data)*

- **Veredicto de salud**: nivel, motivos y momento de observación de un agente; no contiene secretos.
- **Situación del login**: renovable, próxima a vencer, renovación vencida, login perdido o verificación incompleta; la fecha de acceso y la de renovación tienen significados distintos.
- **Señal de conexión**: conexión establecida atribuible a un proceso perteneciente a la unidad del agente; indicador parcial, no prueba de una conversación completa.
- **Episodio y entrega de aviso**: situación advertida, escalada, recuperación y confirmación o pendiente de entrega, aislados por agente y persistentes entre evaluaciones. Se distingue si hubo al menos un aviso del episodio confirmado: solo entonces su resolución puede generar aviso de recuperación.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En 30 evaluaciones sintéticas consecutivas de un agente sano con señal de conexión, renovación vigente a más de siete días y sin errores de autenticación, el 100 % reporta OK, incluso al vencer el acceso renovable; no se confirma ningún aviso de vencimiento o pérdida de login.
- **SC-002**: El 100 % de los casos de pérdida real de login, renovación vencida y errores explícitos que exigen volver a iniciar sesión se identifica en el siguiente healthcheck con DEGRADED y un motivo preciso. Los casos desconocidos quedan distinguibles de los conocidos.
- **SC-003**: La matriz de fechas verifica sin esperar tiempo real: más de siete días sin aviso de vencimiento; exactamente siete días y plazo positivo menor con WARN; exactamente vencido y vencido con DEGRADED; fecha no verificable con WARN por limitación. Ningún caso utiliza la fecha de un servicio ajeno.
- **SC-004**: La matriz de conexiones acepta el principal y otros procesos pertenecientes a la unidad, rechaza todos los procesos ajenos y deja la verificación incompleta en WARN. No produce falsos OK por identificadores parecidos, reutilizados o unidad inactiva.
- **SC-005**: Con receptor y registro disponibles, una secuencia de WARN por vencimiento repetido 30 veces, escalada a DEGRADED repetida 30 veces y recuperación produce exactamente tres avisos confirmados. Reiniciar entre repeticiones no aumenta ese número; un episodio posterior tiene sus propios avisos.
- **SC-006**: Ante fallas de entrega, estado dañado y evaluaciones simultáneas, se conservan los veredictos esperados y no se anuncian entregas no confirmadas ni avisos obsoletos. En todas las evaluaciones con registro no persistible hay cero intentos de envío y un diagnóstico explícito de suspensión; al restablecerse la escritura se reevalúa el aviso vigente sin reproducir los obsoletos. Con registro operativo, en una secuencia de evaluaciones a los minutos 0, 5, 25, 30, 55, 60 y 65 de una misma situación, con fallas en 0 y 30 y éxito en 60, hay exactamente tres intentos: 0, 30 y 60. Reiniciar entre evaluaciones no adelanta el próximo intento; después del éxito no hay otro intento de ese aviso. Un episodio que se resuelve sin avisos confirmados produce cero intentos de recuperación y no conserva su aviso pendiente obsoleto.
- **SC-007**: En todos los casos de validación, los valores sintéticos que representan secretos están ausentes de argumentos, salidas y estado de avisos. Las fallas de herramientas o datos son diagnósticos explícitos y no abortos sin veredicto.
- **SC-008**: Tras regenerar, se conservan todos los comportamientos nuevos y las comprobaciones previas de unidad, QMD, grafo y configuración de avisos; los artefactos funcionales del modo Docker no cambian por esta feature, salvo la identificación de versión del launcher.
- **SC-009**: Antes del merge queda registrada una integración Linux que ejecute el healthcheck generado sobre un servicio de prueba real, con login sintético sano: reconoce la conexión cuando pertenece al principal, a un hijo o a un descendiente adicional de la unidad; no acredita conexión con procesos ajenos y conserva DEGRADED con la unidad inactiva. El 100 % de esos casos da el nivel y motivo esperados, sin usar agentes o credenciales reales.

## Assumptions

- El alcance aprobado es únicamente #111; #117, #120 y #131 esperan su propia feature. El despliegue pendiente de 046 no forma parte de esta corrección.
- El período actual de evaluación, aproximadamente cinco minutos, se mantiene. La ventana de siete días es una política aprobada, no una afirmación sobre la duración fija o variable del login del proveedor.
- Los niveles de salud y las fuentes de configuración existentes siguen siendo el contrato público. No se añade un nuevo canal de notificaciones ni se habilita uno por defecto.
- Se usa la fecha de renovación que proporciona el login cuando es verificable. Su ausencia o una forma desconocida se reportan como limitación, sin consultar el proveedor ni leer credenciales reales para completar la especificación.
- Recuperación significa que se resolvió el episodio observado; puede ser parcial si quedan otros WARN. Solo genera aviso si previamente se confirmó al menos un aviso de ese episodio. Se informa la diferencia entre recuperación completa y parcial y se evita sumar mensajes equivalentes por el mismo cambio.
- No se promete entrega exactamente una vez frente a una respuesta de red perdida o una confirmación recibida que no alcanza a persistirse: se deduplican las entregas confirmadas y registradas durablemente, y se distingue una entrega incierta de una confirmada.
- Los 30 minutos son el intervalo mínimo aprobado entre intentos de un mismo aviso pendiente. La ejecución periódica determina cuándo ocurre el primer healthcheck elegible; no se incorpora otro temporizador ni se cambia la frecuencia de evaluación.
- Las tres observaciones históricas del issue y la lectura actual justifican el problema, pero no certifican el comportamiento de todas las versiones de Claude Code ni el estado actual de ferrari o mclaren.
- La aceptación previa al merge incluye un servicio aislado real en Linux con datos ficticios; no exige observación previa de 24 horas en un agente de la flota. El entorno concreto de esa integración se define en la fase de plan y la prueba no se ejecuta durante clarify.

## Clarifications

### Session 2026-11-17

- Q: ¿Qué issue se aborda primero? → A: #111, falsos avisos del healthcheck local; una sola feature a la vez.
- Q: ¿Con cuánta anticipación advertir el vencimiento de la renovación? → A: siete días.
- Q: ¿Qué cambios generan aviso con NOTIFY configurado? → A: entrada en WARN por vencimiento, DEGRADED y recuperación, sin repetir cada tick.
- Q: ¿Cómo reintentar una entrega fallida? → A: Reintentar el aviso pendiente cada 30 minutos hasta éxito; nunca repetir un envío confirmado.
- Q: ¿Qué debe hacer el healthcheck si detecta una incidencia pero no puede guardar el registro que evita avisos repetidos? → A: Suspender envíos hasta poder guardar el registro, mantener el diagnóstico visible y reanudar solo con registro persistible y situación vigente.
- Q: Si una incidencia se resuelve antes de confirmarse cualquiera de sus avisos, ¿debe enviarse una notificación de recuperación? → A: No. Cancelar el aviso obsoleto y no enviar recuperación si ningún aviso del episodio se confirmó; conservar la resolución en el diagnóstico local.
- Q: ¿Qué comprobación debe exigirse antes del merge, además de las pruebas automáticas del healthcheck? → A: Pruebas automáticas más integración aislada con un servicio de prueba real en Linux y datos ficticios, antes del merge.

## Out of Scope

- Corregir los otros issues o los hallazgos laterales de 046; cambiar el despliegue o los respaldos de esa feature.
- Cambiar el comportamiento del modo Docker, el supervisor, el heartbeat, el watcher o el motor de QMD.
- Cambiar la duración de los tokens del proveedor, renovar el login automáticamente, leer credenciales reales desde el asistente o hacer llamadas al modelo.
- Garantizar la operatividad de extremo a extremo de Remote Control solo a partir de conexiones de red.
- Modificar agentes vivos, instalar unidades, reiniciar hosts, publicar cambios en GitHub o desplegar durante esta fase de especificación.
