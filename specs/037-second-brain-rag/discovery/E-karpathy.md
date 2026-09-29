# Informe E — El patrón "LLM Wiki" de Karpathy: fuente primaria vs. implementación del repo

**Feature**: 037 (discovery) · **Fecha**: 22-09-2026 · **Repo**: `agentic-pod-launcher` en `main` (VERSION 0.26.0, `70214d9`) · **Modo**: solo lectura del repo; nada modificado.

Convenciones de este informe:

- **[HV]** hecho verificado: leí el archivo/URL o ejecuté el comando que se cita.
- **[INF]** inferencia razonable a partir de hechos verificados.
- **[NV]** no pude verificarlo; se declara el vacío en vez de taparlo.

---

## 0. Resumen ejecutivo

- **[HV]** Existen DOS fuentes primarias, no una: el post en X del 02-04-2026 (`x.com/karpathy/status/2039805659525644595`, fecha decodificada del Snowflake ID = 2026-04-02 20:42:21 UTC) y el gist `llm-wiki.md` publicado dos días después (04-04-2026, una sola revisión, sha `ac46de1a…`). El gist es el "idea file" abstracto; el post describe el workflow real de Karpathy y trae elementos que el gist NO tiene (formatos de salida Marp/matplotlib, "impute missing data with web searches", finetuning como exploración futura, "room for an incredible new product").
- **[HV]** Karpathy no ha publicado follow-ups propios sobre el patrón: 0 de 1.123 comentarios del gist son suyos, el gist tiene 1 revisión, y no encontré replies suyas verificables en el hilo. Su único texto previo afín es "The append-and-review note" (19-03-2025), que rechaza explícitamente carpetas, tags y metadatos estructurados.
- **[HV]** Lo que Karpathy dice de RAG es preciso y acotado: el problema del RAG clásico es que "there's no accumulation", no que recupere mal. La búsqueda es secundaria: "at small scale the index file is enough"; a ~100 fuentes / ~400K palabras "the LLM reads all the important related data fairly easily"; qmd entra "as the wiki grows". Nunca menciona "grep" como estrategia de búsqueda (solo para parsear `log.md`) ni la búsqueda de Obsidian.
- **[INF]** Por lo tanto, en este paradigma "mejorar el RAG" NO es mejorar el retriever (eso el repo ya lo cubre con QMD BM25+vector+rerank, exactamente la herramienta que el gist nombra). Es mejorar la **compilación** (calidad y densidad del wiki, filing de respuestas, lint semántico con imputación de vacíos) y la **navegación** (index-first, grafo). El retriever es el último recurso, no el primero.
- **[HV]** Cobertura: de 22 elementos del gist+post, el repo implementa 12 completos (las 3 capas, 6 tipos, schema co-evolucionado con mecanismo de upgrade aditivo, ingest, `index.md`, `log.md` parseable, qmd, lint estructural determinista + semántico agéntico, normalización que el gist no pide), 7 parciales y 3 ausentes.
- **[HV]** Brecha más barata y más alineada con la fuente: el protocolo de **query del repo no lee `index.md` primero** (`vault-skeleton/CLAUDE.md:118-119` va a `search_notes`/`Glob`/`Grep`), mientras el gist dice "the LLM reads the index first to find relevant pages, then drills into them". El repo mantiene el índice y detecta su drift, pero no lo usa como punto de entrada.
- **[HV]** Ausentes en el repo y presentes en la fuente: (a) "data gaps that could be filled with a web search" + "suggesting new questions to investigate and new sources" en el lint; (b) formatos de salida distintos de markdown (Marp, matplotlib, canvas); (c) el paso de ingest "discusses key takeaways with you" antes de escribir; (d) manejo de imágenes en el protocolo (leer texto, luego ver imágenes); (e) uso del historial git del wiki por el LLM (el vault no es repo git; `backup/vault` vive en un clon de caché).
- **[HV]** `vault.initial_sources: []` se escribe en `agent.yml` (`setup.sh:1287`) y aparece en `schema.bats`, pero ningún consumidor lo lee (grep en `setup.sh`, `scripts/lib/`, `docker/scripts/`, `modules/`). Es un campo inerte — candidato natural para el "batch-ingest" que el gist menciona.
- **[HV]** PARA / Second Brain / Tiago Forte / revisión semanal / progressive summarization: **cero menciones** en el gist y en el post. Un comentarista (MironV, 04-04-2026) llamó al patrón "a much cleaner, more flexible version of the 'Second Brain' concept"; es un comentario, no Karpathy. El único "review" periódico de Karpathy (append-and-review note) es de una sola nota sin estructura: lo contrario de PARA.
- **[INF]** El gist se autodeclara "intentionally abstract… everything mentioned above is optional and modular". Superponer PARA/CODE es una extensión legítima del patrón, pero no sale de la fuente; hay que presentarla como decisión propia de 037, no como fidelidad a Karpathy.

