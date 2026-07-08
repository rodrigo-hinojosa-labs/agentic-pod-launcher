# Feature Specification: Wiki-grafo RAG agéntico — grafo derivado, normalización y mantenimiento determinista

**Feature Branch**: `014-wiki-graph-rag`

**Created**: 2026-07-06

**Status**: Draft

**Input**: User description: "Wiki-grafo RAG agéntico (patrón Karpathy LLM Wiki completo): derivar automáticamente un grafo de conocimiento de TODA la base wiki del vault, agregar capa de normalización, y automatizar el mantenimiento determinista — agnóstico al modo de instalación (docker y local systemd por igual, sobre la paridad lograda en 013)."

## Contexto

El vault skeleton (feature 010) implementa las 3 capas del patrón "LLM Wiki" de Karpathy
(gist `442a6bf555914893e9891c11519de94f`): `raw_sources/` inmutable (capa 1), `wiki/` de 6
tipos de página (capa 2), `CLAUDE.md` como schema (capa 3), con protocolos ingest/query/lint
y qmd como búsqueda híbrida. La brecha verificada contra el gist y contra la práctica real
(agente `rodri-cenco-admin` con wiki poblada):

- **(a)** qmd ya indexa la wiki COMPLETA — colección única sobre el vault root con mask
  `**/*.md` (`scripts/lib/qmd_index.sh:181`). La búsqueda cubre toda la base; lo que NO
  existe es la dimensión de grafo.
- **(b)** Los `[[wikilinks]]` y los arrays `related:`/`sources:` del frontmatter son pura
  convención: nada los parsea. Los backlinks explícitamente NO se mantienen automáticamente
  (`modules/vault-skeleton/CLAUDE.md:75-76`).
- **(c)** El lint es 100% manual y 100% agéntico (`CLAUDE.md:116-137`): huérfanos, links
  rotos, drift — todo depende de que el humano lo pida y de una sesión LLM cara. Los
  comentarios del gist recomiendan explícitamente scripts deterministas para validación y
  LLM solo para síntesis.
- **(d)** El drift de `index.md` solo se detecta a mano ("filesystem wins; run lint",
  `vault-skeleton/index.md:10-11`).
- **(e)** No existe normalización: transcripts con errores (SENCOSUD en vez de Cencosud)
  entran tal cual y el drift terminológico crece en silencio.
- **(f)** `vault_seed_if_empty` es no-op con vault poblado (`scripts/lib/vault.sh:39-41`) y
  `vault_backup_and_reseed` es un upgrade destructivo → los agentes EXISTENTES (ferrari,
  mclaren) no recibirían nada de esta feature sin un mecanismo de upgrade aditivo nuevo.
- **(g)** La infraestructura de scheduling ya existe en ambos modos post-012/013: docker
  crontab + sync loop del entrypoint; local systemd OnCalendar vía `local_schedule.sh`, con
  las lecciones de 013 (PATH auto-provisto, env del vault, kill-switch, doctor honesto).

**Decisión de arquitectura** (RATIFICADA en clarify 2026-07-06 — la sesión fijó la
materialización del grafo derivado; no reabrir sin causa): NO usar
un servidor de base de datos de grafos (Neo4j o similar viola el stack: imagen Alpine,
`cap_drop: ALL`, mínimas dependencias, y el propio gist no lo usa). El grafo ya existe
implícito en los wikilinks — esta feature lo DERIVA determinísticamente y lo materializa
como artefacto regenerable bajo el vault, jamás respaldado (mismo principio que el índice
qmd). Obsidian graph view sigue siendo el visualizador humano.

## Clarifications

### Session 2026-07-06

