# Contract: Artefactos del grafo y state file

Norma para `scripts/lib/wiki_graph.sh` (espejada a la imagen) y sus consumidores
(agentctl, heartbeatctl, healthcheck, schema del vault).

## Ubicación y formato

- Artefactos: `<vault>/.graph/graph.json`, `<vault>/.graph/backlinks.json`,
  `<vault>/.graph/findings.json`.
- **Regla dura**: `.graph/` contiene EXCLUSIVAMENTE archivos con extensión no-`.md`.
  Razón: el backup del vault stagea solo `find -name '*.md'` (`backup_vault.sh:93`) y la
  colección qmd usa mask `**/*.md` (`qmd_index.sh:181`) — la exclusión de derivados es por
  construcción, no por configuración. Emitir un `.md` dentro de `.graph/` es una violación
  de este contrato (entraría a backup + índice).
- Escritura atómica: generar en `<vault>/.graph/<name>.tmp.$$` y `mv` al nombre final
  (mismo filesystem). Nunca puede observarse un JSON parcial en el nombre final.
- Lock: `flock` no bloqueante sobre `<ws>/scripts/heartbeat/.wiki-graph.lock`. El perdedor
  sale rc=91 SIN tocar artefactos y SIN escribir el state file (no existe estado `locked`:
  el ganador es la única corrida que actualiza `wiki-graph.json`, de modo que el perdedor
  jamás pisa el state del ganador ni introduce un estado ambiguo). Lock y temporales JAMÁS
  dentro del vault (Syncthing).

## graph.json (schema 1)

```json
{
  "schema": 1,
  "generated_at": "2026-07-06T12:00:00Z",
  "vault": "<abs path>",
  "nodes": [
    {"id": "entities/cencosud", "type": "entity", "title": "Cencosud",
     "status": "active", "created": "2026-07-01", "updated": "2026-07-05",
     "tags": ["retail"]}
  ],
  "edges": [
    {"from": "summaries/x", "to": "entities/cencosud", "kind": "wikilink", "broken": false},
    {"from": "summaries/x", "to": "raw_sources/transcripts/y.md", "kind": "source", "broken": false},
    {"from": "normalization/cencosud", "to": "entities/cencosud", "kind": "alias", "broken": false}
  ]
}
```

- `id` = path relativo a `wiki/` sin `.md`. Los destinos `source` usan path relativo al
  vault (no son nodos).
- Nodos con frontmatter parcialmente inválido SE INCLUYEN con los campos que parsearon
  (campo faltante = `""`); la omisión completa de una página es violación de contrato.
- **Campo requerido presente pero vacío** (L6): "requerido" significa CLAVE-PRESENTE, no
  valor-no-vacío, para los campos de nodo (`title`, `type`, `status`). Un `title: ""` (que
  los templates del skeleton envían como placeholder) NO es `frontmatter_violation` — la
  clave existe. Excepción: los campos de página de normalización `canonical`/`aliases`
  exigen valor NO vacío (contrato normalization-pages.md), porque ahí el valor vacío hace
  la regla inaplicable. Criterio unificado y cubierto por el fixture.

## backlinks.json (schema 1)

```json
{
  "schema": 1,
  "generated_at": "...",
  "pages": {
    "entities/cencosud": {
      "backlinks": ["summaries/x", "concepts/retail-media"],
      "related_out": ["concepts/retail-media"],
      "co_sourced": ["summaries/z"],
      "canonical_of": ["SENCOSUD", "Sencosud"]
    }
  }
}
```

- `backlinks`: aristas entrantes `wikilink` + `related` (H2: un `related:` entrante
  cuenta SIEMPRE, no exige reciprocidad). Un nodo es `orphan` sii su lista `backlinks`
  queda vacía.
- `co_sourced`: páginas que citan al menos un mismo `sources:`.
- `canonical_of`: aliases que resuelven a esta página (via reglas de normalización con
  `entity` apuntando aquí).
- Este archivo es la interfaz del protocolo query del schema (vecinos a 1 salto): el
  agente lo lee directo con jq/Read — no hay servicio ni MCP nuevo.

## findings.json (schema 1)

```json
{
  "schema": 1,
  "generated_at": "...",
  "findings": [
    {"kind": "broken_link", "page": "summaries/x", "detail": "concepts/no-existe"},
    {"kind": "frontmatter_violation", "page": "entities/y", "detail": "type: invalid 'entitty'"},
    {"kind": "index_drift", "page": "concepts/z", "detail": "missing_from_index"},
    {"kind": "orphan", "page": "overviews/w", "detail": ""},
    {"kind": "stale", "page": "summaries/x", "detail": "raw_sources/a.md newer than updated:"},
    {"kind": "alias_occurrence", "page": "summaries/x", "detail": "SENCOSUD -> Cencosud"}
  ]
}
```

