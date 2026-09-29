# Fixture: vault-graph-para (oráculo de US1/US3/US4/US5/US6/US7/US8, feature 037)

Vault con `WIKI_GRAPH_TODAY=2030-06-15` fijo. `CLAUDE.md` es una copia byte a byte del
skeleton **pre-037** (sin `## Actionability (PARA)`, CANON-D1) — a propósito, para que
`schema_delta_pending` tenga algo que reportar. El marcador
`_templates/.schema-updates-0.27.0.applied` trae `deposited: 2030-05-01`.

21 nodos bajo `wiki/`, 0 de índice caído (`index.md` los lista todos), 3 raw sources.

## project_incomplete / project_overdue / review_due (US1/US3)

| page | goal | due | next_action | next_review | finding |
|---|---|---|---|---|---|
| `entities/proj-active` | sí | 2030-08-01 (futuro) | sí | 2030-07-01 (futuro) | ninguno |
| `entities/proj-incomplete` | **falta** | 2030-09-01 | **falta** | 2030-08-01 | `project_incomplete: missing: goal,next_action` |
| `entities/proj-overdue` | sí | 2030-05-01 (**45 días**) | sí | 2030-06-01 (**14 días**) | `project_overdue: due: 2030-05-01 (45 days)` + `review_due: next_review: 2030-06-01 (14 days)` |
| `entities/proj-no-review` | sí | 2030-09-01 | sí | **ausente** | `review_due: next_review: missing` |
| `entities/proj-nodesc` | sí | 2030-09-01 | sí | 2030-09-01 (futuro) | ninguno de esta tabla (ver description_missing) |
| `entities/proj-badpara` (`para: projet`) | — | — | — | — | NO cuenta (para ≠ "project" exacto) |
| `entities/proj-archived` (`para: archive`) | — | due/next_review pasados | — | — | excluido por `para==archive` |

Totales: `project_incomplete`=1, `project_overdue`=1, `review_due`=2.

## description_missing (US4)

| page | description | para | created | finding |
|---|---|---|---|---|
| `entities/proj-nodesc` | ausente | `project` (declarado) | 2030-01-01 | `para: project` |
| `entities/proj-badpara` | `""` (vacía = ausente) | `projet` (declarado, inválido) | 2030-01-01 | `para: projet` |
| `concepts/new-undescribed` | ausente | ausente | 2030-06-01 (≥ delta 2030-05-01) | `created: 2030-06-01 >= delta 2030-05-01` |
| `summaries/note-proj-active` | ausente | ausente | 2030-01-01 (< delta) | ninguno (preexistente) |

Total `description_missing` = 3.

## packets (US5)

| page | packet | listado en packets.json |
|---|---|---|
| `summaries/packet-good` | `wip` (válido) | sí — `{id, type:summary, packet:wip, description, project:null, updated:2030-06-05}` |
| `concepts/packet-bad` | `nope` (inválido) | no — además `frontmatter_violation: packet: invalid 'nope'` (CANON-F2) |

`counts.packets` = 1.

## favorite problems (US6)

`synthesis/favorite-problems` lista `fp-1` (pregunta), `fp-2` (pregunta), `fp-3` (**no** es
pregunta → CANON-F6 `favorite_problems: fp-3 is not a question`).

- `concepts/problem-fp1-fed` → `problems: [fp-1]`, `updated: 2030-06-10` (5 días) → fp-1 **fed**.
- Nadie referencia `fp-2` ni `fp-3` → **unfed**. Regla de fallback (sin página que lo
  alimente): se usa el `created:` de la propia página `favorite-problems` (2030-01-01) como
  piso de "última vez tocado" → 165 días. `problem_unfed`: `fp-2: 165 days without entries
  (threshold 30)` y `fp-3: 165 days without entries (threshold 30)`.
- Con `WIKI_GRAPH_PROBLEM_UNFED_DAYS=400`: 165 < 400 → 0 `problem_unfed`.
- `concepts/problem-fp9-ref` → `problems: [fp-9]` (no listado en el cuerpo de
  `favorite-problems`) → crea la arista `related` hacia `synthesis/favorite-problems`
  (el nodo existe) pero **ningún hallazgo** (fp-9 no se seguimiento porque no aparece en el
  cuerpo del catálogo).

Total `problem_unfed` = 2 (default), 0 con el override.

## archive_candidate (US8)

| page | status | backlinks | mención en log.md | candidato (default, 90 días) | candidato (override 1 día) |
|---|---|---|---|---|---|
| `concepts/candidate-stale` | stale | 0 | ninguna | sí — `status: stale; backlinks: 0; last log mention: none` | sí (mismo detail) |
| `concepts/candidate-mentioned` | stale | 0 | `2030-06-10` (5 días) | no (dentro de 90 días) | sí — `status: stale; backlinks: 0; last log mention: 2030-06-10` |
| `concepts/candidate-superseded-linked` | superseded | 1 (desde `problem-fp9-ref`) | — | no (tiene backlink) | no |
| `entities/proj-archived` | active, `para: archive` | 0 | — | excluido por `para==archive` | excluido |

