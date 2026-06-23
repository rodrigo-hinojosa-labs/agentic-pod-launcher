# Contrato: ensure_official_marketplace (acotado) + stub `claude` del E2E

Fija el comportamiento esperado tras el fix. No cambia la semántica del happy path; agrega resiliencia (timeout) y completa el doble de prueba.

## `ensure_official_marketplace` (docker/scripts/start_services.sh)

Pre: corre en el boot path desde `next_tmux_cmd`, antes de iniciar tmux. `CLAUDE_CONFIG_DIR_VAL`, `OFFICIAL_MARKETPLACE_NAME`, `OFFICIAL_MARKETPLACE_SOURCE` definidos.

Contrato:

| Condición | Comportamiento esperado |
|---|---|
| `claude` ausente (`command -v claude` falso) | retorna 0 sin hacer nada (ya existente) |
| marketplace ya registrado (`marketplace list` contiene el nombre) | retorna 0 temprano, no llama `add` |
| no registrado, `add` OK | loguea "registered", retorna 0 |
| no registrado, `add` falla | loguea WARN, retorna 0 (reintenta próximo tick) |
| **`claude` cuelga en `marketplace list`/`add`** | **`timeout` aborta la llamada en ≤ N s; loguea WARN; retorna 0. NUNCA bloquea el boot.** |
| `timeout` no disponible en PATH | degrada a la llamada directa (sin timeout); no rompe |

Invariantes:
- Siempre `return 0` (fail-silent; Principio IV).
- Nunca cuelga indefinidamente cuando `timeout` está disponible.
- El happy path (claude real, respuesta <1s) no cambia su salida ni su orden.

## Stub `claude` del E2E (tests/docker-e2e-postlogin.bats)

El stub modela el lag de auth. Debe responder NO BLOQUEANTE a toda la familia `plugin`:

| Invocación | Respuesta del stub |
|---|---|
| `plugin marketplace list` | imprime nada, exit 0 (→ el supervisor procede a `add`) |
| `plugin marketplace add ...` | exit 0 (registro "exitoso") |
| `plugin install <spec>` | si existe `.credentials.json`: crea `cache/<mkt>/<name>/.installed-ok`, exit 0; si no: `Error: Not authenticated`, exit 1 (lógica actual) |
| `plugin list` | exit 0 (sin plugins aún) |
| bare `claude` (sesión) | `exec sleep 86400` (mantiene tmux vivo) — ÚNICO caso que duerme |

Regla: el `exec sleep 86400` se reserva exclusivamente para la sesión interactiva. Cualquier subcomando `plugin` retorna rápido. Esto evita que `ensure_official_marketplace` (006) cuelgue el boot.

## Entrega del lib (docker/Dockerfile)

| Aserción | Esperado |
|---|---|
| Dockerfile contiene COPY de plugin-install.sh | `COPY scripts/lib/plugin-install.sh /opt/agent-admin/scripts/lib/plugin-install.sh` |
| Tras scaffold, presente en el build context | `<dest>/docker/scripts/lib/plugin-install.sh` existe (vía copia wholesale) |
| En la imagen construida | `/opt/agent-admin/scripts/lib/plugin-install.sh` existe |
| En runtime, al sourcear el supervisor | `command -v retry_plugin_install_bounded` verdadero (no path legacy) |
