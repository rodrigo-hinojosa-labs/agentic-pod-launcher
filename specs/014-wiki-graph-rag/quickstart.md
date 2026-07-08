# Quickstart / Gates: 014-wiki-graph-rag

Secuencia de validación de la feature, del inner loop al hardware real.

## Gate 1 — Suite host (obligatorio, cada iteración)

```bash
bats tests/                                   # suite completa, sin Docker
bats tests/wiki-graph.bats                    # runner: grafo/hallazgos sobre fixtures
bats tests/vault-upgrade.bats                 # vault_seed_missing
bats tests/local-wiki-graph.bats              # render wrapper/unit/timer
shellcheck -S error scripts/lib/wiki_graph.sh scripts/lib/vault.sh setup.sh scripts/agentctl
```

Criterios: 0 fallos; fixture con hallazgos conocidos → exactamente esos (SC-001); skeleton
limpio → 0 hallazgos; upgrade aditivo → 0 hashes cambiados (SC-005).

## Gate 2 — DOCKER_E2E (obligatorio antes del merge)

```bash
DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats   # fase wiki-graph agregada al boot qmd
DOCKER_E2E=1 bats tests/docker-e2e-vault.bats
```

Criterios: la línea `wiki-graph` aparece en `/etc/crontabs/agent`; `heartbeatctl
wiki-graph` genera `.graph/*.json` + `wiki-graph.json` con `last_status: ok`;
`vault_seed_missing` en boot no toca contenido preexistente; `cap_drop: ALL` intacto.

## Gate 3 — mclaren (local, RPi5) — manual, cuando el host esté disponible

Se apila con los gates pendientes de 013 (misma sesión). Checklist:

1. `git pull` del launcher a `main` post-merge; `./setup.sh --regenerate` en el workspace.
2. Vault poblado previo: verificar upgrade aditivo — `wiki/normalization/` creado,
   `_templates/schema-updates-0.8.0.md` presente, entrada en `log.md`, `CLAUDE.md` del
   vault INTACTO (hash), cero páginas modificadas.
3. `systemctl list-timers 'agent-*'` incluye `wiki-graph.timer` con OnCalendar correcto
   (o marker de fallback consultable si el schedule no fue convertible).
4. `./scripts/agentctl heartbeat wiki-graph` → `.graph/{graph,backlinks,findings}.json`
   frescos; `wiki-graph.json` con counts plausibles para la wiki real.
5. Crear una regla de normalización (`canonical: Cencosud`, `aliases: [SENCOSUD]`) y una
   página con "SENCOSUD" en el cuerpo → siguiente corrida reporta `alias_occurrence`.
6. `./scripts/agentctl doctor` → exit 0/1/2 coherente con los counts; romper un wikilink
   → WARN (exit 1); restaurarlo → OK.
7. Kill-switch ON → `wiki-graph.timer` detenido (SC-004); OFF → reactivado.
8. SC-006 spot-check: `time` de la corrida sobre la wiki real (< 60 s con margen amplio).
9. Sesión agéntica: pedir un ingest de un transcript con "SENCOSUD" → capa 1 verbatim,
   páginas capa 2 con "Cencosud" (SC-007); pedir una query → la respuesta cita vecinos
   del grafo.

## Gate 4 — ferrari (docker, wiki poblada real) — manual, post-merge

Se apila con el gate 013 de ferrari (habilitar QMD por primera vez, FR-016). Checklist:

1. Rebuild de imagen con launcher 0.8.0; `agentctl up`.
2. Boot ejecuta `vault_seed_missing`: `wiki/normalization/` + delta + log entry en el
   vault REAL (comparisons/concepts/entities/overviews/summaries/synthesis intactos —
   verificar por hash de muestra).
3. `grep wiki-graph /etc/crontabs/agent` (vía `agentctl`) → línea presente con `20 */6`.
4. `./scripts/agentctl heartbeat wiki-graph` → grafo refleja la wiki real (counts de
   nodos ≈ número de páginas; hallazgos plausibles, no vacíos triviales).
5. El agente (vía Telegram) responde una query citando vecinos a 1 salto y resuelve un
   alias declarado hacia la entity canónica.
6. Syncthing: `.graph/` aparece en el Mac sin conflictos tras 2+ regeneraciones.

## Recordatorio de gates 013 aún pendientes (misma sesión de hardware)

- mclaren: index.sqlite bajo `<ws>/.state/.cache/qmd`, watcher >5 min activo, edición
  `.md` → reindex ~15 s, kill-switch detiene backup, doctor exit codes.
- ferrari: habilitar `vault.qmd.enabled` por primera vez (bunx ya existe en la imagen),
  `claude mcp list` → qmd Connected.
