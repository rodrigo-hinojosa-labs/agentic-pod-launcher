# Fase 0 — Research: ventana de handshake MCP configurable

Todas las incógnitas de la spec resueltas por **medición** (binario de Claude Code) y **mapeo del
código** (3 exploradores en paralelo). Nada inferido de documentación sin verificar.

## D1. La variable de entorno y su default (MEDIDO en el binario)

**Decisión**: la ventana de handshake de **arranque** del MCP es la variable de entorno
**`MCP_TIMEOUT`**, con **default 30000 ms (30 s)**.

**Cómo se midió**: el binario nativo de Claude Code del host (`~/.local/share/claude/versions/2.1.223`,
Mach-O arm64; la imagen pinea `2.1.220`, tres patches atrás) es un ejecutable con el bundle JS
embebido. `strings` sobre el binario expone los getters de timeout:

```js
function qw(){  let e = te.MCP_TIMEOUT;             return e && e>0 ? e : 30000 }   // arranque MCP
function ghd(){ let e = te.MCP_CONNECT_TIMEOUT_MS;  return e && e>0 ? e : 5000  }   // dial/connect remoto
function FNs(e){ let t = Rp(process.env.MCP_TOOL_TIMEOUT), ... }                    // timeout de tool-call
```

Y la cadena `"Per-server tool-call timeout ... Overrides the MCP_TOOL_TIMEOUT environment variable"`
confirma que `MCP_TOOL_TIMEOUT` es la de **tool calls**, no la de arranque.

**Las tres variables MCP de timeout, separadas**:

| Variable | Default | Qué controla | ¿Es la del incidente? |
|---|---|---|---|
| `MCP_TIMEOUT` | **30000 ms** | ventana de **arranque/handshake** del server | **Sí** |
| `MCP_TOOL_TIMEOUT` | (sin default fijo; per-call) | timeout de ejecución de una tool | No |
| `MCP_CONNECT_TIMEOUT_MS` | 5000 ms | dial/connect de servers **remotos** (HTTP/SSE) | No (el incidente es stdio) |

**Rationale del incidente**: `workspace-mcp` descargó su wheel de PyPI durante el boot (~50 s medido
en ferrari), y 50 s > 30 s (default de `MCP_TIMEOUT`) → el handshake expiró y Claude Code marcó el
server como failed **sin reintento**. Con el cache caliente el arranque baja a 3 s (< 30 s) y no falla:
por eso `docker restart` lo resolvió. `MCP_TIMEOUT` seteado y > 0 lo usa; si no, 30000.

**Alternativas consideradas**: `MCP_TOOL_TIMEOUT` (descartada: es tool-call, no arranque);
`MCP_CONNECT_TIMEOUT_MS` (descartada: dial de remotos, el incidente es un server stdio local).

**Residual**: la medición es sobre 2.1.223, no la 2.1.220 exacta pineada. El default `30000` y el
patrón del getter son estables; una reconfirmación sobre la imagen 2.1.220 exacta puede hacerse en el
gate de despliegue, pero no bloquea el diseño (el mecanismo es agnóstico al valor exacto del default
del binario).

## D2. Default de la feature: 120000 ms (120 s)

**Decisión**: default **120000 ms (120 s)** cuando el operador no configura nada.

**Rationale**: el peor caso medido de descarga en frío es ~50 s. 120 s da holgura ~2.4x y supera con
margen el default del binario (30 s), cerrando el incidente out-of-the-box. Es más generoso que los
60 s de la 026 a propósito: la 026 esperaba la *aparición de un proceso ya instalado* (`bun server.ts`,
~22-25 s de contención), mientras que aquí el peor caso incluye la *descarga e instalación completa*
del paquete. El valor es orientativo y ajustable por el operador (US1).

## D3. Mecanismo: campo en `agent.yml`, no en el `.env` (contraste con 026)

**Decisión**: el valor vive en **`agent.yml`** como fuente única y se rendea a **dos artefactos**
(uno por modo). La 026 usó el `.env` del workspace; aquí no aplica ese atajo.

**Rationale**:
- La 026 (`CHANNEL_HEALTH_TIMEOUT`) es **docker-only** y su consumidor es un script bash image-baked
  (`docker/scripts/start_services.sh:727`) que lee la var en runtime dentro del contenedor. El `.env`
  vía `env_file` bastó. Su research lo dice explícito: prefirió el `.env` "para validar la cadena de
  entrega de producción" (`specs/026-channel-watchdog-timeout/research.md:68`).
- La 029 aplica a **ambos modos**. En modo local el `.env` del workspace históricamente no llegaba a
  la sesión (feature 021 lo arregló para la unit, pero el `.env` es operator-owned, para secretos, no
  derivado de `agent.yml`). Un `.env` directo no da una fuente única cross-mode.
