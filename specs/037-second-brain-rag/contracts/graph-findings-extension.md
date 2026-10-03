# Contract: extensión del runner del grafo (`scripts/lib/wiki_graph.sh`) — claves PARA, aristas, hallazgos nuevos, `packets.json`, `policy.json`

Extiende `specs/014-wiki-graph-rag/contracts/graph-artifacts.md` (schema 1) de forma aditiva. Líneas citadas
sobre `main` @ `70214d9` (informe K, `discovery/K-touchpoints.md` §1). Aplica igual en docker (lib
espejada al `docker/` del workspace por `mirror_catalog_to_docker`) y local.

## 1. Entradas del runner

| Entrada | Fuente | Default | Override de test |
|---|---|---|---|
| `TODAY` (ISO, UTC) | `date -u +%F` (misma zona que `generated_at`, `:93`, `:367`) | fecha de la corrida | `WIKI_GRAPH_TODAY=YYYY-MM-DD` |
| `archive_candidate_days` | `agent.yml` `.vault.archive.candidate_days` (yq, molde `wiki_graph_enabled` `:49-60`) | 90 | `WIKI_GRAPH_ARCHIVE_CANDIDATE_DAYS` |
| `review.project_days` / `review.area_days` | `.vault.review.project_days` / `.area_days` | 7 / 30 | `WIKI_GRAPH_REVIEW_PROJECT_DAYS` / `WIKI_GRAPH_REVIEW_AREA_DAYS` |
| `delta_pending_days` | constante | 14 | `WIKI_GRAPH_DELTA_PENDING_DAYS` |
| `problem_unfed_days` | constante | 30 | `WIKI_GRAPH_PROBLEM_UNFED_DAYS` |
| `index_first_max_pages` | constante (solo se publica en `policy.json`; no tiene lector en código) | 300 | `WIKI_GRAPH_INDEX_FIRST_MAX_PAGES` |
| `DELTA_DATE` | marcador `_templates/.schema-updates-0.27.0.applied`: existe y parsea (`deposited: YYYY-MM-DD`, CANON-D13) → esa fecha; existe pero NO parsea (incluido vacío) → mtime del marcador; no existe → `""`. Un scaffold nuevo nace con el marcador fechado (lo escribe `vault_seed_if_empty`); sin marcador = vault que no recibió el delta (`seed_skeleton: false`) → `description_missing` gatea solo por `para` declarado (M I5/U3) | — | por fixture |

Valores no enteros o fuera de `1..3650` → default, con una línea `WARN` en el log del runner que nombra la
clave (nunca el valor). El runner no aborta por config.

## 2. Parser awk (`:108-263`) — columnas nuevas

`reset()` `:144-151` gana las variables; las ramas `else if (key == …)` `:206-225` ganan las claves. El record
`N` `:170` y el destructuring jq `:506` se extienden **en el mismo orden** (son posicionales; un desfase
corrompe `type/status` en silencio — riesgo K-4). Orden canónico de las columnas nuevas, anexadas tras
`title_present`:

```
para  description_present  packet  distill  due  next_review  archived  goal_present  next_action_present  project  area  problems  tags
```

- `para` vacío se normaliza a `resource` **en jq** (el awk emite lo leído; la normalización vive en un solo
  lugar, `$nodes`).
- `problems` y `tags`: arrays (flow `[a, b]` o guiones) → unidos con `;` en el TSV, separados en jq.
- `project` / `area`: `unwrap(unquote(v))` como `entity` `:213` (acepta `[[entities/x]]` y `entities/x`).
- `description_present`, `goal_present`, `next_action_present`: `1` si la clave existe **y** el valor no es
  vacío tras `unquote` (a diferencia de `title_present`, regla L6 de 014, porque aquí el valor vacío hace
  inaplicable la semántica; misma excepción que `canonical`/`aliases`).
- `SRCN` `:178` gana la columna `para` (necesaria para suprimir `stale` en archive; riesgo K-5).

### Aristas nuevas (en `flush()`, tras `:176`)

```
E  <id>  <project>   related     # si project != ""
E  <id>  <area>      related     # si area != ""
E  <id>  synthesis/favorite-problems  related   # si problems != "" (una sola arista por página)
```

