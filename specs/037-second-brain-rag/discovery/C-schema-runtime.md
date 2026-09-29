# 037 discovery — Lente C: schema del vault y uso en runtime

Fecha: 22-09-2026. Base: `main` @ `70214d9` (árbol limpio). Solo lectura; ningún archivo del repo fue modificado.

Convención de este informe:

- **[H]** = hecho verificado, con `archivo:línea` del repo.
- **[I]** = inferencia razonable a partir de los hechos; no confirmada por código ni por medición.
- **[P]** = propuesta no validada (diseño sugerido para 037).

Las rutas son relativas a la raíz del launcher salvo que se indique lo contrario. Nada de esto es código de producción hoy: 037 no existe en `specs/` (el último directorio es `036-cold-start-boot-resilience`; `grep -rli` de "second brain|tiago forte|PARA|progressive summar|intermediate packet|favorite problem" en `specs/`, `docs/`, `modules/`, `README.md` y `CHANGELOG.md` no devuelve ningún artefacto relacionado — los únicos hits son usos incidentales de la palabra "para" en 016/024) [H].

---

## Resumen ejecutivo

- El vault es una implementación fiel y **cerrada** del patrón Karpathy: seis tipos de página ("the only six", `modules/vault-skeleton/CLAUDE.md:32-46`), un frontmatter único de 8 claves (`:59-72`), y un enum `status` de cuatro valores (`:69`). Todo eso lo **impone un linter determinista** (`scripts/lib/wiki_graph.sh:111-114`, `:170-174`), no solo la prosa: un `type` fuera de los seis o un `status` fuera del enum produce `frontmatter_violation`, que el `doctor` local eleva a WARN (`specs/014-wiki-graph-rag/contracts/graph-artifacts.md:117`).
- Los tres protocolos (ingest / query / lint) son **100 % LLM en su ejecución**; lo determinista es todo lo que ocurre *después* y *alrededor*: reindex qmd por inotify + cron, backup por hash, grafo + findings cada 6 h. Ningún script valida un ingest al momento de escribirlo; la validación llega diferida vía `.graph/findings.json`.
- El heartbeat (`scripts/heartbeat/heartbeat.sh`) **no toca el vault** [H, grep sin resultados]: es un `claude --print` con un único prompt configurable, docker-only (`modules/claude-md.tpl:92`), y con un config dir aislado sin plugins. Es el único gancho existente para correr un LLM contra el vault por calendario, y solo admite **un** prompt para todos los ticks.
- Las tres capas de memoria tienen una heurística de routing escrita en dos lugares idénticos (`modules/vault-skeleton/CLAUDE.md:177-183` y `modules/claude-md.tpl:187-193`) y una regla dura: "Don't double-write across layers". La auto-memoria ya tiene un tipo `project_*` ("project-specific facts, deadlines, decisions", `docs/state-layout.md:49`), y el tipo `entity` del vault ya admite "project" (`CLAUDE.md:39`). PARA "Projects" colisiona con **ambos** a la vez.
- Lo que el vault **no puede expresar** hoy: fechas de inicio/fin ni estado de avance de un proyecto, áreas de responsabilidad, archivo (no hay directorio ni estado `archived`), niveles de destilación, paquetes reutilizables, revisiones periódicas con vencimiento, ni un filtro de captura (favorite problems). `vault.initial_sources` y `vault.schema.*` existen en `agent.yml` pero **nadie los consume** [H].
- El camino de menor cambio es **claves de frontmatter adicionales + secciones nuevas en `index.md` + ops nuevas en `log.md` + un delta de schema**: el parser del linter ignora claves desconocidas (`wiki_graph.sh:202-226`), ignora los encabezados de `index.md` (`:399-427`) y nadie valida el vocabulario de ops del log. Lo que **sí** cuesta caro es un tipo nuevo o un `status` nuevo (linter + tests + docs + mirror docker + DOCKER_E2E + delta para vaults existentes).
- Riesgo estructural principal: el schema vivo de cada agente es su `CLAUDE.md` co-evolucionado, que el upgrade aditivo **nunca sobreescribe** (`scripts/lib/vault.sh:52-57`); la entrega de 037 a la flota sería un delta que el agente integra a mano, sin verificación de que lo hizo.

---

## 1. Contrato de página actual

### 1.1 Frontmatter exacto (páginas de conocimiento)

Fuente: `modules/vault-skeleton/CLAUDE.md:57-72` [H]. Reproducido verbatim:

```yaml
---
title: ""
type: summary | entity | concept | comparison | overview | synthesis
sources: []          # paths relative to vault root, e.g. ["raw_sources/papers/karpathy-llm-wiki.md"]
related: []          # wikilinks to other pages, e.g. ["[[concepts/llm-wiki-pattern]]"]
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: draft | active | stale | superseded
tags: []
---
```

"Every page in `wiki/` starts with this YAML block (no exceptions)" (`:59`). Las ocho plantillas de tipo (`modules/vault-skeleton/_templates/{summary,entity,concept,comparison,overview,synthesis}.md:1-10`) llevan exactamente esas claves y **arrancan con `status: active`**, no `draft` [H, línea 8 de cada plantilla].

Lo que el **linter determinista** verifica de ese bloque, que es más estrecho que la prosa [H, `scripts/lib/wiki_graph.sh`]:

| Clave | Qué hace el parser | Consecuencia |
|---|---|---|
| `title` | Solo comprueba **presencia** de la clave (`:210`, `:171`) | `title: key missing` si falta; `title: ""` NO es violación (contrato 014 `graph-artifacts.md:48`) |
| `type` | Valor contra `summary entity concept comparison overview synthesis` (`:111-112`, `:172-173`) | `type: missing` / `type: invalid '<x>'` |
| `status` | Si está, contra `draft active stale superseded` (`:113-114`, `:174`) | `status: invalid '<x>'`; ausente = sin violación |
| `created`, `updated` | Se capturan (`:208-209`), `updated` alimenta el cálculo de `stale` (`:430-455`); **no se valida formato** | ninguna |
| `sources` | Cada ítem → arista `source` (`:177`, `:198`, `:218-221`) | alimenta `co_sourced` y `stale` |
| `related` | Cada ítem → arista `related` (`:176`, `:197`, `:214-217`); se desenvuelve `[[x\|y#z]]` (`:125-132`) | cuenta como backlink si resuelve; `broken_link` si no (`:514`) |
| `tags` | **No se parsea** (no hay rama para `tags` en `:202-226`) | canal libre |
| cualquier otra clave | Se ignora (`curkey` queda seteado pero ninguna rama la consume) | **canal libre** — hecho clave para 037 |

