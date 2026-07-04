# Quickstart: Gate manual Linux — Vault + RAG en modo local (012)

Host objetivo: mclaren (Raspberry Pi 5, Debian trixie, arm64) u otro Linux/systemd. Prerrequisito: agente local 011 operativo (sesión Remote Control activa) o workspace de prueba nuevo.

## 1. Habilitar vault+qmd y regenerar

```bash
cd <workspace>
yq -i '.vault.enabled=true | .vault.seed_skeleton=true | .vault.mcp.enabled=true | .vault.qmd.enabled=true' agent.yml
./setup.sh --regenerate
```

Verificar:

```bash
ls .state/.vault/index.md .state/.vault/wiki            # (a) skeleton sembrado
jq -r '.mcpServers.vault.args[-1]' .mcp.json             # → <ws>/.state/.vault (no /home/agent)
ls scripts/local/agent-qmd-reindex.sh scripts/local/agent-vault-backup.sh
```

## 2. Instalar units (vía login helper o sudo directo)

```bash
./setup.sh --login        # instala/habilita units staged + dispara setup qmd en background
systemctl list-timers 'agent-*'                          # (c) reindex + backup timers
systemctl is-active agent-<name>-qmd-watch.service       # watcher activo (si inotify-tools presente)
```

## 3. Índice construido (SC-002: ≤15 min post-login)

```bash
watch -n 10 'ls -la .state/.cache/qmd/ 2>/dev/null'      # (b) index.sqlite + .qmd-setup-ok
jq . scripts/heartbeat/qmd-index.json
CLAUDE_CONFIG_DIR=$PWD/.state/.claude claude mcp list | grep -E 'vault|qmd'   # (e) ambos Connected
```

## 4. Freshness por watcher (SC-002: ≤2 min)

```bash
echo "## test $(date +%s)" >> .state/.vault/log.md
journalctl -u agent-<name>-qmd-reindex.service -f        # (d) reindex disparado ~15 s después
jq -r '.last_run + " " + .last_status' scripts/heartbeat/qmd-index.json
```

## 5. Backup (si fork configurado) (SC-004)

```bash
sudo systemctl start agent-<name>-vault-backup.service   # forzar un ciclo sin esperar el timer
jq . scripts/heartbeat/vault-backup.json                 # (f) last_status=pushed | noop
git ls-remote <fork-url> backup/vault
```

## 6. Degradaciones y observabilidad

```bash
sudo apt-get remove inotify-tools 2>/dev/null; sudo systemctl restart agent-<name>-qmd-watch.service
systemctl is-active agent-<name>-qmd-watch.service       # inactive limpio, sin failed-loop
./scripts/agentctl status                                # unidades vault/qmd reportadas
./scripts/agentctl doctor                                # índice + frescura reindex/backup
```

## 7. Kill-switch / uninstall

```bash
scripts/local/agent-killswitch.sh                        # para también qmd/backup units
./setup.sh --uninstall --yes                             # las remueve; .state (vault+índice) queda
```

Gates de aceptación: (a)–(f) arriba + suite host verde + `DOCKER_E2E=1 bats tests/docker-e2e-qmd.bats tests/docker-e2e-vault.bats` verde.