Total `archive_candidate` = 1 (default), 2 (con `WIKI_GRAPH_ARCHIVE_CANDIDATE_DAYS=1`).

## pending_ingest

- `raw_sources/articles/uncited.md` (`clipped: 2030-06-01`) → nadie lo cita →
  `pending_ingest: no summary cites this source (clipped: 2030-06-01)`.
- `raw_sources/articles/cited.md` (`clipped: 2030-06-01`) → citado por
  `summaries/cited-summary` (`sources:`) → sin hallazgo.
- `raw_sources/articles/archived-source.md` → **sin** `clipped:` → no se enumera (no cuenta
  como pending ni como citado); solo sirve para el `sources:` de `entities/proj-archived` y
  para que el test le toque el mtime (`touch -d`) al verificar la supresión de `stale` por
  `para==archive`.

Total `pending_ingest` = 1.

## schema_delta_pending (US7)

Marcador `deposited: 2030-05-01`, `CLAUDE.md` sin CANON-D1, `TODAY=2030-06-15` → 45 días
(> 14 default) → `schema_delta_pending: deposited 2030-05-01 (45 days); vault CLAUDE.md
lacks '## Actionability (PARA)'` sobre `page: _templates/schema-updates-0.27.0.md`.
Con `WIKI_GRAPH_DELTA_PENDING_DAYS=60` o `WIKI_GRAPH_TODAY=2030-05-10` (9 días) → 0.

Total `schema_delta_pending` = 1 (con la configuración por defecto y `TODAY=2030-06-15`).

## broken_link nuevo (project:/area:)

`summaries/dangling-project` → `project: [[entities/no-existe]]` → arista `related` rota →
`broken_link: page=summaries/dangling-project, detail=entities/no-existe`.

## Aristas `related` desde project:/area:/problems:

- `summaries/note-proj-active` → `entities/proj-active` (via `project:`)
- `concepts/area-note` → `overviews/area-main` (via `area:`)
- `concepts/problem-fp1-fed` → `synthesis/favorite-problems` (via `problems:`)
- `concepts/problem-fp9-ref` → `synthesis/favorite-problems` (via `problems:`)

Estas cuatro aristas nuevas, más las dos preexistentes por wikilink (`entities/proj-active`
→ `summaries/note-proj-active` en el cuerpo; `concepts/problem-fp9-ref` →
`concepts/candidate-superseded-linked` en el cuerpo), las dos por `sources:`
(`entities/proj-archived`, `summaries/cited-summary`) y la arista rota
`summaries/dangling-project` → `entities/no-existe` (via `project:`, cuenta como arista
aunque `broken: true`), dan **9 aristas** totales bajo el parser 037 (verificado por
ejecución directa: `jq '.edges' .graph/graph.json`; bajo el parser PRE-037, que ignora
`project:`/`area:`/`problems:`, solo se ven 4: las 2 wikilink + las 2 source).

## orphan (con el parser 037)

Nodos con backlink: `entities/proj-active`, `summaries/note-proj-active`,
`overviews/area-main`, `synthesis/favorite-problems`, `concepts/candidate-superseded-linked`
(5 nodos). De los 16 restantes, `entities/proj-archived` se excluye por `para==archive` →
**15 `orphan`**.

## stale (supresión por para==archive)

El test toca (`touch -d`) el mtime de `raw_sources/articles/archived-source.md` a una fecha
posterior a `updated: 2030-01-01` + 1 día de `entities/proj-archived` (que tiene
`status: active`). Sin la supresión por `para=="archive"` saldría `stale`; con ella, **0**
apariciones en `findings.json` (aunque el cálculo interno sí lo incluya en el set antes del
filtro `para!="archive"`).

## F1-F6 (violaciones de forma)

- F1: `entities/proj-badpara` → `para: invalid 'projet'`.
- F2: `concepts/packet-bad` → `packet: invalid 'nope'`.
- F3/F4/F5: ninguno en esta fixture (0).
- F6: `synthesis/favorite-problems` → `favorite_problems: fp-3 is not a question`.

## Resumen de counts esperados (`WIKI_GRAPH_TODAY=2030-06-15`, config por defecto)

| count | valor |
|---|---|
| nodes | 21 |
| edges | 9 |
| orphans | 15 |
| broken_links | 1 |
| frontmatter_violations | 3 (F1 + F2 + F6) |
| index_drift | 0 |
| stale | 0 |
| alias_occurrences | 0 |
| project_incomplete | 1 |
| project_overdue | 1 |
| review_due | 2 |
| description_missing | 3 |
| pending_ingest | 1 |
| problem_unfed | 2 |
| archive_candidate | 1 |
| schema_delta_pending | 1 |
| packets | 1 |
| para_project | 5 (los cinco `entities/proj-*` con `para: project` exacto; `proj-badpara` queda fuera — su valor crudo es `projet`, no normaliza a `project`) |
| para_area | 1 (`overviews/area-main`) |
| para_archive | 1 (`entities/proj-archived`) |

Determinismo: dos corridas con el mismo `WIKI_GRAPH_TODAY` producen `findings.json`
idéntico (sin timestamps embebidos salvo `generated_at`, que no forma parte del diff de
`findings`).
