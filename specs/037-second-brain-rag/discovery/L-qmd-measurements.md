# L — Mediciones de `@tobilu/qmd` 2.5.3 para la feature 037

- Fecha de medición: 26-09-2026, 21:28 a 21:40 (hora local Santiago).
- Repo: `agentic-pod-launcher`, rama `037-second-brain-rag`, sin modificar (`git status --short` solo muestra `.specify/feature.json` y `specs/037-second-brain-rag/`, preexistentes).
- Host: macOS 26.3.1, arm64 (Apple M4 Pro, Metal), bun 1.3.12, Docker 29.8.0, `sqlite3` del sistema (sin extensión `vec0`).
- Lab desechable: `$LAB` = `/private/tmp/claude-501/-Users-rodrigo-hinojosa-Documents-Cencosud-Claude-Agents-agentic-pod-launcher/39e5ee01-c1c3-454a-ba47-6d398dabb108/scratchpad/qmd-lab`. Todo qmd corrió a través del wrapper `$LAB/q`, que exporta `HOME=$LAB/home`, `XDG_CACHE_HOME=$LAB/cache`, `XDG_CONFIG_HOME=$LAB/config`, `QMD_CONFIG_DIR=$LAB/qmdconfig`, `QMD_CACHE_HOME=$LAB/cache/qmd`, `TMPDIR=$LAB/tmp`.
- Etiquetas: **[H]** hecho medido (comando + salida), **[I]** inferencia, **[NV]** no verificable en esta sesión.

## Resumen ejecutivo

1. **Q1 — CLI.** [H] Los subcomandos no aceptan `--help` (`qmd collection --help` → `Unknown command`); la ayuda real es `qmd --help` y `qmd collection help`. `collection add <path> [--name N] [--mask GLOB]` es toda la superficie declarativa: **no existe `--ignore`/`--exclude`, y cualquier flag desconocido se ignora en silencio** (parseo no estricto). `collection include|exclude <name>` sí existe y escribe `includeByDefault: false` en el YAML. `ignore: [...]` SÍ existe en el archivo de colecciones y `update` lo honra, pero solo se puede poner editando el YAML. El archivo es `$QMD_CONFIG_DIR/index.yml` (fallback `$XDG_CONFIG_HOME/qmd/index.yml`, luego `~/.config/qmd/index.yml`). `--mask` acepta un solo string con extglob (`!(_templates|raw_sources)/**/*.md` funciona), llaves (`{wiki,raw_sources}/**/*.md`) y subdirectorio (`wiki/**/*.md`); un `!` inicial solo da 0 archivos.
2. **Q2 — Estado actual.** [H] Con `collection add <vault> --mask '**/*.md'` (lo que hace hoy `_qmd_setup_locked`) entran los 23 `.md` del vault sintético: `CLAUDE.md`, `index.md`, `log.md`, los 8 de `_templates/`, los 3 de `raw_sources/` y las 9 páginas de `wiki/`. Los paths quedan "handelizados": `_templates/` → `templates/`, `raw_sources/` → `raw-sources/`.
3. **Q3 — Recreación.** [H] `collection remove vault` borra en duro las filas de `documents` y el `content` huérfano, y deja `collections: {}` en el YAML; `collection add <vault>/wiki --name vault` re-indexa 9 y el conteo coincide con `wiki/`. No quedan documentos huérfanos; sí quedan **vectores huérfanos** en `content_vectors` (19 chunks) hasta `qmd cleanup`. Rechazos (nombre duplicado, mismo path+patrón, remove inexistente) salen con rc=1.
4. **Q4 — Reutilización de embeddings.** [H] **Se reutilizan.** Tras embed completo (28 chunks / 23 docs, 15 s wall en M4 Pro con Metal, modelo de 333,59 MB descargado a `$XDG_CACHE_HOME/qmd/models/`), remove + add de `wiki/` + `update` deja `Pending` ausente y `qmd embed` responde `All content hashes already have embeddings` en 0,1 s. Los vectores están indexados por hash de contenido + modelo + fingerprint (`c37385`), y `removeCollection` no los toca. La migración en ferrari cuesta el re-scan léxico (segundos), no ~85 min, siempre que no se corra `qmd cleanup` entre el remove y el add.
5. **Q5 — Frontmatter.** [H] Un cambio SOLO de frontmatter (`para: archive`) cambia el hash, produce `1 updated`, deja `Pending: 1` y el término es buscable por FTS (`qmd search archive` acierta); el re-embed fue de 1 chunk en 1 s. Un `touch` sin cambio de bytes no re-indexa (`0 updated`). **No hace falta bumpear `updated:`**; al contrario, toda reescritura masiva de frontmatter dispara re-embed de las páginas tocadas.
6. **Q6 — MCP.** [H] `tools/list` en vivo: `query` (params `searches[]`, `limit`, `minScore`, `candidateLimit`, **`collections: string[]`**, `intent`, `rerank`), `get`, `multi_get`, `status`. Sin `collections`, el scope por defecto son las colecciones con `includeByDefault != false`. No hay tool que mute colecciones.
7. **Q7 — Inesperados.** [H] El CLI escribe un bloque `models:` en `index.yml` en el primer uso; `qmd status` cuenta vectores huérfanos en `Vectors: N embedded` (28 con 9 docs); el índice usa WAL (`*.sqlite-shm/-wal` junto al `.sqlite`); `bun install` deja `$HOME/.npm/_prebuilds/` y `$TMPDIR/*.node-gyp`. Versión instalada exacta `qmd 2.5.3` (CHANGELOG `[2.5.3] - 2026-05-28`). Nada se escribió fuera del lab. Contenedor `agentic-pod:latest` (Alpine 3.24.1, musl aarch64, bun 1.3.14): `--version`, `--help` y `collection help` byte-idénticos al host; operaciones de índice en musl **[NV container]** (la imagen no trae qmd y el pkg del lab tiene nativos darwin).

