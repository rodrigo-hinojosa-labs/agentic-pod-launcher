# Data model — 037 Second Brain sobre el LLM Wiki

**Branch**: `037-second-brain-rag` | **Date**: 2026-09-26 | **Spec**: [spec.md](spec.md)

Extiende de forma **aditiva** los contratos de 014 (`specs/014-wiki-graph-rag/contracts/graph-artifacts.md`,
schema 1 de `graph.json`/`backlinks.json`/`findings.json`/`wiki-graph.json`). Ningún campo existente cambia
de nombre ni de semántica; todo lo nuevo son claves opcionales, kinds nuevos de hallazgo, un artefacto
derivado nuevo (`packets.json`), un artefacto de política (`policy.json`), un sentinel bajo `.state` y seis
claves nuevas de `agent.yml`. Los nombres exactos de rutas internas (cache root de qmd, flags del runner del
heartbeat) se confirman en `research.md` a partir del mapa de puntos de cambio (informe K) y de las
mediciones de qmd (informe L); aquí se marcan con **[K]** o **[L]** cuando dependen de esa confirmación.

## 1. Frontmatter extendido (las seis páginas de `wiki/`)

Todas las claves son opcionales, planas, escalares o arrays de flujo, nombres `[a-z_]+` (el parser awk de
014 solo reconoce esa forma). `para` ausente equivale a `resource`. Fechas en ISO `YYYY-MM-DD` (mismo
formato que `created`/`updated`), comparables lexicográficamente en awk.

| Clave | Tipo | Aplica a | Semántica | Validación (runner) |
|---|---|---|---|---|
| `para` | enum `project`, `area`, `resource`, `archive` | los seis tipos | Accionabilidad (PARA de Forte) | valor fuera del enum → `frontmatter_violation` `para: invalid '<v>'` |
| `archived` | fecha | `para: archive` | fecha de cierre/archivo | `para: archive` sin `archived` → violación `archived: missing`; malformada → violación |
| `goal` | string | `para: project` | resultado esperado del proyecto | ausente/vacío → `project_incomplete` (campo listado) |
| `due` | fecha | `para: project` | fecha objetivo | ausente → `project_incomplete`; malformada → violación `due: malformed`; anterior a hoy → `project_overdue` |
| `next_action` | string | `para: project` | siguiente paso concreto (Hemingway Bridge) | ausente/vacío → `project_incomplete` |
| `next_review` | fecha | `para: project` (opcional en `area`) | próxima revisión fijada por el agente | ausente en project → `review_due` (`next_review: missing`); anterior a hoy → `review_due`; malformada → violación, no `review_due`; en `area` solo se valida forma |
| `standard` | string | `para: area` | estándar a sostener | solo forma (string) |
| `cadence` | string | `para: area` | cadencia declarada por el humano (texto libre) | solo forma |
| `project` | wikilink o id | cualquier tipo | proyecto al que aporta la página | destino resoluble → arista `related` hacia la ficha; no resoluble → `broken_link` |
| `area` | wikilink o id | cualquier tipo | área a la que pertenece | idem |
| `problems` | array de slugs `fp-<n>` | cualquier tipo | favorite problems a los que aporta | si existe la página `synthesis/favorite-problems` → una arista `related` hacia ella (la entrada `fp-<n>` concreta solo importa para `problem_unfed`); página ausente → sin arista, sin hallazgo |
| `packet` | enum `distilled-note`, `outtake`, `wip`, `deliverable`, `external` | cualquier tipo | Intermediate Packet reutilizable | fuera del enum → violación `packet: invalid '<v>'`; presente y válido → entra a `packets.json` |
| `distill` | entero 1..4 | `summary` (tolerado en otros) | capa de Progressive Summarization alcanzada | fuera de rango → violación `distill: invalid` |
| `description` | string (una línea) | los seis tipos | gancho de `index.md`; unidad de "distill on read" | ausente o vacía → `description_missing` **solo si** `para` está declarado o `created >= fecha del delta` (ver §4) |

Notas:
- **Valor vacío = clave ausente** para `para`, `packet`, `distill`, `due`, `next_review`, `archived`: las
  plantillas traen `due: ""`/`next_review: ""` y no deben producir violación (molde `status`,
  `wiki_graph.sh:174`); solo un valor NO vacío e inválido es violación.