Acepta arrays en forma flow `[a, b]` (`:134-143`) y en forma bloque `- item` (`:195-201`) solo para `related`, `sources`, `aliases` [H].

### 1.2 Frontmatter de reglas de normalización (no es conocimiento)

`modules/vault-skeleton/_templates/normalization.md:1-7` [H]: `canonical`, `aliases`, `match_case` (default `false`), `entity` (wikilink opcional a `[[entities/...]]`), `notes`. **Sin `type`**: si aparece, el linter emite `normalization: type key not allowed` (`wiki_graph.sh:162`); `canonical` vacío y `aliases` vacío son violaciones (`:163-164`). Las páginas bajo `wiki/normalization/` **no son nodos** del grafo (`:185`, `:161-168`; test `tests/wiki-graph.bats:33` "normalization is not a node") y "are never cited as knowledge" (`CLAUDE.md:54`).

### 1.3 Frontmatter de fuentes crudas (capa 1)

`modules/vault-skeleton/raw_sources/README.md:46-55` y `_templates/source.md:1-8` [H]: `title`, `url`, `author`, `published` (fecha propia de la fuente), `clipped` (fecha de captura), `type: article | paper | transcript | gist | data | image`. Para binarios, un `<filename>.md` hermano con frontmatter y texto extraído (`README.md:57-58`). Regla dura: "LLM-generated content of any kind" no va en `raw_sources/` (`README.md:18`); "Mutable working notes" van al wiki (`:19`).

El linter **no** parsea `raw_sources/` (solo enumera `wiki/`, `:321`); la única lectura que hace de una fuente es su **mtime** para el finding `stale` (`:446-452`) [H].

### 1.4 Tipos: los seis y su semántica declarada

`CLAUDE.md:36-43` [H]:

| `type` | Subdir | Propósito declarado |
|---|---|---|
| `summary` | `wiki/summaries/` | Uno por fuente ingerida; argumento, claims, ejemplos |
| `entity` | `wiki/entities/` | Cosa concreta: "person, product, tool, **project**, place, organization" |
| `concept` | `wiki/concepts/` | Idea abstracta: framework, principio, definición, teoría |
| `comparison` | `wiki/comparisons/` | X vs Y, criterios de decisión |
| `overview` | `wiki/overviews/` | Síntesis alta de un dominio, página de navegación |
| `synthesis` | `wiki/synthesis/` | Integración transversal; meta-páginas; "should be rare" (`:108`) |

"No other types. If something doesn't fit, the right move is usually to make it a `concept` or to extend an existing page, not to invent a new type." (`:45-46`). El identificador de nodo es la ruta bajo `wiki/` sin `.md` (`wiki_graph.sh:152-157`), y **cualquier** `*.md` bajo `wiki/` (recursivo, cualquier subdirectorio, incluso la raíz de `wiki/`) es un nodo sujeto a la validación de `type` (`:321`, `:329`, `:340`) [H]. El subdirectorio NO se cruza contra el `type` declarado: `wiki/concepts/x.md` con `type: entity` no es violación [H, no hay comprobación dir↔type en `:170-174`].

Cuerpos esperados por plantilla [H]: `summary` = Thesis / Key claims / Examples-evidence / Caveats / Connections; `entity` = identity card / Facts (Founded, Located, Primary role, Key affiliations) / What it does / Notable claims / Connections; `concept` = Definition / Why it matters / Mechanics / Examples / Limits / Connections; `comparison` = Subjects / Side-by-side / When A / When B / Tradeoffs / Sources; `overview` = Map of the territory / Open questions / Where to start; `synthesis` = Integrated view / Constituents / Implications / Tensions.

### 1.5 Wikilinks

`CLAUDE.md:76-85` [H]: forma `[[<type>/<title>]]` con título slugificado (kebab-case). "Backlinks are not maintained automatically. If you add a link from A to B, also add the reverse in B's `related:` array if it's load-bearing." El grafo deriva backlinks (`wiki_graph.sh:517-521`) y la resolución de `[[x|display]]` / `[[x#anchor]]` (`:125-132`). Un wikilink cuyo destino no es un nodo de `wiki/` es `broken_link` (`:514`) — esto incluye enlaces a rutas fuera de `wiki/` (ver riesgo 6.5). Los `[[...]]` dentro de fences ``` se ignoran (`:230-231`).

### 1.6 Naming

`CLAUDE.md:197-201` [H]: kebab-case; **sin fechas en el nombre** salvo `lint-YYYY-MM-DD.md` "and similar dated artifacts"; un tema por archivo; dividir sobre ~500 líneas. `raw_sources/README.md:35-40`: mismo slug, sin fechas (la fecha va en frontmatter), discriminador ante colisiones; subdirectorios (`articles/ papers/ transcripts/ data/ images/`) solo cuando el plano deja de servir (~50 fuentes, `:22-33`).

### 1.7 `index.md` (catálogo, orientado a contenido)

`modules/vault-skeleton/index.md:1-11` [H]: una línea por página, `- [[<type>/<title>]] — short one-line hook`; secciones `Summaries / Entities / Concepts / Comparisons / Overviews / Synthesis / Normalization` (`:15-42`); "If `index.md` and the actual filesystem disagree, the filesystem wins."

Cómo lo lee el linter (`wiki_graph.sh:399-427`) [H]: toma **cualquier** línea que sea bullet `- ` y extrae todos los tokens `[[...]]` que no contengan `<` ni `>`, quitando comentarios HTML y spans en backticks. **Ignora por completo los encabezados**. Luego cruza: entrada sin archivo → `index_drift/missing_file`; nodo sin entrada → `index_drift/missing_from_index` (`:542-543`). Consecuencias para 037: (a) se pueden añadir secciones nuevas con cualquier encabezado sin tocar código; (b) una misma página puede aparecer en varias secciones (`sort -u`, `:427`); (c) una lista de texto plano sin `[[...]]` (p. ej. preguntas guía) es invisible para el linter.

### 1.8 `log.md` (bitácora, orientada a tiempo)

`modules/vault-skeleton/log.md:6-14` [H]: `## [YYYY-MM-DD] {ingest|query|lint|init|other} | <short title>` + párrafo opcional; append-only; "parseable by `grep "^## \[" log.md | tail -N`". `vault.sh::vault_log_append` (`:146-153`) escribe ese mismo formato con `op` **libre**, y el upgrade 014 usa `op = upgrade` (`vault.sh:105`), fuera del vocabulario documentado [H]. `vault.schema.log_format: "## [{date}] {op} | {title}"` se escribe en `agent.yml` (`setup.sh:1296-1297`) pero **ningún script lo lee** [H, `grep -rn log_format` solo encuentra al escritor].