---

## 1. Fuentes primarias localizadas y estado de verificación

### 1.1 Post en X (el origen)

| Dato | Valor | Estado |
|---|---|---|
| URL | https://x.com/karpathy/status/2039805659525644595 | [HV] localizada por búsqueda; x.com no es fetcheable directo |
| Fecha | **2026-04-02 20:42:21 UTC** | [HV] decodificada del Snowflake ID (`(id >> 22) + 1288834974657`), cruzada con `created_at` de fxtwitter |
| Texto | completo, verbatim | [HV] vía `api.fxtwitter.com` (espejo de terceros de la API pública); se reproduce íntegro en el Anexo A |
| Métricas al 22-09-2026 | 21.916.158 vistas, 60.981 likes, 108.614 bookmarks | [HV] según fxtwitter; cifra de terceros |
| Título del post | "LLM Knowledge Bases" | [HV] |
| Replies de Karpathy en el hilo | no localizadas | [NV] fxtwitter devuelve solo el post raíz; búsquedas no arrojaron ninguna |

Nota: fuentes secundarias dan "2 de abril", "3 de abril" y "Easter weekend" indistintamente. La fecha decodificada del ID es 2 de abril (UTC); en hora de Chile sigue siendo 2 de abril.

### 1.2 Gist `llm-wiki.md`

| Dato | Valor | Estado |
|---|---|---|
| URL | https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f | [HV] |
| Raw (revisión única) | https://gist.githubusercontent.com/karpathy/442a6bf555914893e9891c11519de94f/raw/ac46de1ad27f92b28ac95459c782c07f6b8c964a/llm-wiki.md | [HV] texto completo leído |
| Creación | 04-04-2026 16:25 (hora mostrada por GitHub en `/revisions`); primer comentario a las 16:49:23Z | [HV] página de revisiones + `gh api --paginate .../comments` |
| Revisiones | **1** (creación, 75 líneas) | [HV] página `/revisions`; la API `gists/{id}` respondió HTTP 502 dos veces, así que el `committed_at` exacto no lo obtuve [NV] |
| Comentarios | **1.123** entre 2026-04-04T16:49:23Z y 2026-09-22T16:50:57Z | [HV] `gh api --paginate` |
| Comentarios de `karpathy` | **0** | [HV] filtro por `user.login` en las 1.123 filas |
| Stars/forks | "5,000+" | [NV] cifra del resumen del fetch HTML, no confirmada por API |

### 1.3 Follow-ups del propio Karpathy

- **[HV]** "The append-and-review note", https://karpathy.bearblog.dev/the-append-and-review-note/, 19-03-2025. Precursor, no follow-up. Citado por un comentarista del gist (expectfun, 2026-04-04T17:09:29Z). Relevante para la sección 6.
- **[NV]** Índice del blog de Karpathy: la página raíz no lista posts (solo cabecera y RSS); no pude confirmar si existe un post posterior sobre el wiki. Las búsquedas de "follow-up May/June/July 2026" solo devolvieron artículos de terceros.
- **[HV]** El gist no fue editado después de su creación; los conceptos "the wiki compounds", "filing answers back", "schema co-evolution", "index/log", "lint" están todos en la revisión única (o en el post), no en follow-ups.

### 1.4 Lo que NO pude verificar

- Replies de Karpathy dentro del hilo de X (herramienta sin acceso al hilo).
- `committed_at` exacto del gist vía API (502).
- Si Karpathy comentó en otros foros (HN, Reddit) sobre el patrón: no buscado en profundidad; fuera de alcance.

---

## 2. El patrón según Karpathy, sección por sección

Citas cortas, verbatim, del gist (raw sha `ac46de1a`) salvo donde se indica "post". Todas [HV].

### 2.1 Encabezado — qué es el documento

> "This is an idea file, it is designed to be copy pasted to your own LLM Agent (e.g. OpenAI Codex, Claude Code, OpenCode / Pi, or etc.). Its goal is to communicate the high level idea, but your agent will build out the specifics in collaboration with you."

### 2.2 The core idea

> "Most people's experience with LLMs and documents looks like RAG: you upload a collection of files, the LLM retrieves relevant chunks at query time, and generates an answer. This works, but the LLM is rediscovering knowledge from scratch on every question. There's no accumulation."

> "Instead of just retrieving from raw documents at query time, the LLM **incrementally builds and maintains a persistent wiki** — a structured, interlinked collection of markdown files that sits between you and the raw sources."

> "**the wiki is a persistent, compounding artifact.** The cross-references are already there. The contradictions have already been flagged. The synthesis already reflects everything you've read."

