# Feature Specification: Self-Managing RAG (auto-setup + auto-reindex del vault QMD)

**Feature Branch**: `010-self-managing-rag`

**Created**: 2026-06-28

**Status**: Draft

**Input**: User description: "RAG que funciona solo (F1): instalación y reindexación automáticas, zero-touch y opt-in, del motor de búsqueda QMD (@tobilu/qmd) sobre el vault Obsidian del agente, para que la búsqueda semántica del vault esté siempre fresca sin intervención manual."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Auto-setup del RAG al boot (Priority: P1)

El operador habilita QMD en `agent.yml` y levanta el agente. Sin ningún paso manual, en el primer boot el agente deja el motor de búsqueda semántica del vault operativo: descarga y cachea el modelo de embeddings de forma persistente y construye el índice inicial sobre el contenido del vault. En reinicios posteriores el agente reutiliza el modelo y el índice ya presentes en vez de rehacerlos.

**Why this priority**: Es la condición de entrada de todo el RAG. Sin el modelo cacheado y un índice inicial, la búsqueda semántica simplemente no existe; hoy el operador tendría que entrar al contenedor y correr comandos a mano — algo que un agente headless 24/7 nunca hace. Sin US1 no hay nada que mantener fresco.

**Independent Test**: Con QMD habilitado y un vault sembrado, bootear el agente y verificar que (a) el modelo queda cacheado en el estado persistente, (b) existe un índice consultable del vault, (c) un segundo boot no rehace la descarga ni la reindexación completa. Entrega valor por sí solo: búsqueda semántica disponible tras el primer arranque.

**Acceptance Scenarios**:

1. **Given** QMD habilitado en `agent.yml` y un vault con contenido, **When** el agente arranca por primera vez, **Then** el modelo de embeddings queda cacheado en el estado persistente y existe un índice inicial del vault, sin intervención manual.
2. **Given** un agente ya inicializado (modelo e índice presentes), **When** reinicia, **Then** detecta que el setup ya está hecho y no repite la descarga del modelo ni una reindexación completa innecesaria.
3. **Given** QMD habilitado pero el setup falla (p. ej. sin red para bajar el modelo), **When** el agente arranca, **Then** registra el fallo, continúa el resto del boot con normalidad y reintenta el setup en el próximo arranque (degradación con gracia, el supervisor no se cuelga).

---

### User Story 2 - Reindexación automática con doble disparador (Priority: P1)

Cuando el contenido del vault cambia —lo escriba el propio agente, una herramienta de edición, o una sincronización externa (Syncthing)— el índice se actualiza solo, sin que nadie dispare la reindexación. La frescura está garantizada por dos mecanismos complementarios: uno inmediato que reacciona al cambio, y uno periódico de respaldo que cubre cualquier evento perdido. Una ráfaga de muchos cambios seguidos produce una sola reindexación, no una por archivo.

**Why this priority**: Un índice que se queda obsoleto tras el primer boot es tan inútil como no tener índice: las búsquedas devuelven resultados desactualizados y el operador vuelve a depender de pasos manuales. La frescura automática es el corazón de "RAG que funciona solo". Es P1 junto con US1 porque ambos son necesarios para el MVP funcional.

**Independent Test**: Con el RAG ya operativo (US1), modificar el contenido del vault y verificar que el índice refleja el cambio en segundos sin acción humana; provocar una ráfaga de cambios y verificar que se ejecuta una única reindexación; matar el mecanismo inmediato y verificar que el respaldo periódico igualmente reindexa.

**Acceptance Scenarios**:

