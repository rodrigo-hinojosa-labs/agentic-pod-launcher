# Contract: Paridad de modos y operación

Norma para el scheduling, las acciones manuales y la integración operacional en ambos
modos. Criterio de paridad: mismo vault → mismos artefactos y mismos hallazgos (SC-003).

## Config única

`agent.yml` → `vault.wiki_graph.{enabled,schedule}`; defaults en `scripts/lib/schema.sh`
(`enabled: true` si `vault.enabled`; `schedule: "20 */6 * * *"`). Render vars precomputadas
en `setup.sh` (D12): `WIKI_GRAPH_ENABLED`, `WIKI_GRAPH_SCHEDULE`. Sin prompt de wizard.
Gating en runtime: `wiki_graph_enabled` lee `agent.yml` vía yq (patrón `_qmd_enabled`).

## Docker

- **Programado**: `heartbeatctl` agrega al `.crontab.staging` la línea
  `${schedule} /usr/local/bin/heartbeatctl wiki-graph >> /workspace/scripts/heartbeat/logs/wiki-graph.log 2>&1`
  (patrón `qmd_reindex_line`, heartbeatctl:265-272). El sync-loop root existente publica a
  `/etc/crontabs/agent`. `crontab.tpl` NO se toca.
- **Manual**: `heartbeatctl wiki-graph` (nuevo subcommand; carga `wiki_graph.sh`, corre
  `wiki_graph_run`, imprime resumen de counts). Proxy ya existente:
  `./scripts/agentctl heartbeat wiki-graph`.
- **Imagen**: `COPY scripts/lib/wiki_graph.sh` explícito en Dockerfile + línea en
  `setup.sh::mirror_catalog_to_docker` + `COPY modules/vault-deltas/` para el upgrade en
  boot. Drift-guard en `tests/docker-render.bats`.
- **Boot**: `start_services.sh::seed_vault_if_needed` llama `vault_seed_missing` después de
  `vault_seed_if_empty` (ambas fail-silent, contexto usuario `agent`; NO `entrypoint.sh` — H5).

## Local (systemd)

- **Programado**: `agent-<name>-wiki-graph.{service,timer}` renderizados de
  `modules/local-wiki-graph.{service,timer}.tpl`; OnCalendar vía
  `local_schedule.sh::cron_to_systemd_calendar`; si cae al fallback → marker persistente
  `<ws>/scripts/heartbeat/wiki-graph-schedule.fallback` (mecanismo CRON_FALLBACK 013),
  reportado por status/doctor.
- **Wrapper** (`modules/local-wiki-graph.sh.tpl`), en este orden obligatorio:
  1. `export PATH="{{OPERATOR_HOME}}/.local/bin:{{DEPLOYMENT_WORKSPACE}}/scripts/vendor/bin:$PATH"`
  2. `export VAULT_ROOT_OVERRIDE="{{LOCAL_VAULT_DIR}}"` y
     `export WIKI_GRAPH_VAULT_DIR="{{LOCAL_VAULT_DIR}}"`
  3. source de la lib + `wiki_graph_run` con exit 0 incondicional (Principle IV; la
     honestidad va en el state file).
- **Manual**: `agentctl heartbeat wiki-graph` → caso nuevo en `cmd_local_heartbeat`, exec
  DIRECTO del wrapper (sin systemctl/polkit, sin privilegios — patrón 013).
- **Instalación**: units staged en scaffold + instaladas por `--login` (mismo flujo
  012/013, incluida la reinstalación de staged pendientes).

## Kill-switch (local)

`modules/local-killswitch.sh.tpl` → `AUX_UNITS` incluye
`agent-${AGENT_NAME}-wiki-graph.timer`. Con kill-switch activo NO corre ninguna corrida
programada (SC-004); la acción manual sigue disponible (decisión deliberada: el kill-switch
detiene automatismos, no herramientas del operador).

## Healthcheck (local)

`modules/local-healthcheck.sh.tpl`: si `systemctl is-failed --quiet
agent-<name>-wiki-graph.service` (self-gating: unit ausente → no-op) → `_demote WARN
"wiki-graph runner failed"`. WARN, no DEGRADED: el grafo viejo sigue siendo utilizable y
la acción manual lo refresca.

## Status / Doctor

- `agentctl status` (local): bloque `Wiki graph` con frescura (`last_run` humanizado),
  `last_status`, counts resumidos y marker de schedule fallback si existe.
- `agentctl doctor` (local): aplica el contrato de degradación de
  `contracts/graph-artifacts.md` (WARN integridad/error; FAIL runner muerto a 2× intervalo,
  fallback 24 h; exit codes 0/1/2 agregados al resultado global de `cmd_local_doctor`).
- Docker status/doctor para RAG: fuera de alcance (backlog 013, sin ampliación aquí).
  La observabilidad docker es el state file `wiki-graph.json` (`cat` / `jq`) + el log de
  cron `logs/wiki-graph.log` + `heartbeatctl wiki-graph` (que RE-EJECUTA el runner e
  imprime counts, no consulta la última corrida programada). Por eso **SC-002 queda
  acotado a modo local** (H1): la vista de frescura+counts "en un solo comando" es una
  garantía local; en docker la frescura se lee del state file. Si a futuro se quiere
  paridad total, la superficie es un `heartbeatctl wiki-graph status` read-only (backlog).

## NEXT_STEPS (en/es)

Bloque bajo el condicional de vault (bloques hermanos, sin `{{#if}}` anidado):

- Local: `journalctl -u agent-<name>-wiki-graph.service -n 50`,
  `systemctl list-timers 'agent-<name>-*'`, `./scripts/agentctl heartbeat wiki-graph`.
- Docker: `./scripts/agentctl heartbeat wiki-graph`,
  `tail -f scripts/heartbeat/logs/wiki-graph.log`.

## Touchpoints de tests conocidos (M8)

Como `WIKI_GRAPH_ENABLED`/`WIKI_GRAPH_SCHEDULE` son render vars SIN prompt nuevo de wizard,
el ÚNICO touchpoint es **`known_external` en `schema.bats`** (ambos arrays, ~:62 y ~:114).
`wizard_answers` y el array posicional de `e2e-smoke.bats` son respuestas a PROMPTS del
wizard — no se tocan aquí (aplican solo cuando se agrega un prompt, no un `{{VAR}}` de
render). La gotcha de "3 touchpoints" del repo aplica a prompts nuevos, no a este caso.
