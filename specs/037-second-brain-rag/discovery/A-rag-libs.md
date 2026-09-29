# 037 — Discovery A: mapa técnico de las librerías RAG del launcher

**Fecha:** 22-09-2026 · **Repo:** `agentic-pod-launcher` en `main` (`70214d9`) · **Alcance:** solo lectura.

Convención de este informe:

- **[H]** = hecho verificado leyendo el archivo indicado (`archivo:línea`).
- **[I]** = inferencia razonable a partir de hechos verificados; no medida en runtime.
- **[NV]** = no verificable en este host (por ejemplo, semántica interna de `@tobilu/qmd`, que no está instalado aquí: `~/.cache/qmd` no existe).

Notas de contexto sobre el estado del árbol:

- `docker/scripts/qmd_watch.sh` **no existe en el repo** [H: `ls`]. El canónico es `scripts/qmd_watch.sh` [H: `git ls-files`], y `setup.sh::mirror_catalog_to_docker` lo copia a `docker/scripts/qmd_watch.sh` en cada scaffold/`--regenerate` [H: `setup.sh:1641,1680-1681`]; el `Dockerfile` lo espera ahí [H: `docker/Dockerfile:244`]. Lo mismo ocurre con `qmd_index.sh`, `wiki_graph.sh`, `backup_vault.sh`, `rag_obs.sh`, `vault.sh`, el skeleton y los deltas [H: `setup.sh:1655-1690`, `docker/Dockerfile:261-290`].
- Las libs RAG son **una sola fuente** en `scripts/lib/` y se espejan a la imagen; cualquier cambio en ellas exige `DOCKER_E2E` (regla del repo, `CLAUDE.md` raíz).

---

## Resumen ejecutivo

1. El sistema ya implementa completo el patrón Karpathy: skeleton de vault con `raw_sources/` inmutable, `wiki/` de 6 tipos + `wiki/normalization/`, `CLAUDE.md` del vault como schema (capa 3), `index.md`, `log.md`, grafo derivado `.graph/{graph,backlinks,findings}.json` y búsqueda híbrida QMD. Todo lo que **escribe conocimiento** lo hace el agente (LLM); todo lo que **deriva, indexa, respalda y audita** es determinista (bash + awk + jq + qmd).
2. El parser del grafo (`wiki_graph.sh`) **ignora silenciosamente cualquier clave de frontmatter que no conoce** [H: `scripts/lib/wiki_graph.sh:202-227`]: agregar `para:`, `layer:`, `project:` u otros campos **no rompe nada** ni genera `frontmatter_violation`. Pero tampoco los extrae: para que lleguen a `graph.json` hay que tocar tres puntos (rama awk, registro `N`, proyección jq).
3. El índice QMD es **una sola colección `vault` con máscara `**/*.md` y sin exclusiones** [H: `qmd_index.sh:372,379`]: entran `CLAUDE.md`, `index.md`, `log.md`, `_templates/*.md`, `raw_sources/**/*.md` y `wiki/normalization/*.md`. `.graph/` queda fuera solo porque es JSON.
4. Dos "review hooks" ya existen y son reutilizables: el cron/timer del wiki-graph (cada 6 h) y el heartbeat (único tick LLM programado, solo docker). No hay hoy ningún pase LLM programado sobre el vault; el lint semántico depende de que el agente lo inicie.
5. Pins duros: `@tobilu/qmd` **2.5.3**, `sqlite-vec` **0.1.9** (compilado para musl con SHA256 fijo), `@bitbonsai/mcpvault` **0.12.0** (tres lugares que deben coincidir). Cambiar qmd re-dispara un `bun install` con compilación nativa de `node-llama-cpp` y arriesga el parsing de las cadenas `Pending: N` / `All content hashes already have embeddings` de las que depende el loop de embed.

---

## 1. Cada lib: propósito, funciones públicas, contrato, estado que escribe

### 1.1 `scripts/lib/backup_vault.sh` (228 líneas) — resolver de vault, hash y backup

Es la base que las otras dos libs reutilizan (resolver + hash) [H: `qmd_index.sh:27-32`, `wiki_graph.sh:22-27`].

| Función | Entrada | Salida / efecto | Ref |
|---|---|---|---|
| `vault_resolve_root [agent_yml]` | `VAULT_ROOT_OVERRIDE` (gana si está seteada) o `agent.yml` | Docker: `.state/.vault` → `/home/agent/.vault`; otro path → `/home/agent/<path sin .state/>`. Vacío si `vault.enabled != true` | `:26-48` |
| `vault_exclude_patterns` | — | `.git`, `.obsidian/cache`, `.obsidian/workspace*.json`, `.obsidian/.trash`, `.trash`, `*.sync-conflict-*` | `:52-61` |
| `vault_list_markdown DIR` | dir | `find ... -prune -o -type f -name '*.md' -print0`, ordenado `LC_ALL=C` | `:86-95` |
| `vault_hash DIR` | dir | sha256 sobre `FILE <rel>\n<contenido>\nEND` de cada `.md` (renombrar cuenta como cambio) | `:100-110` |
| `vault_last_hash STATE` | state file | `.hash` o vacío | `:122-126` |
| `vault_prepare_clone URL` | fork url | clon `--no-checkout` en `${VAULT_BACKUP_CACHE_DIR:-/home/agent/.cache/agent-backup}/vault-clone` | `:130-141` |
| `vault_commit_and_push CLONE VAULT` | — | worktree `backup/vault` (orphan si no existe), **borra el árbol** y copia el subset `.md`; stdout `<sha>` o `-` | `:146-212` |
| `vault_write_state STATE HASH COMMIT PUSH_TS` | — | atómico tmp+mv | `:215-228` |

**Estado:** `<ws>/scripts/heartbeat/vault-backup.json` [H: `heartbeatctl:62`]
```json
{"hash":"<sha256>","last_commit":"<sha|''>","last_push":"<ISO8601|''>"}
```
Sin campo `schema`. `hash` es el mismo criterio que usa el reindex qmd (ver 1.2).

