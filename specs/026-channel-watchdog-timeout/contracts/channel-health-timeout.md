# Contract — `channel_health_timeout` + `CHANNEL_HEALTH_TIMEOUT`

Interfaz interna del watchdog image-baked (`docker/scripts/start_services.sh`). No es una API pública; es el contrato que los tests bats ejercen.

## 1. Variable de entorno `CHANNEL_HEALTH_TIMEOUT`

- **Quién la define**: el operador, opcionalmente, en el `.env` del workspace (`CHANNEL_HEALTH_TIMEOUT=<segundos>`).
- **Cómo llega**: `env_file: - ./.env` en `docker-compose.yml.tpl:67` → entorno del proceso del contenedor → `start_services.sh`.
- **Unidad**: segundos.
- **Ausencia**: comportamiento por defecto (60s). No es obligatoria; un scaffold nuevo no la trae.

## 2. Función `channel_health_timeout()`

```
channel_health_timeout() -> stdout: <entero segundos>
```

- **Entrada**: lee `$CHANNEL_HEALTH_TIMEOUT` del entorno en **tiempo de invocación** (no cacheado en source-time).
- **Salida**: imprime en stdout un entero de segundos, siempre `> 0`.
- **Exit code**: siempre `0` (usa `printf`; no rompe `set -e`).
- **Contrato de validación**:

| `CHANNEL_HEALTH_TIMEOUT` | stdout |
|--------------------------|--------|
| (unset) | `60` |
| `""` | `60` |
| `abc` | `60` |
| `1.5` | `60` |
| `-5` | `60` |
| `0` | `60` |
| `20` | `20` |
| `45` | `45` |
| `90` | `90` |

- **Portabilidad**: corre igual en bash 3.2 (macOS stock) y 5.x. Patrón `=~` sin comillas.

## 3. Comportamiento observable en `verify_channel_healthy()`

- Espera hasta `channel_health_timeout()` segundos a que aparezca `bun server.ts` (poll cada 2s).
- Aparece dentro del plazo → `return 0`.
- No aparece → `return 1` (el llamador mata la sesión y respawnea).
- **Contrato de test (host)**: con `pgrep` stubbeado para aparecer en `elapsed=22s` y `sleep` no-op:
  - default (var unset) → `return 0` (22 < 60).
  - `CHANNEL_HEALTH_TIMEOUT=20` → `return 1` (22 > 20).
  - nunca aparece → `return 1` en tiempo real `< 3s` (no duerme el timeout completo).

## 4. Log honesto (FR-005)

- Cuando el channel no aparece, el WARN de `start_session()` (`:760`) nombra el valor efectivo: `... never appeared within <N>s — killing for respawn`, donde `<N> = channel_health_timeout()`.
- **Contrato de test cruzado**: `tests/docker-render.bats:162` deja de asertar el literal `"never appeared within 20s"` y pasa a tolerar el valor dinámico.

## 5. WARN de crash budget al boot (decisión D)

- En `main()`, una vez al arranque: si `channel_health_timeout() >= UMBRAL_WARN` (candidato `65`), emitir un WARN informativo: con ese valor, 5 fallos consecutivos del channel no caben en la ventana del crash budget (`WINDOW=300`), por lo que el backstop de restart-de-contenedor puede no escalar.
- **Sin cap**: el valor se usa igual (el operador decide).
- **Contrato de test**: un test de `crash_budget_check` valida el punto de ruptura `T < 70` (5º fallo dentro/fuera de la ventana); un test verifica que el WARN se emite para `≥ UMBRAL_WARN` y NO para el default 60.

## 6. Gate DOCKER_E2E

- `docker-e2e-postlogin.bats`: con `CHANNEL_HEALTH_TIMEOUT=<N>` en el `.env` del workspace de prueba, asertar (a) presencia de la var en el proceso (`docker compose exec -u agent … sh -c 'echo $CHANNEL_HEALTH_TIMEOUT'`), (b) el WARN/log del watchdog refleja `<N>`. Aserción conductual, no de timing estricto.
