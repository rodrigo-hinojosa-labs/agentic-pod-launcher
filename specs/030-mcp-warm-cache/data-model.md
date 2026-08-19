# Data model — 030 warm cache

Esta feature no introduce campos nuevos en `agent.yml` (la lista de warm se **deriva** del `.mcp.json`
efectivo — D1/D3). Las "entidades" son las estructuras que el mecanismo lee y produce.

## Entidad: Warm target (paquete precalentable)

Unidad derivada, en memoria, no persistida en `agent.yml`.

| Campo | Tipo | Origen | Notas |
|---|---|---|---|
| `runtime` | enum `uvx` \| `npx` | token hallado en `[command]+args` del server | determina el warmer |
| `package` | string | token no-flag siguiente al token de runtime | spec literal, con `@version` si lo trae |
| `server_id` | string | clave del server en `.mcpServers` | solo para traza/log |

**Reglas de validación / derivación** (contrato en `contracts/warm-derivation.md`):
- Se omiten servers cuyo `[command]+args` no contiene ningún token `uvx`/`npx` (binarios como
  `github-mcp-server`, wrapper qmd, remotos).
- El `package` se toma **literal** de `args` (fidelidad de pin, D3). No se re-pinnea desde una tabla.
- `npx`: saltar `-y`/`--yes`; con `-p <pkg>`/`--package <pkg>`, el `package` es el token tras el flag.
- `uvx`: el `package` es el token inmediatamente posterior al token `uvx`.
- Deduplicar por `(runtime, package)`.

## Entidad: Cache tibio (existente, reusado)

No se crea; se reusa. Documentado para fijar FR-004.

| Cache | Ruta | Var de entorno | Dueño | Evidencia |
|---|---|---|---|---|
| uv tools | `/opt/uv/tools` | `UV_TOOL_DIR` | `agent` (chown build) | `Dockerfile:118,125` |
| uv download | `/opt/uv/cache` | `UV_CACHE_DIR` | `agent` | `Dockerfile:119` |
| npm/npx | `/opt/npm-cache` | `NPM_CONFIG_CACHE` | `agent` | `Dockerfile:205,211` |

Invariante FR-004: **fuera de `/home/agent`** (el volumen de estado monta ahí en runtime y taparía un
cache interno). `UV_PYTHON_PREFERENCE=only-system` (`Dockerfile:120`) evita auto-descargar un CPython
gestionado que rompería la reproducibilidad del cache.

En **local**, los caches uvx viven bajo el HOME del operador (defaults de uv: `~/.local/share/uv/tools`,
`~/.cache/uv`), fuera del `.state` — coherente con el alcance uvx-only de D5.

## Entidad: Manifiesto de precalentamiento (traza)

Salida legible del paso de warm (FR-008), no un archivo de estado con schema versionado (a diferencia
de `heartbeat`/`backup`); es log a stderr/`claude.log`.

| Elemento | Contenido |
|---|---|
| por target intentado | `warming <runtime> <package>` |
| por éxito | (silencioso o `ok`) |
| por fallo | `warn: <runtime> <package> failed (will resolve on first use)` |
| resumen | conteo intentados / tibios / fallidos |

## Flujo de datos

```
.mcp.json efectivo  ──mcp_warm_targets()──▶  [{runtime, package}]  ──mcp_warm_run()──▶  /opt/uv, /opt/npm-cache
   (post custom-apply)     (pura, sin red)         (dedup)              (timeout+failsoft)   (cache tibio)
```

- **Docker**: `start_services.sh` invoca `mcp_warm_run <workspace>/.mcp.json` síncrono, pre-`claude`.
- **Local**: `provision_uv_tools` usa `mcp_warm_targets` (filtrando `runtime==uvx`) para el warm uvx en
  `--login` (D5).

## Estado / no-estado

- **Idempotencia** (FR-005): un paquete ya tibio → `uv tool install`/`npm exec` es no-op rápido; no hay
  archivo `.installed` propio, la idempotencia la da el cache del gestor.
- **Sin secretos** (FR-006): ninguna entidad referencia `.env` ni credenciales.
- **Regenerate-safety** (FR-011): como la lista se deriva del `.mcp.json` (a su vez derivado de
  `agent.yml` + overlay), no hay estado que un `--regenerate` pueda borrar; el warm re-deriva en cada
  boot/login.
