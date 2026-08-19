---
description: "Task list — feature 030 warm cache para MCPs fuera del catálogo"
---

# Tasks: Warm cache para MCPs fuera del catálogo (docker boot + local login)

**Input**: Design documents from `specs/030-mcp-warm-cache/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md,
contracts/{warm-derivation,boot-integration,docker-e2e-tiers}.md

**Tests**: OBLIGATORIOS. Repo test-first (Principio III). Los bats se escriben RED antes de la
implementación y quedan GREEN al cerrar cada fase. Suite host sin Docker; `DOCKER_E2E` gateado y
diferido a un host Docker (research D7).

**Organización**: por user story. MVP = Setup + Foundational + US1.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: puede correr en paralelo (archivo distinto, sin dependencia pendiente)
- **[Story]**: US1/US2/US3; Setup/Foundational/Polish sin label

## Convenciones de rutas

Single project. Código: `scripts/lib/mcp_warm.sh` (nuevo), `docker/scripts/start_services.sh`,
`modules/local-bootstrap.sh.tpl`, `setup.sh`. Tests: `tests/*.bats`.

---

## Phase 1: Setup

**Purpose**: línea base de no-regresión antes de tocar nada.

- [X] T001 Capturar baseline: `bats tests/` en los dos bash disponibles (env bash 5.x y `PATH=/bin:$PATH` 3.2.57), anotar `N ok / 0 not ok`. Referencia de no-regresión para T024.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: la lib de derivación `scripts/lib/mcp_warm.sh` — fuente única consumida por US1 (docker
boot) y US2 (local). Bloquea ambas. Test-first. Contrato: `contracts/warm-derivation.md`.

**Tests (RED primero):**

- [X] T002 [P] En `tests/mcp-warm.bats` (NUEVO): los 12 casos oráculo de `contracts/warm-derivation.md` §"Casos de prueba" para `mcp_warm_targets <mcp_json>` — uvx directo (1,2), npx `-y` (3,6,8), npx sin flag (4), **wrapper `seed-*.sh` con `uvx` anidado = google-workspace (5)**, npx `-p` (7), binarios omitidos (9,10), dedup (11), `.mcp.json` ausente → 0 líneas rc 0 (12). Aserta salida byte-exacta `runtime\tpackage` ordenada (C3.3). (FR-002/FR-003)
- [X] T003 [P] En `tests/mcp-warm.bats`: robustez (C4) — server sin `command`/sin `args` no aborta; `.mcpServers` vacío → 0 líneas rc 0.

**Implementación (GREEN):**

- [X] T004 En `scripts/lib/mcp_warm.sh` (NUEVO): `mcp_warm_targets <mcp_json_path>` — pura, sin red. Escanea `[command]+args` por el primer token `uvx`/`npx` (o su basename), toma el siguiente token no-flag como paquete (salta `-y`/`--yes`; `-p <v>`/`--package <v>` → `<v>`), spec literal, dedup `(runtime,package)`, `sort -u` estable (C1-C4). Guarda side-effects tras `BASH_SOURCE` (sin ejecución al `source`). (FR-001/FR-002/FR-003)
- [X] T005 En `scripts/lib/mcp_warm.sh`: `mcp_warm_run <mcp_json_path>` — recorre `mcp_warm_targets`; por target: `uvx` → `uv tool install <spec>` (con `--python python3` si hay); `npx` → poblar `/opt/npm-cache` con `<spec>` (`npm exec --prefer-offline -y --package=<spec> -- true`). **Idempotente** (re-ejecución de un target ya tibio = no-op rc 0, FR-005), timeout por paquete, best-effort (`|| warn "… will resolve on first use"`), retorna 0 SIEMPRE (B3/B7). Emite traza `warming <runtime> <pkg>` + resumen (FR-008). No lee `.env`/secretos (B4). (FR-001/FR-005)

**Checkpoint**: la derivación existe, es pura y testeada; el warmer existe. US1/US2 pueden empezar.

---

## Phase 3: User Story 1 - Un MCP de overlay conecta sin descarga en frío (Priority: P1) — MVP

**Goal**: en docker, al recrear el contenedor, un MCP de overlay (uvx/npx) queda tibio antes de que
`claude` arranque; recrear con la red a PyPI/npm cortada → conecta igual.

**Independent Test**: `DOCKER_E2E=1` — scaffold con `workspace-mcp` estilo-overlay, build, recrear,
probar offline (`UV_OFFLINE=1 uvx workspace-mcp` / `uv tool list | grep`), y sin warm (build-arg) falla.

**Tests (RED primero):**

- [X] T006 [P] [US1] En `tests/start-services-warm.bats` (NUEVO, o el archivo de start_services): sourcear `start_services.sh` con `START_SERVICES_NO_RUN=1` y stubs de `uv`/`npm`; verificar que `pre_warm_mcps` (a) llama al warmer con el `.mcp.json` del workspace, (b) corre ANTES del `tmux new-session` (orden vs los `pre_*`), (c) retorna 0 aun si el warmer "falla" (stub rc≠0), (d) no referencia `.env`/secretos. (B1-B6)
- [X] T007 [P] [US1] En `tests/docker-render.bats` o el test de mirror: verificar que `scripts/lib/mcp_warm.sh` queda disponible para la imagen (mirror a `docker/scripts/lib/` o COPY) y que `start_services.sh` lo sourcea — guardia contra el gotcha `docker-lib-needs-explicit-copy` (B8).
- [X] T008 [P] [US1] En `tests/docker-e2e-warm-cache.bats` (NUEVO, gateado `DOCKER_E2E=1`): tiers E1 (GREEN, warm cubre `workspace-mcp` offline + `/opt/uv`,`/opt/npm-cache` presentes, FR-004), E2 (RED por build-arg off), E3 (no-regresión catálogo, SC-003, **+ idempotencia FR-005: 2º recreate = warm no-op, sin descarga en frío**), E4 (verif previa del offline de `uv`). Contrato `docker-e2e-tiers.md`. Validación real DIFERIDA a host Docker (T025). (SC-001)

**Implementación (GREEN):**

- [X] T009 [US1] En `docker/scripts/start_services.sh`: `pre_warm_mcps` que `source`a `mcp_warm.sh` y llama `mcp_warm_run "<workspace>/.mcp.json"`, **síncrono, pre-`claude`** (junto a los `pre_*` de `start_session()` `:781-783`, antes de `tmux new-session` `:797`), como `agent`. Guard `START_SERVICES_NO_RUN`/`BASH_SOURCE` para testabilidad (B6). (FR-001/FR-002/FR-010)
- [X] T010 [US1] Mirror de `scripts/lib/mcp_warm.sh` a la imagen. **Preferir el patrón mirror-por-`setup.sh`** (como `mcp-catalog.sh`, ya usado para libs compartidas host↔docker); alternativa `git add docker/scripts/lib/mcp_warm.sh` + COPY en `docker/Dockerfile` (patrón `backup_config.sh`). Elegir UNO en impl mirando cuál usa hoy el repo para las libs mirroreadas, y dejar el test T007 verde. (B8)

**Checkpoint**: US1 completo. MVP: el warm de boot cubre los MCP de overlay en docker. Gate real = T025 (DOCKER_E2E) + T026 (hardware).

---

## Phase 4: User Story 2 - El precalentamiento es declarativo y general (Priority: P2)

**Goal**: sin hardcode por-MCP: la lista se deriva del `.mcp.json`. En local, `provision_uv_tools` pasa
a args-aware (cubre el wrapper google-workspace); paridad de derivación con docker.

**Independent Test**: `BOOTSTRAP_DRY_RUN=1` sobre un `.mcp.json` con el wrapper google-workspace → el
plan de warm local incluye `workspace-mcp` (hoy lo omite).

**Tests (RED primero):**

- [X] T011 [P] [US2] En `tests/local-bootstrap.bats` (o el archivo de bootstrap): con un `.mcp.json` que incluye el wrapper `seed-google-creds.sh`→`uvx workspace-mcp`, `provision_uv_tools` en `DRY_RUN=1` emite `PLAN uv-tool workspace-mcp…` (hoy el selector `command=="uvx"` lo OMITE). Mantiene el catálogo (fetch/git al pin) y sigue uvx-only (no warmea npx). (B9/B10)
- [X] T012 [P] [US2] En `tests/mcp-warm.bats`: aserción "general/derivado" — la salida de `mcp_warm_targets` sobre un `.mcp.json` mixto (catálogo + overlay) incluye TODOS los uvx/npx sin ninguna lista hardcodeada (SC-002).

**Implementación (GREEN):**

- [X] T013 [US2] En `modules/local-bootstrap.sh.tpl`: `provision_uv_tools` deriva sus paquetes uvx vía `mcp_warm_targets` (filtrando `runtime==uvx`) en vez de `jq 'select(.command=="uvx") | .args[0]'` (`:92`). Conserva `_mcp_pin`+`--with mcp==<lib>` para el catálogo. Single-source de la derivación (la misma lib que docker); resolver cómo el bootstrap local alcanza `mcp_warm.sh` (copia al workspace o source directo) sin duplicar el jq (B11/D6). (FR-002/FR-010)

**Checkpoint**: US2 completo. La derivación es general en ambos modos; local ve el wrapper del incidente.

---

## Phase 5: User Story 3 - Un warm que falla no rompe el arranque ni filtra secretos (Priority: P3)

**Goal**: fail-soft + traza legible + cero secretos.

**Independent Test**: forzar un warm fallido (paquete inválido / gestor inalcanzable) → el arranque
continúa, la traza nombra el paquete, y ningún paso lee un archivo de secretos.

**Tests (RED primero):**

- [X] T014 [P] [US3] En `tests/mcp-warm.bats`: (a) con `uv`/`npm` stub que retorna rc≠0, `mcp_warm_run` retorna 0 y emite `warn: <runtime> <pkg> failed (will resolve on first use)` nombrando el paquete (FR-007/FR-008/SC-004); (b) **idempotencia (FR-005)**: con un stub que simula un target ya tibio (rc 0), una segunda `mcp_warm_run` sobre el mismo `.mcp.json` retorna 0 y no rompe (re-ejecución segura) — la idempotencia real del cache la asevera además E3 en T008.
- [X] T015 [P] [US3] En `tests/mcp-warm.bats`: aserción no-secretos — `mcp_warm_run` no referencia `.env`/`GOOGLE_OAUTH`/credenciales (grep del source + traza del stub); instalar el paquete es independiente del arranque del MCP (FR-006/SC-005).

**Implementación (GREEN):**

- [X] T016 [US3] En `scripts/lib/mcp_warm.sh`: consolidar el manejo de error (timeout, `|| warn`, resumen intentados/tibios/fallidos) y confirmar que ninguna ruta lee secretos. (Refina T005 si los tests lo exigen.)

**Checkpoint**: el warm es seguro de desplegar — no aborta el boot, es diagnosticable, no toca secretos.

---

## Phase 6: Polish & Cross-Cutting

- [X] T017 [P] Mutación (host): revertir la derivación a `command`-only (`select(.command=="uvx")|.args[0]`) → cae ≥1 test (casos 5 y 7); revertir el fix de `provision_uv_tools` → cae el test del wrapper local; quitar el mirror → cae T007. Restaurar. (C5)
- [X] T018 [P] Bump `VERSION` (MINOR: nueva capacidad). **Verificar contra `origin/main` antes de fijar** (lección 023): si 029 (→0.20.0, PR #91) mergea primero, 030 va a **0.21.0**; si no, 0.20.0. No dejar dos features reclamando la misma versión.
- [X] T019 [P] Entrada en `CHANGELOG.md`: warm de boot derivado del `.mcp.json` (docker uvx+npx) + fix args-aware del local (uvx); cubre MCP de overlay sin cambio en el overlay.
- [X] T020 [P] `README.md`: sub-sección de warm cache / troubleshooting — cómo se precalientan los MCP de overlay y cómo diagnosticar un warm fallido (traza). Superficie de usuario (FR-012).
- [X] T021 [P] `docs/` que corresponda (adding-an-mcp.md / architecture.md): nota del mecanismo de warm en boot y la derivación desde `.mcp.json`.
- [X] T022 `shellcheck -S error` limpio sobre `scripts/lib/mcp_warm.sh`, `docker/scripts/start_services.sh` y las libs/tpl tocadas (comando exacto de CI).
- [X] T023 Regenerate-safety: dos `./setup.sh --regenerate` seguidos dejan `.mcp.json` y derivados byte-idénticos; un agente sin MCP de overlay no cambia comportamiento (FR-009/FR-011). Cubierto por `regenerate.bats` + `docker-render.bats` dentro de la suite verde de T024: 030 no agrega variables nuevas a `.mcp.json` ni a derivados renderizados (mcp_warm.sh es una lib, no un derivado), la byte-identidad se sostiene por construcción.
- [X] T024 Suite completa `bats tests/` GREEN en bash 3.2.57 Y 5.x, byte-idéntico, sin regresión sobre el baseline de T001 (baseline + los tests nuevos). (SC-006) — RESULTADO: 1252 ok / 0 not ok byte-idéntico en bash 3.2.57 Y 5.3.15 (baseline T001 = 1225 + 27 nuevos: mcp-warm 14, start-services-warm 8, local-bootstrap +2, docker-e2e-warm-cache 3 skip).
- [ ] T025 DIFERIDO — `DOCKER_E2E=1 bats tests/docker-e2e-warm-cache.bats` en un host Docker: E1 GREEN, E2 RED, E3 no-reg, E4 (confirmar el offline de `uv`). Gate del Development Workflow por tocar image-baked; se cierra en el deploy.
- [ ] T026 DIFERIDO — Gate de hardware (ferrari): recrear el contenedor de `donna` con la red a PyPI cortada y verificar que `google-workspace` conecta (SC-001 real). Gateado por el operador en el deploy.
- [X] T027 (Opcional, recomendado) `/speckit-analyze` para consistencia spec/plan/tasks antes de `/speckit-implement`.

---

## Dependencies

- **Setup (T001)** → antes de todo.
- **Foundational (T002-T005)** → bloquea US1/US2/US3 (la lib de derivación es la base). Tests (T002-T003) RED antes de impl (T004-T005).
- **US1 (T006-T010)** → depende de Foundational. Tests RED (T006-T008) antes de impl (T009-T010).
- **US2 (T011-T013)** → depende de Foundational (usa `mcp_warm_targets`). Tests RED antes de impl.
- **US3 (T014-T016)** → depende de Foundational (propiedades de `mcp_warm_run`). Puede solaparse con US1/US2.
- **Polish (T017-T027)** → al final; T024/T025/T026 tras cerrar US1/US2/US3.

## Parallel opportunities

- Foundational: T002, T003 en paralelo (casos distintos, mismo archivo nuevo → coordinar merge).
- US1: T006, T007, T008 en paralelo (archivos de test distintos).
- US2: T011, T012 en paralelo.
- US3: T014, T015 en paralelo.
- Polish: T017-T021 en paralelo (archivos distintos).

## MVP scope

Setup + Foundational + US1 (T001-T010): el warm de boot en docker cubre los MCP de overlay derivando la
lista del `.mcp.json`, sin hardcode. US2 (paridad local) y US3 (fail-soft/no-secretos) endurecen y
extienden. Los gates reales (T025 DOCKER_E2E, T026 hardware) se cierran en el deploy.
