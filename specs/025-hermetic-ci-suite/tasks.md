# Tasks: Hermetic CI test suite + bash 3.2/5.x matrix

**Feature**: `025-hermetic-ci-suite` | **Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)

Test-first (Principio III). El oráculo de sellado es correr con un PATH podado (sin `claude`/`bun`),
que reproduce el runner limpio. Fase 0 ya MIDIÓ las dos incógnitas (ver [research.md](./research.md)):
685/686 fallan por el guard `command -v bun` (`qmd_index.sh:544`), NO por un subshell; bash 3.2 en CI =
runner macOS + `PATH=/bin:$PATH`.

**Objetivos de archivo (medidos):**
- Clase 1 (claude): `tests/deployment-mode.bats` (`_seed_agent_yml:42`, tests 206-211),
  `tests/local-vault-seed.bats` (`claude_cli: claude` en `:30` y `:84`, tests 579-585),
  `tests/regenerate.bats` (SOLO el test `:135` "preserves an existing deployment.mode", que hace
  `mode=local`; los demás son docker y no resuelven claude).
- Clase 2 (bun): `tests/qmd-reindex-cmd.bats` (tests 685/686).

---

## Phase 1: Setup — línea base RED (oráculo test-first)

- [X] T001 **RED confirmada — CORRECCIÓN sobre research.md**: el simple PATH podado NO bastó en este
      host (Claude Code instalado nativamente → `resolve_claude_bin` Caso 4 encuentra
      `$HOME/.local/bin/claude` igual). Con `env -i PATH=<podado> HOME=<tmpdir>` (neutralizando también
      `$HOME`) se reproducen los 16 `not ok` EXACTOS medidos en CI. Corrección registrada en research.md
      y quickstart.md.

---

## Phase 2: Foundational — seam compartido (bloquea US1)

- [X] T002 `tests/hermetic-seam.bats` escrito y confirmado RED (6 tests: `install_claude_stub`
      ausente → `command not found`, status 127) antes de implementar.
- [X] T003 `install_claude_stub`/`install_bun_stub` implementados en `tests/helper.bash` (GREEN: 6/6).
      Nota de diseño: el default de ambos es `${1:-$TMP_TEST_DIR/bin}` — en archivos SIN
      `setup_tmp_dir` (p.ej. `qmd-reindex-cmd.bats`) hay que pasar un dir explícito (T007).

---

## Phase 3: User Story 1 (P1) — suite hermética verde en runner limpio

**Meta**: los 16 tests pasan con PATH podado. **Test independiente**: T008 (suite con PATH podado → 0 not ok).

- [X] T004 [US1] `deployment-mode.bats`: `setup()` llama `install_claude_stub`; `_seed_agent_yml` usa
      `"${CLAUDE_STUB}"` en `deployment.claude_cli`.
- [X] T005 [P] [US1] `local-vault-seed.bats`: `setup()` llama `install_claude_stub`; ambos
      `claude_cli: claude` (`:30`, `:84`) reemplazados por `"$CLAUDE_STUB"`.
- [X] T006 [P] [US1] `regenerate.bats`: SOLO el test `:135` gana un `yq -i .deployment.claude_cli=<stub>`
      justo después de fijar `mode=local`. El resto del archivo (docker) intacto.
- [X] T007 [P] [US1] `qmd-reindex-cmd.bats` 685/686: `bunx` falso retirado; `install_bun_stub` (con dir
      EXPLÍCITO — el archivo no llama `setup_tmp_dir`) prependeado al PATH antes de `_qmd_reindex_locked`.
- [X] T008 [US1] Gate GREEN confirmado: los 4 archivos con `env -i PATH=<podado> HOME=<tmpdir>` → **0 not
      ok / 33 ok**; suite COMPLETA en host normal → **1189 ok / 0 not ok** (1183 base + 6 de
      hermetic-seam.bats). Ninguna aserción rebajada.
- [X] T009 [US1] Mutación confirmada (`git stash` de los 4 archivos): con el seam revertido, el mismo
      entorno hermético reproduce los **16 `not ok` byte-idénticos** a la RED de T001. Restaurado
      (`git stash pop`).
- [X] T010 [US1] SC-004 confirmado: `git diff --name-only` fuera de `tests/`+`specs/` → vacío. Ningún
      archivo de runtime de producción tocado (`resolve_claude_bin`/`setup.sh`/`qmd_index.sh` intactos).

---

## Phase 4: User Story 2 (P2) — matriz de bash 3.2/5.x en CI

**Meta**: el job `tests` corre en 3.2 y 5.x, ambos verdes, cada uno imprimiendo su versión.
**Depende de US1** (la suite debe estar sellada antes de correr en dos bash).