### 1.9 Lo que no forma parte del contrato pero lo rodea

- `_templates/` es "boilerplate you read when creating new pages. Not part of the wiki." (`CLAUDE.md:29`). El linter no lo enumera [H]; **qmd sí lo indexa** (máscara `**/*.md` sobre la raíz del vault, `scripts/lib/qmd_index.sh:379`) y el backup también (`scripts/lib/backup_vault.sh:93`) [H].
- `.graph/` es derivado, JSON-only, regenerable, excluido de backup y de qmd por construcción (`docs/vault.md:248-250`, `docs/state-layout.md:160`; test `tests/wiki-graph.bats:142`) [H].
- `.obsidian/` vacío en el scaffold, propiedad del usuario (`docs/vault.md:324`); Dataview opcional para consultar por frontmatter (`:536-537`) [H].
- MCPVault expone 14 tools, incluidas `get_frontmatter`, `update_frontmatter`, `manage_tags`, `move_note`, `search_notes` (`docs/vault.md:347-350`) [H]; qmd es solo lector (`modules/claude-md.tpl:202`) [H].

---

## 2. Los tres protocolos, paso a paso, y qué es determinista

### 2.1 Ingest (`CLAUDE.md:87-112`)

| Paso | Qué dice el schema | Quién lo ejecuta |
|---|---|---|
| 0 | Si es chat-driven, ack de una línea con estimación; máx. 1 mid-progress (`:91`) | LLM |
| 1 | Clip a `raw_sources/<slug>.md` con frontmatter mínimo; "Never modify the source content again" (`:92-94`) | LLM (la inmutabilidad es regla, no está impuesta por ningún script [H]; lo único que la delata indirectamente es `stale` por mtime) |
| 2 | `wiki/summaries/<slug>.md` desde la plantilla; `sources:` apunta al raw (`:95-97`) | LLM |
| 2.5 | Normalizar terminología leyendo `wiki/normalization/` o `canonical_of` en `.graph/backlinks.json`; proponer regla nueva si hay mis-transcripción recurrente (`:98-102`) | LLM lee un artefacto determinista |
| 3 | Entidades y conceptos "load-bearing": crear o actualizar (claim nuevo, link al summary, bump `updated:`, refinar `status:`) (`:103-105`) | LLM |
| 4 | Cross-refs: `comparison` si compara; `synthesis` "should be rare" (`:106-108`) | LLM |
| 5 | Una línea por página nueva en `index.md` (`:109`) | LLM |
| 6 | `## [YYYY-MM-DD] ingest \| <source title>` en `log.md` (`:110`) | LLM |

"A single ingest typically touches 5–15 wiki pages" (`:112`). No hay slash command: se dispara en lenguaje natural (`docs/vault.md:173-177`, y la justificación en `:542-553`) [H].

Efectos deterministas **posteriores** a un ingest [H]:

- Watcher inotify (debounce ~15 s) → `qmd-reindex` (`docs/vault.md:400`); backstop cron `*/5` docker (`docker/scripts/heartbeatctl:280-287`) / timer local. Debounce por `vault_hash` (`backup_vault.sh:100-109`, reutilizado por `qmd_index.sh:533`).
- Backup `backup/vault` horario por hash (`heartbeatctl:241-247`; `docs/vault.md:267-274`).
- Grafo + findings a las `20 */6` (`heartbeatctl:290-300`).

Nada determinista valida el ingest **en el momento**: los hallazgos (`missing_from_index`, `broken_link`, `type: invalid`, `orphan`) aparecen en el siguiente pase del grafo y el agente los corrige después (`CLAUDE.md:140-146`).

### 2.2 Query (`CLAUDE.md:114-134`)

| Paso | Qué dice el schema | Determinista vs LLM |
|---|---|---|
| 1 | Buscar en el wiki primero (`search_notes`, `Glob`, `Grep`); preferir `status: active` y `updated:` reciente (`:118-119`). Con qmd habilitado, el `.mcp.json` trae `qmd` para preguntas conceptuales (`claude-md.tpl:200-202`) | Retrieval determinista (BM25 + vector + rerank, `docs/vault.md:363-366`); selección LLM |
| 1.5 | Expandir por el grafo: vecinos 1-hop `backlinks`, `related_out`, `co_sourced`, `canonical_of` de `.graph/backlinks.json`; fallback a búsqueda plana si `.graph/` falta o está viejo (`:120-125`) | Artefacto determinista, consumo LLM |
| 2 | Leer páginas completas (`:126`) | LLM |
| 3 | Citar `[[type/slug]]` y rutas `raw_sources/...` (`:127-128`) | LLM |
| 4 | Sintetizar, no pegar (`:129-130`) | LLM |
| 5 | "File good answers back": proponer `overview`/`synthesis`; **no auto-crear, preguntar** (`:131-133`) | LLM + humano |
| 6 | `## [YYYY-MM-DD] query \| <question summary>` (`:134`) | LLM |

Observación [H]: la colección qmd es la **raíz del vault** con `**/*.md` (`qmd_index.sh:379`), o sea indexa `CLAUDE.md`, `index.md`, `log.md`, `_templates/*.md`, `raw_sources/**/*.md` y `wiki/normalization/*.md`, no solo las páginas de conocimiento. [I] El ruido de plantillas y reglas en el retrieval semántico no está medido; para 037 importa porque cualquier directorio nuevo con markdown (revisiones semanales, packets) entra al índice automáticamente.

### 2.3 Lint (`CLAUDE.md:136-165`)