> "You never (or rarely) write the wiki yourself — the LLM writes and maintains all of it. You're in charge of sourcing, exploration, and asking the right questions."

> "Obsidian is the IDE; the LLM is the programmer; the wiki is the codebase."

Contextos de aplicación listados: Personal (goals, health, psychology, journal entries), Research (thesis que evoluciona), Reading a book (fan wiki tipo Tolkien Gateway), Business/team ("fed by Slack threads, meeting transcripts… Possibly with humans in the loop reviewing updates"), Competitive analysis / due diligence / trip planning / course notes / hobby.

### 2.3 Architecture — tres capas

> "**Raw sources** — … These are immutable — the LLM reads from them but never modifies them. This is your source of truth."

> "**The wiki** — a directory of LLM-generated markdown files. Summaries, entity pages, concept pages, comparisons, an overview, a synthesis. The LLM owns this layer entirely."

> "**The schema** — a document (e.g. CLAUDE.md for Claude Code or AGENTS.md for Codex)… This is the key configuration file — it's what makes the LLM a disciplined wiki maintainer rather than a generic chatbot. You and the LLM co-evolve this over time as you figure out what works for your domain."

Observación [HV]: la lista de tipos de página es una enumeración de ejemplos ("Summaries, entity pages, concept pages, comparisons, an overview, a synthesis"), no un conjunto cerrado. El repo la convirtió en "the only six" (`vault-skeleton/CLAUDE.md:32-46`). Ver §4.

### 2.4 Operations

**Ingest**:
> "the LLM reads the source, discusses key takeaways with you, writes a summary page in the wiki, updates the index, updates relevant entity and concept pages across the wiki, and appends an entry to the log. A single source might touch 10-15 wiki pages. Personally I prefer to ingest sources one at a time and stay involved… But you could also batch-ingest many sources at once with less supervision. It's up to you to develop the workflow that fits your style and document it in the schema for future sessions."

**Query**:
> "The LLM searches for relevant pages, reads them, and synthesizes an answer with citations. Answers can take different forms depending on the question — a markdown page, a comparison table, a slide deck (Marp), a chart (matplotlib), a canvas. The important insight: **good answers can be filed back into the wiki as new pages.**… This way your explorations compound in the knowledge base just like ingested sources do."

Post (más fuerte que el gist): "Often, I end up 'filing' the outputs back into the wiki to enhance it for further queries. So my own explorations and queries always 'add up' in the knowledge base."

**Lint**:
> "Look for: contradictions between pages, stale claims that newer sources have superseded, orphan pages with no inbound links, important concepts mentioned but lacking their own page, missing cross-references, data gaps that could be filled with a web search. The LLM is good at suggesting new questions to investigate and new sources to look for."

Post: "find inconsistent data, impute missing data (with web searchers), find interesting connections for new article candidates".

### 2.5 Indexing and logging

> "**index.md** is content-oriented. It's a catalog of everything in the wiki — each page listed with a link, a one-line summary, and optionally metadata like date or source count. Organized by category… The LLM updates it on every ingest. **When answering a query, the LLM reads the index first to find relevant pages, then drills into them.** This works surprisingly well at moderate scale (~100 sources, ~hundreds of pages) and avoids the need for embedding-based RAG infrastructure."

> "**log.md** is chronological. It's an append-only record… if each entry starts with a consistent prefix (e.g. `## [2026-04-02] ingest | Article Title`), the log becomes parseable with simple unix tools — `grep "^## \[" log.md | tail -5`… helps the LLM understand what's been done recently."

### 2.6 Optional: CLI tools

> "A search engine over the wiki pages is the most obvious one — at small scale the index file is enough, but as the wiki grows you want proper search. qmd is a good option: … hybrid BM25/vector search and LLM re-ranking, all on-device. It has both a CLI (so the LLM can shell out to it) and an MCP server (so the LLM can use it as a native tool). You could also build something simpler yourself".

### 2.7 Tips and tricks

Obsidian Web Clipper; "Download images locally… Note that LLMs can't natively read markdown with inline images in one pass — the workaround is to have the LLM read the text first, then view some or all of the referenced images separately"; Obsidian graph view ("which pages are hubs, which are orphans"); Marp; Dataview ("If your LLM adds YAML frontmatter to wiki pages (tags, dates, source counts)"); "The wiki is just a git repo of markdown files. You get version history, branching, and collaboration for free."

### 2.8 Why this works

> "The tedious part of maintaining a knowledge base is not the reading or the thinking — it's the bookkeeping… Humans abandon wikis because the maintenance burden grows faster than the value. LLMs don't get bored, don't forget to update a cross-reference, and can touch 15 files in one pass."

> "The human's job is to curate sources, direct the analysis, ask good questions, and think about what it all means. The LLM's job is everything else."

