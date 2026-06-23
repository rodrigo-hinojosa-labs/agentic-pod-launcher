# Feature Specification: Corregir drift de tests del contrato MCP renderizado

**Feature Branch**: `007-fix-mcp-test-drift`

**Created**: 2026-06-22

**Status**: Draft

**Input**: User description: corregir 6 assertions de tests obsoletas (mcp-json.bats, regenerate.bats, scaffold.bats) que afirman el contrato MCP previo a la migración deliberada de PR #59 (github → `github-mcp-server` nativo; vault `@latest` → `@0.12.0` image-baked). Los templates están correctos; los tests están viejos. Solo cambios de tests.

## Contexto

PR #59 (feature 004-macos-bootstrap-hardening) cambió de forma deliberada y ya entregada el contrato de dos servidores MCP que el launcher renderiza desde `modules/mcp-json.tpl`:

- **github**: pasó de `npx @modelcontextprotocol/server-github` al binario nativo image-baked `github-mcp-server` (args `["stdio"]`), para esquivar la patología de small-file de VirtioFS en macOS que rompe el handshake de `npx`.
- **vault**: pasó de `@bitbonsai/mcpvault@latest` al pin image-baked `@bitbonsai/mcpvault@0.12.0`, consistente con `AGENTIC_FLOOR_MCP_VAULT="0.12.0"` en `scripts/lib/versions.sh`.

Los templates reflejan correctamente ese contrato. Lo que quedó atrás son **6 assertions de tests** que siguen afirmando el contrato anterior, por lo que la suite por defecto en `main` está en **668 tests, 6 fallando** desde el merge de PR #59 — una falla persistente que erosiona la señal de la suite (un fallo nuevo y real se confundiría con el ruido pre-existente).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Suite por defecto verde y fiel al contrato vigente (Priority: P1)

Como mantenedor del launcher, al correr `bats tests/` quiero que **todos** los tests pasen y que cada assertion del contrato MCP refleje lo que el template realmente renderiza hoy, para que la suite vuelva a ser una señal binaria confiable (verde = sano) y para que un fallo futuro real no se pierda entre 6 fallas crónicas.

**Why this priority**: Es el único objetivo del feature. Sin esto, la suite por defecto nunca está verde y la disciplina test-first del repo (constitución) queda comprometida: no se puede distinguir una regresión nueva de la deuda heredada.

**Independent Test**: Correr `bats tests/mcp-json.bats` y `bats tests/regenerate.bats` aislados, y luego `bats tests/` completa. Verde en los tres = entregado.

**Acceptance Scenarios**:

1. **Given** el template `modules/mcp-json.tpl` con github en `github-mcp-server` args `["stdio"]`, **When** se corre `tests/mcp-json.bats`, **Then** las assertions de github afirman `command == "github-mcp-server"` y `args[0] == "stdio"` y pasan.
2. **Given** el template con vault pineado a `@bitbonsai/mcpvault@0.12.0`, **When** se corren `tests/mcp-json.bats`, `tests/regenerate.bats` y `tests/scaffold.bats`, **Then** las assertions de vault afirman `args == ["-y", "@bitbonsai/mcpvault@0.12.0", "/home/agent/.vault"]` y pasan.
3. **Given** los 6 tests corregidos (320, 321, 324, 328 en mcp-json.bats; 367 en regenerate.bats; 397 en scaffold.bats), **When** se corre `bats tests/` completa, **Then** el resultado es 0 fallas (la suite reporta todos los tests en `ok`).
4. **Given** el alcance test-only, **When** se inspecciona el diff del feature, **Then** no hay cambios en `modules/*.tpl`, `docker/`, `setup.sh` ni ningún archivo de runtime/render — solo archivos bajo `tests/`, más `CHANGELOG.md` y `VERSION`.

### Edge Cases

