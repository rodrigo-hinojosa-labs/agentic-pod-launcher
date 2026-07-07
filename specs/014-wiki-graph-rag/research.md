# Research: 014-wiki-graph-rag

Fase 0 del plan. Cada entrada: Decision / Rationale / Alternatives considered.
Evidencia verificada leyendo el repo y el gist fuente en esta sesión (2026-07-06).

## R1 — Fuente de diseño: gist "LLM Wiki" de Karpathy

**Decision**: implementar el "siguiente nivel" del patrón que el gist describe y sus
comentarios recomiendan: validación determinista por scripts (LLM solo para síntesis),
explotación del grafo implícito en wikilinks, y control de drift terminológico.

**Rationale**: el vault skeleton (feature 010) ya es la implementación literal de las 3
capas del gist (`modules/vault-skeleton/CLAUDE.md` cita el gist textualmente). Los gaps
que el gist deja abiertos y que esta feature cierra: backlinks no mantenidos
(`vault-skeleton/CLAUDE.md:75-76`), lint 100% manual/agéntico (`:116-137`), drift de
`index.md` solo detectable a mano (`vault-skeleton/index.md:10-11`), sin normalización.
Los comentarios del gist (leídos 2026-07-06): "deterministic Python scripts para
intake/validation, LLM solo para synthesis"; "lint pass obligatorio, no opcional";
"a escala ~4000+ conceptos el flat index no escala; necesita híbrido" (qmd ya cubre la
búsqueda; el grafo cubre la navegación estructural).

**Alternatives**: lint agéntico programado (sesiones LLM cron) — descartado para v1 por
costo de tokens y porque la dimensión estructural es 100% determinizable; queda en backlog.

## R2 — Lenguaje del runner: bash + awk (extracción) + jq (agregación)

**Decision**: lib bash espejada; awk POSIX extrae registros per-file (TSV: nodo, arista
candidata, violación, ocurrencia de alias); jq agrega globalmente (backlinks, huérfanos,
drift) y ensambla los JSON finales atómicamente.

**Rationale**: (a) cero dependencias nuevas — jq y yq YA están en la imagen
(`docker/Dockerfile:36-37`), en el host (deps de tests) y en local; (b) el host macOS NO
tiene bash 4+ (memoria de proyecto verificada en 013) → nada de arrays asociativos: la
agregación vive en awk/jq, no en bash; (c) la separación extracción-per-file / agregación
global permite `xargs` por lotes sin perder correctitud (awk no necesita estado global);
(d) el parser estricto del subset de frontmatter ES el validador — entrada no parseable se
convierte en `frontmatter_violation`, que es exactamente el comportamiento que FR-004 pide.

**Alternatives**: bun/JS — parsing YAML/markdown robusto y bun garantizado en ambos modos
post-013 (FR-016), PERO agrega bun como dependencia de la suite host (hoy: bats, yq, jq,
git, tmux), rompe el patrón de libs espejadas bash y duplica estilos de test. Rechazado.
yq por archivo — 1.000 forks de yq en la Pi rompería SC-006. Rechazado.

## R3 — Transporte de scheduling docker: staging de heartbeatctl, NO crontab.tpl

**Decision**: `heartbeatctl` gana subcommand `wiki-graph` y agrega la línea al
`.crontab.staging`, patrón exacto de `qmd_reindex_line`.

**Rationale**: verificado — `docker/crontab.tpl` SOLO contiene la línea del heartbeat; la
línea de qmd-reindex nace en `docker/scripts/heartbeatctl:265-272` y llega a
`/etc/crontabs/agent` vía el sync-loop root del entrypoint (cmp -s). Reusar ese camino
mantiene el modelo de privilegios intacto (crontab root-owned, Principle II).

**Alternatives**: editar `crontab.tpl` — rompería el patrón establecido en 010 y duplicaría
el mecanismo de staging. Rechazado.

## R4 — Espejado de la lib a la imagen

**Decision**: `scripts/lib/wiki_graph.sh` + línea `cp` en
`setup.sh::mirror_catalog_to_docker` + línea `COPY` explícita en `docker/Dockerfile`.

**Rationale**: verificado — el build context es `./docker` del workspace
(`modules/docker-compose.yml.tpl:9`); `mirror_catalog_to_docker` (setup.sh:1488-1511)
copia las libs compartidas (`vault.sh`, `qmd_index.sh`, …) a `docker/scripts/lib/` en el
scaffold para que el COPY las encuentre; y la gotcha documentada del repo exige COPY
explícito por lib. Los tres puntos deben tocarse juntos (drift-guard en
`tests/docker-render.bats`).

## R5 — Exclusión natural de `.graph/` del backup y de qmd

**Decision**: TODOS los artefactos derivados usan extensiones no-`.md` (JSON). Contrato
duro en `contracts/graph-artifacts.md`.

**Rationale**: verificado — el backup del vault solo stagea `find … -name '*.md'`
(`scripts/lib/backup_vault.sh:93`) y la colección qmd usa mask `**/*.md`
(`scripts/lib/qmd_index.sh:181`). Mientras `.graph/` contenga solo JSON, queda fuera de
backup e índice sin tocar ninguno de los dos subsistemas (Principle V: los 3 primitivos de
backup no se modifican). Corolario: si alguna vez se emite un reporte `.md`, entraría a
backup + qmd — prohibido por contrato en esta feature.

## R6 — Páginas de normalización SÍ entran a qmd

**Decision**: `wiki/normalization/*.md` se indexa en qmd (sin cambios de mask) y se respalda
(son `.md`).

**Rationale**: son contenido curado (reglas) que conviene que sea buscable y durable; el
costo es cero (la mask existente ya las cubre). No confundir con `.graph/` (derivado).

