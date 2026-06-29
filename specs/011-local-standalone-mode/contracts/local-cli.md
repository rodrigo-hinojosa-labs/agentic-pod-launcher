# Contract — Local-mode CLI surface

**Date**: 2026-06-28 · **Branch**: `011-local-standalone-mode`

`agentctl` hoy es la CLI de ciclo de vida del **modo docker** (host-side wrapper de `docker exec -u agent`). En v1 Thin NO se porta el supervisor; la superficie de CLI local se mantiene mínima y honesta sobre lo que existe.

## `setup.sh --login` (helper guiado, único paso manual)

- Disponible cuando el workspace está en `mode=local`. Ejecuta `modules/local-login.sh` (rendizado al workspace, p.ej. `scripts/local/agent-login.sh`).
- Idempotente; documentado en NEXT_STEPS (modo local).

## `agentctl` en modo local (degradación honesta v1)

- `agentctl` detecta `deployment.mode` (ya lee `agent.yml`, ~72-77). En `mode=local`:
  - `up`/`down`/`restart`/`attach`/`shell`/`logs -f` (que asumen docker/tmux) → **error claro** con hint: usar `systemctl {start,stop,status} agent-<name>.service`, `journalctl -u agent-<name>.service -f`, y el kill-switch. NO intentar `docker`.
  - `status` → mostrar `systemctl is-active` + última señal del journal + edad del login (en vez de `docker exec heartbeatctl status`).
  - `doctor` → checks de modo local: `claude --version` ≥ 2.1.51, `.credentials.json` presente (0600) + `expiresAt`, `systemctl is-active`, señal de conexión en journal, PID de la sesión. (Reemplaza los checks de daemon/contenedor/crond.)
- Justificación: en v1 Thin no hay supervisor/heartbeat/crond en local, así que las subórdenes de ciclo de vida del contenedor no aplican; se degradan con un mensaje accionable en vez de fallar opaco (Principio IV).

## Fuera de v1 (follow-up)

- `heartbeatctl` host-side, scheduling de heartbeat por systemd timer, auto-install de plugins, qmd watcher y backups en local — diferidos (D3). Cuando se aborden, `agentctl heartbeat <sub>` ramificará a la implementación local.

## Gates de test (host-side bats)

- `agentctl` con un `agent.yml` `mode=local`: las subórdenes docker-only devuelven exit≠0 con el hint de `systemctl` (stub de `docker` no invocado); `status`/`doctor` usan stubs de `systemctl`/`journalctl`/`jq`.
