# Quickstart: verificar el fix de plugins de marketplaces de terceros

## Reproducir el bug (pre-fix)

Un agente cuyo `agent.yml` declara un plugin de un marketplace de terceros (p.ej. `claude-mem@thedotmack`, presente por defecto en el catálogo):

```bash
# Tras boot del contenedor:
docker logs <agente> 2>&1 | grep -E 'marketplace|claude-mem'
# PRE-FIX:
#   registering extra marketplaces: {"thedotmack": ...}
#   attempting to install plugin: claude-mem@thedotmack
#   plugin install skipped: marketplace not registered yet — claude-mem@thedotmack
docker exec -u agent <agente> sh -c 'CLAUDE_CONFIG_DIR=/home/agent/.claude claude plugin list' | grep claude-mem
#   PRE-FIX: (vacío) — el plugin no quedó instalado, y la sesión estable no reintenta.
```

## Validación host-side (sin Docker)

```bash
# US1/US2 — cobertura del nuevo helper:
bats tests/start-services-extra-marketplace.bats
# Casos: registra-cuando-ausente, idempotente-cuando-presente,
# acotado-cuando-cuelga (shim timeout), degrada-sin-timeout, no-op-sin-claude.

# Suite completa host-side debe quedar verde:
bats tests/

# shellcheck:
shellcheck -S error docker/scripts/start_services.sh
```

## Validación de integración (DOCKER_E2E)

```bash
# El caso de marketplace de terceros + el resto del post-login:
DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats
# Suite e2e completa (sin regresiones):
DOCKER_E2E=1 bats tests/docker-e2e-*.bats
```

Espera-verde (post-fix): el log del supervisor muestra `extra marketplace registered: <key>` seguido de `plugin installed: <plugin>@<key>` (no "skipped: marketplace not registered yet"), y `claude plugin list` incluye el plugin de terceros — todo sin intervención manual.

## Validación runtime opcional (agente real)

```bash
# En un agente recién booteado que declara un plugin de terceros:
docker exec -u agent <agente> sh -c 'CLAUDE_CONFIG_DIR=/home/agent/.claude claude plugin marketplace list' | grep <key>
docker exec -u agent <agente> sh -c 'CLAUDE_CONFIG_DIR=/home/agent/.claude claude plugin list' | grep <plugin>
# Ambos presentes = marketplace resuelto + plugin instalado al boot.
```
