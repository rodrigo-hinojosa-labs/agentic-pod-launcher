# Implementation Plan: Wiki-grafo RAG agéntico — grafo derivado, normalización y mantenimiento determinista

**Branch**: `014-wiki-graph-rag` | **Date**: 2026-07-06 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/014-wiki-graph-rag/spec.md`

## Summary

Derivar determinísticamente un grafo de conocimiento de toda la base `wiki/` del vault
(nodos = páginas tipadas; aristas = wikilinks + `related:` + `sources:` + alias→canonical),
materializado bajo `<vault>/.graph/` como JSON regenerable; agregar la capa
`wiki/normalization/` (canonical+aliases, ej. SENCOSUD→Cencosud) consumida por el ingest
agéntico y vigilada por el linter; y automatizar el mantenimiento (grafo + lint estructural
sin LLM) con la misma semántica en docker (línea de crontab staged por `heartbeatctl`) y
local (wrapper+unit+timer systemd con las lecciones de 013 desde el día 1). Vaults
existentes reciben la estructura vía upgrade aditivo no destructivo (`vault_seed_missing`)
con el delta de schema entregado como documento aparte + entrada en `log.md`.

Enfoque técnico: lib bash espejada `scripts/lib/wiki_graph.sh` — awk hace la extracción
por archivo (frontmatter de subset restringido + wikilinks fuera de fences), jq hace la
agregación global y el ensamblado JSON atómico. El parser estricto ES el validador: lo que
no parsea se reporta como `frontmatter_violation` (FR-004). Sin dependencias nuevas.

## Technical Context

**Language/Version**: Bash compatible 3.2 (host macOS para bats) / bash de Alpine y Debian
en runtime; awk POSIX (BSD y GNU); jq 1.x; yq v4 (gating de `agent.yml`).

**Primary Dependencies**: awk + jq + yq — TODAS ya presentes en los tres contextos
(imagen: `docker/Dockerfile:36-37`; host: deps de tests; local: mismas del host +
`scripts/vendor/bin`). flock solo en Linux (runtime); tests host lo skipean (precedente
013 `qmd-setup.bats`). Cero dependencias nuevas.

**Storage**: artefactos derivados en `<vault>/.graph/{graph.json,backlinks.json,findings.json}`
(tmp+mv atómico); state file `<ws>/scripts/heartbeat/wiki-graph.json`; lock FUERA del vault
en `<ws>/scripts/heartbeat/.wiki-graph.lock` (Syncthing no debe ver locks).

**Testing**: bats host-first (fixtures de vault con hallazgos conocidos); stubs systemd ya
establecidos (`tests/local-*.bats`); DOCKER_E2E obligatorio (lib nueva en imagen + línea de
crontab staged = cambio de comportamiento docker real).

**Target Platform**: contenedor Alpine (docker mode) y Linux systemd (local mode, RPi5
arm64 objetivo); host macOS/Linux para scaffold y tests.

**Project Type**: launcher bash de 3 rutas de código (host / imagen / workspace-templated).

**Performance Goals**: SC-006 — 1.000 páginas < 60 s en RPi5. Diseño: awk por lotes (solo
extracción per-file, sin estado global en awk) + una agregación jq; estimado en segundos.

**Constraints**: docker cambia SOLO por adición (lib espejada + subcommand heartbeatctl +
línea de crontab staged + seed_missing en boot); el runner JAMÁS edita la wiki; fail-silent
exit 0 en entrypoints batch con honestidad en doctor (Principle IV); bash 3.2 en código
host-testeable (sin arrays asociativos — la agregación vive en awk/jq).

**Scale/Scope**: wikis de 0 a ~1.000 páginas; 1 agente por host (local v1); multi-agente
preparado solo vía aislamiento ya existente de 013.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*
*Source: `.specify/memory/constitution.md` (v1.0.0).*

- [x] **I. Single Source of Truth** — PASS. `vault.wiki_graph.{enabled,schedule}` nace en
  `agent.yml`; `scripts/lib/schema.sh` SOLO valida su forma (add a `_SCHEMA_BOOLEANS` /
  `_SCHEMA_OPTIONAL_NONEMPTY`, patrón `.vault.qmd.*`), y los defaults reales (`enabled`
  condicionado a `vault.enabled`, `schedule: 20 */6 * * *`) se aplican en el precompute de
  `setup.sh` (D12) y en los fallbacks yq `//` de los sitios de consumo. Todo derivado
  (wrapper/unit/timer locales, línea de crontab staged, NEXT_STEPS) se re-renderiza con
  `--regenerate`; los artefactos `.graph/` y el state file son runtime-derivados (no
  rendered files) y siempre regenerables desde la wiki.