### 1.2 `scripts/lib/qmd_index.sh` (566 líneas) — índice QMD autogestionado

| Función | Contrato | Ref |
|---|---|---|
| `qmd_pkg [agent_yml]` | `@tobilu/qmd@<vault.qmd.version>`; default `2.5.3` si falta/`null` | `:49-58` |
| `qmd_cache_root` | `${QMD_CACHE_HOME:-$HOME/.cache/qmd}` | `:62` |
| `qmd_state_file` | `${QMD_INDEX_STATE_FILE:-/workspace/scripts/heartbeat/qmd-index.json}` | `:65` |
| `qmd_vault_dir [agent_yml]` | `QMD_VAULT_DIR` o `vault_resolve_root` | `:69-74` |
| `_qmd_enabled [agent_yml]` | 0 sii `vault.enabled == true` **y** `vault.qmd.enabled == true` | `:82-90` |
| `_qmd_ensure_prefix PKG` | instala `@tobilu/qmd` en `<cache>/pkg` con manifest fijo (`trustedDependencies: [better-sqlite3, node-llama-cpp]`), guardado por hash `.installed-hash`; `timeout ${QMD_INSTALL_TIMEOUT:-3600}`; flags `GGML_NATIVE=OFF`, `GGML_CPU_ARM_ARCH=armv8-a`; luego `_qmd_swap_sqlite_vec` | `:150-152, :175-229` |
| `_qmd_run PKG ARGS...` | ejecuta `<prefix>/node_modules/.bin/qmd ARGS` con `timeout ${QMD_CMD_TIMEOUT:-900}`; `LD_PRELOAD=bigstack.so` **solo** para `embed` y solo si existe | `:235-250` |
| `qmd_mcp_exec [PKG]` | `exec ... qmd mcp` sin timeout, con bigstack si existe | `:258-267` |
| `qmd_write_state STATE HASH STATUS [PENDING]` | atómico; `runs` autoincrementa; `pending` omitido → conserva el anterior (ausente = "desconocido") | `:286-313` |
| `qmd_setup_if_needed [agent_yml]` | fast-path por sentinel `<cache>/.qmd-setup-ok` + `index.sqlite`; flock `<cache>/.reindex.lock` | `:319-354` |
| `_qmd_setup_locked` | `collection add <vault> --name vault --mask '**/*.md'` (solo si no hay `index.sqlite`) → `update` → `embed` → sentinel | `:357-400` |
| `qmd_reindex [agent_yml]` | flock (mismo lock) + `_qmd_reindex_locked`; siempre `return 0` | `:405-433` |
| `_qmd_reindex_locked` | skip solo si `hash == last` **y** `pending == 0`; hash igual con pending>0/desconocido → reanuda embed sin `update`; hash distinto → `update` + loop | `:529-566` |
| `_qmd_pending_count PKG` | parsea `Pending: N` de `qmd status`; vacío + rc≠0 = desconocido | `:470-476` |
| `_qmd_embed_until_complete` | pasadas `qmd embed` hasta: cadena `All content hashes already have embeddings` o `pending==0` → `indexed`; sin progreso → `stalled`; cap `QMD_EMBED_MAX_PASSES=12` → `partial`; fallo → `error` (hash anterior preservado) | `:463, :484-521` |

**Estado:** `<ws>/scripts/heartbeat/qmd-index.json`
```json
{"hash":"<sha256 del vault>","last_run":"<ISO8601>","last_status":"indexed|skipped|error|partial|stalled","runs":42,"pending":0}
```
`pending` es opcional (pre-018) y su ausencia significa "desconocido → reanudar" [H: `:279-285`; contrato `specs/018-qmd-embed-completion/contracts/reindex-state.md`].

Archivos bajo `qmd_cache_root` (docker: `/home/agent/.cache/qmd` = `<ws>/.state/.cache/qmd` por el bind-mount; local: idéntico bajo el workspace): `index.sqlite`, `models/`, `pkg/` (prefijo bun), `.qmd-setup-ok`, `.reindex.lock`, `tmp/` (scratch: `qmd-install.err`, `qmd-setup.err`, `reindex.err`, `embed-pass.err`) [H: `:190, :204, :363, :487-492, :551`; `docs/vault.md:448-452`].

### 1.3 `scripts/lib/wiki_graph.sh` (565 líneas) — grafo derivado + lint estructural

| Función | Contrato | Ref |
|---|---|---|
| `wiki_graph_enabled [agent_yml]` | 0 sii `vault.enabled == true` y `vault.wiki_graph.enabled != false` (default-on) | `:49-60` |
| `wiki_graph_vault_dir` | `WIKI_GRAPH_VAULT_DIR` o `vault_resolve_root` | `:64-69` |
| `wiki_graph_dir VAULT` | `<vault>/.graph` | `:73` |
| `wiki_graph_state_file` / `wiki_graph_lock` | `${WIKI_GRAPH_STATE_FILE:-/workspace/scripts/heartbeat/wiki-graph.json}` / `.wiki-graph.lock` (fuera del vault) | `:77-84` |
| `wiki_graph_write_state STATE STATUS MS COUNTS [ERR]` | atómico | `:88-104` |
| `wiki_graph_run [agent_yml]` | flock no bloqueante (perdedor rc 91, no escribe estado); siempre `return 0` | `:267-288` |
| `_wg_run_locked` | pipeline: awk pasada A (aliases) → awk pasada B (todo + OCC) → `_wg_index_entries` → `allwiki` → `_wg_compute_stale` → `_wg_aggregate` (jq) → 3 escrituras atómicas → estado | `:291-382` |

**Artefactos** (`<vault>/.graph/`, JSON, `schema: 1`) [H: `:368-373, :495-565`]:

- `graph.json`: `{schema, generated_at, vault, nodes[], edges[]}`; nodo = `{id, type, status, created, updated, title_present}`; arista = `{from, to, kind: wikilink|related|source, broken}`.
- `backlinks.json`: `{schema, generated_at, pages: {<id>: {backlinks[], related_out[], co_sourced[], canonical_of[]}}}`.
- `findings.json`: `{schema, generated_at, findings: [{kind, page, detail}]}` con `kind ∈ {orphan, broken_link, frontmatter_violation, index_drift, stale, alias_occurrence}`, orden estable por `(kind, page, detail)`.

