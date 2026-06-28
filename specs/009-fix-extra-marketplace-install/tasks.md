# Tasks: Instalación al boot de plugins de marketplaces de terceros

**Feature**: 009-fix-extra-marketplace-install · **Branch**: `009-fix-extra-marketplace-install`
**Spec**: [spec.md](./spec.md) · **Plan**: [plan.md](./plan.md) · **Contrato**: [contracts/extra-marketplace-contract.md](./contracts/extra-marketplace-contract.md)

TDD: los tests host-side (US1 base + US2 degradación) se escriben y se ven fallar ANTES de implementar `ensure_extra_marketplaces`. La validación de integración (US1 al boot + US3) es con rebuild + `DOCKER_E2E`.

## Phase 1: Setup (baseline)

- [x] T001 Registrar el baseline: en el agente vivo (o en código) confirmar que NO existe `ensure_extra_marketplaces` en `docker/scripts/start_services.sh` y que un plugin de marketplace de terceros (`claude-mem@thedotmack`) cae en "plugin install skipped: marketplace not registered yet". Anotar como evidencia de partida.

## Phase 2: Foundational (verificación de seams — solo lectura)

- [x] T002 Confirmar los seams para los tests host-side: `docker/scripts/start_services.sh` se sourcea con `START_SERVICES_NO_RUN=1` (patrón de `tests/start-services-marketplace.bats`); `plugin_catalog_marketplaces_json` emite `{key:{source:{source,repo}}}` y permite derivar pares `(key, repo)` con `jq`; `ensure_official_marketplace` usa `MARKETPLACE_CMD_TIMEOUT` y el idiom `_to="timeout N"`/degradación. Confirmar que `timeout` está en la imagen Alpine y AUSENTE en macOS host (los tests proveen shim). No editar nada.

## Phase 3: User Story 1 — El plugin de terceros se instala al boot (Priority: P1)

**Goal**: el supervisor resuelve cada marketplace de terceros (`marketplace add` confirmado) antes del loop de instalación, de modo que el plugin de terceros queda instalado al boot.

**Independent Test**: con un agente que declara un plugin de terceros, el boot lo instala sin intervención manual (validación E2E en US3).

- [x] T003 [US1] TEST-FIRST (rojo): crear `tests/start-services-extra-marketplace.bats` que sourcea `start_services.sh` (`START_SERVICES_NO_RUN=1`), stubea `claude`/`log`/`plugin_catalog_marketplaces_json`/`CLAUDE_CONFIG_DIR_VAL`, e invoca `ensure_extra_marketplaces`. Casos base: (a) marketplace de terceros ausente en `marketplace list` → se ejecuta `marketplace add <repo>` y queda confirmado; (b) idempotente — si `marketplace list` ya muestra el `key`, NO se re-ejecuta `add`. Verlo FALLAR (la función no existe) antes de T004.
- [x] T004 [US1] En `docker/scripts/start_services.sh`, implementar `ensure_extra_marketplaces`: deriva `(key, repo)` de `plugin_catalog_marketplaces_json /workspace/agent.yml`; por cada uno, si `marketplace list | grep key` ya lo muestra continúa, si no `claude plugin marketplace add <repo> --scope user`; espejo estructural de `ensure_official_marketplace`. Confirmar los casos base de T003 en verde.
- [x] T005 [US1] Encadenar `ensure_extra_marketplaces` en `next_tmux_cmd` (docker/scripts/start_services.sh) en el orden `pre_accept_extra_marketplaces` → `ensure_extra_marketplaces` → `ensure_official_marketplace` → `ensure_all_plugins_installed`.

## Phase 4: User Story 2 — Degradación con gracia (Priority: P2)

**Goal**: `ensure_extra_marketplaces` acota cada llamada a `claude` con `timeout`, permanece fail-silent y nunca cuelga el boot.

**Independent Test**: `bats tests/start-services-extra-marketplace.bats` (host, sin Docker).

