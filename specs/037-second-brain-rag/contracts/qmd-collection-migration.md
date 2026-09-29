# Contract: alcance `wiki/` de la colección qmd y migración automática única

Norma para `scripts/lib/qmd_index.sh` (image-baked por COPY vía el `docker/` del workspace),
`docker/scripts/heartbeatctl`, `scripts/agentctl`, `modules/local-qmd-reindex.sh.tpl`, el seam de tests de
019 y los DOCKER_E2E de qmd. Toda afirmación sobre qmd 2.5.3 está **medida** el 26-09-2026 en
`discovery/L-qmd-measurements.md` (host macOS; superficie del CLI byte-idéntica en la imagen Alpine;
operaciones sqlite en musl cubiertas por el arnés DOCKER_E2E de 016/017/018). Decisiones del operador:
alcance `wiki/` (2026-09-26) y disparo automático una vez (2026-09-27).

## 1. Hechos de qmd 2.5.3 que fijan el diseño

| Hecho [H] | Consecuencia |
|---|---|
| `collection add <path> [--name N] [--mask GLOB]` es toda la superficie; **flags desconocidos se ignoran en silencio** (`--ignore` "acepta" y no hace nada) | Ningún test puede asertar por `rc`; se aserta sobre los argumentos grabados por el stub y, en DOCKER_E2E, sobre `qmd ls vault` |
| `--mask` es un string; `wiki/**/*.md` sobre la raíz del vault indexa exactamente las páginas de `wiki/` y conserva las URIs `qmd://vault/wiki/...` | La colección mantiene `path=<vault>`; solo cambia la máscara. Ninguna URI citada por el agente cambia |
| `collection remove <name>` (alias `rm`) borra `documents` y `content` huérfano; **no toca `content_vectors`** | `remove` + `add` reutiliza embeddings |
| `getPendingEmbeddingDocs` cruza por hash de contenido + modelo + fingerprint | Tras `add`, `qmd embed` responde `All content hashes already have embeddings` (0,1 s); `status` sin `Pending` |
| `qmd cleanup` purga vectores huérfanos y hace `VACUUM`; solo `cleanup` o `embed -f` destruyen vectores | `cleanup` va **después** del `add`, nunca entre `remove` y `add` |
| `qmd status` "Vectors: N embedded" cuenta huérfanos | La métrica honesta post-migración es la ausencia de `Pending` y la salida de `qmd embed` |
| El binario honra `XDG_CACHE_HOME` y `QMD_CONFIG_DIR`, no `QMD_CACHE_HOME`; índice en `$XDG_CACHE_HOME/qmd/index.sqlite` (WAL: `-shm`/`-wal`) | El cache root real es `.state/.cache/qmd/` en ambos modos (`qmd_index.sh:62`; `local-qmd-reindex.sh.tpl:39-41`): ahí va el sentinel |
| Un cambio solo de frontmatter cambia el hash → `1 updated` + re-embed de ese documento | Sin mitigación de `updated:`; evitar reescrituras masivas |
| MCP `query` acepta `collections: string[]`; `includeByDefault` gobierna el scope por defecto | No se necesita segunda colección; queda como opción futura para `raw` |

## 2. Cambios en `scripts/lib/qmd_index.sh`

