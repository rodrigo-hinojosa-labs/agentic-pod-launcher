# Implementation Plan: Hermetic CI test suite + bash 3.2/5.x matrix

**Branch**: `025-hermetic-ci-suite` | **Date**: 2026-07-26 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/025-hermetic-ci-suite/spec.md`

## Summary

El job `tests` de CI está rojo en cada commit de `main` por 16 tests no herméticos (medido 2026-07-26): 14 corren `./setup.sh --regenerate` en modo local y necesitan `claude` resoluble (post-015 `resolve_claude_bin`); 2 (`qmd-reindex-cmd.bats` 685/686) retornan temprano por el guard `command -v bun` (`qmd_index.sh:544`) antes del `_qmd_run` stubbeado. Además el CI corre en un solo bash (5.x), dejando viva la clase de defecto que 023 midió.

Enfoque técnico (todo MEDIDO en Fase 0, ver [research.md](./research.md)): (1) sembrar un `claude` falso ejecutable a un path absoluto e inyectarlo en `deployment.claude_cli` de los tests de modo local, vía un helper compartido en `tests/helper.bash` — `resolve_claude_bin` Caso 1 lo resuelve sin mirar PATH, forzando el stub aun en un host con claude real; (2) sembrar un `bun` falso ejecutable en el PATH de 685/686 para que el guard `:544` pase; (3) reescribir `.github/workflows/test.yml` como matriz de dos brazos: `ubuntu-latest` (bash 5.x) y `macos-13` (bash 3.2.57, forzado con `PATH=/bin:$PATH`), cada uno imprimiendo `bash --version`. CERO cambio de runtime de producción.

## Technical Context

**Language/Version**: Bash (piso real 3.2.57 macOS; CI de agente 5.x). Tests en `bats-core` v1.11.0.

**Primary Dependencies**: GitHub Actions (`test.yml`); `bats`, `yq` v4, `jq`, `git`, `tmux`, `age` (deps declaradas del job). Sin dependencias nuevas de producción.

**Storage**: N/A (feature de test-infra + CI config).

**Testing**: `bats tests/` host-runnable; oráculo de hermeticidad = correr con PATH podado sin `claude`/`bun`.

**Target Platform**: Runners hospedados por GitHub (`ubuntu-latest`, `macos-13`) + host dev macOS/Linux.

**Project Type**: CLI/bash launcher (single project).

**Performance Goals**: N/A. Nota de costo: el brazo macOS cuesta ~10x minutos vs Linux; suite ~4 min → ~40 min-equivalentes/corrida (aceptable para gate por-PR).

**Constraints**: CERO cambio de comportamiento en producción (`resolve_claude_bin`/`setup.sh`/`qmd_index.sh` intactos en runtime); `docker/` y `docker-e2e.yml` sin tocar; el seam fuerza el stub (no depende de la presencia de claude/bun en el host).

**Scale/Scope**: 16 tests a sellar en ~3 archivos (`deployment-mode.bats`, los de vault/qmd regenerate, `qmd-reindex-cmd.bats`); 1 helper compartido; 1 workflow (`test.yml`) a matrizar.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — N/A directo: no se agregan salidas derivadas. La feature NO altera lo que `--regenerate` emite; de hecho SC-004 exige que un `--regenerate` real quede byte-idéntico. PASS.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — no se toca `docker/`, ni compose, ni capabilities; `docker-e2e` fuera de alcance (FR-010). PASS.
- [x] **III. Test-First, Host-Runnable** — el corazón de la feature: hacer la suite host-runnable DETERMINISTA en un runner limpio. Cada fix se demuestra con la reproducción RED (PATH podado) antes del GREEN. `shellcheck -S error` se mantiene limpio. Los helpers en `tests/helper.bash` no tienen efectos al sourcear. PASS (refuerza el principio).
- [x] **IV. Idempotent, Fail-Silent** — N/A: no toca boot/patch/install/backup ni notifiers. PASS.
- [x] **V. Workspace-Is-the-Agent** — N/A: no toca `.state/` ni backups. Los stubs viven en `$BATS_TEST_TMPDIR` (efímero), no filtran rutas del dev-box ni secretos. PASS.
- [x] **VI. Reproducible, Pinned Dependencies** — sin pins nuevos de producción. El runner macOS y la versión de bats se fijan explícitamente en el workflow. `CHANGELOG.md` + `VERSION` se actualizan (cambio de infra, no de contrato de usuario → bump PATCH). PASS.

**Drift de documentación registrado (no violación de principio)**: la sección *Platform & Toolchain Constraints* dice "Host (launcher): bash 4+", contradicho por la realidad (020) y por esta feature que institucionaliza 3.2 en CI. Ver Complexity Tracking; se propone enmienda PATCH de la constitución en el mismo cambio.

**Veredicto**: 6/6 PASS, sin violaciones de principio.

## Project Structure

### Documentation (this feature)

```text
specs/025-hermetic-ci-suite/
├── plan.md              # Este archivo
├── research.md          # Fase 0 (MEDIDO)
├── spec.md
├── data-model.md        # Fase 1
├── quickstart.md        # Fase 1
├── contracts/           # Fase 1
│   └── hermetic-seam.md
├── checklists/
│   └── requirements.md
└── tasks.md             # Fase 2 (/speckit-tasks — NO lo crea /speckit-plan)
```

### Source Code (repository root)

```text
tests/
├── helper.bash               # + install_claude_stub / install_bun_stub (seam compartido)
├── deployment-mode.bats      # _seed_agent_yml usa el path del claude stub (tests 206-211)
├── <vault/qmd regenerate>.bats  # los tests 579-585, 734 usan el mismo seam de claude
└── qmd-reindex-cmd.bats       # 685/686 siembran un bun falso (guard :544)

