# Research — Modo agente local standalone (011)

**Date**: 2026-06-28 · **Branch**: `011-local-standalone-mode`

Fundamentado en un mapeo paralelo del repo (anchors verificados) + el conocimiento de producción del operador (desplegado y depurado en un cluster RPi5). Las decisiones marcadas "verificado en producción" provienen de ese despliegue y se toman como contrato.

---

## D1 — Modo como única fuente de verdad en `agent.yml`

**Decisión**: agregar `deployment.mode: docker|local` (default `docker`). Render flatea a `DEPLOYMENT_MODE`; en `setup.sh` se deriva `DEPLOYMENT_MODE_IS_DOCKER=true|false` tras `render_load_context` para gatear plantillas. Legacy sin la clave → backfill a `docker` (espejo del backfill de `vault.qmd.version` en 010).
**Rationale**: Principio I; cero regresión para agentes pre-011; opt-in real.
**Alternativas**: requerir `mode` siempre (rompe legacy en `--regenerate`) — rechazada.

## D2 — Branch en `setup.sh`, no en las plantillas docker

**Decisión**: el modo docker queda byte-idéntico envolviendo en `setup.sh` los call-sites: omitir `render_to_file` de `docker-compose.yml` (~1901-1903) y `mirror_catalog_to_docker` (~1908) cuando `mode=local`; NO envolver `docker-compose.yml.tpl` en `{{#if}}` (evita escribir un archivo vacío y mantiene el diff docker en cero).
**Rationale**: SC-002 (docker byte-idéntico); el render engine escribiría un archivo aunque el contenido condicional sea vacío.
**Alternativas**: envolver el tpl en `{{#unless}}` — deja un archivo vacío y cambia el set de archivos del modo docker.

## D3 — Alcance v1 "Thin" (decidido en clarify)

**Decisión**: v1 = elección de modo + render de la base de config + persistencia Remote Control (login/healthcheck/kill-switch/seguridad). La automatización del supervisor (scheduling de heartbeat, auto-install de plugins, qmd watcher, backups) — hoy image-baked en `docker/scripts/start_services.sh` + `crond` — se **defiere**.
**Rationale**: todo el runtime del supervisor vive en la imagen (`/opt/agent-admin`), no se renderiza al workspace; portarlo es esencialmente reimplementar el contenedor fuera del contenedor (esfuerzo grande). El núcleo (sesión persistente controlable + base) entrega el valor pedido; el agente puede hacer esas tareas interactivamente vía Remote Control.
**Alternativas**: paridad completa (rechazada para v1 por esfuerzo); thin+timer de heartbeat (rechazada: `heartbeat.sh` lanza una sesión claude vía tmux inexistente en local → requiere adaptación no trivial).

## D4 — Comando y modelo de sesión (verificado en producción)

**Decisión**: `claude remote-control --name <NAME> --spawn=session --verbose`. `<NAME>` estable y único = `<hostname>-<agent_name>`. `--spawn=session` sale limpio al completarse → la unit usa `Restart=always`.
**Rationale**: contrato verificado; `--name` da identidad estable en claude.ai/code; `--spawn=session` minimiza superficie (rechaza conexiones extra).
**Alternativas**: `--spawn=same-dir|worktree` (multi-sesión) — fuera de v1 (1 agente/host).

## D5 — Autenticación full-scope (bloqueante, verificado)

**Decisión**: el login es OAuth interactivo one-time por host/usuario; credenciales en `$CLAUDE_CONFIG_DIR/.credentials.json` (con `expiresAt` en ms epoch), reutilizables. No hay vía headless; en headless se tuneliza el callback por SSH. El launcher provee un **helper guiado** (`setup.sh --login` → `modules/local-login.sh.tpl` en el workspace) que lanza el login, aplica trust y habilita el servicio.
**Rationale**: Remote Control rechaza el token inference-only ("requires a full-scope login token"); es la restricción que obliga a host persistente.
**Alternativas**: automatizar el OAuth — no existe vía oficial (descartada).

## D6 — Identidad: usuario actual del login (decidido en clarify)

**Decisión**: el servicio corre como el **usuario del operador** (`User=$(id -un)` al instalar). `HOME` el del operador; `CLAUDE_CONFIG_DIR=<workspace>/.state/.claude` (aísla la config del agente de la `~/.claude` personal y respeta Principio V). **v1 usa una unit de SISTEMA** (`/etc/systemd/system/agent-<name>.service`) con `User=`; `systemd --user` + `loginctl enable-linger` queda como follow-up (A1, pin de la ambigüedad: un solo camino de instalación en v1). El campo `claude.config_dir` de `agent.yml` es **docker-only** y se ignora en local (C1).
**Rationale**: elección del usuario; el agente hereda privilegios/secretos del operador → advertencia reforzada (es la mayor exposición). Unit de sistema = persistencia tras logout/reboot sin la complejidad del linger. `CLAUDE_CONFIG_DIR` bajo `.state` evita pisar la config personal y mantiene el login gitignored.
**Alternativas**: usuario dedicado (menor privilegio, recomendado pero no elegido); root (máximo riesgo); `systemd --user`+linger (más complejo, follow-up).

