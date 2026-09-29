# K — Touchpoints de código para el plan de 037 (second-brain-rag)

Base verificada hoy (2026-09-26): `main` @ `70214d9`, VERSION `0.26.0`, rama `037-second-brain-rag`
(árbol idéntico a main salvo `specs/037-second-brain-rag/` y `.specify/feature.json`). Toda cita
`archivo:línea` fue leída en esta sesión. Los informes A/B/C de discovery NO existen en disco
(el scratchpad se limpió; solo quedó `J-decisions.md`), así que este informe no hereda nada de ellos.

Convención de las tablas: **qué cambia | dónde exactamente | patrón/precedente a copiar | tests afectados**.

---

## 1. `scripts/lib/wiki_graph.sh` (565 líneas) — el runner del grafo

### Pipeline hoy

| Etapa | Línea | Detalle |
|---|---|---|
| Gate | `:49-60` | `wiki_graph_enabled`: `vault.enabled==true` y `vault.wiki_graph.enabled!=false`. |
| Vault dir | `:64-69` | `WIKI_GRAPH_VAULT_DIR` (tests) > `vault_resolve_root` (agent.yml). |
| State file / lock | `:77-79`, `:82-84` | `WIKI_GRAPH_STATE_FILE`, `WIKI_GRAPH_LOCK` (fuera del vault). |
| State write | `:88-104` | `wiki_graph_write_state FILE STATUS DUR COUNTS ERR`; counts por defecto `:94` (8 claves: nodes, edges, orphans, broken_links, frontmatter_violations, index_drift, stale, alias_occurrences); schema 1 `:96`. |
| awk estructural | `:108-263` | `VALIDTYPE` `:111-112`, `VALIDSTATUS` `:113-114`; `unquote` `:118-123`; `unwrap` (`[[t\|d#a]]` → `t`) `:125-132`; `parse_flow` `:134-143`; `reset()` `:144-151` (variables por página); `compute_id` `:152-157` (ruta relativa a `wiki/` sin `.md`); `emit_v` `:158`; `flush()` `:159-180`: emite `N\tid\ttype\tstatus\tcreated\tupdated\ttitle_present` `:170`, violaciones `:171-174`, aristas `E\tfrom\tto\tkind` con kinds `wikilink` `:175`, `related` `:176`, `source` `:177`, y `SRCN\tid\tstatus\tupdated` `:178` (para stale). |
| Parser frontmatter | `:188-228` | Guiones `:195-201` (solo `related`/`sources`/`aliases`); `key: value` `:202-226` con `else if` por clave: `type`, `status`, `created`, `updated`, `title`, `canonical`, `match_case`, `entity`, `related`, `sources`, `aliases`. **Toda otra clave se ignora en silencio** (no hay rama `else`). `tags` NO se extrae. |
| Cuerpo | `:229-243` | Fences `:230-231`; wikilinks `:233-238`; cuerpo limpio para aliases `:240-242`. |
| Aliases (OCC) | `:244-261` | Word-boundary, case según `match_case`. |
| Orquestación | `:291-382` | `_wg_run_locked`: scratch/TMPDIR `:309-311` (`scratch_dir "$(dirname state_file)"` → `<hb>/tmp`); `find "$wiki_dir" -name '*.md'` **solo `wiki/`** `:321`, `:329`, `:340`; `index.md` `:334-336`; stale `:343-345`; agregación jq `:353`; escritura atómica de los TRES artefactos `:365-373`; state `:375-378`. |
| `index.md` | `:401-428` | `_wg_index_entries`: bullets `- [[…]]`, excluye comentarios HTML, backticks, `<…>`. |
| stale | `:433-455` | Bash: por `SRCN` con `status==active` y `updated` no vacío; mtime de cada `E/source` vs `updated+86400`. |
| Fechas | `:458-463` | `_wg_date_epoch YYYY-MM-DD` → epoch (`date -d` GNU/busybox, `date -j -f` BSD). `date -u` directo en `:93`, `:367`. **No existe `TODAY` inyectable.** |
| jq agregación | `:495-565` | `$nodes` por posición `.[1]..[6]` `:506`; `broken` para `wikilink`/`related` `:514`; `$backmap` incluye `related` `:518-520`; findings `:539-547`; `counts` `:553-562`. |

### Toques exactos que 037 necesita