El destino de `problems` es el id fijo `synthesis/favorite-problems`. En jq: si ese nodo no existe, la
arista se **descarta** (ni `broken_link` ni backlink) — Edge Cases de la spec. Para `project`/`area` la
regla es la de `related`: destino inexistente → `broken: true` → `broken_link` (`:514`).

### Violaciones nuevas (`emit_v` en `flush()` `:171-174`), literales CANON-F

| CANON | detail |
|---|---|
| F1 | `para: invalid '<v>'` (v ∉ {project, area, resource, archive}) |
| F2 | `packet: invalid '<v>'` (v ∉ {distilled-note, outtake, wip, deliverable, external}) |
| F3 | `distill: invalid '<v>'` (no entero 1..4) |
| F4 | `due: malformed '<v>'`, `next_review: malformed '<v>'`, `archived: malformed '<v>'` (no `^[0-9]{4}-[0-9]{2}-[0-9]{2}$`) |
| F5 | `archived: missing` (`para: archive` sin `archived`) |
| F6 | `favorite_problems: <n> entries (max 12)` y `favorite_problems: fp-<n> is not a question` — solo sobre el nodo `synthesis/favorite-problems`; "question" = la entrada termina en `?` o empieza por `How|What|Why|When|Which|Cómo|Qué|Por qué|Cuándo|Cuál` |

Las violaciones de forma se emiten en awk (tiene el valor crudo); las de fecha malformada también, de modo que
jq solo hace aritmética sobre fechas ya válidas.

**Regla del valor vacío** (refutación N C8): F1, F2, F3 y F4 se emiten SOLO cuando el valor tras `unquote` es
NO vacío (molde `status`, `wiki_graph.sh:174`). `para: ""`, `packet: ""`, `distill: ""`, `due: ""`,
`next_review: ""`, `archived: ""` equivalen a clave ausente (`para` vacío = `resource`). Esto es lo que
permite que una plantilla de `_templates/` (que trae `due: ""`, `next_review: ""`, `created: ""`) sembrada en
`wiki/` parsee sin `frontmatter_violation` (oráculo del contrato del schema §5). Para `para: project`, un
`due: ""` sí cuenta como ausente en `project_incomplete`.

Detalles de implementación que el parser exige (refutación N C13): la rama de continuación por guiones
`:195-201` hoy solo trata `related`/`sources`/`aliases` y debe ganar `problems` y `tags`, o un array en
guiones se descarta en silencio; `description`, `goal` y `next_action` viajan en TSV y necesitan
`gsub(/\t/, " ", v)` antes del record `N`; la firma posicional de `_wg_aggregate` (`:496`) se extiende junto
con su único call site (`:353`); `policy.json.collection` lee `qmd-index.json` desde
`$(dirname "$WIKI_GRAPH_STATE_FILE")/qmd-index.json` (ambos state files viven en `scripts/heartbeat/`; en
local `QMD_INDEX_STATE_FILE` no está exportada al runner del grafo).

## 3. Enumeraciones nuevas fuera de `wiki/` (bash, molde `_wg_index_entries` `:401-428`)

| Lista | Comando | TSV |
|---|---|---|
| Raw sources | `find "$vault_dir/raw_sources" -name '*.md'` + awk que lee el frontmatter y toma `clipped:` (solo archivos con la clave) | `RAW\t<ruta relativa al vault>\t<clipped>` |
| Menciones en `log.md` | awk sobre `$vault_dir/log.md`: por cada `## [YYYY-MM-DD] …`, la fecha y todos los `[[type/slug]]` o tokens `type/slug` de esa entrada y su párrafo | `LOG\t<fecha>\t<id>` |
| Marcador del delta | `cat _templates/.schema-updates-0.27.0.applied` → `DELTA_DATE`; `grep -F -q -- '## Actionability (PARA)' "$vault_dir/CLAUDE.md"` → `integrated=0/1` | argumentos `--arg` a jq |

Las tres se pasan a `_wg_aggregate` `:497-501` como `--rawfile`/`--arg` adicionales. Un `raw_sources/`
ausente o un `log.md` ausente producen listas vacías, no error.

## 4. Agregación jq (`:495-565`) — hallazgos nuevos

