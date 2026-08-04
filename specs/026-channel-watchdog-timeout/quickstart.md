# Quickstart — Feature 026

## Para el operador: ampliar el timeout del channel

Si un agente docker flapea en el boot porque el plugin de Telegram (`bun server.ts`) tarda más que el default en levantar (host lento o muchos MCPs):

```bash
# En el workspace del agente
echo 'CHANNEL_HEALTH_TIMEOUT=90' >> .env     # segundos; default es 60
docker compose build && ./scripts/agentctl up   # el valor es image-baked-agnóstico,
                                                 # pero el .env se lee en cada arranque
```

Verificar que tomó efecto:

```bash
docker compose exec -u agent <agent> sh -c 'echo $CHANNEL_HEALTH_TIMEOUT'   # -> 90
docker compose logs <agent> | grep -E 'channel plugin healthy|never appeared within'
```

- Un valor ausente, vacío, no numérico o `<= 0` cae al default 60 sin fallar el arranque.
- **Aviso de crash budget**: si fijas un valor `>= 65s`, verás al boot un WARN informativo — con timeouts tan largos, el backstop que reinicia el contenedor tras 5 fallos consecutivos del channel puede no escalar. Es intencional; el valor se usa igual.

## Para el desarrollador: correr los tests

```bash
# Unit host-side (sin Docker): la lógica del timeout configurable
bats tests/start-services-watchdog.bats

# Repro en bash 3.2 real (macOS stock), como la matriz de CI (feature 025)
env PATH=/bin:$PATH bats tests/start-services-watchdog.bats

# Gate de la cadena de entrega .env -> env_file (requiere host Docker)
DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats
```

Casos cubiertos por el seam host (stub de `pgrep` que aparece en `elapsed=22s`, `sleep` no-op):
- default 60 (var unset) → el channel a 22s se detecta (pasa).
- `CHANNEL_HEALTH_TIMEOUT=20` → el channel a 22s NO se detecta (falla, como el bug original).
- channel que nunca aparece → retorna fallo en `< 3s` reales (no duerme el timeout completo).
- valores inválidos → default 60.
- `crash_budget_check` → valida el punto de ruptura `T < 70`.

## Retiro del override manual de ferrari (post-deploy)

Ferrari corre hoy un `docker-compose.override.yml` que bind-montea un `start_services.sh` parcheado (`timeout=90`). Tras desplegar la imagen 026, retirar el override preservando el valor conocido-bueno:

```bash
# En el workspace de ferrari, DESPUÉS de que la imagen 026 esté horneada
docker compose down
echo 'CHANNEL_HEALTH_TIMEOUT=90' >> .env
rm docker-compose.override.yml
rm -rf .override/
docker compose build            # OBLIGATORIO: el script vuelve a ser image-baked
docker compose up -d
# Verificar imagen 026 (no debe quedar 'timeout=20' baked):
docker compose exec -u agent rodri-cenco-admin \
  grep -n 'channel_health_timeout' /opt/agent-admin/scripts/start_services.sh
docker compose logs rodri-cenco-admin | grep 'channel plugin healthy'
```

**Orden crítico**: no retirar el override antes de hornear 026 — el contenedor caería al script baked pre-026 (`timeout=20`) y volvería a flapear. Se preserva `90` (no `60`) para riesgo conductual cero; bajar a 60 en ferrari es un cambio separado a medir aparte.