Referencia a Vannevar Bush / Memex (1945): "The part he couldn't solve was who does the maintenance. The LLM handles that."

### 2.9 Note (licencia de adaptación)

> "This document is intentionally abstract… Everything mentioned above is optional and modular — pick what's useful, ignore what isn't."

### 2.10 Solo en el post (no en el gist)

- "Output: … render markdown files for me, or slide shows (Marp format), or matplotlib images, all of which I then view again in Obsidian."
- "Extra tools: … I vibe coded a small and naive search engine over the wiki, which I both use directly (in a web ui), but more often I want to hand it off to an LLM via CLI".
- "Further explorations: … synthetic data generation + finetuning to have your LLM 'know' the data in its weights instead of just context windows."
- "I think there is room here for an incredible new product instead of a hacky collection of scripts."
- Escala concreta: "mine on some recent research is ~100 articles and ~400K words".

---

## 3. RAG tradicional vs. wiki compilada, y qué dice de búsqueda

### 3.1 Qué dice exactamente [HV]

| Tema | Cita | Fuente |
|---|---|---|
| Crítica al RAG | "the LLM is rediscovering knowledge from scratch on every question. There's no accumulation." | gist, core idea |
| Qué reemplaza al RAG | "the LLM incrementally builds and maintains a persistent wiki… The knowledge is compiled once and then kept current, not re-derived on every query." | gist |
| Búsqueda a escala pequeña | "I thought I had to reach for fancy RAG, but the LLM has been pretty good about auto-maintaining index files and brief summaries of all the documents and it reads all the important related data fairly easily at this ~small scale." | post |
| Punto de entrada | "the LLM reads the index first to find relevant pages, then drills into them." | gist |
| Umbral | "~100 sources, ~hundreds of pages… avoids the need for embedding-based RAG infrastructure." | gist |
| Cuándo sí hay buscador | "at small scale the index file is enough, but as the wiki grows you want proper search." | gist |
| Qué buscador | qmd (BM25/vector + rerank), CLI + MCP; o "a naive search script". | gist + post |

### 3.2 Qué NO dice (relevante para no atribuirle cosas) [HV]

- **"grep"** aparece UNA vez en el gist y es para parsear `log.md` (`grep "^## \[" log.md | tail -5`). No propone grep como estrategia de recuperación.
- **La búsqueda de Obsidian** no se menciona ni en el gist ni en el post. Obsidian es "IDE/frontend" para el humano: graph view, Web Clipper, Marp, Dataview.
- No dice que el RAG sea inexacto o de baja calidad; su objeción es estructural (sin acumulación), no de precisión de recuperación.
- No dice "nunca uses embeddings"; dice que a escala moderada no hacen falta y que a escala mayor qmd es buena opción.

### 3.3 Qué significa "mejorar el RAG" en este paradigma [INF]

Dado lo anterior, hay cuatro palancas ordenadas por fidelidad a la fuente:

1. **Compilación**: que cada ingest deje el wiki más denso y consistente (páginas de entidad/concepto actualizadas, contradicciones marcadas). El repo la cubre (§4, filas 7 y 9).
2. **Filing de respuestas**: que las consultas también compilen. El repo lo hace en modo "proponer y preguntar"; Karpathy lo hace "often".
3. **Navegación**: index-first + grafo. El repo tiene el grafo (014) pero no el index-first.
4. **Retriever**: qmd. El repo lo tiene, con ciclo de vida gestionado que el gist ni imagina (016-018).

La palanca 4 ya está saturada en el repo. Las 1-3 son donde la fuente pone el valor.

---

## 4. Tabla de cobertura: cada elemento de la fuente → repo

Leyenda: **Impl** = implementado; **Parcial**; **Ausente**. Todas las referencias al repo son [HV] (archivo:línea leído en esta sesión).

