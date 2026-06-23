# Contrato: salida MCP renderizada (github + vault)

Contrato que las aserciones de test DEBEN afirmar. Fuente de verdad: `modules/mcp-json.tpl` renderizado vía `scripts/lib/render.sh`. Este documento NO cambia el contrato; lo fija para que los tests lo reflejen.

## github (cuando `mcps.github.enabled: true`)

```json
"github": {
  "command": "github-mcp-server",
  "args": ["stdio"],
  "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PAT}" }
}
```

Aserciones esperadas:

| jq path | Valor esperado |
|---|---|
| `.mcpServers.github.command` | `github-mcp-server` |
| `.mcpServers.github.args[0]` | `stdio` |

Contrato OBSOLETO (a eliminar de los tests): `.mcpServers.github.command == "npx"`.

## vault (cuando `vault.mcp.enabled: true`)

```json
"vault": {
  "command": "npx",
  "args": ["-y", "@bitbonsai/mcpvault@0.12.0", "/home/agent/.vault"],
  "env": {}
}
```

Aserciones esperadas:

| jq path | Valor esperado |
|---|---|
| `.mcpServers.vault.command` | `npx` (sin cambios — ya pasa) |
| `.mcpServers.vault.args[0]` | `-y` |
| `.mcpServers.vault.args[1]` | `@bitbonsai/mcpvault@0.12.0` |
| `.mcpServers.vault.args[2]` | `/home/agent/.vault` |
| `.mcpServers.vault.env` | `{}` |

Contrato OBSOLETO (a eliminar de los tests): `.mcpServers.vault.args[1] == "@bitbonsai/mcpvault@latest"`.

Fuente de la versión `0.12.0`: `scripts/lib/versions.sh::AGENTIC_FLOOR_MCP_VAULT`. La duplicación del literal con el template es deuda pre-existente (Principio VI), fuera de alcance.

## Tests afectados

| Test (ID en suite) | Archivo | Aserción a corregir |
|---|---|---|
| 320 "has github when enabled" | tests/mcp-json.bats | github `npx` → `github-mcp-server` (+ `args[0]==stdio`) |
| 321 "has vault MCP when vault.mcp.enabled is true" | tests/mcp-json.bats | vault `@latest` → `@0.12.0` |
| 324 "renders valid JSON with atlassian + github + vault all enabled" | tests/mcp-json.bats | github `npx` → `github-mcp-server`; vault (si aplica) |
| 328 "renders valid JSON with vault MCP + QMD both enabled" | tests/mcp-json.bats | vault `@latest` → `@0.12.0` |
| 367 "--regenerate emits vault MCP and Vault row in CLAUDE.md when vault.enabled" | tests/regenerate.bats | vault `@latest` → `@0.12.0` |
| 397 "wizard with vault enabled writes vault block + emits vault MCP + memory section" | tests/scaffold.bats | vault `@latest` → `@0.12.0` |

Nota: el valor exacto a corregir por test se confirma leyendo cada test en `/speckit-implement` (las líneas pueden incluir más de una aserción vault/github por test).