| Qué cambia | Dónde exactamente | Patrón/precedente | Tests afectados |
|---|---|---|---|
| (a) Extraer claves nuevas (`para`, `tags`, `project`, `area`, `problems`, `packet`, `distill`, `description`, `goal`, `due`, `next_action`, `next_review`, `archived`) | Variables en `reset()` `:144-151`; ramas `else if (key == …)` en `:206-225`; `tags`/`problems` son arrays: usar `parse_flow` `:134` + rama de guiones `:195-201`; columnas nuevas en el record `N` `:170` y en el destructuring jq `:506` (posicional: extender en el mismo orden) | Cómo `related` se parsea flow+guiones (`:197`, `:214-217`) y `entity` usa `unwrap(unquote())` `:213` | `wiki-graph.bats:33-40` (7 nodos), `:65-73` (conteos exactos), `:98-107` (skeleton 0) |
| (b) Aristas desde `project`/`area`/`problems` | En `flush()` tras `:176`: `print "E\t" curid "\t" target "\trelated"` reutilizando kind `related` → `broken` `:514` y backlinks `:518-520` salen gratis (FR-004 cumplido sin nuevo kind). `problems: [fp-3]` sin wikilink → resolver a `synthesis/favorite-problems` solo si el nodo existe (jq `$nodeset`), si no, sin arista ni finding (spec Edge Cases) | Kind `related` existente | `wiki-graph.bats:42-53` (aristas), `:55-62` (backlinks); re-baseline de la fixture si se agregan páginas |
| (c) Findings nuevos | `frontmatter_violation` con razón `para invalid`/`packet invalid`/fecha malformada: `emit_v` en `flush()` `:171-174` (mismo shape que `type: invalid '…'`). Findings de página (`project_incomplete`, `description_missing`) → en jq `:539-545` como `$f_*` nuevos sobre `$nodes`, concatenar en `:546` y `counts` `:553-562`. Supresión `orphan` para `para: archive`: `select(.para!="archive")` en `:539`. Supresión `stale`: `SRCN` `:178` necesita columna `para` (o filtrar en `_wg_compute_stale` `:439`). | `$f_orphan`/`$f_stale` `:539`, `:544` | `wiki-graph.bats:65-85` (conteos + páginas), `:87-96` (negativos) |
| (d) Fechas para `review_due`/`project_overdue` | Hoy solo hay epoch en bash (`_wg_date_epoch` `:458`) y comparación de mtime `:452`. Opción 1: lista `due.txt`/`review.txt` en bash como `_wg_compute_stale` `:433` (misma forma, lee columnas nuevas del `N`). Opción 2: en jq con `strptime("%Y-%m-%d")\|mktime` (jq ≥1.6; medir en Alpine — Fase 0). `TODAY`: introducir `WIKI_GRAPH_TODAY` (env, default `date -u +%F`) | `QMD_EMBED_MAX_PASSES` env-overridable `qmd_index.sh:463`; `today` posicional en `vault_seed_missing` `vault.sh:71` | Nuevos tests con fixture de fechas remotas |
| (e) `packets.json` | Cuarto `_wg_atomic_write` en `:365-373`, clave `packets:` en la salida de `_wg_aggregate` `:548-563`; lista vacía siempre (`[]`) | `findings.json` `:372-373` | `wiki-graph.bats:142-149` (L1: solo no-`.md` en `.graph/`), `:151-158` (JSON válido) |
| (f) `raw_sources/**/*.md` + `log.md` | El runner solo enumera `$wiki_dir` (`:321`, `:329`, `:340`). Para `pending_ingest`: nuevo `find "$vault_dir/raw_sources" -name '*.md'` + awk que lea `clipped:` → TSV `RAW\tpath\tclipped` → `--rawfile` en `_wg_aggregate` `:497-501`; comparar contra `E/source` `.to` (ruta relativa al vault, p.ej. `raw_sources/articles/base.md`, fixture `alpha.md`) restringido a nodos `type==summary`. Para `archive_candidate`: nuevo `_wg_log_mentions` sobre `$vault_dir/log.md` (formato `## [YYYY-MM-DD] op \| título`, `log.md:9`) extrayendo fecha + ids mencionados en N días | `_wg_index_entries` `:401-428` (awk sobre un archivo raíz) | Fixture actual: `raw_sources/articles/base.md` tiene `clipped:` y está citado por `alpha` → `pending_ingest=0`; `log.md` de la fixture no menciona páginas → `archive_candidate=0` |
| (g) `CLAUDE.md` del vault y marcador del delta | El runner tiene `$vault_dir` (`:292`): puede `grep -F` la marca de integración en `$vault_dir/CLAUDE.md` y leer `_templates/.schema-updates-0.27.0.applied`. Edad: el marcador 0.8.0 es un archivo VACÍO (`vault.sh:103`, `: > marker`) → solo mtime (`_wg_file_mtime` `:466-471`); recomendación: que el bloque 0.27.0 escriba la fecha DENTRO del marcador (`printf '%s' "$today"`) para no depender de mtime (Constitución IV, y `cp -R` no preserva mtime) | `_wg_file_mtime` `:466` | `vault-upgrade.bats:30-35` (marcador existe), `:47-54` (idempotencia por hash) |

### Contrato y oráculo

- Contrato: `specs/014-wiki-graph-rag/contracts/graph-artifacts.md` — `.graph/` solo no-`.md` `:10-14`; escritura atómica `:15-16`; lock rc=91 sin state `:17-21`; `graph.json` `:23-52` (nota: el ejemplo trae `title`/`tags` `:31-33` que el código NO emite — drift documental preexistente); `backlinks.json` `:54-78`; `findings.json` `:80-97` (orden `kind, page, detail`); state `:99-111`; **contrato de degradación doctor** `:113-126` (WARN=1 solo `broken_links`/`frontmatter_violations`/`index_drift`/`error`; FAIL=2 runner muerto; `orphans`/`stale`/`alias` solo informan). Parser normativo `:128-155`.
- Fixture `tests/fixtures/vault-graph/` (12 archivos: `README.md`, `index.md`, `log.md`, `raw_sources/articles/base.md`, `wiki/{comparisons/broken,concepts/orphan-note,concepts/widget,entities/acme,normalization/cencosud,overviews/topic,summaries/alpha,synthesis/badfm}.md`). Oráculo exacto hoy (`README.md:26-36`): orphan 1, broken_link 1, frontmatter_violation 1, index_drift 2, stale 1, alias_occurrence 1 = **7**, fijado en `wiki-graph.bats:65-73` y por página `:75-85`. Estados de la fixture: `orphan-note` es `draft`; ninguna página `stale|superseded`; `alpha` tiene `tags: [demo]` (única con tags).

---

## 2. `scripts/lib/vault.sh` (153 líneas) — upgrade aditivo

| Función | Línea | Detalle |
|---|---|---|
| `vault_seed_if_empty` | `:33-50` | Copia skeleton si vacío; `SCAFFOLD_DATE` en `log.md` `:46-49`. |
| `vault_seed_missing TARGET SKELETON DELTAS [TODAY]` | `:70-112` | No-op si target vacío `:74`; `changed=0` `:76`; (1) dir `wiki/normalization` `:80-85`; (2) template `normalization.md` `:87-90`; (3) delta 0.8.0 gateado por marcador oculto `:93-95` (`_templates/.schema-updates-0.8.0.applied`), fresh-scaffold guard `changed==1 \|\| has_pages` `:96-100`, `cp` del delta `:102`, marcador vacío `:103`, línea `log.md` `:105-106` (`## [%s] upgrade \| schema updates 0.8.0 — read _templates/schema-updates-0.8.0.md and integrate into CLAUDE.md`). |
| `vault_backup_and_reseed` (force_reseed) | `:126-141` | Mueve a `.backup-<ts>` y re-siembra. |
| `vault_log_append VAULT OP TITLE [TODAY]` | `:146-153` | `## [%s] %s \| %s`. Existe pero `vault_seed_missing` NO la usa (imprime directo `:105`). |