Aritmética de fechas **en jq**: `(d|strptime("%Y-%m-%d")|mktime)`; medido el 26-09-2026: jq 1.8.1 en la
imagen Alpine y jq 1.7.1 en macOS devuelven ambos 25 días entre `2026-09-01` y `2026-09-26`. No se usa
`awk mktime` (ausente en awk BSD del host) ni `date -d` (semántica distinta BSD/GNU/busybox).
`$today` llega por `--arg today "$TODAY"`.

| kind | page | detail (CANON) | Condición jq | Excluye |
|---|---|---|---|---|
| `project_incomplete` | id | `missing: <goal,due,next_action>` (solo los ausentes, en ese orden) | `.para=="project"` y alguno de `goal_present==0`, `due==""`, `next_action_present==0` | — |
| `project_overdue` | id | `due: <due> (<n> days)` | `.para=="project"`, `due!=""`, `due < today` (n = días) | `para=="archive"` |
| `review_due` | id | `next_review: <d> (<n> days)` o `next_review: missing` | `.para=="project"` y (`next_review==""` o `< today`) | `para=="archive"` |
| `description_missing` | id | `para: <v>` o `created: <c> >= delta <DELTA_DATE>` | `description_present==0` y (`para` declarado en el archivo — columna cruda no vacía — o (`DELTA_DATE!=""` y `created>=DELTA_DATE`)); con `DELTA_DATE==""` (vault sin marcador) solo la rama `para` | páginas preexistentes sin `para`; cualquier página sin `para` en un vault sin marcador |
| `pending_ingest` | `raw_sources/<ruta>` | `no summary cites this source (clipped: <c>)` | ruta de `RAW` ∉ conjunto de `.to` de aristas `source` cuyo `.from` es un nodo `type=="summary"` (comparación por ruta relativa al vault, sin `./`, sin `/` inicial) | — |
| `problem_unfed` | `synthesis/favorite-problems` | `fp-<n>: <d> days without entries (threshold <T>)` | nodo existe; para cada `fp-<n>` listado en el cuerpo de la página: máximo `updated` entre las páginas cuyo `problems` contiene `fp-<n>`; si no hay ninguna o `today - max > T` | nodo ausente → 0 |
| `archive_candidate` | id | `status: <stale\|superseded>; backlinks: 0; last log mention: <d\|none>` | `status ∈ {stale, superseded}`, backlinks vacíos, ninguna `LOG` con ese id y fecha `>= today - N` | `para=="archive"` |
| `schema_delta_pending` | `_templates/schema-updates-0.27.0.md` | `deposited <DELTA_DATE> (<n> days); vault CLAUDE.md lacks '## Actionability (PARA)'` | `DELTA_DATE!=""`, `integrated==0`, `today - DELTA_DATE > delta_pending_days` | — |

Supresión sobre kinds de 014: `$f_orphan` `:539` y la lista `stale` `:512` filtran `para!="archive"`.

Orden estable: por `kind`, luego `page`, luego `detail` (los kinds nuevos pueden repetir `page`).

## 5. Artefactos

| Archivo | Cambio |
|---|---|
| `graph.json` | nodos con campos nuevos (`para` normalizado, `description`, `packet`, `distill`, `due`, `next_review`, `archived`, `project`, `area`, `problems[]`, `tags[]`); `title` sigue sin emitirse como texto (solo `title_present` interno) — el contrato 014 se corrige para reflejar el código |
| `backlinks.json` | sin cambio de shape; gana entradas por las aristas nuevas |
| `findings.json` | kinds y razones nuevas (§2, §4) |
| `packets.json` (nuevo) | `{schema:1, generated_at, packets:[{id,type,packet,description,project,updated}]}`; orden `updated` desc, `id`; `[]` si no hay; **siempre** se escribe |
| `policy.json` (nuevo) | `{schema:1, generated_at, review:{project_days,area_days}, archive:{candidate_days}, thresholds:{delta_pending_days, problem_unfed_days, index_first_max_pages}, collection:{layout, migration}}`; `collection` se copia de `$(dirname "$WIKI_GRAPH_STATE_FILE")/qmd-index.json` si existe (`collection_layout`/`migration`), si no `{"layout":"none","migration":"n/a"}` (mismo vocabulario que el state de qmd) |
| `wiki-graph.json` | `counts` gana con default 0 (también en el path de error `:94`): `project_incomplete`, `project_overdue`, `review_due`, `pending_ingest`, `description_missing`, `problem_unfed`, `archive_candidate`, `schema_delta_pending`, `packets`, `para_project`, `para_area`, `para_archive` |

