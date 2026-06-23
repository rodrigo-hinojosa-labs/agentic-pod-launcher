# Research: Corregir drift de tests del contrato MCP renderizado

Feature de alcance test-only. No hay incógnitas tecnológicas abiertas; la investigación se limita a confirmar empíricamente el contrato vigente y la fuente de cada valor esperado, para que las aserciones se alineen a un hecho verificado y no a una suposición.

## D1 — Contrato github vigente

- **Decisión**: las assertions de github deben afirmar `command == "github-mcp-server"` y `args[0] == "stdio"`.
- **Rationale**: `modules/mcp-json.tpl` líneas 60-66 renderizan el bloque github con `"command": "github-mcp-server"` y `"args": ["stdio"]` cuando `MCPS_GITHUB_ENABLED`. Es el binario nativo image-baked introducido por PR #59 (feature 004) para esquivar la patología small-file de VirtioFS que rompe el handshake `npx`. El `npx @modelcontextprotocol/server-github` anterior ya no se renderiza.
- **Alternativas consideradas**: revertir el template a `npx` (rechazado — revierte una migración deliberada y ya validada de PR #59, y reintroduce el fallo de VirtioFS en macOS).

## D2 — Contrato vault vigente y fuente de la versión

- **Decisión**: las assertions de vault deben afirmar `args == ["-y", "@bitbonsai/mcpvault@0.12.0", "/home/agent/.vault"]`, con la versión literal `0.12.0`.
- **Rationale**: `modules/mcp-json.tpl` línea 70 renderiza `"args": ["-y", "@bitbonsai/mcpvault@0.12.0", "/home/agent/.vault"]`. La versión `0.12.0` es el pin image-baked declarado en `scripts/lib/versions.sh` (`AGENTIC_FLOOR_MCP_VAULT="0.12.0"`). El `@latest` anterior ya no se renderiza.
- **Alternativas consideradas**: (a) hacer que el test lea la versión desde `versions.sh` en runtime (sourcear la lib y construir la cadena esperada) para evitar el literal duplicado — atractivo por el Principio VI, pero agrega acoplamiento de test a la lib y amplía el alcance; se difiere como deuda opcional. (b) afirmar solo el prefijo `@bitbonsai/mcpvault@` ignorando la versión — rechazado: debilita la aserción y dejaría pasar un downgrade/upgrade no intencional.

## D3 — Alcance test-only (no tocar templates)

- **Decisión**: corregir exclusivamente las aserciones; no modificar `modules/mcp-json.tpl`, `docker/`, `setup.sh` ni render/runtime.
- **Rationale**: el defecto está en los tests, no en el producto. Los templates representan el contrato correcto e intencional post-PR #59 (verificado leyendo el template y corriendo la suite: solo fallan aserciones de github/vault, ninguna otra). Cambiar el template para "satisfacer" tests viejos revertiría una decisión correcta.
- **Alternativas consideradas**: parametrizar el template para leer la versión de vault desde `versions.sh` (consolidar el pin duplicado) — correcto a futuro por Principio VI, pero fuera de alcance de un fix de tests; se anota como deuda.

## D4 — Verificación sin Docker

- **Decisión**: la validación es `bats tests/mcp-json.bats`, `bats tests/regenerate.bats` y `bats tests/` completa, todo en el host.
- **Rationale**: Principio III (test-first, host-runnable). Ninguno de los 6 tests requiere `DOCKER_E2E`; renderizan con `render_template` contra fixtures YAML temporales.
- **Alternativas consideradas**: ninguna; no hay seam de integración Docker en este cambio.