- `tags` (clave de 014 que el parser nunca extrajo) pasa a extraerse y a poblarse en el nodo, cerrando el
  drift del contrato `graph-artifacts.md:31-33`.
- `status` conserva su enum y su semántica de frescura. `para: archive` **no** cambia `status`.
- Los valores se normalizan como en 014 (comillas envolventes fuera; `[[wikilink]]` desenvuelto en
  `project`/`area` igual que en `related`).

## 2. Plantillas y páginas especiales

| Artefacto | Ubicación | Contenido |
|---|---|---|
| Plantilla ficha de proyecto | `modules/vault-skeleton/_templates/entity-project.md` | `type: entity`, `para: project`, `goal`, `due`, `next_action`, `next_review`, `description`, `related: []`, `sources: []`; secciones `## Goal`, `## Outline (archipelago)`, `## Packets`, `## Log` (pointer to `log.md`) |
| Plantilla página de área | `modules/vault-skeleton/_templates/overview-area.md` | `type: overview`, `para: area`, `standard`, `cadence`, `next_review` (opcional), `description`; secciones `## Standard`, `## Indicators`, `## Active projects`, `## Key resources` |
| `summary.md` (extendida) | `_templates/summary.md` | + `distill: 1`, `description`; resumen ejecutivo arriba; secciones opcionales `## Highlights` (capa 2), `## Core` (capa 3) |
| Resto de plantillas | `_templates/{entity,concept,comparison,overview,synthesis}.md` | + `description` (obligatoria en páginas nuevas); `packet` comentado como opcional |
| Página de favorite problems | `wiki/synthesis/favorite-problems.md` — **creada bajo demanda**, nunca en el skeleton | `type: synthesis`, `status: active`, `description`; cuerpo: lista numerada `1. **fp-1** — <pregunta>` donde "pregunta" = termina en `?` o empieza por How, What, Why, When, Which, Cómo, Qué, Por qué, Cuándo, Cuál (misma regla que CANON-F6); máximo 12 entradas |
| `index.md` (skeleton) | `modules/vault-skeleton/index.md` | + secciones `## Projects (active)`, `## Areas`, `## Archive`, `## Packets`, `## Favorite problems`, cada una con su comentario de formato; ninguna entrada semilla |
| `log.md` (skeleton) | `modules/vault-skeleton/log.md` | línea de formato ampliada: `{ingest\|query\|lint\|init\|upgrade\|project-open\|project-close\|review\|session\|other}` |

Identidad: la ficha de proyecto se identifica por su id de nodo `entities/<slug>`; el puntero de
auto-memoria usa el mismo `<slug>` (`project_<slug>.md`). La página de favorite problems tiene id fijo
`synthesis/favorite-problems`; sus entradas se identifican por slug `fp-<n>` estable (nunca se renumeran; una
entrada retirada deja su número libre pero no reutilizado).

## 3. Puntero de auto-memoria

`<auto-memoria>/project_<slug>.md` queda reducido a un puntero. Forma (respetando el frontmatter que la
auto-memoria exige hoy, `docs/state-layout.md`):

```markdown
---
name: project_<slug>
description: <estado en una frase>
type: project
---
Estado: <una frase>. Ficha: [[entities/<slug>]] en el vault. Última revisión: YYYY-MM-DD.
```

Regla: sin estado adicional (ni tareas, ni decisiones, ni fechas más allá de la última revisión). El delta
0.27.0 trae la nota de migración: para cada `project_*` existente, crear o completar la ficha en el vault y
reducir el archivo de auto-memoria a esta forma.

## 4. Hallazgos nuevos (`findings.json`, schema 1, aditivo)

Cada hallazgo conserva la forma `{kind, page, detail}`. `page` es el id de nodo (`<type>/<slug>`) cuando
el hallazgo es sobre una página del wiki; para hallazgos sobre archivos que no son nodos se usa la ruta
relativa al vault (`raw_sources/...`, `_templates/...`). Orden estable por `kind`, luego `page`.

