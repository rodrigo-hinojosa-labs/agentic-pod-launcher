# Contract: schema del vault 0.27.0 — secciones nuevas, delta y cadenas canónicas

Norma para `modules/vault-skeleton/CLAUDE.md` (scaffolds nuevos), `modules/vault-deltas/schema-updates-0.27.0.md`
(vaults existentes), `modules/vault-skeleton/{index.md,log.md,_templates/*}` y para los tests que los fijan
(`tests/vault.bats`, `tests/vault-upgrade.bats` o equivalente) y el hallazgo `schema_delta_pending`.

## 1. Principios

1. **Prosa, no código.** Todo lo que el agente "hace" en 037 (kickoff, close, revisiones, filing, cierre de
   sesión, filtro de captura, index-first, destilación) es instrucción en el schema del vault. Ningún script
   ejecuta esas operaciones ni edita páginas (014 FR-005, ratificado).
2. **Un solo texto, dos vehículos.** Cada sección nueva existe **una vez** como texto y se entrega por dos
   vías: integrada en el `CLAUDE.md` del skeleton (scaffold nuevo) y como delta aparte para vaults
   existentes. Oráculo: cada sección `## …` del delta aparece **verbatim** (cuerpo incluido) en el
   `CLAUDE.md` del skeleton. Un test lo verifica sección por sección; si divergen, el test cae.
3. **Inglés.** Skeleton, delta y plantillas en inglés (decisión del operador). El agente habla en
   `user.language` igual que hoy.
4. **El humano decide.** Toda instrucción que archive, cierre, mueva fechas o declare resonancia se redacta
   como propuesta al humano; el texto usa "propose", "ask", "candidate", nunca "archive it" imperativo.
5. **Sin páginas semilla.** Ninguna sección instruye crear páginas al sembrar; todo se crea bajo demanda.

## 2. Cadenas canónicas (CANON-D*)

Literales que tests, delta, skeleton y runner comparten. Cambiarlas exige tocar los cuatro a la vez.

| Id | Literal (línea completa salvo indicación) | Dónde vive | Quién la lee |
|---|---|---|---|
| CANON-D1 | `## Actionability (PARA)` | skeleton `CLAUDE.md` + delta | `wiki_graph.sh` (`schema_delta_pending` busca esta línea en el `CLAUDE.md` del vault); tests |
| CANON-D2 | `## Operation: project kickoff` | idem | tests |
| CANON-D3 | `## Operation: project close` | idem | tests |
| CANON-D4 | `## Operation: weekly review` | idem | tests |
| CANON-D5 | `## Operation: monthly review` | idem | tests |
| CANON-D6 | `Step 0 — read the map first` (substring, dentro de la operación query) | idem | tests |
| CANON-D7 | `Step 0.5 — capture filter` (substring, dentro de la operación ingest) | idem | tests |
| CANON-D8 | `## Filing policy` | idem | tests |
| CANON-D9 | `## Session close (Hemingway Bridge)` | idem | tests |
| CANON-D10 | `## Intermediate packets` | idem | tests |
| CANON-D11 | `## Favorite problems` | idem | tests |
| CANON-D12 | `## Migration: project_* memory files` | **solo delta** (no aplica a un scaffold nuevo) | tests |
| CANON-D13 | `deposited: ` (prefijo de la única línea del marcador `_templates/.schema-updates-0.27.0.applied`, seguido de `YYYY-MM-DD`) | marcador | `vault.sh` (lo escriben dos caminos: el bloque 0.27.0 de `vault_seed_missing` al depositar el delta, y `vault_seed_if_empty` al sembrar un scaffold nuevo con la fecha de siembra y SIN delta), `wiki_graph.sh` (lee `DELTA_DATE`), tests |
| CANON-D14 | `upgrade \| schema delta 0.27.0 deposited` (substring de la línea de `log.md`) | `log.md` | tests (idempotencia: exactamente una ocurrencia tras dos corridas) |
| CANON-D15 | `{ingest\|query\|lint\|init\|upgrade\|project-open\|project-close\|review\|session\|other}` | skeleton `log.md` + delta (sección "log.md format") | tests |

Nota: los guiones largos de D6/D7 son el carácter U+2014 escrito como tal (el skeleton ya usa `—` en
`log.md`); se verifica byte a byte y no debe haber marcas combinantes (`LC_ALL=C grep -c $'\xcc\x80'` = 0
sobre skeleton, delta y bats — regla vigente desde 033/034).

## 3. Contenido obligatorio por sección

Cada sección se describe por lo que **debe** decir; la redacción final es tarea de implementación, pero
estos elementos son el oráculo de revisión (checklist del quickstart).