- [X] T011 [US2] `.github/workflows/test.yml` reescrito como matriz `{ubuntu-latest, "bash 5.x"}` /
      `{macos-13, "bash 3.2"}`, instalación por-OS (Linux como antes; macOS vía `brew list X || brew
      install X`, idempotente), paso de verificación imprime `bash --version` (+ `/bin/bash --version` en
      macOS). YAML validado con `python3 -c 'import yaml; yaml.safe_load(...)'`. Un bug de sintaxis (`:`
      sin comillas en un nombre de step rompía el parseo) detectado y corregido antes de commitear.
- [X] T012 [US2] Proxy local confirmado: suite COMPLETA bajo `PATH=/bin:$PATH` (3.2.57) → **1189 ok / 0
      not ok**, byte-idéntico al resultado bajo 5.x (T008). Cero skips necesarios.
- [ ] T013 [US2] **GATE de CI (post-push, ANTES del merge — disciplina SC-006 de features previas)**:
      tras empujar la rama, confirmar en la corrida de `tests` que aparecen los dos brazos, ambos verdes,
      y que el brazo 3.2 imprime `GNU bash, version 3.2.x` (autoverificación SC-003). Si mostrara 5.x, el
      cableado está mal.

---

## Phase 5: User Story 3 (P3) — reproducible localmente

**Meta**: un contribuyente sin `claude`/`bun` corre `bats tests/` y pasa.

- [X] T014 [US3] Puntero agregado a `README.md` (sección `## Testing`): el comando `env -i
      PATH=... HOME=$(mktemp -d) bats tests/` verificado copy-paste-funcional, más la nota de la
      matriz de CI.

---

## Phase 6: Polish & Cross-Cutting

- [X] T015 [P] Constitución enmendada `.specify/memory/constitution.md`: Platform "bash 4+" →
      "bash 3.2+, tested in both 3.2 (macOS stock) and 5.x (CI matrix, feature 025)"; bump 1.0.0→1.0.1
      con nuevo SYNC IMPACT REPORT y `Last Amended: 2026-07-26`.
- [X] T016 [P] `CHANGELOG.md`: entrada bajo `### Fixed`, sin bump de `VERSION` (precedente 019).
- [X] T017 [P] Confirmado que `shellcheck.yml` EXCLUYE `tests/*` por diseño (línea documentada
      "covered by bats itself") — ningún archivo tocado por 025 entra al scope de ese gate. Corrido el
      comando EXACTO de CI (`find ... -not -path './tests/*' | xargs shellcheck -S error -e
      SC1090,SC1091`) → `rc=0`, sin regresión.
- [X] T018 Gate final: bash 5.x → **1189 ok / 0 not ok**; bash 3.2.57 (`PATH=/bin:$PATH`) → **1189 ok /
      0 not ok**, byte-idéntico. Los 16 antes rojos ahora pasan en ambos. Suma: 1183 base + 6 nuevos
      (`hermetic-seam.bats`) = 1189.
- [ ] T019 Al mergear (main protegida, **no mergear sin confirmación explícita**): abrir el PR; en el
      merge, marcar el bloque SPECKIT de `CLAUDE.md` como MERGED con su SHA y anotar que el job `tests`
      quedó VERDE en ambos brazos.

---

## Dependencies

- T001 (RED) primero; ancla el oráculo.
- T002→T003 (foundational seam) antes de todo US1.
- US1: T004/T005/T006/T007 en paralelo (archivos distintos) tras T003; luego T008 (gate), T009
  (mutación), T010 (no-regresión de producción).
- US2 (T011-T013) DESPUÉS de US1 (la suite debe estar sellada). T013 es gate de CI antes del merge.
- US3 (T014) tras T008.
- Polish (T015-T018) tras US1/US2; T019 es merge-time.

## Parallel example

Tras T003, correr en paralelo (archivos distintos):
`T004 (deployment-mode.bats)`, `T005 (local-vault-seed.bats)`, `T006 (regenerate.bats)`,
`T007 (qmd-reindex-cmd.bats)`.

## Implementation strategy (MVP first)

- **MVP = US1** (T001-T010): sella los 16 → el job `tests` se vuelve verde en `ubuntu-latest`. Entrega
  la señal de CT recuperada por sí solo, aun sin la matriz.
- **US2** agrega la cobertura de bash 3.2 (la deuda de 023) sobre la suite ya sellada.
- **US3** es documentación/onboarding sobre el mismo oráculo.
- **Polish** cierra constitución/CHANGELOG/shellcheck y el gate final + merge.