**Estado:** `<ws>/scripts/heartbeat/wiki-graph.json`
```json
{"schema":1,"last_run":"<ISO8601>","last_status":"ok|error","duration_ms":123,
 "counts":{"nodes":0,"edges":0,"orphans":0,"broken_links":0,"frontmatter_violations":0,"index_drift":0,"stale":0,"alias_occurrences":0},
 "error":""}
```

Temporales bajo `<ws>/scripts/heartbeat/tmp/wg.XXXXXX` (no `/tmp`) [H: `:309-314`].

### 1.4 `scripts/lib/vault.sh` (153 líneas) — siembra y upgrade del vault

| Función | Contrato | Ref |
|---|---|---|
| `vault_ensure_paths DIR` | `mkdir -p` | `:15-19` |
| `vault_seed_if_empty TARGET SKELETON [TODAY]` | `cp -R skeleton/. target/` solo si target vacío; reemplaza `SCAFFOLD_DATE` en `log.md` | `:33-50` |
| `vault_seed_missing TARGET SKELETON DELTAS [TODAY]` | upgrade **aditivo** de un vault poblado: crea `wiki/normalization/`, copia `_templates/normalization.md` si falta, deposita `_templates/schema-updates-0.8.0.md` gateado por marcador oculto `_templates/.schema-updates-0.8.0.applied` y agrega línea a `log.md`; **nunca toca `CLAUDE.md`**; lista explícita, no walk del skeleton | `:70-112` |
| `vault_backup_and_reseed` | `mv target target.backup-<ts>` + seed | `:126-141` |
| `vault_log_append VAULT OP TITLE [TODAY]` | `## [YYYY-MM-DD] <op> \| <title>` al final de `log.md` | `:146-153` |

`vault_log_append` **no tiene ningún llamador** en `setup.sh`, `scripts/`, `docker/` ni `modules/` [H: grep; solo aparece en un comentario `start_services.sh:27`].

### 1.5 `scripts/lib/rag_obs.sh` (39 líneas) — observabilidad compartida

- `redact_secrets` (filtro stdin, sed ERE portable: `sk-ant-*`, `gh[pousr]_*`, tokens Telegram `<digits>:<20+>`, `*_TOKEN|KEY|SECRET|PASSWORD|PAT=`) [H: `:18-24`].
- `scratch_dir BASE` → `BASE/tmp` (o `${TMPDIR:-/tmp}` si no puede crearlo) [H: `:30-39`].

Regla: **redactar antes de truncar** (`qmd_index.sh:438-446`, `wiki_graph.sh:355-357`).

### 1.6 `docker/scripts/qmd-mcp` (23 líneas) y `scripts/qmd_watch.sh` (84 líneas)

- `qmd-mcp`: sourcea `qmd_index.sh` y hace `qmd_mcp_exec` [H: `:13-23`]. Es el `command` del MCP `qmd` en docker [H: `setup.sh:2477`, `modules/mcp-json.tpl:73-77`]. Equivalente local: `scripts/local/agent-qmd-mcp.sh` [H: `modules/local-qmd-mcp.sh.tpl`].
- `qmd_watch.sh`: `inotifywait -r -m -q -e modify,create,delete,move "$vault_dir"`; debounce `QMD_WATCH_DEBOUNCE=15` s; al asentarse dispara `${QMD_REINDEX_CMD:-heartbeatctl qmd-reindex}`; backoff 5 s al morir el stream [H: `:20-25, :44, :52-77`]. Sale 0 sin inotifywait (el cron es el respaldo) [H: `:39-43`].

### 1.7 Orquestación: `start_services.sh`, `heartbeatctl`, `agentctl`

- `start_services.sh::seed_vault_if_needed` (boot, usuario `agent`): resuelve `vault_root`, `force_reseed`, `vault_seed_if_empty`, `vault_seed_missing`, symlink `/home/agent/vault` [H: `:83-142`]. `boot_side_effects` lanza `qmd_setup_if_needed` en background [H: `:183-187`]. Watcher: `qmd_watch_start` tras la sesión inicial y respawn por tick de 2 s si el PID murió (pidfile en `$WATCHDOG_RUNTIME_DIR`, tmpfs) [H: `:196-236, :1228-1231, :1264, :1345`].
- `heartbeatctl reload` renderiza el crontab con hasta 7 líneas: heartbeat, `backup-identity` (30 3), `backup-vault` (default `0 * * * *`), `backup-config` (30 3), token-health (0 *), `qmd-reindex` (default `*/5 * * * *`), `wiki-graph` (default `20 */6 * * *`) [H: `:225-312`]. Subcomandos: `backup-vault [--dry-run|--gc]` [H: `:708-798`], `qmd-reindex [--dry-run]` [H: `:948-995`], `wiki-graph` (re-ejecuta el runner e imprime counts) [H: `:1000-1020`].
- `agentctl` docker: `heartbeat <sub>` es `docker exec -u agent <agent> heartbeatctl "$@"` [H: `:865-873`]; el `doctor` docker solo verifica que `/home/agent/.vault/CLAUDE.md` exista y la frescura del backup (`DOCTOR_VAULT_MAX_AGE_HOURS=25`) [H: `:580-590, :696-700`]. `agentctl` local: `status` con bloque `vault/RAG` (timers, índice presente, último reindex, counts del grafo) [H: `:1107-1151`] y `doctor` con contrato de degradación (WARN integridad/error, FAIL runner muerto a 2× intervalo) [H: `:1155-1236`]; `heartbeat qmd-reindex|backup-vault|wiki-graph` ejecutan los wrappers locales directo (rechaza `--dry-run` en reindex) [H: `:1565-1596`].

---

## 2. Invocación del indexador qmd

**Comandos exactos** (todos vía `_qmd_run`, es decir `timeout 900 <cache>/pkg/node_modules/.bin/qmd ...`) [H: `qmd_index.sh:235-250`]:

| Fase | Comando | Cuándo | Ref |
|---|---|---|---|
| Setup (una vez) | `qmd collection add "<vault_dir>" --name vault --mask '**/*.md'` | solo si no existe `<cache>/index.sqlite` | `:377-382` |
| Setup | `qmd update` | siempre en setup | `:389` |
| Setup | `qmd embed` (con `LD_PRELOAD=bigstack.so` en musl) | siempre en setup; sentinel al éxito | `:393-397` |
| Reindex | `qmd update` | solo si `vault_hash` cambió | `:553-561` |
| Reindex | `qmd embed` × N pasadas + `qmd status` entre pasadas | hasta `indexed`/`stalled`/`partial` (cap 12) | `:484-521` |
| Lectura | `qmd mcp` (stdio, sin timeout) | por Claude, vía `.mcp.json` | `:258-267` |

Nombre de colección: `${QMD_COLLECTION_NAME:-vault}` [H: `:372`]. No hay `--mask` distinto ni segunda colección.

**Qué se indexa:** todo `.md` bajo el vault raíz (la máscara es `**/*.md` sin exclusiones): `CLAUDE.md`, `index.md`, `log.md`, `_templates/*.md` (incluido el delta `schema-updates-0.8.0.md`), `raw_sources/**/*.md`, `wiki/**/*.md` y `wiki/normalization/*.md` [H: comando `:379`; el contrato 014 declara explícito que normalization "entra a la colección qmd", `specs/014-wiki-graph-rag/contracts/normalization-pages.md:74-78`].

**Qué se excluye:** `.graph/` solo porque contiene exclusivamente JSON [H: contrato `specs/014-wiki-graph-rag/contracts/graph-artifacts.md:10-14`]. Si qmd omite directorios ocultos (`.obsidian/`, `.trash/`) al expandir el glob es **[NV]** (depende de la implementación de qmd 2.5.3).

**Inconsistencia de criterios [I]:** el debounce del reindex usa `vault_hash`, que **sí** excluye `.trash`, `.obsidian/*`, `*.sync-conflict-*` [H: `backup_vault.sh:52-61,100-110`], mientras la colección qmd no excluye nada. Un cambio solo en `.trash/*.md` no cambia el hash → no dispara `update`; un `.md` de conflicto de Syncthing sí entra al índice en el próximo `update` provocado por otra edición. Efecto práctico bajo, pero conviene alinear ambos criterios si 037 agrega carpetas (p. ej. `archives/`).

**Superficie del CLI 2.5.3** (fuente secundaria, README citado por el research de 010): `collection add/remove/rename/list`, `embed`, `update`, `search`/`vsearch`/`query`, `status`, `cleanup`, `mcp` [H: `specs/010-self-managing-rag/research.md:13`]. Los nombres de herramientas que expone `qmd mcp` **no están documentados en el repo** [H: grep en `docs/vault.md` sin resultados] → **[NV]**. Que la búsqueda pueda filtrar por frontmatter o por subcarpeta también es **[NV]**.

**Flags de embed/status:** ninguno adicional; el loop confía en dos cadenas literales del stdout de qmd: `Pending:[[:space:]]*[0-9]+` [H: `:473`] y `All content hashes already have embeddings` [H: `:498`] (ambas ubicadas en `cli/qmd.js` de 2.5.3 según `specs/018-qmd-embed-completion/research.md:54-56`). La causa del loop es el tope hardcodeado de 30 min por sesión de embed en `dist/store.js` (`maxDuration: 30*60*1000`) [H: `research.md:11-17`].

**Storage y env que el binario honra** [H: `modules/local-qmd-reindex.sh.tpl:32-41`, `setup.sh:2453-2467`]: `XDG_CACHE_HOME` (índice + modelos) y `QMD_CONFIG_DIR` (registro de colecciones); `QMD_CACHE_HOME` lo lee **solo la lib bash**. Docker deja `env: {}` en el MCP (todo cae en `$HOME/.cache/qmd`); local exporta los tres.

---

## 3. El grafo derivado

### 3.1 Qué extrae el parser awk (`_wg_structural_awk`, `wiki_graph.sh:108-263`)

**Identidad del nodo:** `id` = path relativo a `wiki/` sin `.md` (`compute_id`, `:152-157`). Páginas bajo `wiki/normalization/` se marcan `isnorm` y no son nodos [H: `:185`].

**Frontmatter:** solo el primer bloque `---`…`---` que abre en la línea 1 [H: `:191-192`]. Gramática aceptada:

| Forma | Claves donde se procesa | Ref |
|---|---|---|
| `key: valor` (escalar, comillas simples/dobles despojadas) | `type`, `status`, `created`, `updated`, `title` (**solo presencia**), `canonical`, `match_case`, `entity` | `:202-213` |
| `key: [a, b]` (flow array) | `related` (con `unwrap` de `[[...]]`), `sources`, `aliases` | `:214-225` |
| `- item` (dash array, continuación de la clave anterior) | `related`, `sources`, `aliases` | `:195-201` |
| cualquier otra clave `^[A-Za-z_]+[ \t]*:` | **ignorada en silencio** (setea `curkey`, no emite nada) | `:202-205, :227` |
| líneas indentadas (mapa anidado, block scalar) | no matchean `^[A-Za-z_]+` → **ignoradas en silencio**, sin violación | `:202, :227` |

Regex de claves: `^[A-Za-z_]+[ \t]*:` → una clave con guion (`para-kind:`) o dígito **no** matchea y se ignora; `para_kind:` sí matchearía como clave (y también se ignoraría por no tener rama) [H: `:202`].

**Cuerpo:** salta fences ``` (toggle) [H: `:230-231`]; extrae cada `[[...]]` con `unwrap` (descarta `|display` y `#anchor`) como arista `wikilink` [H: `:233-238`]; construye `cbody` sin tokens de wikilink para el escaneo de aliases [H: `:240-242`].