## Método

### Fuente del pin

- [H] `grep -n -i qmd scripts/lib/versions.sh` → vacío. `versions.sh` NO pinea qmd.
- [H] `scripts/lib/qmd_index.sh::qmd_pkg` lee `vault.qmd.version` de `agent.yml` y cae a `"2.5.3"` cuando falta; `setup.sh:2242` hace backfill `yq -i '.vault.qmd.version = "2.5.3"'`. El pin efectivo vive en `agent.yml`; el default duro está duplicado en esos dos sitios.

### Instalación (mismo método que el repo)

- [H] Manifiesto idéntico a `_qmd_manifest` (`qmd_index.sh:150-152`):
  ```json
  { "dependencies": { "@tobilu/qmd": "2.5.3" }, "trustedDependencies": ["better-sqlite3", "node-llama-cpp"] }
  ```
- [H] `cd $LAB/cache/qmd/pkg && bun install` → `bun install v1.3.12`, `+ @tobilu/qmd@2.5.3`, `254 packages installed [4.35s]`, `Blocked 5 postinstalls`, rc=0. `bun pm untrusted` lista los 5: `tree-sitter-{go,python,rust,typescript,javascript}` (`node-gyp-build`), exactamente lo que el repo quiere dejar sin compilar.
- [H] Binario: `node_modules/.bin/qmd -> ../@tobilu/qmd/bin/qmd` (launcher Node/Bun que ejecuta `dist/cli/qmd.js`). `qmd --version` → `qmd 2.5.3`. `package.json` `version: 2.5.3`. sha256 `dist/cli/qmd.js` = `2fb0da8887e4cac6fca35a11895b3b9ce8f2ecd677ab7590c069bd564003939d`. `bun.lock` resuelve `@tobilu/qmd@2.5.3` con sha512 `wUKc4pSPDbgs7mV7JYE8/Qj1pNXXatJFV8byTT/T3yLaoAXheFtWu0BgSWwoWGhRkMmxl5Qyitt66NHgbMyeBA==`.
- [H] Dependencias declaradas por qmd: `@modelcontextprotocol/sdk 1.29.0`, `better-sqlite3 12.10.0`, `fast-glob 3.3.3`, `node-llama-cpp 3.18.1`, `picomatch 4.0.4`, `sqlite-vec 0.1.9`, `yaml 2.9.0`, `zod 4.2.1`, tree-sitter-*.

### Contenedor

- [H] `docker run --rm --entrypoint sh agentic-pod:latest -c 'cat /etc/alpine-release; uname -m; ls /lib/ld-musl-*; bun --version; ls /home/agent/.cache/qmd'` → `3.24.1`, `aarch64`, `/lib/ld-musl-aarch64.so.1`, `1.3.14`, "no qmd prefix baked in image". Presentes `/opt/agent-admin/{bigstack.so,sqlite-vec/vec0.so,scripts/qmd-mcp}`.
- [H] Montando el pkg del lab read-only: `bun /lab-pkg/node_modules/@tobilu/qmd/dist/cli/qmd.js --version` → `qmd 2.5.3`; `collection help` → mismo texto; `--help` → `diff` vacío contra el host (excluida la línea `Index:`), 96 líneas ambos.
- [NV container] No se ejecutó `collection add`/`update`/`embed` en el contenedor: exigiría instalar qmd dentro (build nativo largo) o llevar nativos linux; el pkg del lab trae `better-sqlite3` darwin-arm64. La lógica medida acá es JS puro del mismo tarball ([I] comportamiento idéntico en musl salvo lo nativo, que 016/017 ya cubren).

## Q1 — Superficie del CLI

### Ayuda

