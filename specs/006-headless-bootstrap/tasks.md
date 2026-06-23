---
feature: 006-headless-bootstrap
branch: 006-headless-bootstrap
---

# Tasks: Headless bootstrap — token auth, marketplace, onboarding

**Spec**: [spec.md](./spec.md) · **Plan**: [plan.md](./plan.md) · **Research**: [research.md](./research.md) · **Contracts**: [contracts/shell-functions.md](./contracts/shell-functions.md)

**TDD obligatorio** (Constitución, Principio III): cada cambio de comportamiento lleva su `bats` (host, sin Docker), escrito y mostrado en rojo antes de la implementación. La suite por defecto `bats tests/` debe quedar verde y `shellcheck -S error` limpio.

## Format: `[ID] [P?] [Story?] Description with file path`

- `[P]` = paralelizable (archivo distinto, sin dependencias pendientes). Ediciones al mismo archivo (`docker/scripts/start_services.sh`) van **secuenciales**.

---

## Phase 1: Setup

- [ ] T001 Confirmar rama `006-headless-bootstrap` y baseline verde: `bats tests/` y `shellcheck -S error docker/scripts/start_services.sh docker/scripts/lib/plugin-install.sh` antes de tocar nada (línea base para los red→green).

## Phase 2: Foundational (prerequisitos compartidos)

- [ ] T002 [P] En `scripts/lib/plugin-catalog.sh` (o junto a `REQUIRED_CHANNEL_PLUGIN` en `docker/scripts/start_services.sh:147`), declarar las constantes single-source del marketplace oficial: nombre `claude-plugins-official` y fuente `anthropics/claude-plugins-official` — sin duplicar literales (Principio VI). Las consumen US2 y US4.

---

## Phase 3: User Story 1 — Arrancar autenticado sin /login (Priority: P1) 🎯 MVP

**Goal**: el operador scaffoldea con token y el agente arranca autenticado; el supervisor reconoce el token y no cae a `/login` ni dispara kicks espurios. Sin token, se preserva `/login`.

**Independent Test**: `bats tests/` (casos US1) verde; scaffold con token → `claude -p` READY sin /login; scaffold sin token → path /login intacto.

### Tests (rojo primero)

- [ ] T003 [P] [US1] En `tests/start-services-watchdog.bats` añadir: `has_oauth_token` → rc 0 con `CLAUDE_CODE_OAUTH_TOKEN` set, rc 1 unset/empty; y `next_tmux_cmd` con token set + plugin NO listo → output NO emite bare-claude/`/login`; con token unset + plugin no listo → sí (Case A, regresión). Confirmar que FALLA contra el código actual.
- [ ] T004 [P] [US1] En `tests/watchdog-auth-flip-detection.bats` añadir el caso: con `has_oauth_token` true, tocar `AUTH_MARKER_OVERRIDE` (absent→present) ⇒ `_kick_count == 0`; sin token, el caso existente sigue verde. Confirmar rojo.
- [ ] T005 [P] [US1] Añadir un test del `.env` writer de `setup.sh`: token provisto ⇒ línea `CLAUDE_CODE_OAUTH_TOKEN=<v>` presente en `.env` (0600); token vacío ⇒ línea ausente. Ubicar junto a los tests de scaffold/.env existentes (`tests/scaffold*.bats` / `tests/setup*.bats`), siguiendo su estilo no-interactivo. Confirmar rojo.
- [ ] T006 [P] [US1] En `tests/modules-render.bats` añadir: el render de `modules/env-example.tpl` contiene la línea `CLAUDE_CODE_OAUTH_TOKEN=` (sin valor). Confirmar rojo.

### Implementación (verde)

