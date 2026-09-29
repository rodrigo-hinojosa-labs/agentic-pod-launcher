# Implementation Plan: Second Brain sobre el LLM Wiki — eje PARA, higiene del retrieval, cola de revisión, packets y favorite problems

**Branch**: `037-second-brain-rag` | **Date**: 2026-09-27 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/037-second-brain-rag/spec.md`

## Summary

037 pone una dimensión de **accionabilidad** (PARA de Forte) encima del LLM Wiki de Karpathy que el vault
ya implementa, sin tocar los seis tipos ni el pin de qmd: claves nuevas de frontmatter validadas por el
linter determinista, hallazgos nuevos que forman una **cola de revisión** (`review_due`, `project_overdue`,
`project_incomplete`, `pending_ingest`, `archive_candidate`, `problem_unfed`, `description_missing`,
`schema_delta_pending`), un catálogo derivado de **packets**, la **higiene del índice qmd** (alcance `wiki/`
con migración automática única que reutiliza embeddings), navegación **index-first gateada**, y las
operaciones de proyecto y revisión como **prosa** en el schema del vault, entregadas a la flota por un
segundo delta con marcador propio. Un aviso semanal opt-in por heartbeat (docker) informa la cola sin
ejecutar nada. Todo es aditivo: ningún script edita el wiki, ningún vault existente cambia, el skeleton
limpio sigue dando 0 hallazgos.

Enfoque técnico: bash 3.2+ / awk / jq en las libs existentes (`wiki_graph.sh`, `vault.sh`, `qmd_index.sh`),
prosa en `modules/vault-skeleton/` + `modules/vault-deltas/`, seis claves en `agent.yml` con el trío de
Principio I, una octava línea de crontab en `heartbeatctl`, y test-first con la suite host dual (bash 3.2 y
5.x), DOCKER_E2E real en este host y gate de hardware antes del merge.

## Technical Context

**Language/Version**: bash 3.2.57 (macOS) y 5.x (Linux/CI), busybox awk (Alpine) y awk BSD (host), jq 1.7.1
(host) / 1.8.1 (imagen), yq v4, Python solo en tests auxiliares. Sin lenguaje nuevo.

**Primary Dependencies**: `@tobilu/qmd` **2.5.3** pineado (sin bump; superficie medida en `discovery/L`),
`inotify-tools` 4.23.9 (Alpine), `flock`, bats-core en host. Ninguna dependencia nueva.

**Storage**: archivos del vault (`wiki/**/*.md`, `raw_sources/`, `index.md`, `log.md`, `_templates/`) que
solo el agente escribe; derivados JSON bajo `<vault>/.graph/` (`graph`, `backlinks`, `findings`,
`packets`, `policy`); state files bajo `<ws>/scripts/heartbeat/` (`wiki-graph.json`, `qmd-index.json`,
`review-prompt.txt`); sentinel de layout de colección bajo `.state/.cache/qmd/`; `agent.yml` como fuente
única.

**Testing**: bats host sin Docker (suite completa en bash 3.2 y 5.x; hoy 1502 `@test`), `shellcheck -S
error`, DOCKER_E2E=1 (imagen `agentic-pod:latest` disponible; Tier-1 de `docker-e2e-qmd.bats` se
des-difiere), gate de hardware (linus docker, mclaren local, ferrari vault de 2.696 páginas) antes del
merge (precedente 024). Mutación por fix (precedente 028-036).

**Target Platform**: contenedor Alpine 3.24.1 aarch64/musl (docker) y hosts Linux glibc con systemd (local);
launcher en macOS/Linux.

**Project Type**: launcher bash + libs image-baked + skeleton de vault (documentos). Sin servicio nuevo.

**Performance Goals**: runner del grafo con todos los hallazgos nuevos < 60 s sobre 2.696 páginas en RPi5
(SC-005, cota heredada de 014); aviso semanal < 60 s medido (SC-007); migración de colección en segundos
(embeddings reutilizados, medido).

**Constraints**: sin séptimo `type` ni `status` nuevos; ningún script edita `wiki/`, `raw_sources/` ni el
`CLAUDE.md` del vault; sin bump de qmd ni escritura del YAML del vendor; sin prompt de wizard; `heartbeat.sh`
(workspace-templated) no cambia; `local_schedule.sh` no cambia; derivados solo JSON bajo `.graph/`;
`vault_hash` no cambia; contrato 0/1/2 de doctor intacto; inglés en skeleton/delta.

**Scale/Scope**: flota de cinco agentes (tres docker en ferrari, dos local); vault mayor de 2.696 páginas;
nueve historias, 36 FR, 10 SC; ~55-70 tareas test-first.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.1). Mark each PASS / N/A / VIOLATION; justify any VIOLATION in Complexity Tracking.*

- [x] **I. Single Source of Truth** — PASS. Seis claves nuevas en `agent.yml` con heredoc + backfill `has()` +
  validación (`contracts/agent-yml-config-037.md`); ningún `{{VAR}}` nuevo en plantillas; los derivados
  nuevos (`policy.json` del runner, `review-prompt.txt` de `cmd_reload`, la octava línea de crontab) se
  regeneran desde `agent.yml`; `--regenerate` idempotente (oráculo en `regenerate.bats`). Re-check
  post-diseño: PASS (K §6 confirma que los moldes 029/034/036 cubren los tres backfills).
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. Cero cambios en compose, capabilities, mounts o
  sockets; el aviso semanal es una línea más del crontab existente ejecutada como `agent`; `heartbeatctl`
  y las libs siguen corriendo con los mismos privilegios. Re-check: PASS.
- [x] **III. Test-First, Host-Runnable** — PASS. Todo hallazgo nuevo es determinista con `WIKI_GRAPH_TODAY`
  inyectable y fixtures de fechas remotas; fixture 014 intacta + golden; seam de qmd de 019 extendido
  (`collection remove`, `cleanup`, `status`, `ls`) para que la migración se pruebe sin qmd real;
  DOCKER_E2E gateado. Re-check: PASS.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. Delta 0.27.0 gateado por marcador con contenido
  (no mtime); migración gateada por sentinel escrito al final, tolerante a interrupción; `cmd_reload` omite
  la línea nueva ante cron inválido con WARN; el runner degrada a defaults ante config inválida; ninguna
  acción automática sobre páginas. Re-check: PASS.
- [x] **V. Workspace-Is-the-Agent** — PASS. Sentinel bajo `.state/.cache/qmd/`; derivados bajo `.graph/`
  (nunca respaldados, JSON); ningún secreto tocado; los tres backups intactos; `--restore-from-fork`
  preservado (nada nuevo que restaurar: el sentinel se recrea en el primer tick). Re-check: PASS.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. qmd sigue en 2.5.3 (medido contra ese binario);
  sin pin nuevo ni duplicado; VERSION 0.26.0 → 0.27.0 (verificar `origin/main` antes del bump) y
  CHANGELOG. Re-check: PASS.

Complexity Tracking: vacío (sin violaciones).

## Project Structure

### Documentation (this feature)

```text
specs/037-second-brain-rag/
├── spec.md                 # especificación (clarify integrado)
├── plan.md                 # este archivo
├── research.md             # Fase 0: decisiones + mediciones + riesgos
├── data-model.md           # Fase 1: frontmatter, hallazgos, artefactos, config
├── quickstart.md           # Fase 1: gates, escenarios, mutación, despliegue
├── contracts/
│   ├── vault-schema-delta-0.27.0.md   # prosa del schema, delta, CANON-D*
│   ├── graph-findings-extension.md    # runner: columnas, aristas, hallazgos, packets, policy, CANON-F
│   ├── qmd-collection-migration.md    # alcance wiki/, sentinel, migración automática, seam
│   ├── heartbeat-review-notice.md     # octava línea de crontab, prompt, CANON-H
│   └── agent-yml-config-037.md        # seis claves, backfill, saneo, touchpoints
├── discovery/              # A-L + digest de Forte (recuperados del scratchpad; ver memoria)
├── checklists/requirements.md
└── tasks.md                # /speckit-tasks (no creado por /speckit-plan)
```

### Source Code (repository root)

```text
scripts/lib/
├── wiki_graph.sh            # columnas PARA, aristas, 8 kinds nuevos, packets.json, policy.json, TODAY
├── vault.sh                 # bloque 0.27.0 con flag propio + marcador con fecha
└── qmd_index.sh             # máscara wiki/**/*.md, sentinel de layout, qmd_migrate_collection, state
modules/
├── vault-skeleton/CLAUDE.md, index.md, log.md, _templates/{entity-project,overview-area,summary,…}.md
├── vault-deltas/schema-updates-0.27.0.md
├── claude-md.tpl            # ruteo de estado de proyecto, findings nuevos, aviso docker / nada en local
├── local-qmd-reindex.sh.tpl # --migrate [--dry-run]
docker/scripts/heartbeatctl  # cmd_reload (línea 8, review-prompt.txt, _v_cron5), cmd_qmd_migrate, cmd_status
scripts/agentctl             # status/doctor local (counts nuevos, layout), heartbeat qmd-migrate
setup.sh                     # heredocs, backfills has(), saneo *_days, heartbeat_review_prompt_default
scripts/lib/schema.sh        # boolean + nonempty nuevos
docs/{vault,heartbeatctl,state-layout,qmd-upgrade-checklist}.md, README.md, CHANGELOG.md, VERSION
tests/
├── fixtures/vault-graph/ (intacta) + vault-graph.findings.golden.json
├── fixtures/vault-graph-para/ (nueva), fixtures/vault-0.8.0-{empty,pages}/ (nuevas)
├── fixtures/sample-agent{,-with-vault}.yml
├── wiki-graph.bats, vault.bats, vault-upgrade.bats, qmd-setup.bats, qmd-index.bats, qmd-reindex-cmd.bats,
│   heartbeatctl.bats, heartbeat-runs-jsonl.bats, agentctl-local.bats, schema.bats, schema-validate.bats,
│   regenerate.bats, docker-render.bats, local-render.bats, local-qmd.bats, helper.bash (stub qmd)
├── vault-review-config.bats (nuevo)
└── docker-e2e-qmd.bats (Tier-1 des-diferido + migración), docker-e2e-heartbeat.bats (+1), docker-e2e-vault.bats (+delta)
```

**Structure Decision**: sin archivo de código nuevo salvo fixtures, un bats nuevo y el delta; toda la
lógica entra en las tres libs canónicas de `scripts/lib/` (espejadas al `docker/` del workspace por
`mirror_catalog_to_docker`, `setup.sh:1629-1690`), en `heartbeatctl` (image-baked por COPY) y en
`agentctl`. No se crea nada bajo `docker/scripts/lib/` del repo (K §8).

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

Sin entradas.

## Phase 0 — Outline & Research

Hecha; salida en [research.md](research.md). Incógnitas de la spec resueltas o dispuestas: Q1/Q9/Q13
medidas contra el binario 2.5.3 (discovery L), Q8 y la aritmética de fechas medidas en la imagen Alpine y el
host, Q7 y Q11 por lectura verificada (discovery K), Q3/Q12 vueltas irrelevantes por diseño, Q2/Q4/Q5/Q6/
Q10/Q14/Q15/Q16 bloqueadas por acceso a la flota y trasladadas al gate de despliegue con protocolo en
`quickstart.md`. Ninguna deja una incógnita sin disposición en el diseño; las decisiones del operador (dos
rondas previas, una de clarify, una de plan) están en `spec.md` Clarifications y en `research.md` §1.

Agent context: el hook `after_plan` (`speckit.agent-context.update`) **no se ejecuta** en este repo: su
script reemplaza todo el bloque `<!-- SPECKIT START/END -->` del `CLAUDE.md` por tres líneas, y en este
repo ese bloque contiene ~1.100 líneas de historia de features (034 a 016). El contexto de agente para 037
se agrega a mano en Polish, como en 028-036 (memoria `speckit-agent-context-hook-wipes-claude-md`).

## Phase 1 — Design & Contracts

Hecha; salida en [data-model.md](data-model.md) y [contracts/](contracts/). Puntos de diseño que fijan las
tareas:

1. **Runner** (`contracts/graph-findings-extension.md`): trece columnas nuevas en orden canónico en `N` y en
   jq; aristas `related` desde `project`/`area`/`problems`; violaciones CANON-F1..F6 en awk; ocho kinds
   nuevos en jq con `strptime`/`mktime` y `$today`; supresión `orphan`/`stale` para archive; enumeraciones
   nuevas de `raw_sources/` y `log.md`; `packets.json` y `policy.json`; counts con default en el path de
   error. Fixture 014 intacta + golden; fixture nueva con fechas remotas.
2. **Upgrade** (`contracts/vault-schema-delta-0.27.0.md`): bloque 0.27.0 con flag propio tras el check
   0.8.0; marcador `deposited: <fecha>`; delta en inglés con CANON-D1..D15; cada sección del delta verbatim
   en el skeleton; sin página semilla; `log.md` con la línea de formato ampliada; nota de migración de
   `project_*` solo en el delta; `claude-md.tpl` con la fila de ruteo.
3. **qmd** (`contracts/qmd-collection-migration.md`): máscara `wiki/**/*.md` sobre la raíz; sentinel
   `.qmd-collection-wiki` escrito solo tras un `collection add` exitoso; `qmd_collection_migration_state`
   (`n/a`/`pending`/`done`, calculado en vivo por `status`); `qmd_migrate_collection` (remove → add →
   update → sentinel → cleanup → embed solo si Pending; fallo a mitad → `error`, hash intacto, `pending`)
   invocada por `_qmd_reindex_locked` cuando `pending`, y por `qmd-migrate [--dry-run|--force]` en ambos
   modos (sin flags idempotente); state con `collection_layout`/`migration`; stub del seam extendido.
4. **Heartbeat** (`contracts/heartbeat-review-notice.md`): `cmd_reload` lee tres claves, valida con
   `_v_cron5`, escribe `review-prompt.txt` (default por idioma con CANON-H1/H2, `{{VAULT_DIR}}`
   sustituido), emite la octava línea con `--trigger review --prompt "$(cat …)"`; byte-idéntico con
   `enabled: false`; `heartbeat.sh` intacto; local sin nada.
5. **Config** (`contracts/agent-yml-config-037.md`): seis claves, backfills `has()`, saneo de enteros,
   `schema.sh`, fixtures, `schema.bats:43`, docs con las cuatro claves reservadas.
6. **Observabilidad**: `heartbeatctl status` gana wiki-graph y qmd; `agentctl` local suma counts y layout;
   `doctor` sin cambio de exit.

Orden de fases para tasks (dependencias reales, no prioridad): Setup (fixtures, golden, baseline dual) →
Foundational (schema del vault + plantillas + delta + `vault.sh`, porque todo lo demás valida contra ese
texto; luego runner: columnas + aristas + violaciones; luego config `agent.yml`) → US2 higiene qmd (antes
que cualquier regla que escriba en `log.md`, FR-011) → US1/US3 hallazgos de la cola → US4/US5/US6 (`description`,
`packets.json`, favorite problems) → US7 (`schema_delta_pending`, backfills, docs) → US8 (`archive_candidate`)
→ US9 (heartbeat + status) → Polish (README/CHANGELOG/VERSION/CLAUDE.md, DOCKER_E2E real, mutación, gates
duales, gate de hardware).

Agent context: ver la nota de Phase 0 (el hook no se ejecuta; el bloque SPECKIT se actualiza a mano).