1. **Given** el RAG operativo y el vault en reposo, **When** se agrega o edita una nota del vault, **Then** el índice incorpora el cambio dentro de un margen breve (decenas de segundos) sin intervención manual.
2. **Given** una ráfaga de múltiples escrituras consecutivas (p. ej. una ingesta de varias notas), **When** la ráfaga termina, **Then** se ejecuta una sola reindexación que cubre todos los cambios, evitando una reindexación por archivo.
3. **Given** que el mecanismo de reacción inmediata deja de estar disponible (su proceso muere), **When** el contenido del vault cambia, **Then** el mecanismo de respaldo periódico reindexa de todos modos dentro de su ventana, y el proceso de reacción inmediata es resucitado.
4. **Given** que el mecanismo inmediato y el periódico coinciden en el tiempo, **When** ambos intentan reindexar a la vez, **Then** solo una reindexación se ejecuta y la otra se descarta de forma segura, sin corromper el índice ni el estado.
5. **Given** un cambio que no altera el contenido efectivo del vault (mismo hash), **When** se dispara una reindexación, **Then** el paso costoso de cómputo de embeddings se omite (no se rehace trabajo idéntico).

---

### User Story 3 - Versión reproducible y configuración validada (Priority: P2)

El operador puede confiar en que el motor de búsqueda usa una versión fija y conocida (no "la última que haya hoy"), y en que una configuración de vault/QMD mal escrita en `agent.yml` es rechazada con un error claro durante el scaffolding, en vez de fallar silenciosamente en runtime.

**Why this priority**: Reproducibilidad y diagnóstico temprano. La versión flotante hace que dos scaffolds del "mismo" agente difieran y rompe la auditabilidad de upgrades (Principio VI). La validación de schema convierte un typo de configuración en un error inmediato y legible. Es P2 porque el RAG puede funcionar sin ello, pero queda frágil y no reproducible.

**Independent Test**: Verificar que la plantilla del MCP referencia una versión fija (no flotante) del motor QMD; y que el validador de schema rechaza una configuración de vault/QMD inválida (tipo o valor fuera de dominio) y acepta una válida.

**Acceptance Scenarios**:

1. **Given** dos scaffolds del mismo `agent.yml` en momentos distintos, **When** se renderiza la configuración del MCP, **Then** ambos referencian la misma versión fija del motor de búsqueda.
2. **Given** un `agent.yml` con una clave de vault/QMD con tipo o valor inválido, **When** se valida el schema, **Then** la validación falla con un mensaje que identifica la clave ofensora.
3. **Given** un `agent.yml` con la configuración de vault/QMD bien formada, **When** se valida el schema, **Then** la validación pasa.

---

### Edge Cases