| Función | Cambio |
|---|---|
| `_qmd_setup_locked` `:357-400` | `:379`: `collection add "$vault_dir" --name "$coll" --mask 'wiki/**/*.md'`; el **sentinel de layout** `$(qmd_cache_root)/.qmd-collection-wiki` (contenido `wiki-root <TODAY>`) se escribe SOLO dentro de la rama `if [ ! -f "$cache_root/index.sqlite" ]` (`:377-382`), inmediatamente después de un `collection add` exitoso y antes de `update`. La rama re-entrante `:383-385` (índice presente, `.qmd-setup-ok` ausente) NO lo escribe: ese índice puede ser heredado con máscara `**/*.md` y debe migrar en el primer tick (refutación N C6). Scaffold nuevo nace en `wiki-root`, sin migración |
| `qmd_collection_migration_state` (nueva, lector puro, molde `qmd_last_hash` `:270-274`) | Devuelve `n/a` (sin `index.sqlite`), `pending` (`index.sqlite` presente y sentinel ausente) o `done` (sentinel presente). Determinista, sin parsear el YAML del vendor |
| `qmd_migrate_collection` (nueva) | Bajo el mismo `.reindex.lock` `:334`. Pasos: (1) `collection remove vault` (rc≠0 tolerado si la colección no existe); (2) `collection add "$vault_dir" --name vault --mask 'wiki/**/*.md'`; (3) `update`; (4) escribir sentinel; (5) `cleanup`; (6) `embed` **solo si** `status` reporta `Pending` (loop de 018). Cada paso con `_qmd_run` (timeout `QMD_CMD_TIMEOUT`), stderr redactado a scratch (US4 de 015), y una línea de log `qmd: collection migrated to wiki scope (<n> docs)`. Con `--dry-run`: imprime los seis pasos y el estado actual, no ejecuta nada |
| `_qmd_reindex_locked` `:529-566` | Antes del guard de hash `:538`: `if [ "$(qmd_collection_migration_state)" = pending ]; then qmd_migrate_collection; fi`. Es el **disparo automático**: el primer tick de reindex (cron `*/5` o watcher) tras la actualización migra; el guard `vault unchanged → skip` no lo bloquea porque la migración va antes |
| `qmd_write_state` `:286-313` | `qmd-index.json` gana `collection_layout: "vault-root"\|"wiki-root"\|"none"` y `migration: "pending"\|"done"\|"n/a"` (`none`/`n/a` cuando no hay `index.sqlite`, para que `status` nunca imprima vacío); ambos se calculan dentro de `qmd_write_state` llamando a `qmd_collection_migration_state` (el JSON se reconstruye completo en cada escritura, `:305-307`), también en el path de error |

Orden dentro del tick: migración (si pendiente) → hash → `update` → embed loop. La migración escribe el
sentinel **al final** de su paso 4 para que una interrupción entre `remove` y `add` deje `pending` (el
siguiente tick la reintenta: `remove` sobre colección inexistente es tolerado, `add` recrea).

**Fallo a mitad** (M U1): si cualquier paso de `qmd_migrate_collection` falla, el tick termina ahí con
`qmd_write_state … error` (hash del vault NO actualizado, `migration: pending`, `collection_layout` según
lo que exista en disco) y rc 0 (Principio IV); no continúa a `update`/embed sobre una colección inexistente;
el siguiente tick reintenta desde `remove`. El nombre de la función de estado es
`qmd_collection_migration_state` (devuelve `n/a`/`pending`/`done`); el layout se deriva de ella
(`n/a` → `none`, `pending` → `vault-root`, `done` → `wiki-root`) en `qmd_write_state`.

Caso borde documentado: scaffold 037+ con setup interrumpido entre `:383-384` (`index.sqlite` creado,
sentinel aún no) → el siguiente tick lee `pending` y "migra" una colección que ya tenía alcance `wiki/`
(remove+add idénticos, segundos, embeddings intactos) → sentinel → `done`. Inocuo e idempotente.

## 3. Acción manual

| Modo | Superficie | Comportamiento |
|---|---|---|
| docker | `heartbeatctl qmd-migrate [--dry-run\|--force]` (molde `cmd_qmd_reindex` `:948-975` + `_qmd_reindex_dry` `:978-996`; dispatch `main()` `:1056`; help `:121-130`) | Sin flags: **idempotente** — con sentinel presente informa `already migrated` y sale 0 sin tocar qmd; con `pending` migra. `--dry-run`: estado + pasos, sin cambios. `--force`: recrea aunque exista el sentinel (misma máscara; útil tras un `cleanup` manual o para reparar) (M I3) |
| local | `agentctl heartbeat qmd-migrate [--dry-run\|--force]` → wrapper `agent-qmd-reindex.sh --migrate [--dry-run\|--force]`, despachado **antes** de `qmd_setup_if_needed` (`local-qmd-reindex.sh.tpl:51`; si fuera tras `:52-54` como `--setup-only`, un dry-run sin índice ejecutaría el setup real y descargaría el modelo, N C10). Oráculo: con `--migrate --dry-run` el log del stub no contiene `collection add` ni `embed` | idem |
| ambos | `status` muestra `qmd index: <status> pending=<n> collection=<layout> migration=<state>` con layout/migración **calculados en vivo** (`qmd_collection_migration_state` sobre sentinel + `index.sqlite`; `heartbeatctl` ya carga `qmd_index.sh` `:47-50`, `agentctl` local ya mira `.state/.cache/qmd/index.sqlite` `:1118`), no solo leídos del state, para que `pending` sea visible antes del primer tick (M U2); `doctor` local informa, no degrada; `doctor` docker remite a `heartbeatctl status` (FR-009) | — |

## 4. Seam de tests (019) — extensión

