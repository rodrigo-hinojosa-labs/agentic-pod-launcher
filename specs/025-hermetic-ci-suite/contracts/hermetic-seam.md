# Contract: seam de hermeticidad + brazo de matriz de bash

## `install_claude_stub` (tests/helper.bash)

**Firma**: `install_claude_stub [DEST_DIR]` → imprime el path absoluto del stub por stdout; rc 0.

**Comportamiento**:
- Crea `${DEST_DIR:-$BATS_TEST_TMPDIR/bin}/claude` con contenido `#!/bin/sh\nexit 0` y `chmod +x`.
- Imprime su path ABSOLUTO (resuelto, sin `..`).
- Idempotente: llamarlo dos veces deja el mismo archivo.

**Contrato de uso**: el `agent.yml` de prueba pone `deployment.claude_cli: <ese path>`. NUNCA el literal `"claude"` en tests de modo local que ejerzan `--regenerate`.

**Garantía**: con esto, `./setup.sh --regenerate` en modo local resuelve el CLI por `resolve_claude_bin` Caso 1 (absoluto + `-x`) y NO aborta, en cualquier runner, con o sin `claude` real en PATH.

## `install_bun_stub` (tests/helper.bash)

**Firma**: `install_bun_stub [DEST_DIR]` → imprime el path del dir que debe ir en PATH; rc 0.

**Comportamiento**:
- Crea `${DEST_DIR:-$BATS_TEST_TMPDIR/bin}/bun` con `#!/bin/sh\nexit 0` y `chmod +x`.
- El test debe prependear ese dir al PATH ANTES de llamar `_qmd_reindex_locked`.

**Garantía**: el guard `command -v bun` (`qmd_index.sh:544`) pasa → el flujo llega al `_qmd_run` stubbeado → las señales de error (US4) se ejercen en runner limpio.

## Brazo de matriz de CI (`.github/workflows/test.yml`)

**Contrato del workflow**:
- `strategy.matrix` con al menos dos entradas: `{ runner: ubuntu-latest, name: "bash 5.x" }` y `{ runner: macos-13, name: "bash 3.2" }`.
- `runs-on: ${{ matrix.runner }}`.
- Paso obligatorio ANTES de correr la suite: imprimir `bash --version` (y, en el brazo 3.2, `/bin/bash --version`) → FR-007.
- Brazo 5.x: `bats --print-output-on-failure tests/`.
- Brazo 3.2: `PATH=/bin:$PATH bats --print-output-on-failure tests/` (fuerza `/bin/bash` 3.2.57).
- Instalación de deps por-OS: Linux vía `apt`/curl (como hoy); macOS vía `brew` (`bats-core`, `yq`, `jq`, `age`; `tmux` y `git` ya vienen).
- Ambos brazos deben terminar en `0 not ok` (salvo skips nombrados, FR-008).

**Autoverificación (FR-006/SC-003)**: el log del brazo 3.2 muestra `GNU bash, version 3.2.x`. Si mostrara 5.x, el brazo está mal cableado y debe fallar el gate (no correr 3.2 supuesto).

## Oráculo RED→GREEN (test-first, Principio III)

- **RED**: correr los 16 tests con PATH podado sin `claude` ni `bun` → 14 fallan por `resolve_claude_bin`, 2 (685/686) por el guard `:544`. (Reproducción de 685/686 ya medida en research.md.)
- **GREEN**: con los seams aplicados, los mismos 16 pasan con el PATH podado.
- **Mutación (FR-011/SC-005)**: revertir el seam (volver `claude_cli:"claude"` / quitar el bun stub) vuelve a poner rojos exactamente esos 16 en runner limpio.