**Registros TSV emitidos** [H: `:158-180`]: `N id type status created updated title_present`, `V id razón`, `E from to kind`, `SRCN id status updated`, `AL canonical alias match_case entity`, `OCC page alias canonical`.

**Validaciones (`V`)** [H: `:161-174`]: `title: key missing`; `type: missing`; `type: invalid '<x>'` contra `VALIDTYPE = summary entity concept comparison overview synthesis` [H: `:111-112`]; `status: invalid` contra `draft active stale superseded` [H: `:113-114`]; en normalization: `type key not allowed`, `canonical missing/empty`, `aliases missing/empty`. Un nodo con `type` inválido **sigue siendo nodo** [H: fixture `tests/fixtures/vault-graph/wiki/synthesis/badfm.md`, test `wiki-graph.bats:109`].

### 3.2 Agregación jq (`_wg_aggregate`, `:495-565`)

- `broken` = arista `wikilink|related` cuyo destino no es nodo [H: `:514`].
- `backlinks` = entrantes `wikilink|related` no rotas [H: `:518-520`]; `related_out` [H: `:522-523`]; `co_sourced` = páginas que comparten al menos un `sources:` [H: `:525-528`]; `canonical_of` = aliases de reglas cuyo `entity` apunta al nodo [H: `:530-531`].
- Findings: `orphan` (sin backlinks) [H: `:539`], `broken_link` [H: `:540`], `frontmatter_violation` [H: `:541`], `index_drift` bidireccional `missing_file`/`missing_from_index` [H: `:542-543`], `stale` [H: `:544`], `alias_occurrence` [H: `:545`].
- `stale` (`_wg_compute_stale`, `:433-455`): solo nodos `status: active` con `updated:` parseable; marca si el mtime de algún `sources:` existente en disco supera `updated + 86400`.
- `index.md`: entradas = bullets `- [[type/slug]]` fuera de comentarios HTML, backticks y placeholders `<...>` [H: `:401-428`].

### 3.3 Cómo se consume

- El agente lee `.graph/backlinks.json` en el paso "Expand via the graph" del protocolo query (vecinos a 1 salto: `backlinks`, `related_out`, `co_sourced`, `canonical_of`) y `canonical_of` en ingest [H: `modules/vault-skeleton/CLAUDE.md:98-102, :120-125`]. No hay MCP ni servicio: lectura directa con `jq`/`Read`.
- `findings.json` es la cola de trabajo del lint estructural; el agente aplica los arreglos, el runner nunca edita el wiki [H: `CLAUDE.md` del vault `:140-146`; test `wiki-graph.bats:117`].
- `agentctl status/doctor` (local) leen `wiki-graph.json` (counts y frescura) [H: `agentctl:1137-1143, :1204-1229`]; docker solo tiene el state file + `logs/wiki-graph.log` [H: `specs/014-wiki-graph-rag/contracts/mode-parity-ops.md:67-73`].

### 3.4 Drift documentado entre contrato y código [H]

El contrato `graph-artifacts.md:31-33` promete nodos con `title` y `tags`; el código emite `title_present` (booleano) y **no extrae `tags`** en ninguna parte (`grep tags scripts/lib/wiki_graph.sh` vacío; proyección `:506`). Si 037 quiere usar `tags:` (ya está en todas las plantillas del skeleton) como portador de PARA, hoy el grafo no lo ve.

---

## 4. Puntos de extensión reales (sin romper parser ni índice)

### 4.1 Metadatos nuevos en frontmatter (por ejemplo `para:`, `layer:`, `project:`)

- **Seguro hoy:** cualquier clave plana `key: valor` o `key: [a, b]` adicional es ignorada por el parser sin violación [H: `wiki_graph.sh:202-227`]. Todas las plantillas ya traen `tags: []` sin consumidor [H: `_templates/*.md:9`].
- **Restricciones de forma:** usar claves `[A-Za-z_]+` (sin guion), escalares o flow arrays; **evitar mapas anidados y block scalars** (se ignoran, no se validan). Los dash arrays solo funcionan para `related|sources|aliases` [H: `:195-201`].
- **Para extraerlos al grafo** (tres toques, todos en `wiki_graph.sh`): rama en el parse de claves (`:206-225`), campo extra en el registro `N` (`:170`) y en la proyección jq de `$nodes` (`:506`); opcionalmente nuevos findings (`:539-547`) y counts (`:553-562`) + counts por defecto en `wiki_graph_write_state` (`:94`) + consumidores en `agentctl` (`:1141`, `:1226-1228`).
- **Validación de valores** (p. ej. `para ∈ {project, area, resource, archive}`): mismo patrón que `VALIDTYPE`/`VALIDSTATUS` (`:110-115`) emitiendo `V` [I: mecanismo claro; no hay test que lo cubra aún].
- **Costo de compatibilidad:** los oráculos de `tests/wiki-graph.bats` fijan counts exactos sobre `tests/fixtures/vault-graph` [H: `:65-75`]; agregar findings nuevos con count > 0 sobre ese fixture rompe esos tests (se ajustan; es esperado).

### 4.2 Tipos de página o carpetas nuevas (p. ej. `wiki/projects/`, capas de destilación)

- `compute_id` ya acepta cualquier subcarpeta bajo `wiki/` [H: `:152-157`]; una página `wiki/projects/x.md` sería nodo `projects/x`.
- Sin tocar `VALIDTYPE` (`:111`), un `type: project` genera `frontmatter_violation` → degrada `doctor` a WARN en local [H: `agentctl:1226-1228`] y contradice la regla "solo seis tipos" del schema del vault [H: `CLAUDE.md` del vault `:32-46`]. Alternativa sin nuevo tipo: mantener `type` en los seis y poner la dimensión PARA en una clave aparte (`para:`) o en `tags`.
- Superficie a tocar si se agrega tipo: `VALIDTYPE`, skeleton (`modules/vault-skeleton/wiki/<dir>/.gitkeep`, `_templates/<tipo>.md`, sección en `index.md`, tabla en `CLAUDE.md`), y upgrade aditivo para vaults existentes vía `vault_seed_missing` con **nuevo marcador oculto** y nuevo delta bajo `modules/vault-deltas/` [H: patrón `vault.sh:70-112`; contrato `vault-additive-upgrade.md`]. El `CLAUDE.md` del vault poblado **nunca** se reescribe: se deposita un delta y el agente integra.

