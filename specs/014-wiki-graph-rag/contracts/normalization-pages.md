# Contract: Páginas de normalización

Norma para `wiki/normalization/`, su template, el paso de ingest del schema y el escaneo
del linter. Decisión base (clarify Q1): carpeta-convención con frontmatter PROPIO; los 6
types de conocimiento quedan intactos.

## Frontmatter (spec propio — el linter valida contra ESTO)

```yaml
---
canonical: "Cencosud"            # requerido, no vacío
aliases: [SENCOSUD, Sencosud]    # requerido, lista no vacía
match_case: false                # opcional, default false
entity: "[[entities/cencosud]]"  # opcional; genera arista alias→canonical
notes: "Transcripciones de reuniones suelen escribirlo mal."  # opcional
---
```

- SIN campo `type:` — estas páginas están FUERA del sistema de 6 types. Si una página bajo
  `wiki/normalization/` declara `type:`, es `frontmatter_violation` (scope normalization).
- `canonical` ausente/vacío o `aliases` ausente/vacío → `frontmatter_violation`.
- El cuerpo es libre (contexto, ejemplos, cuándo NO aplica).

## Template

`modules/vault-skeleton/_templates/normalization.md` con el frontmatter de arriba y
comentarios de uso. Nombre de archivo: slug del canonical (`cencosud.md`).

## Semántica de matching (linter, FR-004/FR-009)

- Word-boundary: `SENCOSUD` matchea como palabra completa, no dentro de otra
  (`SENCOSUDESTE` no matchea).
- Case: insensitive por default; `match_case: true` exige match exacto.
- Ámbito de escaneo: cuerpos de páginas en `wiki/` EXCEPTO `wiki/normalization/`;
  fenced code blocks excluidos; frontmatter excluido (los aliases pueden aparecer
  legítimamente en `title:` de la página histórica que documenta el error).
- **Alias dentro de un wikilink** (L5): un alias que aparece dentro de `[[…]]` (p. ej.
  `[[SENCOSUD]]` o `[[entities/x|SENCOSUD]]`) NO cuenta como `alias_occurrence` — es un
  link, no prosa a corregir; marcarlo sería un falso positivo sobre un enlace legítimo. El
  escaneo de aliases opera sobre el texto tras remover los tokens de wikilink completos.
  Inline code spans (backticks) NO se excluyen en v1 (documentado; research R9).
- Cada match → hallazgo `alias_occurrence` con `detail: "<alias> -> <canonical>"`.
  Informativo (no degrada doctor — clarify Q5): es cola de trabajo del agente.
- Un alias declarado en DOS reglas distintas → `frontmatter_violation` en ambas
  (ambigüedad de canonical: no hay resolución determinista).

## Grafo (FR-009)

Regla con `entity:` → arista `{"from": "normalization/<slug>", "to": "<entity id>",
"kind": "alias"}` y entrada `canonical_of` en `backlinks.json` de la entity. Regla sin
`entity:` → sin arista (la regla existe solo para el escaneo y el paso de ingest).

## Paso de ingest en el schema (FR-008)

El `CLAUDE.md` del skeleton agrega, entre los pasos 2 y 3 del protocolo ingest existente:

> **2.5. Normalize terminology.** Read `wiki/normalization/` (or the `canonical_of` map in
> `.graph/backlinks.json` if fresh). Write ALL layer-2 pages using canonical forms; keep
> the raw source VERBATIM (layer 1 is immutable). If the source contains a recurring
> mis-transcription not yet declared, propose creating a normalization page.

Capa 1 verbatim + capa 2 canónica es verificable en el gate manual (SC-007).

## index.md

Sección nueva al final:

```markdown
## Normalization

<!-- Reglas de forma canónica. Formato: `- [[normalization/<slug>]] — canonical <- aliases` -->
```

## qmd y backup

Las páginas de normalización SON `.md`: entran a la colección qmd (buscables) y al backup
del vault (durables). Esto es intencional (research R6) — no requiere cambio alguno en
qmd ni en backup.