- **QMD deshabilitado**: Si QMD no está habilitado en `agent.yml`, ninguna de estas rutas se activa — sin descarga del modelo, sin watcher, sin entrada de cron, sin overhead. Todo el código nuevo es no-op para agentes que no usan QMD.
- **Vault vacío en el primer boot**: El setup produce un índice vacío válido (no un error); cuando luego se agrega contenido, la reindexación automática lo incorpora.
- **inotify no soportado bajo el bind-mount**: Si el mecanismo de reacción inmediata no puede observar el directorio del vault con el modelo de privilegios actual, el sistema degrada al respaldo periódico (el índice sigue fresco, solo con mayor latencia) y lo registra; no se cuelga ni se eleva el privilegio del contenedor.
- **Modelo no descargable (sin red)**: El setup falla-silencioso, el boot continúa, y se reintenta en el próximo arranque.
- **Vault muy grande (setup excede el tiempo acotado)**: La operación está acotada por timeout; si lo excede, se registra y se reintenta luego, sin bloquear el resto del boot.
- **Reindexación más lenta que el intervalo periódico**: El guard de exclusión mutua evita solapamiento; un disparo que cae mientras otro corre se descarta.
- **Watcher en bucle de reinicio**: La supervisión del watcher es un chequeo determinístico de "¿proceso vivo?"; no reintroduce detección heurística (la del "bridge watchdog" revertido por falsos positivos).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: El sistema MUST, cuando QMD está habilitado en `agent.yml`, dejar el motor de búsqueda semántica del vault operativo durante el boot sin requerir ningún paso manual del operador.
- **FR-002**: El sistema MUST cachear el modelo de embeddings en el estado durable del agente, de modo que persista entre reinicios y rebuilds de imagen (no se re-descargue en cada arranque).
- **FR-003**: El sistema MUST construir un índice inicial del contenido del vault en el primer boot con QMD habilitado, y MUST detectar en boots posteriores que el setup ya está hecho para no rehacerlo (idempotencia por presencia/hash, nunca por mtime).
- **FR-004**: El sistema MUST reindexar automáticamente tras un cambio en el contenido del vault, independientemente del origen del cambio (agente, herramienta de edición, o sincronización externa).
- **FR-005**: El sistema MUST coalescer una ráfaga de cambios consecutivos en una sola reindexación mediante una ventana de reposo (debounce), evitando una reindexación por archivo.
- **FR-006**: El sistema MUST proveer un mecanismo de respaldo periódico que reindexe en una ventana acotada aunque el mecanismo de reacción inmediata haya fallado o perdido un evento.
- **FR-007**: El sistema MUST garantizar que reacción inmediata y respaldo periódico no se solapen: si una reindexación está en curso, otro disparo concurrente se descarta de forma segura (exclusión mutua), sin corromper índice ni estado.
- **FR-008**: El sistema MUST omitir el paso costoso de cómputo de embeddings cuando el contenido efectivo del vault no cambió, usando un hash de contenido (igual criterio que el respaldo del vault).
- **FR-009**: El sistema MUST resucitar el proceso de reacción inmediata si su proceso muere, mediante un chequeo determinístico de "proceso vivo" en el ciclo de supervisión existente, sin reintroducir detección heurística previamente revertida.
- **FR-010**: El sistema MUST persistir el estado de la última reindexación (timestamp, hash del índice, contadores) en un archivo de estado atómico, con la misma forma que los demás archivos de estado del agente.
- **FR-011**: Toda invocación del motor de búsqueda en la ruta de boot MUST estar acotada por timeout y MUST fallar-silenciosa (registrar y continuar), sin colgar el supervisor antes de que actúe el watchdog.
- **FR-012**: Cuando QMD no está habilitado en `agent.yml`, el sistema MUST ser un no-op completo: sin descarga de modelo, sin watcher, sin entrada de cron, sin overhead.
- **FR-013**: El sistema MUST referenciar una versión fija y explícita del motor de búsqueda QMD (no una referencia flotante a "la última"), con una única fuente de verdad para esa versión (sin pins duplicados nuevos).
- **FR-014**: El sistema MUST validar las claves de configuración de vault/QMD de `agent.yml` durante el scaffolding, rechazando tipos o valores fuera de dominio con un mensaje que identifique la clave ofensora.
- **FR-015**: Todo el comportamiento MUST sobrevivir `./setup.sh --regenerate` (re-render desde `agent.yml`) y MUST preservar el modelo de menor privilegio del contenedor (sin nuevas capabilities ni mounts privilegiados).

### Key Entities *(include if feature involves data)*

