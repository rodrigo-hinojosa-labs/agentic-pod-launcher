# Research — Feature 026: timeout configurable del watchdog del channel (docker-only)

**Fase 0** · Fecha: 2026-08-02 · Fuente: workflow de 5 investigadores read-only + síntesis adversarial (`wf_922c62d5-f37`, 552k tokens, 0 errores) + cierre del agente principal.

Convención: `[VERIFICADO]` = citado con archivo:línea leído · `[INFERENCIA]` = derivado/calculado, no medido · `[DECISIÓN USUARIO]` = trade-off que requiere elección del operador.

## Contexto verificado (sin conflicto entre áreas)

- La función a modificar es `verify_channel_healthy()` en `docker/scripts/start_services.sh:721-732`, con `local timeout=20` en `:722`. El loop opera en **segundos**, granularidad `sleep 2` (`:728`, `:729`), chequea `pgrep -f "bun server.ts"` en `elapsed = 0,2,4,…` (`:724-730`).
- Script **image-baked** (`docker/Dockerfile:231`); un cambio exige `docker compose build` + recreate.
- **Docker-only, sin mirror**: una sola ubicación (`docker/scripts/start_services.sh`), no hay copia en `scripts/lib/`. Aun así DOCKER_E2E es pertinente (cambio de boot/supervisor).
- El `.env` llega al contenedor vía `modules/docker-compose.yml.tpl:67-68` (`env_file: - ./.env`); la cadena `.env → env_file → tini → su-exec → start_services.sh` no filtra env vars (`docker/entrypoint.sh:118`). Mismo canal que `TELEGRAM_TYPING_MAX_MS` y `PLUGIN_POSTLOGIN_BUDGET`.
- `verify_channel_healthy`/`start_session` son **vírgenes de cobertura** (cero tests). El seam se crea desde cero.

## (a) Nombre de la variable — Decision: `CHANNEL_HEALTH_TIMEOUT`, segundos, default 60

**Rationale**: único candidato respaldado por inventario citado de tunables (`TELEGRAM_TYPING_MAX_MS` `apply_telegram_typing_patch.py:119`; `MARKETPLACE_CMD_TIMEOUT` `start_services.sh:579,622`; `PLUGIN_POSTLOGIN_BUDGET` `:257`; `QMD_EMBED_MAX_PASSES` `qmd_index.sh:463`). Patrón `<SUBSISTEMA>_<QUÉ>_<UNIDAD-o-ROL>`; sufijo de unidad solo cuando desambigua (`_MS`). Los tunables en segundos con "TIMEOUT/BUDGET" **no** llevan `_S` (el repo no tiene ningún `_S`/`_SECONDS`). "channel"+"health" reutiliza el vocabulario del sitio (`verify_channel_healthy`, `REQUIRED_CHANNEL_PLUGIN` `:229`, `CHANNEL_MARKER` `:243`).

**Unidad — segundos**: el loop razona en segundos; expresarlo en ms (paridad con `TELEGRAM_TYPING_MAX_MS`) obligaría a dividir por 1000 sin beneficio. El precedente se cita por su **mecanismo de entrega** (`env_file`), no por su unidad.

**Alternativas**: `CHANNEL_VERIFY_TIMEOUT` (menor tracción de vocabulario), `CHANNEL_HEALTHY_TIMEOUT_S` (`_S` inédito), `CHANNEL_HEALTHCHECK_TIMEOUT` ("healthcheck" colisiona con el healthcheck de modo local).

## (b) Resolución del valor — Decision: helper `channel_health_timeout()`, lectura en tiempo de llamada

```bash
# Resuelve el timeout de verificación de salud del channel (segundos).
# Ausente/vacío/no-numérico/<=0 -> 60. Se lee en tiempo de invocación
# para que los tests puedan overridear por entorno.
channel_health_timeout() {
  local t="${CHANNEL_HEALTH_TIMEOUT:-}"
  if ! [[ "$t" =~ ^[0-9]+$ ]] || [ "$t" -le 0 ]; then
    t=60
  fi
  printf '%s\n' "$t"
}
```

`:722` → `local timeout; timeout="$(channel_health_timeout)"`; `:760` → `... never appeared within $(channel_health_timeout)s ...`.