- [H] `qmd --help` (rc=0) lista: `query`, `search`, `vsearch`, `get`, `multi-get`, `skills`, `skill`, `mcp`, `bench`; `collection add/list/remove/rename/show`; `context add/list/rm`; `ls`; `init`, `status`, `update [--pull]`, `embed [-f] [-c <name>] [--max-docs-per-batch] [--max-batch-mb]`, `cleanup`. Opciones globales `--index <name>`, `QMD_EDITOR_URI`; de búsqueda `-n`, `--all`, `--min-score`, `--full`, `-C/--candidate-limit`, `--no-rerank`, `--no-gpu`, `--line-numbers`, `--full-path`, `--explain`, `--format cli|json|csv|md|xml|files`, `-c/--collection <name>` (múltiple); `--chunk-strategy auto|regex`.
- [H] `qmd collection --help`, `qmd collection add --help`, `qmd update --help`, `qmd embed --help`, `qmd status --help`, `qmd mcp --help`, `qmd search --help` → todos `Unknown command: <x> --help` + `Run 'qmd --help' for usage.` (el dispatcher trata `--help` como parte del nombre de comando).
- [H] `qmd collection help` (o `qmd collection` sin subcomando) imprime:
  ```
  list                      List all collections
  add <path> [--name NAME]  Add a collection
  remove <name>             Remove a collection
  rename <old> <new>        Rename a collection
  show <name>               Show collection details
  update-cmd <name> [cmd]   Set pre-update command (e.g., 'git pull')
  include <name>            Include in default queries
  exclude <name>            Exclude from default queries
  ```
  Aliases en código (`dist/cli/qmd.js:3743-3840`): `rm`, `mv`, `info`, `set-update`.

### Flags reales de `collection add`

- [H] Código `dist/cli/qmd.js:3747-3754`: `pwd = args[1] || cwd`, `globPattern = values.mask || DEFAULT_GLOB`, `name = values.name`. Solo `--name` y `--mask`. Tabla `parseArgs` (`:2437-2471`): `index`, `full`, `format`, `collection (-c, multiple)`, `name`, `mask`, `force (-f)`, `pull`, etc. Ninguna opción `ignore`/`exclude`.
- [H] `qmd --index lab7 collection add $V --name vault --mask '**/*.md' --ignore '_templates/**'` → `Indexed: 23 new`, rc=0. `--exclude '_templates/**'` (lab8) → `Indexed: 23 new`, rc=0. `qmd status --bogus-flag` → imprime el status normal, rc=0. **Flags desconocidos = no-op silencioso.**

### Archivo de colecciones

- [H] Ruta: `dist/collections.js::getConfigDir()` → `QMD_CONFIG_DIR` si existe; si no `$XDG_CONFIG_HOME/qmd`; si no `$HOME/.config/qmd`. Archivo `${indexName}.yml`, `indexName` default `index` (con `--index lab2` se crea `lab2.yml`; medido: `ls $LAB/qmdconfig` → `index.yml lab2.yml lab3.yml …`). Nada se escribió en `$XDG_CONFIG_HOME` porque `QMD_CONFIG_DIR` tiene precedencia (medido: `find $LAB/config -type f` vacío).
- [H] Contenido tras `collection add` (medido, `cat $LAB/qmdconfig/index.yml`):
  ```yaml
  collections:
    vault:
      path: /…/qmd-lab/vault
      pattern: "**/*.md"
  models:
    embed: hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf
    generate: hf:tobil/qmd-query-expansion-1.7B-gguf/qmd-query-expansion-1.7B-q4_k_m.gguf
    rerank: hf:ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/qwen3-reranker-0.6b-q8_0.gguf
  ```
  El bloque `models:` lo escribe el CLI (`ensureModelsConfiguredForCli`, llamado desde `getStore()`), no el operador.
- [H] Tipo `Collection` (`dist/collections.d.ts`): `path: string; pattern: string; ignore?: string[]; context?: Record<string,string>; update?: string; includeByDefault?: boolean`. `CollectionConfig`: `global_context?`, `editor_uri?`, `editor_uri_template?`, `collections`, `models?`.
- [H] `ignore:` es honrado. Prueba en índice aislado `lab2`: add raíz (23 docs) → edición manual del YAML agregando `ignore: ["_templates/**","raw_sources/**","CLAUDE.md","index.md","log.md"]` → `qmd --index lab2 update` → `Indexed: 0 new, 0 updated, 9 unchanged, 14 removed`; `collection list` muestra `Ignore:   _templates/**, raw_sources/**, CLAUDE.md, index.md, log.md`; sqlite `store_collections.ignore_patterns` = el JSON de la lista; `documents` active=9, inactive=14; `search quimbotoken-tpl1` (token de una plantilla) → sin resultados.
- [H] Mecanismo de sincronización (`dist/cli/qmd.js:26-66`, `dist/store.js::syncConfigToDb`): en cada arranque del CLI, `getStore()` carga el YAML y lo vuelca a `store_collections` ("External config always wins", con hash del JSON para saltarse el trabajo si no cambió). `update` toma `pwd`/`glob_pattern` del sqlite y `ignore` del YAML (`updateCollections`, `:553`). Editar el YAML a mano es, de facto, una vía soportada.
- [H] Los patrones `ignore` se evalúan con `fast-glob` sobre la ruta relativa REAL del filesystem (antes de handelizar), sumados a los fijos `**/{node_modules,.git,.cache,vendor,dist,build}/**`, `dot: false`, `followSymbolicLinks: false`, y un filtro adicional que descarta cualquier segmento que empiece con `.` (`dist/store.js:945-963`). Por eso `.obsidian/` nunca entra.