### 4.3 Artefactos derivados nuevos (p. ej. `.graph/para.json`, `.graph/review-queue.json`)

- Regla dura: dentro de `.graph/` solo extensiones no-`.md` [H: `graph-artifacts.md:10-14`]; escritura atómica con `_wg_atomic_write` [H: `wiki_graph.sh:484-491`].
- Efecto colateral [I, cadena de hechos]: el watcher vigila el vault completo (`-r` sobre `vault_dir`, `qmd_watch.sh:77`), así que cada escritura en `.graph/` marca `dirty` y, 15 s después, dispara `heartbeatctl qmd-reindex`; como el hash `.md` no cambió y `pending==0`, termina en `skipped` con `runs++` [H: `qmd_index.sh:538-541`]. Es barato, pero cada artefacto derivado nuevo suma un tick vacío. Si 037 genera derivados con frecuencia, conviene sacarlos del vault o excluir `.graph/` en el `inotifywait` (`@<dir>` de inotify-tools: [NV] en esta versión Alpine).

### 4.4 Claves nuevas en `agent.yml`

Patrón vigente (feature 014 como molde): heredoc del wizard (`setup.sh:1282-1297`), backfill en `regenerate()` con `has()` (regla del `CLAUDE.md` raíz), `scripts/lib/schema.sh` (`_SCHEMA_BOOLEANS` `:65-74`, `_SCHEMA_OPTIONAL_NONEMPTY` `:81-89`), placeholders derivados en `setup.sh` (molde `WIKI_GRAPH_ENABLED/SCHEDULE/TIMER_ONCALENDAR`, `:2515-2545`) y `known_external` en `tests/schema.bats` [H: `mode-parity-ops.md:84-90`]. Tres claves ya existentes **sin consumidor** que pueden reutilizarse: `vault.initial_sources`, `vault.schema.frontmatter_required`, `vault.schema.log_format` [H: grep sin llamadores fuera del heredoc y de fixtures e2e].

### 4.5 Tareas programadas nuevas

Docker: octava línea en `heartbeatctl::cmd_reload` (molde `wiki_graph_line`, `:294-301`) + subcomando + `Dockerfile` COPY si es image-baked + `mirror_catalog_to_docker`. Local: trío `modules/local-<x>.{sh,service,timer}.tpl` + render en `setup.sh` (`:2750-2761`, `:3008-3027`) + `cron_to_systemd_calendar` (formas soportadas: `*/N * * * *`, `M * * * *`, `M */N * * *`, `M H * * *` — **no hay forma semanal `M H * * D`**; cae a default con marcador `.fallback` [H: `scripts/lib/local_schedule.sh:14-19, :44-47`]) + `AUX_UNITS` del kill-switch (`modules/local-killswitch.sh.tpl:23-25`) + healthcheck + `agentctl` status/doctor/`cmd_local_heartbeat`.

### 4.6 API del agente para editar metadatos

MCPVault expone `get_frontmatter`, `update_frontmatter`, `manage_tags`, `patch_note`, `search_notes`, `get_vault_stats` entre 14 herramientas [H: `docs/vault.md:346-350`]; además herramientas nativas `Read/Write/Edit/Glob/Grep` sobre el path del vault. Un "distill pass" agéntico puede operar solo con esto; nada del código bash escribe páginas del wiki.

---

## 5. Restricciones

### 5.1 Determinista (sin LLM) vs dependiente del agente

| Determinista (bash/awk/jq/qmd) | Depende del agente (LLM) |
|---|---|
| Siembra y upgrade aditivo del vault (`vault.sh`) | Ingest: clipping a `raw_sources/`, `summary`, entidades/conceptos, `index.md`, `log.md` [H: `CLAUDE.md` del vault `:87-112`] |
| `vault_hash`, backup a `backup/vault` | Normalización de terminología y creación de reglas [H: `:98-102`] |
| `qmd update`/`embed`/`status` (modelo local; sin red tras la descarga inicial [H: `qmd_index.sh:19`]) | Query con expansión por grafo y síntesis [H: `:114-134`] |
| Grafo + findings estructurales | Lint semántico (contradicciones, páginas faltantes) y aplicar findings [H: `:136-165`] |
| Watcher, cron/timers, doctor/status | Integrar deltas de schema en `CLAUDE.md` del vault [H: `vault-deltas/schema-updates-0.8.0.md:3-7`] |
| Heartbeat (`claude --print`, prompt por defecto "No tool use") — es el único tick LLM programado, y solo en docker [H: `heartbeat.sh:32`; `modules/claude-md.tpl:92`] | Cualquier "review"/"distill" hoy: iniciado por chat o por criterio del agente ("Maintenance triggers", `:185-195`) |

Nota sobre "rerank": `docs/architecture.md:287` describe QMD como BM25 + vector + LLM-rerank vía RRF "on-device"; que el rerank use un modelo local y no llame a red es **[NV]** en este host.

### 5.2 Docker vs local (paridad)

