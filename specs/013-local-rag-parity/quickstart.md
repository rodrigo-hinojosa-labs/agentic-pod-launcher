# Quickstart: 013-local-rag-parity — gates de verificación

## Gate 1 — Suite host (obligatorio, cada fase)

```bash
bats tests/                      # completa, sin Docker
shellcheck -S error setup.sh scripts/agentctl scripts/lib/*.sh scripts/*.sh
```

Verde total; test-first: los tests de cada contrato se escriben ANTES de su implementación.

## Gate 2 — DOCKER_E2E (obligatorio: FR-015 toca lib espejada, FR-016 toca Dockerfile)

```bash
DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats      # incluye la nueva aserción bunx en imagen real
DOCKER_E2E=1 bats tests/docker-e2e-vault.bats
DOCKER_E2E=1 bats tests/docker-e2e-smoke.bats    # flaky conocido en 1er boot — reintentar aislado
```

## Gate 3 — Byte-identidad docker (test, no manual)

Render en modo docker de `.mcp.json` y de las units locales NO tocadas == contrato v0.6.0 (el bloque qmd conserva `"env": {}` exacto).

## Gate 4 — mclaren (manual, confirmatorio; cuando el host vuelva)

Workspace `mclaren-admin` (RPi5, Debian trixie, arm64), rama del launcher con 013:

1. `vault.enabled=true`, `vault.qmd.enabled=true` en `agent.yml` → `./setup.sh --regenerate` → `./setup.sh --login` (o units ya instaladas).
2. **Storage correcto**: `ls <ws>/.state/.cache/qmd/` muestra `index.sqlite` + `models/`; `~/.cache/qmd` NO crece (los tres fallos predichos por la auditoría — timer sin bunx, watcher failed <35s, índice en `~/.cache` — deben estar corregidos).
3. **Refresco**: `systemctl is-active agent-mclaren-admin-qmd-watch.service` = active sostenido >5 min; editar un `.md` del vault → journal del reindex en ~15s; `systemctl list-timers 'agent-mclaren-admin-*'` muestra reindex + backup + healthcheck.
4. **MCP**: `claude mcp list` (config dir del workspace) → `vault` y `qmd` Connected; una búsqueda qmd devuelve contenido del vault.
5. **Operabilidad**: `agentctl status` muestra last_run; simular error (renombrar bunx) → `agentctl doctor` warn + exit ≥1; `agentctl heartbeat qmd-reindex` ejecuta; kill switch → las 5 units detenidas, sin push al fork en la siguiente hora; restaurar.
6. **Backup**: con fork configurado, `agentctl heartbeat backup-vault` → rama `backup/vault` actualizada.

## Gate 5 — ferrari (manual, post-merge; valida FR-016 en docker real)

Workspace `rodri-cenco-admin` (RPi5 ferrari, modo docker, QMD hoy OFF):

1. Actualizar launcher assets del workspace a la versión con 013 → `yq -i '.vault.qmd.enabled = true' agent.yml` → `./setup.sh --regenerate`.
2. `docker compose build` (la imagen nueva trae `bunx`) → `./scripts/agentctl up`.
3. `docker exec -u agent <c> command -v bunx` → `/usr/local/bin/bunx`; primer boot indexa (background, minutos); `claude mcp list` → qmd Connected; editar nota vía Obsidian/Syncthing → reindex (watcher inotify nativo en la Pi).

## Registro

Resultados de gates 4 y 5 → CHANGELOG (si ajustan algo) y cierre de tasks; si mclaren sigue caído al momento del PR, el gate queda documentado como pendiente confirmatorio (criterio 011/012).