- Q: ¿Cómo se modela `wiki/normalization/` dentro del sistema de tipos del schema del vault? → A: Carpeta-convención con frontmatter propio (canonical, aliases, scope, entity link), validada por el linter contra su propio spec; los 6 types de conocimiento quedan intactos ("the only six"); las páginas de normalización son reglas de escritura, no conocimiento citable.
- Q: ¿Cómo se entregan las secciones nuevas del schema a un vault existente cuyo CLAUDE.md fue co-evolucionado? → A: Delta aparte: el upgrade deposita `_templates/schema-updates-<version>.md` + entrada instructiva en `log.md`; el agente integra a su CLAUDE.md en la próxima sesión. Idempotente, trazable, sin tocar el archivo co-evolucionado.
- Q: ¿Cuál es el schedule por defecto del runner de grafo+lint? → A: Cada 6 horas (configurable en `agent.yml`); la acción manual cubre la regeneración inmediata; independiente del ciclo qmd.
- Q: ¿Dónde se materializan los artefactos derivados del grafo? → A: `<vault>/.graph/` como dot-dir: ruta relativa al vault idéntica en ambos modos (cero plumbing mode-resuelto), excluido del backup por naturaleza (solo markdown se respalda), oculto en Obsidian, inspeccionable en el Mac vía Syncthing.
- Q: ¿Qué hallazgos degradan el estado en doctor (exit 0/1/2)? → A: Integridad degrada, contenido informa. WARN (1): wikilinks rotos>0, frontmatter inválido>0, drift de index>0, o last_status=error. Informativo (0): huérfanos, stale, ocurrencias de alias (cola de trabajo del agente). FAIL (2): runner muerto — state file ausente o más viejo que 2 intervalos con la feature habilitada.

### Remediaciones del /speckit-analyze — 2026-07-07

Auditoría multi-agente (6 finders + verificación adversarial, 22 confirmados / 15 refutados). Resueltas en spec/plan/tasks/contratos:

- **C1 (CRITICAL)**: sentinel del upgrade aditivo = marcador oculto `_templates/.schema-updates-0.8.0.applied`, NO el delta `.md` borrable (evita re-depósito y duplicado de `log.md` en cada boot docker).
- **H5**: el trigger de boot docker es `start_services.sh::seed_vault_if_needed`, NO `entrypoint.sh` (que no toca el vault).
- **H3**: regla de extracción de entradas de `index.md` (excluir comentarios HTML/backticks/placeholders) para no generar `index_drift` espurio sobre el skeleton limpio.
- **H4**: normalización de valores de frontmatter (strip de comillas + desenvolver `[[wikilink]]` en `related:`) para no convertir todo `related:`/`sources:` en broken_link.
- **H2**: huérfano = sin backlinks; `related:` entrante cuenta siempre (sin exigir reciprocidad).
- **H1**: SC-002 acotado a modo local; docker se observa vía state file + log.
- **M6**: parser de intervalo de doctor lee el campo hora (`20 */6` → 6 h).
- **M7**: los defaults viven en el precompute de `setup.sh` + fallbacks yq; `schema.sh` solo valida forma.
- **M8**: único touchpoint de tests = `known_external` en `schema.bats` (no `wizard_answers`/`e2e-smoke`, que son prompts).
- **locked**: eliminado del enum del state file (perdedor del flock no escribe state).
- **schedule_fallback**: es archivo marcador aparte, no campo del state file JSON.
- **M1/M2**: tareas nuevas — comparación cross-mode del fixture en DOCKER_E2E (T029) y fixture de complejidad de ~100 páginas (T034).
- **L1/L2/L4/L5/L6**: aserción `.graph/` sin `.md`; aserción de seed del schema; guard `status: active` en stale; alias dentro de `[[…]]` no cuenta; "requerido" = clave-presente (`title: ""` válido).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Grafo derivado determinista de toda la wiki (Priority: P1)

Como operador de un agente con vault poblado, quiero que el sistema derive automáticamente
un grafo de conocimiento de TODA la base wiki (nodos = páginas tipadas; aristas = wikilinks
del cuerpo + `related:` + `sources:` del frontmatter) junto con un índice de backlinks y un
reporte de hallazgos estructurales (huérfanos, wikilinks rotos, frontmatter inválido, drift
de `index.md`, páginas stale), sin gastar tokens LLM y sin que ningún script edite la wiki.

**Why this priority**: Es la base de todo lo demás (retrieval graph-aware, lint automático,
normalización detectable). Sin el grafo derivado, la wiki sigue siendo un conjunto de
archivos cuya estructura nadie explota.

**Independent Test**: Sobre un vault fixture con un huérfano, un wikilink roto y un drift de
`index.md` conocidos, ejecutar el runner y verificar que emite exactamente esos hallazgos;
sobre el skeleton limpio emite cero hallazgos. No requiere scheduling ni contenedor.

**Acceptance Scenarios**:

