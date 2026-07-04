# Contract — Deployment mode branching (host-side)

**Date**: 2026-06-28 · **Branch**: `011-local-standalone-mode`

Cómo el launcher ramifica docker vs local. Todo host-side (bash), test-first con bats.

## Wizard (`setup.sh`)

- En el bloque deployment (~449-489), tras la pregunta de `install_service`, agregar la elección de modo con `ask_choice` (opciones `docker local`, default `docker`). Primera opción "Docker (recomendado)"; segunda "local standalone (riesgo de seguridad)" **con advertencia explícita** antes de confirmar: el agente corre como tu usuario y hereda tus privilegios/secretos; quien controle la cuenta claude.ai controla el host (MFA obligatorio); sin aislamiento de contenedor.
- Persistir en el heredoc de `agent.yml` (~1075-1080): `  mode: "<docker|local>"` dentro de `deployment:`.
- En modo no-interactivo y en `wizard_answers` (tests), aceptar `deployment_mode=docker|local` (default docker).

## Schema (`scripts/lib/schema.sh`)

- `_SCHEMA_ENUMS += '.deployment.mode=docker,local'` (~52-59). Opcional: ausente = válido (legacy docker); presente debe ser del enum.
- NO agregar a `_SCHEMA_REQUIRED_LEAVES` (opcional + backfill).

## Render branch (`setup.sh::regenerate`)

- Tras `render_load_context` (~1819): `DEPLOYMENT_MODE="$(yq -r '.deployment.mode // "docker"' "$agent_yml")"`; `export DEPLOYMENT_MODE`; derivar `DEPLOYMENT_MODE_IS_DOCKER` (`true`/`false`) y exportarla.
- Backfill: si `deployment.mode` ausente en `agent.yml`, escribir `docker` (junto al bloque de backfill docker.* existente ~1786-1799).
- **Si `mode=docker`** (o ausente): comportamiento ACTUAL sin cambios (byte-idéntico). Render de `docker-compose.yml` (~1901-1903) y `mirror_catalog_to_docker` (~1908) corren igual; `install_service` usa `systemd.service.tpl` (docker compose).
- **Si `mode=local`**:
  - OMITIR `render_to_file docker-compose.yml.tpl` y `mirror_catalog_to_docker`.
  - Renderizar la base de config (CLAUDE.md, .mcp.json, .env.example, heartbeat.conf, vault, RAG) — sin cambios.
  - Renderizar los artefactos local (ver `systemd-remote-control.md`): unit de sesión, EnvironmentFile, healthcheck (+ timer), kill-switch, login helper.
  - `install_service` (si `install_service=true`) usa la unit local en vez de la docker.
- **Cambio de modo en `--regenerate`** (FR-005a): si el modo previo (detectado por presencia de `docker-compose.yml` vs la unit local) difiere del actual, regenerar solo el set actual y emitir un aviso listando los huérfanos del modo anterior; NO borrar.

## NEXT_STEPS (`setup.sh::render_next_steps` + `modules/next-steps.{en,es}.tpl`)

- Exportar `DEPLOYMENT_MODE`/`DEPLOYMENT_MODE_IS_DOCKER` antes del render.
- Branch con `{{#if DEPLOYMENT_MODE_IS_DOCKER}}` (instrucciones docker compose / agentctl) y `{{#unless DEPLOYMENT_MODE_IS_DOCKER}}` (login one-time guiado, `systemctl enable --now`, healthcheck, kill switch, requisitos: claude ≥ 2.1.51, plan compatible, MFA).

## Gates de test (host-side bats)

- `tests/schema-validate.bats`: `deployment.mode` docker válido, local válido, valor bogus rechazado, ausente válido (legacy).
- `tests/deployment-mode.bats`: `mode=local` → NO `docker-compose.yml`, NO `mirror_catalog_to_docker`, artefactos local presentes; `mode=docker` → set de archivos byte-idéntico a hoy (regresión).
- `tests/regenerate.bats`: backfill ausente→docker; modo preservado; aviso al cambiar de modo.