- **Bandera de habilitación de QMD**: La decisión opt-in en `agent.yml` que activa o desactiva todo el subsistema RAG. Determina si el resto de las entidades existen.
- **Modelo de embeddings**: Artefacto descargable (~300MB) cacheado en el estado durable del agente; entrada del cómputo semántico. Persistente entre reinicios.
- **Índice del vault**: Representación consultable derivada del contenido del vault; lo que sirve las búsquedas semánticas. Se construye en setup y se mantiene fresco por reindexación.
- **Hash de contenido del vault**: Huella sha256 sobre contenido + nombres de los archivos del vault; criterio de idempotencia que decide si una reindexación tiene trabajo real que hacer.
- **Estado de reindexación**: Registro atómico de la última reindexación (timestamp, hash del índice, contadores) para observabilidad y para la decisión de idempotencia.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Con QMD habilitado, un agente recién scaffoldeado deja la búsqueda semántica del vault operativa tras el primer boot con **cero** pasos manuales del operador.
- **SC-002**: Tras un cambio en el contenido del vault, el índice refleja ese cambio en **menos de 60 segundos** sin intervención humana, por la vía de reacción inmediata.
- **SC-003**: Aun si la reacción inmediata está caída, el respaldo periódico mantiene el índice fresco dentro de su ventana acotada (**≤ 5 minutos** desde el cambio).
- **SC-004**: Una ingesta de N notas en ráfaga produce **una sola** reindexación (no N), verificable por el conteo de pasadas de embedding.
- **SC-005**: Reacción inmediata y respaldo periódico **nunca** producen una reindexación solapada ni corrompen el índice/estado, bajo disparos concurrentes.
- **SC-006**: Un segundo boot, sin cambios en el vault, **no** re-descarga el modelo ni rehace la reindexación completa.
- **SC-007**: Para un agente con QMD deshabilitado, el overhead de esta feature en boot y en runtime es **cero** (no se ejecuta ninguna ruta nueva).
- **SC-008**: Dos renders del mismo `agent.yml` referencian la **misma** versión fija del motor de búsqueda (reproducibilidad).
- **SC-009**: Una configuración de vault/QMD inválida en `agent.yml` es **rechazada** durante el scaffolding con un mensaje accionable; una válida pasa.

## Assumptions

- **Runtime de embeddings presente**: El runtime requerido por el motor QMD ya está instalado y pinneado en la imagen; esta feature no lo agrega, solo lo usa.
- **Vault ya existe**: El skeleton del vault y su siembra en boot ya están implementados; esta feature opera sobre ese vault, no lo rediseña.
- **Versión estable del motor**: Se pinea a la release estable confirmada del motor QMD, **v2.5.3** (la `latest` en npm al 2026-06-28; ver research D1). La versión 0.4.4 que se asumió en el brainstorm NO existe en npm — la fase de research lo corrigió. De aparecer una incompatibilidad en 2.5.3 durante la implementación, se documenta y se ajusta el pin, manteniendo una única fuente de verdad (`agent.yml` `vault.qmd.version`).
- **Reacción inmediata vía observación del filesystem**: El mecanismo inmediato observa el directorio del vault a nivel de filesystem (no depende de que el agente "recuerde" disparar), lo que captura cambios de cualquier origen, incluida la sincronización externa.
- **Respaldo periódico vía el planificador existente**: El respaldo usa el planificador de tareas ya presente en el contenedor (cron), con una entrada propia.
- **Caché en el estado durable**: El modelo y el índice viven bajo el estado bind-mounteado del agente, por lo que sobreviven `down -v`, rebuilds y `--uninstall` no destructivo; nunca se commitean ni se loguea su contenido.
- **Opt-in zero-touch**: El subsistema solo existe cuando el operador lo habilita; los agentes que no usan QMD no pagan ningún costo.

## Dependencies

- **Configuración de QMD/vault en `agent.yml`** como única fuente de verdad (Principio I): la habilitación, la ruta del vault y los parámetros relevantes se derivan de ahí.
- **Estado durable del agente** (`.state/`, Principio V) para cachear el modelo y el índice y para los archivos de estado.
- **Planificador de tareas (cron) del contenedor** para el respaldo periódico.
- **Ciclo de supervisión del boot** (watchdog del supervisor) para resucitar el proceso de reacción inmediata.

## Out of Scope

- Rediseñar el esquema del vault o sus plantillas (el skeleton del vault queda igual).
- Reemplazar el MCP de búsqueda por keyword existente (la búsqueda por keyword coexiste con la semántica).
- Cambiar el flujo de auth/login, el contrato del canal Telegram, o el catálogo de plugins.
- Rediseñar el modelo de backup (las tres ramas huérfanas).
- Tuning fino de los parámetros de ranking del motor (más allá de sus defaults).
- La rotación de secretos del agente de prueba (responsabilidad del operador).