## D7 — Trust del workspace en `.claude.json` (verificado)

**Decisión**: pre-sembrar onboarding (`hasCompletedOnboarding=true`) ANTES del login sin sobreescribir si existe; y aplicar el trust (`projects["<workdir>"].hasTrustDialogAccepted=true`) DESPUÉS del login (el login reescribe `.claude.json` y resetea el trust). Merge idempotente que preserva el resto del archivo (comparación por igualdad exacta, no substring).
**Rationale**: sin trust, `claude remote-control` sin TTY sale exit 1 ("Workspace not trusted") → bucle de reinicio. WorkingDirectory = workspace (nunca `/`).
**Alternativas**: correr en `/` (rompe); trust manual (frágil) — el helper lo automatiza.

## D8 — Unit systemd de la sesión (verificado)

**Decisión**: `Type=simple`; `ExecStart=<claude> remote-control --name <NAME> --spawn=session --verbose`; `Restart=always` + `RestartSec=10`; `StartLimitIntervalSec=300`/`StartLimitBurst=5`; `ExecCondition=/usr/bin/test -r <CONFIG_DIR>/.credentials.json` (no arranca sin login → inactive, no failed); `WorkingDirectory=<workspace>` (trusted); `EnvironmentFile=<workspace>/.state/remote-control.env`; `User=<operador>`. **Sin** `--dangerously-skip-permissions`. Ruta absoluta del binario `claude`.
**Rationale**: contrato verificado; `Restart=always` (no on-failure) porque `--spawn=session` sale limpio; `ExecCondition` evita el estado failed sin login; `systemctl stop` con `Restart=always` NO rearranca → kill switch válido.
**Alternativas**: `Restart=on-failure` (la sesión no persistía — gotcha #3 verificado).

## D9 — EnvironmentFile (verificado)

**Decisión**: `modules/remote-control.env.tpl` (modo 0640) con `CLAUDE_CONFIG_DIR=<workspace>/.state/.claude`, `DISABLE_AUTOUPDATER=1`, `HOME=<operador>`. **SIN** `ANTHROPIC_API_KEY` (Remote Control usa login, no API key).
**Rationale**: Principio VI (auto-updater off); separar secretos del unit.

## D10 — Healthcheck: vivo vs conectado vs expirado (verificado)

**Decisión**: `modules/local-healthcheck.sh.tpl` + `.service.tpl` + `.timer.tpl` (~5 min). Lógica: `systemctl is-active` (proceso); grep en journal de `API Error: 401|Please run /login` (auth → DEGRADED) y de `session url|connected|polling` (conexión → WARN si ausente); leer `expiresAt` (ms epoch) de `.credentials.json` con `jq` (expirado → DEGRADED; ventana → WARN). Degrada con gracia si falta `jq`/credenciales. Notificación opcional reusa el canal del agente; token nunca en argv (curl `--config -`).
**Rationale**: FR-015/016/017/018; distinguir "PID vivo" de "controlable" es la señal real.
**Alternativas**: solo `is-active` (no detecta login expirado — gotcha #5).

## D11 — `--regenerate`: preservar modo + aviso de cambio (clarify)

**Decisión**: `--regenerate` preserva `deployment.mode`; si el modo cambió respecto a la generación previa, regenera solo el set actual y **emite un aviso** listando los artefactos huérfanos del modo anterior (`docker-compose.yml`/unit docker, o la unit local), **sin borrarlos** (FR-005a).
**Rationale**: seguro y trazable; nunca borra archivos del usuario.
**Alternativas**: limpiar automáticamente (destructivo); silencio (huérfanos confusos).

## D12 — Verificación: host-side bats + gate manual Linux

**Decisión**: cobertura `bats` host-side con stubs-on-PATH (`systemctl`/`journalctl`/`jq`/`claude`) para schema, render de artefactos local, trust-merge idempotente y healthcheck (OK/WARN/DEGRADED). DOCKER_E2E cubre la **no-regresión del modo docker**. La integración real systemd/Linux se valida con un **gate manual en host Linux** (los 6 gates del operador: versión ≥ 2.1.51, `.credentials.json` 0600, `is-active` + señal de conexión, `claude -p "Reply: READY"` sin 401, idempotencia, auto-recuperación kill -9 → ~10s).
**Rationale**: Principio III; honesto sobre el límite de DOCKER_E2E en macOS.
**Alternativas**: ninguna (no se puede correr systemd nativo en el contenedor Alpine de e2e en macOS).

---

## Gotchas verificados a respetar (del despliegue del operador)

1. `claude` fuera del PATH al loguear → la unit usa ruta absoluta; el login manual necesita PATH (documentar en NEXT_STEPS).
2. Restart loop por "Workspace not trusted" en cwd `/` → trust pre-aceptado + WorkingDirectory confiado (D7).
3. La sesión no persistía con `Restart=on-failure` → `Restart=always` (D8).
4. Idempotencia falsa por comparación substring ("CHANGED" in "UNCHANGED") → comparar por igualdad exacta (trust-merge, D7).
5. Healthcheck sin `jq` no chequeaba expiración → `jq` requerido; degradar si falta (D10).
6. `--name` debe ser estable y único → `<hostname>-<agent_name>` (D4).