Dos linters con reparto explícito [H]:

**Determinista** (`scripts/lib/wiki_graph.sh`, "NEVER edits the wiki; you apply the fixes", `CLAUDE.md:140-146`): produce `.graph/findings.json` con siete kinds (`:539-546`, contadores `:555-560`):

| kind | Definición operativa |
|---|---|
| `orphan` | nodo sin backlink entrante por `wikilink` o `related` (`:519-521`, `:539`) |
| `broken_link` | arista `wikilink`/`related` cuyo destino no es nodo (`:514`, `:540`) |
| `frontmatter_violation` | las siete razones de `emit_v` (`:162-164`, `:171-174`) |
| `index_drift` | `missing_file` / `missing_from_index` (`:542-543`) |
| `stale` | `status: active` **y** mtime de una fuente en `sources:` > `updated:` + 1 día (`:430-455`) — solo eso; no hay noción de "vence el" |
| `alias_occurrence` | alias de normalización en el cuerpo, con límite de palabra, fuera de fences y wikilinks (`:246-260`) |

Cadencia `20 */6 * * *` en ambos modos; manual `agentctl heartbeat wiki-graph` (`docs/heartbeatctl.md:464-479`). Mapeo a `doctor` (local): `broken_links`/`frontmatter_violations`/`index_drift` > 0 → WARN (exit 1); `orphans`/`stale`/`alias_occurrences` → solo counts (`graph-artifacts.md:117-120`). Docker: `doctor` no mira el grafo, se lee `scripts/heartbeat/wiki-graph.json` a mano (`docs/heartbeatctl.md:483-487`).

**Agéntico** (LLM, `CLAUDE.md:148-165`): ack; detectar contradicciones, orphans, stale claims, cross-refs faltantes, conceptos sin página; reporte en `wiki/synthesis/lint-<date>.md` "treat it as a synthesis page"; nada destructivo; `## [date] lint | <count> findings`. Disparadores (`:185-195`): tras 5+ ingests, antes de una síntesis grande, cuando el humano pregunta, "once a month".

### 2.4 Heartbeat: qué hace un tick y si toca el vault

`scripts/heartbeat/heartbeat.sh` [H]:

- Un tick = `tmux new-session` que corre `CLAUDE_CONFIG_DIR=<aislado> claude --print --dangerously-skip-permissions --permission-mode auto '<HEARTBEAT_PROMPT>'` con cwd = workspace (`:213-214`), espera hasta `HEARTBEAT_TIMEOUT` (default 300 s, `:30`) el centinela `HEARTBEAT_DONE` (`:216-229`), detecta 401/`Please run /login` en stdout (`:279-285`), invoca **un** notifier (`:287-304`), appendea a `logs/runs.jsonl` y reescribe `state.json` (`:306-388`), y conserva 20 logs de sesión (`:390`).
- El config dir aislado comparte credenciales y `.claude.json` por symlink pero deshabilita **todos** los plugins y borra los hooks `Stop` y `PreToolUse` (`:126-172`, jq en `:151`).
- **No hay ninguna referencia al vault** en el script (grep de `vault`, `wiki`, `raw_sources`: 0 resultados). El prompt por defecto pide explícitamente "No tool use" (`:32`). El único modo en que un tick toca el vault es que el operador configure un prompt que lo haga (`heartbeatctl set-prompt`; ejemplo documentado "Vault ingestion monitor" contando archivos en `~/.vault/wiki/`, `docs/heartbeatctl.md:145`).
- Docker-only: en local "Nothing. No systemd timer for the heartbeat ships" (`modules/claude-md.tpl:92`).
- Hay **un solo** prompt vigente (`heartbeat.conf` → `HEARTBEAT_PROMPT`; `state.json.prompt`, `:373-383`); `--prompt` solo se acepta como override por invocación (`:37-43`, expuesto por `heartbeatctl test`).
- [I] Como el cwd es el workspace y `.claude.json` está compartido, los MCP de proyecto (`vault`, `qmd`) probablemente sí se cargan en la sesión del heartbeat aunque los plugins estén apagados. No está medido; si 037 quiere usar el heartbeat como motor de revisiones, hay que verificarlo primero.

### 2.5 Tabla resumen: determinista vs LLM

| Capacidad | Determinista (script) | LLM |
|---|---|---|
| Escribir/actualizar páginas, index, log | — | Sí (todo) |
| Validar frontmatter, links, índice | `wiki_graph.sh` (6 h / manual) | Contradicciones, páginas faltantes |
| Retrieval | qmd (BM25+vector+rerank), MCPVault `search_notes` | Selección, lectura, síntesis |
| Grafo / backlinks / alias→canónico | `wiki_graph.sh` → `.graph/*.json` | Consumo en query 1.5 |
| Frescura ("stale") | mtime fuente > `updated`+1 d, solo `active` | "stale claims" semántico |
| Reindex / backup | inotify + cron/timer, hash-debounce | — |
| Ejecución programada de un LLM | heartbeat (docker, 1 prompt) | El prompt que el operador fije |
| Entrega de cambios de schema a vaults existentes | `vault_seed_missing` (lista explícita + delta + sentinel) | El agente integra el delta a mano en su `CLAUDE.md` |

---

## 3. Las tres capas de memoria y la heurística de routing

### 3.1 Qué dice cada fuente (idénticas en fondo)

`modules/vault-skeleton/CLAUDE.md:167-183` (lo que ve el agente al trabajar en el vault) y `modules/claude-md.tpl:176-193` (lo que ve al arrancar) [H]:

| Capa | Ruta | Para qué |
|---|---|---|
| Auto-memoria | docker `~/.claude/projects/-workspace/memory/`; local `<ws>/.state/.claude/projects/<slug>/memory/` (`claude-md.tpl:182-183`) | "Atomic facts about the user, preferences, project state. Indexed by `MEMORY.md` (loaded into every session). Write tipped memories: `user_*`, `feedback_*`, `project_*`, `reference_*`." |
| claude-mem | `~/.claude-mem/*.db` (en local, home del operador; `docs/state-layout.md:18,67`) | Observaciones pasivas de transcripts; escribe el worker; se consulta con `mem-search`, `smart_search`, `timeline` |
| Vault | `{{VAULT_MCP_PATH}}` | "Curated, synthetic, compounding knowledge derived from external sources" |

