# Feature Specification: Prueba de migración de QMD independiente del orden de arranque

**Feature Branch**: `050-e2e-qmd-boot-race`

**Created**: 2026-11-24

**Status**: Draft

**Input**: Issue #117 y selección del operador el 24-11-2026: eliminar la dependencia del orden de arranque en la prueba de migración legacy de QMD (prueba 13), mediante Spec Kit. Conservar la comprobación de la migración en el primer reindex y su idempotencia.

## Contexto y evidencia

El operador necesita que un rojo del e2e signifique que la migración falló. Hoy la prueba puede caer porque el setup terminó antes de lo que su autor supuso, aunque el producto se comporte según su contrato.

**Verificado en `main` y `origin/main`, ambos en `a45beae`, el 24-11-2026:**

- La prueba prepara un índice existente y omite tanto el marcador de setup completado como el de migración. Luego exige que el marcador de setup siga ausente inmediatamente después de levantar el contenedor. Su comentario afirma que la existencia del índice basta para omitir el setup. Fuente: [prueba de migración](../../tests/docker-e2e-qmd.bats), bloque `qmd e2e (037): a legacy vault-root collection migrates to wiki/-only on the first reindex tick`.
- El producto omite el setup cuando existen el índice **y** el marcador de setup. Sin ese marcador, actualiza el índice, ejecuta el embed y escribe el marcador al terminar. Fuente: [qmd_setup_if_needed y _qmd_setup_locked](../../scripts/lib/qmd_index.sh).
- El marcador de setup y el de migración representan hechos distintos. Completar el setup con un índice heredado deja la migración pendiente; solo la ausencia del marcador de migración, junto al índice existente, determina ese estado. Fuente: `qmd_collection_migration_state` y `_qmd_setup_locked`, en la misma biblioteca.
- Las dos pruebas existentes `refreshes ... when sentinel missing though index present` y `re-entrant setup ... does NOT write the layout sentinel` pasan en bash 5.3.15 y 3.2.57. Comando: `bats --tap tests/qmd-setup.bats -f 'refreshes|re-entrant'`, con el bash de cada entorno. Esto confirma el comportamiento del setup; **no reproduce el rojo del e2e**.
- La prueba de migración contiene dos aserciones intermedias `[[ ... ]]`, una sobre el setup y otra sobre el marcador de migración. La regla del proyecto exige aserciones cuyo fallo termine la prueba en ambos bash soportados.

**Pendiente de medir:** un fallo provocado por esta carrera en la prueba completa. El issue y el [registro de 043](../043-e2e-lock-race-hardening/tasks.md) describen el mecanismo y una coincidencia de procesos, pero no acreditan una corrida que haya fallado por esta causa. La reproducción controlada forma parte de la aceptación de esta feature.

