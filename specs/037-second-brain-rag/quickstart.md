# Quickstart — 037 Second Brain sobre el LLM Wiki: gates, escenarios, mutación y despliegue

**Branch**: `037-second-brain-rag` | **Date**: 2026-09-27 | **Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

Todo comando se corre desde la raíz del repo salvo indicación. Ningún paso imprime contenido de vaults ni
secretos; los conteos de flota van por `docker exec -u agent` o `ssh` con `wc`/`grep -c`.

## 1. Gates de host (obligatorios antes del PR)

```bash
# suite completa, ambos bash (precedente 025-036)
bats tests/ > /tmp/037-bash5.txt 2>&1; grep -c '^ok ' /tmp/037-bash5.txt; grep -c '^not ok ' /tmp/037-bash5.txt
PATH=/bin:$PATH bats tests/ > /tmp/037-bash3.txt 2>&1; grep -c '^ok ' /tmp/037-bash3.txt; grep -c '^not ok ' /tmp/037-bash3.txt
# shellcheck (comando exacto de CI)
shellcheck -S error setup.sh scripts/lib/*.sh scripts/agentctl scripts/heartbeat/*.sh docker/scripts/heartbeatctl docker/scripts/*.sh
# bytes: cero marcas combinantes en skeleton, delta, patcher, setup y bats
LC_ALL=C grep -rc $'\xcc\x80' modules/vault-skeleton modules/vault-deltas setup.sh docker/scripts/heartbeatctl tests/*.bats | grep -v ':0$' || echo clean
# docker byte-idéntico fuera de las libs/heartbeatctl/crontab
git diff --stat main -- docker/ | grep -v heartbeatctl || true     # debe quedar vacío: docker/crontab.tpl intacto
```

Línea base: capturar `bats tests/` en ambos bash sobre `main` antes de la primera tarea (T00x) y anotar
los conteos en `tasks.md` (hoy 1502 `@test` estáticos; el número dinámico se mide).

Archivos bats que 037 toca o crea (correr en aislamiento durante el desarrollo):

```bash
bats tests/wiki-graph.bats tests/vault.bats tests/vault-upgrade.bats tests/qmd-setup.bats tests/qmd-index.bats \
     tests/qmd-reindex-cmd.bats tests/heartbeatctl.bats tests/heartbeat-runs-jsonl.bats tests/agentctl-local.bats \
     tests/schema.bats tests/schema-validate.bats tests/regenerate.bats tests/docker-render.bats tests/local-render.bats \
     tests/local-qmd.bats tests/vault-review-config.bats
```

## 2. Escenarios ejecutables en host (sin Docker)

### 2.1 Runner sobre la fixture 014 (no regresión)

```bash
source tests/helper.bash; load_lib wiki_graph; load_lib vault
# sin agent.yml, wiki_graph_run resuelve /workspace/agent.yml (ausente en host) y sale "disabled — skip"
ay=$(mktemp); printf 'vault: {enabled: true, wiki_graph: {enabled: true}}\n' > "$ay"
WIKI_GRAPH_VAULT_DIR=tests/fixtures/vault-graph WIKI_GRAPH_STATE_FILE=/tmp/wg.json WIKI_GRAPH_TODAY=2030-06-15 wiki_graph_run "$ay"
jq -S .findings tests/fixtures/vault-graph/.graph/findings.json | diff - <(jq -S .findings tests/fixtures/vault-graph.findings.golden.json) && echo IDENTICAL
jq '.counts' /tmp/wg.json    # los 8 counts de 014 iguales; los 12 nuevos en 0
```

### 2.2 Runner sobre la fixture nueva (kinds nuevos)

```bash
WIKI_GRAPH_VAULT_DIR=tests/fixtures/vault-graph-para WIKI_GRAPH_STATE_FILE=/tmp/wg2.json WIKI_GRAPH_TODAY=2030-06-15 wiki_graph_run "$ay"
jq -r '.findings[] | "\(.kind)\t\(.page)\t\(.detail)"' tests/fixtures/vault-graph-para/.graph/findings.json | sort
# comparar con tests/fixtures/vault-graph-para/README.md (conteo exacto por kind)
jq '.packets | length' tests/fixtures/vault-graph-para/.graph/packets.json     # packets esperados
jq . tests/fixtures/vault-graph-para/.graph/policy.json                          # 7/30/90/14/30/300 y collection
ls tests/fixtures/vault-graph-para/.graph/ | grep -c '\.md$'                     # 0 (L1 de 014)
```