Heurística (`claude-md.tpl:187-193`; `CLAUDE.md:177-183`) [H]:

- "Save this fact about the user / project" → auto-memoria.
- "What did we do last week?" → claude-mem.
- "Build a knowledge base on X / ingest this article / synthesize across sources" → vault.
- "If unsure, ask. Don't double-write across layers."

Detalle de la auto-memoria (`docs/state-layout.md:45-55`) [H]: archivos con frontmatter `name`, `description`, `type`; `project_<topic>.md` = "project-specific facts, deadlines, decisions"; `user_<topic>.md` = "who the user is, role, preferences"; `MEMORY.md` se carga en cada sesión y **se trunca a 200 líneas**.

### 3.2 Por qué PARA colisiona con esto

1. **"Project" ya tiene dos casas.** Auto-memoria `project_*` (`state-layout.md:49`; `claude-md.tpl:182`) y vault `entity` ("person, product, tool, **project**, place, organization", `CLAUDE.md:39`; `_templates/entity.md:14`). PARA "Projects" sería una tercera. Con la regla "don't double-write", 037 **tiene que** decidir una sola casa por tipo de dato, no puede sumar una tercera sin regla.
2. **"Areas" pisa `user_*` y `project_*`.** Un área de responsabilidad ("rol, estándar a mantener") es hoy, por la heurística, un hecho sobre el usuario (`user_*`) o un estado de proyecto (`project_*`). El vault no tiene construct para "estándar que se mantiene en el tiempo"; lo más cercano es `overview` (mapa de un dominio, `CLAUDE.md:42`), pero eso es conocimiento, no responsabilidad.
3. **"Resources" es exactamente el dominio del vault hoy** (fuentes externas curadas). Sin colisión.
4. **"Archives" no existe en ninguna capa.** El vault solo tiene `status: superseded | stale` por página (`CLAUDE.md:69`), semántica de "reemplazada por fuente nueva" / "desactualizada", no de "proyecto cerrado". La auto-memoria no tiene archivo; `MEMORY.md` se trunca a 200 líneas, o sea, lo viejo se **pierde del contexto**, no se archiva.
5. **claude-mem es la "captura pasiva" que Forte no contempla.** Second Brain asume captura manual; aquí ya existe una capa que captura sola. [I] Buena parte de "Capture" ya está resuelta por claude-mem para lo conversacional, y por `raw_sources/` para lo externo; lo que falta es el **filtro** (favorite problems) y la **bandeja** (inbox sin procesar).

### 3.3 Regla de routing propuesta [P]

Principio: **la auto-memoria guarda punteros y estado mínimo; el vault guarda la sustancia**. Es compatible con "don't double-write" si el puntero es una referencia, no una copia.

| Dato | Casa única | Cómo se referencia desde las otras |
|---|---|---|
| Ficha de proyecto (objetivo, resultado, inicio/fin, siguiente acción, checklist) | Vault, página `entity` con claves PARA (ver §5) | Auto-memoria `project_<slug>.md` con 2-3 líneas: estado actual + `[[entities/<slug>]]` |
| Área de responsabilidad (estándar, indicadores, qué revisar) | Vault, página `overview` con `para: area` | `user_role.md` apunta a las áreas |
| Recursos (fuentes, conceptos, comparaciones) | Vault (sin cambio) | — |
| Archivo | Vault, mismo archivo, clave `para: archive` + `archived: YYYY-MM-DD`; sección "Archive" en `index.md` | Auto-memoria: eliminar el `project_*` o dejar una línea "cerrado, ver [[...]]" |
| Preferencias del usuario, cómo trabajar | Auto-memoria (sin cambio) | — |
| Lo que pasó en una sesión | claude-mem (sin cambio) | El vault cita `timeline`/`mem-search` cuando destila |
| Favorite problems | Vault, **una** página (p. ej. `wiki/synthesis/favorite-problems.md`) | `CLAUDE.md` del vault la nombra en el paso 0.5 de ingest; opcionalmente `MEMORY.md` la lista |

Riesgo del principio [I]: si el agente guarda "estado actual" en auto-memoria y "ficha" en el vault, el estado se desincroniza en silencio (la regla 06 del operador sobre réplica vs puntero aplica). Mitigación: que el `project_*` no lleve estado, solo el puntero y la fecha de la última revisión.

---

## 4. Qué le falta al vault para expresar Second Brain

| Necesidad (Forte) | Estado hoy [H] | Hueco concreto |
|---|---|---|
| Proyectos activos con inicio/fin | `entity` admite "project" (`CLAUDE.md:39`), pero la plantilla es una "identity card" (`_templates/entity.md:14-23`: Founded, Located, Primary role, Key affiliations). Frontmatter solo tiene `created`/`updated` (`:67-68`). `status` no tiene `completed`/`on-hold`/`archived` (`:69`, enum cerrado en `wiki_graph.sh:113`) | Sin fecha objetivo, sin resultado esperado, sin siguiente acción, sin estado de avance |
| Áreas de responsabilidad | Nada. `overview` es el más cercano (`:42`) | Sin noción de "estándar a sostener" ni de indicadores |
| Archivo de lo inactivo | `status: superseded|stale` por página; sin directorio ni sección en `index.md` (`index.md:15-42`); `log.md` es historia, no archivo | Sin operación "archive", sin vista de archivo, sin fecha de cierre |
| Destilación progresiva por capas | Pipeline implícito: raw (L0) → `summary` (L1-L2: Thesis, Key claims) → `concept`/`overview`/`synthesis`. Sin campo de nivel; sin conservación de highlights (`raw_sources` inmutable, `README.md:3-5`; contenido LLM prohibido allí, `:18`) | No hay dónde poner los subrayados (L2) ni el "bold within bold" (L3) sin violar la capa 1; el resumen ejecutivo (L4) se confunde con `summary` |
| Intermediate packets reutilizables | Nada. Query paso 5 "file good answers back" los archiva como `overview`/`synthesis` (`:131-133`), y `synthesis` "should be rare" (`:108`) | Sin tipo ni marca para entregables (plantillas, checklists, borradores, decisiones); sin forma de encontrarlos ("dame el checklist de X") |
| Revisiones periódicas | "Maintenance triggers" (`:185-195`) son revisiones de salud del wiki, "once a month". Único motor programado con LLM = heartbeat, docker-only, 1 prompt (§2.4). Local: solo timers deterministas | Sin revisión semanal/mensual de PARA (limpiar bandeja, actualizar lista de proyectos, decidir siguientes acciones); sin `next_review`; sin op `review` en el log |
| Favorite problems como filtro de captura | Nada. Ingest arranca "when the human says ingest" (`:89`) y no filtra. `vault.initial_sources: []` se escribe (`setup.sh:1287`) y **nadie lo consume** [H, grep] | Sin lista de preguntas guía; sin paso "¿esto responde a alguna pregunta abierta?"; sin marca en las páginas de a qué problema aportan |
| Bandeja de captura (Capture sin Organize) | Ingest es síncrono y completo (5-15 páginas, `:112`); `raw_sources/` es la única entrada | [I] Sin lugar para "capturado, no procesado" el agente ingiere de inmediato o pierde la captura |
| Express (salida) | Sin construct | Los outputs viven en chat/Confluence/Jira, fuera del vault |