- El Principio I exige que todo derivado salga de `agent.yml`; FR-004 exige que docker y local deriven
  del **mismo campo sin duplicar el literal**. Eso obliga a anclar en `agent.yml`.

**Ubicación del campo: `claude.mcp_timeout_ms`** (flatten → `CLAUDE_MCP_TIMEOUT_MS`).

**Rationale de la ubicación** (evaluadas 4 opciones):

| Opción | Veredicto |
|---|---|
| `docker.mcp_timeout_ms` | **Descartada**: `docker:` alimenta **build args** del compose (`docker-compose.yml.tpl:11-21`), es específico de docker; no tiene sentido en local. |
| bloque nuevo `mcp:` | Descartada: casi-colisión visual/flatten con `mcps:` (catálogo de servers existente); riesgo de confusión `MCP_*` vs `MCPS_*`. |
| `mcps.handshake_timeout_ms` | Descartada: mezcla config de runtime con el catálogo de servers (`mcps.defaults[]`, `mcps.github`). |
| **`claude.mcp_timeout_ms`** | **Elegida**: el bloque `claude:` (`setup.sh:1203-1205`: `config_dir`, `profile_new`) es config del **binario Claude Code, cross-mode**. `MCP_TIMEOUT` es exactamente eso. Flatten `CLAUDE_MCP_TIMEOUT_MS` sin colisión con `mcps:` ni con la env var `MCP_TIMEOUT`. |

## D4. Entrega a los dos artefactos (el análogo `TZ` ya existe)

**Decisión**: dos plantillas leen el **mismo** placeholder saneado y escriben la env var `MCP_TIMEOUT`:

- **Docker**: una línea en el bloque `environment:` de `modules/docker-compose.yml.tpl:61-66`, hermana
  de `TZ: "{{USER_TIMEZONE}}"`. El bloque `environment:` hoy declara solo `TZ`; el env del compose
  llega **intacto** al proceso `claude` (ver D5). → `MCP_TIMEOUT: "{{CLAUDE_MCP_TIMEOUT_MS}}"`.
- **Local**: una línea en `modules/remote-control.env.tpl` (el segundo `EnvironmentFile` de la unit de
  sesión, `systemd-remote-control.service.tpl:21`, que gana en precedencia). Ya rendea config
  no-secreta (`CLAUDE_CONFIG_DIR`, `DISABLE_AUTOUPDATER`, `HOME`, `PATH`). →
  `MCP_TIMEOUT={{CLAUDE_MCP_TIMEOUT_MS}}`.

**Rationale del canal local** (recomendación del mapeo): `remote-control.env.tpl` se re-rendea en
**cada** `--regenerate` (`setup.sh:2349`), sin `sudo` y sin reinstalar el unit file; solo requiere
`systemctl restart`. Poner la var en el unit file (`Environment=`) la ataría a `sudo` +
`install_service` + `daemon-reload`. Además el unit file no siempre se re-rendea en `--regenerate` (si
`install_service≠true`). El `.env` se descarta: rompería FR-004 (no deriva de `agent.yml`) y el
edge-case del `.env` no entregado en local (`spec.md`).

**Alcance local (verificado)**: solo la unit de sesión (`claude remote-control`,
`systemd-remote-control.service.tpl:38`) lanza `claude`. Las demás units (healthcheck, qmd-reindex,
qmd-watch, vault-backup, wiki-graph) no lanzan `claude`. El `qmd-mcp` es hijo del proceso `claude` y
hereda su entorno. → entregar `MCP_TIMEOUT` a la sesión cubre a todos los MCPs transitivamente.

## D5. Gate: la 029 NO requiere DOCKER_E2E (env passthrough verificado)

**Decisión**: la feature es **host-testeable con `bats`**; DOCKER_E2E **no es requerido**.

**Rationale (verificado en el mapeo)**: agregar una var al bloque `environment:` de
`modules/docker-compose.yml.tpl` **no toca código image-baked**:
- `docker/entrypoint.sh:118` termina en `exec su-exec agent .../start_services.sh` — `su-exec`
  **preserva** el environment (no lo limpia); el propio entrypoint lee `TZ` del compose (`:25`).
- `docker/scripts/start_services.sh:797` lanza `claude` vía `tmux new-session` **sin** `env -i`,
  `tmux set-environment`, `unset` ni reconstrucción del env → `claude` hereda el env del compose intacto.
- El consumidor de `MCP_TIMEOUT` es **el binario `claude` nativo**, no un nuevo lector bash baked (a
  diferencia de la 026, que añadió `channel_health_timeout()` a `start_services.sh` y por eso sí
  necesitó DOCKER_E2E).