### 3.1 `## Actionability (PARA)` (CANON-D1)

- Define los cuatro valores de `para` y que ausente = `resource`.
- Tabla de claves auxiliares (las de data-model §1) con "when to set it".
- Regla: PARA vive en frontmatter; nunca carpetas; archivar nunca mueve archivos ni toca `status`.
- Regla de ruteo de estado de proyecto: "the project page in `wiki/entities/` is the single home of project
  state; the auto-memory `project_<slug>.md` is a 2–3 line pointer (one-sentence status, wikilink, last
  review date) and carries no further state".
- Sin regla de reindexado: la medición L (26-09-2026) demostró que qmd re-indexa y re-embebe una página
  ante cualquier cambio de bytes, frontmatter incluido; el texto NO pide bumpear `updated:` por eso (solo
  cuando el contenido cambia de verdad, como hoy).
- Vistas: secciones de `index.md` (`Projects (active)`, `Areas`, `Archive`, `Packets`, `Favorite problems`)
  y su formato de línea.

### 3.2 Frontmatter spec (extensión de la sección existente)

- Lista las claves nuevas como **optional** con su tipo y formato de fecha ISO.
- `description`: "required on every page created from now on; one line; it is the hook that goes to
  `index.md`". No exige retro-rellenar páginas existentes.
- `distill`: capas 1–4 con una línea por capa y la regla "raise it only when you are already touching the
  page for another reason; never run a distillation pass over the vault".

### 3.3 Query — `Step 0 — read the map first` (CANON-D6)

Inserta antes del paso actual de búsqueda:

1. Read `.graph/policy.json` (cadences, thresholds, collection layout); if absent, defaults 7/30/90/14/30/300.
2. Read the `overview` pages of the domain (two-level map) and the PARA sections of `index.md` relevant to
   the question; read the active project page when the question names a project.
3. Read `index.md` in full **only if** `counts.nodes` in `wiki-graph.json` is below
   `thresholds.index_first_max_pages`.
4. Then hybrid search (`qmd`), then the graph (backlinks, 1-hop), as today.
5. `raw_sources/` is not in the search collection: when the question needs the raw text, use Grep or
   `search_notes` on `raw_sources/`.
6. Archived pages (`para: archive`) are cited only when the question asks about the past or names them.

### 3.4 Ingest — `Step 0.5 — capture filter` (CANON-D7)

Inserta entre "clip" y "read":

- If `wiki/synthesis/favorite-problems.md` exists: match the source against the problems; set `problems:`
  on the pages you create or update; treat any inferred fit as a **candidate** ("this seems to feed fp-3"),
  never as resonance you felt.