1. **Given** un vault con páginas wiki interconectadas, **When** corre el runner de grafo,
   **Then** el grafo materializado contiene un nodo por página de `wiki/` (con type, title,
   status, fechas) y una arista por cada wikilink/`related:`/`sources:`, y un índice de
   backlinks consultable.
2. **Given** un vault fixture con 1 huérfano + 1 wikilink roto + 1 entrada de `index.md` sin
   archivo correspondiente, **When** corre el runner, **Then** el reporte de hallazgos
   contiene exactamente esos 3 hallazgos, tipados y con la página afectada.
3. **Given** el skeleton recién sembrado (wiki vacía), **When** corre el runner, **Then**
   termina exitoso con 0 nodos, 0 hallazgos y state file coherente.
4. **Given** una página con frontmatter malformado, **When** corre el runner, **Then** la
   página se reporta como hallazgo de violación de spec y el runner NO se cae ni omite el
   resto de la wiki.
5. **Given** cualquier corrida del runner, **When** termina, **Then** ninguna página de
   `wiki/` ni `raw_sources/` fue modificada (el runner solo escribe artefactos derivados y
   state file).

---

### User Story 2 - Capa de normalización (Priority: P1)

Como operador que ingesta transcripts con errores de transcripción (SENCOSUD → Cencosud),
quiero una carpeta `wiki/normalization/` donde se declaren formas canónicas y sus alias,
de modo que (a) el agente normalice la terminología ANTES de escribir páginas wiki durante
el ingest, y (b) el linter determinista detecte ocurrencias de alias conocidos en páginas
wiki existentes y las reporte para corrección agéntica.

**Why this priority**: Es la petición directa del usuario y ataca un modo de degradación
real ya observado: el drift terminológico silencioso que fragmenta entidades (dos páginas
para la misma organización bajo nombres distintos rompen el grafo y el retrieval).

**Independent Test**: Sembrar una página de normalización (canonical: Cencosud; aliases:
SENCOSUD), crear una página wiki cuyo cuerpo contenga "SENCOSUD", correr el linter y
verificar que reporta la ocurrencia con página y alias. Verificable sin scheduling.

**Acceptance Scenarios**:

1. **Given** el skeleton nuevo, **When** se scaffoldea un agente con vault habilitado,
   **Then** existe `wiki/normalization/` con su template y `index.md` tiene la sección
   correspondiente.
2. **Given** una página de normalización con canonical y aliases declarados, **When** el
   linter corre sobre una wiki que contiene un alias en el cuerpo de una página, **Then**
   el hallazgo se reporta (página, alias encontrado, canonical sugerido) y NINGÚN script
   edita la página — la corrección es del agente.
3. **Given** el schema actualizado, **When** el agente ejecuta el protocolo ingest sobre una
   fuente que contiene un alias conocido, **Then** el raw source se preserva VERBATIM (capa
   1 inmutable) y las páginas wiki generadas (capa 2) usan la forma canónica.
4. **Given** una página de normalización enlazada a una entity canónica, **When** corre el
   runner de grafo, **Then** el grafo contiene la relación alias→canonical de modo que una
   mención variante resuelve hacia la entity correcta.

---

### User Story 3 - Retrieval graph-aware (Priority: P2)

Como agente respondiendo una consulta sobre el vault, quiero que el protocolo query use el
grafo: tras localizar páginas seed (vía qmd o grep), traer los vecinos a 1 salto (backlinks,
`related:`, páginas que citan la misma fuente) antes de sintetizar, y resolver menciones que
matcheen alias hacia la página canónica. Además, como operador quiero regenerar el grafo
on-demand con una acción manual equivalente en ambos modos.

**Why this priority**: Es lo que convierte el grafo en mejor RAG efectivo — "usar toda la
base" en el momento de responder. Depende de US1 (grafo existente) y se potencia con US2.

**Independent Test**: Con un grafo generado sobre un fixture, verificar que el schema del
skeleton documenta el flujo de vecinos a 1 salto y que la acción manual regenera el grafo
en ambos modos (fixture local con stubs; docker vía e2e).

**Acceptance Scenarios**:

1. **Given** el skeleton nuevo, **When** se lee el schema del vault, **Then** el protocolo
   query instruye consultar el índice de backlinks/vecinos tras localizar páginas seed y
   antes de sintetizar, citando las páginas vecinas usadas.