- [x] **II. Least-Privilege (NON-NEGOTIABLE)** — PASS. Cero capabilities/mounts/sockets
  nuevos; la línea de crontab viaja por el staging root-sync existente; el runner corre
  como `agent`/operador; acciones manuales sin systemctl ni polkit (exec directo).
- [x] **III. Test-First, Host-Runnable** — PASS. Suite bats nueva host-first con fixtures;
  flock/timers gated o stubbeados; DOCKER_E2E para la superficie de imagen; shellcheck
  `-S error`; `wiki_graph.sh` con guard `BASH_SOURCE` sin side effects al source.
- [x] **IV. Idempotent, Fail-Silent Lifecycle** — PASS. Runner re-ejecutable (lock +
  tmp+mv); `vault_seed_missing` idempotente con sentinel = marcador OCULTO
  `_templates/.schema-updates-0.8.0.applied` que el agente no toca (NO la existencia del
  delta `.md` borrable — C1); entrypoints batch exit 0 con error en state file; nada puede
  tumbar supervisor ni sesión.
- [x] **V. Workspace-Is-the-Agent** — PASS. Todo bajo `<ws>` (vault en `.state/.vault` por
  default); `.graph/` queda fuera del backup por el filtro `*.md` existente
  (`backup_vault.sh:93`) — cero cambios a los 3 primitivos de backup; nada nuevo se
  commitea ni loguea con secretos.
- [x] **VI. Reproducible, Pinned Dependencies** — PASS. Sin deps ni pins nuevos; VERSION
  0.7.0 → 0.8.0 + CHANGELOG (superficie nueva en ambos modos).

**Post-design re-check (Phase 1)**: sin cambios — PASS en los 6. Complexity Tracking: sin
violaciones que justificar.

## Decisiones de diseño

- **D1 — Lenguaje del runner: bash + awk (extracción) + jq (agregación).** awk corre por
  lotes SOLO extrayendo registros per-file (nodos, aristas candidatas, violaciones) en TSV;
  jq agrega globalmente (backlinks, huérfanos = nodos sin arista entrante, drift) y emite
  los JSON. Esto permite `xargs` por lotes sin perder agregación global y mantiene bash 3.2.
  El parser de frontmatter acepta el subset restringido del skeleton (claves planas +
  arrays de flujo `[a, b]` + arrays de guiones); lo no parseable = `frontmatter_violation`.
  Rechazado: bun/JS (parsing YAML robusto pero dependencia nueva de tests host y ruptura
  del estilo de libs espejadas).
- **D2 — Lib espejada**: `scripts/lib/wiki_graph.sh` + línea en
  `setup.sh::mirror_catalog_to_docker` (patrón `qmd_index.sh`, setup.sh:1488-1511) + línea
  `COPY` explícita en `docker/Dockerfile` (la copia wholesale no basta — gotcha
  documentada). Funciones: `wiki_graph_enabled`, `wiki_graph_vault_dir` (override
  `WIKI_GRAPH_VAULT_DIR` para tests, `VAULT_ROOT_OVERRIDE` para local), `wiki_graph_run`.
- **D3 — Artefactos y estado**: `.graph/graph.json` (nodos+aristas), `.graph/backlinks.json`
  (mapa por página: backlinks, related salientes, co-citadores de fuente, canonical de
  alias), `.graph/findings.json` (hallazgos tipados). SOLO extensiones no-`.md` (contrato:
  el filtro del backup y la mask de qmd no deben verlos jamás). State file
  `wiki-graph.json` schema 1 con `last_run`, `last_status` (`ok|error` — el perdedor del
  flock NO escribe state, no existe estado `locked`), `duration_ms`, `error`,
  `counts{nodes,edges,orphans,broken_links,frontmatter_violations,index_drift,stale,
  alias_occurrences}`. El fallback de schedule NO es campo del state file: es un archivo
  marcador aparte `wiki-graph-schedule.fallback` (única fuente, leída por status/doctor).
