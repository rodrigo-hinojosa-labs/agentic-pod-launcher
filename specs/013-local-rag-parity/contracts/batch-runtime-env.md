# Contract: batch-runtime-env (US2 — FR-005/006/007/015)

Los contextos batch locales (timer reindex, watcher, backup, dispatch de `--login`, ejecución manual) corren con el entorno completo que las libs necesitan.

## PATH (FR-005 — los 3 wrappers)

- Primera acción ejecutable de `local-qmd-reindex.sh.tpl`, `local-qmd-watch.sh.tpl`, `local-vault-backup.sh.tpl`:
  `export PATH="{{OPERATOR_HOME}}/.local/bin:{{DEPLOYMENT_WORKSPACE}}/scripts/vendor/bin:$PATH"`
- Garantiza: `bunx` (bootstrap 011 → `~/.local/bin`), `yq` v4 (vendorado → `scripts/vendor/bin`). Las units NO cambian (el wrapper se auto-provee en cualquier contexto de invocación).

## Env del watcher (FR-006)

- `local-qmd-watch.sh.tpl` DEBE exportar además:
  - `QMD_VAULT_DIR="{{LOCAL_VAULT_DIR}}"`
  - `VAULT_ROOT_OVERRIDE="{{LOCAL_VAULT_DIR}}"`
- Postcondición: watcher, reindex y backup triangulan el MISMO vault (`<ws>/<vault.path>`); `/home/agent/.vault` no aparece en ningún camino local.

## Loop supervisado (FR-007 — Clarify Q1)

- El wrapper reemplaza `exec bash qmd_watch.sh` por:
  `while :; do bash "${WORKSPACE}/scripts/qmd_watch.sh"; sleep 30; done`
- La unit `local-qmd-watch.service.tpl` NO cambia: conserva `ExecCondition=command -v inotifywait` (degradación limpia: sin inotify-tools la unit queda inactive y el loop nunca arranca) y `Restart=always`/`RestartSec=2` como cinturón si el loop muere.
- Postcondición: N salidas de `qmd_watch.sh` en ventana corta ⇒ la unit sigue `active`; `failed` = anomalía real (señal para FR-011).

## Flock del setup (FR-015 — Clarify Q3; lib espejada ⇒ DOCKER_E2E)

- `qmd_setup_if_needed` (scripts/lib/qmd_index.sh) serializa su cuerpo efectivo con `flock -n` sobre `$cache_root/.reindex.lock` (el mismo del reindex). Perdedor: log + return 0 (el guard del próximo tick reintenta). Sentinel-hit sigue siendo no-op instantáneo sin tomar el lock.
- Guards `BASH_SOURCE` intactos; `shellcheck -S error` limpio; espejo a `docker/` vía mecanismo estándar (sin edición manual bajo `docker/scripts/lib/`).

## Tests (test-first)

1. Render de cada wrapper: `export PATH=` presente con ambos prefijos, ANTES de cualquier invocación de yq/bunx/source de lib.
2. bats con PATH mínimo estilo systemd (`/usr/bin:/bin`) + stubs de bunx/yq en `$HOME/.local/bin` y `vendor/bin`: el entrypoint los resuelve.
3. Render del watcher: exports `QMD_VAULT_DIR`/`VAULT_ROOT_OVERRIDE` + loop `while :` presente; `exec bash` ausente.
4. Watcher stub que sale inmediatamente: el wrapper reintenta (observar ≥2 invocaciones con sleep stubbeado) sin propagar exit≠0.
5. Flock: dos `qmd_setup_if_needed` concurrentes (bunx stub lento) ⇒ una sola descarga/registro; perdedor exit 0.
6. Unit render sin cambios vs v0.6.0 (byte-idéntico) para `local-qmd-watch.service`.
