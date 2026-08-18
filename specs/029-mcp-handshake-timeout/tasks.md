---
description: "Task list — feature 029 ventana de handshake MCP configurable"
---

# Tasks: Ventana de handshake MCP configurable (docker + local)

**Input**: Design documents from `specs/029-mcp-handshake-timeout/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/mcp-timeout-contract.md, quickstart.md

**Tests**: OBLIGATORIOS. El repo es test-first (Principio III). Los tests `bats` se escriben RED antes de
la implementación y quedan GREEN al cerrar cada fase. Suite host, sin Docker. `DOCKER_E2E` no requerido
(research.md D5).

**Organización**: por user story. MVP = Setup + Foundational + US1.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: puede correr en paralelo (archivo distinto, sin dependencia pendiente)
- **[Story]**: US1/US2/US3 (fases de user story); Setup/Foundational/Polish sin label

## Convenciones de rutas

Single project (bash + plantillas). Código: `setup.sh`, `scripts/lib/`, `modules/`. Tests: `tests/*.bats`.

---

## Phase 1: Setup

**Purpose**: línea base para no-regresión antes de tocar nada.

- [X] T001 Capturar baseline: correr `bats tests/` y anotar el conteo verde (`N ok / 0 not ok`) en ambos bash disponibles; esta es la referencia de no-regresión para T021.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: el campo `claude.mcp_timeout_ms`, su saneo y su backfill. Bloquea US1/US2/US3 (ambos modos y
todos los tests dependen de que el campo exista, se sanee y tenga default). Test-first.

**Tests (RED primero):**

- [X] T002 [P] En `tests/mcp-handshake-timeout.bats` (NUEVO): tests del **saneo del valor efectivo** vía `./setup.sh --regenerate` sobre un workspace tmp — casos: valor válido (`90000` → artefacto `90000`), ausente (→ `120000`), `0` (→ `120000`), vacío (→ `120000`), no numérico `"abc"` (→ `120000`), negativo `-5` (→ `120000`), > 7 dígitos (→ `120000`). Aserta contra `docker-compose.yml`. El artefacto efectivo nunca `≤ 0` (INV-2/INV-3, C2).
- [X] T003 [P] En `tests/mcp-handshake-timeout.bats`: tests del **backfill** — un `agent.yml` sin `claude.mcp_timeout_ms` recibe `120000` tras `--regenerate`; un `agent.yml` con `mcp_timeout_ms: 0` NO se toca (queda `0` en `agent.yml`, y el saneo lo degrada en el artefacto); dos `--regenerate` dejan `agent.yml` byte-estable (C1.3/C1.4, D7).
- [X] T004 [P] En `tests/schema.bats` (o `tests/schema-validate.bats`): un `agent.yml` con `claude.mcp_timeout_ms` presente y otro sin él pasan `agent_yml_validate` sin error (campo opcional; C1.1).

**Implementación (GREEN):**

- [X] T005 En `setup.sh`, heredoc de `agent.yml` (~:1203-1205, bloque `claude:`): agregar la línea `mcp_timeout_ms: 120000` (C1.2, data-model §"Artefactos derivados").
- [X] T006 En `setup.sh`, helper nuevo `mcp_timeout_effective()` (molde `channel_health_timeout` de `docker/scripts/start_services.sh:726-728`): valida `^[0-9]{1,7}$` y `> 0`; inválido/ausente → `120000`; **re-exporta `CLAUDE_MCP_TIMEOUT_MS`** con el valor saneado, llamado justo después de `render_load_context` en `regenerate()` (~:2064) para que ambos renders (docker y local) usen el mismo valor. Patrón de export: `_export_local_context` (~:2466-2479). (C2, D6, INV-1)
- [X] T007 En `setup.sh`, `regenerate()` (bloque backfill ~:2048): agregar el backfill con `(.claude | has("mcp_timeout_ms"))` → si ausente, `yq -i '.claude.mcp_timeout_ms = 120000'`; NO usar `//` (evita el gotcha del `0`). Molde: backfill `reply_guard` de la 028. (C1.3, D7)
- [X] T008 En `scripts/lib/schema.sh`: confirmar que `claude.mcp_timeout_ms` opcional pasa `agent_yml_validate` sin registro (los campos no listados no fallan); si el diseño de `schema.sh` lo exige, registrarlo en `_SCHEMA_OPTIONAL_NONEMPTY`. Sin validación numérica dura (haría fallar `--regenerate`, contra FR-006). (C2, research D6)

**Checkpoint**: el campo existe, se sanea y tiene default. US1/US2/US3 pueden empezar.

---

## Phase 3: User Story 1 - Configurable desde el flujo declarativo, ambos modos (Priority: P1) — MVP

**Goal**: el operador fija la ventana en `agent.yml` y el valor llega al proceso `claude` en docker y en
local, sobrevive `--regenerate`, sin editar derivados.

**Independent Test**: fijar `claude.mcp_timeout_ms` a un valor N, `--regenerate`, y ver N en el artefacto
de cada modo (compose `environment:` / `remote-control.env`), sin edición manual.

**Tests (RED primero):**

- [X] T009 [P] [US1] En `tests/docker-render.bats`: tras `--regenerate` en modo docker, el `docker-compose.yml` tiene `MCP_TIMEOUT: "<valor efectivo>"` dentro de `environment:`. (C3.1/C3.2)
- [X] T010 [P] [US1] En `tests/local-render.bats`: tras `--regenerate` en modo local, `.state/remote-control.env` tiene `MCP_TIMEOUT=<valor efectivo>`. (C4.1/C4.2)
- [X] T011 [P] [US1] En `tests/mcp-handshake-timeout.bats`: **single-source** — cambiar `claude.mcp_timeout_ms` de A a B y re-renderizar hace que AMBOS artefactos (compose + remote-control.env) reflejen B; el literal no aparece hardcodeado en ninguna de las dos plantillas (ambas usan `{{CLAUDE_MCP_TIMEOUT_MS}}`). (C5, INV-1)

**Implementación (GREEN):**

- [X] T012 [P] [US1] En `modules/docker-compose.yml.tpl`, bloque `environment:` (~:61-66, junto a `TZ`): agregar `MCP_TIMEOUT: "{{CLAUDE_MCP_TIMEOUT_MS}}"`. NO tocar nada bajo `docker/`. (C3.3)
- [X] T013 [P] [US1] En `modules/remote-control.env.tpl`: agregar `MCP_TIMEOUT={{CLAUDE_MCP_TIMEOUT_MS}}`. NO tocar el `.service` ni el `.env`. (C4.1/C4.4)

**Checkpoint**: US1 completo e independientemente testeable. MVP entregable.

---

## Phase 4: User Story 2 - El default absorbe la descarga en frío out-of-the-box (Priority: P2)

**Goal**: un agente nuevo, sin configurar nada, ya tiene la ventana en 120 s, suficiente para una descarga
en frío de ~50 s.

**Independent Test**: con `claude.mcp_timeout_ms` ausente, verificar que el valor efectivo en ambos
artefactos es `120000`.

**Tests (RED primero):**

- [X] T014 [P] [US2] En `tests/mcp-handshake-timeout.bats`: con el campo ausente (scaffold nuevo o `agent.yml` viejo backfilleado), el valor efectivo escrito en ambos artefactos es `120000` (> 50 s de descarga + > 30 s del default del binario). (SC-003, C6.2)

**Gate diferido (hardware, fuera de esta sesión):**

- [ ] T015 [US2] DIFERIDO — Gate de despliegue a `donna`: `--regenerate` + rebuild/recreate del contenedor con el cache de `workspace-mcp` frío, y verificar que `google-workspace` conecta (la descarga de ~50 s cabe en 120 s), en vez del estado muerto del 16-08-2026. Requiere el host ferrari; se documenta en el PR y se cierra en el deploy. (SC-004)

**Checkpoint**: el default cierra el incidente out-of-the-box (código); el gate real es el deploy.

---

## Phase 5: User Story 3 - Una ventana amplia no esconde un MCP roto (Priority: P3)

**Goal**: dejar documentado cómo distinguir un MCP que arrancó lento (y conectó) de uno genuinamente roto.

**Independent Test**: seguir el procedimiento del quickstart §4 y confirmar que separa "lento pero sano"
de "roto".

- [X] T016 [US3] Confirmar que `specs/029-mcp-handshake-timeout/quickstart.md` §4 documenta el método de diagnóstico (arranque manual del MCP, `pgrep` en el contenedor, cache caliente vs frío) y agregar un puntero breve en `README.md` (sección de MCP / troubleshooting) hacia ese diagnóstico. (SC-007, FR-009)

**Checkpoint**: el trade-off de la ventana amplia queda con contramedida documentada.

---

## Phase 6: Polish & Cross-Cutting

- [X] T017 [P] Bump `VERSION` (MINOR: nueva capacidad configurable; precedente 026 = MINOR).
- [X] T018 [P] Entrada en `CHANGELOG.md` describiendo `claude.mcp_timeout_ms`, el default 120 s, y que aplica a docker y local.
- [X] T019 [P] Documentar `claude.mcp_timeout_ms` en `README.md` (superficie de usuario) y en la referencia de `docs/` que corresponda (config de `agent.yml`). (FR-011, gate de documentación)
- [X] T020 `shellcheck -S error` limpio sobre `setup.sh` y las libs tocadas (comando exacto de CI).
- [X] T021 Suite completa `bats tests/` GREEN en bash 3.2.57 Y 5.x, byte-idéntico, sin regresión sobre el baseline de T001 (baseline + los tests nuevos).
- [X] T022 Mutación: revertir por separado cada fix clave (saneo T006, render docker T012, render local T013, backfill T007) y confirmar que cada reversión tumba ≥1 test; restaurar. (SC-001/SC-002/SC-005)
- [X] T023 (Opcional, recomendado) `/speckit-analyze` para consistencia spec/plan/tasks antes de `/speckit-implement`.

---

## Dependencies

- **Setup (T001)** → antes de todo.
- **Foundational (T002-T008)** → bloquea US1/US2/US3. Tests (T002-T004) RED antes de impl (T005-T008).
- **US1 (T009-T013)** → depende de Foundational (necesita el campo, el saneo/export y el backfill). Tests RED (T009-T011) antes de impl (T012-T013).
- **US2 (T014-T015)** → depende de Foundational (el default) + US1 (los artefactos rendeados). T015 diferido a hardware.
- **US3 (T016)** → independiente (documentación).
- **Polish (T017-T023)** → al final; T021/T022 tras cerrar US1/US2.

## Parallel opportunities

- Foundational: T002, T003, T004 en paralelo (archivos/casos distintos).
- US1: T009, T010, T011 en paralelo (tests, archivos distintos); T012 y T013 en paralelo (plantillas distintas).
- Polish: T017, T018, T019 en paralelo (archivos distintos).

## MVP scope

Setup + Foundational + US1 (T001-T013): el operador puede fijar la ventana desde `agent.yml` y el valor
llega a ambos modos, sobreviviendo `--regenerate`. US2 (el default 120 s) ya viene de Foundational; su
tarea de código es solo el test T014 (el gate real T015 es el deploy). US3 es documentación.