## R7 — Upgrade aditivo: helper nuevo + dir de deltas fuera del skeleton

**Decision**: `vault_seed_missing TARGET SKELETON DELTAS_DIR [TODAY]` en
`scripts/lib/vault.sh`; los deltas de schema viven en `modules/vault-deltas/`
(`schema-updates-0.8.0.md`), NO dentro del skeleton.

**Rationale**: verificado — `vault_seed_if_empty` es no-op con vault poblado
(`vault.sh:39-41`) y `vault_backup_and_reseed` mueve el vault entero (destructivo). Si el
delta viviera en el skeleton, cada scaffold fresco lo heredaría como ruido (su CLAUDE.md ya
está actualizado). Separar deltas permite: fresh scaffold = skeleton completo actualizado;
vault existente = solo estructuras faltantes + delta + entrada `log.md`. Idempotencia por
un marcador OCULTO `_templates/.schema-updates-0.8.0.applied` (sentinel, no mtime —
Principle IV); NO por la existencia del delta `.md`, que el agente puede borrar tras
integrarlo sin que el upgrade lo re-deposite (C1, resuelto en /speckit-analyze).

**Alternatives**: append directo al CLAUDE.md del vault con marcadores — rechazado en
clarify (capa co-evolucionada; riesgo de duplicar contenido reorganizado por el agente).

## R8 — Locks y temporales FUERA del vault

**Decision**: flock sobre `<ws>/scripts/heartbeat/.wiki-graph.lock`; escritura de
artefactos con tmp+mv DENTRO de `.graph/` (mismo filesystem → rename atómico).

**Rationale**: el vault se sincroniza por Syncthing (caso real: rodri-cenco-admin ↔ Mac);
locks o tmp de larga vida dentro del vault generarían sync-conflicts. El tmp+mv intra-dir
es de vida corta y el rename es atómico local; un eventual `.tmp` sincronizado a medias es
inocuo (regenerable) y Syncthing lo reconcilia. flock no existe en macOS → los tests host
de concurrencia se gatean/skipean (precedente exacto: 013 `qmd-setup.bats`).

## R9 — Reglas de parsing (subset restringido = contrato)

**Decision**:
- Frontmatter: bloque `---`…`---` inicial; claves planas `key: value`, arrays de flujo
  `key: [a, b]` y arrays de guiones. Cualquier otra forma → `frontmatter_violation`.
- Wikilinks: `[[target]]`, `[[target|display]]`, `[[target#anchor]]`,
  `[[target#anchor|display]]`; la resolución usa solo `target` → `wiki/<target>.md`
  relativo al vault; match exacto (la convención del schema es slug lowercase).
- Exclusiones de escaneo: fenced code blocks (toggle ```); `index.md`/`log.md`/
  `_templates/`/`raw_sources/` no son nodos; `index.md` se valida aparte (drift
  bidireccional).
- Aliases: word-boundary, case-insensitive default (`match_case: true` lo endurece),
  fuera de fences, excluyendo `wiki/normalization/` mismo.

**Rationale**: el subset es exactamente lo que el skeleton documenta como obligatorio
(frontmatter spec en `vault-skeleton/CLAUDE.md:48-65`, wikilinks `:67-76`); parsear más de
lo especificado agregaría ambigüedad sin valor. Inline code spans NO se excluyen del
escaneo de alias en v1 (complejidad awk vs beneficio marginal) — documentado en contrato.

## R10 — Heurística stale determinista

**Decision**: hallazgo `stale` (informativo, no degrada doctor — clarify Q5) cuando una
página `status: active` lista en `sources:` un archivo cuyo mtime (fecha) es posterior a
`updated:` + 1 día.

**Rationale**: es la única señal de staleness computable sin LLM y coincide con la
definición del schema ("updated: predates its newest source"). El ruido posible por mtime
churn de Syncthing es aceptable porque stale nunca degrada (solo informa).

## R11 — Offset de schedule

**Decision**: default `20 */6 * * *`.

**Rationale**: evita estampida con los jobs existentes: vault-backup `0 * * * *`
(hora en punto), identity 03:30, config 03:30, qmd backstop `*/5`. El :20 de cada 6 horas
no coincide con ninguno. Clarify Q3 fijó la cadencia (6 h); el offset es decisión de plan.

## R12 — Lecciones 013 aplicadas desde el diseño (modo local)

**Decision**: el wrapper local nace con: (1) `export PATH="<home>/.local/bin:<ws>/scripts/
vendor/bin:$PATH"` como PRIMERA acción; (2) `VAULT_ROOT_OVERRIDE`/`WIKI_GRAPH_VAULT_DIR`
explícitos; (3) exit 0 fail-silent con `last_status=error` en el state file; (4) marker
persistente `wiki-graph-schedule.fallback` si `cron_to_systemd_calendar` cae a fallback
(mecanismo CRON_FALLBACK de 013); (5) kill-switch y healthcheck integrados desde el primer
render.

**Rationale**: las 3 causas raíz de 013 (storage env, PATH systemd, env del vault) son
exactamente los modos de fallo que este runner repetiría si se portara el patrón 012 sin
las correcciones. Costo marginal cero al diseñarlas de entrada.

## R13 — Performance (SC-006)

**Decision**: presupuesto: 1 pasada awk por lote de archivos + 1 agregación jq; verificación
en gate manual sobre mclaren (RPi5); test host con fixture sintético de 100 páginas como
smoke de complejidad (no benchmark).

**Rationale**: ~1.000 archivos markdown de tamaño típico (< 50 KB) es del orden de decenas
de MB; awk procesa eso en segundos incluso en arm64; el riesgo real serían 1.000 forks
(por eso R2 prohíbe yq per-file). El fixture de 100 páginas en bats protege contra
regresiones de complejidad accidental (loops bash por página).