- [x] T006 [US2] TEST-FIRST (rojo): añadir a `tests/start-services-extra-marketplace.bats` los casos de degradación: (a) `claude` que CUELGA en `marketplace add` con `MARKETPLACE_CMD_TIMEOUT=1` → `ensure_extra_marketplaces` retorna acotado (elapsed < límite, no 30s) usando un shim `timeout` en PATH (macOS no lo trae); (b) sin `timeout` en PATH → degrada a llamada directa sin romper; (c) `claude` ausente → no-op `return 0`. Verlos FALLAR/colgar antes de T007.
- [x] T007 [US2] En `ensure_extra_marketplaces`, envolver las llamadas `marketplace list`/`marketplace add` con `timeout "${MARKETPLACE_CMD_TIMEOUT:-12}"` vía el idiom `command -v timeout` (degrada a directa si ausente); mantener fail-silent (`return 0`, log WARN si falla/timeout). Confirmar T006 en verde.
- [x] T008 [US2] `shellcheck -S error docker/scripts/start_services.sh` limpio tras los cambios.

## Phase 5: User Story 3 — Cobertura E2E del camino de terceros (Priority: P3)

**Goal**: la suite DOCKER_E2E ejercita la instalación al boot de un plugin de marketplace de terceros.

**Independent Test**: `DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats` → ok, e incluye el caso de terceros.

- [x] T009 [US3] TEST-FIRST (rojo): en `tests/docker-e2e-postlogin.bats`, extender el caso post-login para que el `agent.yml` del fixture declare un plugin de marketplace de terceros, y que el stub `claude` maneje `plugin marketplace add <repo-de-terceros>` (no bloqueante, exit 0) y `plugin install <plugin>@<key>`. Afirmar que el plugin de terceros queda instalado tras el flip. Verlo FALLAR sin la implementación (T004/T005) o sin el manejo del stub.
- [x] T010 [US3] Ajustar el stub `claude` del e2e para la familia de marketplaces de terceros (reusar el patrón del fix 008 para la familia oficial). Confirmar el caso de terceros en verde dentro de `DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats`.

## Phase 6: Polish & Cross-Cutting

- [x] T011 Correr la suite host-side completa `bats tests/` → 0 fallas (incluye `start-services-extra-marketplace.bats` y los existentes).
- [x] T012 Validación de integración: `DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats` → ok (rebuild implícito); luego `DOCKER_E2E=1 bats tests/docker-e2e-*.bats` → 0 fallas.
- [x] T013 Bump `VERSION` 0.4.2 → 0.4.3 y entrada en `CHANGELOG.md` (`### Fixed`, 009) describiendo la asimetría de registro y el fix (`ensure_extra_marketplaces`); nota: cero cambios en `setup.sh`/`modules/`/`scripts/lib/` (la derivación de marketplaces ya existe).
- [x] T014 Disciplina de alcance: `git diff --name-only main` toca solo `docker/scripts/start_services.sh`, `tests/`, `CHANGELOG.md`, `VERSION`, `CLAUDE.md` (marcador) y `specs/009-*`/`.specify/feature.json`. Cero cambios en `setup.sh`, `modules/`, `scripts/lib/`.
- [x] T015 Re-correr `bats tests/` tras CHANGELOG/VERSION → sigue verde.

## Dependencies

- T001 → T002 → US1 (T003→T004→T005) → US2 (T006→T007→T008) → US3 (T009→T010) → Polish (T011 → T012 → T013 → T014 → T015).
- US2 depende de US1 (extiende el mismo archivo de test y endurece la misma función). US3 depende de US1 (necesita la función implementada y encadenada).
- Dentro de US1/US2: el test (rojo) ANTES de la implementación.

## Parallel Execution Example

```text
# La mayoría es secuencial (un archivo de función + un archivo de test host-side).
# Paralelizable tras T005: T009 (extensión e2e, archivo distinto) puede prepararse
# mientras se completa US2 (T006–T008), aunque su validación verde (T010/T012) requiere
# la función ya endurecida.
```

## Implementation Strategy

MVP = US1 (el plugin de terceros se instala al boot). US2 cierra el riesgo de boot-stall (Principio IV) sobre la misma función. US3 cierra el hueco de proceso (cobertura E2E que ocultó el bug). TDD host-side en US1/US2; validación de integración con `DOCKER_E2E` + rebuild en US3/Polish. Cero cambios fuera de `docker/scripts/start_services.sh` + tests.
