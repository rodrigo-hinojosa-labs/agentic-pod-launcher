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

- [ ] T001 Registrar la RED: con un PATH podado (sin `claude` ni `bun`, p.ej.
      `PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"`), correr
      `bats tests/deployment-mode.bats tests/local-vault-seed.bats tests/regenerate.bats tests/qmd-reindex-cmd.bats`
      y confirmar que fallan EXACTAMENTE los 16 conocidos (14 por `resolve_claude_bin` + 685/686 por el
      guard `:544`). Anotar el listado como oráculo. (685/686 ya reproducido en research.md.)

---

## Phase 2: Foundational — seam compartido (bloquea US1)

- [ ] T002 Escribir el guard test `tests/hermetic-seam.bats` (RED): `install_claude_stub` produce un
      ejecutable en un path ABSOLUTO (`-x`), e `install_bun_stub` produce un dir con un `bun` ejecutable.
      Sin efectos al sourcear `helper.bash` (Principio III).
- [ ] T003 Implementar `install_claude_stub` e `install_bun_stub` en `tests/helper.bash` (GREEN de T002),
      según [contracts/hermetic-seam.md](./contracts/hermetic-seam.md): crean `#!/bin/sh`+`exit 0`+`chmod +x`
      bajo `$BATS_TEST_TMPDIR/bin`; `install_claude_stub` imprime el path absoluto del stub.

---

## Phase 3: User Story 1 (P1) — suite hermética verde en runner limpio

**Meta**: los 16 tests pasan con PATH podado. **Test independiente**: T008 (suite con PATH podado → 0 not ok).

- [ ] T004 [US1] Cablear el claude stub en `tests/deployment-mode.bats`: `setup()` llama
      `install_claude_stub`; `_seed_agent_yml` (`:42`) usa el path absoluto del stub en
      `deployment.claude_cli` en vez de `"claude"` (tests 206-211).
- [ ] T005 [P] [US1] Cablear el claude stub en `tests/local-vault-seed.bats`: `setup()` llama
      `install_claude_stub`; reemplazar los dos `claude_cli: claude` (`:30`, `:84`) por el path del stub
      (tests 579-585).
- [ ] T006 [P] [US1] Cablear el claude stub en `tests/regenerate.bats`, SOLO el test `:135`
      "preserves an existing deployment.mode": al pasar a `mode=local`, fijar también
      `deployment.claude_cli` al path del stub (via `yq -i` o el seam). NO tocar los tests docker del
      archivo (test 734).
- [ ] T007 [P] [US1] Cablear el bun stub en `tests/qmd-reindex-cmd.bats` (685/686): `install_bun_stub` +
      prependear su dir al PATH del test ANTES de `_qmd_reindex_locked`; retirar el `bunx` falso obsoleto
      (`:102`, `:119`). El guard `:544` pasa → el `_qmd_run` stubbeado se ejerce.
- [ ] T008 [US1] Gate GREEN: correr los cuatro archivos con PATH podado → 0 not ok; y `bats tests/` en
      host normal → 0 not ok. **Cuidado**: si algún test sella la aserción sobre un path exacto de claude
      o un ExecStart, actualizarla al path del stub (relativo a `$BATS_TEST_TMPDIR`); NO bajar aserciones.
- [ ] T009 [US1] Mutación (SC-005/FR-011): revertir cada seam (volver `claude_cli:"claude"` / quitar el
      bun stub) y confirmar que con PATH podado reaparecen EXACTAMENTE esos 16 rojos; restaurar.
- [ ] T010 [US1] SC-004: `git diff --name-only` muestra solo `tests/` tocado (ningún archivo de runtime
      de producción); y un `--regenerate` real sobre un `agent.yml` real da salida byte-idéntica
      (`resolve_claude_bin`/`setup.sh`/`qmd_index.sh` sin cambios).

---

## Phase 4: User Story 2 (P2) — matriz de bash 3.2/5.x en CI

**Meta**: el job `tests` corre en 3.2 y 5.x, ambos verdes, cada uno imprimiendo su versión.
**Depende de US1** (la suite debe estar sellada antes de correr en dos bash).

- [ ] T011 [US2] Reescribir `.github/workflows/test.yml` como matriz: `{ubuntu-latest, "bash 5.x"}` y
      `{macos-13, "bash 3.2"}`. Instalación de deps por-OS (Linux como hoy; macOS vía `brew` para
      `bats-core`/`yq`/`jq`/`age`). Paso obligatorio: imprimir `bash --version` (+ `/bin/bash --version`
      en el brazo 3.2, FR-007). Brazo 5.x: `bats --print-output-on-failure tests/`. Brazo 3.2:
      `PATH=/bin:$PATH bats --print-output-on-failure tests/`.
- [ ] T012 [US2] Proxy local de ambos brazos: `PATH=/bin:$PATH bats tests/` (3.2.57) y `bats tests/`
      (5.x Homebrew) → ambos 0 not ok sobre la suite sellada. Si algún test es incompatible con 3.2 por
      razón legítima, `skip` con razón NOMBRADA (FR-008) y dejar el conteo visible (esperado: 0 skips,
      CLAUDE.md ya reporta 1183/0 en 3.2.57).
- [ ] T013 [US2] **GATE de CI (post-push, ANTES del merge — disciplina SC-006 de features previas)**:
      tras empujar la rama, confirmar en la corrida de `tests` que aparecen los dos brazos, ambos verdes,
      y que el brazo 3.2 imprime `GNU bash, version 3.2.x` (autoverificación SC-003). Si mostrara 5.x, el
      cableado está mal.

---

## Phase 5: User Story 3 (P3) — reproducible localmente

**Meta**: un contribuyente sin `claude`/`bun` corre `bats tests/` y pasa.

- [ ] T014 [US3] Documentar el repro de PATH podado para contribuyentes (ya está en
      [quickstart.md](./quickstart.md)); agregar un puntero breve en `README.md` (sección de tests) si
      corresponde. Es el mismo oráculo de T008; valor incremental.

---

## Phase 6: Polish & Cross-Cutting

- [ ] T015 [P] Enmienda PATCH de la constitución: en `.specify/memory/constitution.md`, cambiar la línea
      de Platform "Host (launcher): bash 4+" por "bash 3.2+, probado en ambos", bump `1.0.0→1.0.1` con
      rationale, y actualizar el SYNC IMPACT REPORT del encabezado (Governance: enmienda vía el mismo PR).
- [ ] T016 [P] `CHANGELOG.md`: entrada de la feature (suite hermética + matriz de bash) bajo la sección
      apropiada. **DECISIÓN: SIN bump de `VERSION`**, consistente con 019 (tests-only, PR #74): 025 no
      cambia el runtime de producción (SC-004 byte-idéntico). Reconciliar plan.md (que decía "bump PATCH
      provisional") y el bloque SPECKIT de CLAUDE.md a "no bump".
- [ ] T017 [P] `shellcheck -S error` limpio sobre `tests/helper.bash` y cualquier shell tocado.
- [ ] T018 Gate final: `bats tests/` 0 not ok en bash 3.2.57 (`PATH=/bin:$PATH`) Y 5.x; registrar los
      conteos (línea base + los 16 que dejan de fallar en runner limpio).
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