Orden estable (por kind, luego página) para diffs deterministas entre corridas.

## wiki-graph.json — state file (schema 1)

Ubicación: `<ws>/scripts/heartbeat/wiki-graph.json`. Escritura atómica (tmp+mv).
Shape completo en `data-model.md`. Reglas:

- `last_status`: `ok` | `error` (NO existe `locked`: el perdedor del flock no escribe
  state, ver sección Lock). El proceso SIEMPRE sale 0 en contextos batch (Principle IV);
  `error` + `error: "<msg>"` es el canal de honestidad.
- `counts` refleja EXACTAMENTE lo que hay en `findings.json` de la misma corrida.
- Vault inaccesible/vacío-inesperado → `last_status: error`, artefactos previos INTACTOS
  (no se publican JSON vacíos sobre un grafo bueno anterior).
- Wiki legítimamente vacía (skeleton limpio) → `ok` con counts en 0 y artefactos vacíos
  válidos (distinción: el vault existe y tiene la estructura esperada).

## Contrato de degradación (doctor) — clarify Q5

| Condición | Estado | Exit |
|---|---|---|
| `broken_links > 0` o `frontmatter_violations > 0` o `index_drift > 0` | WARN | 1 |
| `last_status == "error"` | WARN | 1 |
| state file ausente o `last_run` > 2× intervalo (fallback 24 h) con feature habilitada | FAIL | 2 |
| `orphans`/`stale`/`alias_occurrences` > 0 | OK (solo counts en status) | 0 |

Intervalo esperado (M6): se lee el campo HORA del cron. `*/N` en el campo hora → N horas
AUNQUE el minuto sea fijo — el default `20 */6 * * *` → 6 h (FAIL a 12 h); una lista de
horas `0,6,12,18` → el menor gap (6 h); `*` en hora con `*/N` en el minuto → N minutos;
cualquier otra forma no reconocida → 24 h. El parser de intervalo tiene test unitario sobre
`20 */6 * * *` esperando 6 h.

## Reglas de parsing (normativas, subset del schema del skeleton)

- Frontmatter: primer bloque `---`…`---`; `key: value`, `key: [a, b]` (array de flujo), y
  arrays de guiones. Todo lo demás → `frontmatter_violation` (el parser estricto ES el
  validador).
- **Normalización de valores** (H4): cada valor escalar y cada elemento de array se
  despoja de comillas envolventes (`"…"` o `'…'`) ANTES de usarse. En `related:` se
  desenvuelve el wikilink embebido — `"[[concepts/x]]"` → `concepts/x`, aplicando las
  mismas reglas de wikilink (anchor/display descartados). En `sources:` se conserva el
  path tal cual (con `.md`), solo sin comillas. Sin este paso, el skeleton real
  (`related: ["[[concepts/llm-wiki-pattern]]"]`, `sources: ["raw_sources/x.md"]`)
  produciría broken_links espurios sobre cada `related:` y cada `sources:`.
- Wikilinks: `[[t]]`, `[[t|d]]`, `[[t#a]]`, `[[t#a|d]]` → resolución por `t` exacto a
  `wiki/<t>.md`. Anchor y display no participan.
- Exclusiones: fenced code blocks (toggle ```); `index.md`, `log.md`, `_templates/`,
  `raw_sources/`, `.graph/`, `.obsidian/` no son nodos. `index.md` se valida aparte
  (drift bidireccional contra el filesystem).
- **Extracción de entradas de `index.md`** (H3): una "entrada" es un bullet a nivel de
  lista con la forma `- [[type/slug]] …`. Se EXCLUYEN del escaneo: comentarios HTML
  `<!-- … -->` (que en el skeleton limpio contienen `[[…]]` de ejemplo), texto entre
  backticks (`` `- [[<type>/<title>]] …` ``) y placeholders `<…>`. Sin esta regla, el
  `index.md` limpio del skeleton (que trae tokens `[[…]]` en prosa y comentarios)
  generaría `index_drift: missing_file` espurios y rompería "skeleton limpio → 0
  hallazgos" (SC-001). Drift bidireccional: entrada válida sin archivo → `missing_file`;
  archivo de `wiki/` sin entrada → `missing_from_index`.
- Aliases: word-boundary; case-insensitive salvo `match_case: true`; fuera de fences;
  se excluye `wiki/normalization/` del escaneo. Inline code spans NO se excluyen en v1
  (documentado; costo/beneficio en research R9).
