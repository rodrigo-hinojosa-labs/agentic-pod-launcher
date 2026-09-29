# J — Decisiones del operador para la feature 037 (rondas AskUserQuestion 25/26-09-2026)

Base: `main` @ `70214d9`, VERSION 0.26.0. Insumos: H-synthesis.md (D1-D12) + I-critique.md (A1-A3, M1-M5, D13-D20).

## Decididas por el operador (ocho, dos rondas)

| # | Pregunta | Decisión | Nota |
|---|---|---|---|
| R1-1 | Alcance de 037 | **(c) ambicioso** | Contra la recomendación (a)+(b). Entra: packets como unidad de recuperación, favorite problems como filtro de captura, `archive_candidate` (solo propuesta), heartbeat multi-prompt, claves nuevas en `agent.yml`. |
| R1-2 | Dónde vive PARA | **Frontmatter** sobre los seis tipos | `para:` ausente = resource; archivo = `para: archive` + `archived:` en el mismo archivo; sin carpetas PARA. |
| R1-3 | Higiene del índice qmd | **Sí, raíz `wiki/`**, migración como acción explícita con aviso | Sentinel bajo el cache root de qmd en `.state`; sin bump del pin; `raw_sources` sigue por Grep/`search_notes`. Costo ferrari ≈ 85 min de re-embed (estimado desde 018) salvo que Fase 0 mida reutilización de embeddings. |
| R1-4 | Disparador y cadencia de revisión | **Cola determinista, semanal** | Finding `review_due` desde `next_review` en el runner del grafo; cadencia por defecto semanal para proyectos (no es Forte: su weekly es de bandejas; se documenta como política del operador). Áreas: mensual (H D3) salvo que la spec fije otra cosa. |
| R2-1 | Forma de entrega | **Una spec, un PR** | Contra la recomendación de dos PRs. Todo (c) en la rama 037 y un PR contra main. Gate de hardware completo antes del merge (precedente 024). |
| R2-2 | Casa de la ficha de proyecto | **Vault + puntero** | `entity` + `para: project` en el vault; auto-memoria `project_<slug>.md` = puntero de 2-3 líneas; nota de migración en el delta. |
| R2-3 | Heartbeat multi-prompt | **Opt-in, solo avisa** | Prompts por día de semana entran (toca `heartbeat.sh` + `heartbeatctl set-prompt`); el prompt de revisión por defecto solo AVISA al canal cuando hay `review_due`/`pending_ingest`; la revisión ocurre en sesión. Fase 0 mide si la sesión del heartbeat carga los MCP `vault`/`qmd`. Local sin tick LLM, documentado. |
| R2-4 | Idioma del schema, plantillas y delta | **Inglés** | Consistente con skeleton, delta 0.8.0, docs, README. |

## Asumidas por defecto (no preguntadas: decididas antes, ratificadas, o default obvio)

