# Data Model: Instalación al boot de plugins de marketplaces de terceros

**Feature**: 009-fix-extra-marketplace-install

No hay esquema persistente nuevo. Las "entidades" son conceptos del flujo de boot; sus fuentes ya existen.

## Entidades

### Marketplace de terceros

Origen de plugins distinto del oficial, declarado indirectamente por los plugins del `agent.yml`.

- **key**: identificador del marketplace usado en el spec `plugin@key` (p.ej. `thedotmack`). Clave del objeto que emite `plugin_catalog_marketplaces_json`.
- **repo**: repositorio de origen para registrarlo (`.[key].source.repo`, p.ej. `thedotmack/claude-mem`).
- **source.type**: tipo de fuente (p.ej. `github`).

Fuente: `modules/plugins/<id>.yml` → bloque `marketplace:` → `plugin_catalog_marketplaces_json /workspace/agent.yml`.

**Estados**:
- *declarado*: presente en `extraKnownMarketplaces` (settings.json) y/o en el catálogo.
- *resuelto*: aparece en `claude plugin marketplace list` → la CLI puede instalar sus plugins. **Transición declarado → resuelto** es lo que el fix garantiza (vía `marketplace add` confirmado) antes del loop de instalación.

### Plugin de terceros

Plugin del `agent.yml` cuyo `spec` es `nombre@key` con `key` ≠ `claude-plugins-official`.

**Estados tras el boot**:
- *instalado/habilitado* (objetivo).
- *fallo registrado*: si tras los reintentos acotados no instala, se anota en el registro de fallos (sin secretos).
- ~~*skip silencioso permanente*~~: estado a ELIMINAR — hoy es el resultado real y el fix lo erradica.

### Registro de fallos de instalación

Artefacto observable existente: `PLUGIN_FAILURES_FILE` (`/workspace/.state/plugin-install-failures.jsonl`), una línea JSON `{spec, error, ts}` por fallo residual, con error sanitizado (sin secretos). Sin cambios de esquema; el fix solo cambia qué llega aquí (un marketplace de terceros resuelto ya no produce skip permanente).

## Reglas de validación / invariantes

- La derivación de `(key, repo)` proviene exclusivamente de `agent.yml` (Principio I); no se hardcodea ningún proveedor.
- `ensure_extra_marketplaces` es idempotente: si `key` ya está *resuelto*, no re-registra.
- Ninguna llamada a la CLI en el camino de boot puede bloquear indefinidamente (acotada por `timeout`).
- El camino del marketplace oficial permanece sin cambios de comportamiento.