### `--mask`

- [H] Cinco índices aislados, misma raíz `$V`:
  | índice | `--mask` | docs | observación |
  |---|---|---|---|
  | index | `**/*.md` | 23 | todo el vault |
  | lab3 | `wiki/**/*.md` | 9 | rutas conservan `wiki/` |
  | lab4 | `!(_templates\|raw_sources)/**/*.md` | 9 | extglob funciona; excluye también los `.md` de raíz (exige un segmento de directorio) |
  | lab5 | `{wiki,raw_sources}/**/*.md` | 12 | llaves funcionan |
  | lab6 | `!_templates/**` | 0 | `No files found matching pattern.` |
- [H] Es un solo string (`pattern: string`); no hay lista de patrones. Guardas de `collection add`: mismo nombre → `Collection 'vault' already exists.` rc=1; mismo path+patrón con otro nombre → `A collection already exists for this path and pattern` rc=1; `collection remove nonexistent` → rc=1. No hay verbo para cambiar el patrón de una colección existente: o remove+add, o editar `pattern:` en el YAML (medido en lab7: `pattern: wiki/**/*.md` + `update` → `9 unchanged, 14 removed`, `collection list` refleja el nuevo patrón).

### `include` / `exclude`

- [H] `qmd --index lab3 collection exclude vault` → `✓ Collection 'vault' excluded from default queries`; el YAML gana `includeByDefault: false`; `collection show` → `Include:  no`; `collection list` → `vault (qmd://vault/) [excluded]`.
- [H] `qmd --index lab3 search quimbotoken-sum1 --format files` con la colección excluida → devuelve el documento igual. El CLI `search` no respeta `includeByDefault`; solo afecta el scope por defecto del MCP (`defaultCollectionNames`, ver Q6) [I] y probablemente `query` (no medido, [NV]).

### Variables de entorno reconocidas

- [H] `qmd doctor` enumera y explica (`dist/cli/qmd.js:3148-3162`): `INDEX_PATH`, `QMD_CONFIG_DIR` ("takes precedence over XDG_CONFIG_HOME"), `XDG_CONFIG_HOME`, `XDG_CACHE_HOME` ("moves the default index cache, model cache, and MCP daemon PID files"), `QMD_EMBED_MODEL`, `QMD_GENERATE_MODEL`, `QMD_RERANK_MODEL`, `QMD_FORCE_CPU`, `QMD_LLAMA_GPU`, `QMD_DOCTOR_DEVICE_PROBE`, `QMD_EMBED_PARALLELISM`, `QMD_EXPAND_CONTEXT_SIZE`, `QMD_RERANK_CONTEXT_SIZE`, `QMD_EMBED_CONTEXT_SIZE`, `QMD_EDITOR_URI`. En darwin el launcher fija `GGML_METAL_NO_RESIDENCY=1`.
- [H] `QMD_CACHE_HOME` no aparece en la lista ni en `dist/` (grep) — confirma el comentario 013 RC1 del repo: solo la lib bash lo lee.
- [H] DB: `getDefaultDbPath()` → `$XDG_CACHE_HOME/qmd/<index>.sqlite` (o `~/.cache/qmd/`). Modelos: `MODEL_CACHE_DIR = $XDG_CACHE_HOME/qmd/models` (`dist/llm.js:119-121`).

## Q2 — Vault sintético con el layout del skeleton

