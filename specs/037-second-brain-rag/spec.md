# Feature Specification: Second Brain sobre el LLM Wiki — eje PARA, higiene del retrieval, cola de revisión, packets y favorite problems

**Feature Branch**: `037-second-brain-rag`

**Created**: 2026-09-26

**Status**: Draft

**Input**: User description: "Mejorar el sistema RAG del vault: investigar el patrón Second Brain de Tiago Forte (PDF entregado), potenciar el RAG que ya tenemos con el LLM Wiki de Andrej Karpathy y aplicar un mix con Second Brain para tener todo mejor estructurado. Usar spec-kit; refinar con AskUserQuestion; leer todo el repo antes de diseñar."

## Contexto

El discovery de esta feature (nueve informes, 2.900 líneas, base `main` @ `70214d9`, VERSION
0.26.0; síntesis con 41/41 citas de código verificadas por una pasada adversarial) estableció
qué existe, qué falta y qué no conviene tocar. Lo verificado:

- **(a) El LLM Wiki de Karpathy ya está implementado completo en el skeleton del vault**
  (features 010 a 019): `raw_sources/` inmutable, `wiki/` con seis tipos cerrados (`summary`,
  `entity`, `concept`, `comparison`, `overview`, `synthesis`, "the only six",
  `modules/vault-skeleton/CLAUDE.md:32-46`) más `wiki/normalization/` como carpeta-convención
  de 014, `CLAUDE.md` del vault como schema co-evolucionado que ningún script reescribe,
  `index.md` + `log.md`, protocolos ingest/query/lint, linter determinista con grafo derivado
  bajo `<vault>/.graph/` (`scripts/lib/wiki_graph.sh`, seis kinds de hallazgo, cron `20 */6`
  en ambos modos) y búsqueda híbrida qmd 2.5.3 con ciclo de vida completo. Doce de los
  veintidós elementos del gist están completos, siete parciales, tres ausentes.
- **(b) La palanca "retriever" está saturada.** La crítica de Karpathy al RAG no es de
  precisión sino de acumulación ("no accumulation"). Mejorar el RAG aquí son tres palancas
  distintas: compilación más densa, navegación index-first y una dimensión de accionabilidad
  encima de lo que existe.