| # | Decisión | Fuente |
|---|---|---|
| A1 | Sin séptimo `type` ni valores nuevos de `status` | 014 clarify Q1; H D5 |
| A2 | Ningún script edita `wiki/`, `raw_sources/` ni el `CLAUDE.md` del vault; todo lo que "hace" es prosa o finding | 014 FR-005 y R7 |
| A3 | Entrega del schema por **delta** `schema-updates-0.27.0.md` + marcador oculto propio + línea `upgrade` en `log.md`, más finding `schema_delta_pending` | H D9; C §6.13 |
| A4 | Destilación **oportunista** (`distill` sube solo al tocar la página por otra razón) | Forte R16; H D4 |
| A5 | Ambos modos (docker + local) para skeleton, schema, linter, higiene qmd; heartbeat docker-only opt-in | H D7 |
| A6 | Página `favorite-problems.md` **bajo demanda** desde prosa, nunca semilla en el skeleton (rompe el oráculo "skeleton limpio = 0 findings") | I A1 |
| A7 | Index-first **gateado**: el paso 0 lee `overviews/` (MOC de dos niveles de (c)) y las secciones PARA de `index.md`; `index.md` completo solo bajo un umbral de páginas medido en Fase 0 | I A2 |
| A8 | `para: archive` suprime `orphan` para esa página; `stale` ya mira solo `active` | I D20 |
| A9 | Findings nuevos informan, **no degradan** `doctor` (contrato 0/1/2 de 013 intacto); `heartbeatctl status` docker gana counts de wiki-graph (el rebuild ya es obligatorio) | I D17/D18 |
| A10 | `description_missing` solo para páginas con `para:` o `created` ≥ fecha del delta, valor no vacío; `pending_ingest` con dominio `raw_sources/**/*.md` con `clipped:` | I M4 |
| A11 | Aristas desde claves PARA: el parser emite aristas kind `related` desde `project`/`area`/`problems` cuando el valor es wikilink o slug resoluble (cuarto toque), para que fichas y favorite problems no sean `orphan` perpetuos | I M1 (opción ii) |
| A12 | Higiene qmd aterriza **antes** que las reglas de sesión/filing que escriben en `log.md` (orden de fases en tasks) | I M2 |
| A13 | Weekly review = bandeja (`pending_ingest`) + loops abiertos + proyectos `review_due` (cadencia semanal decidida por el operador); monthly review = áreas + archivo + outcome | I M3 + R1-4 |
| A14 | `packet:` tipado sobre el tipo natural de cada página (`distilled-note|outtake|wip|deliverable|external`) + `.graph/packets.json` + sección `## Packets` en `index.md`; sin directorio nuevo | H D11 |
| A15 | `archive_candidate` = `status: stale|superseded` + sin backlinks + sin citas en `log.md` en N días; **solo propuesta**, el humano decide; nunca mover automáticamente | H §4.3; G §4.1 |
| A16 | Claves nuevas en `agent.yml` con el trío completo (heredoc + backfill `has()` + `schema.sh` + `known_external`); las 4 claves muertas (`vault.initial_sources`, `vault.mcp.server`, `vault.schema.*`) se documentan como reservadas, no se retiran en 037 (retirar toca `schema.bats:43`, cambio aparte) | B §1; H gap #11 |
| A17 | `review_due` determinista en tests: el runner acepta `TODAY` inyectable; fixtures con fechas remotas | I §3 (Principio III) |
| A18 | Sin prompt nuevo de wizard; los campos nuevos se escriben con default en el heredoc y se editan en `agent.yml` | memoria `wizard-prompt-test-touchpoints` |
| A19 | Sin bump de qmd; sin parche a su dist; sin `/vault:*` skill | D §2.2, §2.5, §2.1 |
| A20 | Cambio exclusivo de frontmatter (`para:`) puede no re-indexarse en qmd (Q9): mitigación = bumpear `updated:` y tocar una línea del cuerpo en cada cambio de `para` | I §4.4 |

## Mediciones de Fase 0 heredadas (H Q1-Q12 + I Q13-Q16)

Q1 superficie real de exclusión de qmd 2.5.3 en el contenedor; Q2 degradación del top-K por indexar plantillas/index/log/raw/archivo; Q3 MCP en la sesión del heartbeat; Q4/Q15 duración y tokens de kickoff/close/review; Q5/Q16 estado real de los vaults de la flota (páginas por tipo, delta 0.8.0 integrado, `project_*`, entities-proyecto); Q6 costo del runner con findings nuevos sobre 2.696 páginas; Q7 segundo bloque de `vault_seed_missing` en tres estados; Q8 exclusión de `.graph/` en inotifywait Alpine; Q9 re-index por cambio solo de frontmatter; Q10 index-first en la flota; Q11 artículo Pilevar; Q12 raw consultable con dos colecciones (menos relevante con raíz `wiki/`); Q13 `collection remove`+`add` reutiliza embeddings; Q14 tamaño de `index.md` y `findings.json` en el vault grande.