- Match against active projects (`para: project`); set `project:`.
- If nothing matches: ask the human before ingesting ("nothing active seems to need this — ingest anyway,
  file as resource, or skip?").
- Two-source rule: a new `concept` page needs two cited sources; with one, extend a `summary` instead.

### 3.5 `## Operation: project kickoff` (CANON-D2)

Pasos mecánicos numerados: (1) create or complete the project page from `_templates/entity-project.md`
with `goal`, `due`, `next_action`, `next_review = today + review.project_days`, `description`; (2) read
`.graph/packets.json` and list reusable packets; (3) search related pages (name, tags, text) and link them
from the outline; (4) add `[[entities/<slug>]]` to the `related:` of every page you linked (reciprocal
edge); (5) write the outline as an archipelago of wikilinks; (6) add the page to `## Projects (active)` in
`index.md`; (7) create or reduce `project_<slug>.md` in auto-memory to the pointer form; (8) append
`## [date] project-open | <slug> — <n> packets reused` to `log.md`. Paso decisional (humano): objetivo y
fecha.

### 3.6 `## Operation: project close` (CANON-D3)

Mecánico: set `para: archive` + `archived: today`, refresh `updated:` (the page changed) and optionally add
one outcome line to the body; extract reusable packets (set `packet:` on the pages that qualify); move the `index.md` entry to
`## Archive`; reduce the auto-memory pointer to "closed on <date>"; append `project-close` to `log.md`.
Prohibiciones: never move or delete files; never change `status`. Decisional: whether to close, and the
outcome text.

### 3.7 `## Operation: weekly review` (CANON-D4)

Mecánico: read `findings.json` → `pending_ingest` (inbox), `project_overdue` + `project_incomplete` (open
loops), `review_due` (projects due); for each `review_due` project: propose `next_action` and
`next_review = today + review.project_days`; produce **at most three recommendations**; append
`## [date] review | weekly — <n> due, <m> ingested, <k> loops` to `log.md`. Decisional: cambiar fechas,
cerrar, ignorar. Regla explícita: "do not review every project every week — only what the queue lists"
(F11).

### 3.8 `## Operation: monthly review` (CANON-D5)

Mecánico: areas (`para: area`) — standard vs indicators; `archive_candidate` findings → list at most three
with evidence; outcomes of projects closed this month; append `review | monthly — …`. Decisional: archivar
(via project close), ajustar cadencias ("resistance as feedback").

### 3.9 `## Filing policy` (CANON-D8)

- Propose filing an answer as a page when the synthesis cites three or more pages; pick the natural type
  (`overview`/`synthesis`/`concept`/`comparison`) and, if reusable, a `packet` type.
- Log every query as `## [date] query | <title> | filed: yes|no` so the filing rate is measurable.

### 3.10 `## Session close (Hemingway Bridge)` (CANON-D9)

Every session that touched a project ends by updating `next_action` on the project page and appending
`## [date] session | <slug> — next: <next_action>` to `log.md`.

### 3.11 `## Intermediate packets` (CANON-D10)

Enum de cinco con una línea cada uno; "set `packet:` on the page's natural type; never create a `packets/`
directory; `synthesis` stays rare"; `index.md` section `## Packets`; kickoff reads `packets.json`.

### 3.12 `## Favorite problems` (CANON-D11)

Página única `wiki/synthesis/favorite-problems.md` creada **when the human declares their problems**
(never pre-created); formato de entradas `1. **fp-1** — How …?`; máximo doce; slugs estables; enlazarla desde
`index.md` (`## Favorite problems`) y desde la `overview` raíz si existe; `problems:` en las páginas que
aportan; `problem_unfed` es la señal de que un problema lleva N días sin alimentarse.

### 3.13 `## Migration: project_* memory files` (CANON-D12, solo delta)

For each `project_*.md` in auto-memory: create or complete the vault project page (kickoff, without
re-deciding goal/date: copy them), then reduce the memory file to the pointer form. Do it in the next
session, one project per turn if there are many; log `project-open` for each.

### 3.14 Capas de memoria (extensión de `## What goes here vs. other memory layers`)

Una fila nueva en la heurística: "Project state → vault project page (single home); auto-memory keeps the
pointer". Misma frase en `modules/claude-md.tpl` (plantilla del `CLAUDE.md` del workspace) para scaffolds
nuevos; los agentes existentes la reciben por el delta, porque su `CLAUDE.md` de workspace no se refresca.

### 3.15 Formato de `log.md` (CANON-D15)

La línea de formato del skeleton y una nota en el delta ("update the format line of your `log.md`").

## 4. Delta: estructura del archivo `schema-updates-0.27.0.md`

Mismo formato que `schema-updates-0.8.0.md` (cabecera explicando qué es, cómo integrarlo, y luego las
secciones). Orden: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 3.11, 3.12, 3.13, 3.14, 3.15. La
cabecera dice explícitamente que la integración es manual, que `schema_delta_pending` aparecerá en
`findings.json` mientras CANON-D1 no esté en el `CLAUDE.md` del vault, y que integrar no requiere reescribir
nada existente (todo es aditivo).

## 5. Oráculos (tests host)

| Oráculo | Dónde |
|---|---|
| Cada CANON-D1..D11 y D15 presente exactamente una vez en `modules/vault-skeleton/CLAUDE.md` | `vault.bats` |
| Cada sección `## …` del delta aparece verbatim (encabezado + cuerpo hasta el siguiente `## `) en el skeleton `CLAUDE.md`, salvo D12 y la cabecera del delta | `vault.bats` (extracción con awk + `diff`) |
| Skeleton limpio: `wiki_graph_run` → exactamente 0 hallazgos (sin página semilla) | `wiki-graph.bats:98` (existente, se conserva) |
| Sobre las tres fixtures de estado del vault: 0 archivos preexistentes modificados (sha256 antes/después), marcador con CANON-D13 + fecha ISO, una sola línea CANON-D14 tras dos corridas | `vault-upgrade.bats` |
| `index.md` del skeleton contiene las cinco secciones nuevas y el runner no reporta `index_drift` sobre él | `vault.bats` + `wiki-graph.bats` |
| Plantillas nuevas existen y su frontmatter parsea con el runner sin violación (cada plantilla sembrada en una fixture con `title` vacío, regla L6 de 014) | `wiki-graph.bats` |
| Cero marcas combinantes en skeleton, delta, plantillas y bats | auditoría `LC_ALL=C grep -c $'\xcc\x80'` = 0 |
| `modules/claude-md.tpl` contiene la fila de ruteo de estado de proyecto y sigue rendereando byte-idéntico para agentes sin vault | `docker-render.bats`/`local-render.bats` |
