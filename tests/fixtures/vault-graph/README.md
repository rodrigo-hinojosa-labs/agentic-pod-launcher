# Fixture: vault-graph (oráculo de SC-001)

Vault con hallazgos estructurales CONOCIDOS y EXACTOS. `tests/wiki-graph.bats` corre el
runner sobre una copia de este árbol y asserta contra este inventario (0 falsos +/−).

## Nodos (7) — páginas bajo `wiki/<6-types>/`

| id | type | notas |
|---|---|---|
| `summaries/alpha` | summary | active; `sources: [raw_sources/articles/base.md]` → candidato stale |
| `entities/acme` | entity | `related: [[overviews/topic]]`; muchos backlinks |
| `concepts/widget` | concept | `title: ""` (vacío-presente → NO es violación, L6); NO listado en index → missing_from_index |
| `overviews/topic` | overview | hub; body con alias `SENCOSUD` en prosa + display-alias en wikilink + fence |
| `concepts/orphan-note` | concept | ORPHAN — sin backlinks (index.md no cuenta como arista) |
| `comparisons/broken` | comparison | BROKEN — body linkea `[[concepts/ghost-x]]` inexistente |
| `synthesis/badfm` | synthesisX | FRONTMATTER_VIOLATION — `type` inválido (sí es nodo igual) |

`wiki/normalization/cencosud.md` NO es nodo (canonical `Cencosud`, alias `SENCOSUD`,
`entity: [[entities/acme]]`).

## Inventario EXACTO de hallazgos

| kind | count | dónde |
|---|---|---|
| `orphan` | 1 | `concepts/orphan-note` |
| `broken_link` | 1 | `comparisons/broken` → `concepts/ghost-x` |
| `frontmatter_violation` | 1 | `synthesis/badfm` (type inválido) |
| `index_drift` | 2 | `missing_file`: `concepts/ghostpage` · `missing_from_index`: `concepts/widget` |
| `stale` | 1 | `summaries/alpha` (el test hace `touch` de `base.md` a fecha > `updated:`+1d) |
| `alias_occurrence` | 1 | `overviews/topic` (prosa `SENCOSUD` → `Cencosud`) |

Total findings esperados: **7**.

## Casos negativos deliberados (NO deben aparecer)

- `concepts/widget` con `title: ""` → NO `frontmatter_violation` (L6: requerido = clave presente).
- `[[entities/acme|SENCOSUD]]` en `overviews/topic` → NO `alias_occurrence` (L5: alias dentro de wikilink).
- `echo SENCOSUD` en fenced code de `overviews/topic` → NO `alias_occurrence` (fence excluido).
- `SENCOSUD` en `wiki/normalization/cencosud.md` → NO `alias_occurrence` (normalization/ excluida del escaneo).
- `[[summaries/example-should-be-ignored]]` en comentario HTML de `index.md` → NO `index_drift` (H3: comentarios excluidos).
- `related: ["[[overviews/topic]]"]` (comillas + wikilink) en `entities/acme` → arista válida, NO `broken_link` (H4: strip + desenvolver).

## mtime y stale

`stale` depende del mtime del archivo de `sources:`. Un `cp` a tmpdir deja mtime = ahora
(> `updated:`), así que `summaries/alpha` sale stale por defecto en los tests; el test
puede fijarlo explícito con `touch -d`.