`modules/docker-compose.yml.tpl` está bajo `modules/` (host-rendered), no bajo `docker/`; no cambia
comportamiento de boot/supervisor. El gate de la constitución (DOCKER_E2E para cambios que tocan
`docker/` o boot/supervisor) **no se dispara**. Opcionalmente, un e2e de *entrega de env* estilo
`tests/docker-e2e-postlogin.bats:189-191` (026: `printenv CHANNEL_HEALTH_TIMEOUT`) podría verificar
`printenv MCP_TIMEOUT` en un host con Docker, pero es nice-to-have, no requerido.

## D6. Validación y default seguro (saneo en el render, no en runtime)

**Decisión**: el saneo (validar entero > 0, degradar al default ante inválido) ocurre en **`setup.sh`
al rendear** (host), no en runtime.

**Rationale**: a diferencia de la 026 (que sanea en runtime dentro del contenedor con
`channel_health_timeout()`), la 029 no tiene un lector bash runtime — `claude` lee `MCP_TIMEOUT`
nativo, y si le llega basura cae a **su** default (30000), no al **nuestro** (120000). Para garantizar
el default de la feature ante un valor inválido, el saneo debe ocurrir antes de escribir los
artefactos. Patrón a copiar (molde exacto): `docker/scripts/start_services.sh:726-728`
(`if ! [[ "$t" =~ ^[0-9]{1,6}$ ]] || [ "$t" -le 0 ]; then t=<default>; fi`).

**Mecánica**: tras `render_load_context` (que exporta el flatten crudo `CLAUDE_MCP_TIMEOUT_MS`),
`setup.sh` valida el valor y **re-exporta `CLAUDE_MCP_TIMEOUT_MS`** con el valor efectivo (saneado). Un
helper `mcp_timeout_effective()` (patrón `_export_local_context`, `setup.sh:2466-2479`). Ambos
templates usan `{{CLAUDE_MCP_TIMEOUT_MS}}` → reciben el mismo valor saneado (FR-004 + FR-006). Regex
propuesta: `^[0-9]{1,7}$` y `> 0` (hasta ~2.7 h en ms; sin tope duro por debajo de eso, coherente con
el edge-case "valor muy alto no se acota salvo razón").

**Sin validación dura en el schema**: FR-006 pide **no fallar** el arranque ante valor inválido, sino
degradar. Una validación dura en `schema.sh` (`agent_yml_validate`) haría fallar `--regenerate` — lo
contrario de lo pedido. El schema registra el campo como opcional; el saneo con degradación vive en el
render. (`schema.sh` hoy no tiene mecanismo de validación de enteros; no se agrega uno para esto.)

## D7. Backfill para agentes existentes (patrón 028, con `has()`)

**Decisión**: backfill en `regenerate()` (`setup.sh:1965`, bloque `if [ -f "$agent_yml" ]`) con
detección de presencia por `has()`, no por `// default`.

**Rationale**: el gotcha del `//` de yq (documentado en `schema.sh:89-93` y `CLAUDE.md:172`) colapsa un
valor "presente pero falsy" a `""`. Para 029 el riesgo es real: `0` es un valor presente-pero-inválido,
y `yq -r '.claude.mcp_timeout_ms // 120000'` colapsaría un `0` a 120000, ocultando que el operador puso
`0` (que debe degradar por el saneo de D6, no por el backfill). El backfill solo debe escribir cuando el
campo está **ausente**:

```bash
if [ "$(yq -r '(.claude | has("mcp_timeout_ms")) // false' "$agent_yml" 2>/dev/null)" != "true" ]; then
  yq -i '.claude.mcp_timeout_ms = 120000' "$agent_yml"
fi
```

Molde: el backfill de `reply_guard` de la 028 (`setup.sh:2048-2060`). Idempotente: un valor puesto por
el operador sobrevive; segunda pasada byte-estable.

## Resumen de decisiones

| # | Decisión |
|---|---|
| D1 | Variable = `MCP_TIMEOUT` (arranque), default del binario 30000 ms (medido en 2.1.223) |
| D2 | Default de la feature = 120000 ms (120 s), holgura ~2.4x sobre los ~50 s de descarga en frío |
| D3 | Campo `claude.mcp_timeout_ms` en `agent.yml` (fuente única cross-mode), no el `.env` |
| D4 | Entrega: docker `environment:` (como `TZ`) + local `remote-control.env` (2º EnvironmentFile) |
| D5 | Sin DOCKER_E2E requerido (env passthrough a `claude` verificado; sin consumidor baked nuevo) |
| D6 | Saneo (entero>0 → default) en el render host (`setup.sh`), no en runtime; re-export del flatten |
| D7 | Backfill en `regenerate()` con `has()` (patrón 028), evita el gotcha del `//` con `0` |