2. **Given** un agente en modo local, **When** el operador ejecuta la acción manual de
   regeneración del grafo, **Then** el grafo y el state file quedan frescos sin requerir
   systemctl ni privilegios.
3. **Given** un agente en modo docker, **When** el operador ejecuta la acción manual
   equivalente, **Then** el resultado es el mismo (paridad de semántica).

---

### User Story 4 - Mantenimiento automático agnóstico al modo (Priority: P2)

Como operador, quiero que el runner de grafo+lint corra programado con la MISMA semántica en
ambos modos (docker: crontab; local: timer systemd), con schedule configurable en
`agent.yml`, e integrado a la operación existente: kill-switch lo detiene, healthcheck lo
vigila, status muestra frescura y counts, doctor degrada con exit codes honestos.

**Why this priority**: Sin automatización el grafo envejece igual que el lint manual de hoy.
Aplica desde el día 1 las lecciones de 013 para no repetir la clase de fallo "systemd
muestra todo sano mientras nada corre".

**Independent Test**: Render de crontab/units/wrappers contiene la entrada nueva en cada
modo; con stubs systemd, el kill-switch detiene el timer nuevo, healthcheck emite WARN si la
unit falla, doctor degrada por `last_status=error` y por hallazgos sobre umbral.

**Acceptance Scenarios**:

1. **Given** un agente docker con vault+qmd habilitados, **When** se renderiza el crontab,
   **Then** contiene la línea del mantenimiento de grafo con el schedule configurado.
2. **Given** un agente local con vault habilitado, **When** se instalan las units, **Then**
   existe el par wrapper+unit+timer del grafo con PATH auto-provisto y env del vault
   explícito desde la primera versión.
3. **Given** el kill-switch local activado, **When** se listan las units activas, **Then**
   el timer del grafo está detenido junto con el resto.
4. **Given** una corrida del runner que falla internamente, **When** el operador corre
   doctor, **Then** el estado degrada (warn/fail con exit code no-cero) aunque la unit
   systemd haya salido 0 (fail-silent en el entrypoint, honestidad en doctor).
5. **Given** hallazgos estructurales sobre el umbral configurado (ej. wikilinks rotos > 0),
   **When** el operador corre doctor, **Then** se reporta la degradación con los counts.

---

### User Story 5 - Upgrade aditivo para vaults existentes (Priority: P3)

Como operador de un agente EXISTENTE con wiki poblada (ferrari en docker, mclaren en local),
quiero que el upgrade agregue al vault SOLO lo que falta del skeleton nuevo (carpeta de
normalización, templates nuevos) sin sobreescribir jamás contenido existente y sin tocar el
`CLAUDE.md` del vault (capa co-evolucionada agente-humano): las secciones nuevas del schema
se entregan como material aparte más una entrada en `log.md` que instruye al agente a
integrarlas.

**Why this priority**: Es lo que hace la feature desplegable a los agentes reales sin el
upgrade destructivo de `vault_backup_and_reseed`. Sin esto, solo los scaffolds nuevos se
benefician.

**Independent Test**: Sobre un vault fixture poblado (con contenido en las 6 carpetas y un
`CLAUDE.md` modificado), correr el upgrade y verificar: estructuras nuevas presentes,
CERO archivos preexistentes modificados, `CLAUDE.md` intacto, material de schema nuevo
depositado aparte, entrada en `log.md`.

**Acceptance Scenarios**:

1. **Given** un vault poblado sin `wiki/normalization/`, **When** corre el upgrade aditivo
   (boot en docker, `--login` en local, o `--regenerate`), **Then** la carpeta y sus
   templates existen y ningún archivo previo cambió (verificable por hash).
2. **Given** un vault que ya tiene todas las estructuras nuevas, **When** corre el upgrade,
   **Then** es un no-op idempotente (sin duplicados, sin entradas repetidas en `log.md`).
3. **Given** un `CLAUDE.md` del vault editado por el agente, **When** corre el upgrade,
   **Then** ese archivo NO se modifica y las novedades del schema quedan disponibles como
   material aparte con instrucción de integración en `log.md`.

---

### Edge Cases

- Wiki vacía (skeleton limpio): runner exitoso con 0 nodos/0 hallazgos; no inventa drift.
- Página con frontmatter malformado o sin frontmatter: se reporta como hallazgo, no aborta
  la corrida ni omite el resto.