**Rationale (portabilidad verificada)**: `=~` **sin comillas** (bash 3.2 vuelve literal el patrón comillado; el repo lo usa así en `interval.sh:17`, `token_health.sh:133`, `wizard-validators.sh:150`). Cero construcciones bash-4-only. Cobertura: ausente/vacío/no-numérico → 60; `0` → falla `-le 0` → 60; el valor solo alimenta `[ -lt ]` (base-10), nunca `$(( ))` → sin riesgo octal.

**Por qué helper y no global source-time**: reconcilia un conflicto real. El seam de test (c) overridea `CHANNEL_HEALTH_TIMEOUT` por entorno en el `run` → exige lectura en tiempo de llamada; un global resuelto en source-time queda congelado al sourcear sin la var. El helper da (1) fuente única sin drift entre `:722` y `:760`, (2) lectura call-time, (3) validación. **No existe helper reutilizable** de parse+default+validación en `docker/scripts/lib/` (net-new); el más cercano, `heartbeatctl:521`, falla duro en vez de caer a default.

## (c) Seam de test host — Decision: `START_SERVICES_NO_RUN=1` + stub de `pgrep` (existente) y `sleep` (net-new)

- Guard de no-ejecución: `start_services.sh:1210`. `setup()` canónico: `tests/start-services-watchdog.bats:9-23` (`setup_tmp_dir` + `START_SERVICES_NO_RUN=1` + `source`).
- Stub `pgrep` ya probado: `start-services-watchdog.bats:86-92` (ejecutable falso en `$TMP_TEST_DIR/bin`, `PATH` prependeado en la línea del `run`). **Stub `sleep` es net-new** (nadie shadowea `sleep` hoy) pero idéntico en mecánica; seguro porque `verify_channel_healthy` solo lo usa para espaciar chequeos.
- Los `source lib/*.sh` del tope están guardados por `[ -f ]` → no-op en host; `verify_channel_healthy` no depende de ninguna lib.
- **Discriminador K=12**: `pgrep` se llama en `elapsed=2·(n-1)`; la 12ª llamada es `elapsed=22` → fuera del cap viejo de 20s, dentro del default de 60s. Tres casos RED→GREEN: aparece-en-22s (pasa-con-60/falla-con-20), nunca-aparece (retorna 1 sin dormir real, medido con `date +%s`), default-60-sin-setear-var.

## (d) Puntos de edición en `start_services.sh`

| Línea | Actual | Acción |
|---|---|---|
| `:722` | `local timeout=20` | `local timeout; timeout="$(channel_health_timeout)"` |
| `:760` | log `... never appeared within 20s ...` | interpolar `within $(channel_health_timeout)s` |
| `:719-720` | comentario `... up to 20s.` | actualizar a "default 60s, override CHANNEL_HEALTH_TIMEOUT" |
| nuevo | — | definir `channel_health_timeout()` visible por `verify_channel_healthy` **y** `start_session` |

`verify_channel_healthy` es el **único** consumidor del 20s (verificado). El log de `:760` vive en `start_session`, no ve `local timeout` → de ahí el helper para FR-005.

**Edición cruzada OBLIGATORIA**: `tests/docker-render.bats:162` assertea el literal `*"never appeared within 20s"*` → **se rompe** al volver dinámico el mensaje; actualizar junto con `:760`.

**NO tocar** (otros conceptos): `sleep 2` de `:728` (poll interval, acoplado a `elapsed+2`), literales `20` de `:830`/`:840` (bridge_watchdog revertido, código muerto), `MAX_CRASHES=5`/`WINDOW=300` (`:245-246`, crash budget — pero interactúa, ver (h)), `MARKETPLACE_CMD_TIMEOUT` (`:579,622`), `agentctl:685`.

## (e) Verificación DOCKER_E2E — Decision: `tests/docker-e2e-postlogin.bats`, entrega por `.env` real, aserción conductual