Además, dos claves muertas en `agent.yml` que podrían reciclarse o eliminarse: `vault.initial_sources` y `vault.schema.{frontmatter_required,log_format}` (`setup.sh:1287,1296-1297`; sin lectores) [H].

---

## 5. Dónde vivirían con el menor cambio

Ordenado de menor a mayor costo. El criterio de "costo" es: qué archivos del launcher se tocan, si el linter lo acepta sin cambios, si hay que reflejarlo a docker y si exige DOCKER_E2E.

### 5.1 Frontmatter adicional (costo cero en el linter) [P]

Claves nuevas, todas ignoradas por el parser (`wiki_graph.sh:202-226`) y consultables por Dataview y por MCPVault `get_frontmatter`/`update_frontmatter`:

```yaml
para: project | area | resource | archive      # bucket PARA; ausente = resource
project: ""            # [[entities/<slug>]] al que pertenece (packets, summaries)
starts: YYYY-MM-DD     # solo project
ends: YYYY-MM-DD       # objetivo; solo project
archived: YYYY-MM-DD   # solo cuando para: archive
next_review: YYYY-MM-DD
distill: 1 | 2 | 3 | 4 # nivel de destilación progresiva alcanzado
packet: false          # true = intermediate packet reutilizable
problems: []           # slugs de favorite problems a los que aporta
```

Restricción dura: `status` **no** puede recibir valores nuevos (`archived`, `done`, `on-hold`) sin tocar `wiki_graph.sh:113` → violación. Por eso el archivo va en `para: archive`, no en `status`. Mantener `status` con su semántica de frescura de conocimiento.

Entrega a vaults existentes: es prosa en `CLAUDE.md` + plantillas; sin cambio de código.

### 5.2 Páginas de tipos existentes (costo: plantillas + prosa) [P]

- **Proyecto** = `entity` + `para: project` + `starts/ends`. Plantilla variante `_templates/entity-project.md` (mismo `type: entity`; secciones Objetivo / Resultado esperado / Siguiente acción / Checklist / Packets `[[...]]` / Cierre). Añadir una plantilla no toca el linter; la entrega a vaults existentes va por `vault_seed_missing` (patrón `vault.sh:86-90`, "only when absent").
- **Área** = `overview` + `para: area`. Plantilla variante `_templates/overview-area.md` (Estándar / Indicadores / Proyectos activos / Recursos clave / Revisión).
- **Favorite problems** = **una** página `wiki/synthesis/favorite-problems.md` (o `concepts/`), `status: active`, con lista numerada y por cada problema un slug estable. Justificación: es la "meta-página" por excelencia (`CLAUDE.md:43`) y se cita desde el paso 0.5 de ingest.
- **Intermediate packets**: la opción de menor cambio es `packet: true` sobre una página del tipo que corresponda (`concept` para un framework reutilizable, `comparison` para una matriz de decisión, `synthesis` para un borrador integrador). Contra: diluye "synthesis should be rare" si todo termina ahí. Alternativa con directorio propio: ver 5.4.
- **Destilación progresiva**: secciones adicionales en `_templates/summary.md` (`## Highlights (L2)`, `## Core (L3)`, `## Executive summary (L4)`) + `distill:` en frontmatter. Los subrayados viven en el `summary`, nunca en `raw_sources/` (§6.11).

### 5.3 `index.md`: secciones PARA sin tocar código [P]

El linter ignora encabezados y tolera repetidos (§1.7). Se pueden añadir, además de las siete secciones por tipo:

```markdown
## Projects (active)
## Areas
## Archive
## Packets
## Favorite problems
```

Las cuatro primeras listan páginas que **ya** están en su sección por tipo (vista PARA sobre el mismo catálogo). "Favorite problems" puede ser texto plano o un solo link a la página de §5.2. Costo: prosa en `index.md` del skeleton + delta para vaults existentes.

### 5.4 Directorios nuevos: dentro o fuera de `wiki/` (decisión con consecuencias) [P]

| Opción | Grafo / linter | Backup | qmd | Costo |
|---|---|---|---|---|
| `wiki/<nuevo>/` con `type` de los seis | Nodo normal; validado; `missing_from_index` si no está en el índice | sí | sí | Solo prosa (`CLAUDE.md` dice que el subdir sigue al tipo, pero el linter no lo cruza) |
| `wiki/<nuevo>/` con `type` nuevo (`project`, `packet`) | **`type: invalid`** en cada página (`:173`) → WARN en `doctor` local | sí | sí | `wiki_graph.sh:111` + tests (`wiki-graph.bats:33,65,98`) + docs + mirror docker (`setup.sh:1667-1669`, `Dockerfile:266`) + DOCKER_E2E + delta |
| `<vault>/<nuevo>/` fuera de `wiki/` (p. ej. `packets/`, `reviews/`) | **Invisible** al grafo; cualquier `[[packets/x]]` desde `wiki/` es `broken_link` (`:514`) → WARN | sí (`backup_vault.sh:93`) | sí (`qmd_index.sh:379`) | Cero en código, pero rompe la navegación por wikilinks |