- **El template cambia de nuevo a futuro**: la assertion de vault queda hardcodeada a `0.12.0`. Si alguien bumpea `AGENTIC_FLOOR_MCP_VAULT`, el test volverá a fallar y señalará el drift — comportamiento esperado, no un defecto. Parametrizar la assertion desde la fuente de versión es deuda fuera de alcance (ver Assumptions).
- **github deshabilitado / vault deshabilitado**: los tests que verifican ausencia (`omits ... when disabled`) ya pasan y no se tocan; el feature no debe alterarlos.
- **Regresión silenciosa de fixtures**: si un fixture compartido (`sample-agent-with-vault.yml`) ya afirma `0.12.0` y pasa, no se modifica; solo se corrigen las assertions que hoy fallan.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: La suite `bats tests/` completa DEBE terminar con cero fallas tras el cambio (verde total).
- **FR-002**: Las assertions de github en `tests/mcp-json.bats` (tests "has github when enabled" y "renders valid JSON with atlassian + github + vault all enabled") DEBEN afirmar `command == "github-mcp-server"` y la presencia de `args[0] == "stdio"`, reemplazando el `command == "npx"` obsoleto.
- **FR-003**: Las assertions de vault en `tests/mcp-json.bats` (tests "has vault MCP when vault.mcp.enabled is true", "renders valid JSON with atlassian + github + vault all enabled", "renders valid JSON with vault MCP + QMD both enabled") DEBEN afirmar `args[1] == "@bitbonsai/mcpvault@0.12.0"`, reemplazando `@bitbonsai/mcpvault@latest`.
- **FR-004**: Las assertions de vault en `tests/regenerate.bats` (test "--regenerate emits vault MCP and Vault row in CLAUDE.md when vault.enabled") y en `tests/scaffold.bats` (test "wizard with vault enabled writes vault block + emits vault MCP + memory section") DEBEN afirmar `@bitbonsai/mcpvault@0.12.0`, reemplazando `@bitbonsai/mcpvault@latest`.
- **FR-005**: El valor de versión de vault usado en las assertions DEBE ser `0.12.0`, consistente con `AGENTIC_FLOOR_MCP_VAULT` en `scripts/lib/versions.sh` (única fuente de verdad de esa versión).
- **FR-006**: El cambio NO DEBE modificar `modules/mcp-json.tpl` ni ningún otro template, ni archivos en `docker/`, ni `setup.sh`, ni la lógica de render o runtime. Solo archivos de test (`tests/`), más `CHANGELOG.md` y `VERSION`.
- **FR-007**: El feature DEBE incluir una entrada en `CHANGELOG.md` y un bump de patch en `VERSION` (0.4.0 → 0.4.1), por disciplina de versionado del repo.

### Key Entities

- **Assertion de contrato MCP**: línea de test que afirma un campo del `.mcp.json` renderizado (`command`, `args[n]`) contra el valor esperado. El drift ocurre cuando el valor esperado queda congelado en un contrato anterior al template vigente.
- **Versión pineada de vault** (`0.12.0`): definida en `scripts/lib/versions.sh` (`AGENTIC_FLOOR_MCP_VAULT`) y hardcodeada hoy en `modules/mcp-json.tpl`; las assertions deben coincidir con ese valor.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `bats tests/` pasa de 6 fallas a 0 fallas (668/668 `ok`).
- **SC-002**: El diff del feature toca exclusivamente archivos bajo `tests/`, más `CHANGELOG.md` y `VERSION`; cero líneas en `modules/`, `docker/`, `scripts/` o `setup.sh`.
- **SC-003**: Cada uno de los 6 tests nombrados (320, 321, 324, 328, 367, 397) corre aislado por nombre y reporta `ok`.
- **SC-004**: La verificación es reproducible sin Docker (no requiere `DOCKER_E2E`): basta `bats tests/` en el host con las dependencias estándar.

## Assumptions

- Los templates (`modules/mcp-json.tpl`) representan el contrato **correcto e intencional** post-PR #59; el defecto está exclusivamente en las assertions de test. Verificado leyendo el template (github en `github-mcp-server`/`stdio` líneas 62-63; vault en `@0.12.0` línea 70) y corriendo la suite.
- La versión de vault `0.12.0` es estable y no se bumpeará dentro de este feature; alinear la assertion a `0.12.0` (literal) es suficiente para v1.
- Parametrizar la assertion (y/o el template) para leer la versión de vault desde `scripts/lib/versions.sh` en vez de hardcodearla queda **fuera de alcance** y se anota como deuda técnica opcional para un feature posterior.
- Las migraciones github→`github-mcp-server` y el pin de vault ya fueron entregadas y validadas en PR #59; este feature no las revisa ni las altera.
- No hay impacto en seguridad, secretos, privilegios del contenedor ni comportamiento del agente en runtime: es un cambio puramente de aserción de tests.