Fuente externa: [issue #117](https://github.com/rodrigo-hinojosa-labs/agentic-pod-launcher/issues/117).

## Clarifications

### Session 2026-11-24

- Q: ¿Qué evidencia exigimos antes de abrir el PR del fix #117? → A: Reproducción y validación local, más una corrida manual verde del workflow e2e existente en CI (Linux amd64) antes del PR, con la prueba afectada ejecutada sin salto.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Una migración sana pasa cualquiera sea la velocidad de arranque (Priority: P1)

El mantenedor ejecuta el e2e de una instalación heredada. La prueba conserva su objetivo de migrar en el primer reindex y da el mismo resultado si el proceso de setup de arranque ya fue atendido o si todavía no recibió tiempo de ejecución.

**Why this priority**: elimina el falso rojo sin convertir la prueba en una aceptación de cualquier estado final ni cambiar el comportamiento del agente.

**Independent Test**: ejecutar el escenario con los dos órdenes controlados de arranque. En ambos, comprobar el estado heredado antes del primer reindex, la migración efectuada por ese reindex y la ausencia de una segunda migración al repetirlo.

**Acceptance Scenarios**:

1. **Given** una instalación heredada válida con migración pendiente, **When** el setup de arranque es atendido antes de la comprobación inicial, **Then** la precondición de la prueba sigue siendo válida y el primer reindex efectúa la migración esperada.
2. **Given** la misma instalación heredada, **When** el setup de arranque todavía no ha sido atendido al comprobar la precondición, **Then** la prueba obtiene el mismo resultado sin depender de ganarle una carrera al arranque.
3. **Given** el primer reindex completado, **When** se examina su evidencia, **Then** consta una sola migración de la colección heredada al contenido de la wiki, con las operaciones de reemplazo en el orden requerido y el estado de migración completada.
4. **Given** la migración completada, **When** se ejecuta un segundo reindex que efectivamente consigue correr, **Then** no aparecen nuevas operaciones de reemplazo de la colección.

---

### User Story 2 - Una migración defectuosa deja un rojo útil (Priority: P2)

El mantenedor necesita que estabilizar el e2e conserve su capacidad de detectar una regresión. Si faltan la migración, su confirmación o la idempotencia, la prueba debe fallar con evidencia suficiente para identificar la condición incumplida.

**Why this priority**: una prueba estable que pierde su capacidad de fallar daría confianza falsa y dejaría el defecto sin una regresión verificable.

**Independent Test**: introducir por separado una migración omitida, una confirmación de migración ausente y una migración repetida. Cada defecto debe ser detectado en los dos bash soportados; las fallas del e2e deben conservar el diagnóstico del contenedor.

**Acceptance Scenarios**:

1. **Given** un primer reindex sin migración, **When** la prueba evalúa el resultado, **Then** falla aunque el comando haya terminado con código cero.
2. **Given** operaciones de migración registradas pero sin confirmación de que terminó, **When** la prueba verifica esa confirmación, **Then** falla en ambas versiones de bash soportadas.
3. **Given** una segunda ejecución que vuelve a reemplazar la colección, **When** se comprueba la idempotencia, **Then** la prueba falla.
4. **Given** una ejecución que no consigue correr o excede su espera permitida, **When** se evalúa el resultado, **Then** no se acepta como migración ni como demostración de idempotencia y se conserva el diagnóstico existente.

### Edge Cases

- Índice heredado con setup completado y migración todavía pendiente: ambas condiciones pueden coexistir y no deben confundirse.
- Estado ya migrado antes del primer reindex: no sirve como precondición para demostrar que ese reindex realiza la migración.
- Arranque rápido que termina antes de la primera inspección y arranque tardío que todavía no ejecutó su setup.
- Lock ocupado por otro reindex: conservar la espera acotada y el diagnóstico existentes, sin interpretar un salto con código cero como trabajo ejecutado.
- Registro del motor todavía inexistente durante la espera inicial: conservar la tolerancia incorporada por 043 para #109.
- Comando de inspección fallido: no interpretar la falta de evidencia como confirmación de la precondición ni de la migración.
- Migración registrada pero sin su marcador de confirmación, o con estado final distinto de completado.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: El escenario MUST comenzar con una instalación heredada cuya migración siga pendiente antes del primer reindex. El estado inicial MUST distinguir setup completado de migración completada.
- **FR-002**: La validez de esa precondición MUST ser independiente de que el proceso de setup de arranque haya sido atendido antes o después de la inspección inicial. La solución MUST NOT consistir en aumentar esperas ni timeouts para esconder la carrera.
- **FR-003**: La prueba MUST demostrar que el primer reindex efectúa una sola migración desde la colección heredada a la colección limitada a la wiki. MUST conservar las comprobaciones de orden de reemplazo, confirmación y estado final ya exigidas por la prueba.
- **FR-004**: La prueba MUST ejecutar un segundo reindex y demostrar que no repite el reemplazo de la colección.
- **FR-005**: Ambos reindex MUST conservar la espera acotada ante contención, la comprobación de que la ejecución consiguió correr y la validación de su resultado. Un salto por lock ocupado MUST NOT contar como una ejecución válida.
- **FR-006**: Toda aserción de la prueba modificada MUST poder hacerla fallar en bash 3.2 y 5.x, incluso cuando después existan otros comandos exitosos. Las inspecciones requeridas MUST validar su resultado antes de usarlo como evidencia.
- **FR-007**: Las fallas MUST conservar el volcado de diagnóstico del contenedor y el reporte existente de contención y vencimiento. La espera inicial MUST seguir tolerando que el registro del motor todavía no exista.
- **FR-008**: La validación MUST reproducir de forma controlada el supuesto incorrecto de la prueba anterior y comprobar el escenario corregido con los dos órdenes de arranque. MUST distinguir esa evidencia de cualquier observación de CI sin inyección.
- **FR-009**: La validación MUST demostrar que una migración omitida, una confirmación ausente y una migración repetida producen un fallo. La cobertura ejecutable en el host MUST funcionar sin Docker. Antes de abrir el PR, la aceptación MUST incluir reproducción y validación local, una corrida real en contenedor y una corrida manual verde del workflow e2e existente en CI (Linux amd64) sobre el código corregido, con la prueba afectada ejecutada sin salto. El registro MUST identificar el commit validado y enlazar la corrida de CI.
- **FR-010**: El cambio MUST limitarse a la prueba afectada, su cobertura de regresión, los fixtures o ayudantes de prueba que necesite y su documentación. El comportamiento del launcher y de los agentes desplegados MUST permanecer idéntico.

### Key Entities

- **Instalación heredada**: índice existente que aún usa la colección anterior; puede tener setup completado y seguir necesitando migración.
- **Estado de setup**: confirma que terminó la preparación inicial; no equivale a migración completada.
- **Estado de migración**: pendiente antes del primer reindex y completado después de migrar a la wiki.
- **Ejecución de reindex**: intento con evidencia de que consiguió correr, resultado y operaciones observadas; un salto por contención no representa ejecución.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Los dos órdenes controlados de arranque dan el mismo resultado sano y conservan la precondición de migración pendiente antes del primer reindex.
- **SC-002**: Por cada escenario sano se observa exactamente un reemplazo de la colección en el primer reindex y cero reemplazos adicionales en el segundo.
- **SC-003**: Los tres defectos controlados de US2 (migración omitida, confirmación ausente y migración repetida) son detectados, sin falsos verdes, en ambos entornos de shell soportados.
- **SC-004**: El supuesto que origina #117 se demuestra con una reproducción controlada sobre la prueba anterior; la prueba corregida supera el escenario equivalente en contenedor real. El registro permite distinguir cada resultado y su causa.
- **SC-005**: Antes de abrir el PR, la cobertura de regresión ejecutable sin contenedor y los checks del proyecto pasan en ambos entornos soportados; la reproducción y validación local están registradas, la prueba e2e modificada pasa en contenedor real y una corrida manual del workflow e2e en CI (Linux amd64) termina verde con esa prueba ejecutada sin salto. La evidencia identifica el commit validado y el enlace a la corrida.
- **SC-006**: El cambio deja cero diferencias en los archivos de ejecución del launcher y de los agentes, no cambia su versión de producto y no aumenta los presupuestos de espera existentes.

## Assumptions

- Se conserva el propósito original de la prueba: migración en el primer reindex, seguida de una comprobación de idempotencia. La forma concreta de preparar y observar el estado inicial corresponde al plan.
- Feature de pruebas y documentación, sin bump de `VERSION`, siguiendo el precedente de 043. El producto actual ya contempla el caso de índice presente sin setup completado.
- Se reutiliza el motor de prueba existente. Este e2e valida la orquestación de la migración, no el embed semántico con el motor real.
- La reproducción inducida será evidencia de la carrera bajo condiciones controladas; no establecerá su frecuencia en CI ni afirmará que ya produjo una nocturna roja. El protocolo distinguirá el fallo esperado de la aserción anterior en bash 5.x de su posible ocultamiento en bash 3.2: no exigirá que la versión anterior falle en ambos para reconocer el defecto.
- Las fases siguientes definirán el arnés de reproducción, los controles negativos y el protocolo de ejecución. Docker no se ha utilizado en esta fase de especificación.
- El issue #120 sobre exclusión mutua de la migración manual y los issues #131 y #142 quedan fuera de esta feature. También quedan fuera otras carreras o aserciones de otras pruebas.
- Se trabajará en una rama del checkout principal. Cada fase de Spec Kit se invoca por separado; publicar cambios, abrir PR y hacer merge conservan sus compuertas de autorización.