Determinismo: repetir con el mismo `WIKI_GRAPH_TODAY` → `diff` vacío de `findings.json`. Cambiar
`WIKI_GRAPH_TODAY=2030-01-01` → `review_due`/`project_overdue`/`archive_candidate`/`schema_delta_pending` en 0.

### 2.3 Skeleton limpio sigue en 0

```bash
d=$(mktemp -d); vault_seed_if_empty "$d" modules/vault-skeleton 2030-06-01   # copia el skeleton y sustituye SCAFFOLD_DATE (portable; sed -i '' es solo BSD)
WIKI_GRAPH_VAULT_DIR="$d" WIKI_GRAPH_STATE_FILE=/tmp/wg3.json WIKI_GRAPH_TODAY=2030-06-15 wiki_graph_run "$ay"; jq '.counts' /tmp/wg3.json
```

Todos los counts salvo `nodes`/`edges` en 0 (sin página semilla). El skeleton sembrado trae el marcador 0.27.0
fechado por la siembra y su `CLAUDE.md` ya integra CANON-D1, así que `schema_delta_pending` es 0 por
construcción; `cat "$d/_templates/.schema-updates-0.27.0.applied"` → `deposited: 2030-06-01`.

### 2.4 Upgrade aditivo en los tres estados

```bash
for f in vault-populated vault-0.8.0-empty vault-0.8.0-pages; do
  d=$(mktemp -d); cp -R "tests/fixtures/$f/." "$d"; (cd "$d" && find . -type f -exec shasum -a 256 {} + | sort > /tmp/before.$f)
  vault_seed_missing "$d" modules/vault-skeleton modules/vault-deltas 2030-06-15
  (cd "$d" && find . -type f -exec shasum -a 256 {} + | sort > /tmp/after.$f)
  comm -23 /tmp/before.$f /tmp/after.$f      # vacío = 0 preexistentes modificados
  cat "$d/_templates/.schema-updates-0.27.0.applied"   # deposited: 2030-06-15
  grep -c 'schema delta 0.27.0 deposited' "$d/log.md"  # 1
  vault_seed_missing "$d" modules/vault-skeleton modules/vault-deltas 2030-06-16; grep -c 'schema delta 0.27.0 deposited' "$d/log.md"  # sigue 1
  ls "$d/_templates/" | grep -c 'schema-updates-0.8.0.md'   # 1 en vault-populated y en 0.8.0-pages; 0 en 0.8.0-empty (sin marcador: el guard fresh-scaffold no debe dispararse)
done
# (requiere `load_lib vault` de §2.1)
```

### 2.5 Delta verbatim en el skeleton

```bash
awk '/^## /{h=$0} h && !/^## /{print h"\t"$0}' modules/vault-deltas/schema-updates-0.27.0.md > /tmp/delta.tsv
for h in '## Actionability (PARA)' '## Operation: project kickoff' '## Operation: project close' '## Operation: weekly review' '## Operation: monthly review' '## Filing policy' '## Session close (Hemingway Bridge)' '## Intermediate packets' '## Favorite problems'; do
  grep -c -F -- "$h" modules/vault-skeleton/CLAUDE.md   # 1 cada uno
done
grep -c -F -- '## Migration: project_* memory files' modules/vault-skeleton/CLAUDE.md   # 0 (solo delta)
```

### 2.6 Migración de colección con el stub (seam A)

```bash
# en un test: install_qmd_stub; pre-sembrar index.sqlite sin sentinel; correr _qmd_reindex_locked
grep -n 'collection' "$QMD_STUB_LOG"   # remove vault ; add <vault> --name vault --mask 'wiki/**/*.md'
grep -n 'cleanup' "$QMD_STUB_LOG"      # después de 'add' y de 'update'
cat "$QMD_CACHE_HOME/.qmd-collection-wiki"   # wiki-root 2030-06-15  (los setups exportan QMD_CACHE_HOME, no XDG_CACHE_HOME)
jq '.collection_layout, .migration' scripts/heartbeat/qmd-index.json   # "wiki-root" "done"
```

### 2.7 Aviso semanal (render de crontab)