| Pieza | Docker | Local (systemd) | Ref |
|---|---|---|---|
| Vault path | `/home/agent/.vault` (bind de `.state/.vault`) | `<ws>/<vault.path>` vía `VAULT_ROOT_OVERRIDE` | `backup_vault.sh:26-48`; `setup.sh:2437-2438` |
| Siembra | boot, `start_services.sh:83-142` | scaffold/`--regenerate` `setup.sh:2812-2845` + `--login` | |
| Setup qmd | background en `boot_side_effects` | `nohup agent-qmd-reindex.sh --setup-only` en `--login` + auto-check en cada tick | `start_services.sh:183-187`; `local-login.sh.tpl:180-183`; `local-qmd-reindex.sh.tpl:51-55` |
| Reindex backstop | cron `*/5` → `heartbeatctl qmd-reindex` | `agent-<n>-qmd-reindex.timer` (`Persistent=true`) | `heartbeatctl:282-288`; `local-qmd-reindex.timer.tpl` |
| Watcher | `qmd_watch.sh` respawn 2 s, pidfile tmpfs | `agent-<n>-qmd-watch.service`, `Restart=always`, `ExecCondition=command -v inotifywait`, loop supervisado | `start_services.sh:196-236`; `local-qmd-watch.service.tpl:14-19`; `local-qmd-watch.sh.tpl:36-39` |
| Wiki-graph | cron `20 */6` | `agent-<n>-wiki-graph.timer` | `heartbeatctl:294-301`; `local-wiki-graph.timer.tpl` |
| Backup vault | cron `0 * * * *` | `agent-<n>-vault-backup.timer`, credenciales git del operador | `heartbeatctl:242-248`; `local-vault-backup.sh.tpl:6-8` |
| MCP `qmd` | `/opt/agent-admin/scripts/qmd-mcp`, `env: {}` | `scripts/local/agent-qmd-mcp.sh`, env `XDG_CACHE_HOME` + `QMD_CONFIG_DIR` | `setup.sh:2462-2480` |
| MCP `vault` (MCPVault) | **`/home/agent/.vault` hardcodeado**, ignora `vault.path` (quirk documentado) | `LOCAL_VAULT_DIR` | `setup.sh:2444-2452` |
| bigstack + sqlite-vec musl | sí (imagen) | no-op (glibc) | `qmd_index.sh:117-144, :246` |
| Heartbeat LLM, backup identity/config | sí | **no** | `claude-md.tpl:92, :235` |
| `doctor` RAG | mínimo (skeleton + frescura backup) | completo | `agentctl:580-590, :1155-1236` |
| Kill-switch | n/a | detiene timers + watcher, no la acción manual | `local-killswitch.sh.tpl:23-25` |

### 5.3 Pins y por qué no se tocan a la ligera

| Componente | Valor | Dónde vive | Riesgo al cambiar |
|---|---|---|---|
| `@tobilu/qmd` | `2.5.3` | `agent.yml vault.qmd.version` (heredoc `setup.sh:1293`), default `qmd_pkg` [H: `qmd_index.sh:56`], `docs` | Nuevo manifest → nuevo hash → `bun install` completo con compilación nativa de `node-llama-cpp` en musl (`timeout 3600`, `:184`); el loop de embed depende de dos cadenas literales del CLI (`:473, :498`) y del tope de 30 min por sesión; guardrail `tests/qmd-version-guard.bats` pareja qmd ↔ sqlite-vec |
| `sqlite-vec` | `0.1.9` + SHA256 `3acd67cb…cf61` | `docker/Dockerfile:62`, `docker/scripts/build-sqlite-vec.sh:16-19` | Prebuilt glibc no carga en musl; el swap apunta al path `node_modules/sqlite-vec-linux-arm64/vec0.so` [H: `qmd_index.sh:130`] → **[I]** en amd64 musl el swap sería no-op y `embed` quedaría sin vectores |
| `@bitbonsai/mcpvault` | `0.12.0` | literal en `modules/mcp-json.tpl:70`, `ARG MCP_VAULT_VERSION` `Dockerfile:213`, `AGENTIC_FLOOR_MCP_VAULT` `versions.sh:46` (drift-guard bats) | Tres lugares que deben coincidir; pre-warm en `/opt/npm-cache` (fuera de `.state`) |
| `bun` | floor `1.3.14` | `versions.sh:35`, resuelto a `agent.yml docker:` | Runtime de qmd y del prefijo |
| Deps transitivas de qmd (`node-llama-cpp`, `better-sqlite3`, `tree-sitter`) | no pineadas | resueltas por `bun install` en cada reinstalación (manifest solo pinea qmd, `:150-152`) | **[I]** dos instalaciones en fechas distintas pueden traer versiones nativas distintas |
| `QMD_EMBED_MAX_PASSES` | `12` | `qmd_index.sh:463` (deliberadamente no en `agent.yml`) | Solo tests |

### 5.4 Otras restricciones operativas

- Todo runner batch es **fail-silent** (siempre `exit 0`); la honestidad vive en los state files [H: `qmd_index.sh:405-433`, `wiki_graph.sh:265-288`].
- `/tmp` del contenedor es tmpfs de 100 MB: los runners exportan `TMPDIR` a disco (`.state/.cache/qmd/tmp`, `scripts/heartbeat/tmp`) [H: `rag_obs.sh:26-29`, `wiki_graph.sh:305-311`].
- Bash 3.2–5.3 en host y busybox/GNU/BSD en runtime: los parsers usan awk/sed portables; sin `mapfile`, sin `declare -A`.
- Cualquier cambio en `scripts/lib/{qmd_index,wiki_graph,vault,backup_vault,rag_obs}.sh` o `scripts/qmd_watch.sh` se espeja a la imagen → `DOCKER_E2E` obligatorio (regla del repo).

---

## 6. Ganchos existentes para una "review semanal" o un "distill pass"