- [H] Construido desde `modules/vault-skeleton/`: copiados `CLAUDE.md`, `index.md`, `log.md`, `_templates/` (8 plantillas), `raw_sources/README.md`; creadas 9 páginas bajo `wiki/{summaries,entities,concepts,comparisons,overviews,normalization}/` con frontmatter conforme al spec del skeleton (`title,type,sources,related,created,updated,status,tags`), 2 fuentes crudas en `raw_sources/articles/`, y `.obsidian/app.json`. A cada archivo se le inyectó un token único `quimbotoken-*`. Total `find -name '*.md'` = 23; en `wiki/` = 9.
- [H] `qmd collection add $V --name vault --mask '**/*.md'` (0,5 s) → `Indexed: 23 new, 0 updated, 0 unchanged, 0 removed` + `Run 'qmd embed' to update embeddings (23 unique hashes need vectors)`. `qmd update` → `23 unchanged`. `qmd status` → `Total: 23 files indexed`, `Vectors: 0`, `Pending: 23`.
- [H] `sqlite3 index.sqlite "SELECT path FROM documents"` (23 filas):
  `CLAUDE.md`, `index.md`, `log.md`, `raw-sources/README.md`, `raw-sources/articles/{grelling-report,zorbaflux-primer}.md`, `templates/{comparison,concept,entity,normalization,overview,source,summary,synthesis}.md`, `wiki/comparisons/bm25-vs-vectors.md`, `wiki/concepts/{frontmatter-drift,hybrid-retrieval}.md`, `wiki/entities/{acme-widgets,tobi-lutke}.md`, `wiki/normalization/cencosud.md`, `wiki/overviews/rag-landscape.md`, `wiki/summaries/{grelling-report,zorbaflux-primer}.md`.
- [H] `qmd search <token> --format files` acierta en todos los archivos "no wiki": `quimbotoken-tpl1` → `qmd://vault/templates/summary.md`; `-index1` → `index.md`; `-log1` → `log.md`; `-claude1` → `CLAUDE.md`; `-rawreadme1` → `raw-sources/README.md`; `-raw1` → `raw-sources/articles/zorbaflux-primer.md`.
- [H] **Handelize:** `_templates` → `templates`, `raw_sources` → `raw-sources` (`dist/store.js::handelize`). Las URIs `qmd://vault/...` NO coinciden byte a byte con el filesystem cuando hay `_` en directorios. Los patrones `ignore`/`--mask` se aplican al path real, no al handelizado.
- Conclusión Q2: [H] hoy el índice contiene plantillas, schema, index, log y fuentes crudas; el ruido es 14 de 23 documentos en este vault.

## Q3 — Recreación de la colección apuntando a `wiki/`

Sobre el índice principal, ya embebido (ver Q4):

- [H] Antes: `documents` 23 (activos 23), `content` 23, `content_vectors` 28 filas / 23 hashes, `store_collections` 1.
- [H] `qmd collection remove vault` → `Deleted 23 documents`, `Cleaned up 23 orphaned content hashes`. Después: `documents` 0, `content` 0, `store_collections` 0, YAML `collections: {}`; **`content_vectors` sigue en 28 filas / 23 hashes** (`removeCollection`, `dist/store.js:2265-2280`, borra `documents` y `content` huérfano; no toca `content_vectors` ni `vectors_vec`).
- [H] `qmd collection add $V/wiki --name vault --mask '**/*.md'` → `Indexed: 9 new`, y **sin** la línea `Run 'qmd embed'`. `qmd update` → `9 unchanged`. `documents` 9, `content` 9, `content_vectors` 28 (19 huérfanas: `SELECT COUNT(*) FROM content_vectors cv WHERE NOT EXISTS (… active=1)` → 19).
- [H] Paths resultantes: `comparisons/bm25-vs-vectors.md`, `concepts/…`, … (sin prefijo `wiki/`). `search quimbotoken-sum1` → `qmd://vault/summaries/zorbaflux-primer.md`; `search quimbotoken-index1` → vacío.
- [H] Hashes de las 9 páginas idénticos antes y después (`diff wiki-hashes-before.txt wiki-hashes-after.txt` vacío).
- [H] Filas huérfanas: ninguna en `documents` (borrado duro). Sí en `content_vectors`/`vectors_vec` (19 chunks) hasta `qmd cleanup` → `✓ Removed 19 orphaned embedding chunks`, `✓ Database vacuumed`; tras cleanup `content_vectors` 9 filas / 9 hashes y `qmd embed` sigue diciendo `All content hashes already have embeddings`.
- [H] Variante B (preserva rutas): `remove` + `collection add $V --name vault --mask 'wiki/**/*.md'` → `9 new`, paths `wiki/…`, `Vectors: 28 embedded`, `embed` → `All content hashes already have embeddings`.
- [H] Variante C (sin remove, vía YAML): en lab2 con `ignore:` y en lab7 con `pattern:` → `update` marca `14 removed`, pero esos 14 quedan como filas `active=0` (`documents` inactive=14, `content` 23) hasta `qmd cleanup` → `✓ Removed 14 inactive document records`. El FTS los excluye igual (trigger `documents_au` borra de `documents_fts` cuando `active=0`).
- [H] `qmd ls vault` lista los 9 con tamaño, fecha y URI: útil como oráculo post-migración.

## Q4 — Reutilización de embeddings (Q13 de la spec)

