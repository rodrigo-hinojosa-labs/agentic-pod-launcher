# Quickstart — Modo agente local standalone (011)

**Date**: 2026-06-28 · **Branch**: `011-local-standalone-mode`

Flujo del operador para crear y operar un agente en **modo local** (Linux/systemd). El modo docker no cambia.

## Prerrequisitos (host Linux destino)

- `systemd`, `jq`, `git`, `bash`.
- Claude Code **≥ 2.1.51** (instalador oficial; el bootstrap verifica la versión).
- Cuenta claude.ai con plan compatible con Remote Control y **Remote Control habilitado** (toggle ON en Team/Enterprise).
- **MFA activo** en la cuenta (parte del modelo de amenaza: quien controla la cuenta controla el host).

## 1. Scaffolding

```bash
./setup.sh                      # en el wizard, elegí "local standalone (riesgo de seguridad)"
# o no-interactivo:
./setup.sh --destination ~/agente --non-interactive   # con deployment.mode=local en agent.yml
```

El launcher renderiza en el workspace: la base de config (CLAUDE.md, .mcp.json, skills, vault, heartbeat.conf, RAG) y los artefactos local (unit `agent-<name>.service`, `remote-control.env`, healthcheck + timer, kill-switch, helper de login, NEXT_STEPS). NO se generan `docker-compose.yml` ni `Dockerfile`.

## 2. Login full-scope (único paso manual, one-time)

```bash
./setup.sh --login              # lanza el OAuth interactivo + aplica trust + habilita el servicio
```

- En headless: tunelizá el puerto del callback por SSH (`ssh -L <port>:localhost:<port> host`) y completá el OAuth en tu navegador.
- El login deja `<workspace>/.state/.claude/.credentials.json` (0600, gitignored) y reescribe `.claude.json` → el helper re-aplica el trust del workspace.

## 3. Operación

```bash
systemctl status  agent-<name>.service          # estado de la sesión
journalctl -u     agent-<name>.service -f        # logs (buscar 'session url'/'connected')
systemctl stop    agent-<name>.service           # KILL SWITCH (con Restart=always, no rearranca)
systemctl disable agent-<name>.service           # no arrancar al boot
```

Controlás el agente desde **claude.ai/code** y la app móvil (identidad `<hostname>-<name>`). El healthcheck corre por timer (~5 min) y avisa si el login expira o hay error de auth.

## Gates de verificación (manual, en el host Linux)

DOCKER_E2E no puede ejercitar systemd/Linux desde macOS; estos gates validan la integración real (los 6 verificados en producción):

1. `claude --version` → ≥ 2.1.51.
2. `.credentials.json` presente y `0600` tras el login.
3. `systemctl is-active agent-<name>.service` = `active` **y** señal de conexión en el journal (`session url`/`connected`).
4. `CLAUDE_CONFIG_DIR=<ws>/.state/.claude claude -p "Reply: READY"` → `READY` sin 401.
5. Idempotencia: re-correr `./setup.sh --regenerate` y `--login` no cambia nada.
6. Auto-recuperación: `kill -9` del proceso `claude remote-control` → rearranca en ~10 s (RestartSec=10).

## Suite host-side (en el dev, sin Docker)

```bash
bats tests/                                        # incluye schema/deployment-mode/local-render/healthcheck/trust-merge
bats tests/deployment-mode.bats                    # mode=local sin compose; mode=docker byte-idéntico
shellcheck -S error setup.sh scripts/lib/*.sh      # limpio
DOCKER_E2E=1 bats tests/docker-e2e-*.bats          # no-regresión del modo docker
```

## Seguridad (recordatorio)

- El agente corre como **tu usuario** y hereda tus privilegios y secretos (archivos, llaves SSH). Es la mayor exposición del modo local.
- Nunca se usa `--dangerously-skip-permissions` (las confirmaciones siguen vivas).
- `.credentials.json` y `*.env` del modo local nunca se versionan; el token de notificación nunca va en argv/journal.
- Si preferís aislar, un follow-up puede mover el agente a un usuario dedicado.