| Qué cambia | Dónde exactamente | Patrón/precedente | Tests afectados |
|---|---|---|---|
| Bloque 0.27.0 | Después de `:110`, antes de `return 0` `:111`: plantillas nuevas solo si ausentes (molde `:87-90`), delta `schema-updates-0.27.0.md` con marcador propio (molde `:93-110`). **Usar un `changed27` propio y evaluar el bloque 0.8.0 ANTES de cualquier mutación 0.27.0**: si las plantillas nuevas ponen el `changed` compartido en 1, un vault sembrado por el skeleton 0.8.0 con wiki vacía recibiría el delta 0.8.0 espurio (`:100`). | `:87-110` | `vault-upgrade.bats:23-88` (10 tests; fixture `tests/fixtures/vault-populated/` = pre-014, 10 archivos, sin `normalization/`); agregar fixtures "0.8.0 vacía" y "0.8.0 con páginas" (SC-002). `:65-73` (fresh → sin delta) es el guardia de la trampa anterior. |
| Marcador con fecha | `:103` escribe vacío; para 0.27.0 escribir `$today` dentro (ver §1.g) | — | nuevo test |
| Triggers | Docker: `docker/scripts/start_services.sh:132-135` dentro de `if [ "$vault_seed" = "true" ]` `:108` (llamado desde `boot_side_effects` `:176`). Local: `setup.sh:2840-2844` en `_seed_vault_local`, tras `return 0` si `seed_skeleton` falso `:2824`. `modules/local-login.sh.tpl`: **NO lo llama** (grep `vault\|seed\|delta` solo da units qmd/backup/wiki-graph `:162-223`). | — | `vault-upgrade.bats:88` (docker trigger), `:94` (setup.sh trigger) |

**Riesgo detectado**: ambos triggers están gateados por `vault.seed_skeleton: true`; un agente con `seed_skeleton: false` jamás recibe deltas (ni 0.8.0 ni 0.27.0). La spec no lo contempla.

---

## 3. `scripts/lib/qmd_index.sh` (566 líneas) — índice qmd

| Función | Línea | Detalle |
|---|---|---|
| `qmd_pkg` | `:49-58` | Pin `vault.qmd.version` → default `2.5.3`. |
| `qmd_cache_root` | `:62` | `${QMD_CACHE_HOME:-$HOME/.cache/qmd}`. **Cache root real**: docker `/home/agent/.cache/qmd` (= host `.state/.cache/qmd`; `.mcp.json` env `{}` `setup.sh:2464`, `docker/scripts/qmd-mcp:7-8`); local `QMD_CACHE_HOME=<ws>/.state/.cache/qmd` + `XDG_CACHE_HOME=<ws>/.state/.cache` + `QMD_CONFIG_DIR=<ws>/.state/.config/qmd` (`modules/local-qmd-reindex.sh.tpl:39-41`, `modules/local-qmd-mcp.sh.tpl:25-27`, `setup.sh:2466`). El binario honra `XDG_CACHE_HOME`/`QMD_CONFIG_DIR`, no `QMD_CACHE_HOME` (`local-qmd-reindex.sh.tpl:32-38`). |
| `_qmd_prefix` | `:103` | `$(qmd_cache_root)/pkg`. |
| `_qmd_ensure_prefix` | `:175-229` | Hash del manifest `:195-202`, `bun install` `:206-209`, swap sqlite-vec `:227`. |
| `_qmd_run PKG ARGS…` | `:235-250` | `timeout ${QMD_CMD_TIMEOUT:-900}` + binario del prefijo `:248-249`; bigstack solo en `embed` `:246`. |
| `qmd_mcp_exec` | `:258-267` | `exec … qmd mcp`, sin timeout. |
| `qmd_write_state` | `:286-313` | `{hash,last_run,last_status,runs[,pending]}`, tmp+mv. |
| `qmd_setup_if_needed` | `:319-354` | Sentinel `$cache_root/.qmd-setup-ok` `:326`; fast path `:329-332`; lock `.reindex.lock` `:334`. |
| `_qmd_setup_locked` | `:357-400` | Guard `[ ! -f index.sqlite ]` `:377`; **`collection add "$vault_dir" --name "$coll" --mask '**/*.md'`** `:379` (`coll=${QMD_COLLECTION_NAME:-vault}` `:372`); `update` `:389`; `embed` `:393`; sentinel `:397`. |
| `_qmd_reindex_locked` | `:529-566` | `vault_hash` del vault ENTERO `:533`; guard unchanged+pending==0 `:538-542`; `update` `:557`; embed loop `:564`. |
| `_qmd_embed_until_complete` | `:484-521` | `QMD_EMBED_MAX_PASSES=12` `:463`. |

