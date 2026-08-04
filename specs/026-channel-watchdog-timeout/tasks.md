# Tasks: Timeout configurable del watchdog del channel (docker)

**Feature**: `026-channel-watchdog-timeout` | **Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)

Test-first (Principio III). Cambio **docker-only** en `docker/scripts/start_services.sh` (image-baked,
sin mirror). Oráculo RED: los tests host sourcean el script con `START_SERVICES_NO_RUN=1` y stubbean
`pgrep`/`sleep`; el discriminador es un channel que aparece en `elapsed=22s` (fuera del cap viejo de 20s,
dentro del default nuevo de 60s). Decisiones cerradas en [research.md](./research.md) y
[contracts/channel-health-timeout.md](./contracts/channel-health-timeout.md):
`CHANNEL_HEALTH_TIMEOUT` (segundos, default 60), helper `channel_health_timeout()`, WARN sin cap al
boot si el override ≥ umbral (65s), log honesto (FR-005).

**Archivos objetivo**:
- Runtime: `docker/scripts/start_services.sh` (`verify_channel_healthy` :721-732, `start_session` log
  :760, comentario :719-720, `main` :1191+, helper nuevo).
- Tests: `tests/start-services-watchdog.bats` (seam existente), `tests/docker-render.bats:162`
  (edición cruzada obligatoria), `tests/docker-e2e-postlogin.bats` (gate DOCKER_E2E).
- Docs: `README.md`, `CLAUDE.md`, `docs/architecture.md`. VERSION, CHANGELOG.

---

## Phase 1: Setup — oráculo RED

- [X] T001 Confirmar el estado RED base: sourcear `docker/scripts/start_services.sh` con
      `START_SERVICES_NO_RUN=1` en un scratch y verificar (a) que `channel_health_timeout` NO existe
      (`type channel_health_timeout` → not found) y (b) que `verify_channel_healthy` hoy usa
      `timeout=20` hardcodeado (`docker/scripts/start_services.sh:722`). Anota el oráculo: un channel que
      aparece a `elapsed=22s` NO es detectado con el comportamiento actual.

---

## Phase 2: Foundational — helper `channel_health_timeout()` (bloquea US1/US2/US3)

- [X] T002 Escribir los tests del contrato del helper en `tests/start-services-watchdog.bats`
      (sourceando el script): `channel_health_timeout` imprime `60` para entradas unset, `""`, `abc`,
      `1.5`, `-5`, `0`; e imprime el valor tal cual para `20`, `45`, `90`. Correr → **RED** (función no
      definida). Ref: [contracts/channel-health-timeout.md](./contracts/channel-health-timeout.md) §2.
- [X] T003 Implementar `channel_health_timeout()` en `docker/scripts/start_services.sh` (definido antes
      de `verify_channel_healthy`, en scope visible por `verify_channel_healthy`, `start_session` y
      `main`): lee `${CHANNEL_HEALTH_TIMEOUT:-}`, valida `[[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -gt 0 ]`
      (patrón sin comillas, bash 3.2+5.x), fallback `60`, `printf` a stdout. → **GREEN** de T002.

---

## Phase 3: User Story 1 (P1) — el operador amplía el timeout sin parchear

**Meta**: `verify_channel_healthy` respeta el valor configurado por `CHANNEL_HEALTH_TIMEOUT`, y un
override grande avisa del trade-off con el crash budget. **Test independiente**: T004 (override 20 vs
default 60 con `pgrep` que aparece a `elapsed=22`).

- [X] T004 [US1] En `tests/start-services-watchdog.bats`, agregar el seam de stub (`_stub_pgrep_after K`
      que escribe un `pgrep` con contador en `$TMP_TEST_DIR/bin` + un `sleep` no-op, `PATH` prependeado
      en la línea del `run`) y 3 tests de `verify_channel_healthy` con `K=12` (aparece a `elapsed=22`):
      (a) sin var → `return 0` (22 < 60); (b) `CHANNEL_HEALTH_TIMEOUT=20` → `return 1` (22 > 20);
      (c) nunca aparece → `return 1` en tiempo real `< 3s` (medido con `date +%s`, prueba que `sleep`
      es no-op). Correr → **RED** (caso (a) falla: `:722` usa 20). Ref: contracts §3.
- [X] T005 [US1] Cambiar `docker/scripts/start_services.sh:722` `local timeout=20` →
      `local timeout; timeout="$(channel_health_timeout)"`. → **GREEN** de T004.
- [X] T006 [US1] En `tests/start-services-watchdog.bats`, tests de la interacción con el crash budget:
      (a) usando `crash_budget_check` con timestamps sintéticos, validar el punto de ruptura `T<70`
      (5 fallos de ciclo `T+5` caben en `WINDOW=300` para `T=60`, NO para `T=90`); (b) el WARN de boot
      se emite para un timeout resuelto `≥ 65` y NO para `60`. Correr → **RED** (el WARN no existe).
- [X] T007 [US1] Implementar el WARN de crash budget en `main()` de
      `docker/scripts/start_services.sh` (una sola vez al boot): si `channel_health_timeout() ≥ 65`,
      `log WARN` explicando que con ese valor 5 fallos consecutivos del channel no caben en la ventana
      del crash budget (`WINDOW=300`) y el backstop de restart-de-contenedor puede no escalar. Sin cap.
      → **GREEN** de T006(b).
