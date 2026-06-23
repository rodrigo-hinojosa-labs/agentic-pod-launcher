# Tasks: Reparar auto-instalación de plugins post-login (DOCKER_E2E a verde)

**Feature**: 008-fix-postlogin-plugin-install · **Branch**: `008-fix-postlogin-plugin-install`
**Spec**: [spec.md](./spec.md) · **Plan**: [plan.md](./plan.md) · **Contrato**: [contracts/supervisor-marketplace-contract.md](./contracts/supervisor-marketplace-contract.md)

TDD: en US2 y US3 el test host-side se escribe y se ve fallar ANTES de implementar. US1 ya tiene su test rojo (el E2E falla hoy). Validación final con rebuild + DOCKER_E2E.

## Phase 1: Setup (baseline rojo)

- [x] T001 Confirmar el baseline: `DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats` falla (cuelga el boot, 0 instalaciones); y `docker exec -u agent <agente vivo> ls /opt/agent-admin/scripts/lib/ | grep plugin-install` → ausente. Registrar.

## Phase 2: Foundational (verificación de seams — solo lectura)

- [x] T002 Confirmar que `tests/start-services-watchdog.bats` sourcea `docker/scripts/start_services.sh` (línea ~22) y que `ensure_official_marketplace` es invocable host-side con stubs de `claude`/`log`/`CLAUDE_CONFIG_DIR_VAL`/`OFFICIAL_MARKETPLACE_NAME`. Confirmar que `timeout` (busybox) está en la imagen Alpine. No editar nada.

## Phase 3: User Story 1 — El test post-login vuelve a verde (Priority: P1)

**Goal**: el stub `claude` del E2E maneja toda la familia `plugin` → el boot completa, el watchdog corre, el plugin se instala tras el flip.

**Independent Test**: `DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats` → ok.

- [x] T003 [US1] En `tests/docker-e2e-postlogin.bats` (bloque del stub `claude`, ~líneas 70-84), agregar manejo no bloqueante para `plugin marketplace list` (imprime nada, exit 0), `plugin marketplace add` (exit 0) y `plugin list` (exit 0); preservar la rama `plugin install` actual; reservar `exec sleep 86400` SOLO para bare `claude`. Releer el bloque antes de editar.

## Phase 4: User Story 2 — El boot no se cuelga si claude se cuelga (Priority: P2)

**Goal**: `ensure_official_marketplace` acota sus llamadas a `claude` con `timeout` (degrada si ausente), permanece fail-silent, nunca cuelga el boot.

**Independent Test**: `bats tests/start-services-marketplace.bats` (host, sin Docker).

- [x] T004 [US2] TEST-FIRST (rojo): crear `tests/start-services-marketplace.bats` que sourcea `docker/scripts/start_services.sh`, stubea `claude` para que CUELGUE en `plugin marketplace list` (p.ej. `sleep 30`), setea un timeout corto configurable, e invoca `ensure_official_marketplace`; asevera que retorna 0 dentro de un límite acotado (~2-3s, no 30s). Verlo FALLAR (hoy cuelga / espera 30s) antes de T005.
- [x] T005 [US2] En `docker/scripts/start_services.sh::ensure_official_marketplace`, envolver las llamadas `claude plugin marketplace list` y `claude plugin marketplace add` con `timeout "${MARKETPLACE_CMD_TIMEOUT:-12}"`, usando `command -v timeout` para degradar a la llamada directa si ausente. Mantener fail-silent (retorna 0, loguea WARN si el timeout dispara). Hacer el timeout configurable por env para el test. Confirmar T004 en verde.
- [x] T006 [US2] `shellcheck -S error docker/scripts/start_services.sh` limpio tras el cambio.

## Phase 5: User Story 3 — El retry acotado realmente corre en la imagen (Priority: P3)

**Goal**: `plugin-install.sh` llega a la imagen vía una línea `COPY`; `retry_plugin_install_bounded` queda definido en runtime.

**Independent Test**: `bats tests/docker-setup.bats -f "plugin-install"` (host) + verificación en imagen (DOCKER_E2E).

- [x] T007 [US3] TEST-FIRST (rojo): en `tests/docker-setup.bats`, agregar un test que asevere (a) `docker/Dockerfile` contiene `COPY scripts/lib/plugin-install.sh /opt/agent-admin/scripts/lib/plugin-install.sh`, y (b) tras `run_docker_wizard <dest>`, existe `<dest>/docker/scripts/lib/plugin-install.sh` (presente vía copia wholesale). Verlo FALLAR (la línea COPY no existe) antes de T008.
- [x] T008 [US3] En `docker/Dockerfile`, agregar `COPY scripts/lib/plugin-install.sh /opt/agent-admin/scripts/lib/plugin-install.sh` junto al bloque de libs image-only (líneas 214-219). NO tocar `setup.sh::mirror_catalog_to_docker`. Confirmar T007 en verde.

## Phase 6: Polish & Cross-Cutting

- [x] T009 Correr la suite host-side completa `bats tests/` → 0 fallas (incluye los nuevos tests de US2/US3 y los existentes).
- [x] T010 Validación runtime: `DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats` → ok (rebuild implícito); luego `DOCKER_E2E=1 bats tests/docker-e2e-*.bats` → 0 fallas (11/11).
- [x] T011 Verificación directa del lib en una imagen construida: `/opt/agent-admin/scripts/lib/plugin-install.sh` existe y, al sourcear el supervisor, `command -v retry_plugin_install_bounded` es verdadero (no path legacy). Opcional: agregar esta aserción al test E2E de postlogin si encaja.
- [x] T012 Bump `VERSION` 0.4.1 → 0.4.2 y entrada en `CHANGELOG.md` (`### Fixed`, 008) describiendo los tres defectos y el alcance; nota: `mirror_catalog_to_docker` no se tocó (lib image-only).
- [x] T013 Disciplina de alcance: `git diff --name-only main` toca solo `tests/`, `docker/scripts/start_services.sh`, `docker/Dockerfile`, `CHANGELOG.md`, `VERSION`, `CLAUDE.md` (marcador) y `specs/008-*`/`.specify/feature.json`. Cero cambios en `setup.sh`, `modules/`, `scripts/lib/`.
- [x] T014 Re-correr `bats tests/` tras CHANGELOG/VERSION → sigue verde.

## Dependencies

- T001 → T002 → US1 (T003) ‖ US2 (T004→T005→T006) ‖ US3 (T007→T008) → Polish (T009 → T010 → T011 → T012 → T013 → T014).
- US1/US2/US3 tocan archivos distintos → paralelizables entre sí tras T002.
- Dentro de US2: T004 (rojo) ANTES de T005 (impl). Dentro de US3: T007 (rojo) ANTES de T008 (impl).
- T010 (DOCKER_E2E) requiere US1 (stub) y se beneficia de US3 (lib) para probar el path acotado; correr tras los tres.

## Parallel Execution Example

```text
# Tras T002, en paralelo (archivos distintos):
US1: T003 (docker-e2e-postlogin.bats)
US2: T004→T005→T006 (start-services-marketplace.bats + start_services.sh)
US3: T007→T008 (docker-setup.bats + Dockerfile)
# Converge en Polish (T009 host verde, T010 DOCKER_E2E verde).
```

## Implementation Strategy

MVP = US1 (devuelve el E2E a verde). US2 cierra el riesgo de boot-stall (Principio IV). US3 restaura el retry acotado de 004/006. Entrega incremental con TDD host-side en US2/US3; la validación de integración (US1 + path acotado de US3) es con `DOCKER_E2E=1` + rebuild en Polish.