| # | Elemento (gist/post) | Estado | Dónde en el repo / evidencia | Observación |
|---|---|---|---|---|
| 1 | Idea central: wiki persistente que compone, en vez de RAG a tiempo de consulta | Impl | `modules/vault-skeleton/CLAUDE.md:3-7, 24-30`; `docs/vault.md:1-6`; `README.md:212` | El repo además superpone qmd (retriever). Compatible: el gist lo nombra como herramienta opcional. |
| 2 | Roles: humano cura/pregunta, LLM hace el bookkeeping | Impl | `CLAUDE.md:6-7` ("The human curates sources and asks questions; you do the bookkeeping") | Verbatim en espíritu. |
| 3 | "Obsidian is the IDE": co-navegación en tiempo real | Parcial | `docs/vault.md:527-540` (abrir el vault en Obsidian, opcional); Syncthing en memoria del proyecto | Agente headless: el operador ve por Telegram, no por Obsidian en vivo. Es una diferencia de modelo de uso, no un defecto. |
| 4 | Capa 1: `raw_sources/` inmutable | Impl | `CLAUDE.md:26`; `raw_sources/README.md` completo; `_templates/source.md` | El repo agrega frontmatter para fuentes y subdirectorios por tipo; el gist no lo pide. |
| 5 | Capa 2: wiki con summaries/entities/concepts/comparisons/overview/synthesis | Impl (más estricto) | `CLAUDE.md:32-46` ("the only six"), directorios en `wiki/`, `_templates/*.md` | El gist enumera ejemplos; el repo cierra el conjunto y exige `type:` en frontmatter. Ventaja: lint determinista. Costo: rigidez para tipos nuevos (p. ej. un tipo "project"). |
| 6 | Capa 3: schema co-evolucionado | Impl | `CLAUDE.md:28`; upgrade aditivo que NUNCA toca el `CLAUDE.md` del vault (`docs/vault.md:139-141, 255-258`); `modules/vault-deltas/schema-updates-0.8.0.md` (propone cambios al agente en vez de sobrescribir) | Mecanismo más elaborado que el gist. |
| 7 | Ingest: leer → resumen → index → entidades/conceptos → log; 10-15 páginas | Impl | `CLAUDE.md:87-112` (pasos 0-6); `docs/vault.md:179-191` | Falta el sub-paso "discusses key takeaways with you" (grep `discuss|takeaway` en el skeleton: 0 hits). El repo agrega ack de chat (paso 0) y normalización (2.5). |
| 8 | Ingest uno a uno vs. batch, documentado en el schema | Parcial | `CLAUDE.md` no distingue modos; `vault.initial_sources: []` existe en `setup.sh:1287`, `docs/vault.md:108`, `tests/schema.bats:43` pero sin consumidor | Campo inerte; es el hueco natural para batch-ingest. |
| 9 | Query: buscar → leer → sintetizar con citas | Impl | `CLAUDE.md:114-130` | "Read the relevant pages end-to-end. Don't quote chunks out of context" (`:126`) es exactamente el anti-chunking de Karpathy. |
| 10 | Query: **leer `index.md` primero** | Ausente | `CLAUDE.md:118-119` manda a `search_notes`/`Glob`/`Grep`; `:120-125` al grafo; `index.md` no aparece en el protocolo de query (grep `index.md` en `CLAUDE.md`: líneas 30, 109, 142, 194 — ninguna en query) | Divergencia directa con el gist. El índice se mantiene (`index.md` skeleton) y se lintea (`wiki_graph.sh:542-543` `index_drift`) pero no se consulta. |
| 11 | Query: formatos de salida (tabla, Marp, matplotlib, canvas) | Ausente | grep `marp|dataview|matplotlib` en skeleton y `docs/vault.md`: solo Dataview en `docs/vault.md:536` para humanos | El canal Telegram admite archivos/fotos; nada lo explota. |
| 12 | Query: **filing de respuestas al wiki** | Parcial | `CLAUDE.md:131-133` ("propose… Don't auto-create — ask the human first") | Más conservador que Karpathy ("often, I end up filing"). No hay métrica de cuántas respuestas se archivan. |
| 13 | Lint: contradicciones, stale, huérfanos, conceptos sin página, cross-refs | Impl | Semántico: `CLAUDE.md:150-160`; estructural determinista: `scripts/lib/wiki_graph.sh:8-9, 539-545` (orphan, broken_link, frontmatter_violation, index_drift, stale, alias_occurrence) | Va más allá del gist: separa lo determinizable (script, cron `20 */6 * * *`) de lo semántico (LLM). |
| 14 | Lint: **data gaps con web search** y **sugerir nuevas preguntas/fuentes** | Ausente | grep `data gap|web search` en skeleton y docs: 0 hits | La parte "generativa" del lint no existe; el repo lo trata como control de calidad, no como agenda de investigación. |
| 15 | Lint periódico (cadencia) | Parcial | Determinista: sí, programado. Semántico: solo on-demand; `CLAUDE.md:185-192` sugiere "once a month"; `specs/014-wiki-graph-rag/research.md` R1 difirió el lint agéntico programado "por costo de tokens… queda en backlog". El heartbeat docker tiene prompt configurable (`modules/heartbeat-conf.tpl:11`) pero sin nada de vault | Existe el vehículo (heartbeat), no el uso. |
| 16 | `index.md` por categoría con link + hook de una línea | Impl | `modules/vault-skeleton/index.md` (formato `- [[type/title]] — hook`); drift detectado por `wiki_graph.sh` | Solo falta el uso en query (fila 10). |
| 17 | `log.md` append-only con prefijo parseable | Impl (verbatim) | `modules/vault-skeleton/log.md`; `CLAUDE.md:110, 134, 165`; `docs/vault.md:59-60` cita el mismo `grep` | Idéntico al gist. |
| 18 | Buscador: qmd con CLI + MCP | Impl (más allá) | `docs/vault.md:361-513`; `modules/claude-md.tpl:200-211` ("use it for concept-level questions instead of Grep"); ciclo de vida 010/016/017/018 | Solo MCP está documentado para el agente; el "shell out" por CLI que el gist menciona no (y `bunx` a mano está prohibido, `docs/vault.md:407-420`). |
| 19 | Obsidian Web Clipper / imágenes locales / leer texto y luego ver imágenes | Parcial | `raw_sources/README.md:11, 14, 30, 57-58` (menciona clipper, `images/`, `.md` hermano para binarios) | No hay paso de ingest que descargue imágenes ni que las lea en segunda pasada. En un agente headless el clipper humano no aplica; el agente clipea con `WebFetch`. |
| 20 | Graph view de Obsidian | Impl (equivalente máquina) | `.graph/{graph,backlinks,findings}.json` (`docs/vault.md:231-239`); Obsidian para humanos (`docs/vault.md:534`) | El repo hizo consumible por el LLM lo que el gist deja como vista humana. |
| 21 | El wiki es un repo git (historia, ramas, colaboración) | Parcial | `scripts/lib/backup_vault.sh:128-159`: clon en `~/.cache/agent-backup/vault-clone`, rama huérfana `backup/vault`, snapshot horario | El directorio del vault NO es repo git; el LLM no puede hacer `git log`/`blame` in-place sobre una página. Backup, no historial de trabajo. |
| 22 | Finetuning / datos sintéticos (post) | Ausente | — | Fuera de alcance razonable; se registra por completitud. |

