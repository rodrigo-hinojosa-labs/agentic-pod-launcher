# Quickstart / Validación: Headless bootstrap

**Feature**: 006-headless-bootstrap · **Date**: 2026-06-22

Cómo validar el feature. La suite host (`bats tests/`) cubre la lógica; los pasos e2e (opt-in) validan el flujo real contra un contenedor.

## Suite host (obligatoria, sin Docker)

```bash
bats tests/                                   # toda la suite — debe quedar verde
bats tests/watchdog-auth-flip-detection.bats  # token presente ⇒ sin kick espurio
bats tests/start-services-watchdog.bats       # next_tmux_cmd con token ⇒ no bare /login
bats tests/start-services-plugin-install.bats # marketplace add idempotente; marketplace-not-found ≠ auth
bats tests/start-services-onboarding.bats     # pre_seed_onboarding crea/idempotente (NUEVO)
bats tests/modules-render.bats                # .env.example expone CLAUDE_CODE_OAUTH_TOKEN
shellcheck -S error docker/scripts/start_services.sh docker/scripts/lib/plugin-install.sh
```

Criterio: todo verde; los casos nuevos fallan ANTES del cambio y pasan después (test-first).

## Flujo de operador (validación funcional, SC-001..004)

1. **Generar el token** (host, una vez):
   ```bash
   claude setup-token
   #   → autorizar OAuth en el browser
   #   → pegar el code#state EN LA TERMINAL (no en otro lado)
   #   → claude imprime sk-ant-oat01-…   ← este es el token
   ```
2. **Scaffold** con el wizard; en el paso "Claude authentication" pegar el token (o dejar vacío para usar /login).
3. **Arrancar**: `docker compose up -d --wait` (o `./scripts/agentctl up`).
4. **Verificar auth headless** (sin exponer el secreto):
   ```bash
   docker exec -u agent <agent> sh -c '[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && echo SET || echo unset'
   docker exec -u agent -e CLAUDE_CONFIG_DIR=/home/agent/.claude <agent> \
     claude -p "Reply with: READY" --dangerously-skip-permissions
   #   esperado: READY (sin 401, sin "Not logged in")
   ```
5. **Verificar marketplace + canal** (SC-002):
   ```bash
   docker exec -u agent -e CLAUDE_CONFIG_DIR=/home/agent/.claude <agent> claude plugin marketplace list
   #   esperado: claude-plugins-official (Source: GitHub anthropics/claude-plugins-official)
   docker exec -u agent <agent> sh -c 'find /home/agent/.claude/plugins/cache -name .installed-ok' 
   #   esperado: sentinel del plugin del canal
   ```
6. **Verificar onboarding no bloquea** (SC-003): `./scripts/agentctl attach` no debe quedarse en el theme picker.
7. **Verificar fallback** (SC-004): scaffold SIN token ⇒ el arranque ofrece `/login` interactivo como hoy.

## E2E opt-in (gateado, DOCKER_E2E=1)

```bash
DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats   # fresh scaffold autenticado por token, sin /login
```

## Hygiene de secretos (SC-006)

```bash
grep -r CLAUDE_CODE_OAUTH_TOKEN agent.yml          # NO debe aparecer
grep -r 'sk-ant-oat' .env.example modules/ docs/   # NO debe haber valores de token
```