| Gancho | Tipo | Qué ofrece hoy | Ref | Aptitud para 037 |
|---|---|---|---|---|
| Cron `wiki-graph` (`20 */6 * * *`) + timer local | determinista | Recalcula `findings.json` (orphans, broken, stale, drift, aliases) = **cola de revisión estructural** ya existente | `heartbeatctl:294-301`; `local-wiki-graph.timer.tpl` | Base natural: agregar findings PARA/destilación al mismo runner cuesta poco |
| Cron/timer nuevo (`heartbeatctl <sub>`) | determinista | Patrón completo de 7 líneas + unit local + kill-switch + doctor | `heartbeatctl:225-312`; `setup.sh:2750-3027` | Viable; ojo con `cron_to_systemd_calendar`: **sin forma semanal** (`M H * * 1` cae a fallback) [H: `local_schedule.sh:44-47`] |
| Heartbeat (`heartbeat.sh`) | **LLM** (`claude --print --permission-mode auto`) | Único tick LLM programado; cadencia por intervalo (`set-interval Nm\|Nh`), no cron libre; `CLAUDE_CONFIG_DIR` aislado, plugins deshabilitados, hooks `Stop`/`PreToolUse` eliminados; salida al notifier | `heartbeat.sh:32, :127-176, :213-214`; `heartbeatctl:196-224` | Docker-only [H: `claude-md.tpl:92`]. **[I]** al correr con `cwd=/workspace` cargaría los MCP de `.mcp.json` (vault/qmd); no está medido. Sirve para un "status del vault" semanal si se admite prompt custom, no para un pase pesado (timeout configurable, retries 0..5) |
| `CLAUDE.md` del vault, "Maintenance triggers" | agente | "lint tras 5+ ingests / mensual", reporte a `wiki/synthesis/lint-<date>.md`, entrada `lint` en `log.md` | `vault-skeleton/CLAUDE.md:185-195, :162-165` | Es la "review" actual; sin disparador automático. 037 puede formalizar aquí el weekly/monthly review de Forte |
| `log.md` parseable (`grep "^## \["`) | determinista | Historial `ingest\|query\|lint\|init\|other\|upgrade` fechado | `vault-skeleton/log.md:6-14`; `vault.sh:105` | Insumo para digest semanal determinista |
| `vault_log_append` | determinista | Escribe entradas `log.md`; **hoy sin llamadores** | `vault.sh:146-153` | Reutilizable para registrar pases automáticos |
| `vault_seed_missing` + deltas | determinista | Upgrade aditivo con marcador oculto y aviso en `log.md` | `vault.sh:70-112` | Vía canónica para introducir `_templates/project.md`, `wiki/projects/` o un delta "PARA" en vaults poblados |
| Watcher inotify (15 s) | determinista | Reindex inmediato ante cualquier cambio | `qmd_watch.sh:52-77` | Un "post-ingest" determinista podría colgarse aquí (p. ej. también `wiki-graph`), pero hoy solo dispara `qmd-reindex` |
| Hooks `Stop`/`PreToolUse` (028/031) | instalador jq aditivo en `settings.json` | Infra de hooks por turno ya cableada | `modules/stop-hook-install.sh.tpl` (no leído en este discovery; documentado en `CLAUDE.md` raíz) | **[I]** un `PostToolUse` sobre escrituras al vault podría lanzar `wiki-graph` al vuelo; no existe hoy |

---

## 7. Hallazgos y riesgos a considerar en el diseño de 037

1. **[H] `tags` no se extrae** aunque está en todas las plantillas y en el contrato del grafo. Si PARA/progressive-summarization se codifica en `tags`, hay que agregar la extracción (4.1).
2. **[H] Claves desconocidas se ignoran sin violación**: ventaja para introducir metadatos, pero también significa que un `para: projet` (typo) pasaría inadvertido hasta que exista una validación explícita.
3. **[H] QMD indexa `_templates/`, `CLAUDE.md`, `index.md`, `log.md` y `raw_sources/`**: una capa de destilación con muchas páginas intermedias ("Intermediate Packets") entra íntegra al índice. No hay máscara por carpeta ni segunda colección; filtrar por metadatos en la búsqueda es [NV].
4. **[I] Cada escritura bajo el vault (incluido `.graph/`) cuesta un tick de reindex** vía watcher (termina en `skipped`). Derivados frecuentes conviene sacarlos del vault o excluir el directorio.
5. **[H] Sin cron semanal en local**: `cron_to_systemd_calendar` no convierte `M H * * D`; una "review semanal" en local necesita extender el conversor o un default `OnCalendar` semanal propio.
6. **[H] MCPVault en docker apunta a `/home/agent/.vault` fijo**, no a `vault.path` (quirk preexistente, `setup.sh:2440-2446`).
7. **[H] Tres copias del pin de MCPVault** (template literal, Dockerfile ARG, versions.sh); cualquier bump toca las tres.
8. **[H] `vault.schema.frontmatter_required`/`log_format`/`initial_sources` son config muerta**: candidatos a reutilizar antes de inventar claves nuevas.
9. **[H] Las páginas de normalización tienen frontmatter propio** (`canonical/aliases/match_case/entity/notes`) fuera de los seis tipos; un "PARA" no debería aplicarse ahí (no son conocimiento).
10. **[NV] Semántica interna de qmd 2.5.3** (dotfiles en el glob, nombres de tools MCP, filtros de búsqueda, rerank local): verificar contra el tarball o en un contenedor antes de diseñar sobre ello.

---

## Anexo — inventario de archivos leídos

`scripts/lib/{qmd_index,wiki_graph,vault,rag_obs,backup_vault,schema,versions,local_schedule,mcp-catalog}.sh`, `scripts/qmd_watch.sh`, `scripts/agentctl` (secciones vault/qmd/wiki), `scripts/heartbeat/heartbeat.sh` (secciones aislamiento/prompt), `docker/scripts/{qmd-mcp,start_services.sh (vault/qmd/watchdog),heartbeatctl (crontab + subcomandos),build-sqlite-vec.sh}`, `docker/Dockerfile` (secciones RAG), `docker/crontab.tpl`, `modules/{mcp-json,heartbeat-conf,docker-compose.yml (grep),claude-md (grep)}.tpl`, `modules/local-{qmd-watch,qmd-reindex,qmd-mcp,wiki-graph,vault-backup}.sh.tpl` y sus units, `modules/local-{login,healthcheck,killswitch}.sh.tpl` (grep), `modules/vault-skeleton/**`, `modules/vault-deltas/schema-updates-0.8.0.md`, `setup.sh` (heredoc vault, mirror, placeholders mode-resolved, siembra local), `specs/010-self-managing-rag/contracts/*`, `specs/014-wiki-graph-rag/contracts/*`, `specs/018-qmd-embed-completion/contracts/*`, `specs/{010,018}/research.md` (grep), `docs/{vault,architecture}.md` (secciones RAG), `tests/fixtures/vault-graph/**`, `tests/wiki-graph.bats` (nombres de tests). No se leyó ningún `.env`, clave ni credencial.