```bash
# heartbeatctl.bats: con review.enabled=false el crontab es byte-idéntico al golden v0.26.0
# con enabled=true, schedule "7 9 * * 1":
grep -F -c -- '--trigger review --prompt "$(cat /workspace/scripts/heartbeat/review-prompt.txt)"' "$CRONTAB_OUT"   # 1 (grep -F: el patrón lleva $ y paréntesis)
grep -c 'sin pendientes' scripts/heartbeat/review-prompt.txt     # 1 (agente es/mixed); 'nothing pending' en en
# schedule inválido "9 * *": línea ausente, WARN presente, 7 líneas restantes intactas
```

### 2.8 Config

```bash
# vault-review-config.bats: _write_agent_yml value|OMIT|NULL para project_days/area_days/candidate_days
./setup.sh --regenerate --destination "$WS" 2>&1 | grep 'WARN' | grep -c 'vault.review.project_days'   # 1 con valor inválido, sin imprimir el valor
yq '.vault.review, .vault.archive, .features.heartbeat.review' "$WS/agent.yml"   # defaults tras backfill
./setup.sh --regenerate --destination "$WS"; git -C "$WS" status --short   # byte-idéntico
```

## 3. DOCKER_E2E (se corre de verdad en este host; imagen `agentic-pod:latest`)

```bash
DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats        # Tier-1 des-diferido: collection add con --mask wiki/**/*.md; migración desde colección heredada pre-sembrada: qmd ls vault solo wiki/, embed idempotente, status sin Pending; Fase 4.5 wiki-graph con la fixture nueva copiada al vault del contenedor: mismos conteos que en host
DOCKER_E2E=1 bats tests/docker-e2e-vault.bats      # scaffold fresco: marcador 0.27.0 fechado por la siembra, SIN delta ni línea CANON-D14; vault pre-037 pre-sembrado en .state/.vault: delta + marcador fechado y una sola línea CANON-D14 tras restart
DOCKER_E2E=1 bats tests/docker-e2e-heartbeat.bats  # review.enabled=true → exactamente una línea con --trigger review en /etc/crontabs/agent tras el sync loop; false → 0 (contar con grep -c, no wc -l)
```

Gotchas heredados (033/034): `docker compose run` antepone líneas de progreso a `$output` (usar marcadores
nombrados), `grep -c` sale 1 con conteo 0 bajo `set -e`, el arnés pre-crea `.state/` y declara `plugins: []`.

## 4. Mutación (una por fix, precedente 028-036)

| M | Mutación | Test que debe caer |
|---|---|---|
| M1 | Quitar la rama `else if (key == "para")` del awk | fixture nueva: `para: invalid` y `para_project` en 0 |
| M2 | Invertir el orden de dos columnas nuevas en `N` sin tocar jq | golden 014: `type`/`status` corruptos → findings distintos |
| M3 | Quitar `select(.para!="archive")` de `$f_orphan` | archive orphan aparece |
| M4 | Quitar la columna `para` de `SRCN` | archive stale aparece |
| M5 | Emitir las aristas de `project` con kind `wikilink` en vez de `related` | backlinks iguales pero `graph.json` edges kind cambia → test de aristas |
| M6 | Usar `date +%F` local en vez de `WIKI_GRAPH_TODAY` | test de determinismo con TODAY remoto |
| M7 | `cleanup` antes de `add` en `qmd_migrate_collection` | test de orden del stub |
| M8 | Escribir el sentinel antes del `add` | test de interrupción (queda `done` con colección ausente) |
| M9 | Volver la máscara a `**/*.md` | `qmd-setup.bats` (args grabados) y e2e (`qmd ls`) |
| M10 | Copiar las plantillas nuevas dentro de la sección 2 del bloque 0.8.0 (`:86-90`, con `changed=1`) en vez de en el bloque 0.27.0 | `vault-upgrade.bats` "0.8.0-empty (sin marcador) no recibe el delta 0.8.0" |
| M11 | Marcador 0.27.0 vacío | test `deposited:` y `schema_delta_pending` con fixture |
| M12 | Quitar `_v_cron5` | test de schedule inválido |
| M13 | Minuto por defecto `0 9 * * 1` | test del default de schedule |
| M14 | Borrar CANON-D1 del skeleton | test verbatim delta↔skeleton y `schema_delta_pending` sobre skeleton |
| M15 | Backfill con `//` en vez de `has()` | `regenerate.bats` valor `0`/`false` preexistente pisado |
| M16 | `_doctor_warn` por `review_due > 0` | `agentctl-local.bats` exit 0 esperado |
| M17 | Volver `has_pages27` a la forma `find \| head -1 \| grep -q .` | `vault-upgrade.bats`: fixture con 3.000 páginas vacías y `set -o pipefail` → el delta no se deposita (FALSE 200/200 medido) |
| M18 | Escribir el sentinel de layout en el camino común (`:397`) en vez de dentro de la rama del `add` | `qmd-setup.bats` "setup re-entrante no crea `.qmd-collection-wiki`" |