- **(c) El protocolo de query no lee `index.md` primero** aunque lo mantiene y lo lintea
  (`vault-skeleton/CLAUDE.md:118-119` manda a `search_notes`/Glob/Grep; el gist dice "reads
  the index first").
- **(d) qmd indexa todo el markdown del vault en una sola colección sin exclusiones**
  (`scripts/lib/qmd_index.sh:379`, máscara `**/*.md` sobre la raíz): entran `CLAUDE.md`,
  `index.md`, `log.md`, `_templates/*.md` (incluido el delta 0.8.0), `raw_sources/**` y
  `normalization/`. Cada consulta compite contra plantillas vacías, la bitácora, el schema y
  el texto crudo que ya está resumido. Nadie lo midió; el prior art lo llama "gravity wells".
- **(e) "Project" ya tiene dos casas** con una regla "don't double-write" escrita en dos
  lugares: `entity` del vault admite "project" (`CLAUDE.md:39`) y la auto-memoria guarda
  `project_*` como "ongoing project state" (`docs/state-layout.md:49`; `MEMORY.md` se
  trunca a 200 líneas). No hay `goal`, `due`, `next_action` ni cola de revisión en ninguna.
- **(f) El linter es rígido donde no debe y ciego donde no debe**: `VALIDTYPE`/`VALIDSTATUS`
  hardcodeados (`wiki_graph.sh:111-114`); toda clave de frontmatter fuera de las once
  conocidas se ignora en silencio (`:202-227`), así que `para: projet` pasa; `tags` no se
  extrae pese al contrato de 014; solo `wikilinks` del cuerpo, `related:` y `sources:`
  generan aristas.
- **(g) No hay ejecución LLM programada utilizable para revisiones**: el heartbeat es
  docker-only, un solo prompt, config aislado sin plugins, y no toca el vault; local no tiene
  tick LLM (`modules/claude-md.tpl:92`); `local_schedule.sh:44-47` no convierte crons con día
  de semana. El "lint agéntico programado" quedó en backlog de 014 por costo de tokens.
- **(h) El upgrade aditivo existe pero está cableado a un solo delta**: `vault_seed_missing`
  (`scripts/lib/vault.sh:70-112`) deposita `schema-updates-0.8.0.md` gateado por un marcador
  oculto; un segundo delta necesita bloque y marcador propios; nadie verifica que el agente
  haya integrado el delta a su `CLAUDE.md` co-evolucionado; `--login` local no lo corre (solo
  boot docker y `--regenerate`).
- **(i) Config muerta en `agent.yml`**: `vault.initial_sources`, `vault.mcp.server`,
  `vault.schema.frontmatter_required`, `vault.schema.log_format` se escriben y nadie los lee.
- **(j) La flota real tiene escala**: el vault de Cencosud en ferrari tenía 2.696 páginas en
  el gate de 08-07-2026; `qmd embed` corta a los 30 min por sesión (018 midió 859/2.423
  chunks), así que un re-embed completo allí costaría cerca de 85 minutos. **Medido el
  26-09-2026 (discovery L)**: qmd 2.5.3 indexa los vectores por hash de contenido + modelo, y
  `collection remove` + `collection add` no los toca, así que recrear la colección sobre las
  mismas páginas reutiliza los embeddings y cuesta segundos de re-scan léxico; el costo de 85
  minutos solo aparece si el contenido cambia o si se corre `qmd cleanup` entre medio.
- **(k) Forte (Second Brain) no define formato de nota, ni schema, ni consistencia, ni
  agente**: presupone un humano. Su weekly review es de bandejas (no de proyectos); los
  proyectos y áreas se revisan en la monthly review. La resonancia, la autoría de los
  favorite problems y la decisión de cerrar un proyecto son humanas. Karpathy no menciona
  PARA ni nada de Forte; su "append-and-review note" es el anti-PARA. **037 es una extensión
  propia**, amparada por la cláusula "everything is optional and modular" del gist.
- **(l) Prior art (más de 20 sistemas LLM+wiki/PARA, 2025-2026)**: nadie modela PARA como
  tipo de conocimiento (siempre frontmatter o status); todos separan cola determinista,
  ejecución LLM y decisión humana; decay por acceso y confidence numérico fueron desmontados
  por quienes los probaron en producción; "letting models write on hooks corrupts it
  silently"; medir uso, no volumen (collector's fallacy).
- **(m) Decisiones previas que no se re-litigan** (D §2, ratificadas en 014 y sucesivas):
  sin séptimo `type`; ningún script edita `wiki/`, `raw_sources/` ni el `CLAUDE.md` del
  vault; entrega de schema por delta, nunca append ni reemplazo; sin skill `/vault:*`; sin
  bump casual de qmd (2.5.3 pineado, guardrails en tests); derivados = JSON bajo `.graph/`,
  jamás respaldados.

## Clarifications

### Session 2026-09-26 (ronda AskUserQuestion previa a la spec, dos rondas de cuatro)

- Q: ¿Qué alcance tiene 037? → A: **(c) ambicioso**: además del eje PARA, la higiene del índice, las operaciones de proyecto y la cola de revisión, entran packets como unidad de recuperación, favorite problems como filtro de captura, candidatos a archivo por criterios deterministas (solo propuesta), heartbeat de aviso y claves nuevas en `agent.yml`. Elegido contra la recomendación (a)+(b).
- Q: ¿Dónde vive la clasificación PARA? → A: **Frontmatter** (`para:` sobre los seis tipos existentes); ausente = resource; archivo = `para: archive` + `archived:` en el mismo archivo; sin carpetas PARA.
- Q: ¿037 corrige la higiene del índice qmd? → A: **Sí, colección con alcance `wiki/`**, migración única como acción explícita con aviso (**superada el 2026-09-27**, ver sesión siguiente), sentinel bajo `.state`, sin bump del pin; `raw_sources` sigue accesible por Grep y `search_notes`.
- Q: ¿Cómo se dispara la revisión y con qué cadencia? → A: **Cola determinista** (hallazgo `review_due` derivado de `next_review`, calculado por el runner del grafo existente) con ejecución en sesión; **cadencia semanal** por defecto para proyectos (política del operador, no de Forte; áreas mensual).
- Q: Con alcance (c), ¿cómo se entrega? → A: **Una spec, un PR**: todo (c) en la rama `037-second-brain-rag`, gate de hardware completo antes del merge (precedente 024). Elegido contra la recomendación de dos PRs.
- Q: ¿Dónde vive la ficha de proyecto? → A: **Vault + puntero**: página `entity` con `para: project`; la auto-memoria `project_<slug>.md` queda como puntero de 2-3 líneas; el delta trae nota de migración para los `project_*` existentes.
- Q: ¿Qué papel juega el heartbeat multi-prompt de (c)? → A: **Opt-in, solo avisa**: el heartbeat gana un aviso programado de revisión (docker) que informa al canal cuando hay `review_due`/`pending_ingest`; la revisión la hace el agente en sesión; local sigue sin tick LLM, documentado.
- Q: ¿Idioma del schema, plantillas y delta? → A: **Inglés**, consistente con el skeleton, el delta 0.8.0, docs y README; el agente sigue hablando en `user.language`.

### Session 2026-09-26 (speckit-clarify, una ronda de cuatro)

- Q: ¿El aviso de heartbeat es una entrada semanal aparte con su propio prompt, o un mapa de prompts por día de semana sobre el heartbeat regular? → A: **Entrada semanal aparte**: una línea de cron adicional que invoca el heartbeat con `--prompt` propio (mecanismo que el runner ya acepta); el prompt regular no se toca; con `enabled` false el heartbeat es byte-idéntico a hoy.
- Q: ¿Qué recibe el canal cuando el aviso corre con la cola vacía? → A: **Una línea "sin pendientes"**, a lo más una por semana: distingue "nada que revisar" de "heartbeat muerto" y no exige cambio en los notifiers.
- Q: ¿Qué paquete de umbrales y cadencias por defecto parte? → A: **Paquete propuesto**: proyecto 7 días, área 30 días, `archive_candidate` 90 días, `schema_delta_pending` 14 días, `problem_unfed` 30 días, `index.md` completo solo bajo 300 páginas. Todos configurables; la Fase 0 solo puede recomendar ajustes con medición.
- Q: ¿Quién calcula los "loops abiertos" de la weekly review? → A: **El runner**: hallazgo `project_overdue` cuando `due` es anterior a la fecha de la corrida, y `project_incomplete` se extiende a `next_action` ausente o vacío; el agente no infiere loops leyendo fichas.

### Session 2026-09-27 (plan, tras la medición de Fase 0)

- Q: La Fase 0 midió que recrear la colección qmd sobre `wiki/` reutiliza los embeddings y cuesta segundos, no ~85 minutos. Con la premisa corregida, ¿cómo se dispara la migración en los agentes existentes? → A: **Automática, una vez**: el primer tick de reindexado tras la actualización detecta la colección heredada (sentinel ausente) y la recrea con la máscara `wiki/**/*.md` (`remove` + `add` + `update` + `cleanup` después), escribe el sentinel al final y deja registro en el state file y el log; `heartbeatctl qmd-migrate` (docker) y `agentctl heartbeat qmd-migrate` (local) quedan como `--dry-run` y forzado manual. Reemplaza la decisión "acción explícita" de la sesión anterior.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Eje PARA de accionabilidad sobre los seis tipos (Priority: P1)

Como operador de un agente con vault, quiero que cada página del wiki pueda declarar su
accionabilidad (proyecto activo, área de responsabilidad, recurso, archivo) en su propio
frontmatter, sin cambiar los seis tipos ni mover archivos, con una ficha de proyecto que
lleve objetivo, fecha, próximo paso y próxima revisión, y una página de área que lleve su
estándar y cadencia; que `index.md` muestre esas vistas; que el linter valide el eje y
conecte las fichas al grafo; y que la ficha de proyecto sea la única casa del estado del
proyecto (la auto-memoria solo apunta a ella).

**Why this priority**: Es el núcleo de la feature. Hoy el vault responde "qué sé" pero no
"qué necesito ahora". Sin este eje, ninguna de las demás historias (revisión, packets,
archivo) tiene sobre qué operar.

**Independent Test**: Sobre la fixture del grafo extendida con páginas que declaran `para`,
correr el runner y verificar exactamente los hallazgos esperados (valor inválido, proyecto
incompleto), que las fichas enlazadas desde claves PARA no son huérfanas, que las páginas
archivadas no generan huérfano ni stale, y que el skeleton limpio sigue dando exactamente 0
hallazgos. Verificable en host, sin contenedor ni LLM.

**Acceptance Scenarios**:

1. **Given** una página con `para: projet` (valor fuera del enum), **When** corre el runner,
   **Then** se reporta una violación de frontmatter con la razón `para: invalid 'projet'` y la
   página afectada; la corrida no aborta. Un `para: ""` no es violación (valor vacío = clave
   ausente = resource).
2. **Given** una página `para: project` sin `goal`, sin `due` o con `next_action` ausente o
   vacío, **When** corre el runner, **Then** se reporta `project_incomplete` con los campos
   faltantes.
3. **Given** una página B cuyo frontmatter declara `project: [[entities/proyecto-x]]` (o
   `area:`/`problems:` con destino resoluble), **When** corre el runner, **Then** la ficha
   `proyecto-x` tiene a B como backlink y no aparece como huérfana; si el destino no existe
   se reporta como wikilink roto.
4. **Given** una página `para: archive` que nadie enlaza y cuya fuente cambió después de
   `updated`, **When** corre el runner, **Then** no se reporta ni `orphan` ni `stale` para
   ella; sigue siendo nodo del grafo y aparece en la sección Archive de `index.md`.
5. **Given** un vault existente donde ninguna página declara `para`, **When** corre el runner
   con la lib nueva, **Then** el eje no genera ningún hallazgo nuevo (ausente = resource) y
   los seis hallazgos previos son byte-idénticos a la versión anterior.
6. **Given** el skeleton recién sembrado, **When** corre el runner, **Then** exactamente 0
   hallazgos (el oráculo existente se conserva: ninguna página semilla nueva).
7. **Given** el skeleton nuevo, **When** se lee `index.md`, **Then** existen las secciones
   `Projects (active)`, `Areas` y `Archive` con su formato de línea, y las plantillas
   variante de ficha de proyecto y de página de área existen con los campos PARA
   documentados.
8. **Given** el schema del vault y la plantilla del `CLAUDE.md` del workspace, **When** el
   agente decide dónde guardar el estado de un proyecto, **Then** ambos documentan la misma
   regla: la ficha vive en el vault; la auto-memoria `project_<slug>.md` es un puntero de
   2-3 líneas (estado en una frase, wikilink a la ficha, fecha de última revisión), sin
   estado adicional; el delta trae la nota de migración para los `project_*` existentes.

---

### User Story 2 - Higiene del índice de búsqueda (Priority: P1)

Como agente que consulta el vault, quiero que la búsqueda híbrida compita solo entre
páginas del wiki: ni el schema, ni el índice, ni la bitácora, ni las plantillas, ni el texto
crudo ya resumido deben aparecer como resultados. Como operador, quiero que ese cambio
llegue solo a cada agente existente, una sola vez y sin acción manual, que quede registrado,
que el estado me diga si está pendiente o hecha, y poder ensayarlo o forzarlo a mano.

**Why this priority**: Es el gap de mayor impacto y menor costo del retrieval actual, y es
prerrequisito de las historias que agregan escrituras por sesión a `log.md` e `index.md`
(sin higiene, cada línea nueva empeora lo que 037 dice mejorar).

**Independent Test**: Con el seam de tests de qmd (019), verificar que un scaffold nuevo
crea la colección con la máscara `wiki/**/*.md` sobre la raíz del vault y escribe el sentinel;
que un agente con colección heredada (índice sin sentinel) migra solo en el primer tick de
reindexado en el orden remove → add → update → sentinel → cleanup (sin `embed` cuando no hay
pendientes), que el segundo tick es no-op y que una interrupción deja `pending` y se completa
al tick siguiente; que `qmd-migrate --dry-run` no toca nada; que `status` (ambos modos) y
`doctor` local reportan `pending`/`done`. Sobre una copia de un vault real, un set de
preguntas sonda no devuelve documentos de las rutas excluidas.

**Acceptance Scenarios**:

1. **Given** un agente recién scaffoldeado con vault y qmd habilitados, **When** se
   configura el índice por primera vez, **Then** la colección cubre solo `wiki/` y ningún
   documento de `_templates/`, `raw_sources/`, `index.md`, `log.md` ni `CLAUDE.md` del vault
   queda indexado; las URIs de las páginas (`qmd://vault/wiki/...`) no cambian respecto a hoy.
2. **Given** un agente existente con la colección heredada (todo el vault), **When** corre el
   primer tick de reindexado tras la actualización, **Then** detecta la colección heredada
   (sentinel ausente), la recrea con alcance `wiki/` reutilizando los embeddings (segundos),
   escribe el sentinel al final y deja una línea en el log del reindex y en el state file;
   hasta ese tick, `status`/`doctor` en ambos modos reportan "migración de colección
   pendiente" sin degradar.
3. **Given** la migración hecha (automática o forzada con `qmd-migrate`), **When** termina,
   **Then** la colección cubre solo `wiki/`, el sentinel está bajo el cache root de qmd en
   `.state` (nunca en el vault), `qmd embed` no tiene pendientes, los vectores huérfanos se
   purgaron después del `add`, y una segunda ejecución es un no-op que lo dice;
   `qmd-migrate --dry-run` muestra qué haría sin tocar nada.
4. **Given** la migración hecha y un set de preguntas sonda con respuesta conocida, **When**
   se consulta, **Then** 0 documentos de las rutas excluidas aparecen en el top-10, y 0
   duplicados raw/summary.
5. **Given** una pregunta que exige el texto crudo de una fuente, **When** el agente sigue
   el protocolo de query, **Then** llega a `raw_sources/` por Grep o por `search_notes`; el
   schema documenta esa vía.

---

### User Story 3 - Cola de revisión determinista y operaciones de proyecto (Priority: P1)

Como operador, quiero que el sistema me diga qué proyectos toca revisar y qué fuentes
quedaron sin procesar, calculado sin LLM y sin cron nuevo; y como agente, quiero
operaciones explícitas en el schema para abrir un proyecto (kickoff), cerrarlo (close),
hacer la revisión semanal (bandeja + loops abiertos + proyectos vencidos) y la mensual
(áreas, archivo, outcome), con los pasos mecánicos separados de los decisionales, más una
regla de cierre de sesión que deje el siguiente paso escrito.

**Why this priority**: PARA sin revisión es una etiqueta que nadie mantiene. La cola
determinista es la única forma de que la revisión ocurra en ambos modos sin gastar tokens
hasta que alguien hable con el agente.

**Independent Test**: Con la fecha "hoy" inyectable al runner y una fixture con fechas
remotas, verificar `review_due`, `project_overdue` y `pending_ingest` con 0 falsos positivos
y 0 falsos negativos; verificar que el schema documenta las cuatro operaciones, la regla de cierre y la
política de filing; verificar que ningún cron ni unit nuevos se renderizan en ningún modo.

**Acceptance Scenarios**:

1. **Given** una ficha `para: project` con `next_review` anterior a "hoy", **When** corre el
   runner, **Then** se reporta `review_due` con la página y los días de atraso; con
   `next_review` futuro no se reporta; con `next_review` ausente se reporta (la primera
   revisión fija la fecha); con `next_review` malformado se reporta violación de frontmatter
   y no `review_due`. **Given** la misma ficha con `due` anterior a "hoy", **Then** se
   reporta `project_overdue` con los días de atraso; `due` malformado es violación de
   frontmatter, no `project_overdue`.
2. **Given** una fuente `raw_sources/**/*.md` con `clipped:` y ninguna página `summary` que
   la cite en `sources:`, **When** corre el runner, **Then** se reporta `pending_ingest`; con
   un `summary` que la cita no se reporta; binarios sin `.md` hermano no entran al dominio.
3. **Given** el schema del vault, **When** el agente abre un proyecto, **Then** la operación
   kickoff instruye: registrar objetivo, fecha, próximo paso y próxima revisión según la
   cadencia por defecto; buscar páginas y packets relacionados por nombre, tags y texto; enlazarlos desde
   la ficha y agregar la ficha al `related:` de cada página enlazada; dejar el outline como
   Archipelago; registrar `project-open` en `log.md`.
4. **Given** el schema del vault, **When** el agente cierra un proyecto, **Then** la operación
   close instruye: marcar `para: archive` + `archived:`, extraer packets reutilizables,
   actualizar la sección Archive de `index.md`, actualizar el puntero de auto-memoria,
   registrar `project-close` en `log.md`; nunca mover ni borrar archivos.
5. **Given** el schema del vault, **When** el agente hace la revisión semanal, **Then** los
   pasos mecánicos (leer `findings.json`: `pending_ingest`, `review_due`, y los loops
   abiertos calculados por el runner: `project_overdue` y `project_incomplete`; proponer a
   lo más tres recomendaciones) están separados de los decisionales
   (archivar, cambiar fechas, cerrar), que son del humano; la revisión mensual cubre áreas,
   candidatos a archivo y outcome; ambas se registran en `log.md` con una línea, nunca con
   un archivo por revisión.
6. **Given** una sesión que tocó un proyecto, **When** termina, **Then** el schema exige
   `next_action` actualizado en la ficha y una línea `session | <proyecto> — next: …` en
   `log.md` (Hemingway Bridge).
7. **Given** una consulta que produjo una síntesis que cita tres o más páginas, **When**
   termina, **Then** el schema instruye proponer archivarla como página (filing) y registrar
   `query | … | filed: yes/no` en `log.md`, para medir la tasa de filing.
8. **Given** `findings.json` con `review_due` o `pending_ingest` mayores que cero, **When**
   el agente abre una conversación, **Then** el schema instruye ofrecer la revisión en el
   primer mensaje, sin ejecutar ningún cambio sin confirmación humana.
9. **Given** ambos modos, **When** se renderizan crontab y units, **Then** no hay ninguna
   entrada programada nueva para la revisión (la cadencia vive en las fechas `next_review`
   que el agente fija; `local_schedule.sh` no se toca). El aviso opt-in de US9 no es la
   revisión: solo informa la cola, no la ejecuta.

---

### User Story 4 - Navegación index-first gateada y destilación por capas (Priority: P2)

Como agente, quiero empezar cada consulta por el mapa y no por el buscador: leer las
páginas de visión general del dominio, las secciones PARA pertinentes de `index.md` y la
ficha del proyecto activo antes de buscar; y quiero que toda página nueva lleve una
descripción corta que sirva de gancho en el índice y que las páginas `summary` declaren su
capa de destilación, subiendo de capa solo cuando se las toca por otra razón.

**Why this priority**: Es la brecha más barata respecto al gist de Karpathy y la palanca
"distill on read" del prior art; pero debe gatearse por tamaño, porque leer 2.700 líneas por
consulta en el vault grande sería lo contrario de lo que promete.

**Independent Test**: Verificar en el schema el paso 0 con su gate; en las plantillas los
campos `description` y `distill` con las secciones opcionales; en el runner que
`description_missing` solo se reporta para páginas con `para:` o creadas después del delta y
con valor no vacío, y que un vault existente sin `description` no genera ninguno.

**Acceptance Scenarios**:

1. **Given** el schema del vault, **When** el agente inicia una consulta, **Then** el paso 0
   instruye leer las páginas `overview` del dominio (mapa de dos niveles), las secciones PARA
   pertinentes de `index.md` y la ficha del proyecto activo si existe; `index.md` completo
   solo si el wiki está bajo el umbral por defecto de 300 páginas (ajustable); recién después
   búsqueda híbrida y grafo.
2. **Given** las plantillas nuevas, **When** el agente crea una página, **Then** `description`
   (una línea, no vacía) es obligatorio y es el gancho que va a `index.md`; `summary.md`
   declara `distill` y trae el resumen ejecutivo arriba con secciones opcionales de
   destacados y núcleo.
3. **Given** una página con `para:` declarado o `created` posterior a la fecha del delta y
   sin `description` (o vacía), **When** corre el runner, **Then** se reporta
   `description_missing`; una página preexistente sin `para` ni `description` no genera nada.
4. **Given** el schema, **When** el agente toca una página por ingest, query o revisión,
   **Then** puede subir su capa de destilación en ese mismo acto; el schema prohíbe pases de
   destilación por lotes sobre todo el vault.

---

### User Story 5 - Packets como unidad de recuperación (Priority: P2)

Como agente que arranca un proyecto, quiero saber qué piezas reutilizables ya existen
(notas destiladas, descartes, borradores, entregables, material ajeno) antes de partir de
cero; y como operador quiero medir cuántas se reutilizan.

**Why this priority**: Es la palanca de "compilación" de Karpathy y los Intermediate
Packets de Forte en una sola pieza; da valor solo después de que existan fichas de proyecto
(US1) y kickoff (US3).

**Independent Test**: Sobre la fixture, páginas con `packet:` válidos producen un catálogo
derivado de packets con sus atributos; un valor inválido produce violación de frontmatter;
sin packets el catálogo existe vacío; el schema documenta su lectura en kickoff y la
métrica de reutilización.

**Acceptance Scenarios**:

1. **Given** páginas con `packet:` en el enum (`distilled-note`, `outtake`, `wip`,
   `deliverable`, `external`) sobre su tipo natural, **When** corre el runner, **Then**
   `.graph/packets.json` lista cada una con ruta, tipo de packet, `description`, proyecto y
   fecha; `index.md` tiene la sección `Packets`; un valor fuera del enum se reporta como
   violación de frontmatter.
2. **Given** un vault sin ningún `packet:`, **When** corre el runner, **Then** el catálogo
   existe con lista vacía (nunca ausente) y no hay hallazgos por ello.
3. **Given** el schema, **When** el agente hace kickoff, **Then** lee el catálogo de packets
   y lista los reutilizables; la línea `project-open` de `log.md` registra cuántos se
   reutilizaron; el filing de una síntesis propone su tipo de packet.

---

### User Story 6 - Favorite problems como filtro de captura (Priority: P2)

Como humano dueño del vault, quiero declarar mis problemas favoritos en una sola página y
que el agente los use como filtro al ingerir: cada fuente nueva se relaciona con un
problema o un proyecto activo, o el agente pregunta antes de ingerir; y quiero que el
sistema me avise qué problemas llevan tiempo sin recibir nada.

**Why this priority**: Es el mecanismo de captura de Forte que el LLM Wiki no tiene; evita
el collector's fallacy. Depende de US1 (claves) y US3 (`pending_ingest`).

**Independent Test**: El skeleton no trae página semilla y el runner sobre skeleton limpio
sigue en 0; con la página creada y páginas que declaran `problems:`, los problemas
referenciados tienen backlinks y los no alimentados en N días se reportan; sin la página no
hay hallazgos de ese tipo; el schema documenta el paso 0.5 de ingest con etiqueta
"candidato".

**Acceptance Scenarios**:

1. **Given** el skeleton nuevo, **When** se siembra, **Then** NO existe página de favorite
   problems; el schema instruye crearla bajo demanda cuando el humano declare sus problemas
   (una página, lista numerada con slug estable, máximo doce) y enlazarla desde `index.md`.
2. **Given** la página existe y una página declara `problems: [fp-3]`, **When** corre el
   runner, **Then** el problema `fp-3` cuenta con esa entrada; un problema sin entradas en
   los últimos N días se reporta como `problem_unfed`; más de doce problemas o una entrada
   sin forma de pregunta se reporta como violación de forma.
3. **Given** la página no existe, **When** corre el runner y el agente ingiere, **Then** no
   hay `problem_unfed` y el paso 0.5 de ingest se reduce a "¿aporta a un proyecto activo?".
4. **Given** el schema, **When** el agente ingiere una fuente, **Then** el paso 0.5 anota
   `problems:` y/o `project:` cuando matchea, etiqueta como "candidato" todo criterio de
   resonancia inferido (nunca afirma resonancia propia), y pregunta al humano antes de
   ingerir cuando nada matchea; una página `concept` nueva exige dos fuentes citadas.

---

### User Story 7 - Upgrade aditivo 0.27.0 y configuración (Priority: P2)

Como operador de un agente existente (docker o local), quiero recibir todo lo nuevo sin que
se toque ningún archivo preexistente ni el `CLAUDE.md` del vault: las plantillas y secciones
nuevas llegan como delta con su marcador propio, el sistema me delata si el delta lleva
demasiado tiempo sin integrarse, y las perillas nuevas viven en `agent.yml` con defaults
sensatos que sobreviven `--regenerate`.

**Why this priority**: Es la vía de entrega a la flota; sin ella solo los scaffolds nuevos
se benefician. Es P2 porque las historias P1 son verificables sobre fixtures antes de que la
entrega exista.

**Independent Test**: Sobre tres fixtures (vault pre-014, vault 0.8.0 con wiki vacía, vault
0.8.0 con páginas), correr el upgrade y verificar hash a hash que 0 archivos preexistentes
cambiaron, que los deltas y marcadores correctos existen, que la segunda corrida es no-op;
verificar el hallazgo de delta pendiente; verificar backfill y render de las claves nuevas y
regenerate byte-idéntico en dos pasadas.

**Acceptance Scenarios**:

1. **Given** un vault pre-014 poblado, **When** corre el upgrade, **Then** existen ambos
   deltas (0.8.0 y 0.27.0) con sus marcadores, dos líneas `upgrade` en `log.md`, las
   plantillas nuevas presentes, y 0 archivos preexistentes modificados.
2. **Given** un vault 0.8.0 completo (con o sin páginas), **When** corre el upgrade, **Then**
   solo se deposita el delta 0.27.0 con su marcador y una línea en `log.md`; una segunda
   corrida no duplica nada.
3. **Given** un delta 0.27.0 depositado hace más de N días y un `CLAUDE.md` del vault que
   aún no contiene la marca de integración (la cadena del eje PARA), **When** corre el
   runner, **Then** se reporta `schema_delta_pending`; tras la integración deja de
   reportarse.
4. **Given** un `agent.yml` anterior a 037, **When** corre `--regenerate`, **Then** las
   claves nuevas se agregan con sus defaults sin pisar valores existentes; un valor inválido
   degrada al default con aviso; dos regenerates seguidos producen artefactos byte-idénticos.
5. **Given** la documentación del vault, **When** el operador lee las claves `vault.*`,
   **Then** las cuatro claves sin lector están marcadas como reservadas (no se retiran en
   esta feature) y las nuevas están descritas con su default.
6. **Given** el modo local, **When** el operador corre `--login`, **Then** la documentación
   deja claro que el delta llega por `--regenerate` (drift preexistente, documentado, no
   corregido aquí).

---

### User Story 8 - Candidatos a archivo por criterios deterministas (Priority: P3)

Como operador, quiero que la revisión mensual me proponga qué archivar, con criterios
verificables y sin que nada se archive solo.

**Why this priority**: Cierra el ciclo PARA (Archives) y libera el índice del material
muerto; es la parte que el prior art más advierte que debe quedarse en "propuesta".

**Independent Test**: Sobre la fixture, una página `stale` o `superseded` sin backlinks y
sin menciones en `log.md` en N días se reporta como `archive_candidate`; la misma página
citada recientemente en `log.md` no; el runner no modifica nada; el schema pone la decisión
en el humano.

**Acceptance Scenarios**:

1. **Given** una página con `status: stale` o `superseded`, 0 backlinks y ninguna mención
   en `log.md` en los últimos N días, **When** corre el runner, **Then** se reporta
   `archive_candidate`; si tiene una mención reciente o un backlink, no.
2. **Given** el schema, **When** el agente hace la revisión mensual, **Then** lista a lo más
   tres candidatos con su evidencia y espera la decisión humana; el archivado es siempre la
   operación close de US3 (frontmatter, sin mover).
3. **Given** cualquier corrida, **When** termina, **Then** ninguna página cambió de `para`,
   `status` ni ubicación por acción del runner.

---

### User Story 9 - Aviso programado de revisión (docker, opt-in) y observabilidad (Priority: P3)

Como operador de un agente docker, quiero poder activar un aviso semanal que me llegue por
el canal con lo que hay pendiente (proyectos vencidos, fuentes sin procesar, candidatos a
archivo), sin que ejecute nada; y quiero ver los contadores nuevos en `status`/`doctor` de
ambos modos sin que degraden el estado.

**Why this priority**: Es la única pieza con tick LLM y la de menor evidencia de valor; se
entrega apagada por defecto. La observabilidad cierra una deuda de 013 (docker no reporta
qmd ni wiki-graph).

**Independent Test**: Render del crontab con la entrada semanal solo cuando está habilitada;
el prompt por defecto lee la cola y produce un mensaje corto; con la cola vacía produce una
línea "sin pendientes" a lo más una vez por semana; `status` docker y local muestran los
contadores; `doctor` no cambia su código de salida por ellos.

**Acceptance Scenarios**:

1. **Given** `features.heartbeat.review.enabled: false` (default), **When** se renderiza el
   crontab, **Then** no hay entrada nueva y el heartbeat regular es byte-idéntico a hoy.
2. **Given** el aviso habilitado con su schedule semanal (día de semana permitido en docker),
   **When** llega la hora, **Then** corre una invocación aparte del heartbeat con el prompt
   de revisión, que lee `findings.json` y reporta contadores y a lo más tres ítems, en menos
   de un minuto; con cola vacía reporta "sin pendientes"; nunca modifica el vault.
3. **Given** el modo local, **When** se renderizan las units, **Then** no hay aviso
   programado y la documentación lo dice.
4. **Given** ambos modos, **When** el operador corre `status`, **Then** ve los siete contadores
   de la cola en orden fijo (`review_due`, `project_overdue`, `project_incomplete`,
   `pending_ingest`, `archive_candidate`, `schema_delta_pending`, `problem_unfed`) y el estado
   de la migración de colección; **When** corre `doctor`, **Then** el contrato 0/1/2 de 013 no
   cambia por ninguno de ellos (informan, no degradan).

---

### Edge Cases

- `para` ausente: resource, sin hallazgo. `para` con valor fuera del enum: violación de
  frontmatter, la corrida sigue. `para` en una página de `normalization/`: ignorado (no es
  nodo).
- Página archivada: suprime `orphan` y `stale`; sigue en el grafo, en backlinks y en la
  sección Archive; nunca se mueve. `status` no se toca al archivar (su semántica es de
  frescura, no de ciclo de vida).
- `next_review` ausente en `para: project`: `review_due` (fuerza a fijar la fecha en la
  primera revisión). Malformado: violación, no `review_due`. Área sin `next_review`: no se
  reporta (las áreas se revisan en la mensual; la fecha es opcional).
- `due` anterior a hoy en `para: project`: `project_overdue`. `due` malformado: violación,
  no `project_overdue`. `due` ausente: `project_incomplete` (ya cubierto). Una página
  archivada nunca reporta `project_overdue` ni `review_due` (el proyecto cerró).
- "Hoy" para `review_due`, `project_overdue`, `problem_unfed`, `archive_candidate` y
  `schema_delta_pending`: inyectable en tests; en producción, la fecha de la corrida.
- Cambio exclusivo de frontmatter (`para: archive`): **medido** (discovery L, 26-09-2026):
  qmd hashea el archivo completo, así que un cambio solo de frontmatter re-indexa y re-embebe
  esa página (un chunk, un segundo); no hace falta bumpear `updated:` ni tocar el cuerpo. La
  consecuencia inversa es la que importa: una pasada masiva que agregue `para:` a N páginas
  re-embebe N páginas, y por eso la recreación de la colección (barata) va antes que cualquier
  cambio masivo de contenido, y ningún cambio masivo está en alcance.
- Claves PARA con wikilink a destino inexistente: `broken_link`, igual que un wikilink del
  cuerpo. Con slug no resoluble (`problems:` sin la página de favorite problems): sin arista,
  sin hallazgo.
- Migración de colección con el MCP de qmd vivo en una sesión: la acción avisa y recomienda
  ejecutarla sin sesión activa; si el MCP no tolera la recreación, se reinicia con la
  sesión. Migración interrumpida: el sentinel se escribe solo al final; reintentar es seguro.
- Vault grande (2.696 páginas): el runner con todos los hallazgos nuevos debe seguir bajo el
  presupuesto heredado (SC-005); si `pending_ingest` o `description_missing` producen miles
  de entradas, el plan decide contadores sin lista para esos kinds.
- `description: ""`: cuenta como ausente. `packets.json` sin packets: lista vacía, nunca
  archivo ausente.
- Página de favorite problems ausente: `problem_unfed` apagado; paso 0.5 degrada a proyecto
  activo. Presente pero sin la marca de forma: violación de forma, no de tipo.
- `log.md`: la línea de formato del skeleton (`{ingest|query|lint|init|other}`) ya está
  violada por `upgrade`; el delta y el skeleton la actualizan con las operaciones nuevas
  (`upgrade`, `project-open`, `project-close`, `review`, `session`).
- Aviso semanal con cola vacía: una línea "sin pendientes" (para distinguir "nada que
  revisar" de "heartbeat muerto"), a lo más una por semana. Heartbeat regular: intacto.
- Ventana de divergencia en el despliegue: imagen nueva (linter valida `para`) con schema
  viejo en el agente, o al revés. Orden fijado: rebuild → boot deposita el delta → el agente
  integra; en el intervalo los hallazgos nuevos son esperados y se documentan como tales.
- `--login` local no corre el upgrade aditivo (drift preexistente): el delta llega por
  `--regenerate`; documentado, no corregido en 037.
- `vault.seed_skeleton: false`: ambos disparadores del upgrade aditivo (boot docker y
  `--regenerate` local) cortan antes de depositar cualquier delta, así que un agente que apagó
  el seed no recibe 0.8.0 ni 0.27.0. Es el contrato vigente ("no toques la estructura de mi
  vault") y se conserva; la spec lo declara, la documentación lo dice y el gate de despliegue
  verifica la clave en cada agente de la flota antes de esperar el delta.
- Vault temporalmente inaccesible, corridas solapadas, escritura interrumpida: mismas
  garantías que 014 (lock, escritura atómica, fail-silent con honestidad en doctor).

## Requirements *(mandatory)*

### Functional Requirements

#### Eje PARA (US1)

- **FR-001**: El schema del vault MUST admitir en el frontmatter de cualquiera de los seis
  tipos la clave `para` con valores `project | area | resource | archive`, ausente = resource,
  y las claves auxiliares `archived`, `goal`, `due`, `next_action`, `next_review`, `standard`,
  `cadence`, `area`, `project`, `problems`, `packet`, `distill`, `description`; sin séptimo
  `type` ni valores nuevos de `status`.
- **FR-002**: El skeleton MUST incluir plantillas variante de ficha de proyecto (`type:
  entity`, `para: project`) y de página de área (`type: overview`, `para: area`), y `index.md`
  MUST ganar las secciones `Projects (active)`, `Areas`, `Archive`, `Packets` y `Favorite
  problems`, sin páginas semilla.
- **FR-003**: El runner MUST validar la forma de las claves nuevas como violaciones de
  frontmatter con razón canónica `<clave>: invalid '<valor>'` (`para`, `packet`, `distill`),
  `<fecha>: malformed '<valor>'` (`due`, `next_review`, `archived`) y `archived: missing`
  (`para: archive` sin `archived`), aplicando la regla "valor vacío = clave ausente" (una
  plantilla sembrada con `due: ""` no es violación); reportar `project_incomplete` (`para:
  project` sin `goal`, sin `due` o con `next_action` ausente o vacío), y
  extraer `para`, `tags` (cerrando el drift del contrato de 014) y las claves nuevas al nodo
  del grafo, con contadores nuevos con default en el state file.
- **FR-004**: El runner MUST emitir aristas de tipo `related` desde `project` y `area`
  (destino = wikilink o id resoluble; destino inexistente → wikilink roto) y desde `problems`
  hacia la página fija `synthesis/favorite-problems` solo si esa página existe (si no existe,
  sin arista y sin hallazgo; la entrada `fp-<n>` concreta solo importa para `problem_unfed`),
  de modo que fichas, páginas de área y la página de favorite problems tengan backlinks.
- **FR-005**: El runner MUST suprimir `orphan` y `stale` para páginas `para: archive`, y
  MUST conservar byte-idénticos los seis hallazgos previos sobre páginas sin `para`.
- **FR-006**: El schema del vault y la plantilla del `CLAUDE.md` del workspace MUST
  documentar la misma regla de ruteo: la ficha de proyecto vive en el vault; la auto-memoria
  `project_<slug>.md` es un puntero de 2-3 líneas sin estado; el delta MUST incluir la nota
  de migración para los `project_*` existentes.

#### Higiene del índice (US2)

- **FR-007**: En un scaffold nuevo, la colección de búsqueda MUST cubrir solo `wiki/` (raíz
  del vault con máscara `wiki/**/*.md`, que preserva las URIs `qmd://vault/wiki/...` de hoy),
  dentro del pin 2.5.3 y usando solo argumentos del CLI ya en uso; ningún archivo de
  configuración del vendor se escribe.
- **FR-008**: Para un agente con colección heredada, la migración MUST ocurrir
  automáticamente una sola vez, en el primer tick de reindexado posterior a la actualización,
  gateada por un sentinel bajo el cache root de qmd en `.state` (nunca en el vault),
  reutilizando embeddings (`remove` + `add` + `update`; `cleanup` solo después del `add`) y
  dejando registro en el state file y en el log; MUST ser idempotente; y MUST existir una
  acción manual equivalente en ambos modos (`qmd-migrate`, patrón de acciones manuales de
  013) con tres comportamientos fijos: sin flags es idempotente (con sentinel presente informa
  `already migrated` y sale 0 sin tocar qmd), `--dry-run` solo imprime el estado y los pasos,
  `--force` recrea la colección aunque exista el sentinel. Si un paso de la migración falla, el
  tick termina con `last_status: error`, el hash del vault no se actualiza, la migración sigue
  `pending` y el siguiente tick reintenta desde `remove`.
- **FR-009**: `status` en ambos modos y `doctor` local MUST reportar si la migración está
  pendiente o hecha, calculando el estado en vivo (sentinel + presencia del índice), no solo
  leyendo el state file, para que `pending` sea visible antes del primer tick; en docker
  `doctor` remite a `heartbeatctl status`. Pendiente informa, no degrada.
- **FR-010**: El schema MUST documentar que `raw_sources/` se consulta por Grep o
  `search_notes` cuando la pregunta exige texto crudo.
- **FR-011**: Las reglas nuevas que escriben en `log.md` o `index.md` por sesión (FR-016,
  FR-017) MUST aterrizar después o junto con FR-007/FR-008 en el orden de tareas.

#### Cola de revisión y operaciones (US3)

- **FR-012**: El runner MUST reportar `review_due` para `para: project` cuando `next_review`
  es anterior a la fecha de la corrida o está ausente, y `project_overdue` cuando `due` es
  anterior a la fecha de la corrida, ambos con días de atraso y nunca para páginas
  `para: archive`; MUST aceptar la fecha "hoy" inyectable para tests deterministas.
- **FR-013**: El runner MUST reportar `pending_ingest` para cada `raw_sources/**/*.md` con
  `clipped:` que ninguna página `summary` cite en `sources:` (comparación por ruta
  normalizada); MUST NOT enumerar binarios sin `.md` hermano.
- **FR-014**: El schema del vault MUST definir las operaciones `project kickoff`, `project
  close`, `weekly review` y `monthly review` con pasos mecánicos separados de decisionales:
  kickoff (objetivo, fecha, `next_action`, `next_review` según cadencia por defecto,
  búsqueda de páginas y packets relacionados, enlaces recíprocos vía `related:`, outline,
  `project-open` en `log.md`); close (`para: archive` + `archived:`, refresco de `updated:`,
  extracción de packets, sección Archive, puntero de auto-memoria, `project-close`); weekly (bandeja
  `pending_ingest`; loops abiertos = `project_overdue` + `project_incomplete`, calculados
  por el runner; proyectos `review_due`; a lo más tres recomendaciones); monthly (áreas,
  `archive_candidate`, outcome). Toda decisión de archivar, cerrar o cambiar fechas es humana.
- **FR-015**: La cadencia por defecto MUST ser semanal (7 días) para proyectos y mensual
  (30 días) para áreas, configurable en `agent.yml`; el agente fija `next_review` en cada revisión; MUST NOT
  agregarse ningún cron ni unit para la revisión.
- **FR-016**: El schema MUST exigir el cierre de sesión (Hemingway Bridge): toda sesión que
  tocó un proyecto termina con `next_action` actualizado y una línea `session | <proyecto> —
  next: …` en `log.md`.
- **FR-017**: El schema MUST fijar la política de filing: proponer archivar como página toda
  síntesis que cite tres o más páginas, y registrar `query | … | filed: yes/no` en `log.md`.
- **FR-018**: El schema MUST instruir ofrecer la revisión en el primer mensaje de una
  conversación cuando `findings.json` tiene `review_due` o `pending_ingest` mayores que cero,
  sin ejecutar cambios sin confirmación.
- **FR-019**: Las revisiones MUST registrarse como líneas de `log.md` (`review | weekly —
  …`, `review | monthly — …`), nunca como un archivo por revisión; la línea de formato de
  `log.md` MUST actualizarse con las operaciones nuevas.

#### Index-first y destilación (US4)

- **FR-020**: El protocolo de query MUST empezar por un paso 0: leer las páginas `overview`
  del dominio, las secciones PARA pertinentes de `index.md` y la ficha del proyecto activo;
  `index.md` completo solo bajo el umbral por defecto de 300 páginas (ajustable por
  override; la Fase 0 puede recomendar otro valor con medición); después búsqueda híbrida,
  después grafo.
- **FR-021**: Las seis plantillas de página y las dos variantes nuevas (no `source.md` ni
  `normalization.md`, que no son nodos del wiki) MUST llevar `description` (una línea,
  obligatoria en páginas nuevas) como gancho de `index.md`; `summary.md` MUST declarar `distill` y llevar el resumen
  ejecutivo arriba con secciones opcionales de destacados y núcleo; el schema MUST prohibir
  pases de destilación por lotes.
- **FR-022**: El runner MUST reportar `description_missing` solo para páginas con `para:`
  declarado o `created` igual o posterior a la fecha del delta, y solo si `description` está
  ausente o vacía. La fecha del delta sale del marcador 0.27.0 (contenido `deposited:`; si el
  marcador existe pero no parsea, su mtime); un scaffold nuevo nace con el marcador fechado al
  día de la siembra; un vault sin marcador (p. ej. `seed_skeleton: false`) gatea solo por
  `para:` declarado, nunca por `created`.

#### Packets (US5)

- **FR-023**: El runner MUST derivar `.graph/packets.json` (lista de páginas con `packet:`,
  con ruta, tipo, `description`, proyecto, fecha; lista vacía si no hay), MUST validar el
  enum `distilled-note | outtake | wip | deliverable | external` como violación de
  frontmatter, y el schema MUST instruir su lectura en kickoff y registrar packets
  reutilizados en la línea `project-open`.

#### Favorite problems (US6)

- **FR-024**: El schema MUST definir la página de favorite problems (`type: synthesis`, una
  sola, lista numerada con slug estable, máximo doce, creada bajo demanda por el humano y
  enlazada desde `index.md`) y el paso 0.5 de ingest (relacionar con `problems:`/`project:`,
  etiquetar "candidato" toda resonancia inferida, preguntar antes de ingerir cuando nada
  matchea, dos fuentes para un `concept` nuevo); el skeleton MUST NOT traer la página.
- **FR-025**: El runner MUST reportar `problem_unfed` (problema sin entradas `problems:` en
  N días) solo cuando la página existe, y violación de forma cuando excede doce entradas o
  una entrada no tiene forma de pregunta.

#### Upgrade y configuración (US7)

- **FR-026**: El upgrade aditivo MUST ganar un segundo bloque para el delta
  `schema-updates-0.27.0.md` con marcador oculto propio y línea `upgrade` en `log.md`,
  dejando el bloque 0.8.0 intacto; MUST modificar 0 archivos preexistentes en los tres
  estados posibles del vault y ser idempotente; MUST NOT tocar el `CLAUDE.md` del vault. La
  siembra de un scaffold nuevo MUST dejar el marcador 0.27.0 con `deposited: <fecha de
  siembra>` y sin delta (su schema ya integra las secciones), de modo que "sin marcador"
  signifique "vault que no recibió el delta".
- **FR-027**: El runner MUST reportar `schema_delta_pending` cuando un delta depositado
  hace más de N días no se refleja en el `CLAUDE.md` del vault (ausencia de la marca de
  integración del eje PARA).
- **FR-028**: Las perillas nuevas MUST vivir en `agent.yml` con el trío completo (heredoc
  con default, backfill que no pisa valores, validación de forma, touchpoint de tests):
  cadencias de revisión (proyecto 7 días, área 30 días), días para candidato a archivo
  (90), y el aviso de heartbeat (`enabled` default false, schedule semanal, prompt). Los
  umbrales de delta pendiente (14 días), problema no alimentado (30 días) e index-first
  completo (300 páginas) MAY ser constantes con override por entorno (precedente
  `QMD_EMBED_MAX_PASSES` de 018). Los valores efectivos MUST publicarse al agente en
  `.graph/policy.json` (derivado por el runner en cada corrida, regenerable, nunca
  respaldado), que el schema del vault lee antes de fijar fechas de revisión.
- **FR-029**: Las cuatro claves `vault.*` sin lector MUST documentarse como reservadas; MUST
  NOT retirarse en esta feature. MUST NOT agregarse ningún prompt de wizard.
- **FR-030**: El delta, las plantillas y las secciones nuevas del schema MUST estar en
  inglés.

#### Archivo (US8)

- **FR-031**: El runner MUST reportar `archive_candidate` para páginas `status: stale` o
  `superseded` sin backlinks y sin mención en `log.md` en los últimos N días; MUST NOT
  cambiar `para`, `status` ni ubicación de ninguna página.

#### Aviso y observabilidad (US9)

- **FR-032**: En docker, cuando `features.heartbeat.review.enabled` es true, el crontab
  MUST renderizar una entrada semanal aparte que invoque el heartbeat con el prompt de
  revisión; ese prompt MUST leer `findings.json`, reportar contadores y a lo más tres ítems,
  reportar "sin pendientes" con cola vacía y MUST NOT modificar el vault; MUST estar diseñado
  para terminar en menos de un minuto (se mide en SC-007 por `duration_ms`; el tope duro sigue
  siendo el timeout global del heartbeat, sin timeout por invocación); con `enabled` false el
  heartbeat MUST ser byte-idéntico al actual. La entrada semanal es independiente de
  `features.heartbeat.enabled` y de `heartbeatctl pause` (misma semántica que las otras
  líneas de mantenimiento del crontab): para silenciarla se usa `review.enabled: false`.
  En local MUST NOT haber aviso programado, documentado.
- **FR-033**: `status` en ambos modos (incluido `heartbeatctl status` docker) MUST mostrar
  los contadores de `review_due`, `project_overdue`, `project_incomplete`, `pending_ingest`,
  `archive_candidate`, `schema_delta_pending`, `problem_unfed` y el estado de la migración
  de colección; `doctor`
  MUST conservar el contrato 0/1/2 de 013 (informan, no degradan).

#### Transversales

- **FR-034**: Ningún script MUST editar `wiki/`, `raw_sources/` ni el `CLAUDE.md` del vault;
  todo derivado nuevo es JSON atómico bajo `.graph/`, nunca respaldado.
- **FR-035**: El modo docker MUST recibir la funcionalidad completa vía las libs image-baked
  por COPY (`vault.sh`, `wiki_graph.sh`, `qmd_index.sh`), el crontab y `heartbeatctl`; el
  gate DOCKER_E2E es obligatorio y MUST correrse de verdad (este host tiene Docker).
- **FR-036**: El gate de hardware (vault grande, systemd) MUST correr antes del merge
  (precedente 024); la spec declara el bloqueo actual de ferrari (reautenticación de
  Cloudflare Access pendiente del operador) como riesgo de calendario, no de diseño.

### Key Entities

- **Ficha de proyecto**: página `entity` con `para: project`, `goal`, `due`, `next_action`,
  `next_review`; MOC del proyecto (enlaza al wiki, no lo fragmenta); única casa del estado.
- **Página de área**: `overview` con `para: area`, `standard`, `cadence`; creada bajo
  demanda.
- **Página archivada**: cualquier tipo con `para: archive` + `archived:`; misma ubicación;
  fuera de `orphan`/`stale`; en la sección Archive.
- **Packet**: página de cualquier tipo con `packet:` en el enum de cinco; catalogada en
  `.graph/packets.json`.
- **Página de favorite problems**: una `synthesis` con lista numerada de hasta doce
  problemas con slug estable; referenciada por `problems:`.
- **Puntero de auto-memoria**: `project_<slug>.md` reducido a estado en una frase, wikilink
  a la ficha y fecha; sin estado adicional.
- **Hallazgos nuevos**: `frontmatter_violation` con razones canónicas `para: invalid '<v>'`,
  `packet: invalid '<v>'`, `distill: invalid '<v>'`, `due: malformed '<v>'`, `next_review:
  malformed '<v>'`, `archived: malformed '<v>'`, `archived: missing`, `favorite_problems: <n>
  entries (max 12)`, `favorite_problems: fp-<n> is not a question` (solo sobre valores no
  vacíos); `project_incomplete` (sin `goal`, `due` o `next_action`), `review_due`,
  `project_overdue`, `pending_ingest`, `description_missing`, `problem_unfed`,
  `archive_candidate`, `schema_delta_pending`; todos tipados, anclados a página, con contador
  en el state file. Los siete contadores de la cola que `status` muestra, en orden fijo:
  `review_due`, `project_overdue`, `project_incomplete`, `pending_ingest`, `archive_candidate`,
  `schema_delta_pending`, `problem_unfed`.
- **Política efectiva**: `.graph/policy.json`, derivado, regenerable, nunca respaldado;
  publica al agente las cadencias, los umbrales y el estado de la colección leídos de
  `agent.yml` y del state de qmd; el schema lo lee antes de fijar fechas de revisión.
- **Cola de revisión**: el subconjunto de `findings.json` que el agente lee al abrir sesión
  y el aviso semanal reporta.
- **Catálogo de packets**: `.graph/packets.json`, derivado, regenerable, nunca respaldado.
- **Delta 0.27.0**: `_templates/schema-updates-0.27.0.md` + marcador oculto + línea en
  `log.md`; incluye la marca de integración que `schema_delta_pending` busca.
- **Sentinel de migración de colección**: archivo bajo el cache root de qmd en `.state`
  que registra que la colección ya apunta a `wiki/`.
- **Aviso de revisión**: entrada semanal aparte del heartbeat (docker, opt-in) con su
  propio prompt; solo informa.
- **Perillas nuevas de `agent.yml`**: cadencias de revisión, días para candidato a archivo,
  bloque `features.heartbeat.review`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001 (linter)**: Sobre la fixture del grafo extendida, cada hallazgo nuevo (las razones
  canónicas `para: invalid`, `packet: invalid`, `distill: invalid`, `<fecha>: malformed`,
  `archived: missing`, `favorite_problems: …`, y los kinds `project_incomplete`, `review_due`,
  `project_overdue`, `pending_ingest`, `description_missing`, `problem_unfed`,
  `archive_candidate`, `schema_delta_pending`) se reporta con 0 falsos positivos y 0 falsos
  negativos; los seis
  hallazgos previos son byte-idénticos sobre las páginas sin `para`; el skeleton limpio
  sigue dando exactamente 0.
- **SC-002 (aditividad)**: El upgrade sobre las tres fixtures (pre-014, 0.8.0 vacía, 0.8.0
  con páginas) modifica 0 archivos preexistentes (hash antes/después), deposita exactamente
  los deltas que faltan y es no-op en segunda pasada.
- **SC-003 (higiene)**: Tras la migración, sobre un set de 20-30 preguntas sonda con
  respuesta conocida sobre una copia de un vault real, 0 documentos de `_templates/`,
  `index.md`, `log.md`, `CLAUDE.md` del vault o `raw_sources/` en el top-10, y 0 duplicados
  raw/summary; la migración ocurre exactamente una vez por agente, queda registrada, y `qmd
  embed` no reporta pendientes después de ella (embeddings reutilizados).
- **SC-004 (navegación)**: En 10 preguntas sonda, el protocolo index-first reduce las
  llamadas a herramientas respecto al protocolo actual tanto en un vault chico (linus) como
  en el vault de 2.696 páginas (criterio mínimo: estrictamente menos llamadas en ambos); las
  cotas numéricas se fijan con la medición de Q10 en el gate de hardware (quickstart §5) y se
  registran en `tasks.md` Notes antes del merge.
- **SC-005 (costo del runner)**: El runner con todos los hallazgos nuevos procesa el vault
  de 2.696 páginas en menos de 60 segundos en el hardware objetivo (Raspberry Pi 5, cota
  heredada de 014) y `findings.json` sigue siendo legible en una sola lectura por el agente.
- **SC-006 (uso, anti collector's fallacy)**: Tras cuatro semanas en linus, al menos un
  `review_due` atendido por semana, tasa de filing registrada en `log.md`, y al menos un
  packet reutilizado en un kickoff. Se mide en el despliegue; no se promete.
- **SC-007 (aviso)**: Con el aviso habilitado, a lo más un mensaje por semana en el canal,
  ninguno modifica el vault, cada uno termina en menos de 60 segundos; con `enabled` false
  el heartbeat es byte-idéntico a v0.26.0.
- **SC-008 (no double-write)**: Tras integrar el delta en un agente de la flota, ningún
  `project_*` de auto-memoria contiene estado más allá del puntero (verificación manual del
  gate, conteo sin imprimir contenido).
- **SC-009 (observabilidad)**: `status` en ambos modos muestra los contadores nuevos y el
  estado de la migración en un solo comando; `doctor` conserva su código de salida ante
  cualquier valor de ellos.
- **SC-010 (paridad y gates)**: Docker byte-idéntico fuera de las libs image-baked, el
  crontab y `heartbeatctl`; `bats tests/` con 0 `not ok` en bash 3.2 y 5.x; `shellcheck -S
  error` limpio; DOCKER_E2E verde; gate de hardware (linus docker, mclaren local, ferrari
  vault grande) antes del merge.

## Assumptions

- **Decisiones del operador** (Clarifications): alcance (c); PARA en frontmatter; colección
  con alcance `wiki/` (máscara `wiki/**/*.md` sobre la raíz del vault) con migración
  automática única (27-09; la "explícita" del 26-09 quedó superada); cola determinista
  semanal; una spec, un PR; ficha en vault + puntero; heartbeat opt-in que solo avisa; inglés.
- **Heredado y no re-litigado**: sin séptimo `type` ni `status` nuevos; sin scripts que
  editen el wiki; entrega por delta (nunca append ni reemplazo del `CLAUDE.md` del vault);
  sin `/vault:*`; sin bump de qmd ni parche a su dist; derivados JSON bajo `.graph/` nunca
  respaldados; sin prompt de wizard; libs image-baked por COPY exigen DOCKER_E2E.
- **Destilación oportunista**: `distill` sube solo al tocar la página por otra razón; el
  resumen ejecutivo se escribe al crear el `summary`; nunca batch.
- **Favorite problems bajo demanda**: ninguna página semilla en el skeleton (una semilla en
  `wiki/` sería huérfana por construcción y rompería el oráculo de 0 hallazgos).
- **Aristas desde claves PARA por código** (no solo por disciplina de prosa): el parser gana
  un cuarto toque que emite aristas `related` desde `project`/`area`/`problems`; cambia los
  backlinks y por tanto la fixture-oráculo se re-baselinea con la justificación por caso.
- **`para: archive` suprime `orphan` y `stale`**: un proyecto cerrado no debe acumular
  hallazgos para siempre; `status` no se usa como ciclo de vida.
- **Findings nuevos informan, no degradan**: el contrato 0/1/2 de 013 no cambia; la cola es
  información para el agente y el humano.
- **Gates por escala**: `description_missing` gateado por `para:`/`created`;
  `pending_ingest` con dominio `raw_sources/**/*.md` con `clipped:`; `problem_unfed` solo
  con la página presente; si el vault grande produce miles de entradas de un kind, el plan
  decide contadores sin lista para ese kind.
- **Weekly vs monthly según Forte, con cadencia del operador**: la weekly de Forte es de
  bandejas (aquí `pending_ingest` + loops) y la revisión de proyectos es mensual; el operador
  decidió semanal para proyectos; áreas mensual; ambas configurables; "resistance as
  feedback" es la regla de ajuste.
- **Aviso de heartbeat como entrada semanal aparte, no como mapa por día de semana**
  (ratificado en clarify 2026-09-26): el heartbeat regular corre cada N minutos, así que un
  prompt "del lunes" repetiría el aviso en cada tick del lunes; una segunda entrada de cron
  semanal con `--prompt` propio (mecanismo que el runner ya acepta) da exactamente un aviso
  por semana sin tocar el prompt regular. Con cola vacía envía una línea "sin pendientes"
  (ratificado). El plan confirma si `heartbeat.sh` necesita cambio o solo el crontab y
  `heartbeatctl`.
- **Umbrales y cadencias por defecto** (ratificados en clarify 2026-09-26; configurables):
  proyecto 7 días; área 30 días; `archive_candidate` 90 días; `schema_delta_pending` 14
  días; `problem_unfed` 30 días; index-first completo bajo 300 páginas. La Fase 0 puede
  recomendar ajustes solo con medición.
- **Loops abiertos por el runner** (ratificado en clarify 2026-09-26): `project_overdue`
  (`due` vencido) y `project_incomplete` extendido a `next_action` ausente o vacío; el agente
  no infiere loops leyendo fichas; ambos entran a los contadores y al aviso semanal.
- **Costo de la migración de colección** (medido en discovery L, 26-09-2026): segundos, no
  85 minutos: `collection remove` + `collection add` con la misma raíz y máscara `wiki/**/*.md`
  reutiliza los embeddings por hash de contenido; `qmd cleanup` se corre DESPUÉS, nunca entre
  medio. La decisión "acción explícita" se tomó con la premisa de 85 minutos y fue
  reemplazada el 2026-09-27 por "automática, una vez" (Clarifications).
- **Cambio solo de frontmatter y qmd** (medido): re-indexa y re-embebe esa página; sin
  mitigación por protocolo.
- **Claves muertas de `agent.yml`**: se documentan como reservadas; retirarlas rompe
  `schema.bats:43` y es un cambio aparte.
- **`--login` local no corre el upgrade aditivo**: drift preexistente, documentado; el
  delta llega por `--regenerate`.
- **Gate de hardware antes del merge** (precedente 024); ferrari está bloqueado por la
  reautenticación de Cloudflare Access que solo el operador puede hacer: riesgo de
  calendario declarado, no de diseño.
- **VERSION** 0.26.0 → 0.27.0 (MINOR), verificado contra `origin/main` antes del bump
  (lección 023). CHANGELOG, README (sección vault), `docs/vault.md`, `docs/state-layout.md`
  (puntero) y `CLAUDE.md` del repo se actualizan.

## Incógnitas para la Fase 0 del plan (medir antes de diseñar)

Heredadas de la síntesis y la crítica; ninguna imprime contenido de vaults ni secretos.

1. Superficie real de exclusión y recreación de colección en qmd 2.5.3 dentro del contenedor:
   ¿`collection remove` + `add` reutiliza embeddings por hash de contenido o re-embebe todo?
   ¿El MCP de qmd vivo tolera la recreación? ¿El tool MCP acepta parámetro de colección?
2. Degradación del top-K por indexar plantillas, índice, bitácora, raw y archivo: set de
   20-30 preguntas sonda sobre una copia de un vault real, con y sin exclusiones.
3. ¿La sesión del heartbeat (config aislado, sin plugins) carga los MCP `vault`/`qmd`? Si
   no, el prompt de aviso lee `findings.json` por ruta.
4. Duración y tokens de un turno de kickoff, close y weekly review sobre un vault real,
   contra el timeout de 300 s y el cap de typing de 5 min.
5. Estado real de la flota: páginas por tipo, ¿integraron el delta 0.8.0?, cuántos
   `project_*` y cuántas `entity` son proyectos (conteos, sin contenido).
6. Costo del runner con todos los hallazgos nuevos sobre 2.696 páginas en RPi5; tamaño de
   `index.md` y de `findings.json` allí.
7. Comportamiento del segundo bloque de `vault_seed_missing` en los tres estados del vault.
8. ¿`inotifywait` de Alpine 3.24 puede excluir `.graph/`? (tick vacío por corrida del grafo;
   crece con `packets.json`).
9. ¿`qmd update` re-indexa una página cuyo único cambio es de frontmatter?
10. Index-first en la flota: llamadas y latencia con y sin paso 0, en vault chico y grande.
11. ¿Necesita cambio `heartbeat.sh` para la entrada semanal con `--prompt`, o basta crontab y
    `heartbeatctl`? Impacto en `runs.jsonl` (campo `trigger`).

## Fuera de alcance (backlog)

- Séptimo `type`, valores nuevos de `status`, carpetas PARA paralelas a `wiki/`, mover
  páginas al archivar, stub de redirección.
- Archivado, destilación o movimiento automáticos; decay numérico; scores de confianza.
- Bump de qmd (2.6.x cambia deps nativas; el filtro por metadatos no está liberado), parche
  a su dist, escritura del YAML de colecciones del vendor (`ignore:`).
- Skill `/vault:*`; prompt de wizard; retiro de las claves `vault.*` muertas.
- Heartbeat que ejecute la revisión; tick LLM en modo local; lint agéntico programado.
- Migración big-bang de vaults existentes (`para` ausente = resource; la estructura crece
  por uso); reescritura de páginas existentes para agregar `description` o `distill`.
- Número mayor de niveles de índice que dos; reordenar `index.md` por PARA además de por
  tipo (queda como opción del agente, no del skeleton).
- Corregir el drift de `--login` local que no corre el upgrade aditivo.
- Deuda docker de MCPVault apuntando a `/home/agent/.vault` fijo (ignora `vault.path`).
- Conversación en tiempo real, canales nuevos, cualquier cambio al plugin de Telegram.
