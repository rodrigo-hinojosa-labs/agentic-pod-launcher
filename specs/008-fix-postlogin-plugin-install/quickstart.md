# Quickstart: validar el fix de auto-instalación post-login

## 1. Reproducir el estado roto (antes)

```bash
# host-side: el lib no llega a la imagen viva (si hay un agente corriendo)
docker exec -u agent <agente> ls /opt/agent-admin/scripts/lib/ | grep plugin-install || echo "AUSENTE (bug #3)"

# E2E: la falla
DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats   # not ok (cuelga el boot, 0 instalaciones)
```

## 2. Aplicar el fix

- **US1 (stub):** en `tests/docker-e2e-postlogin.bats`, el stub `claude` maneja `plugin marketplace list/add` y `plugin list` (exit 0), reservando `exec sleep` para bare claude.
- **US2 (timeout):** en `docker/scripts/start_services.sh::ensure_official_marketplace`, envolver las llamadas a `claude` con `timeout` (degradar si ausente), fail-silent.
- **US3 (COPY):** en `docker/Dockerfile`, agregar `COPY scripts/lib/plugin-install.sh /opt/agent-admin/scripts/lib/plugin-install.sh` junto a las libs image-only.

## 3. Validar host-side (sin Docker)

```bash
# US2: ensure_official_marketplace no cuelga ante un claude colgado
bats tests/start-services-marketplace.bats

# US3: Dockerfile copia plugin-install.sh + presente tras scaffold
bats tests/docker-setup.bats -f "plugin-install"

# suite host-side completa verde
bats tests/ 2>&1 | grep -cE "^not ok"   # => 0
```

## 4. Validar runtime (DOCKER_E2E, rebuild)

```bash
# rebuild implícito en el test (docker compose build) + boot + flip
DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats        # ok
DOCKER_E2E=1 bats tests/docker-e2e-*.bats 2>&1 | grep -cE "^not ok"   # => 0 (11/11)

# verificación directa del lib en una imagen construida
DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats   # incluye la aserción de retry acotado
```

## 5. Criterio de aceptación

- `DOCKER_E2E=1 bats tests/docker-e2e-*.bats` → 0 fallas (11/11).
- `bats tests/` host-side → 0 fallas (incluye nuevos tests US2/US3).
- En imagen construida: `/opt/agent-admin/scripts/lib/plugin-install.sh` existe y `retry_plugin_install_bounded` definido.
- `shellcheck -S error` limpio en `start_services.sh`.
- `VERSION` = 0.4.2; `CHANGELOG.md` con la entrada.
