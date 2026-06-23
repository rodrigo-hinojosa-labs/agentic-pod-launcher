# Quickstart: verificar el fix de drift de tests MCP

Guía mínima para reproducir el estado roto, aplicar el criterio del fix y validar verde total. Todo en el host, sin Docker.

## 1. Reproducir el estado roto (antes)

```bash
# En main o en la rama del feature antes de editar los tests:
bats tests/ 2>&1 | grep -E "^not ok"
# Esperado (6 fallas): 320, 321, 324, 328 (mcp-json.bats), 367 (regenerate.bats), 397 (scaffold.bats)
```

## 2. Confirmar el contrato vigente (fuente de verdad)

```bash
# github: binario nativo, NO npx
grep -n "github-mcp-server\|\"stdio\"" modules/mcp-json.tpl
# vault: pin 0.12.0, NO @latest
grep -n "mcpvault" modules/mcp-json.tpl
# versión fuente
grep -n "AGENTIC_FLOOR_MCP_VAULT" scripts/lib/versions.sh   # => 0.12.0
```

## 3. Aplicar el fix

Editar SOLO `tests/mcp-json.bats` y `tests/regenerate.bats`:

- github: `command == "npx"` → `command == "github-mcp-server"` (y afirmar `args[0] == "stdio"`).
- vault: `@bitbonsai/mcpvault@latest` → `@bitbonsai/mcpvault@0.12.0`.

No tocar `modules/`, `docker/`, `setup.sh` ni render.

## 4. Validar (después)

```bash
# Por archivo
bats tests/mcp-json.bats
bats tests/regenerate.bats

# Suite completa: 0 fallas
bats tests/ 2>&1 | tail -3
bats tests/ 2>&1 | grep -cE "^not ok"   # => 0

# Disciplina de scope: el diff solo toca tests/, CHANGELOG.md, VERSION
git diff --name-only main...HEAD
```

## 5. Criterio de aceptación

- `bats tests/` → 668/668 `ok` (0 fallas).
- `git diff --name-only` no lista ningún archivo en `modules/`, `docker/`, `scripts/` ni `setup.sh`.
- `VERSION` = `0.4.1`; `CHANGELOG.md` con la entrada del feature.