| Qué cambia | Dónde exactamente | Patrón/precedente | Tests afectados |
|---|---|---|---|
| Colección con raíz `wiki/` (FR-007) | `:379`: `"$vault_dir"` → `"$vault_dir/wiki"` (mismos flags del CLI ya en uso); escribir sentinel de colección `$cache_root/.qmd-collection-wiki` junto a `:397` | Sentinel `.qmd-setup-ok` `:326`, `:397` | `qmd-setup.bats:37-47` (log del stub: `collection add`), `:112-121`; `docker-e2e-qmd.bats:171` (`collection add` en el log); `docs/vault.md:398`, `specs/010…/contracts/qmd-cli.md:23` |
| Detección "migración pendiente" (FR-008/009) | Determinista sin parsear al vendor: `index.sqlite` presente Y sentinel de colección ausente → pendiente. Helper nuevo `qmd_collection_migration_state` en la lib; leído por `heartbeatctl status`/`agentctl` | `qmd_last_hash` `:270-274` (lector puro) | nuevos tests con seam A |
| Acción `qmd-migrate` | Lib: `qmd_migrate_collection` (bajo el mismo `.reindex.lock` `:334`; verbo `collection remove`/`rm` de qmd 2.5.3 = **Fase 0 Q1**, el contrato de 010 solo documenta `add`); escribe sentinel AL FINAL. Docker: `docker/scripts/heartbeatctl` nuevo `cmd_qmd_migrate` (molde `cmd_qmd_reindex` `:948-975` con `--dry-run` molde `_qmd_reindex_dry` `:978-996`), dispatch `main()` `:1056`, help `:121-130`. Local: `scripts/agentctl::cmd_local_heartbeat` `:1566-1596` nuevo `case qmd-migrate)`, ejecutando el wrapper `agent-qmd-reindex.sh --migrate` (el tpl ya despacha `--setup-only` `local-qmd-reindex.sh.tpl:52-54`) | `cmd_wiki_graph` `:1001-1021`; `agentctl:1585-1592` | `qmd-reindex-cmd.bats` (10), `local-qmd.bats:51-66`, `agentctl-local.bats:263-289`; `docs/heartbeatctl.md:5` lista de subcomandos |
| Seam de tests (019) | `specs/019-fix-qmd-test-drift/contracts/qmd-test-seam.md` Seam A `:13-43` = `tests/helper.bash::install_qmd_stub` `:93-106` (stub ve `$1`=subcomando; `collection` crea `index.sqlite` `:99`), `install_qmd_stub_fail` `:110-118`, `_qmd_stub_prefix_seed` `:79-87`; Seam B `:45-52` (override `_qmd_run`, solo unit). Setups: `qmd-index.bats:14-33`, `qmd-setup.bats:15-33` (`QMD_VAULT_DIR` = dir plano con `a.md`, **sin `wiki/`** `:18-19`) | — | Con raíz `wiki/`, `qmd-setup.bats`/`qmd-index.bats` deben crear `$QMD_VAULT_DIR/wiki/` o el stub grabará una ruta inexistente (el stub no valida, pero el test de `collection add` debería asertar el sufijo `/wiki`) |
| DOCKER_E2E Tier-1 | `tests/docker-e2e-qmd.bats:25-27`: "019 NOTE: … syntax-validated on the host only; full Docker validation is DEFERRED to the next DOCKER_E2E=1 run" — **confirmado, sigue sin validar en Docker desde 019**. El mismo archivo trae la Fase 4.5 wiki-graph `:236-275` (cron line, run manual, counts). Gating `:48`. | — | 037 (FR-035) debe correrlo de verdad |

**Nota de acoplamiento**: `vault_hash` (`scripts/lib/backup_vault.sh:100-110`) hashea todo `*.md` del vault (excluye solo `.git`, `.obsidian/cache`, `.obsidian/workspace*.json`, `.obsidian/.trash`, `.trash`, `*.sync-conflict-*` `:52-61`); es compartida con el backup, así que el debounce del reindex seguirá disparando `update` por escrituras en `log.md`/`index.md` aunque la colección sea `wiki/`. No cambiar `vault_hash` (rompería el criterio de backup); aceptar el `update` extra (barato).

---

## 4. Observabilidad

| Superficie | Línea | Hoy | Toque 037 |
|---|---|---|---|
| `docker/scripts/heartbeatctl::cmd_status` | `:350-438` | Heartbeat `:368-381`, últimos 5 runs `:385-388`, identity/vault/config backup `:391-418`, token health `:422-437`. **No lee `qmd-index.json` ni `wiki-graph.json`** (`docs/vault.md:519` lo reconoce). Vars ya definidas: `QMD_INDEX_STATE_FILE` `:66`, `WIKI_GRAPH_STATE_FILE` `:68`. | Bloque tras `:418`: `wiki-graph: <status> @ <run> counts …` (molde `cmd_wiki_graph` `:1018-1020`) + `qmd index: <status> pending=… migration=pending\|done`. Solo `echo`; `cmd_status` no tiene exit por contenido → contrato intacto. |
| `scripts/agentctl status` docker | `:858-863` | `exec docker exec -u agent … heartbeatctl status`. | Hereda lo anterior. |
| `agentctl doctor` docker | `:337-751` | Vault solo `:580-591` (skeleton seeded); sin qmd/wiki-graph. Salida 0/1/2 `:741-750`. | Fuera de alcance salvo lectura por `docker exec` (como `boot-attempt`). No degradar. |
| `agentctl` local `_local_vault_qmd_status` | `:1107-1151` | wiki-graph counts string `:1141` (`broken fm drift orphans alias`); qmd `:1121-1125`. | Extender `:1141` con contadores nuevos; línea de migración junto a `:1118-1119`. |
| `agentctl` local `_local_vault_qmd_doctor` | `:1155-1236` | Contrato Q5: FAIL runner muerto `:1216-1218`; WARN error `:1220-1222`; WARN integridad solo `broken/fmv/drift` `:1226-1228`. | Agregar solo `_doctor_pass`/línea informativa para los kinds nuevos; jamás `_doctor_warn`. Parser de intervalo `_wg_interval_hours` `:164-173` (lee campo HORA del cron). |
| `scripts/lib/rag_obs.sh` | `:18-24` `redact_secrets`, `:30-39` `scratch_dir` | Sin cambio. | — |
| Tests | `agentctl-local.bats:163-220` (status/doctor wiki-graph, exit 1/2/0), `:238` (all-sane 0), `heartbeatctl.bats:109-140` (status) | Los nuevos contadores no deben mover ningún exit. | Agregar casos "counts nuevos > 0 → exit 0". |

---

## 5. Heartbeat y crontab

