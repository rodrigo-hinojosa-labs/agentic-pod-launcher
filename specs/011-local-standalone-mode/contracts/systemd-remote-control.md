# Contract — Local-mode systemd artifacts

**Date**: 2026-06-28 · **Branch**: `011-local-standalone-mode`

Plantillas nuevas bajo `modules/`, renderizadas desde `agent.yml` solo cuando `deployment.mode=local`. Placeholders entre `{{ }}` los provee `render.sh`; los valores derivados (User, HOME, hostname) los resuelve `install_service`/el login helper al instalar (no se versionan).

## `modules/systemd-remote-control.service.tpl` → `agent-<name>.service`

Se instala como **unit de sistema** en `/etc/systemd/system/agent-<name>.service` (A1; v1 no usa `systemd --user`/linger). `__OPERATOR__`/`__CLAUDE_BIN__`/`__HOSTNAME__` los resuelve `install_service` al instalar (`id -un`, ruta absoluta de `claude`, `hostname`).

Contrato de la unit (valores verificados en producción):

```ini
[Unit]
Description=Claude Code Remote Control ({{AGENT_NAME}})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=__OPERATOR__                       # resuelto a `id -un` al instalar
WorkingDirectory={{DEPLOYMENT_WORKSPACE}}
EnvironmentFile={{DEPLOYMENT_WORKSPACE}}/.state/remote-control.env
ExecCondition=/usr/bin/test -r {{DEPLOYMENT_WORKSPACE}}/.state/.claude/.credentials.json
ExecStart=__CLAUDE_BIN__ remote-control --name __HOSTNAME__-{{AGENT_NAME}} --spawn=session --verbose
Restart=always
RestartSec=10
# Sin --dangerously-skip-permissions (confirmaciones vivas)

[Install]
WantedBy=multi-user.target
```

Invariantes verificables (bats render test):
- `Restart=always` (NO on-failure).
- `ExecCondition` presente apuntando a `.credentials.json` bajo `.state/.claude`.
- `ExecStart` contiene `remote-control`, `--name`, `--spawn=session`; NO contiene `--dangerously-skip-permissions`.
- `WorkingDirectory` = workspace (nunca `/`).
- `EnvironmentFile` apunta a `.state/remote-control.env`.

## `modules/remote-control.env.tpl` → `.state/remote-control.env` (0640)

```ini
CLAUDE_CONFIG_DIR={{DEPLOYMENT_WORKSPACE}}/.state/.claude
DISABLE_AUTOUPDATER=1
HOME=__OPERATOR_HOME__
# SIN ANTHROPIC_API_KEY (Remote Control usa login)
```

Invariantes: contiene `CLAUDE_CONFIG_DIR` y `DISABLE_AUTOUPDATER=1`; NO contiene `ANTHROPIC_API_KEY`.

## `modules/local-login.sh.tpl` → helper de login guiado

- Verifica `claude --version` ≥ 2.1.51 (falla claro si no).
- Pre-siembra onboarding (`hasCompletedOnboarding=true`) en `.claude.json` si no existe (no sobreescribe).
- Lanza el login OAuth interactivo (tuneliza el callback por SSH en headless — documentado).
- DESPUÉS del login: merge idempotente del trust `projects["{{DEPLOYMENT_WORKSPACE}}"].hasTrustDialogAccepted=true` preservando el resto de `.claude.json` (comparación por igualdad exacta).
- `systemctl enable --now agent-<name>.service` (o `--user` + linger).
- Idempotente: re-ejecutar no rompe (detecta login/trust ya presentes).

## `modules/local-healthcheck.sh.tpl` (+ `.service.tpl` + `.timer.tpl`)

Script (corre por timer ~5min):
- `systemctl is-active --quiet <unit>` → si no, DEGRADED ("unit no active").
- journal (10 min): `API Error: 401|Please run /login` → DEGRADED (auth); `session url|connected|polling` ausente → WARN.
- Si `jq` y `.credentials.json` legibles: leer `expiresAt` (ms epoch); expirado → DEGRADED; dentro de ventana (24h) → WARN. Si falta `jq`/creds → degradar con gracia (no romper).
- Notificación opcional ante DEGRADED reusando el canal del agente; token nunca en argv (curl `--config -`).
- Exit 0 = OK; salidas no-cero solo señalizan estado a quien lo invoque (el notifier siempre exit 0).

## `modules/local-killswitch.sh.tpl`

- `systemctl stop <unit>` (con `Restart=always`, stop explícito no rearranca) y opción `--disable` para no arrancar al boot.
- Documenta el canal remoto alternativo (toggle /remote-control en claude.ai).

## Gates de test (host-side bats, stubs)

- `tests/local-render.bats`: renderiza cada plantilla desde un `agent.yml` con `mode=local` y asevera los invariantes de arriba.
- `tests/local-trust-merge.bats`: aplica el merge sobre un `.claude.json` con otras claves → trust=true y el resto intacto; re-ejecutar es no-op (igualdad exacta, no substring).
- `tests/local-healthcheck.bats`: stubs de `systemctl`/`journalctl`/`jq` + `.credentials.json` con `expiresAt` controlado → OK / WARN (por-expirar, sin señal de conexión) / DEGRADED (401, expirado, unit inactiva); degrada si falta `jq`.