- **D4 — Config**: `vault.wiki_graph.enabled` (default `true` si `vault.enabled`),
  `vault.wiki_graph.schedule` (default `20 */6 * * *` — offset :20 para no chocar con
  vault-backup :00 ni identity/config 03:30). SIN prompt nuevo de wizard (default sano,
  editable en `agent.yml`). Al ser render vars SIN prompt nuevo, el ÚNICO touchpoint de
  tests es `known_external` en `schema.bats` (ambos arrays, :62 y :114) — `wizard_answers`
  y el array posicional de `e2e-smoke.bats` son respuestas a prompts del wizard y NO se
  tocan (aplican solo cuando se agrega un prompt, no un `{{VAR}}` de render).
- **D5 — Docker scheduling**: `heartbeatctl` gana subcommand `wiki-graph` y agrega la
  línea al `.crontab.staging` (patrón exacto de `qmd_reindex_line`,
  `docker/scripts/heartbeatctl:265-272`) — NO se toca `crontab.tpl` (solo heartbeat vive
  ahí). El sync-loop root existente la publica.
- **D6 — Local scheduling**: `modules/local-wiki-graph.{sh,service,timer}.tpl` — wrapper
  con PATH auto-provisto PRIMERO, `VAULT_ROOT_OVERRIDE`/`WIKI_GRAPH_VAULT_DIR` explícitos,
  `local_schedule.sh::cron_to_systemd_calendar` (+ marker `wiki-graph-schedule.fallback`
  reutilizando el mecanismo CRON_FALLBACK de 013). Unit `agent-<name>-wiki-graph.service`
  + `.timer`, instalación en `--login` y staged en scaffold (mismo flujo 012/013).
- **D7 — Normalización**: `wiki/normalization/` + `_templates/normalization.md`.
  Frontmatter propio: `canonical` (req), `aliases` (req, no vacío), `match_case` (opt,
  default false), `entity` (opt, wikilink), `notes` (opt). El linter valida estas páginas
  contra ESTE spec (no contra el de los 6 types — decisión clarify Q1). Escaneo de alias:
  word-boundary, case-insensitive por default, fuera de fenced code, excluyendo las
  propias páginas de normalización.