| kind | page | detail (formato) | Condición | Supresiones |
|---|---|---|---|---|
| `frontmatter_violation` (razones nuevas) | id | `para: invalid 'x'`, `packet: invalid 'x'`, `distill: invalid 'x'`, `due: malformed 'x'`, `next_review: malformed 'x'`, `archived: missing`, `archived: malformed 'x'`, `favorite_problems: 13 entries (max 12)`, `favorite_problems: fp-4 is not a question` | ver §1 | ninguna |
| `project_incomplete` | id | `missing: goal,due,next_action` (subconjunto, orden fijo) | `para: project` y falta alguno de los tres | `para: archive` no aplica (no es project) |
| `project_overdue` | id | `due: 2026-09-01 (25 days)` | `para: project`, `due` válido y `due < TODAY` | nunca en `para: archive` |
| `review_due` | id | `next_review: 2026-09-10 (16 days)` o `next_review: missing` | `para: project` y (`next_review` ausente o `< TODAY`) | nunca en `para: archive`; `area` no genera `review_due` |
| `pending_ingest` | `raw_sources/<ruta>.md` | `no summary cites this source (clipped: 2026-08-30)` | archivo `raw_sources/**/*.md` con clave `clipped:` cuyo path (normalizado) no aparece en ningún `sources:` de una página `summary` | binarios y `.md` sin `clipped:` fuera del dominio |
| `description_missing` | id | `para: project` o `created: 2026-10-02 >= delta 2026-09-30` | `description` ausente o vacía **y** (`para` declarado **o** `created >= DELTA_DATE`) | páginas preexistentes sin `para` |
| `problem_unfed` | `synthesis/favorite-problems` | `fp-3: 31 days without entries (threshold 30)` | la página existe; ninguna página con `problems` que incluya `fp-3` tiene `updated` en los últimos N días | página ausente → 0 hallazgos |
| `archive_candidate` | id | `status: stale; backlinks: 0; last log mention: none` | `status` es `stale` o `superseded` **y** `backlinks` vacío **y** ninguna línea de `log.md` de los últimos N días menciona el id | `para: archive` (ya archivado) |
| `schema_delta_pending` | `_templates/schema-updates-0.27.0.md` | `deposited 2026-09-30 (16 days); vault CLAUDE.md lacks '## Actionability (PARA)'` | marcador `.schema-updates-0.27.0.applied` presente con fecha (contenido del archivo; fallback mtime) más antigua que N días **y** el `CLAUDE.md` del vault no contiene la cadena de integración | integrado → 0 |

Supresión sobre hallazgos de 014: una página `para: archive` **no** genera `orphan` ni `stale` (sí sigue
generando `broken_link`, `frontmatter_violation`, `index_drift` y `alias_occurrence`).

`TODAY`: la fecha ISO de la corrida (`date -u +%F`), sobreescribible con `WIKI_GRAPH_TODAY=YYYY-MM-DD` para
tests deterministas (seam, mismo patrón que `WIKI_GRAPH_VAULT_DIR`). `DELTA_DATE` (regla única, análisis M I5):
el marcador `_templates/.schema-updates-0.27.0.applied` existe y parsea (`deposited: YYYY-MM-DD`) → esa
fecha; existe pero no parsea (incluido vacío) → su mtime; no existe → `""`. Un scaffold nuevo nace con el
marcador fechado al día de la siembra (lo escribe `vault_seed_if_empty`, ver §7), así que "sin marcador"
significa "vault que no recibió el delta" (p. ej. `seed_skeleton: false`) y en ese caso `description_missing`
gatea SOLO por `para` declarado, nunca por `created` (análisis M U3).

## 5. Nodos y aristas (`graph.json`, schema 1, aditivo)

Nodo: `{id, type, title, status, created, updated, tags, para, description, packet, distill, due,
next_review, archived, project, area, problems}` — los campos nuevos van con `""`/`[]` cuando faltan; `para`
ausente se emite como `"resource"` (normalizado) para que los consumidores no repitan la regla.

Aristas nuevas: `{from: <página>, to: <ficha|área|favorite-problems>, kind: "related", broken: <bool>}`
emitidas desde `project`, `area` y `problems`. Al ser kind `related`, alimentan `backlinks` (regla H2 de
014: un `related:` entrante cuenta siempre) y por tanto retiran a la ficha del conjunto `orphan`. Un
`problems: [fp-9]` cuya página o entrada no existe **no** emite arista ni hallazgo.

## 6. Artefactos derivados nuevos bajo `<vault>/.graph/` (JSON, atómicos, nunca respaldados)

### `packets.json` (schema 1)

```json
{
  "schema": 1,
  "generated_at": "2026-10-05T06:20:00Z",
  "packets": [
    {"id": "concepts/kickoff-checklist", "type": "concept", "packet": "distilled-note",
     "description": "Checklist reutilizable para abrir un proyecto", "project": "entities/proyecto-x",
     "updated": "2026-10-01"}
  ]
}
```