.github/workflows/
└── test.yml                  # matriz: ubuntu-latest (5.x) + macos-13 (3.2 via PATH=/bin:$PATH)

.specify/memory/constitution.md  # (opcional) enmienda PATCH "bash 3.2+, probado en ambos"
CHANGELOG.md                   # entrada de la feature
VERSION                        # bump PATCH
```

**Structure Decision**: Single project (launcher). Los cambios son test-infra (`tests/`) + CI config (`.github/workflows/test.yml`) + docs de versión. NINGÚN archivo de runtime de producción (`setup.sh`, `scripts/lib/*.sh`, `modules/`, `docker/`) se modifica en su comportamiento.

## Complexity Tracking

| Violación | Por qué se necesita | Alternativa más simple rechazada porque |
|-----------|---------------------|------------------------------------------|
| Ninguna violación de principio | — | — |
| Drift de doc: constitución dice "bash 4+" | La feature institucionaliza el soporte bash 3.2 en CI (ya real desde 020). Dejar "4+" haría que la constitución contradiga un gate de CI verde. | No enmendar: rechazado — dejaría la constitución mintiendo sobre el piso de bash que el propio CI ahora exige verde. Se propone enmienda PATCH ("bash 3.2+, probado en ambos") en el mismo PR, con bump + rationale (Governance). |

## Phase 0 — Outline & Research

Completa. Las dos incógnitas del spec quedaron MEDIDAS (no asumidas) en [research.md](./research.md):
- **685/686**: guard `command -v bun` en `qmd_index.sh:544` corta antes del stub; reproducido con PATH podado (RED) vs bun presente (GREEN).
- **bash 3.2 en CI**: runner macOS + `PATH=/bin:$PATH` fuerza `/bin/bash` 3.2.57; medido en el host. Costo del runner macOS declarado.
- **Seam Clase 1**: `resolve_claude_bin` Caso 1 (setup.sh:89-92) resuelve un absoluto ejecutable sin mirar PATH → fuerza el stub aun con claude real.

## Phase 1 — Design & Contracts

- **data-model.md**: entidades del seam (claude stub, bun stub, brazo de matriz) con sus invariantes.
- **contracts/hermetic-seam.md**: firma y contrato de `install_claude_stub`/`install_bun_stub` y del brazo de CI (qué imprime, cómo se autoverifica la versión de bash).
- **quickstart.md**: cómo reproducir la RED (PATH podado) y verificar la GREEN + los dos brazos de CI.
- **Agent context**: actualizar el puntero SPECKIT en `CLAUDE.md` hacia este plan.

## Re-evaluación Constitution Check (post-diseño)

Sin cambios: el diseño confirma 6/6 PASS. El seam vive en `tests/` (Principio III), no toca runtime (I/VI), no toca docker (II) ni state (V). El único ítem a mano es la enmienda PATCH de la constitución, opcional y no bloqueante.