Cinco escrituras atómicas (`_wg_atomic_write`, `:365-373`) en vez de tres. Regla dura de 014 intacta:
solo no-`.md` bajo `.graph/`.

## 6. Consumidores

| Superficie | Cambio | Exit codes |
|---|---|---|
| `agentctl` local `_local_vault_qmd_status` `:1141` | string de counts gana los siete de la lista canónica en orden fijo: `review_due=<n> project_overdue=<n> project_incomplete=<n> pending_ingest=<n> archive_candidate=<n> schema_delta_pending=<n> problem_unfed=<n>`; línea `qmd collection: <layout> (migration <state>)` junto a `:1118-1119`, calculada en vivo (sentinel + `index.sqlite`) | sin cambio |
| `agentctl` local `_local_vault_qmd_doctor` `:1155-1236` | líneas informativas (`_doctor_pass`) para la cola; **nunca** `_doctor_warn` por kinds nuevos; `migration: pending` es informativo | contrato Q5 de 014 intacto (`:1216-1228`) |
| `heartbeatctl status` docker `:350-438` | bloque nuevo tras `:418`: `wiki-graph: <status> @ <last_run> — due=<n> overdue=<n> incomplete=<n> ingest=<n> archive=<n> delta=<n> unfed=<n>` (los siete canónicos, mismo orden) y `qmd index: <status> pending=<n> collection=<layout> migration=<state>` (lee `WIKI_GRAPH_STATE_FILE` `:68` y `QMD_INDEX_STATE_FILE` `:66`; layout/migración calculados en vivo con `qmd_collection_migration_state`, `heartbeatctl` ya carga `qmd_index.sh` `:47-50`) | `cmd_status` no tiene exit por contenido |
| `modules/claude-md.tpl:222` | menciona los kinds nuevos y `policy.json`/`packets.json` | — |

## 7. Oráculos y fixtures

1. **Fixture 014 intacta**: `tests/fixtures/vault-graph/` no cambia. Golden nuevo
   `tests/fixtures/vault-graph.findings.golden.json` (los 7 hallazgos actuales) → test "la lib 037 sobre la
   fixture 014 produce `findings` byte-idéntico al golden y counts nuevos en 0" (SC-001, "los seis
   hallazgos previos byte-idénticos").
2. **Fixture nueva** `tests/fixtures/vault-graph-para/` con fechas remotas y `WIKI_GRAPH_TODAY=2030-06-15`:
   ficha completa y vigente (0 hallazgos propios), ficha incompleta (`missing: goal,next_action`), ficha
   vencida (`due` 2030-05-01 → `(45 days)`; `next_review` 2030-06-01 → `(14 days)`), ficha `para: archive`
   sin backlinks y con fuente más nueva (0 `orphan`, 0 `stale`), página `para: projet` (F1), página con
   `packet: wip` y otra `packet: nope` (F2), `favorite-problems` con tres entradas (una sin forma de
   pregunta → F6) y una página `problems: [fp-1]` con `updated` 2030-06-10 (fp-2 y fp-3 `unfed`), página
   `status: stale` sin backlinks (archive_candidate) y otra `stale` mencionada en `log.md` el 2030-06-10 (no
   candidata), raw con `clipped:` sin summary (pending_ingest) y raw citado (no), marcador
   `deposited: 2030-05-01` con `CLAUDE.md` sin CANON-D1 (delta pending, 45 días) y una página `created`
   2030-06-01 sin `description` (missing) más otra preexistente `created` 2030-01-01 sin `para` (no).
   Conteo exacto esperado documentado en su `README.md`, como en 014.
3. **Skeleton limpio → 0** (`wiki-graph.bats:98`) se conserva.
4. Determinismo: mismo `TODAY` → dos corridas → `findings.json` idéntico (diff vacío).
5. Robustez: `raw_sources/` ausente, `log.md` ausente, marcador vacío → sin error, listas vacías.
6. L1 de 014 (`wiki-graph.bats:142-149`): `.graph/` sigue sin `.md` con cinco artefactos.
7. Alpine: mismos conteos en DOCKER_E2E (`docker-e2e-qmd.bats` Fase 4.5 `:236-275`, extendida con la
   fixture nueva copiada al vault del contenedor).