- [ ] T007 [US1] En `docker/scripts/start_services.sh` §4 (cerca de `has_telegram_token`, :360) añadir `has_oauth_token() { [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; }` — definido antes de `next_tmux_cmd`/`_check_auth_flip`; nunca imprime el valor. (verde T003 parte helper)
- [ ] T008 [US1] En `docker/scripts/start_services.sh::next_tmux_cmd` (:453) cambiar el guard del Case A a `if ! _channel_plugin_ready && ! has_oauth_token; then` — con token nunca cae a bare-claude/`/login`; procede a Case B/C dejando que `ensure_all_plugins_installed` reintente. (verde T003)
- [ ] T009 [US1] En `docker/scripts/start_services.sh::_check_auth_flip` (:835) añadir al tope `if has_oauth_token; then _prev_auth_present=1; return 0; fi` (baseline ya-autenticado; sin kick espurio). (verde T004)
- [ ] T010 [P] [US1] En `setup.sh` añadir el paso de wizard "Claude authentication" (cerca del bloque de notificaciones ~540): instruir `claude setup-token` en el host y recoger con `ask_secret` (vacío = skip válido). Garantizar paridad `wizard.sh` + `wizard-gum.sh` (sin echo del valor).
- [ ] T011 [US1] En `setup.sh` (.env writer, ~1137) emitir `CLAUDE_CODE_OAUTH_TOKEN=<valor>` cuando el token fue provisto, con el idiom condicional existente; `.env` queda `0600`; omitir la línea si vacío. (verde T005)
- [ ] T012 [P] [US1] En `modules/env-example.tpl` añadir la sección comentada `# Claude headless auth — from 'claude setup-token' (host); set to skip interactive /login` + `CLAUDE_CODE_OAUTH_TOKEN=` (sin valor). (verde T006)
- [ ] T013 [P] [US1] En `modules/next-steps.en.tpl` y `modules/next-steps.es.tpl` (§ "Log in to Claude") añadir el sub-path headless (recomendado): correr `claude setup-token` en el host y poner `CLAUDE_CODE_OAUTH_TOKEN` en `<workspace>/.env` antes de `docker compose up`; mantener `/login` interactivo como fallback. Advertir que en backup/identity modo partial el `.env` viaja en plano.

**Checkpoint US1**: `bats tests/start-services-watchdog.bats tests/watchdog-auth-flip-detection.bats tests/modules-render.bats` + el test de .env writer verdes; `shellcheck` limpio.

---

## Phase 4: User Story 2 — Plugins/canal instalan en headless (Priority: P2)

**Goal**: el marketplace oficial se registra idempotentemente en boot, antes de instalar plugins, para que los `@claude-plugins-official` (incl. el canal) instalen.

**Independent Test**: tests US2 verdes; en runtime, `marketplace list` muestra el oficial y el plugin del canal obtiene `.installed-ok`.

### Tests (rojo primero)

- [ ] T014 [P] [US2] En `tests/start-services-plugin-install.bats` (stub PATH `claude`) añadir: `ensure_official_marketplace` llama `claude plugin marketplace add anthropics/claude-plugins-official --scope user` cuando `marketplace list` NO contiene el oficial; no-op cuando ya está (idempotencia); stub que falla el add ⇒ rc 0 + WARN (fail-silent). Confirmar rojo.
- [ ] T015 [P] [US2] En `tests/plugin-catalog.bats` añadir aserción que documenta que los specs `@claude-plugins-official` contribuyen `{}` a `marketplaces_json` (por diseño) — así el registro oficial es responsabilidad de `ensure_official_marketplace`. Confirmar verde (no-regresión).

### Implementación (verde)

- [ ] T016 [US2] En `docker/scripts/start_services.sh` añadir `ensure_official_marketplace()` (fail-silent, idempotente con guard `claude plugin marketplace list`, usa la constante de T002 y `CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR_VAL`, corre como agent) e invocarla dentro de `pre_accept_extra_marketplaces` (:412) **antes** del merge de terceros, de modo que `next_tmux_cmd` la corra antes de `ensure_all_plugins_installed`. (verde T014)

**Checkpoint US2**: `bats tests/start-services-plugin-install.bats tests/plugin-catalog.bats` verdes; `shellcheck` limpio.

---

## Phase 5: User Story 3 — Onboarding no bloquea la sesión headless (Priority: P3)

**Goal**: pre-sembrar theme/trust en `.claude.json` y crear `settings.json` si falta, para que el TUI headless no se bloquee.

**Independent Test**: tests US3 verdes; primer arranque alcanza estado operativo sin intervención.

### Research-en-implementación (no inventar — FR-014)

- [ ] T017 [US3] Determinar las keys reales de onboarding de claude **2.1.170** por diff: en el contenedor, completar el onboarding una vez en un `CLAUDE_CONFIG_DIR` coherente (tmpfs) y capturar las keys que pasan de ausente→presente en `.claude.json` (`theme`, `hasCompletedOnboarding`, trust de `/workspace`, etc.). Registrar los nombres exactos en `research.md` (D3) antes de hardcodear.

### Tests (rojo primero)

- [ ] T018 [P] [US3] Crear `tests/start-services-onboarding.bats` (patrón `START_SERVICES_NO_RUN=1` + `$HOME` temporal): `pre_seed_onboarding` CREA `.claude.json` con las keys de T017 cuando está ausente; idempotente cuando ya está; con versión no coincidente ⇒ WARN sin romper. Confirmar rojo.
- [ ] T019 [P] [US3] Extender los tests de `pre_accept_bypass_permissions` (en `tests/start-services-watchdog.bats` o donde vivan) para el caso "settings.json ausente ⇒ se crea con `defaultMode=auto` + skip-perms". Confirmar rojo.

### Implementación (verde)

