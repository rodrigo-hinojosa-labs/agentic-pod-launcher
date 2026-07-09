---

description: "Task list for 015-local-mode-hardening"
---

# Tasks: Local-mode & docker RAG hardening (post first hardware gate)

**Input**: Design documents from `specs/015-local-mode-hardening/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: OBLIGATORIOS y test-first (Constitution Principle III — bats host-side escrito ANTES de la implementación; `shellcheck -S error`; `DOCKER_E2E=1` para cambios de runtime docker).

**Organization**: Por user story (US1-US4). Los cambios tocan las tres rutas de código (host-launcher `setup.sh`, workspace-templated `modules/local-bootstrap.sh.tpl`, image-baked/espejadas `scripts/lib/{wiki_graph,qmd_index}.sh`).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: puede correr en paralelo (archivo distinto, sin dependencias)
- **[Story]**: US1-US4; fases Setup/Foundational/Polish sin label
- Ruta de archivo exacta en cada tarea

## Conflictos de archivo a respetar (no marcar [P] entre sí)

- `setup.sh`: T007, T008, T009, T010 (secuenciales)
- `modules/local-bootstrap.sh.tpl`: T012, T013, T014 (secuenciales)
- `scripts/lib/wiki_graph.sh`: T016, T017 (secuenciales)
- `scripts/lib/qmd_index.sh`: T018 (US3), T021, T022 (US4) — MISMO archivo, secuenciales aunque crucen fases
- `docker/Dockerfile` + `setup.sh::mirror_catalog_to_docker`: T004, T024 (secuenciales)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Baseline de regresión antes de tocar código.

- [X] T001 Capturar baseline verde: correr `bats tests/` y `shellcheck -S error setup.sh scripts/lib/*.sh modules/*.tpl`, registrar conteos de paso (guard de regresión antes de los cambios test-first).

---

## Phase 2: Foundational (Blocking Prerequisites para US3 & US4)

**Purpose**: Helper compartido de observabilidad (redacción de secretos + scratch dir host-backed) que consumen US3 y US4. US1 y US2 NO dependen de esta fase.

**⚠️ CRITICAL**: US3/US4 no pueden empezar hasta completar esta fase. US1/US2 son independientes y pueden arrancar en paralelo.

- [X] T002 [P] Test-first: `tests/rag-obs.bats` (nuevo) para `redact_secrets` (redacta `sk-ant-[A-Za-z0-9_-]+`, `*_TOKEN=…`, `*_KEY=…`, tokens OAuth desde stdin) y `scratch_dir BASE` (`mkdir -p BASE/tmp` fail-silent + echo de la ruta). Escribir PRIMERO; debe FALLAR.
- [X] T003 Implementar `scripts/lib/rag_obs.sh` (nuevo): `redact_secrets` (filtro de stdin) + `scratch_dir`; init guardada con `BASH_SOURCE` (sin efectos al hacer `source`), `shellcheck` limpio.
- [X] T004 Espejar el lib: agregar `scripts/lib/rag_obs.sh` a `setup.sh::mirror_catalog_to_docker` (~L1488-1505, junto a qmd_index/wiki_graph) y una línea `COPY scripts/lib/rag_obs.sh /opt/agent-admin/scripts/lib/rag_obs.sh` en `docker/Dockerfile` (~L230-231).

**Checkpoint**: helper compartido disponible y espejado — US3/US4 pueden empezar.

---

## Phase 3: User Story 1 - Unit del agente local arranca tras `--regenerate` headless (Priority: P1) 🎯 MVP

**Goal**: `deployment.claude_cli` se resuelve a ruta absoluta, se persiste en `agent.yml`, y la unit renderiza un `ExecStart` que systemd arranca sin `203/EXEC`, aunque `--regenerate` corra sin `~/.local/bin` en PATH.

**Independent Test**: contract [claude-cli-resolution.md](contracts/claude-cli-resolution.md) C1-C5; fixture con `claude` sólo en `~/.local/bin`.

### Tests for User Story 1 ⚠️ (escribir primero, deben FALLAR)

- [X] T005 [P] [US1] `tests/claude-cli-resolution.bats` (nuevo): fixture `claude` ejecutable en `HOME/.local/bin` con PATH sin ese dir → assert `detect_claude_cli` devuelve ruta absoluta (C1); assert fail-loud rc≠0 sin candidatos (C4); assert valor persistido absoluto se respeta (C2) y pelado se re-resuelve (C3).
- [X] T006 [P] [US1] Extender `tests/local-render.bats`: dada `CLAUDE_BIN` absoluta, la unit renderizada de `modules/systemd-remote-control.service.tpl` trae `ExecStart=/…/claude remote-control …` (ruta absoluta, nunca el literal `claude`).

### Implementation for User Story 1

- [X] T007 [US1] `setup.sh:80-88` `detect_claude_cli`: resolver a **ruta absoluta** — `command -v claude-enterprise|claude-personal|claude` (ya absoluta si en PATH) y, como fallback, `${OPERATOR_HOME:-$HOME}/.local/bin/claude` y `${OPERATOR_HOME:-$HOME}/.claude/local/claude`; devolver absoluta ejecutable o rc≠0 (no el literal `claude`).
- [X] T008 [US1] `setup.sh:~1109` (scaffold): persistir el valor **absoluto** resuelto en `agent.yml deployment.claude_cli` (Principle I, single source).
- [X] T009 [US1] `setup.sh:2253-2260` `_export_local_context`: usar `DEPLOYMENT_CLAUDE_CLI` si es absoluta+ejecutable; si no (relativa/movida/vacía) re-resolver vía `detect_claude_cli` contra `OPERATOR_HOME` y re-persistir; si nada resuelve, **fail-loud** (rc≠0 + mensaje accionable) en vez de emitir `CLAUDE_BIN=claude`.
- [X] T010 [US1] Round-trip Principle I: verificar que `--regenerate` re-persiste el valor corregido a `agent.yml` y que un segundo `--regenerate` es no-op (idempotente); cubrir en `tests/claude-cli-resolution.bats`.

**Checkpoint**: US1 funcional e independientemente testeable (MVP).

---

## Phase 4: User Story 2 - qmd arranca en local sobre host glibc (Priority: P1)

**Goal**: `provision_bun` detecta la libc del host y baja la build que ejecuta; `bun --version` rc 0 en glibc; idempotente por ejecución real.

**Independent Test**: contract [bun-libc-provisioning.md](contracts/bun-libc-provisioning.md) C1-C5.

### Tests for User Story 2 ⚠️ (escribir primero, deben FALLAR)

- [X] T011 [P] [US2] Extender `tests/local-bootstrap.bats`: `_libc_variant` → `musl` con loader `/lib/ld-musl-*` simulado (o `ldd` stub), `glibc` en caso contrario y por default; el builder de URL omite `-musl` para glibc y lo incluye para musl (interceptar `curl` con stub que registra la URL, sin red); guard re-provisiona cuando un `bun` stub falla `--version` (C3/C4).

### Implementation for User Story 2

- [X] T012 [US2] `modules/local-bootstrap.sh.tpl`: agregar `_libc_variant` (probe `/lib/ld-musl-*` → `ldd --version` `*musl*`/`*GLIBC*` → `getconf GNU_LIBC_VERSION` → default `glibc`).
- [X] T013 [US2] `modules/local-bootstrap.sh.tpl:156-169` `provision_bun`: elegir asset por variante — glibc `bun-linux-${bun_arch}.zip` (dir `bun-linux-${bun_arch}`), musl conserva `-musl`; pin `BUN_VERSION` 1.3.14 intacto.
- [X] T014 [US2] `modules/local-bootstrap.sh.tpl:147` guard idempotente: cambiar a `if have bun && have bunx && bun --version >/dev/null 2>&1; then …` (salta sólo si EJECUTA; una build musl-en-glibc se re-provisiona).

**Checkpoint**: US1 y US2 funcionan independientemente.

---

## Phase 5: User Story 3 - wiki-graph y qmd sin ENOSPC en `/tmp` (docker) (Priority: P1)

**Goal**: los consumidores pesados usan un `TMPDIR` host-backed bajo `.state`; wiki-graph completa `ok` sobre vault grande; los errores de infra se registran (no se tragan). Depende de Foundational (T003).

**Independent Test**: contract [temp-routing-and-observability.md](contracts/temp-routing-and-observability.md) C1-C5.

### Tests for User Story 3 ⚠️ (escribir primero, deben FALLAR)

- [X] T015 [P] [US3] Extender `tests/wiki-graph.bats`: assert el runner fija un `TMPDIR` host-backed y `mktemp -d` cae ahí, no en `/tmp` (C3); un `_wg_aggregate`/`jq` stub que escribe a stderr y falla deja el **stderr real** en `wiki-graph.json.error` (no el genérico `jq aggregation failed`, C4); un stderr con `sk-ant-…` sale **redactado** del state (C5).

### Implementation for User Story 3

- [X] T016 [US3] `scripts/lib/wiki_graph.sh`: `source` de `rag_obs.sh`; al inicio del runner (antes de L290 `mktemp -d`) fijar `TMPDIR` (y `TMP`/`TEMP`) a `scratch_dir <base host-backed>` (base derivada del state/cache dir del vault bajo `.state`).
- [X] T017 [US3] `scripts/lib/wiki_graph.sh:323-327`: reemplazar `2>/dev/null` de la agregación por captura a `"$tmpd/agg.err"`; en fallo, escribir el error real (`aggregation failed: <tail redactado>` vía `redact_secrets`) en el campo `error` del state, no el genérico.
- [X] T018 [US3] `scripts/lib/qmd_index.sh` `_qmd_run` (L84-89): exportar `TMPDIR` (y `TMP`/`TEMP`) host-backed vía `scratch_dir "$(qmd_cache_root)"` antes de invocar `bunx`, de modo que el cache del paquete (~98MB) salga del tmpfs `/tmp`. (Mismo archivo que T021/T022 — secuencial.)
- [X] T019 [P] [US3] DOCKER_E2E: extender `tests/docker-e2e-qmd.bats` — con qmd on y `bunx` cacheado ocupando espacio, `heartbeatctl wiki-graph` completa `last_status: ok` sobre un vault sembrado y escribe `.graph/*.json`; `/tmp` no se llena (cache bajo `.state`).

**Checkpoint**: US1-US3 funcionan independientemente; el tmpfs `/tmp` no bloquea el mantenimiento.

---

## Phase 6: User Story 4 - Observabilidad del reindex qmd en docker (Priority: P2)

**Goal (alcance 015)**: el error real del reindex es observable (sin `/dev/null`) y el env efectivo queda registrado (redactado). El fix de causa raíz (índice construido, G1/SC-005) se DEFIERE al gate confirmatorio con ferrari. Depende de Foundational (T003) y T018.

**Independent Test**: contract [qmd-reindex-observability.md](contracts/qmd-reindex-observability.md) C1-C3.

### Tests for User Story 4 ⚠️ (escribir primero, deben FALLAR)

- [X] T020 [P] [US4] Extender `tests/qmd-reindex-cmd.bats` (y/o `tests/qmd-index.bats`): un `bunx` stub que escribe a stderr y falla → el log/estado del reindex captura ese stderr (C1) y el env efectivo (pkg, coll, cache_root, config dir, TMPDIR) queda registrado (C2); un secreto en stderr/env sale redactado (C3).

### Implementation for User Story 4

- [X] T021 [US4] `scripts/lib/qmd_index.sh:252,257` `_qmd_reindex_locked`: reemplazar `>/dev/null 2>&1` por captura de stderr (a scratch host-backed + `tee` al log del reindex); incluir el error real (redactado) en el estado. (Mismo archivo que T018 — secuencial.)
- [X] T022 [US4] `scripts/lib/qmd_index.sh`: loguear una vez por corrida el env efectivo del wrapper (`pkg`, `coll`, `cache_root`, `QMD_CONFIG_DIR`/`XDG_CACHE_HOME`, `TMPDIR`) filtrado por `redact_secrets` — la pista para la causa raíz diferida. (Mismo archivo — secuencial.)
- [X] T023 [P] [US4] DOCKER_E2E: extender `tests/docker-e2e-qmd.bats` — un `bunx` que falla deja su stderr visible en el log del reindex (no `/dev/null`). NOTA: G1 (índice construido) NO se asserta aquí — es el gate de hardware diferido.

**Checkpoint**: los 4 fixes en código; el error del reindex docker es diagnosticable.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T024 Verificar espejo docker completo: `./setup.sh --regenerate` re-espeja `rag_obs.sh` + libs modificadas a `docker/scripts/lib/`; correr `DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats tests/docker-e2e-heartbeat.bats` verde. (Mismo territorio que T004 — secuencial.)
- [ ] T025 [P] `CHANGELOG.md`: agregar entrada de hardening 015 bajo `## [Unreleased]`; bump `VERSION` 0.8.0 → 0.9.0 (Principle VI, documentation gate).
- [ ] T026 [P] (opcional, Principle VI SHOULD) Consolidar el pin de `bun` hacia `scripts/lib/versions.sh:35` si resulta de bajo riesgo; si requiere plumbing, dejar anotado y no forzar.
- [ ] T027 Gate final: `bats tests/` verde + `shellcheck -S error` limpio + `DOCKER_E2E=1 bats tests/docker-e2e-*.bats` verde (SC-006).
- [ ] T028 Preparar el gate confirmatorio en hardware: revisar `specs/015-local-mode-hardening/quickstart.md` (mclaren US1/US2, ferrari US3/US4). El gate real es post-merge y requiere los túneles Cloudflare arriba (US4 G1 depende de ferrari).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (T001)**: sin dependencias.
- **Foundational (T002-T004)**: tras Setup; BLOQUEA US3 y US4 (no US1/US2).
- **US1 (P1, T005-T010)**: tras Setup; independiente de Foundational y del resto.
- **US2 (P1, T011-T014)**: tras Setup; independiente.
- **US3 (P1, T015-T019)**: tras Foundational (T003).
- **US4 (P2, T020-T023)**: tras Foundational (T003) y tras T018 (mismo archivo `qmd_index.sh`).
- **Polish (T024-T028)**: tras las stories deseadas.

### Cross-file (secuencial obligatorio)

- `setup.sh`: T007 → T008 → T009 → T010
- `modules/local-bootstrap.sh.tpl`: T012 → T013 → T014
- `scripts/lib/wiki_graph.sh`: T016 → T017
- `scripts/lib/qmd_index.sh`: T018 → T021 → T022
- `docker/Dockerfile`/mirror: T004 → T024

### Parallel Opportunities

- US1 y US2 completos pueden avanzar en paralelo entre sí (archivos distintos: `setup.sh` vs `modules/local-bootstrap.sh.tpl`).
- Los tests test-first marcados [P] (T002, T005, T006, T011, T015, T019, T020, T023) corren en paralelo (archivos de test distintos).
- Dentro de US3/US4, `wiki_graph.sh` (T016/T017) y la parte de `qmd_index.sh` son series distintas salvo el archivo compartido `qmd_index.sh`.

---

## Parallel Example: arranque tras Foundational

```bash
# US1 y US2 en paralelo (archivos distintos):
Task: "T005 tests/claude-cli-resolution.bats (US1)"   # + T007-T010 en setup.sh
Task: "T011 extender tests/local-bootstrap.bats (US2)" # + T012-T014 en local-bootstrap.sh.tpl

# Tests test-first de US3/US4 juntos (distinto archivo):
Task: "T015 extender tests/wiki-graph.bats (US3)"
Task: "T020 extender tests/qmd-reindex-cmd.bats (US4)"
```

---

## Implementation Strategy

### MVP First (US1)

1. T001 (baseline) → T005/T006 (tests fallan) → T007-T010 (fix) → validar unit absoluta sin `203/EXEC`.
2. **STOP & VALIDATE**: US1 es el bug crítico; entregable independiente.

### Incremental Delivery

1. Setup → US1 (MVP crítico) → US2 (qmd arranca en glibc) → Foundational → US3 (sin ENOSPC) → US4 (observabilidad) → Polish.
2. Cada story es testeable en aislamiento; US4 cierra sólo la observabilidad (root-cause diferido).

### Orden recomendado por riesgo

US1 (crítico) → US2 (desbloquea qmd local) → Foundational (helper) → US3 (desbloquea espacio) → US4 (observabilidad) → Polish (mirror + CHANGELOG/VERSION + gate).

---

## Notes

- Tests test-first: verificar que FALLAN antes de implementar (Principle III).
- Cambios en `scripts/lib/{wiki_graph,qmd_index,rag_obs}.sh` tocan el runtime docker → `DOCKER_E2E` obligatorio.
- Redacción de secretos (Principle V) obligatoria en TODA captura de stderr/env que llegue a log/state.
- No tocar el modelo de privilegios del contenedor (Principle II): el mecanismo A NO modifica `docker-compose.yml.tpl`.
- Commit por tarea o grupo lógico; excluir SIEMPRE `.claude/settings.json` del commit (modificación local no relacionada).
- El gate confirmatorio en hardware (T028) es post-merge; US4 G1 requiere ferrari alcanzable.