`docker-e2e-smoke.bats` NO ejercita `--channels` (`notifications: none`). `docker-e2e-postlogin.bats` sí es el camino de `--channels`/watchdog (`:119-143`), con precedente exacto de acortar un tiempo del watchdog en e2e (`PLUGIN_POSTLOGIN_BUDGET` inyectado, `:52-63`). Para 026 se prefiere el camino real (`.env`/`env_file`) sobre parchear `environment:`, para validar la cadena de entrega de producción. Asertar: WARN `never appeared within Ns` (`:760`) con el `N` configurado + presencia de la var (`docker compose exec -u agent … sh -c 'echo $CHANNEL_HEALTH_TIMEOUT'`). Un test de timing estricto se descarta por flaky. El unit host-side de (c) cubre la lógica; el e2e cubre la entrega.

## (f) Retiro del override de ferrari — Decision: desplegar imagen 026 primero, luego retirar, preservando `CHANNEL_HEALTH_TIMEOUT=90` en `.env`

**Forma real del override [VERIFICADO por el agente principal — lo aplicó hoy 2026-08-02]**: en el workspace de ferrari hay `docker-compose.override.yml` (no trackeado en git) que auto-mergea y bind-montea `.override/start_services.sh` (copia con `timeout=90`, `:ro`) sobre el baked. Esto **resuelve el `[DUDOSO]` del workflow**, que no podía leer el host remoto. El plan de retiro (abajo) es correcto para esta forma.

Secuencia: (1) `docker compose down`; (2) añadir `CHANNEL_HEALTH_TIMEOUT=90` al `.env`; (3) `rm docker-compose.override.yml`; (4) `rm -rf .override/`; (5) `docker compose build` (obligatorio — baked, ya no bind-mount); (6) `up -d`; (7) verificar imagen 026 (`grep CHANNEL_HEALTH_TIMEOUT /opt/agent-admin/scripts/start_services.sh` dentro del contenedor; si aparece `timeout=20`, no se reconstruyó); (8) confirmar `channel plugin healthy` sin WARN.

**Orden es precondición dura**: retirar el override antes de hornear 026 cae al baked pre-026 (`timeout=20`) → regresión. Se preserva `90` (no `60`) para riesgo conductual cero; bajar a 60 en ferrari es un cambio separado a medir aparte.

## (g) Docs a tocar — Decision: documentar donde ya vive `TELEGRAM_TYPING_MAX_MS`; NO tocar `env-example.tpl`

| Archivo | Acción |
|---|---|
| `README.md` (~:112, doc de `TELEGRAM_TYPING_MAX_MS`) | añadir `CHANNEL_HEALTH_TIMEOUT`, mismo estilo |
| `CLAUDE.md:67-75` (Watchdog state machine) | bullet: verify timeout configurable, default 60s, interacción crash budget |
| `docs/architecture.md:112-121` (pseudocódigo del loop) | añadir el paso de verify + su timeout |
| `docker/scripts/start_services.sh:720,760` | parte de (d) |

Ningún documento menciona "20s" literal (solo el código). **NO agregar a `env-example.tpl`**: verificado que todas sus entradas son secretos a rellenar (RHS vacío), no hay patrón de "variable opcional documentada"; agregarla inauguraría un patrón nuevo. El operador puede añadir `CHANNEL_HEALTH_TIMEOUT=<n>` a mano al `.env` y `--regenerate` no lo borra (las únicas escrituras de `.env` en `setup.sh` son wizard `:1251`, scaffold-move `:1899`, restore-fork `:1742` — ninguna dentro de `regenerate()` `:1941+`; `--regenerate` solo renderiza `.env.example`, `:2249`).

## (h) Interacción con el crash budget — [DECISIÓN USUARIO] el hallazgo crítico

**Mecánica [VERIFICADO]**: `MAX_CRASHES=5` (`:245`), `WINDOW=300` (`:246`); `crash_budget_check` (`:801-816`) dispara al 5º crash dentro de la ventana; `start_session` llama a `verify_channel_healthy` **síncronamente** (`:759`), bloqueando el watchdog T segundos; un timestamp de crash por iteración de fallo (`:1177-1181`).

**[INFERENCIA — cálculo aritmético, no medido en hardware]**: ciclo de fallo sostenido (bun nunca aparece) = `sleep 2` (`:1134`) + `start_session`[`sleep 1` (`:752`) + `sleep 2` (`:755`) + verify(T)] ≈ **T+5s**. El 5º crash cabe en la ventana si `4·(T+5) < 300` → **T < 70s**.