- [ ] T020 [US3] En `docker/scripts/start_services.sh` añadir `pre_seed_onboarding()` (jq-merge en `$CLAUDE_CONFIG_DIR_VAL/.claude.json`, CREA si falta, idempotente, version-guard/fail-loud con las keys de T017) e invocarla en `start_session` junto a `pre_accept_bypass_permissions`, antes del primer launch. (verde T018)
- [ ] T021 [US3] En `docker/scripts/start_services.sh::pre_accept_bypass_permissions` (:382) relajar el early-return `[ -f settings.json ] || return 0`: si falta, crear `settings.json` con `{}` y aplicar `defaultMode=auto` + `skipDangerousModePermissionPrompt=true`. (verde T019)

**Checkpoint US3**: `bats tests/start-services-onboarding.bats` + casos de bypass verdes; `shellcheck` limpio.

---

## Phase 6: User Story 4 — Log distingue marketplace-not-found de not-authenticated (Priority: P4)

**Goal**: la causa real "marketplace not found" deja de loguearse como "not authenticated".

**Independent Test**: test US4 verde — un install que falla por marketplace ausente se clasifica/loguea distinto de auth-skip.

### Tests (rojo primero)

- [ ] T022 [P] [US4] En `tests/start-services-plugin-install.bats` extender `CLAUDE_STUB_MODE` con `no-marketplace` y aseverar: NO se reintenta 3× y NO se clasifica/loguea como "not authenticated yet". Confirmar rojo.

### Implementación (verde)

- [ ] T023 [US4] En `docker/scripts/lib/plugin-install.sh::retry_plugin_install_bounded` (:38) añadir la clasificación de "No marketplaces configured"/"not found in marketplace"/"unknown marketplace" como outcome distinto (no-retry, etiqueta propia), separado del auth-skip (rc=2). (verde T022)
- [ ] T024 [US4] En `docker/scripts/start_services.sh::ensure_plugin_installed_one` (:231) corregir el mensaje catch-all para no conflacionar "marketplace not found" con "not authenticated yet". (verde T022)

**Checkpoint US4**: `bats tests/start-services-plugin-install.bats` verde; `shellcheck` limpio.

---

## Phase 7: Polish & Cross-Cutting

- [ ] T025 Correr la suite completa `bats tests/` (0 fallas) + `shellcheck -S error docker/scripts/start_services.sh docker/scripts/lib/plugin-install.sh setup.sh`.
- [ ] T026 [P] (Opcional, DOCKER_E2E) Añadir/extender `tests/docker-e2e-postlogin.bats` con el escenario e2e: scaffold con token ⇒ contenedor autenticado por token, sin `/login` interactivo, marketplace registrado y plugin del canal instalado. Gateado tras `DOCKER_E2E=1`; documentar lo que cubre.
- [ ] T027 [P] Verificación funcional (SC-001..004, SC-006) sobre `rodri-cenco-admin` siguiendo [quickstart.md](./quickstart.md): auth READY, marketplace listado, canal con sentinel, fallback sin token, y `grep` de hygiene (token fuera de `agent.yml`/`.env.example`/logs).
- [ ] T028 [P] `CHANGELOG.md` `[Unreleased]` con la entrada del feature 006 + bump `VERSION` (0.3.1 → 0.4.0, feature) por disciplina (Principio VI).

---

## Dependencies

- T001 (setup) → T002 (foundational) → fases de US.
- T002 (constante marketplace) antes de T016 (US2) y T023/T024 (US4).
- Dentro de cada US: tests (rojo) antes de implementación (verde).
- US1 (P1, MVP) es independiente y entrega valor solo. US2 depende conceptualmente de auth (US1) pero su código/test es independiente (stub). US3 y US4 son independientes.
- Ediciones a `docker/scripts/start_services.sh` (T007, T008, T009, T016, T020, T021, T024) son **secuenciales** entre sí (mismo archivo).
- T017 (diff de keys) antes de T018/T020 (US3).
- Polish (T025–T028) tras las fases de US.

## Parallel execution examples

- Tests rojos de US1: T003, T004, T005, T006 en paralelo (archivos distintos).
- Docs/templates de US1: T012, T013 en paralelo con T010 (archivos distintos).
- US2 y US3 pueden avanzar en paralelo salvo las ediciones secuenciales a `start_services.sh`.

## Implementation Strategy

- **MVP = US1** (auth headless): un agente que arranca y se mantiene autenticado sin `/login`. Entregable y testeable solo.
- Incremental: US1 → US2 (canal operativo) → US3 (arranque desatendido sin bloqueo) → US4 (observabilidad). Cada checkpoint deja la suite verde.
- Cierre: polish (suite completa, e2e opcional, verificación funcional, CHANGELOG/VERSION).