- Wikilinks con anchor (`[[page#seccion]]`) o alias de display (`[[page|texto]]`): el
  destino se resuelve a la página; el anchor no genera falso "roto".
- Alias de normalización dentro de un wikilink (`[[SENCOSUD]]`) o de un fenced code block:
  NO cuenta como ocurrencia (RESUELTO — es un link/código, no prosa a corregir; marcarlo
  sería falso positivo). Los inline code spans SÍ se escanean en v1. Ver
  contracts/normalization-pages.md (L5) y graph-artifacts.md (reglas de parsing).
- Alias con mayúsculas/minúsculas variables (SENCOSUD vs Sencosud): el matching es
  case-insensitive salvo que la página de normalización declare lo contrario.
- Dos corridas solapadas (manual + programada): lock; el perdedor sale limpio sin corromper
  artefactos.
- Corrida interrumpida a mitad de escritura: los artefactos derivados se escriben de forma
  atómica (nunca queda un grafo parcial visible).
- Vault temporalmente inaccesible (Syncthing moviendo archivos, bind-mount caído): el runner
  falla suave (exit 0, error en state file) y doctor lo reporta.
- Wiki grande (cientos/miles de páginas): la corrida completa termina en tiempo razonable
  (ver SC-006); si excede, se reporta en state file en vez de colgar el timer.
- Archivos fuera de `wiki/` (`raw_sources/`, `_templates/`, `index.md`, `log.md`): no son
  nodos del grafo, pero `index.md` sí se valida contra el filesystem.
- Artefactos derivados frente al backup del vault: quedan naturalmente excluidos (el backup
  toma solo el subset markdown) — verificar que ninguna extensión elegida los reintroduzca.
- qmd deshabilitado pero vault habilitado: el grafo funciona igual (no depende de qmd).

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: El sistema MUST derivar de TODA la base `wiki/` un grafo con un nodo por
  página (path, type, title, status, created/updated, tags) y aristas por cada wikilink del
  cuerpo, cada entrada de `related:` y cada entrada de `sources:` del frontmatter.
- **FR-002**: El grafo y sus índices MUST materializarse como artefactos derivados bajo
  `<vault>/.graph/` (dot-dir, ruta relativa al vault idéntica en ambos modos), regenerables
  siempre desde la wiki, escritos atómicamente, y NUNCA incluidos en el backup del vault
  (mismo principio que el índice qmd).
- **FR-003**: El sistema MUST producir un índice de backlinks consultable por el agente
  (dado una página, sus páginas entrantes y vecinas a 1 salto).
- **FR-004**: El runner MUST detectar y reportar determinísticamente, sin uso de LLM:
  huérfanos (sin links entrantes), wikilinks rotos (destino inexistente), violaciones del
  spec de frontmatter (type inválido, campos obligatorios faltantes), drift entre `index.md`
  y el filesystem, páginas stale (status incoherente con fechas/fuentes), y ocurrencias de
  alias de normalización en cuerpos de páginas wiki.
- **FR-005**: El runner MUST NOT editar jamás páginas de `wiki/` ni `raw_sources/` — reporta
  hallazgos; la corrección es del agente (LLM ownership de capa 2, principio del gist).
- **FR-006**: Cada corrida MUST dejar un state file parseable (frescura, último estado,
  counts por tipo de hallazgo) siguiendo el patrón de los state files existentes, y las
  corridas solapadas MUST serializarse vía lock.
- **FR-007**: El skeleton MUST incluir `wiki/normalization/` con template y convención de
  frontmatter PROPIA (forma canónica, lista de aliases, ámbito/notas, link a la entity
  canónica cuando exista); NO se agrega un séptimo `type` al enum del schema — los 6 types
  de conocimiento quedan intactos y el linter valida las páginas de normalización contra su
  propio spec de frontmatter; `index.md` MUST ganar la sección correspondiente.
- **FR-008**: El schema del vault (CLAUDE.md del skeleton) MUST instruir en el protocolo
  ingest un paso temprano de normalización: consultar `wiki/normalization/` y escribir capa
  2 con formas canónicas, preservando capa 1 VERBATIM.