| Pieza | Línea | Detalle |
|---|---|---|
| `scripts/heartbeat/heartbeat.sh` | `:30` `HEARTBEAT_TIMEOUT` (default 300, viene de `heartbeat.conf`); `:32` prompt default; `:35` `TRIGGER=${HEARTBEAT_TRIGGER:-cron}`; **`:37-43` parsea `--prompt` y `--trigger`** (mecanismo ya existente); `:57-59` `is_prior_session_alive` → `skipped` `:252-255` (sin notificación `:303`); `:126-172` config dir aislado `~/.claude-heartbeat`: symlinks solo `.credentials.json` y `.claude.json` `:133-137`, `settings.json` reescrito sin plugins ni hooks `:151`, `plugins/` vacío `:166`; **`:213-214` `tmux new-session -c "$WORKSPACE_DIR"` + `claude --print --dangerously-skip-permissions --permission-mode auto`** → cwd = workspace, así que `/workspace/.mcp.json` está en alcance; su aprobación depende del `.claude.json` compartido (inferencia; Fase 0 Q3). `runs.jsonl` con `trigger` `:308`, `:315`; `state.json` con `prompt` `:375` (un tick de revisión lo sobreescribe hasta el siguiente regular → `heartbeatctl status` `:371` mostraría el prompt de revisión). |
| `docker/crontab.tpl` | `:5` única línea `${HEARTBEAT_CRON} …heartbeat.sh`; renderizado por `entrypoint.sh:55-62` (`envsubst`, default `*/30`) SOLO como pre-reload; el crontab real lo escribe `heartbeatctl reload` en el boot (`start_services.sh:151`). Sync loop root `entrypoint.sh:78-103` (`cmp -s`, 15 s). |
| `heartbeatctl::cmd_reload` | `:173-331`: lee 5 claves heartbeat `:178-184`; `interval_to_cron` valida SOLO el intervalo `:187` (`docker/scripts/lib/interval.sh:14-53`, acepta `Nm`/`Nh`); `heartbeat.conf` con claves fijas `:198-210`; línea heartbeat `:224-228`; líneas 2-7 (identity `:230-236`, vault backup `:242-248`, config `:254-261`, token `:268-275`, qmd `:282-288`, wiki-graph `:294-301`) — **cada `schedule` se usa VERBATIM, sin validación de cron** (`:233`, `:245`, `:258`, `:272`, `:285`, `:298`); heredoc del crontab `:304-313`. |
| `heartbeatctl::cmd_test` | `:549-562`: `HEARTBEAT_TRIGGER=manual bash heartbeat.sh --prompt "$prompt"` — el precedente exacto de "invocación aparte con prompt propio". |
| `_mutate`/`set-prompt` | `:494-510`, `:536-547` (`_v_prompt` 1..4000 chars `:526-529`). |
| `local_schedule.sh` | `:44-47` rechaza `dom/mon/dow != *` (fallback + WARN `:73-77`); test `local-schedule.bats:63-64`. **No se toca** (entrada docker-only). |

| Qué cambia | Dónde exactamente | Patrón/precedente | Tests afectados |
|---|---|---|---|
| Octava línea de crontab (opt-in) | `cmd_reload` tras `:301`: leer `features.heartbeat.review.{enabled,schedule,prompt}` y emitir `$sched HEARTBEAT_TRIGGER=review /workspace/scripts/heartbeat/heartbeat.sh --trigger review --prompt "$(cat /workspace/scripts/heartbeat/review-prompt.txt)" >> logs/review.log 2>&1`; agregar `${review_line}` al heredoc `:304-313` | wiki-graph line `:294-301`; `cmd_test` `:559-561` | `heartbeatctl.bats:299-327` (líneas presentes/ausentes), `docker-render.bats:132-137` (crontab.tpl intacto), `heartbeat-runs-jsonl.bats:62` (`trigger`) |
| Prompt en archivo, no inline | Escribir `review-prompt.txt` en `cmd_reload` junto a `heartbeat.conf` `:196-215` (tmp+mv). Motivo: un prompt de hasta 4000 chars con comillas dentro de una línea de crontab busybox es frágil; `heartbeat.sh` NO cambia (`--prompt` ya existe `:39`). | `heartbeat.conf` `:198-215` | nuevo |
| Validación mínima del cron semanal | No existe `_v_cron`; agregar validador de 5 campos en `heartbeatctl` para la línea nueva (las otras seis siguen verbatim: no cambiar comportamiento heredado) | `_v_timeout` `:520-522` | nuevo |
| Colisión con el tick regular | `is_prior_session_alive` `:57-59`: si la revisión coincide con un tick regular, uno de los dos sale `skipped` sin notificar → el "sin pendientes" semanal no llega. Elegir minuto fuera de la rejilla `*/N` del intervalo (documentar) o gatear en `heartbeat.sh` (cambio). | — | — |
| `HEARTBEAT_TIMEOUT` | Global (`:30`, `heartbeatctl:203`); FR-032 pide <60 s pero no hay `--timeout` por invocación. Decisión de plan: aceptar el cap global o agregar `--timeout` (cambia `heartbeat.sh`). | — | `heartbeatctl.bats:247` |

`heartbeat.sh` **no necesita cambio** para una segunda entrada con `--prompt`/`--trigger` (ambos parseados en `:37-43`); sí lo necesitaría para `--timeout` por invocación o para evitar el `skipped` por colisión. Impacto en `runs.jsonl`: campo `trigger` ya existe (`:315`), valor nuevo `review`.

---

## 6. Superficie declarativa (`agent.yml`)