- [H] `qmd embed` sobre la colección original (23 docs), en background con presupuesto de 15 min: arrancó 21:32:26, terminó 21:32:41 (15 s wall). Log: `Downloading to $LAB/cache/qmd/models` → `hf_ggml-org_embeddinggemma-300M-Q8_0.gguf` (333.590.944 bytes), `Model: embeddinggemma-300M-Q8_0.gguf`, `✓ Done! Embedded 28 chunks from 23 documents in 15s`, rc=0. Solo se descargó el modelo de embedding; reranker y expansión no (doctor: `model cache: missing 2/3`).
- [H] `qmd status` → `Vectors: 28 embedded`, sin `Pending`. `qmd embed` de nuevo → `✓ All content hashes already have embeddings.` `content_vectors`: `model=hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf`, `embed_fingerprint=c37385`, 28 filas.
- [H] Tras remove + add `wiki/` + update (Q3): `qmd status` → `Total: 9 files indexed`, `Vectors: 28 embedded`, **sin línea Pending**; `time qmd embed` → `✓ All content hashes already have embeddings.` en 0,096 s. Idem en la variante B (raíz + mask `wiki/**/*.md`).
- [H] Por qué (código): `getPendingEmbeddingDocs` (`dist/store.js:1085-1107`) hace `documents JOIN content LEFT JOIN content_vectors ON hash` filtrando `model` + `embed_fingerprint`; un documento re-insertado con el mismo hash encuentra sus chunks y no queda pendiente. Solo `qmd cleanup` (`cleanupOrphanedVectors`, `dist/cli/qmd.js:4125`) o `qmd embed -f` (`clearAllEmbeddings`) destruyen vectores; `update` no llama a `cleanupOrphanedVectors` (solo `cleanupOrphanedContent`).
- [I] En ferrari la reutilización se mantiene mientras (a) la versión de qmd/modelo/fingerprint sea la misma (`c37385` con 2.5.3 + embeddinggemma-300M-Q8_0), (b) el contenido de las páginas de `wiki/` no cambie entre el estado embebido y la recreación, y (c) no se ejecute `qmd cleanup` entre `remove` y `add`. Costo esperado de la migración: un `update` léxico (segundos) y cero embed.
- [NV] Tiempos de embed en ferrari (CPU aarch64 musl) no medibles acá; el dato de 018 (~2423 chunks, cap 30 min/sesión) sigue siendo la referencia para el caso en que SÍ hubiera que re-embeber.

## Q5 — Cambio solo de frontmatter (Q9 de la spec)

Sobre `wiki/concepts/frontmatter-drift.md` en el índice principal (raíz + mask `wiki/**/*.md`, embebido):

- [H] Hash antes `360fc0d5…8bb7`. Se insertó `para: archive` dentro del bloque YAML (única modificación). `qmd update` → `Indexed: 0 new, 1 updated, 8 unchanged, 0 removed` + `Run 'qmd embed' … (1 unique hashes need vectors)`. Hash después `99ebccfd…ab33` (cambió). `status` → `Pending: 1 need embedding`.
- [H] `qmd search archive --format files` → `#99ebcc,0.63,qmd://vault/wiki/concepts/frontmatter-drift.md`; la frase `"para: archive"` también acierta; `documents_fts MATCH 'archive'` → 1. El frontmatter forma parte del cuerpo indexado por FTS.
- [H] `qmd embed` → `✓ Done! Embedded 1 chunks from 1 documents in 1s` (0,83 s wall). Solo se re-embebió el documento tocado.
- [H] Segunda edición (línea de cuerpo con token `quimbotoken-bodyedit1`) → `1 updated`, hash `534c026c…4b029`, token buscable, `Pending: 1`.
- [H] `touch` del archivo sin cambiar bytes → `0 new, 0 updated, 9 unchanged` (la detección es por hash de contenido, `reindexCollection` compara `existing.hash === hash`; el mtime solo se persiste en `modified_at`).
- Conclusión: [H] no hace falta la mitigación de bumpear `updated:`; cualquier cambio de bytes en el archivo (frontmatter incluido) re-indexa y re-embebe ese documento. [I] Consecuencia inversa: una pasada masiva que agregue un campo de frontmatter a N páginas dispara re-embed de N documentos.

## Q6 — Parámetro de colección en el servidor MCP

- [H] Medido en vivo por stdio (`printf` de `initialize` + `notifications/initialized` + `tools/list` a `qmd mcp`, stderr vacío, sin `mcp.pid` en modo stdio). `serverInfo` = `{name: qmd, version: 2.5.3}`. Tools:
  | tool | propiedades del `inputSchema` |
  |---|---|
  | `query` | `searches` (array 1-10 de `{type: lex\|vec\|hyde, query}`), `limit`, `minScore`, `candidateLimit`, **`collections`** (`array` de `string`, "Filter to collections (OR match)"), `intent`, `rerank` |
  | `get` | `file`, `fromLine`, `maxLines`, `lineNumbers` |
  | `multi_get` | `pattern`, `maxLines`, `maxBytes`, `lineNumbers` |
  | `status` | (ninguna) |
