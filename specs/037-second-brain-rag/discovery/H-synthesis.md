# H — Síntesis de discovery para la feature 037: LLM Wiki (Karpathy) + Second Brain (Forte)

**Fecha:** 25-09-2026 · **Base:** `main` @ `70214d9`, VERSION `0.26.0` · **Insumos:** informes A (libs RAG), B (config/render/tests), C (schema y runtime), D (historia de specs 010-019), E (fuente primaria de Karpathy), F (método de Forte), G (prior art 2025-2026). Todos leídos completos. Solo lectura del repo; nada modificado.

**Propósito.** Documento base para `/speckit-specify` de 037. No es la spec: es el mapa de lo que existe, lo que falta, tres diseños posibles, las decisiones que le corresponden al operador y lo que hay que medir antes de decidir.

Convención de evidencia:

- **[H]** hecho verificado: `archivo:línea` leído en esta sesión o en el informe citado (A-G verifican con línea; las citas clave las re-leí hoy).
- **[I]** inferencia razonable; no confirmada por código ni medición.
- **[NV]** no verificable en este host (semántica interna de `qmd` 2.5.3, estado de vaults vivos, etc.).
- **[SEC]** fuente secundaria (resúmenes del libro de Forte; el libro no es fetchable).

Las referencias `A §4.3`, `C:154`, `D §2.1` apuntan a secciones o líneas de los informes de este directorio.

---

## 1. Estado actual verificado: qué del LLM Wiki de Karpathy ya existe y dónde

1. **Las tres capas del gist están implementadas verbatim** [H]: `raw_sources/` inmutable con frontmatter propio (`modules/vault-skeleton/raw_sources/README.md`, `_templates/source.md`); `wiki/` con seis tipos cerrados — `summary entity concept comparison overview synthesis` ("the only six", `modules/vault-skeleton/CLAUDE.md:32-46`) más `wiki/normalization/` como carpeta-convención de 014; y el `CLAUDE.md` del vault como schema **co-evolucionado** que ningún script reescribe (`scripts/lib/vault.sh:52-57`). E §4 mide 12/22 elementos del gist+post completos, 7 parciales, 3 ausentes.
2. **Frontmatter único de 8 claves** (`title type sources related created updated status tags`, `CLAUDE.md:57-72`) con `status ∈ {draft, active, stale, superseded}` [H]. Las plantillas arrancan en `status: active` (C §1.1).
3. **`index.md` y `log.md` existen y se lintean, pero `index.md` no se consulta** [H]: el protocolo de query manda a `search_notes`/`Glob`/`Grep` (`CLAUDE.md:118-119`) y al grafo (`:120-125`); el gist dice "reads the index first" (E fila 10). `log.md` es idéntico al gist (`## [YYYY-MM-DD] op | título`, parseable con `grep "^## \["`).
4. **Linter determinista + grafo derivado** [H]: `scripts/lib/wiki_graph.sh` (awk + jq, bash 3.2) emite `<vault>/.graph/{graph,backlinks,findings}.json` con seis kinds de findings (`orphan broken_link frontmatter_violation index_drift stale alias_occurrence`) cada `20 */6 * * *` en ambos modos; "el script reporta, el agente corrige" (014 FR-005). Enums `VALIDTYPE`/`VALIDSTATUS` hardcodeados (`wiki_graph.sh:111-114`); toda clave de frontmatter fuera de las 11 conocidas se **ignora en silencio** (`:202-227`); `tags` no se extrae (grep vacío) pese al contrato `graph-artifacts.md:31-33` (A §3.4).
5. **Retriever híbrido ya saturado** [H]: `@tobilu/qmd` 2.5.3 (BM25 + vector + rerank on-device) con ciclo de vida completo — setup al boot, watcher inotify (debounce 15 s) + cron `*/5`, loop de embed multi-pasada (018), sqlite-vec compilado para musl (017). **Una sola colección `vault` sobre la raíz del vault con máscara `**/*.md` y sin exclusiones** (`scripts/lib/qmd_index.sh:379`): entran `CLAUDE.md`, `index.md`, `log.md`, `_templates/*.md`, `raw_sources/**` y `normalization/`.
6. **Upgrade aditivo con contrato** [H]: `vault_seed_missing` (`vault.sh:70-112`) crea dirs/plantillas ausentes, deposita `modules/vault-deltas/schema-updates-0.8.0.md` gateado por el marcador oculto `_templates/.schema-updates-0.8.0.applied` (`:93-94`) y agrega una línea `upgrade` a `log.md`. Cableado a literales `0.8.0`; un segundo delta necesita bloque y marcador propios (B §3). Triggers reales: boot docker y `--regenerate` local; `--login` local **no** lo corre (drift, B §6.8).
7. **Backup y estado** [H]: `backup/vault` solo `*.md` (`backup_vault.sh:93`); `.graph/` JSON-only, nunca respaldado; state files bajo `scripts/heartbeat/*.json`; locks/tmp fuera del vault (Syncthing).
8. **Único tick LLM programado = heartbeat** [H]: `claude --print` con **un** prompt configurable, config dir aislado sin plugins, **docker-only** (`modules/claude-md.tpl:92`: "Nothing" en local), y **no toca el vault** (grep vacío en `heartbeat.sh`, C §2.4). El "lint agéntico programado" quedó en backlog de 014 por costo de tokens (D §3).
9. **Tres capas de memoria con heurística de ruteo y regla "don't double-write"** [H] (`CLAUDE.md:167-183`; `claude-md.tpl:176-193`). "Project" ya tiene dos casas: `entity` del vault ("person, product, tool, **project**…", `CLAUDE.md:39`) y auto-memoria `project_*` (`docs/state-layout.md:49`). PARA "Projects" sería la tercera (C §3.2).
10. **Config muerta en `agent.yml`** [H]: `vault.initial_sources`, `vault.mcp.server`, `vault.schema.frontmatter_required`, `vault.schema.log_format` se escriben en el heredoc y nadie los lee (B §1). `initial_sources` es el hueco natural del batch-ingest que el gist menciona (E fila 8).
11. **Ausente de Karpathy en el repo** [H, E §5.1]: index-first en query; lint generativo ("data gaps con web search", "nuevas preguntas y fuentes"); paso "discuss key takeaways" en ingest; filing de respuestas como política ("often" vs "ask first"); formatos de salida (Marp/matplotlib); historial git del wiki consultable in-place.
12. **Cero menciones previas** a PARA, Forte, Second Brain, Progressive Summarization, Intermediate Packets o weekly review en `specs/`, `docs/`, `modules/`, README y CHANGELOG (D §6). Karpathy tampoco los nombra (E §6); su "append-and-review note" es el anti-PARA. **037 es una extensión propia**, amparada por la cláusula "everything is optional and modular" del gist, no una lectura de la fuente.
13. **Flota** (memoria del proyecto, [NV] estado interno): donna, linus y rodri-cenco-admin en docker (ferrari); ferrari-admin y mclaren-admin en local (systemd). Sus `CLAUDE.md` de vault son co-evolucionados y nunca se sobreescriben; cualquier cambio de protocolo les llega solo como delta que el agente integra a mano, sin verificación (C §6.13).

---

## 2. Tabla de mapeo: Second Brain → mecanismo existente | parcial | ausente → dónde vivir con el menor cambio

Regla de lectura: "Existente" = ya cubierto sin cambio; "Parcial" = hay construct pero falta la semántica de Forte; "Ausente" = nada. La columna "Propuesta" es **[I]/propuesta no validada**, elegida para no tocar ni los seis tipos ni el `status` (C §5, D §7, F §5.3, G §7).