- **D8 — Grafo y parsing**: wikilinks `[[target]]`, `[[target|display]]`,
  `[[target#anchor]]`, `[[target#anchor|display]]` — resolución al archivo
  `wiki/<target>.md` (el anchor no cuenta para resolución); fenced code blocks (```)
  excluidos del escaneo de links y aliases; `related:`/`sources:` del frontmatter como
  aristas tipadas; `sources:` además valida existencia del archivo fuente.
  **Normalización de valores de frontmatter** (H4): antes de resolver, cada elemento de
  array se despoja de comillas envolventes (`"…"`/`'…'`); en `related:` se desenvuelve el
  wikilink embebido (`"[[concepts/x]]"` → `concepts/x`); en `sources:` se conserva el path
  con `.md`. Sin este paso, el skeleton real (`related: ["[[concepts/x]]"]`) generaría
  broken_links espurios. **Huérfano** (H2) = página sin NINGUNA arista entrante `wikilink`
  o `related`; `related:` entrante cuenta SIEMPRE (no exige reciprocidad; coincide con
  `backlinks.json`). `index.md`/`log.md` no son nodos pero `index.md` se valida contra el
  filesystem (drift bidireccional). **Extracción de entradas de `index.md`** (H3): una
  entrada es un bullet `- [[type/slug]] …` a nivel de lista; se EXCLUYEN los comentarios
  HTML `<!-- … -->`, el texto entre backticks y los placeholders `<…>` — así el `index.md`
  limpio del skeleton (que trae `[[…]]` de ejemplo en prosa/comentarios) da 0
  `index_drift`. **Stale** (informativo, L4): SOLO páginas `status: active` cuyo archivo de
  `sources:` tenga fecha posterior a `updated:` + 1 día (el guard `status: active` es
  intencional; draft/superseded no reportan stale).
- **D9 — Superficie operacional**: local — `agentctl heartbeat wiki-graph` (exec directo,
  caso nuevo en `cmd_local_heartbeat`), bloque nuevo en `_local_vault_qmd_status` (frescura
  + counts) y checks en `_local_vault_qmd_doctor` con el contrato Q5 (WARN integridad /
  FAIL runner muerto: state ausente o `last_run` > 2× intervalo, fallback 24 h si el
  schedule no es parseable); healthcheck local WARN si la unit está failed; kill-switch
  `AUX_UNITS += agent-<name>-wiki-graph.timer`. Docker — `heartbeatctl wiki-graph` +
  proxy `agentctl heartbeat wiki-graph` ya genérico; status/doctor docker para RAG sigue
  en backlog 013 (no se amplía aquí).
- **D10 — Skeleton (scaffolds nuevos)**: `modules/vault-skeleton/` gana
  `wiki/normalization/.gitkeep`, `_templates/normalization.md`, sección en `index.md`, y
  el `CLAUDE.md` del skeleton gana: descripción de la capa de normalización, paso de
  ingest "2.5 Normalize" (consultar `wiki/normalization/` antes de escribir capa 2; capa 1
  VERBATIM), paso de query "vecinos a 1 salto vía `.graph/backlinks.json`", y nota de que
  el lint estructural ya corre determinístico (el lint agéntico se concentra en
  contradicciones semánticas).
- **D11 — Upgrade aditivo (vaults existentes)**: `vault_seed_missing TARGET SKELETON
  DELTAS_DIR [TODAY]` en `scripts/lib/vault.sh` (espejada — COPY ya existe): crea SOLO
  dirs/archivos faltantes (`wiki/normalization/`, `_templates/normalization.md`); NUNCA
  sobreescribe; NO toca `CLAUDE.md`; deposita `_templates/schema-updates-0.8.0.md` desde
  `modules/vault-deltas/` (NUEVO dir, fuera del skeleton para que los scaffolds frescos no
  lo hereden como ruido) + entrada `log.md` `## [fecha] upgrade | schema updates 0.8.0 …`.
  **Idempotencia (C1)**: el sentinel es un marcador OCULTO que el agente no toca —
  `_templates/.schema-updates-0.8.0.applied` (touch al depositar) — NO la existencia del
  delta `.md`, que el agente puede borrar tras integrarlo. Con el sentinel desacoplado, el
  boot docker (que corre en cada arranque) no re-deposita ni duplica la entrada de
  `log.md`. Triggers (H5): boot docker en `start_services.sh::seed_vault_if_needed` (tras
  la rama `vault_seed_if_empty`, contexto usuario `agent`, `vault.sh` ya source-ado) —
  NO en `entrypoint.sh` (que solo corre como root y no toca el vault); `--login` local;
  `--regenerate` host.
- **D12 — Render**: variables nuevas precomputadas en `setup.sh` (patrón VAULT_MCP_PATH;
  el engine no soporta `{{#if}}` anidado): `WIKI_GRAPH_ENABLED`, `WIKI_GRAPH_SCHEDULE`,
  `LOCAL_VAULT_DIR` ya existe. NEXT_STEPS con bloques hermanos (no anidados).
- **D13 — Locking**: flock sobre `<ws>/scripts/heartbeat/.wiki-graph.lock`; el perdedor
  sale 91 y NO escribe state (no existe estado `locked` — el ganador es la única corrida
  que actualiza `wiki-graph.json`); patrón `qmd_setup_if_needed` 013; lock y tmp JAMÁS
  dentro del vault (Syncthing).
- **D14 — Doctor freshness (M6)**: intervalo esperado derivado del schedule leyendo el
  campo HORA — `*/N` en el campo hora → N horas AUNQUE el minuto sea fijo (el default
  `20 */6 * * *` → 6 h); lista de horas `0,6,12,18` → menor gap (6 h); `*/N` solo en el
  campo minuto → N minutos; cualquier otra forma no reconocida → 24 h. FAIL a 2× intervalo
  (default: 12 h). Test unitario del parser sobre `20 */6 * * *` esperando 6 h.
- **D15 — Docs**: `docs/vault.md` (capa normalización + .graph + protocolos),
  `docs/architecture.md` (párrafo 014), `docs/heartbeatctl.md` (subcommand), CHANGELOG,
  VERSION 0.8.0.
- **D16 — Fuera de e2e smoke**: el e2e nuevo extiende `docker-e2e-qmd.bats` (mismo boot)
  con fase wiki-graph en lugar de un archivo nuevo — evita otro boot completo de imagen.

## Project Structure

### Documentation (this feature)

```text
specs/014-wiki-graph-rag/
├── spec.md
├── plan.md              # este archivo
├── research.md          # Phase 0
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1 (gates)
├── contracts/
│   ├── graph-artifacts.md
│   ├── normalization-pages.md
│   ├── mode-parity-ops.md
│   └── vault-additive-upgrade.md
├── checklists/requirements.md
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
scripts/lib/wiki_graph.sh                 # NUEVA lib espejada (runner completo)
scripts/lib/vault.sh                      # + vault_seed_missing
scripts/lib/schema.sh                     # defaults vault.wiki_graph.*
scripts/agentctl                          # status/doctor/heartbeat wiki-graph (local)
setup.sh                                  # mirror línea, render vars, units staged,
                                          #   seed_missing en --regenerate, marker fallback
docker/Dockerfile                         # + COPY wiki_graph.sh + COPY modules/vault-deltas/
docker/scripts/start_services.sh          # + vault_seed_missing en seed_vault_if_needed (H5)
docker/scripts/heartbeatctl               # + subcommand wiki-graph + staging cron line
modules/local-wiki-graph.sh.tpl           # NUEVO wrapper (PATH + env vault + lib)
modules/local-wiki-graph.service.tpl      # NUEVA unit
modules/local-wiki-graph.timer.tpl        # NUEVO timer
modules/local-killswitch.sh.tpl           # AUX_UNITS += wiki-graph.timer
modules/local-healthcheck.sh.tpl          # WARN unit failed
modules/local-login.sh.tpl                # instala units nuevas + seed_missing
modules/next-steps.en.tpl / .es.tpl       # bloques de operación wiki-graph
modules/vault-skeleton/CLAUDE.md          # schema: normalización + query grafo + lint det.
modules/vault-skeleton/index.md           # sección Normalization
modules/vault-skeleton/wiki/normalization/.gitkeep
modules/vault-skeleton/_templates/normalization.md
modules/vault-deltas/schema-updates-0.8.0.md   # NUEVO dir (delta para vaults existentes)

tests/wiki-graph.bats                     # NUEVO: parser/grafo/hallazgos sobre fixtures
tests/vault-upgrade.bats                  # NUEVO: vault_seed_missing (poblado/idempotente)
tests/local-wiki-graph.bats               # NUEVO: render wrapper/unit/timer + env + PATH
tests/agentctl-local.bats                 # doctor/status/heartbeat wiki-graph
tests/local-killswitch.bats               # timer nuevo en AUX_UNITS
tests/local-healthcheck.bats              # WARN unit failed
tests/schema.bats                         # known_external + defaults nuevos
tests/docker-render.bats                  # drift-guard COPY wiki_graph.sh
tests/docker-e2e-qmd.bats                 # fase wiki-graph (DOCKER_E2E)
tests/fixtures/vault-graph/               # NUEVO fixture con hallazgos conocidos

VERSION (0.8.0) · CHANGELOG.md · docs/{vault,architecture,heartbeatctl}.md
```

**Structure Decision**: se mantienen las tres rutas de código del launcher; la lógica vive
en UNA lib espejada (paridad por construcción, mismo criterio 012/013); los modos difieren
solo en transporte de scheduling (crontab staged vs timer systemd) y en superficie de
operación ya existente.

## Complexity Tracking

Sin violaciones constitucionales que justificar. Nota de alcance: el runner agrega
comportamiento docker real (lib en imagen + cron staged + seed_missing en boot) — cubierto
por el gate DOCKER_E2E obligatorio, no es excepción sino superficie nueva planificada.