Extras del repo que el gist no pide (para no confundir "fidelidad" con "cobertura"): `wiki/normalization/` + alias→canónico (014); frontmatter obligatoria con `status`/`updated`; `_templates/`; tres capas de memoria con heurística de ruteo (`CLAUDE.md:167-183`); backup a fork; QMD auto-gestionado.

---

## 5. Ideas de la fuente que el repo aún no explota

Ordenadas por (fidelidad a la fuente × costo estimado). Las de origen "comentario" están marcadas: no son de Karpathy.

### 5.1 Del gist y del post (Karpathy)

1. **Index-first en query** (fila 10). El gist es explícito. Cambio de protocolo en `vault-skeleton/CLAUDE.md` + delta en `modules/vault-deltas/` para vaults existentes. [INF] Costo mínimo; además reduce dependencia del retriever en vaults chicos (<100 fuentes), que es el caso de todos los agentes de la flota según memoria del proyecto.
2. **Lint generativo**: "data gaps that could be filled with a web search" y "suggesting new questions to investigate and new sources to look for". Hoy el lint solo reporta defectos. [INF] Encaja como sección adicional del reporte `wiki/synthesis/lint-<date>.md`: "vacíos imputables" + "preguntas abiertas" + "fuentes candidatas".
3. **Filing de respuestas como primera clase**: pasar de "propón y pregunta" a una política explícita (p. ej. auto-file cuando la síntesis cita ≥N páginas, o registrar en `log.md` `query | … | filed: yes/no` para medir la tasa). El post dice "often"; el repo dice "ask first".
4. **Paso "discuss key takeaways" en ingest**: en un canal de chat equivale a un mensaje intermedio con 3-5 takeaways y la pregunta "¿qué enfatizo?". El repo ya tiene la infraestructura de ack/mid-progress (`CLAUDE.md:91`, `claude-md.tpl:151-155`).
5. **Batch-ingest documentado** y cableado a `vault.initial_sources` (campo hoy inerte, fila 8).
6. **Formatos de salida**: Marp (md → deck) y matplotlib (png) enviados por Telegram como archivo. El post los usa "instead of getting answers in text/terminal".
7. **Imágenes en ingest**: descargar adjuntos a `raw_sources/images/` y segunda pasada de lectura visual (gist, tips). Hoy `raw_sources/README.md` lo describe pero el protocolo no lo ejecuta.
8. **Git del wiki para el LLM**: exponer el historial (p. ej. `git -C <clone> log -- wiki/concepts/x.md` o convertir el vault en repo) para que el lint detecte "qué cambió desde el último lint" y para `blame` de claims. Hoy solo hay snapshot horario.
9. **qmd por CLI** además de MCP ("so the LLM can shell out to it"): útil para consultas grandes en un solo `Bash`. Hay que hacerlo vía el prefijo gestionado, nunca `bunx`.
10. **Lint semántico programado** (backlog declarado en 014 R1) usando el heartbeat existente como vehículo.

### 5.2 De los comentarios del gist (NO son de Karpathy; [HV] leídos por API, 1.123 comentarios)