Recomendación de menor cambio [P]: **no** crear tipos ni directorios nuevos; usar 5.1-5.3. Si se quiere un directorio propio para packets, que sea `wiki/packets/` con `type` de los seis (p. ej. `synthesis`) y `packet: true` — o bien pagar el costo completo de un séptimo tipo (§6.1), pero de forma consciente.

### 5.5 `log.md`: ops nuevas (costo: prosa) [P]

Nada valida el vocabulario (`vault.sh:146-153` acepta cualquier op; `log_format` es clave muerta). Añadir a la línea `:9` de `log.md` y al `CLAUDE.md`: `capture`, `review`, `archive`, `express`. Formato sugerido para revisiones: `## [YYYY-MM-DD] review | weekly — N projects, M archived, K packets`. Mantener el grep `^## \[` intacto.

### 5.6 `CLAUDE.md` del vault: operaciones nuevas y entrega a la flota [P]

Secciones nuevas: "Operation: capture" (bandeja + filtro por favorite problems), "Operation: review (weekly / monthly)" (lista de proyectos, archivar, siguiente acción, `next_review`), "Operation: archive", "Operation: express (packets)"; e insertar en ingest un paso 0.5 "leer `favorite-problems` y anotar `problems:`".

Entrega a vaults existentes: el precedente es exacto y está en código [H]:

1. Nuevo delta `modules/vault-deltas/schema-updates-<versión>.md` (molde `schema-updates-0.8.0.md:3-7`: el agente integra y puede borrarlo).
2. Entradas explícitas nuevas en `vault_seed_missing` (`vault.sh:78-110`: lista explícita, nunca un walk del skeleton; nuevo sentinel oculto `_templates/.schema-updates-<versión>.applied`; una línea `upgrade` en `log.md`).
3. `vault.sh` y `modules/vault-deltas/` se copian al build context docker en el scaffold (`setup.sh:1658-1660`, `:1676-1679`) y se hornean en la imagen (`docker/Dockerfile:285,290`); el boot llama `vault_seed_missing` (`docker/scripts/start_services.sh:132-133`) y local lo hace `--regenerate` (`setup.sh:2840-2842`). Cualquier cambio a `vault.sh` exige rebuild + **DOCKER_E2E** (regla del proyecto: lib con COPY en el Dockerfile).
4. Tests a extender: `tests/vault-upgrade.bats` (upgrade aditivo), `tests/vault.bats`; y el oráculo "skeleton-clean vault yields exactly 0 findings" (`wiki-graph.bats:98`) si cambia el skeleton.

### 5.7 Revisiones programadas: tres opciones [P]

| Opción | Modo | Cambio | Observación |
|---|---|---|---|
| A. Heartbeat con prompt de revisión | docker | `heartbeatctl set-prompt` (operador) | Cero código; pero un solo prompt para todos los ticks (§2.4), y el tick corre sin plugins; [I] MCP de proyecto probablemente disponibles, por verificar |
| B. Finding determinista `review_due` | ambos | `wiki_graph.sh`: nueva razón/kind cuando `next_review < hoy` (o `para: project` sin `next_review`); `.graph/findings.json`; el agente lo consume en la siguiente sesión como hace con `orphan` | Consistente con "script reports, agent fixes"; toca tests de conteo exacto (`wiki-graph.bats:65`) y de skeleton limpio (`:98`) + mirror + DOCKER_E2E |
| C. Línea de cron / timer nueva | docker: `heartbeatctl reload` (`:290-300` como molde); local: unidad `local-*.tpl` nueva + `local_schedule.sh` | Mayor costo; solo tiene sentido si el motor de revisión es determinista (B) o un `claude --print` propio | Un `claude --print` propio replicaría el heartbeat; evaluar reutilizar A |

Menor cambio real: **A + B**. B da la señal de "toca revisar" en ambos modos sin LLM; A (o la sesión interactiva) ejecuta la revisión.

---

## 6. Riesgos de colisión con lo existente