- [H] Código `dist/mcp/server.js:125,244-247`: `defaultCollectionNames = store.getDefaultCollectionNames()` (las con `includeByDefault != false`); si `collections` viene vacío se usa ese default. `instructions` del initialize dice "Collections (scope with `collection` parameter): vault" aunque el parámetro real se llama `collections` (inconsistencia menor del vendor). Recurso `qmd://{+path}`. No existe tool para agregar/quitar colecciones ni para re-indexar; la mutación es solo CLI.
- [H] `qmd mcp` acepta subcomandos `stop`/`status` y flags `--http --port --daemon` (pid en `$XDG_CACHE_HOME/qmd/mcp.pid`). [NV] si `--index` es honrado por `qmd mcp` (no medido).

## Q7 — Comportamientos inesperados y versión

- [H] Versión: `qmd 2.5.3`; `CHANGELOG.md` `## [2.5.3] - 2026-05-28` (agrega `--format`, `--full-path`, `get` con `:from:count`, line numbers por defecto). Sin mensajes de deprecación en ninguna corrida.
- [H] Subcomandos sin `--help`; flags desconocidos ignorados en silencio (riesgo de falsa sensación de configuración: `--ignore` "acepta" y no hace nada).
- [H] El CLI escribe `models:` en `index.yml` en el primer `getStore()`; cualquier diseño que "posea" ese YAML debe tolerar que el vendor lo reescriba (`YAML.stringify`, indent 2, sin wrap).
- [H] `qmd status` → `Vectors: N embedded` cuenta filas de `content_vectors` incluidas las huérfanas (28 con 9 docs activos). La métrica honesta es la ausencia de `Pending` y la salida de `qmd embed`. `qmd cleanup` normaliza.
- [H] Paths handelizados (`_templates` → `templates`, `raw_sources` → `raw-sources`).
- [H] WAL: aparecen `<index>.sqlite-shm` y `<index>.sqlite-wal` junto al `.sqlite` (relevante para rsync/backup de `.state`).
- [H] Escrituras colaterales de `bun install`: `$HOME/.npm/_prebuilds/…better-sqlite3-v12.10.0-node-v127-darwin-arm64.tar.gz` y `$TMPDIR/.…node-gyp/`. En producción caen en `/home/agent` (`.state`) y en el scratch del repo respectivamente.
- [H] `qmd doctor` en un índice nunca embebido recomienda `qmd embed --force` ("no vector table to test") — sugerencia espuria; y hace un probe de GPU (`GPU metal … Apple M4 Pro`). Declara sqlite 3.53.1, better-sqlite3 12.10.0, sqlite-vec 0.1.9.
- [H] El `sqlite3` del host no puede consultar `vectors_vec` (`no such module: vec0`); los conteos se hicieron sobre `content_vectors`.
- [H] Aislamiento verificado al final: `~/.cache/qmd`, `~/.config/qmd`, `~/.qmd`, `~/.node-llama-cpp`, `~/.cache/huggingface` ausentes; `find ~/.cache ~/.config ~/.bun -newer $LAB/install.log` vacío; `$LAB/config` (XDG_CONFIG_HOME) vacío porque `QMD_CONFIG_DIR` manda.
- [H] Guardas del CLI que el repo asume: `collection add` duplicado → rc=1 con mensaje (coincide con el comentario de `_qmd_setup_locked`: "re-adding it would error").

## Implicaciones para el diseño de 037

