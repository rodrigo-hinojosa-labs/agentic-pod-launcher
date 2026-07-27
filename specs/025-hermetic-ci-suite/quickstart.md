# Quickstart: verificar la hermeticidad del CI + la matriz de bash

## 1. Reproducir la RED (runner limpio simulado, antes del fix)

Podar el PATH NO BASTA en un host con Claude Code instalado nativamente: `resolve_claude_bin` Caso 4
(`setup.sh:104-106`) también prueba `"$HOME/.local/bin/claude"`, que existe de verdad en ese host y
enmascara el bug. Hay que neutralizar TAMBIÉN `$HOME` con `env -i`:

```bash
CLEAN_PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"   # ajustar a donde vivan bats/yq/jq
FAKE_HOME=$(mktemp -d)
env -i PATH="$CLEAN_PATH" HOME="$FAKE_HOME" bash -c 'command -v bun || echo "bun ausente (como CI)"'
env -i PATH="$CLEAN_PATH" HOME="$FAKE_HOME" bats tests/deployment-mode.bats tests/local-vault-seed.bats tests/regenerate.bats tests/qmd-reindex-cmd.bats
rm -rf "$FAKE_HOME"
```

Esperado ANTES del fix: 16 `not ok` exactos (medido T001) — los 14 de Clase 1 abortan con "could not
resolve an absolute, executable path to the Claude CLI"; 685/686 fallan (`grep -q "config not found"`
falla) por el guard `qmd_index.sh:544`. Un runner real de GitHub Actions no tiene `$HOME/.local/bin/claude`,
así que ahí el simple PATH podado ya reproducía la RED — la neutralización de `$HOME` es solo necesaria
para reproducirla fielmente en un host de dev con Claude Code instalado.

## 2. Verificar la GREEN (después del fix)

```bash
PATH="$CLEAN_PATH" bats tests/            # los 16 antes rojos pasan, 0 not ok, con PATH podado
```

Y en un host normal (con claude/bun): la suite completa sigue en `0 not ok`, y el resultado es IDÉNTICO al del PATH podado (SC-002).

## 3. Verificar que el seam FUERZA el stub (FR-004)

En un host CON `claude` real instalado, la suite debe seguir usando el stub (no el claude real): el `deployment.claude_cli` de los tests apunta a un path absoluto bajo `$BATS_TEST_TMPDIR`, que `resolve_claude_bin` Caso 1 resuelve sin mirar PATH. Verificación: el resultado de la suite no cambia si se quita `claude` del PATH.

## 4. Verificar que NO cambió producción (SC-004)

```bash
# Sobre un agent.yml real (mclaren) o un fixture, comparar la salida de --regenerate antes/después.
git stash   # o checkout del árbol pre-feature
./setup.sh --regenerate   # capturar artefactos
# aplicar la feature, repetir, y diff byte a byte de los artefactos derivados → deben ser idénticos
```

`resolve_claude_bin`, `setup.sh` y `qmd_index.sh` no cambian de comportamiento.

## 5. Verificar los dos brazos de CI (SC-001/SC-003)

Tras el push de la rama, en la corrida del workflow `tests`:
- Aparecen dos brazos: `bash 5.x` (ubuntu-latest) y `bash 3.2` (macos-latest).
- Cada brazo imprime `bash --version` en su log.
- El brazo 3.2 muestra `GNU bash, version 3.2.x` (autoverificación; si mostrara 5.x, el cableado está mal).
- Ambos terminan verdes (0 not ok), salvo skips nombrados explícitamente.

## 6. Mutación (FR-011/SC-005)

Revertir el seam (volver `claude_cli:"claude"` y quitar el `bun` stub) → con PATH podado, vuelven a fallar exactamente esos 16 tests. Confirma que el seam es load-bearing, no cosmético.

## Fuera de alcance (recordatorio)

- `docker-e2e (nightly)` `exit 141` (SIGPIPE): follow-up aparte, docker-only.
- Cualquier cambio de comportamiento en `resolve_claude_bin`/`setup.sh`/`qmd_index.sh`.