| Concepto (Forte) | Fuente F | Estado | Mecanismo existente (archivo) | Propuesta de menor cambio |
|---|---|---|---|---|
| **Capture: criterios** (resonancia; 4 preguntas: inspira / útil / personal / sorprende) | F §2.5 [HV/SEC] | Parcial | Capa 1 `raw_sources/` + ingest paso 1 "clip" (`CLAUDE.md:92-94`); captura pasiva conversacional ya la hace claude-mem (C §3.2). No hay filtro ni bandeja. | La resonancia **no se mecaniza** (F §4.2). Proxy: paso 0.5 de ingest = "¿aporta a un favorite problem o a un proyecto activo? ¿contradice una página existente?" → anota `problems:`/`project:`; si nada matchea, el agente **pregunta** antes de ingerir. Bandeja = **estado computado**, no carpeta: finding `pending_ingest` (raw sin `summary` que lo cite en `sources:`), derivable del grafo (E §5.2, F §5.2). |
| **12 Favorite Problems** | F §2.8 [HV] | Ausente | Nada. `vault.initial_sources` es config muerta, no sirve de lista. | **Una** página `wiki/synthesis/favorite-problems.md` (`type: synthesis`, `status: active`, lista numerada con slug estable por problema), nombrada en `CLAUDE.md` del vault. Campo `problems: []` en páginas que aportan. Autoría humana; lint de forma (How/What, ≤ 12) solo en el diseño (c). Nunca en `normalization/` (C §6.3). |
| **PARA: Projects** | F §2.1-2.2 [HV] | Parcial | `entity` admite "project" (`CLAUDE.md:39`; `_templates/entity.md:14`) pero su plantilla es una ficha de identidad; auto-memoria `project_*` guarda "ongoing project state" (`state-layout.md:49`). Sin `goal`, `due`, `next_action`, ni estado de avance. | `entity` + `para: project` + `goal`, `due`, `next_action`, `next_review` en frontmatter; plantilla variante `_templates/entity-project.md` (mismo `type: entity`). Es la página-MOC del proyecto: enlaza al wiki, no lo fragmenta (F §5.2 "MOC-as-category", G P1/P2). Auto-memoria `project_<slug>.md` pasa a ser **puntero** de 2-3 líneas (C §3.3; G P15 "single-source status"). |
| **PARA: Areas** | F §2.2 [HV] | Ausente | Lo más cercano es `overview` (mapa de un dominio, `CLAUDE.md:42`); no hay "estándar a sostener". | `overview` + `para: area` + `standard`, `cadence`; plantilla `_templates/overview-area.md` (Estándar / Indicadores / Proyectos activos / Recursos clave). Se crea **bajo demanda**, nunca pre-creada (F R25, S3 "never pre-create empty folders"). |
| **PARA: Resources** | F §2.1 [HV] | Existente | Todo el vault es "R" (F §5.2: "the R of my PARA can be my Zettelkasten"). | `para` **ausente = resource** por defecto; ninguna página existente cambia. |
| **PARA: Archives** | F §2.1, §2.4 [HV] | Ausente | Solo `status: superseded|stale` por página, con semántica de frescura de conocimiento, no de "proyecto cerrado" (C §4). Sin sección, sin fecha de cierre, sin exclusión del índice. | `para: archive` + `archived: YYYY-MM-DD` **en el mismo archivo** (sin mover: mover rompe wikilinks, C §5.4); sección `## Archive` en `index.md` (el linter ignora encabezados, C §1.7). `status` **no** se toca (D6 en §5). Exclusión del índice qmd: decisión D6. |
| **Progressive Summarization** (capas 0-5; 50/25/20/5/<1 %; oportunista) | F §2.6 [HV] | Parcial | Cadena implícita raw (L0) → `summary` con Thesis/Key claims (≈L1+L4) → `concept/overview/synthesis` (≈L5). Sin nivel declarado; sin lugar para L2/L3 porque `raw_sources/` es inmutable y prohíbe contenido LLM (`README.md:18`; C §6.11). | Campo `distill: 1..4` + secciones opcionales en `_templates/summary.md` (`## Highlights`, `## Core`, resumen ejecutivo arriba). **Solo se sube de capa al tocar la página por otra razón** (F R16). No importar L2/L3 como fin: la crítica de Sascha (F §6) dice que el valor está en L4-L5, que el wiki ya hace. |
| **Intermediate Packets** (5 tipos [SEC]; reutilizables como Lego) | F §2.7 | Parcial | Query paso 5 "file good answers back" como `overview`/`synthesis` (`CLAUDE.md:131-133`); `synthesis` "should be rare" (`:108`); lint reports ya van a `wiki/synthesis/lint-<date>.md`. | `packet: distilled-note|outtake|wip|deliverable|external` sobre el **tipo natural** de cada página (un checklist reutilizable es `concept`, una matriz de decisión es `comparison`, un borrador integrador es `synthesis`) — no todo a `synthesis` (C §6.8). Sección `## Packets` en `index.md`. Sin directorio nuevo. |
| **Project checklists** (kickoff / completion) | F §2.10 [SEC] | Ausente | Nada. | Dos operaciones nuevas en `CLAUDE.md` del vault: "Operation: project kickoff" (registrar objetivo/fecha, buscar páginas relacionadas por nombre/tags/texto, enlazarlas, outline) y "Operation: project close" (marcar `para: archive` + `archived`, extraer packets, actualizar `index.md`, nota en auto-memoria). Ops `project-open`/`project-close` en `log.md` (vocabulario libre, `vault.sh:146-153`; C §5.5). |
| **Weekly / monthly review** | F §2.9 [HV] | Parcial | "Maintenance triggers… once a month" (`CLAUDE.md:185-195`) es salud del wiki, no revisión de compromisos. Lint determinista cada 6 h; heartbeat docker-only con 1 prompt (C §2.4). Local sin tick LLM (`claude-md.tpl:92`). | Separar **cola** (determinista) de **ejecución** (LLM) de **decisión** (humano), como hace todo el prior art (G P11). Cola = finding `review_due` cuando `next_review < hoy`, computado por el runner del grafo existente (sin cron nuevo). Ejecución = el agente ofrece la revisión en la próxima conversación (ambos modos) y, opcionalmente en docker, un prompt de heartbeat. Registro = `## [fecha] review | weekly — N proyectos, M archivados` en `log.md`, **no** un archivo por semana (C §6.7-6.8; G P17). |
| **Noticing habits** (retitular, enlazar, mover, `updated` viejo) | F §4.2 [SEC] | Existente (equivalente máquina) | `findings.json`: `orphan`, `broken_link`, `index_drift`, `stale`, `alias_occurrence` (A §3.2). | Añadir validación del valor de `para` (finding `frontmatter_violation: para invalid`) y `project_incomplete` (`para: project` sin `goal` o `due`) al mismo runner. |
| **Archipelago of Ideas / Hemingway Bridge** (Express: outline de fragmentos existentes; cerrar cada sesión dejando el siguiente paso) | Digest S4 [SEC]; F R19 | Ausente | Query paso 6 y ingest paso 6 escriben `log.md` con título, sin "siguiente paso". Los hooks `Stop` de 028 son de canal, no de vault. | Archipelago = el outline de wikilinks del kickoff (R11 d). Hemingway Bridge = regla de cierre en `CLAUDE.md` del vault: toda sesión que tocó un proyecto termina con `next_action` actualizado en la ficha y una línea `## [fecha] session | <proyecto> — next: …` en `log.md`. Prosa, cero código. |