| Qué cambia | Dónde exactamente | Patrón/precedente | Tests afectados |
|---|---|---|---|
| Heredoc `features.heartbeat` | `setup.sh:1254-1260` (`enabled/interval/timeout/retries/default_prompt`); agregar `review: {enabled: false, schedule: "...", prompt: "..."}` | `reply_guard` `:1261-1263` | `e2e-smoke.bats:85-87` (lee solo claves existentes) |
| Heredoc `vault:` | `setup.sh:1282-1297`: `enabled/path/seed_skeleton/force_reseed/initial_sources/mcp{enabled,server}/qmd{enabled,version,schedule}/schema{frontmatter_required,log_format}`. Agregar `review: {project_days: 7, area_days: 30}` y `archive: {candidate_days: 90}`. Claves muertas: `initial_sources` `:1287`, `mcp.server` `:1290`, `schema.*` `:1295-1297` (documentar como reservadas, no retirar). | — | **`tests/schema.bats:38-50`**: compara el set EXACTO de sub-claves de `vault` en `sample-agent-with-vault.yml` (`:42-43`: `enabled force_reseed initial_sources mcp path qmd schema seed_skeleton`) → agregar `review`/`archive` a la fixture (`tests/fixtures/sample-agent-with-vault.yml:75-90`) Y a la lista `:43`, o rompe. |
| Backfill `has()` en `regenerate()` | `setup.sh:2189` inicio; precedentes exactos: 029 `:2335-2337` (`((.claude // {}) \| has("mcp_timeout_ms"))`), 036 `:2358-2362` (`((.docker // {}) \| has("channel_health_timeout_s"))`), 034 sub-clave `:2324-2329` (`(.features.voice \| has("signoff"))`). Nuevos: `((.vault // {}) \| has("review"))`, `((.vault // {}) \| has("archive"))`, `((.features.heartbeat // {}) \| has("review"))`. Sanitizado de enteros en render: molde `mcp_timeout_effective` `:2373` y `channel_health_timeout_effective` `:2380` (regex `^[0-9]{1,7}$`, inválido → default). | 029/036 | `regenerate.bats:85` (idempotente), `:104-120` (backfill qmd.version); `mcp-handshake-timeout.bats` (12) como molde de tests de backfill/saneo |
| `scripts/lib/schema.sh` | `_SCHEMA_BOOLEANS` `:65-74` → `.features.heartbeat.review.enabled`; `_SCHEMA_OPTIONAL_NONEMPTY` `:81-89` → `.features.heartbeat.review.schedule`, `.features.heartbeat.review.prompt`. **No existe validador de enteros** en schema.sh (solo required/enum/bool/nonempty) → los `*_days` se sanean en render. | `.vault.wiki_graph.enabled` `:73`, `.vault.wiki_graph.schedule` `:88` | `schema-validate.bats` (34) |
| `known_external` | `schema.bats:62-83` (placeholders) y `:129-139` (predicados). Solo si 037 agrega `{{VAR}}` derivados fuera de agent.yml (p.ej. `{{VAULT_REVIEW_PROJECT_DAYS}}` saneado antes de `render_to_file` como `CLAUDE_MCP_TIMEOUT_MS` `:2373-2374`). La línea de crontab NO es placeholder (la escribe heartbeatctl en runtime). | 029 `CLAUDE_MCP_TIMEOUT_MS` (flatten automático, sin `known_external`) | `schema.bats:52-116` |
| Wizard | `tests/helper.bash::wizard_answers` `:141-210` y `tests/e2e-smoke.bats:52-65`: **NO se tocan** si no hay prompt nuevo (FR-029). | memoria `wizard-prompt-test-touchpoints` | — |
| Fixtures | `sample-agent.yml:62-67` (vault sin `mcp/qmd/schema`, con `backup_schedule`); `sample-agent-with-vault.yml:39-44` (heartbeat), `:75-90` (vault). | — | `schema.bats:21-36` (top-level keys, no cambia) |
| ¿`schedule` con día de semana pasa validación docker? | Sí: nada valida la forma de los `schedule` en heartbeatctl (`:233-298` verbatim) ni en schema.sh (`_SCHEMA_OPTIONAL_NONEMPTY` solo no-vacío). `interval_to_cron` (`interval.sh:14-53`) aplica SOLO a `features.heartbeat.interval`. Un cron malformado llegaría a `/etc/crontabs/agent` y fallaría en silencio (log en `/workspace/claude.cron.log`, `entrypoint.sh:107`). | — | — |

---

## 7. Skeleton, delta y prosa

