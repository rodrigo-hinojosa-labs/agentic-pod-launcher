# Phase 0 Research: Hermetic CI test suite + bash 3.2/5.x matrix

**Fecha**: 2026-07-26. Todo lo de abajo está MEDIDO en el host de desarrollo (macOS arm64) o leído del código con archivo:línea. Nada asumido.

## Decisión 1 — Causa exacta de los tests 685/686 (Clase 2)

**Decisión**: La causa NO es la hipótesis del spec (un subshell/`flock` que pierde el override de `_qmd_run`). Es el guard **`command -v bun`** en [`scripts/lib/qmd_index.sh:544`](../../scripts/lib/qmd_index.sh#L544):

```bash
command -v bun >/dev/null 2>&1 || { _qmd_log "reindex: bun unavailable — skip"; return 0; }
```

`_qmd_reindex_locked` (que los tests llaman directo, sin el wrapper de flock) hace, en orden: hash del vault (no coincide → no es el skip de :538), y en :544 **retorna 0 antes de llamar al `_qmd_run` stubbeado** si `bun` no está en PATH. El stub (que emite `qmd: fatal: config not found (sk-ant-oat01-LEAKME999)`) nunca corre → la aserción `grep -q "config not found"` de 685 falla; nunca se llega a `qmd_write_state ... error` → `last_status=error` de 686 falla. El `bunx` falso que el test siembra (`qmd-reindex-cmd.bats:102,119`) es inútil: el guard chequea `bun`, no `bunx` (quedó obsoleto post-016, cuando `_qmd_run` pasó de `bunx` a un prefijo `bun install`).

**Evidencia (reproducción, 2026-07-26)**:
- Con `bun` en PATH (host dev): `ok 1` / `ok 2` — los dos pasan.
- Con PATH podado sin `bun` (= runner limpio, `/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`): `not ok 1` (`grep -q "config not found"` falla) / `not ok 2`. El tercer test del archivo (redacción de límite de 500 bytes) pasa en ambos porque no depende del path gateado por bun.

**CORRECCIÓN (T001, durante implementación)**: reproducir la RED completa (los 16) exige TAMBIÉN neutralizar `$HOME`, no solo podar el PATH. `resolve_claude_bin` (`setup.sh:104-106`, Caso 4) prueba `"$home/.local/bin/claude"` con `home="${2:-$HOME}"` — en un host de dev con Claude Code instalado nativamente, `$HOME/.local/bin/claude` existe de verdad y el Caso 4 lo resuelve aunque el PATH esté podado, enmascarando el bug de los 14 tests de Clase 1. Medido: `PATH=<podado> bats ...` da solo 2 `not ok` (los de bun); `env -i PATH=<podado> HOME=<tmpdir> bats ...` da los 16 exactos que mide CI (un runner de GitHub Actions no tiene `$HOME/.local/bin/claude`, así que ahí el Caso 4 nunca aplicaba — la discrepancia era solo del intento de reproducción local, no de la medición de CI original). El oráculo local correcto es `env -i PATH=<podado> HOME=<tmpdir>`, actualizado en quickstart.md.

**Rationale**: El fix correcto es sembrar un `bun` falso ejecutable en el PATH del test para que :544 pase y el stub de `_qmd_run` se ejerza — mismo patrón de seam que el `claude` falso. NO se toca `qmd_index.sh` (el guard `command -v bun` es correcto en producción: sin bun no hay reindex posible; el bug es que el test no le da un bun).

**Alternativas consideradas**:
- Reescribir 685/686 para no depender de `_qmd_reindex_locked` (probar `_qmd_run`/redacción directo): descartado — perdería la cobertura de que la señal de error fluye por el path real de reindex (US4).
- Cambiar el guard de producción a `command -v bun || command -v bunx`: descartado — cambio de comportamiento en producción (Principio II/FR-005), y `bunx` ya no se usa.

## Decisión 2 — Cómo correr bash 3.2 en CI

**Decisión**: Brazo 3.2 en un runner **macOS** (`macos-13`/`macos-latest`), corriendo bats con **`PATH=/bin:$PATH`** para forzar que el shebang `#!/usr/bin/env bash` de bats resuelva a `/bin/bash` 3.2.57 (el bash de stock de Apple). Brazo 5.x en `ubuntu-latest` (bash 5.x por defecto). Cada brazo imprime `bash --version` (FR-007).

**Evidencia (medido en el host dev, 2026-07-26)**:
- `/bin/bash --version` → `GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)`.
- `which -a bash` → `/opt/homebrew/bin/bash` PRIMERO (5.3.15), luego `/bin/bash`. O sea `env bash` (el shebang de bats) resuelve a **5.x** por defecto — la trampa exacta que 023 documentó.
- `PATH=/bin:$PATH env bash --version` → `3.2.57`. Confirmado: prependear `/bin` fuerza 3.2.
- Es el mismo mecanismo con que la suite host de los devs ya da `1183/0` bajo 3.2.57 (CLAUDE.md; `render.bats` "11/11 con PATH=/bin:$PATH").

**Rationale**: macOS de stock ES bash 3.2.57 (Apple lo congeló por GPLv3), que es exactamente el piso que el proyecto soporta y que los devs prueban. No requiere compilar nada ni mantener un binario. El brazo se autoverifica imprimiendo `bash --version`: si GitHub algún día cambiara `/bin/bash`, el log lo delata (FR-007), en vez de correr en 3.2 silenciosamente supuesto.

**Alternativas consideradas**:
- **Compilar bash 3.2 en `ubuntu-latest`**: runner más barato (Linux ~1x vs macOS ~10x en minutos), pero agrega un paso de build (~1-2 min) + mantenimiento del pin de bash + riesgo de que un 3.2 compilado difiera del 3.2.57 real de los devs. Descartado como default; se puede reconsiderar si el costo de minutos macOS molesta.
- **Contenedor con bash 3.2**: hay imágenes viejas, pero atan a una distro EOL y un 3.2 empaquetado por terceros ≠ el 3.2.57 de macOS que es el objetivo real. Descartado.
- **No verificar la versión**: descartado — es justo la lección de 023 (correr bajo un bash supuesto que en realidad era otro).

**Costo declarado**: el runner macOS cuesta ~10x minutos vs Linux; la suite corre ~4 min → ~40 "min-equivalentes" por corrida del brazo 3.2. Aceptable para un gate por-PR; se registra el trade-off (SC-003 no exige el runner más barato, exige que el brazo 3.2 exista y se verifique).

## Decisión 3 — Forma del seam de hermeticidad (Clase 1, `claude`)

**Decisión**: Un helper compartido en `tests/helper.bash` (p.ej. `install_claude_stub`) que crea un ejecutable trivial `$BATS_TEST_TMPDIR/bin/claude` (`#!/bin/sh\nexit 0`, `chmod +x`) y devuelve su path absoluto; los tests de modo local siembran `deployment.claude_cli: <ese path absoluto>` en vez de `"claude"`.

**Evidencia (leído, setup.sh:89-92)**: `resolve_claude_bin` Caso 1 — `if [ "${cli#/}" != "$cli" ] && [ -x "$cli" ]; then printf '%s\n' "$cli"; return 0; fi`. Un path absoluto ejecutable se resuelve tal cual, **sin consultar PATH**. Esto:
- Funciona en CI (sin `claude` en PATH).
- **Fuerza el stub incluso en un host con `claude` real** (Caso 1 corta antes del Caso 2 que mira PATH) → cumple FR-004 (comportamiento idéntico dev vs CI).
- No requiere `claude` real y NO toca `resolve_claude_bin` (FR-005).

**Rationale**: Sigue el precedente del repo (019 `install_qmd_stub` en `tests/helper.bash`; 021 seam `SETUP_SYSTEMD_DIR`). El path absoluto bajo `$BATS_TEST_TMPDIR` no filtra ninguna ruta del dev-box y es determinista.

**Alternativas consideradas**:
- Sembrar `claude` en un dir y prependearlo al PATH (como el `bun` stub): funcionaría en CI, pero en un host con `claude` real dependería del orden de PATH → NO fuerza el stub de forma robusta (viola FR-004 si el claude real quedara primero). El path absoluto en `claude_cli` es estrictamente mejor para Clase 1.
- Instalar Claude Code real en el runner: descartado — pesado, no determinista, y contradice la meta de hermeticidad.

## Notas de constitución (para el Constitution Check)

- La línea de Platform de la constitución dice **"Host (launcher): bash 4+"**. La feature 020 ya midió que el código NO requiere bash 4+ y que la suite corre en 3.2.57; CLAUDE.md/README se corrigieron entonces, pero la constitución quedó con "4+". Esta feature INSTITUCIONALIZA el soporte 3.2 en CI, así que esa línea queda contradicha por el hecho. Es drift de documentación, no una violación de principio. Recomendación: enmienda PATCH de la constitución a "bash 3.2+, probado en ambos" en el mismo cambio (Governance permite enmienda vía PR con bump + rationale). Se registra en Complexity Tracking.