Orden: `updated` descendente, luego `id`. Lista vacía cuando no hay `packet:` (el archivo existe siempre).

### `policy.json` (schema 1)

Canal por el que las perillas de `agent.yml` llegan al agente sin tocar el `CLAUDE.md` del vault ni el del
workspace (que no se refresca en agentes existentes):

```json
{
  "schema": 1,
  "generated_at": "...",
  "review": {"project_days": 7, "area_days": 30},
  "archive": {"candidate_days": 90},
  "thresholds": {"delta_pending_days": 14, "problem_unfed_days": 30, "index_first_max_pages": 300},
  "collection": {"layout": "wiki-root", "migration": "done"}
}
```

El schema del vault (delta) instruye: "read `.graph/policy.json` for cadences and thresholds; if absent, use
7/30/90/14/30/300". El runner lo escribe en cada corrida leyendo `agent.yml` con yq (mismo mecanismo que
`wiki_graph_enabled`, `wiki_graph.sh:49-60`, confirmado en K §1) más los overrides de entorno para tests.

### `wiki-graph.json` (state, schema 1, aditivo)

`counts` gana claves con default 0: `project_incomplete`, `project_overdue`, `review_due`,
`pending_ingest`, `description_missing`, `problem_unfed`, `archive_candidate`, `schema_delta_pending`,
`packets`, `para_project`, `para_area`, `para_archive`. `last_status` y el contrato 0/1/2 de doctor no cambian.

**Contadores de `status` (lista canónica, ambos modos, orden fijo)**: `review_due`, `project_overdue`,
`project_incomplete`, `pending_ingest`, `archive_candidate`, `schema_delta_pending`, `problem_unfed`, más
el estado de la colección (`collection_layout`, `migration`). Todo consumidor (`agentctl` local,
`heartbeatctl status`, el prompt del aviso CANON-H1) usa exactamente estos siete en este orden.

## 7. Delta 0.27.0 y marcador

| Artefacto | Ruta | Contenido |
|---|---|---|
| Delta | `<vault>/_templates/schema-updates-0.27.0.md` (fuente: `modules/vault-deltas/schema-updates-0.27.0.md`) | Secciones nuevas del schema en inglés, listas para pegar en el `CLAUDE.md` del vault: `## Actionability (PARA)`, extensión de `## Frontmatter spec`, `## Operation: project kickoff`, `## Operation: project close`, `## Operation: weekly review`, `## Operation: monthly review`, paso 0 de query (index-first gateado), paso 0.5 de ingest (favorite problems), política de filing, regla de cierre de sesión (Hemingway Bridge), packets, nota de migración de `project_*`, línea de formato de `log.md`. Incluye la **cadena de integración** que `schema_delta_pending` busca: el encabezado literal `## Actionability (PARA)`. |
| Marcador | `<vault>/_templates/.schema-updates-0.27.0.applied` | contenido: `deposited: YYYY-MM-DD` (a diferencia del marcador 0.8.0, que está vacío); es la fuente de `DELTA_DATE` y del cómputo de `schema_delta_pending`. Lo escriben DOS caminos: el bloque 0.27.0 de `vault_seed_missing` al depositar el delta en un vault existente, y `vault_seed_if_empty` al sembrar un scaffold nuevo (fecha de siembra, sin delta: el schema ya integra las secciones, así que `schema_delta_pending` es 0 por construcción) |
| Línea de log | `log.md` | `## [YYYY-MM-DD] upgrade \| schema delta 0.27.0 deposited — integrate _templates/schema-updates-0.27.0.md into CLAUDE.md` |

Estados del vault frente al upgrade (fixtures de test): (a) pre-014 (sin `normalization/`, sin marcadores)
→ recibe 0.8.0 y 0.27.0; (b) 0.8.0 completo con wiki vacía → recibe solo 0.27.0; (c) 0.8.0 con páginas →
recibe solo 0.27.0 y **0 archivos preexistentes cambian**. Segunda corrida en cualquier estado: no-op.

## 8. Colección de búsqueda: layout y sentinel