1. **"The only six" es un contrato de tres capas.** Prosa (`CLAUDE.md:32-46`; `docs/vault.md:50`; `docs/state-layout.md:104,120`), código (`wiki_graph.sh:111`, `:173`) y tests (`wiki-graph.bats:33`). Un tipo nuevo obliga a mover las tres a la vez **y** a entregar el cambio a vaults cuyo `CLAUDE.md` es co-evolucionado y nunca se sobreescribe (`vault.sh:52-57`; `docs/vault.md:141,171`). Ventana de divergencia inevitable: imagen nueva (linter acepta 7) con schema viejo en el agente (prohíbe 7), o al revés si el agente integra el delta antes del rebuild. Hay que fijar el orden (rebuild primero, delta después) y decir que en el intervalo `type: invalid` es esperado.
2. **`status` es un enum cerrado con semántica de frescura.** `draft|active|stale|superseded` (`CLAUDE.md:69`; `wiki_graph.sh:113,174`). Reusar `superseded` para "proyecto cerrado" o `stale` para "en pausa" corrompe el finding `stale` (que solo mira `active`, `:439`) y la prioridad de query ("prefer `status: active`", `:119`). Estado PARA en clave aparte.
3. **Normalization no es conocimiento.** Excluida de nodos (`:185`), sin `type` (`:162`), "never cited" (`CLAUDE.md:54`). Tentación a evitar: poner favorite problems, checklists de revisión o "estándares de área" ahí porque "son reglas". Quedarían fuera del grafo, no citables y sin backlinks. Van en `wiki/` como páginas de conocimiento.
4. **`.graph/` no se respalda y es JSON-only.** Regenerable, excluido de backup y qmd (`docs/vault.md:248-250`; `state-layout.md:160`; invariante L1 en `wiki-graph.bats:142`). Un "dashboard PARA" o "reporte de revisión" en markdown **no** puede vivir ahí; y el agente no debe escribir en `.graph/` (derivado, read-only, `claude-md.tpl:214`). Cualquier derivado nuevo de 037 (p. ej. `review.json`) debe ser JSON, atómico y producido solo por el runner.
5. **El linter enumera `wiki/` recursivo y solo `wiki/`.** Dentro: cada `*.md` es nodo validado (`:321`). Fuera: invisible, y los wikilinks hacia allá son `broken_link` (`:514`). Un directorio `packets/` o `reviews/` en la raíz del vault "funciona" para backup y qmd pero castiga la navegación (§5.4).
6. **Drift de índice.** Toda página nueva bajo `wiki/` debe aparecer en `index.md` o dispara `missing_from_index` (`:543`) → WARN local. Más páginas (fichas de proyecto, packets, revisiones) = más disciplina de índice. Las secciones PARA no cambian esto; ayudan.
7. **qmd indexa todo el markdown del vault.** Máscara `**/*.md` sobre la raíz (`qmd_index.sh:379`). Revisiones semanales acumuladas, packets y plantillas nuevas entran al índice y al hash de reindex/backup (`vault_hash`, `backup_vault.sh:100-109`). [I] Riesgo de dilución del retrieval con notas de proceso; no medido. Mitigación posible: que las revisiones se registren en `log.md` (ya indexado, una sola página) en vez de un archivo por semana.
8. **`synthesis` "should be rare" y ya recibe los lint reports.** `CLAUDE.md:108,162`. Si además recibe packets y revisiones, deja de ser raro y el tipo pierde significado. Los nombres con fecha solo están permitidos para "lint-YYYY-MM-DD.md and similar dated artifacts" (`:200`): `review-YYYY-MM-DD.md` encaja en la letra, no en el espíritu de "one topic per file".
9. **Doble escritura con auto-memoria `project_*`.** Prohibida explícitamente (`CLAUDE.md:183`; `claude-md.tpl:193`). [I] Los agentes de la flota ya tienen `project_*` en su `MEMORY.md` porque siguen esa plantilla. 037 necesita la regla de routing (§3.3) **y** una nota de migración (qué hacer con los `project_*` existentes), o los dos sistemas divergen en silencio.
10. **`entity` ya incluye "project".** (`CLAUDE.md:39`; `_templates/entity.md:14`). Es una ventaja (no hace falta tipo nuevo) y un riesgo: sin clave `para:` no se distingue un proyecto activo de una organización o herramienta en `wiki/entities/`. La clave es obligatoria si se elige esa vía.
11. **Inmutabilidad de `raw_sources/` vs Progressive Summarization.** Las capas 2-3 de Forte subrayan y ennegrecen el texto fuente. Aquí la fuente es intocable (`CLAUDE.md:26`; `README.md:3-5`) y no se admite contenido generado por LLM en esa carpeta (`README.md:18`). El sidecar `<filename>.md` existe solo para binarios (`README.md:57-58`) y no es un precedente válido para highlights. Las capas viven en el `summary` (§5.2).
12. **Turnos más largos en canales de chat.** Un ingest con filtro + destilación + packets, o una revisión mensual sobre un vault grande, alarga el turno; el indicador de typing se corta a los 5 min y el plugin avisa al chat (`claude-md.tpl:157`). [I] Duración no medida; existe `TELEGRAM_TYPING_MAX_MS` como perilla.
13. **La entrega del schema es una petición al agente, no una garantía.** El delta 0.8.0 se deposita en `_templates/` y "Integrate the sections below into THIS vault's CLAUDE.md" (`schema-updates-0.8.0.md:3-7`). No hay test ni finding que verifique que el `CLAUDE.md` del agente incorporó algo [H, no existe tal chequeo en `wiki_graph.sh`]. 037 hereda esa incertidumbre; conviene un finding determinista mínimo (p. ej. "delta pendiente: archivo presente y sentinel aplicado hace > N días") o aceptar el hueco explícitamente.
14. **Local mode no tiene heartbeat.** (`claude-md.tpl:92`). Cualquier revisión programada con LLM es docker-only salvo que 037 añada una unidad; lo determinista (timers) sí es simétrico (`docs/heartbeatctl.md:395-403`, `:476-479`).
15. **Claves muertas en `agent.yml`.** `vault.initial_sources` y `vault.schema.*` (`setup.sh:1287,1296-1297`, sin lectores). Si 037 introduce config nueva bajo `vault:`, decidir primero si estas se reciclan, se documentan como reservadas o se retiran, para no acumular un tercer key sin consumidor. El schema (`scripts/lib/schema.sh:70-73,84-88`) solo conoce `enabled`, `mcp.enabled`, `qmd.enabled`, `wiki_graph.enabled`, `path`, `backup_schedule`, `qmd.version`, `qmd.schedule`, `wiki_graph.schedule` [H].

---

## Anexo A — Inventario de fuentes leídas completas

`modules/vault-skeleton/{CLAUDE.md,index.md,log.md,raw_sources/README.md}`, `modules/vault-skeleton/_templates/{comparison,concept,entity,normalization,overview,source,summary,synthesis}.md`, `modules/vault-deltas/schema-updates-0.8.0.md`, `docs/vault.md` (730 líneas), `docs/heartbeatctl.md` (sección Vault RAG `:381-488` + grep general), `docs/state-layout.md` (`:34-162`, `:246-266` + grep general), `modules/claude-md.tpl` (275 líneas), `scripts/heartbeat/heartbeat.sh` (392 líneas). Verificaciones puntuales: `scripts/lib/wiki_graph.sh` (`:100-265`, `:265-380`, `:382-495` + grep), `scripts/lib/vault.sh` (completo), `scripts/lib/backup_vault.sh` (grep), `scripts/lib/qmd_index.sh` (grep), `scripts/lib/schema.sh` (grep), `modules/mcp-json.tpl` (completo), `docker/crontab.tpl`, `docker/scripts/heartbeatctl` (grep), `docker/scripts/start_services.sh` (grep), `docker/Dockerfile` (COPY), `setup.sh` (`:1629-1735` + grep), `specs/014-wiki-graph-rag/contracts/graph-artifacts.md` (grep), `tests/wiki-graph.bats` (nombres de tests).

## Anexo B — Lo que NO se verificó

- Ningún vault real de la flota (donna, linus, rodri-cenco-admin, ferrari-admin, mclaren-admin): el informe describe el skeleton y el código, no el estado co-evolucionado de cada `CLAUDE.md` vivo ni sus `MEMORY.md`.
- Si la sesión del heartbeat carga los MCP de proyecto (`vault`, `qmd`) con plugins deshabilitados (§2.4, [I]).
- Duración real de un ingest/lint extendido bajo el cap de typing (§6.12, [I]).
- Efecto en el retrieval de qmd de indexar `_templates/` y notas de proceso (§2.2, §6.7, [I]).