- "pending ingest" como **estado computado** (fuentes en `raw_sources/` sin `summary` asociado), no como flag (wy-cats, 10-09-2026). El grafo ya tiene los datos para derivarlo.
- **Citations-as-links** unificando backlinks, grafo y lint (wy-cats).
- Lint con **verificación de evidencia** (la cita existe en la fuente) (frankchu91, 14-09-2026).
- **Aristas supersedidas** en vez de borradas + dos relojes temporales (valid time vs belief time) (crajah, 20-09-2026).
- **Proposal flow** revisado antes de merge (equationalapplications, 18-09-2026) — el gist mismo menciona "humans in the loop reviewing updates" en el caso business/team.
- "Do you have any rules on periodic cleaning and pruning?" (MironV, 04-04-2026) — pregunta sin respuesta de Karpathy; el gist solo tiene lint.

---

## 6. ¿Menciona Karpathy proyectos, revisiones periódicas o algo afín a PARA/Second Brain?

**Respuesta corta [HV]: no.** Evidencia:

| Término | Gist | Post | Append-and-review note (2025) |
|---|---|---|---|
| PARA / Projects / Areas / Resources / Archives | 0 | 0 | 0 |
| Second Brain / Tiago Forte / CODE | 0 | 0 | 0 |
| Progressive Summarization / Intermediate Packets / Favorite Problems | 0 | 0 | 0 |
| Weekly / monthly review | 0 | 0 | 0 (su "review" es "every now and then… skimming") |
| "Project" | 0 como unidad organizativa (aparece "project documents" como tipo de fuente en business/team) | 0 | 0 |
| "Periodically" | 1: "Periodically, ask the LLM to health-check the wiki" (lint) | "incrementally clean up the wiki" | "Every now and then, I fish through the notes" |

Lo más cercano, y por qué no es PARA [HV + INF]:

- El ejemplo "Personal" del gist ("tracking your own goals, health, psychology, self-improvement — filing journal entries") se parece a *Areas* de PARA, pero el gist lo organiza por **ontología del conocimiento** (entidades, conceptos, comparaciones), no por **accionabilidad** (cuándo lo vas a necesitar), que es el eje de PARA.
- El "lint periódico" es una revisión de **salud del wiki**, no una revisión de **compromisos del humano** (weekly review de Forte).
- El único texto de Karpathy con "review" como práctica personal es "The append-and-review note" (19-03-2025): una sola nota, "Maintaining more than one note and managing and sorting them into folders and recursive substructures costs way too much cognitive bloat", "I don't find that tagging these notes with any other structured metadata (dates, links, concepts, tags) is that useful". Es el **anti-PARA**: sin carpetas, sin tags, con gravedad (lo que importa se rescata arriba, lo demás se hunde). Nota: eso fue ANTES del LLM Wiki; el gist sí adopta frontmatter y estructura, pero delegándola al LLM, no al humano.
- Terceros conectan ambos mundos (blogs "Karpathy's Second Brain", "two-axis second brain", el comentario de MironV). Ninguno cita a Karpathy diciéndolo.

Implicación para 037 [INF]: combinar LLM Wiki + BASB es una **extensión** amparada por la cláusula "everything mentioned above is optional and modular", no una lectura del gist. Conviene declararlo así en la spec: "Karpathy define el qué (compilación, index/log, lint, filing); PARA/CODE aportan el para-qué (proyectos activos, revisión de compromisos) que Karpathy deja deliberadamente fuera". Y un riesgo concreto: PARA organiza por accionabilidad y el repo cierra los tipos en seis por ontología (`CLAUDE.md:32-46`); superponer *Projects* como séptimo tipo choca con "No other types" y con el linter determinista (`wiki_graph.sh` solo reconoce los seis). Habrá que decidir si PARA vive en frontmatter (`tags`/`status`) o como tipo nuevo.

---

## 7. Notas operativas para la spec 037

- **[HV]** La spec 014 (`specs/014-wiki-graph-rag/research.md` R1) ya declaró que el skeleton "es la implementación literal de las 3 capas del gist" y tomó tres ideas de los comentarios del gist (validación determinista, lint obligatorio, índice plano no escala a 4000+ conceptos). 037 debería citar ese R1 y no re-derivarlo.
- **[HV]** Primer commit del skeleton: `1915fc2` (27-04-2026), 23 días después del gist. El repo lo adoptó en la ventana de su viralización.
- **[HV]** `vault-skeleton/CLAUDE.md` cita el gist textualmente (`:11-22`) y `docs/vault.md:190` cita "a single source might touch 10–15 wiki pages" — ambas citas coinciden con el raw verificado.
- **[INF]** Cualquier cambio al protocolo del skeleton necesita su `modules/vault-deltas/schema-updates-<ver>.md` (mecanismo de 014) porque los vaults vivos (donna, linus, rodri-cenco-admin) tienen `CLAUDE.md` co-evolucionado que el upgrade no sobrescribe.