| Elemento | Valor |
|---|---|
| Layout nuevo (scaffold nuevo) | colección `vault` con raíz `<vault>` y máscara `wiki/**/*.md` (medido en L: excluye `_templates/`, `raw_sources/`, `index.md`, `log.md`, `CLAUDE.md`; `.graph/` nunca entra por ser JSON; las URIs `qmd://vault/wiki/...` se conservan) |
| Layout heredado | colección `vault` con raíz `<vault>` y máscara `**/*.md` |
| Sentinel | `<cache root de qmd>/.qmd-collection-wiki` con contenido `wiki-root <YYYY-MM-DD>`; cache root confirmado (K §3, L Q1) = `.state/.cache/qmd/` en ambos modos (docker `/home/agent/.cache/qmd`; local `QMD_CACHE_HOME=<ws>/.state/.cache/qmd`); nunca en el vault |
| Detección "pendiente" | sentinel ausente **y** `index.sqlite` presente (colección heredada existe); `status`/`doctor` la calculan **en vivo** sobre esos dos archivos (no solo leen el state, que lo escribe el mismo tick que migra), para que `pending` sea visible antes del primer tick |
| Detección "hecha" | sentinel presente |
| Scaffold nuevo | `qmd_setup_if_needed` crea la colección sobre `wiki/` y escribe el sentinel en el mismo acto (no hay migración) |
| Acción | `qmd-migrate` (docker: subcomando de `heartbeatctl`; local: acción de `agentctl`, patrón 013): `collection remove vault` → `collection add <vault> --name vault --mask 'wiki/**/*.md'` → `update` → sentinel → `cleanup` (purga vectores huérfanos; SIEMPRE después del `add`, nunca antes, para reutilizar embeddings) → `embed` solo si `status` reporta `Pending`. Disparo: **automático** en el primer tick de reindexado tras la actualización (decisión del operador 2026-09-27). Acción manual `qmd-migrate`: sin flags idempotente (sentinel presente → `already migrated`, rc 0, sin tocar qmd), `--dry-run` solo imprime estado y pasos, `--force` recrea aunque exista el sentinel. Fallo a mitad: `last_status: error`, hash intacto, `migration: pending`, reintento desde `remove` en el tick siguiente |
| Estado | `qmd-index.json` gana `collection_layout: "vault-root" \| "wiki-root" \| "none"` y `migration: "pending" \| "done" \| "n/a"` (`none`/`n/a` sin `index.sqlite`); `status`/`doctor` lo leen |

Transiciones: `vault-root (legacy)` → [primer tick de reindexado tras la actualización, o `qmd-migrate`
manual] → `wiki-root`. Exactamente una vez; nunca de vuelta. Un scaffold nuevo nace en `wiki-root`.

## 9. Configuración nueva en `agent.yml`

```yaml
vault:
  review:
    project_days: 7        # cadencia por defecto de next_review para para: project
    area_days: 30          # idem para para: area (opcional)
  archive:
    candidate_days: 90     # días sin backlinks ni menciones en log.md para archive_candidate
features:
  heartbeat:
    review:
      enabled: false       # aviso semanal (docker only)
      schedule: "7 9 * * 1"   # cron de 5 campos; día de semana permitido (docker crontab); minuto 7 fuera de la rejilla */N del tick regular
      prompt: "<prompt por defecto del aviso, ver contracts/heartbeat-review-notice.md>"
```

Flatten (`render_load_context`): `VAULT_REVIEW_PROJECT_DAYS`, `VAULT_REVIEW_AREA_DAYS`,
`VAULT_ARCHIVE_CANDIDATE_DAYS`, `FEATURES_HEARTBEAT_REVIEW_ENABLED`, `FEATURES_HEARTBEAT_REVIEW_SCHEDULE`,
`FEATURES_HEARTBEAT_REVIEW_PROMPT`. Validación de forma: enteros positivos (1..3650) para los días, con
degradación al default y aviso (patrón `channel_health_timeout`/`mcp_timeout_effective`); booleano en
`schema.sh` para `enabled`; cron de 5 campos para `schedule` (validador nuevo `_v_cron5` en `heartbeatctl`: no existía
ninguno, K §5; rechaza `*`/`*/N` en el minuto y valores fuera de rango). Backfill en `regenerate()` con `has()` (nunca `//`). Touchpoints de tests: la
lista exacta de sub-claves de `vault` en `tests/schema.bats:42-43` gana `archive review`; fixtures
`sample-agent*.yml` ganan los bloques; ningún `{{VAR}}` nuevo entra a plantillas ni a `known_external`
(`schema.bats:52-117` solo verifica placeholder → producido, sin chequeo inverso; contrato agent-yml §1,
refutación N C11). Sin prompt de wizard.