1. **Forma de migración viable: solo argumentos de CLI, sin tocar el YAML del vendor.** [H] Cambiar el literal de `--mask` en `_qmd_setup_locked` (`qmd_index.sh:379`) de `'**/*.md'` a `'wiki/**/*.md'` manteniendo la raíz del vault como `path` deja las URIs `qmd://vault/wiki/...` idénticas a las actuales y excluye `_templates/`, `raw_sources/`, `CLAUDE.md`, `index.md`, `log.md` en un solo paso. Si 037 quiere `raw_sources/` indexado, `'{wiki,raw_sources}/**/*.md'` (medido: 12 docs) o `'!(_templates)/**/*.md'` — ojo: la forma extglob con un segmento de directorio también excluye los `.md` de la raíz.
2. **Para agentes existentes (ferrari):** [H] `qmd collection remove vault && qmd collection add <vault> --name vault --mask 'wiki/**/*.md' && qmd update` reutiliza los embeddings; costo = segundos de re-scan léxico, no ~85 min. Gate del procedimiento: no ejecutar `qmd cleanup` entre `remove` y `add`; ejecutarlo DESPUÉS, deliberadamente, para purgar los chunks huérfanos y que `status` vuelva a ser veraz. Oráculo post-migración: `qmd ls vault` = solo `wiki/…`, `qmd embed` → `All content hashes already have embeddings`, `qmd status` sin `Pending`.
3. **Alternativa por YAML (`pattern:`/`ignore:` en `index.yml` + `update`)** funciona y preserva rutas sin `remove` [H], pero escribe en un archivo que el propio CLI reescribe (`models:`) y compite con el `collection add` del setup; deja 14 filas `active=0` hasta `cleanup`. `ignore:` queda como única vía para exclusiones finas que un solo `--mask` no exprese (p. ej. excluir `wiki/synthesis/lint-*.md` manteniendo el resto de `wiki/`). Si 037 la necesita, el escritor debe ser idempotente y tolerar el `models:` ajeno.
4. **Costo de re-embed:** cero para páginas cuyo contenido no cambia [H]. El costo real aparece si 037 reescribe frontmatter masivamente (p. ej. agregar `para:` a todas las páginas): cada archivo tocado se re-embebe [H]. Secuenciar: primero recrear la colección (barato), después cambios de contenido en lotes que quepan en el loop de 018.
5. **Mitigación "bumpear `updated:`" innecesaria** [H]: el hash de contenido ya captura cambios de frontmatter; `touch` no dispara nada. Si la spec la mantiene, su única función sería semántica (trazabilidad), no técnica.
6. **`includeByDefault` como herramienta de scope MCP** [H]: permite mantener una colección secundaria (p. ej. `archive` o `raw`) indexada pero fuera del scope por defecto del `query` MCP, con opt-in vía `collections: [...]`. No afecta al `qmd search` del CLI.
7. **Supuestos del repo confirmados** [H]: el binario honra `XDG_CACHE_HOME` (índice + modelos) y `QMD_CONFIG_DIR` (YAML), ignora `QMD_CACHE_HOME`; `--index` permite índices paralelos en el mismo cache (útil para tests o para una colección de staging). La instalación con `trustedDependencies` deja los 5 tree-sitter sin compilar, como el repo espera.
8. **Contenedor** [NV]: la superficie del CLI es idéntica en Alpine (JS), pero toda operación con sqlite/vectores en musl sigue dependiendo del DOCKER_E2E de 016/017/018; 037 debería reusar ese arnés para la migración `remove`+`add`.

## Archivos y directorios creados en el lab

Todo bajo `$LAB` (`/private/tmp/claude-501/-Users-rodrigo-hinojosa-Documents-Cencosud-Claude-Agents-agentic-pod-launcher/39e5ee01-c1c3-454a-ba47-6d398dabb108/scratchpad/qmd-lab/`), 511 MB en total:

- `q` — wrapper que fija HOME/XDG_CACHE_HOME/XDG_CONFIG_HOME/QMD_CONFIG_DIR/QMD_CACHE_HOME/TMPDIR y ejecuta `cache/qmd/pkg/node_modules/.bin/qmd`.
- `cache/qmd/pkg/` — prefijo gestionado: `package.json` (manifiesto del repo), `bun.lock`, `node_modules/` (254 paquetes, `@tobilu/qmd@2.5.3`).
- `cache/qmd/models/hf_ggml-org_embeddinggemma-300M-Q8_0.gguf` — 333,59 MB.
- `cache/qmd/index.sqlite` (índice principal) y `lab2..lab8.sqlite` (+ `-shm`/`-wal` de algunos) — índices aislados de las pruebas de `ignore`, `--mask`, `include/exclude`, `--ignore` ignorado y `pattern:` por YAML.
- `qmdconfig/index.yml`, `qmdconfig/lab2.yml … lab8.yml` — archivos de colecciones (el `QMD_CONFIG_DIR`).
- `config/` — vacío (XDG_CONFIG_HOME no usado por precedencia de QMD_CONFIG_DIR).
- `home/.npm/_prebuilds/` — prebuild de better-sqlite3 dejado por `bun install`.
- `tmp/.…node-gyp/` — scratch de node-gyp del install.
- `vault/` — vault sintético (23 `.md` + `.obsidian/app.json`), con `wiki/concepts/frontmatter-drift.md` modificado dos veces por Q5.
- `install.log`, `embed.log`, `embed.start`, `embed.end`, `mcp.out`, `mcp.err`, `help.host.txt`, `help.container.txt`, `wiki-hashes-before.txt`, `wiki-hashes-after.txt` — evidencia cruda.

Fuera del lab: solo este informe, en `scratchpad/037-discovery/L-qmd-measurements.md`. Ningún archivo del repo ni del `$HOME` real fue modificado; la imagen Docker no se reconstruyó (se usó `agentic-pod:latest` existente con un bind-mount read-only del pkg del lab).