- **FR-009**: El grafo MUST modelar la relación alias→canonical de modo que menciones
  variantes resuelvan hacia la página canónica en el retrieval.
- **FR-010**: El schema del vault MUST instruir en el protocolo query el uso del índice de
  backlinks/vecinos a 1 salto tras localizar páginas seed y antes de sintetizar.
- **FR-011**: El operador MUST poder regenerar el grafo on-demand con una acción manual
  equivalente en ambos modos (patrón de acciones manuales de 013), sin privilegios extra.
- **FR-012**: El runner MUST correr programado en ambos modos con la misma semántica —
  docker vía crontab, local vía timer systemd (conversión cron→OnCalendar existente) — con
  schedule configurable en `agent.yml`; default: cada 6 horas, independiente del ciclo qmd.
- **FR-013**: En modo local, los artefactos nuevos MUST aplicar desde la primera versión las
  lecciones de 013: PATH auto-provisto como primera acción del wrapper, env del vault
  explícito, fail-silent (exit 0) en el entrypoint con honestidad en doctor/healthcheck.
- **FR-014**: La integración operacional MUST ser completa en local: kill-switch incluye la
  unit/timer nuevos; healthcheck emite WARN si la unit falla; `agentctl status` muestra
  frescura del grafo y counts de hallazgos; `agentctl doctor` aplica el contrato de
  degradación: WARN (exit 1) por wikilinks rotos>0, frontmatter inválido>0, drift de
  index>0 o `last_status=error`; huérfanos/stale/alias son solo informativos; FAIL (exit 2)
  cuando el runner está muerto (state file ausente o más viejo que 2 intervalos con la
  feature habilitada).
- **FR-015**: NEXT_STEPS (en/es) MUST documentar la operación de lo nuevo en cada modo
  (journalctl/list-timers en local; heartbeatctl en docker).
- **FR-016**: Un mecanismo de upgrade aditivo MUST agregar a un vault poblado SOLO las
  estructuras faltantes del skeleton nuevo: nunca sobreescribe contenido existente, nunca
  modifica el `CLAUDE.md` del vault; las novedades del schema se entregan como
  `_templates/schema-updates-<version>.md` más una entrada instructiva en `log.md` que
  indica al agente integrarlas a su CLAUDE.md en la próxima sesión. MUST ser idempotente
  (segunda corrida: sin duplicados de archivos ni de entradas en `log.md`).
- **FR-017**: El upgrade aditivo MUST dispararse en boot (docker), en `--login` (local) y en
  `--regenerate`, y MUST ser desplegable a los agentes existentes (ferrari, mclaren) sin
  pérdida de contenido.
- **FR-018**: El modo docker MUST recibir la funcionalidad completa vía la lib espejada y la
  línea de crontab nuevas; el gate DOCKER_E2E es obligatorio por el cambio de comportamiento
  real en la imagen.

### Key Entities

- **Nodo de grafo**: una página de `wiki/` con sus atributos de frontmatter (type, title,
  status, fechas, tags) y su path como identidad.
- **Arista**: relación dirigida entre páginas — wikilink de cuerpo, `related:` declarado,
  co-cita de fuente (`sources:`), o alias→canonical.
- **Página de normalización**: declaración de forma canónica + aliases + ámbito + link a la
  entity canónica. Vive en `wiki/normalization/`.
- **Hallazgo estructural**: defecto detectado determinísticamente (huérfano, link roto,
  frontmatter inválido, drift de index, stale, ocurrencia de alias), tipado y anclado a la
  página afectada.
- **Artefacto derivado de grafo**: materialización regenerable del grafo + backlinks +
  hallazgos bajo el vault; nunca respaldado, siempre reconstruible.
- **State file del runner**: resumen parseable de la última corrida (frescura, estado,
  counts) para status/doctor/healthcheck.
- **Delta de skeleton**: el conjunto de estructuras nuevas que el upgrade aditivo aporta a
  un vault existente sin tocar su contenido.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Sobre un vault fixture con hallazgos conocidos (huérfano, link roto, drift de
  index, alias presente), el runner reporta exactamente esos hallazgos — 0 falsos positivos
  y 0 falsos negativos; sobre el skeleton limpio reporta exactamente 0.