| T | ciclo | 5º crash a | ¿dispara budget? | margen |
|---|---|---|---|---|
| 20s (hoy) | 25s | ~100s | Sí | ~200s |
| **60s (default nuevo)** | 65s | ~260s | **Sí, apenas** | **~40s** |
| ≥70s (override, p.ej. ferrari 90) | ≥75s | — | **NO** — flapeo indefinido en vez de exit limpio | roto |

Dos costos del default 60: (1) el tiempo-hasta-restart de un fallo genuino casi se triplica (~100s → ~260s) — trade-off buscado, documentar; (2) el margen cae de ~200s a ~40s. **Con default 60 el crash budget SIGUE disparando** (260s < 300s); el problema aparece solo con **overrides ≥70s** (ferrari con 90 hoy los dispararía a nunca).

**Opciones de mitigación**: (A) cap duro del override <~65s + WARN — limita al operador, ferrari no podría usar 90; (B) escalar `WINDOW` en función de T — robusta pero el crash budget es global (cuenta también crashes de tmux/bun), escalarlo por el timeout del channel enturbia esos otros; (C) que verify no bloquee el watchdog — invasiva; (D) usar el valor tal cual + **WARN al boot si el override supera el umbral de margen** (sin cap) + documentar el trade-off.

**DECISIÓN DEL USUARIO (2026-08-02): opción D.** El operador puede fijar cualquier valor (ferrari conserva 90); cuando el timeout resuelto alcanza el umbral en que el crash budget deja de dar margen, el watchdog emite **una vez al boot** un WARN explicando que con ese valor el backstop de restart-de-contenedor puede no escalar. Sin cap, sin tocar el crash budget global. Umbral candidato **65s** (bajo el punto de ruptura 70s, con margen por overheads): el default 60 NO dispara el WARN; ferrari 90 SÍ. El número exacto lo fija el plan y lo valida un test.

**[INFERENCIA no medida]**: el umbral `T<70s` es aritmético; conviene validarlo con un test de `crash_budget_check` (ya hay cobertura en `start-services-watchdog.bats:27-73`) o medirlo en el gate.

## (i) VERSION / CHANGELOG — Decision: bump MINOR `0.16.0 → 0.17.0`, bajo `### Fixed`

VERSION actual `0.16.0` (`VERSION:1`). Precedente inequívoco: toda feature que toca runtime de producción bumpea MINOR, incluidos bug fixes (023 0.14→0.15, 024 0.15→0.16); solo se saltan el bump los tests-only (019, 025) y docs-only (020). 026 toca `docker/scripts/start_services.sh` (runtime) → MINOR. `### Fixed` (el motivo dominante es corregir el flapeo, como 023/024). Alternativa `### Changed` (por el cambio de default 20→60 + nueva var) — defendible, pero se recomienda Fixed.

## Riesgos y pendientes

1. **[DECISIÓN USUARIO — bloqueante del plan] Interacción crash budget (h).** El default 60 es seguro; el punto abierto es qué hacer con overrides ≥70s (ferrari usa 90). Recomendación: **opción D** (WARN sin cap + documentar), preserva libertad del operador y no toca el crash budget. Elevada al usuario antes de finalizar el plan.
2. **[RESUELTO por el agente principal] Forma del override de ferrari** (ver (f)): es bind-mount de `start_services.sh` parcheado vía `docker-compose.override.yml`. El plan de retiro es correcto.
3. **Edición cruzada obligatoria**: `tests/docker-render.bats:162` (`"never appeared within 20s"`) debe cambiar con `:760` o rompe.
4. **Stub de `sleep` es net-new**: primer test que shadowea `sleep`; verificado seguro para `verify_channel_healthy`.
5. **Granularidad `sleep 2`**: un override no-múltiplo-de-2 (p.ej. 61) redondea el techo efectivo hacia abajo al par (60). Documentar; el spec no exige normalizar.
6. **DOCKER_E2E es gate, no suite host**: el unit host-side de (c) cubre la lógica; el e2e cubre la entrega `.env → env_file`.
