# Data Model: Hermetic CI test suite + bash 3.2/5.x matrix

Esta feature no tiene modelo de datos de dominio (es test-infra + CI). Las "entidades" son artefactos del seam de hermeticidad y de la matriz de CI, con sus invariantes.

## Entidad: Claude stub (seam Clase 1)

- **Qué es**: un ejecutable trivial (`#!/bin/sh` + `exit 0`) creado en tiempo de test bajo `$BATS_TEST_TMPDIR/bin/claude`.
- **Productor**: `install_claude_stub` en `tests/helper.bash` (nuevo). Devuelve su path absoluto por stdout.
- **Consumidor**: el `agent.yml` de prueba, campo `deployment.claude_cli`, que recibe el path ABSOLUTO del stub (no el literal `"claude"`).
- **Invariantes**:
  - Path ABSOLUTO y `-x` (ejecutable) → satisface `resolve_claude_bin` Caso 1 (`setup.sh:92`) sin consultar PATH.
  - Efímero (bajo `$BATS_TEST_TMPDIR`); no filtra ninguna ruta fija del dev-box.
  - Fuerza su uso aun cuando el host tenga `claude` real (FR-004): al ser absoluto, `resolve_claude_bin` corta antes del lookup de PATH.
  - Su contenido no importa: `--regenerate` solo necesita que el path sea resoluble; nunca EJECUTA el claude durante el render de la unit.

## Entidad: Bun stub (seam Clase 2)

- **Qué es**: un ejecutable trivial creado bajo un dir de test (p.ej. `$BATS_TEST_TMPDIR/bin/bun`) y prependeado al PATH del test.
- **Productor**: `install_bun_stub` en `tests/helper.bash` (nuevo), o extensión del bin dir que 685/686 ya crean.
- **Consumidor**: el guard `command -v bun` en `qmd_index.sh:544`, que debe PASAR para que `_qmd_reindex_locked` llegue al `_qmd_run` stubbeado.
- **Invariantes**:
  - Solo necesita existir y ser `-x`; nunca se invoca de verdad (los tests stubean `_qmd_run` como función, que gana sobre cualquier binario).
  - Reemplaza al `bunx` falso obsoleto que hoy siembran (el guard chequea `bun`, no `bunx`).

## Entidad: Brazo de matriz de bash (CI)

- **Qué es**: una instancia parametrizada del job `tests` en `.github/workflows/test.yml`.
- **Atributos**: `runner` (`ubuntu-latest` | `macos-13`), `bash_target` (`5.x` | `3.2`), `invocación` (`bats tests/` | `PATH=/bin:$PATH bats tests/`).
- **Invariantes**:
  - Cada brazo imprime `bash --version` antes de correr la suite (FR-007); el brazo 3.2 debe imprimir una versión que empieza con `3.2` (autoverificación, FR-006/SC-003).
  - Ambos brazos corren la MISMA suite sellada; ambos deben quedar verdes salvo skips nombrados explícitamente (FR-008).
  - El brazo 3.2 fuerza `/bin/bash` con `PATH=/bin:$PATH` (medido: sin eso, `env bash` del shebang de bats resuelve al Homebrew 5.x del runner macOS).

## Relaciones y orden

1. Los seams (claude/bun stub) sellan los 16 tests → US1.
2. La matriz corre la suite YA sellada en ambos bash → US2 (depende de 1: sin sellar, el brazo 3.2 también estaría rojo por entorno, no por versión).
3. La suite sellada corre localmente con PATH podado → US3 (mismo oráculo que 1).
