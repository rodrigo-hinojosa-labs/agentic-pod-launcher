# Data Model: Corregir drift de tests del contrato MCP renderizado

Feature sin entidades de datos persistentes ni esquema. Los únicos "datos" son los valores de aserción que los tests comparan contra el `.mcp.json` renderizado.

## Entidades conceptuales

### Aserción de contrato MCP

- **Qué representa**: una comparación en un test `.bats` entre un campo del `.mcp.json` renderizado (extraído con `jq`) y un valor esperado literal.
- **Campos**:
  - `jq_path` — ruta del campo (ej. `.mcpServers.github.command`).
  - `expected` — valor esperado literal.
- **Regla de validación**: `expected` DEBE coincidir con lo que `modules/mcp-json.tpl` renderiza hoy. El drift ocurre cuando `expected` queda congelado en un contrato anterior.
- **Transición de estado**: `obsoleta (rojo)` → `vigente (verde)` tras corregir el literal. No hay otros estados.

### Versión pineada de vault

- **Qué representa**: el literal de versión del paquete `@bitbonsai/mcpvault`.
- **Valor**: `0.12.0`.
- **Fuente de verdad**: `scripts/lib/versions.sh::AGENTIC_FLOOR_MCP_VAULT`.
- **Relación**: hardcodeada hoy también en `modules/mcp-json.tpl` (duplicación pre-existente, deuda Principio VI). Las aserciones deben usar `0.12.0`.

## No aplica

- Sin almacenamiento, sin migraciones, sin máquina de estados de runtime, sin relaciones entre entidades de producto. El cambio no altera ningún dato del agente scaffoldeado.