- **SC-002**: Tras cualquier corrida (programada o manual), el operador puede ver en un solo
  comando (`agentctl status`/`doctor`) la frescura del grafo y los counts de hallazgos **en
  modo local** (acotado en clarify de análisis, H1). En docker la observabilidad es el state
  file `wiki-graph.json` + el log de cron (el status/doctor docker para RAG queda en el
  backlog de 013). Un comando docker read-only equivalente es superficie futura.
- **SC-003**: El mismo vault produce los mismos hallazgos en modo docker y en modo local
  (paridad de semántica, mismo criterio que 013).
- **SC-004**: Con el kill-switch activo en local, ninguna corrida programada del grafo se
  ejecuta hasta reactivar.
- **SC-005**: El upgrade aditivo sobre un vault poblado modifica 0 archivos preexistentes
  (verificable por hash antes/después) y deja las estructuras nuevas presentes; correrlo dos
  veces no duplica nada.
- **SC-006**: Una wiki de hasta 1.000 páginas se procesa completa en menos de 60 segundos en
  el hardware objetivo (Raspberry Pi 5); el runner nunca deja el timer colgado.
- **SC-007**: Un ingest de una fuente que contiene un alias declarado produce páginas de
  capa 2 escritas con la forma canónica, con la capa 1 intacta VERBATIM (verificable en el
  gate manual con un transcript real que contenga SENCOSUD).
- **SC-008**: Suite host completa verde y DOCKER_E2E verde antes del merge.

## Assumptions

- **Grafo derivado, no servidor de grafos** (RATIFICADO en clarify 2026-07-06): derivación
  determinista materializada bajo `<vault>/.graph/`. Un motor de grafos externo queda fuera
  por stack (Alpine, `cap_drop: ALL`, mínimas dependencias) y porque el gist mismo no lo
  usa. No se reabre sin causa.
- **Normalización como carpeta con convención propia** (RESUELTO en clarify 2026-07-06):
  `wiki/normalization/` NO introduce un séptimo `type` formal ("the only six" intacto);
  funciona como capa de configuración del wiki con su propio frontmatter, validada por el
  linter contra su propio spec.
- **Entrega del schema nuevo a vaults existentes** (RESUELTO en clarify 2026-07-06):
  `_templates/schema-updates-<version>.md` + entrada instructiva en `log.md`; el agente
  integra a su `CLAUDE.md` co-evolucionado en la próxima sesión.
- **Default de schedule** (RESUELTO en clarify 2026-07-06): cada 6 horas, configurable en
  `agent.yml`, independiente del ciclo qmd. La acción manual cubre la regeneración
  inmediata.
- **Lenguaje del runner**: decisión de plan (bash/awk estilo de la casa vs bun/JS con
  parsing más robusto — bun está garantizado en ambos modos post-013 FR-016, pero agregaría
  una dependencia de tests host). El spec solo exige determinismo, robustez ante entrada
  malformada y testeabilidad bats.
- **El grafo no depende de qmd**: vault habilitado basta; qmd sigue siendo el buscador y no
  cambia (pin 2.5.3, colecciones intactas).
- **Los gates 013 pendientes se apilan**: el gate manual 014 en ferrari/mclaren puede
  ejecutarse en la misma sesión que los confirmatorios de 013 cuando el hardware esté
  disponible.
- **Decisiones heredadas** (no reabrir): storage contracts 013 (XDG bajo `.state`), render
  engine sin `{{#if}}` anidado → precomputar en `setup.sh`, libs espejadas con COPY
  explícito, fail-silent Principle IV con honestidad en doctor, derivados regenerables nunca
  respaldados, 1 agente por host en local v1.

## Fuera de alcance (backlog)

- Servidor de base de datos de grafos real (Neo4j o similar).
- Visualización propia del grafo (Obsidian graph view ya lo cubre vía Syncthing).
- Lint AGÉNTICO programado (sesiones LLM automáticas para contradicciones semánticas):
  sigue siendo manual/on-demand vía protocolo lint del schema; candidato futuro sobre la
  infraestructura heartbeat existente.
- Cambios al motor qmd o su esquema de colecciones.
- Edición automática de páginas wiki por scripts (el script reporta, el agente corrige).
- Migración de contenido de vaults existentes (solo estructura aditiva).
- Deuda docker registrada en 013 (status/doctor docker sin reporte RAG, stderr del watcher
  docker) — no se amplía aquí.