## 5. Protocolos de medición que quedaron para el gate (Q2, Q10)

**Hit-rate (Q2)**: sobre una **copia** del vault de un agente (nunca el vivo), 20-30 preguntas con
respuesta conocida (página esperada). Con la colección heredada: `qmd query` top-10 y contar documentos de
`_templates/`, `index.md`, `log.md`, `CLAUDE.md`, `raw_sources/` y duplicados raw/summary. Migrar la copia
(`qmd-migrate` sobre un `XDG_CACHE_HOME` aparte) y repetir. Registrar solo conteos.

**Index-first (Q10)**: 10 preguntas en linus (vault chico) y, cuando haya acceso, en el vault grande;
protocolo actual vs paso 0; contar tool calls y segundos por respuesta desde el log de sesión. Las cotas de
SC-004 se fijan con esos números y se anotan en `tasks.md`.

## 6. Despliegue y gate de hardware (antes del merge; precedente 024)

Prerrequisito: reautenticar Cloudflare Access (operador); ferrari respondió `banner exchange timeout` el
26-09-2026.

1. **Por agente, antes de actualizar** (conteos, sin contenido): `yq '.vault.seed_skeleton' agent.yml` (debe
   ser `true` para recibir el delta), `find <vault>/wiki -name '*.md' | wc -l`, `grep -c 'normalization' <vault>/CLAUDE.md`
   (delta 0.8.0 integrado), `ls <auto-memoria>/project_*.md | wc -l`, `grep -l 'para: project' <vault>/wiki/entities/*.md | wc -l`.
2. **Orden**: swap de archivos de sistema + `--regenerate` (local) / rebuild + `agentctl up` (docker) →
   el boot o `--regenerate` deposita el delta 0.27.0 → el primer tick de reindex migra la colección
   (`heartbeatctl status`: `collection=wiki-root migration=done`; `qmd ls vault` solo `wiki/`; `qmd embed`
   → already have embeddings) → `wiki-graph.json` muestra `schema_delta_pending: 0` hasta que pasen 14 días
   o `1` después si el agente no integró → el agente integra el delta en la siguiente sesión
   (`grep -c '## Actionability (PARA)' <vault>/CLAUDE.md` = 1) → migra sus `project_*` a fichas + punteros.
3. **Ventana de divergencia**: entre el rebuild y la integración del delta, los hallazgos nuevos son
   esperados; no son regresión.
4. **linus** (docker, vault chico): SC-006 arranca aquí (4 semanas); Q4/Q15 (duración y tokens de
   kickoff/weekly desde `runs.jsonl` y el log de sesión); aviso semanal habilitado a prueba editando
   `features.heartbeat.review.enabled: true` en `agent.yml` + `heartbeatctl reload` (no hay subcomando
   `set-*` para esta clave); verificar un mensaje por semana y `trigger: review` en `runs.jsonl`.
5. **mclaren** (local): `--regenerate` deposita el delta; `agentctl status` muestra counts y layout;
   `agentctl heartbeat qmd-migrate --dry-run` antes del primer tick; timers intactos (`list-timers`).
6. **ferrari, vault grande**: `time` del runner sobre las 2.696 páginas (< 60 s, SC-005); `wc -l index.md`,
   `wc -c findings.json` (Q14); migración de colección en segundos (`runs` de `qmd-index.json`); Q2 sobre
   una copia.
7. Registrar todo en `tasks.md` (Notes) con fecha; solo entonces PR y merge.

## 7. Checklist de cierre

- [ ] Suite dual 0 `not ok`; shellcheck rc 0; bytes limpios.
- [ ] DOCKER_E2E verde (qmd, vault, heartbeat).
- [ ] Mutación M1-M18 corrida contra la implementación real.
- [ ] VERSION 0.27.0 (verificado contra `origin/main`), CHANGELOG `### Added`, README, `docs/vault.md`,
      `docs/heartbeatctl.md`, `docs/state-layout.md`, `docs/qmd-upgrade-checklist.md`, `CLAUDE.md` del repo.
- [ ] Gate de hardware §6 registrado.
- [ ] Commit + PR contra `main` solo con confirmación del operador; nunca push sin ella.