| Archivo | Secciones (líneas) | Toque 037 |
|---|---|---|
| `modules/vault-skeleton/CLAUDE.md` (210) | Tres capas `:9-30`; seis tipos `:32-46` (`:39` entity incluye "project"); normalization `:48-55`; **frontmatter spec `:57-74`** (bloque YAML `:61-72`: `title,type,sources,related,created,updated,status,tags`); wikilinks `:76-85`; **ingest `:87-112`** (paso 0 ack `:91`, 2.5 normalize `:98-102`, `index.md` `:109`, `log.md` `:110`); **query `:114-134`** (`:118-119` "Search the wiki first", 1.5 grafo `:120-125`, filing `:131-133`, log `:134`); **lint `:136-165`**; **capas de memoria `:167-183`** (`:173` auto-memoria "ongoing project state", `:183` "Don't double-write"); maintenance triggers `:185-195`; file naming `:197-201`; when unsure `:203-210`. | Paso 0 index-first antes de `:118`; 0.5 ingest antes de `:92`; operaciones nuevas (kickoff/close/weekly/monthly) como secciones `## Operation:`; FR-006 en `:167-183`. |
| `modules/vault-skeleton/index.md` (42) | Formato de línea `:4`; secciones `## Summaries` `:15` … `## Synthesis` `:35`, `## Normalization` `:39-42` (ejemplos en comentarios HTML: obligatorio para no romper `_wg_index_entries`). | Agregar `## Projects (active)`, `## Areas`, `## Archive`, `## Packets`, `## Favorite problems` con ejemplos SOLO dentro de `<!-- -->` o backticks. |
| `modules/vault-skeleton/log.md` (21) | **Línea de formato `:9`** `{ingest\|query\|lint\|init\|other}` (ya violada por `upgrade`); entrada init `:18`. | FR-019. |
| `_templates/*.md` | `summary/entity/concept/comparison/overview/synthesis.md` frontmatter idéntico `:1-10` (`title,type,sources,related,created,updated,status,tags`); `source.md:1-8` (`title,url,author,published,clipped,type`); `normalization.md:1-7`. | Nuevos `project.md` (`type: entity`, `para: project`) y `area.md` (`type: overview`, `para: area`); `description`/`distill` en todos. `tests/vault.bats:36-40` exige los 7 existentes (los nuevos no rompen); `:42-53` valida `type` == nombre solo para los seis (un `project.md` con `type: entity` no entra al bucle). |
| `raw_sources/README.md` (69) | Frontmatter fuente `:46-55` (`clipped:` `:52`); binarios con `.md` hermano `:57-58` (base del dominio de `pending_ingest`). | FR-010 (Grep/`search_notes`). |
| `modules/vault-deltas/schema-updates-0.8.0.md` (57) | Título `:1`; nota al agente `:3-7` (marcador oculto); "what's new" `:9-13`; secciones `## New section: …` `:17`, `## <protocol> — add step` `:25`, `:34`, `:43`, `## index.md — add …` `:51-57` con bloque markdown. | Copiar el formato para `schema-updates-0.27.0.md`; incluir la **marca de integración** que `schema_delta_pending` grepea. |
| `modules/claude-md.tpl` | Heartbeat `:80-135`; **local "Nothing" `:92`**; tabla heartbeatctl `:114-121`; **Memory `:176-193`** (`:182-183` auto-memoria `project_*`, `:193` don't double-write); Vault `:195-198`; QMD `:200-212`; Wiki graph `:214-223` (`:220` describe findings como "orphans, broken links, stubs"). | FR-006 puntero en `:182-183`; contadores nuevos en `:222`; aviso semanal docker en `:80-135`; local sin aviso en `:92`. |
| `docs/vault.md` (730) | Tabla `vault:` `:100-119` + claves opcionales `:121-126`; seeding `:128-146` (`:139-141` `vault_seed_missing`); operaciones `:173-218`; wiki-graph `:219-258` (tabla docker/local `:243-246`, `:248-253` estado); coexistencia memoria `:282-296`; QMD `:361-459` (**`:398` `collection add <vault>`**, storage `:444-452`, sentinel `:452`); pin `:488-494`; ops surface `:515-525` (**`:519` docker status sin qmd/wiki-graph**); **`:542` "Why no slash-command skill"**. | Todas las anteriores. |
| `docs/state-layout.md` | `:49` `project_<topic>.md`; `:55` MEMORY.md 200 líneas. | Puntero FR-006. |
| `README.md` | Memoria `:206-216` (`:212` vault); RAG `:218-225`. | Sección vault. |
| `CHANGELOG.md` | `:1` `# Changelog`, `:3` `## [Unreleased]`, `:5` `### Fixed` (036). | Nueva entrada `### Added` bajo `:3`. |
| `docs/heartbeatctl.md` | `:5` lista de subcomandos; `:31` status; `:183-200` data files. | `qmd-migrate`, status nuevo, `review-prompt.txt`. |
| `docs/qmd-upgrade-checklist.md` (116) | `## Checklist` `:45`. | Agregar dependencia de `collection add <vault>/wiki` y del sentinel de migración. |

---

## 8. Docker (image-baked)

| Hecho verificado | Línea |
|---|---|
| Compose build context = `./docker` **del workspace** | `modules/docker-compose.yml.tpl:8-9` |
| COPY desde `docker/` (contexto): `heartbeatctl` `:257`, `backup_vault.sh` `:261`, `qmd_index.sh` `:265`, `wiki_graph.sh` `:266`, `rag_obs.sh` `:267`, `mcp_warm.sh` `:268`, `vault.sh` `:285`, `vault-skeleton/` `:286`, `vault-deltas/` `:290`, `qmd_watch.sh` `:244`, `qmd-mcp` `:247`, `crontab.tpl` `:239` | `docker/Dockerfile` |
| En el repo del launcher `docker/scripts/lib/` trackea SOLO `backup_config.sh backup_identity.sh interval.sh plugin-install.sh state.sh token_health.sh` (`git ls-files`); `vault.sh`, `qmd_index.sh`, `wiki_graph.sh`, `rag_obs.sh`, `backup_vault.sh`, `mcp_warm.sh`, `vault-skeleton/`, `vault-deltas/` son canónicos en `scripts/lib/`+`modules/` y se **espejan al `docker/` del workspace** en scaffold/regenerate | `setup.sh::mirror_catalog_to_docker` `:1629-1690` (wiki_graph `:1667-1669`, vault-deltas `:1676-1679`, rag_obs `:1670-1672`); call sites `:1942` (scaffold), `:2701` (regenerate); guard `:1728` |
| Conclusión: 037 edita SOLO `scripts/lib/*.sh` y `modules/vault-*`; nunca crea `docker/scripts/lib/wiki_graph.sh` en el repo. Si agrega una lib nueva necesita COPY + mirror + guard (`:1728`). | memoria `docker-lib-needs-explicit-copy` |
| Tests | `docker-render.bats:333-345` (COPY + mirror de wiki_graph/vault-deltas) |
| DOCKER_E2E existentes para vault/qmd/wiki-graph: `docker-e2e-vault.bats` (2, gating `:17`), `docker-e2e-qmd.bats` (2, gating `:48`; Tier-1 stub diferido `:25-27`; wiki-graph Fase 4.5 `:236-275`; Tier-2 embed `QMD_EMBED_E2E=1` `:38`). No hay e2e específico de heartbeat con `--prompt` (`docker-e2e-heartbeat.bats` = 1 test). | — |

---

## 9. Watcher y hash

- `scripts/qmd_watch.sh:77`: `inotifywait -r -m -q -e modify,create,delete,move "$vault_dir"` — recursivo sobre el vault ENTERO, **sin `--exclude`**; debounce `QMD_WATCH_DEBOUNCE=15` `:20`, `:52`; dispara `heartbeatctl qmd-reindex` `:44`, `:59`. Cada corrida del grafo (escribe `.graph/*.json` + `.wg.*` temporales) genera eventos → reindex dispatch → `vault_hash` sin cambio → `skipped` (barato, pero es un tick por corrida; con `packets.json` un evento más). Fase 0 Q8 (`--exclude '\.graph/'` en inotify-tools de Alpine).
- `scripts/lib/backup_vault.sh::vault_hash` `:100-110` sobre `vault_list_markdown` `:86-95` (`find … -name '*.md'` con prune `:52-61`). `.graph/` queda fuera por construcción (no `.md`), `log.md`/`index.md`/`raw_sources/**.md` ENTRAN al hash.

---

## 10. Conteos de la suite (sin correrla)

`grep -c '^@test' tests/*.bats` → **1502 tests en 129 archivos**. Por archivo que 037 toca o re-baselinea:

| Archivo | @test | Archivo | @test |
|---|---|---|---|
| wiki-graph | 19 | vault | 24 |
| vault-upgrade | 10 | local-vault-seed | 7 |
| qmd-index | 11 | qmd-setup | 8 |
| qmd-reindex-cmd | 10 | qmd-embed-completion | 13 |
| qmd-invocation | 8 | qmd-sqlite-vec | 7 |
| qmd-version-guard | 3 | qmd-watch | 4 |
| local-qmd | 15 | local-wiki-graph | 7 |
| start-services-qmd | 4 | schema | 5 |
| schema-validate | 34 | docker-render | 43 |
| local-render | 31 | heartbeatctl | 34 |
| heartbeat-runs-jsonl | 5 | heartbeat-isolation | 11 |
| agentctl | 25 | agentctl-local | 50 |
| regenerate | 16 | local-schedule | 17 |
| docker-e2e-qmd | 2 | docker-e2e-vault | 2 |
| docker-e2e-heartbeat | 1 | docker-e2e-* (12 archivos) | 40 |

Línea base de referencia declarada en CLAUDE.md del repo para 034: 1368/0; hoy el conteo estático es 1502 (035/036 sumaron tests). No se corrió `bats tests/`.

---

## Riesgos de implementación detectados

1. **`vault.seed_skeleton: false` apaga los deltas.** `start_services.sh:108` y `setup.sh:2824` cortan antes de `vault_seed_missing` (`:132-135`, `:2841-2844`). Un agente que desactivó el seed no recibe 0.8.0 ni 0.27.0. La spec (US7) asume entrega universal.
2. **`changed` compartido en `vault_seed_missing`.** Si el bloque 0.27.0 reutiliza `changed` (`vault.sh:76`) y corre antes del check 0.8.0 (`:100`), un vault sembrado con el skeleton 0.8.0 y wiki vacía recibe el delta 0.8.0 espurio. Bloques independientes, 0.8.0 primero.
3. **Marcador 0.8.0 vacío → edad solo por mtime** (`vault.sh:103`). Para `schema_delta_pending` el 0.27.0 debe escribir la fecha dentro del marcador; `cp -R` (migración documentada) no preserva mtime.
4. **`N` record y jq posicionales** (`wiki_graph.sh:170`, `:506`): agregar columnas exige tocar ambos en el mismo orden; un desfase corrompe `type/status` en silencio y cambia los 7 findings del oráculo.
5. **`para` en `SRCN`** (`:178`): la supresión de `stale` para archive necesita la columna o un filtro en bash `:439`; en jq no basta (stale llega como lista ya calculada `:512`).
6. **Sin `TODAY` en el runner** (`:93`, `:367`, `:458`): introducir `WIKI_GRAPH_TODAY` y usarlo en TODAS las comparaciones nuevas; `_wg_date_epoch` es portable pero `date -d` en busybox acepta `YYYY-MM-DD` — verificar en Alpine (Fase 0).
7. **Detección de "colección heredada" sin parsear al vendor**: solo es determinista si el sentinel se escribe en `_qmd_setup_locked` a partir de 037 (`:397`); agentes 037+ recién scaffoldeados con `index.sqlite` pero sin sentinel (setup interrumpido `:383-384`) leerían "pendiente" hasta que el setup complete — aceptable pero documentar.
8. **`collection remove` no está en el contrato de 010** (`qmd-cli.md:23` solo `add`) ni en los tests; el stub del seam no lo conoce (`helper.bash:98-102`). Fase 0 Q1 es bloqueante para `qmd-migrate`.
9. **Setups de test qmd sin `wiki/`** (`qmd-setup.bats:18-19`, `qmd-index.bats:18-19`): con raíz `wiki/`, el `collection add` grabado apuntará a `$QMD_VAULT_DIR/wiki` inexistente; el stub no falla, pero cualquier aserción nueva de ruta debe crear el subdir.
10. **`schema.bats:42-43` rompe al agregar sub-claves a `vault:`** (set exacto). Es un touchpoint obligatorio, no opcional.
11. **Colisión heartbeat regular vs semanal** (`heartbeat.sh:57-59`, `:252-255`, `:303`): el perdedor sale `skipped` SIN notificar; el "sin pendientes" semanal puede perderse. Elegir minuto fuera de la rejilla `*/N` o cambiar `heartbeat.sh`.
12. **`state.json.prompt` y `counters` se mezclan** entre ticks regular y de revisión (`heartbeat.sh:330-342`, `:375`); `heartbeatctl status` `:371` mostrará el último prompt que corrió. Cosmético pero visible.
13. **Ningún validador de cron para `schedule`s** en heartbeatctl (`:233-298` verbatim) ni schema.sh; un `features.heartbeat.review.schedule` malformado llega al crontab y falla en silencio.
14. **`HEARTBEAT_TIMEOUT` global** (`heartbeat.sh:30`): FR-032 "< 1 min" no es exigible por config sin `--timeout` por invocación.
15. **`vault_hash` compartido con backup** (`backup_vault.sh:100`): el debounce del reindex seguirá disparando `update` por `log.md`/`index.md`; cambiar el hash altera el backup. Aceptar.
16. **Watcher sin exclusión de `.graph/`** (`qmd_watch.sh:77`): cada corrida del grafo dispara un dispatch de reindex (queda en `skipped`); `packets.json` agrega un evento.
17. **Drift documental en el contrato 014** (`graph-artifacts.md:31-33` muestra `title`/`tags` en nodos que el código no emite): 037 extrae `tags` y debe alinear contrato y código.

## Preguntas que el plan debe resolver

1. ¿Días de atraso (`review_due`/`project_overdue`) en bash (molde `_wg_compute_stale`) o en jq (`strptime/mktime`)? Depende de la disponibilidad de `strptime` en el jq de Alpine 3.24 (Fase 0).
2. ¿Cómo se resuelve `problems: [fp-3]` a un nodo? ¿Slug fijo `synthesis/favorite-problems` o wikilink obligatorio? (Afecta FR-004 y el `orphan` de esa página.)
3. ¿`schema_delta_pending` mide edad por fecha dentro del marcador 0.27.0 o por mtime? (Riesgo 3.)
4. ¿Qué hacer con `vault.seed_skeleton: false` respecto a los deltas? (Riesgo 1: ¿documentar, o desacoplar el upgrade del seed en 037?)
5. ¿Verbo real de qmd 2.5.3 para retirar la colección y si reutiliza embeddings por hash (Fase 0 Q1/Q13)? Sin esto `qmd-migrate` no se puede especificar.
6. ¿Prompt de revisión en archivo `review-prompt.txt` (sin tocar `heartbeat.sh`) o `--prompt` inline en el crontab? ¿Y `--timeout` por invocación (toca `heartbeat.sh`)?
7. ¿Cómo evitar el `skipped` por colisión del tick semanal con el regular: restricción documentada del minuto, o cambio en `heartbeat.sh`?
8. ¿`description_missing` gateado por `created ≥ fecha del delta`: de dónde sale esa fecha en el runner (marcador con fecha, o `WIKI_GRAPH_TODAY` del primer boot)?
9. ¿Los contadores nuevos entran al `counts` por defecto de `wiki_graph_write_state` `:94` (error path) y al string de `agentctl:1141`, y `heartbeatctl status` los imprime todos o solo los de la cola de revisión?
10. ¿La sesión del heartbeat carga `/workspace/.mcp.json` (cwd = workspace, `.claude.json` compartido) — Fase 0 Q3? Si no, el prompt lee `findings.json` por ruta con `Read`.