`tests/helper.bash::install_qmd_stub` (`:93-106`) graba `$@` en un log; hoy solo crea `index.sqlite` ante
`collection`. Extensión: ante `collection remove` borra un marcador `collections/<name>` del stub; ante
`collection add` lo crea; ante `cleanup` incrementa un contador; ante `status` imprime `Pending: 0` (o el
valor de `QMD_STUB_PENDING`); ante `ls` imprime rutas `wiki/...`. Los tests asertan sobre el log de
argumentos: **`--mask 'wiki/**/*.md'` presente**, orden `remove → add → update → cleanup`, `cleanup`
después del `add`, `embed` ausente cuando `Pending: 0`.

Los setups de `qmd-setup.bats:15-33` y `qmd-index.bats:14-33` crean `$QMD_VAULT_DIR/wiki/` (la raíz de la
colección sigue siendo `$QMD_VAULT_DIR`, pero el stub de `ls` y las aserciones de rutas lo necesitan).

## 5. Oráculos

| Oráculo | Dónde |
|---|---|
| Scaffold nuevo: `collection add <vault> --name vault --mask 'wiki/**/*.md'` grabado; sentinel presente; `migration: n/a → done` sin pasar por `pending` | `qmd-setup.bats` |
| Setup re-entrante (`index.sqlite` pre-sembrado, `.qmd-setup-ok` ausente): `qmd_setup_if_needed` hace `update`/`embed` pero NO crea `.qmd-collection-wiki`; el estado queda `pending` y el primer `_qmd_reindex_locked` migra | `qmd-setup.bats` |
| Índice heredado (fixture con `index.sqlite` y sin sentinel): primer `_qmd_reindex_locked` graba `remove`, `add … --mask 'wiki/**/*.md'`, `update`, escribe sentinel, luego `cleanup`; `embed` ausente con `Pending: 0`; `qmd-index.json.migration == done`; segundo tick no repite nada | `qmd-index.bats` (nuevo caso) |
| Interrupción simulada tras `remove` (stub falla en `add` una vez): sentinel ausente, `migration: pending`, el siguiente tick completa | `qmd-index.bats` |
| `qmd-migrate --dry-run` no toca `index.sqlite` ni el sentinel y lista los pasos | `qmd-reindex-cmd.bats` (docker), `agentctl-local.bats` (local) |
| `status` docker y local muestran `collection=` y `migration=`; `doctor` exit sin cambio | `heartbeatctl.bats`, `agentctl-local.bats` |
| DOCKER_E2E (arnés de `docker-e2e-qmd.bats`, Tier-1 des-diferido por FR-035): vault con 23 `.md` como el lab de L → tras el boot `qmd ls vault` lista solo `wiki/...`; `qmd embed` → `All content hashes already have embeddings` tras una migración desde una colección heredada pre-sembrada; `status` sin `Pending`; `qmd search <token de plantilla>` vacío | `tests/docker-e2e-qmd.bats` |
| Docs: `docs/vault.md:398` (`collection add <vault>` → máscara `wiki/**/*.md`), `:444-452` (sentinel de layout), `docs/heartbeatctl.md` (`qmd-migrate`), `docs/qmd-upgrade-checklist.md` (la máscara y el sentinel como dependencias del pin), `specs/010…/contracts/qmd-cli.md:23` (nota de superación) | revisión |

## 6. Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| El servidor MCP `qmd` vivo en la sesión del agente lee el mismo `index.sqlite` mientras `remove`+`add` reescriben `documents` | sqlite en WAL tolera lectores concurrentes; la ventana es de segundos; el MCP no cachea colecciones ([NV] medido solo el CLI). Si una consulta cae en la ventana devuelve menos resultados una vez. Documentado en quickstart |
| `cleanup` corrido antes del `add` (error de orden) destruye los vectores y provoca el re-embed de 85 min en ferrari | Orden fijado en la lib y en el oráculo de tests (`cleanup` después de `add`); el `--dry-run` imprime el orden |
| Flags desconocidos ignorados en silencio | Aserciones sobre argumentos grabados y sobre `qmd ls` en e2e; nunca sobre `rc` |
| `vault_hash` (compartido con backup) sigue incluyendo `log.md`/`index.md`/`raw_sources` | Se acepta el `update` extra por sesión (barato); no se toca el hash (rompería el backup) |
| `qmd_watch.sh:77` sin `--exclude` sobre `.graph/` | Fuera de este contrato; ver research (Q8 medido: `--exclude` existe en Alpine) y tasks (opcional) |
