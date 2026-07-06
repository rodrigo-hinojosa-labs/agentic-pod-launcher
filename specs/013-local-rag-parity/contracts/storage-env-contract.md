# Contract: storage-env (US1 — FR-001/002/003/004)

El índice RAG local vive en el workspace y escritor/lector lo resuelven idéntico. Evidencia base: tarball `@tobilu/qmd@2.5.3` (`store.js:420-435`, `llm.js:119-121`, `collections.js:59-65`, `cli/qmd.js:3149-3151`).

## Escritor (modules/local-qmd-reindex.sh.tpl)

- DEBE exportar, junto al `QMD_CACHE_HOME` existente (que NO se elimina):
  - `XDG_CACHE_HOME="${WORKSPACE}/.state/.cache"`
  - `QMD_CONFIG_DIR="${WORKSPACE}/.state/.config/qmd"`
- Postcondición: `${XDG_CACHE_HOME}/qmd` == `${QMD_CACHE_HOME}` (convergencia lib↔binario); sentinel/lock/chequeo `index.sqlite` de la lib observan el directorio donde el binario escribe (FR-003 — sin cambios en la lib: la convergencia la produce el env).
- `mkdir -p` de ambos roots antes de sourcear la lib.

## Lector (modules/mcp-json.tpl + setup.sh)

- `setup.sh` DEBE exportar `QMD_MCP_ENV` antes del render:
  - docker: exactamente `{}` (dos chars) → render byte-idéntico a v0.6.0.
  - local: JSON de una línea `{"XDG_CACHE_HOME":"<ws>/.state/.cache","QMD_CONFIG_DIR":"<ws>/.state/.config/qmd"}`.
- El bloque qmd renderiza `"env": {{QMD_MCP_ENV}}`. Sin `{{#if}}` anidado.
- Atomicidad (FR-001): escritor y lector cambian en el mismo commit; PROHIBIDO mergear uno sin el otro (un lado solo ⇒ qmd auto-crea sqlite vacío para el lector — RAG vacío silencioso).

## Uninstall (setup.sh — FR-004)

- `--purge`/`--nuke` en local: el storage qmd cae con el workspace (ya dentro); ADEMÁS remover `~/.cache/agent-backup/vault-clone` (R12). Nunca tocar `~/.cache/qmd` / `~/.config/qmd` legacy (limpieza manual documentada en CHANGELOG).

## Tests (test-first)

1. Render local del entrypoint contiene los 3 exports (`XDG_CACHE_HOME`, `QMD_CONFIG_DIR`, `QMD_CACHE_HOME`) con los valores del workspace.
2. Render local de `.mcp.json`: bloque qmd con `env` conteniendo ambas claves y valores `<ws>/...`.
3. Render docker de `.mcp.json`: **byte-idéntico** al fixture v0.6.0 (`"env": {}`).
4. `schema.bats`: `QMD_MCP_ENV` en AMBAS listas `known_external`.
5. Uninstall local con `--purge`: stub de `$HOME` verifica remoción de `agent-backup/vault-clone` y NO-remoción de `~/.cache/qmd`.
6. Migración simulada (SC-002, analyze G4): `cp -a` del workspace stubbeado (sentinel + índice fake) a otra ruta → `qmd_setup_if_needed` es no-op por sentinel-hit en el destino; sin paths absolutos del origen embebidos en el estado.