---

## Anexo A — Texto completo del post en X (02-04-2026, verbatim vía fxtwitter) [HV]

> LLM Knowledge Bases
>
> Something I'm finding very useful recently: using LLMs to build personal knowledge bases for various topics of research interest. In this way, a large fraction of my recent token throughput is going less into manipulating code, and more into manipulating knowledge (stored as markdown and images). The latest LLMs are quite good at it. So:
>
> Data ingest:
> I index source documents (articles, papers, repos, datasets, images, etc.) into a raw/ directory, then I use an LLM to incrementally "compile" a wiki, which is just a collection of .md files in a directory structure. The wiki includes summaries of all the data in raw/, backlinks, and then it categorizes data into concepts, writes articles for them, and links them all. To convert web articles into .md files I like to use the Obsidian Web Clipper extension, and then I also use a hotkey to download all the related images to local so that my LLM can easily reference them.
>
> IDE:
> I use Obsidian as the IDE "frontend" where I can view the raw data, the the compiled wiki, and the derived visualizations. Important to note that the LLM writes and maintains all of the data of the wiki, I rarely touch it directly. I've played with a few Obsidian plugins to render and view data in other ways (e.g. Marp for slides).
>
> Q&A:
> Where things get interesting is that once your wiki is big enough (e.g. mine on some recent research is ~100 articles and ~400K words), you can ask your LLM agent all kinds of complex questions against the wiki, and it will go off, research the answers, etc. I thought I had to reach for fancy RAG, but the LLM has been pretty good about auto-maintaining index files and brief summaries of all the documents and it reads all the important related data fairly easily at this ~small scale.
>
> Output:
> Instead of getting answers in text/terminal, I like to have it render markdown files for me, or slide shows (Marp format), or matplotlib images, all of which I then view again in Obsidian. You can imagine many other visual output formats depending on the query. Often, I end up "filing" the outputs back into the wiki to enhance it for further queries. So my own explorations and queries always "add up" in the knowledge base.
>
> Linting:
> I've run some LLM "health checks" over the wiki to e.g. find inconsistent data, impute missing data (with web searchers), find interesting connections for new article candidates, etc., to incrementally clean up the wiki and enhance its overall data integrity. The LLMs are quite good at suggesting further questions to ask and look into.
>
> Extra tools:
> I find myself developing additional tools to process the data, e.g. I vibe coded a small and naive search engine over the wiki, which I both use directly (in a web ui), but more often I want to hand it off to an LLM via CLI as a tool for larger queries.
>
> Further explorations:
> As the repo grows, the natural desire is to also think about synthetic data generation + finetuning to have your LLM "know" the data in its weights instead of just context windows.
>
> TLDR: raw data from a given number of sources is collected, then compiled by an LLM into a .md wiki, then operated on by various CLIs by the LLM to do Q&A and to incrementally enhance the wiki, and all of it viewable in Obsidian. You rarely ever write or edit the wiki manually, it's the domain of the LLM. I think there is room here for an incredible new product instead of a hacky collection of scripts.

(El "the the" en "IDE" está en el original.)

## Anexo B — Verificaciones ejecutadas

- `WebFetch` raw del gist (sha `ac46de1a…`): texto completo.
- `WebFetch` `/revisions` del gist: 1 revisión, 04-04-2026 16:25.
- `gh api --paginate gists/442a6bf…/comments`: 1.123 comentarios; 0 con `user.login == karpathy`; primero 2026-04-04T16:49:23Z; último 2026-09-22T16:50:57Z. `gh api gists/442a6bf…` → HTTP 502 (2 intentos).
- `WebFetch` `api.fxtwitter.com/karpathy/status/2039805659525644595`: texto completo del post; `created_at` Thu Apr 02 20:42:21 +0000 2026.
- Snowflake → fecha: `python3` `(id >> 22) + 1288834974657` → 2026-04-02T20:42:21Z (coincide).
- `WebFetch` `karpathy.bearblog.dev/the-append-and-review-note/`: 19-03-2025, texto completo.
- Repo: `Read` de `modules/vault-skeleton/CLAUDE.md`, `docs/vault.md`; `cat` de `index.md`, `log.md`, `raw_sources/README.md`, `_templates/*.md`, `modules/vault-deltas/schema-updates-0.8.0.md`; `grep` en `scripts/lib/wiki_graph.sh`, `modules/claude-md.tpl`, `scripts/lib/backup_vault.sh`, `setup.sh`, `specs/014-wiki-graph-rag/research.md`; `git log -- modules/vault-skeleton/CLAUDE.md`.
- No se leyó ningún archivo de credenciales; no se modificó ningún archivo del repo.