Constantes con override por entorno (no en `agent.yml`): `WIKI_GRAPH_DELTA_PENDING_DAYS` (14),
`WIKI_GRAPH_PROBLEM_UNFED_DAYS` (30); `index_first_max_pages` (300) es prosa del schema y valor de
`policy.json`, sin lector en código.

Las cuatro claves muertas (`vault.initial_sources`, `vault.mcp.server`, `vault.schema.frontmatter_required`,
`vault.schema.log_format`) se documentan como **reservadas** en `docs/vault.md`; no se retiran.

## 10. Aviso semanal (docker)

| Elemento | Valor |
|---|---|
| Entrada de crontab | una línea adicional, escrita por `heartbeatctl cmd_reload` solo con `features.heartbeat.review.enabled: true`: `<schedule> HEARTBEAT_TRIGGER=review /workspace/scripts/heartbeat/heartbeat.sh --trigger review --prompt "$(cat /workspace/scripts/heartbeat/review-prompt.txt)" >> …/logs/review.log 2>&1` (flags ya parseados por el runner, `heartbeat.sh:37-43`; `runs.jsonl` registra `trigger: review`) |
| Prompt por defecto | lee `<vault>/.graph/findings.json` y `wiki-graph.json` por ruta (no depende de MCP), reporta contadores de `review_due`, `project_overdue`, `project_incomplete`, `pending_ingest`, `archive_candidate`, `schema_delta_pending` y a lo más tres ítems; con todo en cero responde exactamente `sin pendientes` (`nothing pending` en agentes `en`); no usa herramientas de escritura |
| Registro | una línea en `runs.jsonl` con `trigger: review`; el notifier configurado la entrega como cualquier tick |
| Invariantes | `enabled: false` → crontab byte-idéntico a v0.26.0; el prompt regular (`features.heartbeat.default_prompt`) no cambia; la entrada es independiente de `features.heartbeat.enabled` y de `heartbeatctl pause` (como las otras líneas de mantenimiento; se silencia con `review.enabled: false`); local: sin entrada, documentado |

## 11. Ciclo de vida de una página bajo PARA (transiciones)

```
(sin para) = resource ──kickoff──▶ para: project ──close──▶ para: archive (+ archived:)
                       ──(humano)──▶ para: area
para: archive ──reabrir (raro, humano)──▶ para: project (borra archived:, fija next_review)
```

- Kickoff: crea o completa la ficha (`goal`, `due`, `next_action`, `next_review = TODAY + project_days`),
  enlaza páginas relacionadas (`related:` recíproco), lee `packets.json`, escribe `project-open` en `log.md`,
  crea o reduce el puntero de auto-memoria.
- Revisión: al atender un `review_due`, el agente fija `next_review = TODAY + project_days`, actualiza
  `next_action`, escribe `review | weekly — …` en `log.md`.
- Cierre: `para: archive` + `archived: TODAY`, refresca `updated:` (la página cambió), opcionalmente una línea
  de outcome en el cuerpo, extrae packets, mueve la entrada de `index.md` a `## Archive`, reduce el puntero,
  escribe `project-close`. Nunca mueve archivos ni toca `status`.
- Un cambio de `para` re-indexa y re-embebe esa página por sí solo (medido en L: qmd hashea el archivo
  completo); no hay mitigación que aplicar.

## 12. Invariantes transversales

1. Ningún script escribe en `wiki/`, `raw_sources/`, `index.md`, `log.md` ni `CLAUDE.md` del vault; el
   runner solo escribe bajo `.graph/` (JSON) y el state file; el upgrade solo crea archivos ausentes bajo
   `_templates/` y anexa a `log.md` (única excepción heredada de 014).
2. Todo derivado nuevo es JSON bajo `.graph/`: fuera del backup (`*.md` only) y fuera de la colección qmd
   (son JSON, y la máscara `wiki/**/*.md` sobre la raíz del vault tampoco los alcanza).
3. Skeleton limpio → exactamente 0 hallazgos (ninguna página semilla).
4. Vault existente sin claves nuevas → 0 hallazgos nuevos salvo `schema_delta_pending` pasado el umbral
   (que es precisamente la señal deseada).
5. `TODAY`, `DELTA_DATE` y los umbrales son inyectables en tests; ningún oráculo depende del calendario.
