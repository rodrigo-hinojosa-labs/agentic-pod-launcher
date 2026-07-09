# Contract: TMPDIR host-backed + observabilidad del runner (US3)

**Interfaz**: wrappers de mantenimiento en `scripts/lib/wiki_graph.sh` y
`scripts/lib/qmd_index.sh` (espejados a `docker/scripts/lib/` con COPY explícito).

## Precondiciones

- Modo docker con qmd habilitado; cache de `bunx` (~98 MB) ya presente.
- Vault grande (miles de páginas; ferrari real: 2696).

## Comportamiento observable

| # | Dado | Cuando | Entonces |
|---|------|--------|----------|
| C1 | contenedor con qmd on y `bunx` cacheado | corre `wiki-graph` | completa con `last_status: ok`; escribe `.graph/{graph,backlinks,findings}.json` con conteos reales |
| C2 | mismo contenedor | corre reindex qmd | `collection add`/`update`/`embed` disponen de espacio; sin ENOSPC |
| C3 | `/tmp` (tmpfs) artificialmente lleno | corre `wiki-graph` | usa su `TMPDIR` host-backed y **completa** igual (robusto a `/tmp` lleno) |
| C4 | fallo de infra real durante la agregación (p.ej. sin espacio en el dir host-backed) | el runner termina | `wiki-graph.json.error` trae el **stderr real** (`aggregation failed: <msg>`), no el genérico `jq aggregation failed` |
| C5 | cualquier corrida que capture stderr/env | se escribe state/log | secretos redactados (`sk-ant-*`, `*_TOKEN`, `*_KEY`, OAuth) — nunca en claro |

## Mecanismo

- El wrapper fija `TMPDIR` (y defensivo `TMP`/`TEMP`) a `${cache_root}/tmp`
  (host-backed bajo `.state`), `mkdir -p` fail-silent, antes de `bunx`/qmd/`mktemp`.
- `wiki_graph.sh:290` (`mktemp -d "${TMPDIR:-/tmp}/wg.XXXXXX"`) hereda el `TMPDIR`
  host-backed; el runner lo fija explícito al inicio (defensa ante `/tmp` lleno).
- `wiki_graph.sh:325`: `2>/dev/null` → captura a `"$tmpd/agg.err"`; en fallo, el
  campo `error` del state incluye `tail` del stderr real (redactado).

## Cobertura de test

- **Host (bats, test-first)**: extender `tests/wiki_graph.bats`:
  - Con un `TMPDIR` de test, asserta que el runner crea/usa el dir host-backed y que
    `mktemp` cae ahí (no en `/tmp`).
  - Inyecta un `_wg_aggregate`/`jq` stub que escribe a stderr y falla → asserta que
    `wiki-graph.json.error` contiene el mensaje real, no el genérico (C4).
  - Asserta redacción: un stderr con un token `sk-ant-…` sale redactado del state (C5).
- **DOCKER_E2E (obligatorio, C1-C3)**: en contenedor real con qmd on y `bunx`
  cacheado ocupando su espacio, `wiki-graph` completa `ok` sobre un vault sembrado
  grande; el reindex qmd no falla por ENOSPC.

## Invariantes de constitución

- Principle II: NO se toca `docker-compose.yml.tpl` (routing en wrappers, bind-mount
  `.state` ya existe). Sin nuevas caps/mounts/sockets.
- Principle IV (refinado, FR-007): fail-silent sigue retornando 0 pero **registra**
  el error de infra; no lo traga.
- Principle V: redacción de secretos obligatoria antes de escribir a state/log.
