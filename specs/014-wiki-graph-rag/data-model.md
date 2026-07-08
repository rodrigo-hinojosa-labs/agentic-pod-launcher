# Data Model: 014-wiki-graph-rag

Entidades, atributos, relaciones y reglas de validación. Los shapes JSON normativos viven
en `contracts/graph-artifacts.md`; aquí va el modelo conceptual.

## Nodo (página wiki)

Una página `wiki/<type>/<slug>.md`. Identidad: path relativo al vault sin extensión
(`<type>/<slug>`), que coincide con la forma de los wikilinks del schema.

| Campo | Origen | Tipo | Reglas |
|---|---|---|---|
| `id` | path | string | `<type-dir>/<slug>`, único por construcción (filesystem) |
| `type` | frontmatter `type:` | enum | uno de los 6: summary, entity, concept, comparison, overview, synthesis |
| `title` | frontmatter `title:` | string | requerido = CLAVE presente (valor `""` OK, L6) |
| `status` | frontmatter `status:` | enum | draft, active, stale, superseded |
| `created` / `updated` | frontmatter | date | `YYYY-MM-DD`; `updated >= created` |
| `tags` | frontmatter `tags:` | list | opcional |
| `sources` | frontmatter `sources:` | list de paths | comillas/wikilink desenvueltos (H4); cada path debería existir bajo el vault |

"Requerido" (L6) = la CLAVE debe existir; un valor vacío (`title: ""`, que los templates del
skeleton emiten como placeholder) NO es violación. La excepción son `canonical`/`aliases`
de las páginas de normalización, que exigen valor no vacío (ver normalization-pages.md).

Violación de cualquier regla → hallazgo `frontmatter_violation` (el nodo se incluye igual
en el grafo con los campos que sí parsearon; la página nunca se omite completa).

Las páginas de `wiki/normalization/` NO son nodos de conocimiento: se modelan como
**Regla de normalización** (abajo) y se validan contra su propio spec.

## Arista

Relación dirigida `from → to` con `kind`:

| `kind` | Origen | Semántica |
|---|---|---|
| `wikilink` | `[[target]]` en el cuerpo (fuera de fences) | referencia editorial |
| `related` | frontmatter `related:` | relación declarada load-bearing |
| `source` | frontmatter `sources:` | nodo cita un raw source (destino = path fuente, no nodo) |
| `alias` | regla de normalización → `entity` | mención variante resuelve a la página canónica |

Reglas: una arista `wikilink`/`related` cuyo destino no existe como archivo genera hallazgo
`broken_link` (la arista se conserva marcada como rota para diagnóstico). Backlink de X =
toda arista `wikilink`/`related` con `to == X`. **Huérfano** (H2) = nodo con lista de
backlinks vacía; un `related:` entrante cuenta SIEMPRE como backlink, sin exigir
reciprocidad (esta es la definición normativa; plan D8 se alinea a ésta).

## Regla de normalización

Página `wiki/normalization/<slug>.md` con frontmatter PROPIO (clarify Q1):

| Campo | Tipo | Reglas |
|---|---|---|
| `canonical` | string | requerido, no vacío (ej. `Cencosud`) |
| `aliases` | list de strings | requerido, no vacío (ej. `[SENCOSUD, Sencosud]`) |
| `match_case` | bool | opcional, default `false` (matching case-insensitive) |
| `entity` | wikilink | opcional; si existe, genera arista `alias` hacia esa página |
| `notes` | string | opcional (ámbito, cuándo aplica) |

Validación por el linter contra ESTE spec; violación → `frontmatter_violation` con
`scope: normalization`.

## Hallazgo estructural

| `kind` | Ancla | Degrada doctor (clarify Q5) |
|---|---|---|
| `broken_link` | página + target | Sí — WARN |
| `frontmatter_violation` | página + campo | Sí — WARN |
| `index_drift` | entrada o archivo | Sí — WARN (subkinds: `missing_file`, `missing_from_index`) |
| `orphan` | página | No — informativo |
| `stale` | página + source | No — informativo |
| `alias_occurrence` | página + alias + canonical | No — informativo (cola de trabajo del agente) |

## Artefactos derivados (`<vault>/.graph/`)

| Archivo | Contenido | Consumidor |
|---|---|---|
| `graph.json` | nodos + aristas + metadatos de corrida | agente (análisis), humano (inspección) |
| `backlinks.json` | mapa por nodo: `backlinks[]`, `related_out[]`, `co_sourced[]`, `canonical_of[]` | agente en protocolo query (1 salto) |
| `findings.json` | lista de hallazgos tipados | agente (corrección), doctor (counts ya vienen del state file) |

Invariantes: solo extensiones no-`.md` (R5); escritura tmp+mv; regenerables siempre; nunca
en backup ni en qmd.

## State file (`<ws>/scripts/heartbeat/wiki-graph.json`)

Schema 1, patrón `qmd-index.json`:

```json
{
  "schema": 1,
  "last_run": "2026-07-06T12:00:00Z",
  "last_status": "ok | error",
  "duration_ms": 1234,
  "counts": {
    "nodes": 0, "edges": 0,
    "orphans": 0, "broken_links": 0, "frontmatter_violations": 0,
    "index_drift": 0, "stale": 0, "alias_occurrences": 0
  },
  "error": ""
}
```

Transiciones de `last_status`: `ok` (corrida completa) o `error` (vault inaccesible, fallo
interno — el proceso igual sale 0, Principle IV). NO hay estado `locked`: el perdedor del
flock sale 91 SIN escribir state (el ganador es la única corrida que actualiza este
archivo). El fallback de schedule NO es campo de este JSON: vive en el archivo marcador
`wiki-graph-schedule.fallback` (única fuente para status/doctor). Doctor: WARN si
`last_status=error` o counts de integridad (broken_links/frontmatter_violations/
index_drift) > 0; FAIL si el archivo falta o `last_run` > 2× intervalo (derivado del
schedule, fallback 24 h — ver graph-artifacts.md M6) con la feature habilitada.

## Delta de skeleton (upgrade aditivo)

Conjunto versionado de estructuras nuevas para vaults existentes:

- Estructuras: `wiki/normalization/` (+ `.gitkeep`), `_templates/normalization.md`.
- Delta de schema: `_templates/schema-updates-0.8.0.md` (origen: `modules/vault-deltas/`).
- Registro: entrada en `log.md` — `## [YYYY-MM-DD] upgrade | schema updates 0.8.0`.

Sentinel de idempotencia: existencia de `_templates/schema-updates-0.8.0.md` en el vault
destino. Regla dura: `vault_seed_missing` jamás sobreescribe un path existente y jamás
escribe `CLAUDE.md`.

## Config (`agent.yml`)

```yaml
vault:
  wiki_graph:
    enabled: true          # default: true cuando vault.enabled
    schedule: "20 */6 * * *"  # default; cron de 5 campos, cron→OnCalendar en local
```

Render vars precomputadas en `setup.sh` (D12): `WIKI_GRAPH_ENABLED`,
`WIKI_GRAPH_SCHEDULE`. Sin prompt nuevo de wizard.
