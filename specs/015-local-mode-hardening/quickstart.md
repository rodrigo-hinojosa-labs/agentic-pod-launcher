# Quickstart: gate confirmatorio 015 en hardware

Valida que los cuatro fixes convergen los hosts parcheados-a-mano al código del
launcher vía `--regenerate`/rebuild limpios. Los parches de host aplicados el
2026-07-08 (mclaren `claude_cli` absoluto + bun glibc; ferrari `/tmp` 512m) son la
**referencia de comportamiento esperado**, no la solución.

Acceso a los hosts: túneles Cloudflare `ssh ssh-mclaren` / `ssh ssh-ferrari` (NO las
IP LAN). Corre `--regenerate` local SIEMPRE con login shell:
`ssh <host> 'bash -lc "…"'` (para que `command -v claude`/`bun` resuelvan `~/.local/bin`).

## Gate host (pre-hardware, obligatorio antes de tocar los hosts)

```bash
bats tests/                                  # suite completa host, verde
shellcheck -S error scripts/lib/*.sh modules/*.tpl setup.sh
DOCKER_E2E=1 bats tests/docker-e2e-heartbeat.bats   # runtime docker de US3/US4
```

Criterio: SC-006 — host verde, shellcheck limpio, DOCKER_E2E verde.

## Gate mclaren (local, glibc) — US1 + US2

Overlay del launcher v0.9.0 al workspace preservando `agent.yml`/`.env`/`.state`,
luego:

1. **US1 — unit del agente tras `--regenerate` limpio**:
   ```bash
   ssh ssh-mclaren 'bash -lc "cd <ws> && ./setup.sh --regenerate"'
   # Verificar el ExecStart renderizado
   ssh ssh-mclaren 'grep ExecStart <ws>/agent-*.service /etc/systemd/system/agent-*.service'
   ```
   - Esperado: `ExecStart=/home/rodrigo-hinojosa/.local/bin/claude remote-control …`
     (ruta **absoluta**, no `claude` pelado). `agent.yml.deployment.claude_cli` absoluta.
   - Reiniciar la unit y confirmar **sin `203/EXEC`** (SC-001):
     `systemctl status agent-mclaren-admin.service` → `active (running)`.
   - Regresión negativa: borrar temporalmente `~/.local/bin` del PATH y re-regenerar
     → la unit sigue absoluta (no degrada al literal).

2. **US2 — bun glibc idempotente**:
   ```bash
   ssh ssh-mclaren 'bash -lc "bun --version && bunx --version"'   # rc 0 (SC-002)
   ssh ssh-mclaren 'bash -lc "cd <ws> && ./scripts/local/agent-bootstrap.sh"'  # re-run
   ```
   - Esperado: `bun --version` ejecuta; re-correr el bootstrap es no-op (no re-baja,
     no reintroduce musl). qmd reindexa (cache/sqlite bajo `.state/.cache/qmd`).

## Gate ferrari (docker, musl) — US3 + US4

Overlay v0.9.0 + `--regenerate` (espeja libs a docker) + `docker compose build` +
`up -d` (recreate; `.state` preserva vault+OAuth+Telegram).

3. **US3 — wiki-graph sin ENOSPC sobre 2696 páginas** (SC-003):
   ```bash
   ssh ssh-ferrari 'docker exec -u agent <ctr> heartbeatctl wiki-graph'
   ssh ssh-ferrari 'docker exec -u agent <ctr> cat <vault>/.graph/graph.json | jq .nodes'
   ```
   - Esperado: `last_status: ok`; `.graph/*.json` con conteos reales (nodes ~2696).
   - Verificar que `/tmp` (tmpfs) NO se llenó: el cache de bunx vive bajo `.state`
     (host-backed), no en `/tmp`.
   - **Verificación negativa (SC-004)**: llenar `/tmp` a mano y correr `wiki-graph`
     → el runner completa igual (TMPDIR host-backed) Y ante un fallo de infra el
     `wiki-graph.json.error` trae el mensaje real, no `jq aggregation failed`.

4. **US4 — observabilidad del reindex** (parte en alcance):
   ```bash
   ssh ssh-ferrari 'docker exec -u agent <ctr> heartbeatctl qmd-reindex'
   ssh ssh-ferrari 'docker exec -u agent <ctr> cat <ws>/scripts/heartbeat/logs/qmd-reindex.log'
   ```
   - Esperado (en alcance): si falla, el **stderr real de qmd** es visible en el log
     y el env efectivo (cache root, config dir, TMPDIR, colección) está registrado;
     sin secretos en claro.
   - **Gate deferido (SC-005/G1)**: el índice construido (`index.sqlite` presente,
     `ok` equivalente al binario) es la validación de causa raíz — se cierra cuando
     el env efectivo registrado revele el mismatch y se aplique el fix.

## Seguridad del gate

- Nunca leer/mostrar `.env`/`.credentials.json`/`remote-control.env`.
- Redactar `sk-ant-[A-Za-z0-9_-]+` en cualquier salida.
- Los secretos de estos agentes siguen comprometidos (rotación pendiente del usuario).

## Criterios de salida

| Criterio | Host | Estado |
|----------|------|--------|
| SC-001 unit sin 203/EXEC | mclaren | pendiente |
| SC-002 bun glibc ejecuta | mclaren | pendiente |
| SC-003 wiki-graph ok 2696 | ferrari | pendiente |
| SC-004 error de infra legible | ferrari | pendiente |
| SC-005 índice qmd construido | ferrari | deferido (root-cause) |
| SC-006 host+DOCKER_E2E verde | CI/host | gate previo |