- [X] T008 [US1] Gate DOCKER_E2E en `tests/docker-e2e-postlogin.bats`: con `CHANNEL_HEALTH_TIMEOUT=<N>`
      en el `.env` del workspace de prueba (camino real, no parche de `environment:`), asertar
      conductualmente (a) presencia de la var en el proceso
      (`docker compose exec -u agent … sh -c 'echo $CHANNEL_HEALTH_TIMEOUT'`) y (b) que el log del
      watchdog refleja `<N>`. Diferido a host con `DOCKER_E2E=1`. Ref: contracts §6.

---

## Phase 4: User Story 2 (P2) — un agente recién desplegado no flapea con el default

**Meta**: el default sin configurar es 60, no 20 → el pico de contención (~22-25s) no dispara el flap.
**Test independiente**: T009 (default 60 detecta el channel a 22s; degradación de inválidos a 60).

- [X] T009 [US2] En `tests/start-services-watchdog.bats`, test de aceptación de US2: (a) sin
      `CHANNEL_HEALTH_TIMEOUT`, el channel que aparece a `elapsed=22` es detectado por
      `verify_channel_healthy` (`return 0`) — confirma que el default cambió de 20 a 60; (b) con un
      override inválido (`notanum`), mismo comportamiento (degrada a 60, no flapea). Pasa tras
      T003+T005; si algún caso no pasa, corregir el helper. Ref: spec US2 Acceptance Scenarios.

---

## Phase 5: User Story 3 (P3) — el log del watchdog dice la verdad

**Meta**: el mensaje de channel-no-aparece nombra el valor efectivo (FR-005). **Test independiente**:
T010 (el WARN nombra el valor configurado, no "20s").

- [X] T010 [US3] En `tests/start-services-watchdog.bats`, test de que el mensaje de aviso de
      `start_session` (`:760`) nombra el valor efectivo de `channel_health_timeout` (p.ej. con la var en
      45, el mensaje dice `within 45s`), no el literal `20s`. Correr → **RED** (mensaje hardcoded).
- [X] T011 [US3] Implementar en `docker/scripts/start_services.sh`: (a) `:760` interpola
      `within $(channel_health_timeout)s`; (b) actualizar el comentario `:719-720` (`up to 20s` →
      "default 60s, override CHANNEL_HEALTH_TIMEOUT"); (c) **edición cruzada obligatoria**:
      `tests/docker-render.bats:162` deja de asertar el literal `"never appeared within 20s"` y tolera
      el valor dinámico. → **GREEN** de T010.

---

## Phase 6: Polish & Cross-Cutting

- [X] T012 [P] Documentar `CHANNEL_HEALTH_TIMEOUT` en `README.md`, junto a `TELEGRAM_TYPING_MAX_MS`
      (mismo estilo/lugar): default 60s, override por `.env`, unidad segundos, aviso de crash budget.
      NO tocar `modules/env-example.tpl` (inauguraría un patrón; ver research (g)).
- [X] T013 [P] Actualizar `CLAUDE.md` (Watchdog state machine, ~:67-75) y `docs/architecture.md`
      (pseudocódigo del watchdog, ~:112-121): el verify timeout es configurable (default 60s) y su
      interacción con el crash budget.
- [X] T014 [P] Bump `VERSION` `0.16.0 → 0.17.0` y agregar entrada en `CHANGELOG.md` bajo `### Fixed`
      (flapeo de boot por timeout del channel hardcodeado; nueva var `CHANNEL_HEALTH_TIMEOUT`).
- [X] T015 [P] `shellcheck -S error docker/scripts/start_services.sh` → limpio (el mismo gate de CI).
- [X] T016 Gate final: `bats tests/` completa **GREEN** en bash 5.x y en bash 3.2
      (`env PATH=/bin:$PATH bats tests/`); **mutación** — revertir `:722` a `local timeout=20` reaparece
      la falla de T004(a)/T009 (restaurar); DOCKER_E2E `docker-e2e-postlogin.bats` en host Docker si
      disponible (si no, dejar T008 diferido y anotarlo). Confirmar que ningún test previo se rompió.

---

## Dependencies

- **T001** (RED) primero — ancla el oráculo.
- **T002 → T003** (foundational helper) antes de todo US.
- **US1** (T004→T005, T006→T007, T008) tras T003. T004/T005 (verify) y T006/T007 (WARN) son
  sub-cadenas independientes; T008 (e2e) tras T005.
- **US2** (T009) tras T003+T005.
- **US3** (T010 → T011) tras T003. T011 toca `:760` y `docker-render.bats:162`.
- **Polish** (T012-T016) tras US1/US2/US3. T012/T013/T014/T015 en paralelo (archivos distintos);
  T016 al final.

## Parallel example

- Tests de contrato del helper (T002) y del stub de verify (T004) van al **mismo** archivo
  (`start-services-watchdog.bats`) → NO en paralelo entre sí.
- Polish: `T012 (README.md)`, `T013 (CLAUDE.md + architecture.md)`, `T014 (VERSION + CHANGELOG.md)`,
  `T015 (shellcheck)` — archivos distintos, en paralelo.

## Implementation strategy (MVP first)

- **MVP = US1** (T001-T008 sin el e2e diferido): el timeout deja de estar hardcodeado y el operador lo
  configura por `.env`; el override manual de ferrari se puede reemplazar por config declarativa.
  Entrega el valor central por sí solo.
- **US2** es un cambio de default (ya materializado por el helper); su tarea es el test de aceptación
  que blinda el comportamiento 20→60.
- **US3** cierra la observabilidad (log honesto) y la edición cruzada obligatoria.
- **Polish** cierra docs, VERSION/CHANGELOG, shellcheck y el gate de las dos versiones de bash +
  mutación. El gate de hardware (retiro del override de ferrari, quickstart §3) ocurre en el
  despliegue de v0.17.0, no en esta rama.