Lo que **no** entra al mapeo porque Forte lo reserva al humano (F §4): la resonancia, la autoría de los favorite problems, la zona gris proyecto/área, la decisión de cerrar o pausar un proyecto y "reminding you of what's important" (F21). El agente mecaniza solo lo que se apoya en campos declarados.

---

## 3. Gaps reales del RAG hoy, ordenados por impacto

Criterio de orden: (impacto en la calidad de respuesta o en la operación) × (frecuencia con que ocurre) ÷ (costo de arreglar). Cada fila trae evidencia y remedio candidato.

| # | Gap | Evidencia | Impacto | Remedio candidato (costo) |
|---|---|---|---|---|
| 1 | **qmd indexa todo el markdown del vault** — `CLAUDE.md`, `index.md`, `log.md`, `_templates/*.md` (incluido el delta 0.8.0), `raw_sources/**` y `normalization/` — en una sola colección `vault`, máscara `**/*.md`, sin `ignore` | [H] `qmd_index.sh:372,379`; A §2; C:154. Prior art: `index.md`/`log.md` como "gravity wells" (G §2.4), frontmatter como top hit (qmd #975), doble indexación raw+summary pierde 20 % del top-K (qmd #645). El repo mismo lo marcó [NV] "no medido" (C §6.7) | Alto: cada consulta compite contra plantillas vacías, la bitácora, el schema y el texto crudo que ya está resumido en `summary`. Crece con cada packet/revisión nueva | qmd 2.5.3 ya trae `includeByDefault` + `collection include|exclude` (v1.1.0) e `ignore:` por colección (v1.1.2, solo YAML) [H G §2.26]. Tres formas: raíz de colección = `wiki/`; `ignore:` globs; dos colecciones (`wiki` incluida, `raw` excluida por defecto). Toca lib espejada → DOCKER_E2E. Exige Fase 0 (§7 Q1-Q2) |
| 2 | **El protocolo de query no lee `index.md` primero** | [H] `vault-skeleton/CLAUDE.md:118-119` vs gist "reads the index first" (E fila 10). El índice se mantiene y se lintea (`index_drift`) pero no se usa como entrada | Alto a escala de la flota (< 100 fuentes: es exactamente el régimen donde Karpathy dice que el índice basta); reduce llamadas al retriever y al grafo | Prosa: paso 0 "leer `index.md` (y la ficha del proyecto activo si la hay), luego búsqueda, luego grafo". Skeleton + delta. Costo cero en código; Ar9av reporta 4,4× menos latencia y 9,9 → 4,6 tool calls con "títulos+resúmenes antes de cuerpos" (G §2.5, auto-reportado) |
| 3 | **No hay dimensión de accionabilidad**: sin proyectos activos, áreas, archivo ni cola de revisión; "project" ya vive en dos casas con la regla "don't double-write" | [H] C §3.2, §4; D §6.1; `CLAUDE.md:39` + `state-layout.md:49` | Alto para el uso real (asistente que coordina proyectos): hoy el vault responde "qué sé" pero no "qué necesito ahora" (G P1) | Frontmatter PARA sobre los seis tipos + regla de routing (ficha en vault, puntero en auto-memoria) + delta. Es el núcleo de 037 |
| 4 | **Sin revisión programada con LLM y sin cola determinista**; heartbeat docker-only con un solo prompt; local sin tick LLM; `local_schedule.sh` no convierte crons con día de semana | [H] C §2.4; `claude-md.tpl:92`; `scripts/lib/local_schedule.sh:44-47` (exige `dow=*`); A §4.5 | Medio-alto: la weekly review de Forte no tiene vehículo; un cron `0 9 * * 1` en local caería al fallback con WARN | Cola como finding `review_due` calculado por el runner del grafo desde `next_review` (sin cron nuevo, sin tocar `local_schedule.sh`); ejecución en la próxima sesión o por heartbeat (docker, opt-in). Reabrir el lint agéntico programado solo con argumento de costo (D §7.8) |
| 5 | **Linter rígido donde no debe y ciego donde no debe**: `VALIDTYPE`/`VALIDSTATUS` hardcodeados; claves desconocidas ignoradas sin violación (un `para: projet` pasa); `tags` no se extrae | [H] `wiki_graph.sh:111-114`, `:202-227`; grep `tags` vacío; contrato `graph-artifacts.md:31-33` promete `tags` (A §3.4) | Medio: hoy es ventaja (metadatos nuevos no rompen nada) pero sin validación explícita el eje PARA se degrada en silencio | Tres toques en `wiki_graph.sh` por clave nueva (rama awk, registro `N`, proyección jq; A §4.1) + `VALIDPARA`. Re-baselinea la fixture-oráculo `tests/fixtures/vault-graph` (conteos exactos, `wiki-graph.bats:65-85`) |
| 6 | **Sin unidad de recuperación destilada por página**: `title` solo se valida por presencia; no hay `description`/preamble que el agente lea antes del cuerpo | [H] `wiki_graph.sh:210`; G P7/P8 (obsidian-mind exige `description` ~150 chars; obsidian-second-brain `## For future agent`) | Medio: "distill on read" es donde el prior art pone el mayor efecto sin tocar el índice (G §7.7) | Campo `description` corto obligatorio para páginas nuevas (prosa + plantillas) y hook de `index.md` = ese `description`. Sin código salvo opcional finding `description_missing` |
| 7 | **Watcher inotify vigila `.graph/`**: cada corrida del grafo (6 h) marca dirty y dispara `qmd-reindex` que termina `skipped` con `runs++`; y el hash de debounce (`vault_hash`) excluye `.trash`/`.obsidian` mientras la colección qmd no excluye nada | [H] `scripts/qmd_watch.sh:77` (`-r` sobre `vault_dir`); `qmd_index.sh:538-541`; `backup_vault.sh:52-61`; A §2, §4.3 | Bajo hoy (un tick vacío cada 6 h); crece con cada derivado nuevo (`para.json`, `review.json`) | Excluir `.graph/` del `inotifywait` (`@dir`/`--exclude`, [NV] en Alpine, §7 Q8) o mover derivados frecuentes fuera del vault. Alinear criterios de exclusión hash ↔ qmd si 037 agrega carpetas |
| 8 | **Filing de respuestas conservador y sin métrica**: "propose… ask first" vs Karpathy "often I end up filing" | [H] `CLAUDE.md:131-133`; E fila 12 | Medio: es la palanca 2 de "compilación" (E §3.3) y la anti-collector's-fallacy de F §6 (medir uso, no volumen) | Política explícita en el schema (p. ej. auto-proponer cuando la síntesis cita ≥ 3 páginas) + `query | … | filed: yes/no` en `log.md` para medir tasa. Prosa |
| 9 | **Lint no generativo**: no busca "data gaps imputables con web search" ni propone preguntas/fuentes nuevas | [H] E fila 14 (grep vacío) | Medio-bajo: es la parte del gist que convierte el lint en agenda de investigación; conecta natural con favorite problems ("problemas sin aportes") | Sección adicional del reporte `lint-<date>.md`. Prosa |
| 10 | **Entrega del schema a la flota no verificable**: el delta se deposita y "el agente integra"; ningún finding detecta un delta pendiente | [H] `schema-updates-0.8.0.md:3-7`; C §6.13; ninguna comprobación en `wiki_graph.sh` | Medio para 037 específicamente (será el segundo delta y el más grande) | Finding `schema_delta_pending` (delta presente + marcador con edad > N días + ausencia de un centinela en `CLAUDE.md` del vault, p. ej. la cadena `para:`). [I] propuesta; ver D9 |
| 11 | **Config muerta**: `vault.initial_sources`, `vault.mcp.server`, `vault.schema.frontmatter_required`, `vault.schema.log_format` sin lector | [H] B §1, §6.1 | Bajo, pero cada clave nueva de 037 bajo `vault:` agrava el patrón | Decidir antes de agregar claves: reciclar (`initial_sources` → batch-ingest), documentar como reservadas o retirar (retirar rompe `schema.bats:43`; cambio aparte) |
| 12 | **`status`/`doctor` docker no reportan qmd ni wiki-graph** (hay que leer los JSON a mano); MCPVault docker apunta a `/home/agent/.vault` fijo, ignora `vault.path` | [H] D §3 (`heartbeatctl::cmd_status`); B §6.7 (`setup.sh:2446`) | Bajo para el RAG, medio para operar 037 (una cola de revisión invisible en docker no sirve) | Enriquecer `cmd_status` docker con counts de `wiki-graph.json` (cierra deuda de 013). No ampliar la superficie de `vault.path` sin cerrar el quirk de MCPVault |

Fuera de la tabla pero relevante como fondo: **la palanca "retriever" está saturada** (E §3.3) — 037 no debe vender un vector mejor; debe vender compilación más densa, navegación index-first y una dimensión de accionabilidad encima del RAG existente ("PARA organizes, it does not capture or use", F §6).

---

## 4. Tres diseños candidatos

Todos comparten cuatro invariantes heredadas que no se re-litigan (D §2.6, §7): sin séptimo `type`; sin scripts que editen `wiki/`; `CLAUDE.md` del vault nunca sobreescrito (delta + marcador propio); derivados = JSON en `.graph/`, jamás respaldados. Y una consecuencia común: **los tres exigen DOCKER_E2E**, porque `vault.sh` (nuevo bloque de delta) y `wiki_graph.sh` (validación de `para`) son libs espejadas con `COPY` en el Dockerfile (D §5.2; B §2.3).

### 4.1 Diseño (a) — mínimo: eje PARA + destilación en schema y linter, más higiene del retrieval

| Superficie | Qué cambia | Qué NO cambia |
|---|---|---|
| Skeleton (`modules/vault-skeleton/`) | `CLAUDE.md`: frontmatter extendido; tests PARA como predicados (R1-R4); "Operation: archive"; paso 0 **index-first** en query; paso 0.5 de ingest (favorite problems / proyecto activo); `description` obligatorio; capas de destilación en `summary`. `index.md`: secciones `## Projects (active)`, `## Areas`, `## Archive`, `## Packets`, `## Favorite problems`. `_templates/`: `entity-project.md`, `overview-area.md`, secciones nuevas en `summary.md`. Página semilla `wiki/synthesis/favorite-problems.md` (vacía, con instrucciones) | Los seis tipos, sus subdirs, `status` enum, `log.md` (solo vocabulario de ops en prosa), `normalization/` |
| Schema del vault (`CLAUDE.md`) | Ver arriba; regla de routing "ficha en vault, puntero en auto-memoria"; nota de migración para `project_*` existentes | La estructura de tres capas y los tres protocolos |
| Frontmatter | Nuevas claves planas, todas `[A-Za-z_]+` y escalares/flow arrays (A §4.1): `para`, `archived`, `project`, `distill`, `packet`, `problems`, `description`. `para` ausente = `resource` | `type`, `status`, `sources`, `related`, `created`, `updated`, `title`, `tags` |
| `wiki_graph.sh` | Extraer `para` (y de paso `tags`, cerrando el drift del contrato 014); `VALIDPARA = project area resource archive`; nueva razón de `frontmatter_violation` (`para: invalid`); `para` en el nodo de `graph.json`; counts nuevos con default en `wiki_graph_write_state` | Los seis findings existentes, `VALIDTYPE`, `VALIDSTATUS`, el formato de `.graph/*.json` (schema 1 se conserva; campos aditivos) |
| qmd | Higiene del índice **dentro del pin 2.5.3** (una de: raíz `wiki/`, `ignore:` globs, dos colecciones) con migración única gateada por sentinel; la forma exacta sale de Fase 0 (§7 Q1) | El pin 2.5.3, el loop de embed, el watcher, las cadenas parseadas |
| `agent.yml` | **Ninguna clave nueva** (lista de exclusión como constante interna con override por env solo para tests, precedente `QMD_EMBED_MAX_PASSES` de 018) | Todo |
| heartbeat / cron | Nada | Todo |
| `agentctl` | Nada obligatorio (los counts nuevos llegan al state file; `doctor` local solo suma si se decide elevar `para invalid` a WARN) | Todo |
| `vault.sh` + deltas | Bloque paralelo `schema-updates-0.27.0` con lista explícita (templates nuevos, página semilla), marcador `_templates/.schema-updates-0.27.0.applied`, línea `upgrade` en `log.md` | El bloque 0.8.0 intacto |

- **Constitución:** I sin cambios (cero claves; si se agrega alguna, patrón `has()` + `schema.sh` + `known_external`); II intacto (nada de privilegios; el vault sigue entrando por bind-mount); III test-first en `vault.bats` (lista fija de templates y headers de `index.md`), `vault-upgrade.bats` (segundo delta: "0 archivos preexistentes modificados", idempotencia), `wiki-graph.bats` (fixture re-baselineada + caso `para` inválido + "skeleton limpio → exactamente 0"), `qmd-*.bats` (layout nuevo con el seam 019); IV idempotencia por marcador y sentinel de migración qmd; V estado nuevo solo bajo `.graph/`/`scripts/heartbeat/`; VI pins intactos.
- **DOCKER_E2E:** sí (libs espejadas + `seed_missing` en boot + colección qmd). Nota: el Tier-1 de `docker-e2e-qmd.bats` quedó sin validación Docker desde 019 (D §3) — la primera corrida real puede destapar drift ajeno a 037.
- **Riesgo para vaults existentes:** bajo. Todo es aditivo; ninguna página existente cambia; `para` ausente = resource; la migración qmd re-embebe una vez (en ferrari ~2.400 chunks bajo el loop de 018: minutos a decenas de minutos, [NV] exacto). El riesgo real es humano: el agente debe integrar el delta más grande hasta ahora (C §6.13).
- **Tamaño estimado:** 22-28 tareas test-first (referencia: 014 ≈ 33, 018 = 18, 019 = 12). Sin prompt de wizard (evita los tres touchpoints de B §2.4).

### 4.2 Diseño (b) — medio: (a) + operaciones de proyecto y revisión con disparador determinista, y retrieval con filtro/boost por PARA

Suma a (a):

| Superficie | Qué cambia adicionalmente | Qué NO cambia |
|---|---|---|
| Schema del vault | "Operation: project kickoff" y "project close" (R11/R12); "Operation: weekly review" y "monthly review" con los pasos mecánicos separados de los decisionales (F §4.2); Hemingway Bridge como regla de cierre; política de filing con medición | — |
| Frontmatter | + `goal`, `due`, `next_action`, `next_review`, `standard`, `cadence`, `area` (wikilink a la página de área) | — |
| `wiki_graph.sh` | Findings `review_due` (`next_review < hoy`), `project_incomplete` (`para: project` sin `goal`/`due`), `pending_ingest` (raw sin `summary` que lo cite: la bandeja computada), `description_missing`; counts correspondientes | El runner sigue siendo el de las `20 */6`; **sin cron nuevo**: la cadencia vive en las fechas `next_review` que el agente fija en cada revisión, así `local_schedule.sh` no se toca |
| Retrieval "filtro/boost por PARA" | **A nivel de protocolo y grafo, no de ranking**: la ficha del proyecto activo es la MOC de entrada (index-first → ficha → `related`/backlinks a 1 salto → búsqueda); páginas `para: archive` se citan solo si la pregunta las pide. El filtro en el motor (`--filter status nin [archived]`) existe solo en `[Unreleased]` de qmd, posterior a 2.8.3 (G §2.26) → **fuera** | El pin |
| heartbeat | Docker, opt-in: prompt de revisión documentado para `heartbeatctl set-prompt` (un solo prompt vigente; el operador elige). Ningún cambio en `heartbeat.sh` | Local sin tick LLM; se documenta honesto |
| `agentctl` | `status`/`doctor` local: `review_due` y `pending_ingest` como counts (informan, no degradan); docker `heartbeatctl status` enriquecido con `wiki-graph.json` (cierra deuda 013) | Contrato 0/1/2 |
| `agent.yml` | Sigue sin claves nuevas si la cadencia va en `next_review`. Solo si se opta por heartbeat automático: reutiliza `features.heartbeat` existente, sin campo nuevo | — |

- **Constitución:** igual que (a); IV refuerza que `review_due` es una **cola**, nunca una acción; II intacto porque el heartbeat no cambia.
- **DOCKER_E2E:** sí (mismas libs) + un caso e2e de `heartbeatctl status` si se enriquece.
- **Riesgo para vaults existentes:** medio. El delta trae cuatro operaciones nuevas y siete claves; los `project_*` de auto-memoria de la flota necesitan una nota de migración explícita o los dos sistemas divergen (C §6.9). `pending_ingest` puede arrancar con muchos findings en vaults con raws antiguos sin summary (aceptable: es información, no WARN).
- **Tamaño estimado:** 38-46 tareas. Cabe en una feature si se renuncia al heartbeat automático (que agregaría medición de "¿la sesión del heartbeat carga los MCP de proyecto?", §7 Q3).

### 4.3 Diseño (c) — ambicioso: (b) + packets como unidad de recuperación + favorite problems como filtro de captura + archivado automático con decaimiento

Suma a (b):

| Superficie | Qué cambia adicionalmente |
|---|---|
| Unidad de recuperación | Índice por tema de dos niveles ("summary layers", máximo dos, G §2.8): `overviews/` como MOC por dominio con `description` de cada página; `.graph/packets.json` (lista de `packet:` con `description`, tipo, proyecto) que el agente lee antes de buscar; opcionalmente `index.md` reordenado por PARA además de por tipo |
| Favorite problems como filtro | Paso 0.5 de ingest obligatorio con match contra la página; finding `problem_unfed` (problema sin `problems:` entrantes en N días); lint de forma de la página (How/What, ≤ 12, fecha de última revisión); "regla de dos fuentes" para crear conceptos nuevos (G P13) |
| Archivado con decaimiento | **Solo propuesta, nunca movimiento automático** (G §4.1: decay por acceso y confidence numérico rechazados por quienes los probaron; F21). Finding `archive_candidate` = `status: stale` o `superseded` **y** sin backlinks **y** sin citas en `log.md` en N días; el agente lo lista en la revisión mensual; el humano decide. Si se decide mover a `archive/` fuera de `wiki/` (D6 opción ii), stub de redirección en el path viejo para no romper wikilinks |
| heartbeat | Multi-prompt (revisión semanal por día de semana): toca `heartbeat.sh` (workspace-templated) y `heartbeatctl set-prompt`; reabre el "lint agéntico programado" de 014 con argumento de costo de tokens |
| `agent.yml` | Probables claves nuevas (`vault.review.*`, `vault.archive.candidate_days`): heredoc + backfill `has()` + `schema.sh` + `known_external` + docs |

- **Constitución:** I entra en juego (claves nuevas); II intacto salvo que el heartbeat multi-prompt toque `docker/`; IV en tensión si algo "auto-archiva" (por eso solo propuesta); VI intacto mientras no se toque qmd.
- **DOCKER_E2E:** sí, y además gate de hardware en ferrari por escala (2.696 páginas: presupuesto del runner < 60 s en RPi5, SC-006 de 014) y en mclaren por systemd si se agregan units.
- **Riesgo para vaults existentes:** alto. Tercer eje de organización (packets) sobre un índice que ya tiene dos; `problem_unfed` y `archive_candidate` sobre vaults sin `problems:` producen ruido inicial masivo; el heartbeat multi-prompt cambia código workspace-templated que la flota ya corre.
- **Tamaño estimado:** 55-70 tareas. **Recomendación:** no cabe en una feature; partir en 037 = (a)+(b) y 038 = lo de (c) que sobreviva a la medición de uso de (b).

### 4.4 Recomendación entre los tres [I]

**037 = (a) completo + el subconjunto de (b) que no exige heartbeat ni claves nuevas** (kickoff/close, weekly/monthly como operaciones, findings `review_due`/`project_incomplete`/`pending_ingest`, retrieval por protocolo, `status` docker enriquecido). Razones: (1) toda la evidencia externa converge en "PARA como metadatos + review determinista → brief LLM → triage humano" (G P3/P4/P11); (2) nada de eso toca el pin de qmd ni `agent.yml`; (3) deja medible el uso (tasa de filing, packets reutilizados, `review_due` atendidos) antes de invertir en (c), que es exactamente el anti-collector's-fallacy que F §6 pide como criterio de éxito.

---

## 5. Decisiones que debe tomar el operador

Cada decisión es cerrada, con opciones excluyentes, recomendación primero y el porqué anclado en los informes.

**D1. ¿Dónde vive PARA: frontmatter, carpetas o ambos?**
- **(Recomendada) Frontmatter** (`para:` + claves auxiliares) sobre los seis tipos, con vistas derivadas (`index.md` por sección, `.graph`). Porqué: costo cero en el linter hoy (`wiki_graph.sh:202-227`, C §5.1); no rompe wikilinks ni `compute_id`; es lo que hacen PARA-Tree, obsibrain y Forte mismo ("tags tunnel through the walls of siloed folders", F §5.2); ningún sistema del prior art usa PARA como tipo de conocimiento (G §7.1); coherente con "the only six" ratificado en 014 (D §2.1).
- Carpetas PARA paralelas a `wiki/`. Porqué no: fragmenta el wiki, todo `[[...]]` hacia afuera es `broken_link` (`wiki_graph.sh:514`; C §5.4), churn al cambiar prioridades (F §6 Giaro).
- Ambos (carpeta = lifecycle, frontmatter = estado), estilo obsidian-mind. Porqué no ahora: duplica el eje y exige mover páginas archivadas; reconsiderar solo si D6 mide contaminación real.

**D2. ¿La ficha de proyecto vive en el vault o en la auto-memoria?**
- **(Recomendada) En el vault** (`entity` + `para: project`), y `project_<slug>.md` de auto-memoria queda como puntero de 2-3 líneas (estado de una frase + `[[entities/<slug>]]` + fecha de última revisión). Porqué: "don't double-write" (`CLAUDE.md:183`); `MEMORY.md` se trunca a 200 líneas (lo viejo se pierde, no se archiva, C §3.2); el vault tiene grafo, backup y búsqueda; "single-source status: los demás enlazan" (G P15, obsidian-mind: un estado errado se endureció en 8 notas).
- En la auto-memoria (como hoy). Porqué no: sin backlinks, sin qmd, sin backup, sin cola de revisión.
- Requiere: nota de migración para los `project_*` que la flota ya tiene (C §6.9). Sin ella, la decisión no se sostiene.

**D3. ¿Qué cadencia de revisión y quién la dispara?**
- **(Recomendada) Cola determinista + ejecución en sesión**: el runner del grafo (ya cada 6 h en ambos modos) emite `review_due` desde `next_review`; el agente ofrece la revisión al inicio de la próxima conversación; en docker, opcional un prompt de heartbeat vía `heartbeatctl set-prompt` (opt-in del operador, un solo prompt vigente). Cadencia inicial: semanal para proyectos, mensual para áreas, fijada como fechas por el propio agente en cada revisión ("resistance as feedback" ajusta, F14). Porqué: consenso del prior art "el agente prepara, el humano decide" (G P11); local no tiene tick LLM (`claude-md.tpl:92`) y `local_schedule.sh:44-47` no convierte crons semanales — este diseño no necesita ninguno; el lint agéntico programado fue rechazado en 014 por costo (D §7.8) y aquí el LLM corre solo cuando alguien lo pide.
- Heartbeat LLM programado como motor (docker-only). Porqué no como única vía: un prompt para todos los ticks (C §2.4), timeout 300 s, [NV] si carga los MCP `vault`/`qmd` (§7 Q3), y deja local sin nada.
- Manual (el humano pide "hagamos la revisión"). Porqué no sola: es lo que hay hoy y no ocurre; sin cola no hay señal.

**D4. ¿Destilación oportunista o por lotes?**
- **(Recomendada) Oportunista**: `distill` sube solo cuando la página se toca por otra razón (ingest que la actualiza, query que la cita, revisión); L4 (resumen ejecutivo) se escribe al crear el `summary`. Porqué: es la regla literal de Forte (F R16, "only when I'm already reviewing the note anyway"; "Don't apply all layers to all notes"); un pase batch es una reescritura masiva por LLM sin puerta, el anti-patrón más citado del prior art (G §4.2, Moriwaki "modernizó" un hecho histórico); costo de tokens sin evidencia de valor.
- Batch periódico sobre todo el vault. Porqué no: ver arriba; además alarga turnos (cap de typing 5 min, C §6.12).
- Híbrido: batch solo sobre páginas citadas ≥ N veces sin `distill ≥ 2`. Viable en 038 si (b) mide tasas de cita.

**D5. ¿Se agrega un séptimo tipo de página (`project`, `packet`)?**
- **(Recomendada) No.** Porqué: contrato de tres capas — prosa (`CLAUDE.md:45-46`, docs), código (`wiki_graph.sh:111`) y tests (`wiki-graph.bats:33`) — más entrega a `CLAUDE.md` co-evolucionados con ventana de divergencia inevitable (C §6.1); ratificado en 014 clarify Q1 (D §2.1); `entity` ya admite "project" (`CLAUDE.md:39`); nadie en el prior art lo hace (G §7.1).
- Sí, un tipo `project`. Porqué no: todo lo anterior por un beneficio que `para: project` ya da.

**D6. ¿Cómo evitar que Archives contamine el retrieval de qmd?**
- **(Recomendada para 037) Archivo por frontmatter en el mismo archivo + democión por protocolo**, y medir en Fase 0 si el material archivado degrada el top-K (§7 Q2). Porqué: mover páginas rompe wikilinks e `id` de nodo (C §5.4); qmd 2.5.3 no filtra por metadatos (solo `[Unreleased]`, G §2.26); la afirmación "dead material makes every query worse" es cualitativa, nadie la midió (G §6); reversible.
- Carpeta `archive/` fuera de `wiki/` + `ignore: ["archive/**"]` en qmd + stub de redirección en el path viejo. Porqué después: es el patrón second-brain-os (G §2.8) y funciona con el pin, pero exige mover archivos y un mecanismo de redirect que hoy no existe; solo si Q2 mide degradación.
- Colección qmd separada para archivo. Porqué no: no hay forma de asignar un archivo a una colección por metadato; sería por carpeta igual.
- Filtro por `status`/`para` en la query del motor. Porqué no: exige bump de qmd más allá de 2.8.3, y un bump reabre el diseño (tree-sitter en deps duras, D §3; checklist `docs/qmd-upgrade-checklist.md`).

**D7. ¿Alcance docker + local, o docker primero?**
- **(Recomendada) Ambos para skeleton, schema, frontmatter, linter e higiene qmd** (son libs espejadas y prosa: llegan a local por `--regenerate`, a docker por boot); **docker-only, opt-in y documentado, para cualquier ejecución LLM programada**. Porqué: la paridad RAG local↔docker costó 30 gaps en 013 (D §1); las piezas de (a)+(b) no dependen del modo; la única asimetría real (heartbeat) ya está documentada como tal (`claude-md.tpl:92`). Recordar que `--login` local no corre `vault_seed_missing` (B §6.8): el delta llega por `--regenerate`.
- Docker primero, local en 038. Porqué no: duplica gates y deja mclaren/ferrari-admin con schema viejo mientras comparten `docs/vault.md`.

**D8. ¿037 toca qmd (pin/layout) o solo trabaja alrededor?**
- **(Recomendada) Sin bump del pin; sí al layout de la colección dentro de 2.5.3**, tras medir en Fase 0 cuál de las tres formas funciona (raíz `wiki/` / `ignore:` / dos colecciones con `raw` excluida por defecto). Porqué: el gap #1 es el más barato de arreglar y el más citado en el prior art (qmd #975, #645, "gravity wells"); todo está dentro del pin según el CHANGELOG upstream (G §2.26); el pin 2.5.3 es decisión "no reabrir" (D §2.6) y 2.6.x cambia deps nativas.
- Solo alrededor (no tocar la colección). Porqué no: deja el retrieval compitiendo contra plantillas, log y raw duplicado; y cada packet/revisión nueva lo empeora.
- Bump a ≥ 2.8.x por el filtro de metadatos. Porqué no: el filtro ni siquiera está liberado; el bump exige rediseño de 016/017 (D §3).

**D9. ¿El `CLAUDE.md` del vault se actualiza por delta (el agente integra) o por reemplazo opt-in?**
- **(Recomendada) Delta**, como 014 (`schema-updates-0.27.0.md` + marcador oculto + línea en `log.md`), **más un finding determinista `schema_delta_pending`** que delate un delta depositado hace > N días cuya integración no se refleja (p. ej. `CLAUDE.md` del vault sin la cadena `para:`). Porqué: append directo y reemplazo fueron rechazados en 014 R7 (capa co-evolucionada, D §2.1); el hueco "petición al agente sin verificación" está identificado (C §6.13) y un finding lo cierra sin tocar el archivo.
- Reemplazo opt-in (`--force-claude-md` para el vault). Porqué no: destruye la co-evolución; el único camino a pristine ya existe y es `force_reseed` (mueve todo a backup).
- Delta sin finding. Porqué no: 037 sería el delta más grande y el más fácil de dejar a medias.

**D10. ¿Dónde viven los favorite problems?**
- **(Recomendada) Una página del vault** (`wiki/synthesis/favorite-problems.md`, `status: active`), autoría humana, citada desde el paso 0.5 de ingest; `problems: []` en las páginas que aportan. Porqué: es la meta-página por excelencia (`CLAUDE.md:43`); entra al grafo y al backup; Forte la guarda como "una nota" (F §2.8); no cabe en `normalization/` (no es conocimiento citable, C §6.3) ni en `agent.yml` (no es config del launcher).
- En `MEMORY.md` de auto-memoria. Porqué no: se trunca, no tiene backlinks ni backup por fork.
- En `agent.yml` (`vault.favorite_problems: []`). Porqué no: mezcla contenido del usuario con config del sistema y exige schema/tests por algo que cambia con los intereses.

**D11. ¿Cómo se marcan los intermediate packets?**
- **(Recomendada) `packet:` tipado sobre el tipo natural de cada página** (concept/comparison/synthesis según corresponda) + sección `## Packets` en `index.md`. Porqué: sin tipo ni directorio nuevo (D5); evita que `synthesis` deje de ser raro (C §6.8); la tipología de 5 (`distilled-note|outtake|wip|deliverable|external`) es del libro [SEC], útil como enum cerrado.
- Directorio `wiki/packets/` con `type: synthesis`. Porqué no: `compute_id` lo acepta, pero concentra todo en synthesis y rompe "one topic per file" para los `wip`.
- Sin marca (seguir con "file back as overview/synthesis"). Porqué no: no se puede pedir "dame el checklist de X" ni medir reutilización.

**D12. ¿`para` es obligatorio o ausente = resource?**
- **(Recomendada) Ausente = `resource`, sin violación; violación solo con valor inválido.** Porqué: población perezosa ("as little as possible, as late as possible", F §2.11; "never pre-create", S3); ningún vault existente cambia; el skeleton limpio sigue dando exactamente 0 findings (`wiki-graph.bats:98`).
- Obligatorio en toda página. Porqué no: genera cientos de `frontmatter_violation` en la flota el día uno y obliga a una migración masiva que 014 declaró fuera de alcance (D §2.1).

Nota sobre las cuatro claves muertas de `agent.yml` (gap #11): no es decisión de 037 salvo que se agreguen claves nuevas bajo `vault:`; si se agregan, decidir primero reciclar/reservar/retirar para no acumular una quinta.

---

## 6. Riesgos y cosas que NO conviene hacer

Con la evidencia de las decisiones rechazadas (D) y las críticas (F, G):

1. **No proponer un séptimo `type` ni valores nuevos de `status`** (`archived`, `done`, `on-hold`). `status` tiene semántica de frescura: el finding `stale` solo mira `active` (`wiki_graph.sh:439`) y el query prioriza `active` (`CLAUDE.md:119`); reusar `superseded` para "proyecto cerrado" corrompe ambos (C §6.2). D §2.1, §7.1.
2. **No dejar que ningún script edite `wiki/`, `raw_sources/` o el `CLAUDE.md` del vault.** 014 FR-005 y R7 (D §2.1). Todo lo de 037 que "hace" es prosa para el agente o findings para el runner.
3. **No archivar, mover ni destilar automáticamente.** Todo el prior art con producción real pone una puerta humana a las reescrituras (G P20: "proposal → diff → aprobación"; "letting models write on hooks corrupts it silently"). Astro-Han desmontó decay por acceso y confidence numérico tras tres meses ("frequently asked is not the same as true", G §4.1). Forte reserva "qué es importante" al humano (F21).
4. **No usar decay numérico ni scores de confianza.** Preferir la política de frescura por forma del hecho (timeless / fechado / puntero) y `stale_after` absoluto (G P9/P10). El `stale` actual (mtime fuente > `updated`+1 d) es compatible.
5. **No crear carpetas PARA paralelas a `wiki/`** ni tags que repliquen carpetas (F16, P9): rompe wikilinks (`:514`), duplica el eje, provoca churn.
6. **No poner favorite problems, checklists ni estándares de área en `normalization/`**: quedan fuera del grafo, no citables (`wiki_graph.sh:185`; `CLAUDE.md:54`; C §6.3).
7. **No escribir un archivo por revisión semanal** (`review-YYYY-MM-DD.md`): entra al índice qmd y al hash de backup (C §6.7), invierte la señal de recencia si se edita (G P17), y `synthesis` deja de ser raro. Las revisiones van a `log.md`; solo el brief mensual/trimestral merece página, y como `synthesis` con la excepción de nombres fechados ya prevista (`CLAUDE.md:200`).
8. **No escribir `.md` bajo `.graph/`** ni derivados fuera de JSON atómico (invariante L1, `wiki-graph.bats:142`; D §2.1).
9. **No agregar claves a `agent.yml` sin el trío** heredoc + backfill `has()` (nunca `//` para booleanos) + `schema.sh` + `known_external` en `schema.bats` (B §2.1); y **no agregar prompt de wizard** salvo necesidad real (tres touchpoints: `wizard_answers`, `e2e-smoke.bats`, `schema.bats`; memoria `wizard-prompt-test-touchpoints`).
10. **No bumpear qmd** ni parchear su dist (D §2.2, §2.5; `docs/qmd-upgrade-checklist.md`). Los dos guardrails (`qmd-version-guard.bats`, `qmd-sqlite-vec.bats`) existen para forzar revisión humana.
11. **No re-litigar el skill `/vault:*`** sin mostrar la fricción que `docs/vault.md:542` exige como condición (D §2.1).
12. **No migrar vaults existentes en big-bang** (el "60-second setup" de Forte de archivar todo con fecha [SEC] contradice "0 archivos preexistentes modificados" de 014 SC-005). `para` ausente = resource; la estructura crece por uso.
13. **No confiar en `--login` local para entregar el delta** (drift verificado, B §6.8): es `--regenerate`. Y **no asumir que el `CLAUDE.md` del workspace se refresca**: nuevas secciones en `claude-md.tpl` no llegan a agentes existentes sin `--force-claude-md` (B §2.2). El canal correcto para instruir al agente sobre el vault es el `CLAUDE.md` del vault + delta.
14. **No hacer que el heartbeat corra pases pesados**: timeout 300 s por defecto, un solo prompt, plugins deshabilitados, y el indicador de typing del canal se corta a los 5 min con aviso al chat (C §6.12). Si se usa, que sea para "¿hay `review_due`? avisa", no para ejecutar la revisión.
15. **No listar todo en una revisión**: "three recommendations, not ten" (second-brain-os, G §4.12); la primera versión LLM de Mandalivia fue "slow, token-heavy, inconsistent" hasta que la extracción pasó a script (G §2.12).
16. **No dejar que el agente afirme "resonancia"**: un LLM no resuena; si dice que sí, miente (F §4.2). Todo criterio de captura inferido se etiqueta "candidato".
17. **No medir el éxito por volumen** (páginas, packets, findings): collector's fallacy (F §6, P1/P8). Medir uso: tasa de filing, packets reutilizados en kickoff, `review_due` atendidos, páginas citadas en respuestas.
18. **No mergear con el gate de hardware diferido** si un SC depende de escala (2.696 páginas en ferrari), Syncthing o systemd (mclaren): 013/014/016 lo difirieron y costaron 015/017/018 (D §5.2); 024 fijó el precedente de correrlo antes.
19. **No duplicar el estado del proyecto** entre ficha del vault y `project_*` de auto-memoria: el puntero no lleva estado, solo referencia y fecha (C §3.3; G P15).
20. **Riesgo de ventana de divergencia** al desplegar: imagen nueva (linter valida `para`) con schema viejo en el agente, o al revés. Fijar el orden (rebuild → boot deposita el delta → agente integra) y declarar que en el intervalo los findings nuevos son esperados (C §6.1).

---

## 7. Preguntas abiertas que necesitan medición antes de decidir (Fase 0 del plan)

Cada una con qué se mide, dónde y qué decisión desbloquea. Ninguna imprime contenido de vaults ni secretos.

| # | Pregunta | Cómo medir | Desbloquea |
|---|---|---|---|
| Q1 | ¿Qué superficie de exclusión tiene realmente `qmd` **2.5.3** en el contenedor? (`collection include|exclude`, campo `ignore:` en el archivo de colecciones bajo `QMD_CONFIG_DIR` — ruta y formato exactos —, si `qmd update` purga documentos ya indexados al agregar `ignore:`, si el tool MCP acepta un parámetro de colección, si el glob omite dotfiles) | Imagen `agentic-pod:latest` + fixture de vault sintético; `qmd --help`, inspección del YAML de colecciones, `qmd update` antes/después. G §2.26 verificó el CHANGELOG upstream, no el binario (A §2 lo marca [NV]) | D8 (forma del layout), D6 |
| Q2 | ¿Cuánto degrada el retrieval indexar `_templates/`, `index.md`, `log.md`, `raw_sources/` y páginas archivadas? | Set de 20-30 preguntas sonda con respuesta conocida sobre una **copia** del vault de un agente de la flota (o el fixture `vault-graph` inflado); top-5 hit rate con y sin exclusiones; repetir marcando N páginas `para: archive`. Nadie lo midió (G §6, "lo que nadie midió") | D6, D8, y el SC principal de higiene |
| Q3 | ¿La sesión del heartbeat (plugins deshabilitados, `cwd=/workspace`, `.claude.json` compartido) carga los MCP de proyecto `vault` y `qmd`? | `heartbeatctl test --prompt "lista tus tools MCP"` en un agente docker de prueba; leer el log de sesión | D3 (si el heartbeat sirve como ejecutor opcional) |
| Q4 | ¿Cuánto dura un turno de kickoff, close o weekly review sobre un vault real, contra `HEARTBEAT_TIMEOUT` (300 s) y el cap de typing (5 min)? | Cronometrar 3-5 turnos en linus (vault chico) con las operaciones prototipadas en prosa; leer `telegram-mcp-stderr.log` | D3, D4; si hay que subir `TELEGRAM_TYPING_MAX_MS` en la doc |
| Q5 | Estado real de los vaults de la flota: número de páginas por tipo, ¿integraron el delta 0.8.0 en su `CLAUDE.md`? (buscar la cadena "normalization" y la sección de query 1.5), ¿cuántos `project_*` hay en cada `MEMORY.md`? | Conteos por `docker exec -u agent` / ssh, sin imprimir contenido | D2 (tamaño de la migración de `project_*`), D9 (justifica el finding `schema_delta_pending`), tamaño del delta |
| Q6 | Costo del runner del grafo con los findings nuevos sobre 2.696 páginas | Correr `wiki_graph_run` con la lib modificada sobre una copia en ferrari (RPi5); presupuesto heredado < 60 s (014 SC-006) | Viabilidad de `pending_ingest`/`review_due` en el mismo runner sin cron aparte |
| Q7 | ¿`vault_seed_missing` con un segundo bloque se comporta bien en los tres estados posibles: vault pre-014 (fixture `vault-populated`), vault 0.8.0-completo con wiki vacía, vault 0.8.0 con páginas? B §3 dejó una [INFERENCIA] sobre la variable `changed` compartida | Test bats con fixture nueva (la actual es pre-014, B §6.6) | Diseño del bloque 0.27.0 y su marcador |
| Q8 | ¿`inotify-tools` de Alpine 3.24 soporta excluir `.graph/` (`@dir` o `--exclude`)? | `inotifywait --help` en el contenedor | Gap #7 (tick vacío por corrida del grafo) |
| Q9 | ¿`qmd update` re-indexa una página cuyo único cambio es de frontmatter (`para:` nuevo)? El hash bash (`vault_hash`) sí cambia; el hash interno de qmd es [NV] (anti-patrón G §4.14) | Editar solo frontmatter de una página en el fixture, `qmd update`, consultar por el valor nuevo | Si los cambios PARA llegan al índice sin `force` |
| Q10 | ¿Index-first reduce llamadas y latencia en vaults del tamaño de la flota? (Ar9av reporta 9,9 → 4,6 tool calls y 81 → 19 s en 38 páginas, auto-reportado) | 10 preguntas sonda en linus, protocolo actual vs protocolo con paso 0; contar tool calls y tiempo | Redacción del SC de navegación (estilo D §4.2: "cero" y latencias con dos cotas) |
| Q11 | El único artículo que promete PARA + LLM Wiki (Pilevar, "Second Brain X") no pudo leerse (Cloudflare, G §2.22) | Otra vía de acceso; si no, declararlo sin leer en la spec | Confirma o refuta que nadie modela PARA como tipo |
| Q12 | ¿La colección de raw excluida por defecto sigue siendo consultable desde el agente cuando la pregunta exige el texto crudo? (depende de Q1: parámetro de colección en el tool MCP o solo por CLI desde el prefijo gestionado, nunca `bunx`) | Prueba en contenedor con dos colecciones | D8 forma "dos colecciones" vs "raíz `wiki/`" |

Medición previa que **no** hace falta: soporte de día de semana en `local_schedule.sh` — si D3 se resuelve con `next_review` en el runner existente, no se agrega ningún cron y esa restricción queda documentada, no arreglada.

---

## Anexo — Criterios de éxito sugeridos para la spec (estilo de la cadena 010-019, D §4.2)

Propuestas [I] para que `/speckit-specify` arranque con oráculos medibles:

- **SC-higiene:** con las exclusiones activas, cero documentos de `_templates/`, `index.md`, `log.md` o `CLAUDE.md` en el top-10 de las preguntas sonda de Q2; con `raw` fuera del default, cero duplicados raw/summary en el top-10 (oráculo #645).
- **SC-aditividad:** el segundo delta modifica **0 archivos preexistentes** (hash antes/después) sobre las tres fixtures de Q7 y es idempotente en segunda pasada; el skeleton limpio sigue dando **exactamente 0** findings.
- **SC-linter:** sobre la fixture `vault-graph` extendida, `para` inválido, `project_incomplete`, `review_due` y `pending_ingest` con **0 falsos positivos y 0 falsos negativos**; los seis findings previos byte-idénticos.
- **SC-navegación:** en 10 preguntas sonda, el protocolo index-first reduce las tool calls respecto al actual (cota a fijar tras Q10).
- **SC-uso (anti collector's fallacy):** tras 4 semanas en linus, ≥ 1 `review_due` atendido por semana, tasa de filing registrada en `log.md`, ≥ 1 packet reutilizado en un kickoff. Se mide, no se promete.
- **SC-paridad:** docker byte-idéntico fuera de las libs espejadas (diff vacío); suite `bats tests/` 0 `not ok` en bash 3.2 y 5.x; `shellcheck -S error` rc 0; DOCKER_E2E verde; gate de hardware en ferrari (Q6) **antes** del merge.

