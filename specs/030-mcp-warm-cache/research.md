# Research — 030 warm cache para MCPs fuera del catálogo

**Fase 0**. Medido, no inferido, vía un workflow de 5 agentes de lectura sobre los dos repos
(launcher + overlay `agentic-pod-launcher-custom-config`), más grep directo del catálogo. Cada
decisión cita evidencia `archivo:línea`. Constitución v1.0.1: evaluación en `plan.md`.

Nota de método: 4/5 agentes retornaron; el agente `launcher-mcp-render` reventó el retry cap de
StructuredOutput, pero su pregunta (formas de `command/args` en el `.mcp.json`, MCPs del catálogo que
son target de warm) quedó cubierta de forma redundante por los agentes `overlay-contract` y
`e2e-and-precedent` y por grep directo de `modules/mcps/*.yml` + `modules/mcp-json.tpl` — ver D3.

---

## D1 — Reparto de repos: el fix es 100% del launcher, cero cambio obligatorio en el overlay

**Decisión**: la solución vive enteramente en el launcher. El overlay NO requiere cambios.

**Rationale (medido)**: tras `custom-apply`, el `.mcp.json` del agente contiene fielmente cada MCP de
overlay — el merge (`lib/overlay.sh` `mcp_merge`, contrato M2/M3) es aditivo e idempotente, y
`custom-doctor` D1 asevera su presencia. Por lo tanto el `.mcp.json` **efectivo** es una fuente única
confiable de la que el launcher puede derivar la lista de paquetes a precalentar, **sin** que el overlay
declare nada nuevo — con una condición (D3): la derivación debe escanear `args`, no solo `command`.

**Alternativa considerada y descartada por innecesaria**: agregar un campo `warm: {runtime, package}`
a cada fragmento del overlay. Cambiaría una regla de parseo del launcher por un campo de schema en el
overlay; no es necesario porque el `.mcp.json` ya carga la invocación literal completa. Queda como
mejora OPCIONAL del overlay (no bloqueante, follow-up en ese repo si el equipo lo prefiere).

**Consecuencia**: un solo PR contra `main` del launcher cierra la feature; el overlay queda intacto.

---

## D2 — Momento del warm: en BOOT del contenedor, no en build

**Decisión**: el mecanismo de fondo es un **paso de warm en el arranque del contenedor** que lee el
`.mcp.json` ya mergeado. El warm de build hardcodeado de hoy (`docker/Dockerfile:121-125`) se **conserva**
(catálogo propio, sin regresión, primer boot rápido); el warm de boot es **aditivo** y general.

**Rationale (medido)**: `custom-apply` es una herramienta **host-side que el operador corre a mano**
(`bin/custom-apply.sh`; contrato `custom-apply-cli.md`); NO la dispara `docker build` ni `docker
recreate`. Su flujo: `./setup.sh --regenerate` (que borra los MCP de overlay del `.mcp.json`, contrato
M5) → re-merge de los fragmentos → recordatorio anti-flap "stop → ~150s → start" (no recrea el
contenedor). Secuencia real: **build (warm = lista fija del launcher) → scaffold/regenerate → operador
corre `custom-apply` en el host (los MCP de overlay entran al `.mcp.json`) → operador recrea el
contenedor**. Los MCP de overlay existen en el `.mcp.json` DESPUÉS del build y ANTES del recreate → un
warm de build **jamás** los cubre. Solo un warm que corre DENTRO del contenedor al arrancar, leyendo el
`.mcp.json` ya mergeado, cierra la brecha (evidencia: `overlay-contract` Q2, `custom-apply.sh:38-44,58-60,119`).

**Gap secundario**: un `--regenerate` sin `custom-apply` posterior deja el `.mcp.json` SIN los MCP de
overlay (M5). El warm de boot lee "lo que el `.mcp.json` tenga en ese momento": si el overlay no se
aplicó, warma el set del launcher (correcto, no regresión); si se aplicó, warma también los de overlay.
No hay estado inconsistente — el warm es una función del `.mcp.json` presente.

**Alternativa descartada**: warm solo-build (extender el `Dockerfile`). No satisface US1/FR-002 para el
incidente donna real. Documentado como no-solución.

---

## D3 — Algoritmo de derivación: args-aware, no `command`-only

**Decisión**: derivar los targets escaneando, por cada server del `.mcp.json`, la lista de tokens
`[command] + args`; hallar el primer token `uvx` o `npx` (o cuyo basename lo sea) y tomar el siguiente
token **no-flag** como el spec del paquete. Servers sin token uvx/npx (binarios, wrappers a binarios
horneados, remotos) se **omiten** (no necesitan warm).

**Rationale (medido)** — las formas reales en el `.mcp.json` final:

| Forma | Ejemplo (evidencia) | Paquete |
|---|---|---|
| `command=uvx, args=[<pkg>, …flags]` | fetch `mcp-server-fetch`, git `mcp-server-git --repository …`, time `mcp-server-time --local-timezone=…`, atlassian `mcp-atlassian`, aws `awslabs.aws-api-mcp-server@latest`, tree-sitter `mcp-server-tree-sitter` (`mcp-json.tpl:4-51`) | `args[0]` |
| `command=npx, args=["-y", <pkg>, …]` | filesystem `@modelcontextprotocol/server-filesystem`, firecrawl `firecrawl-mcp`, google-calendar `@cocal/google-calendar-mcp`, mcpvault `@bitbonsai/mcpvault@0.12.0` (`mcp-json.tpl:12-70`) | token tras `-y` |
| `command=npx, args=[<pkg>]` | playwright `@playwright/mcp@latest` (`mcp-json.tpl:16-17`) | `args[0]` |
| `command=<wrapper>.sh, args=["uvx", <pkg>]` | **google-workspace** `seed-google-creds.sh` + `["uvx","workspace-mcp"]` (overlay `google-workspace.json:3-5`) | token tras `uvx` |
| `command=npx, args=["-p", <pkg>, <bin>]` | open-meteo (overlay `open-meteo.json`) | token tras `-p` |
| `command=<binario>, args=[…]` | github-mcp-server `stdio`, qmd `{{QMD_MCP_COMMAND}}` (`mcp-json.tpl:62-75`) | ninguno → omitir |

El selector actual del local (`local-bootstrap.sh.tpl:92`,
`jq 'select(.value.command=="uvx") | .value.args[0]'`) falla en DOS formas: (a) NO ve google-workspace
(su `command` es el wrapper), y (b) aun si lo viera, tomaría `args[0]="uvx"` en vez de `"workspace-mcp"`.
Es exactamente el MCP del incidente el que el selector no puede ver. Docker hoy no tiene ningún selector
(warma una lista fija). La derivación args-aware corrige ambos.

**Fidelidad de pin (medido, riesgo real)**: los fragmentos npx pinnean versión (brave `@2.1.0`, open-meteo
`@2.0.1`); el `Dockerfile:198-201` advierte que un spec warmeado debe COINCIDIR con el spec de runtime o
el hit se pierde en silencio. Por eso la derivación toma el spec **literal de `args`** (con su `@version`),
NO una tabla de pins hardcodeada. La tabla `_mcp_pin` (`local-bootstrap.sh.tpl:74-81`) solo conoce
fetch/git/atlassian y se mantiene solo para esos; los paquetes de overlay se warmean al spec que declara
el `.mcp.json`.

**Flags a saltar**: `npx` `-y`/`--yes` (bandera), `-p <pkg>`/`--package <pkg>` (el pkg es el token
siguiente). `uvx` en el catálogo no usa flags antes del paquete.

---

## D4 — Ubicación e invariantes del warm de boot (docker)

**Decisión**: nuevo paso pre-`claude` en `docker/scripts/start_services.sh`, corriendo como el usuario
`agent`, **síncrono** (bloquea el arranque hasta completar o timeout), con **timeout por paquete** y
**fail-soft**, escribiendo a `/opt/uv` y `/opt/npm-cache`.

**Rationale (medido)**:
- **Por qué síncrono, no background**: el warm sirve solo si termina ANTES de que `claude` lance sus
  MCPs. Backgroundearlo (como el warm de QMD en `start_services.sh:170-175`, que sí puede correr en
  paralelo porque qmd se usa después) dejaría el race del mismo boot sin resolver. El costo síncrono se
  paga una sola vez (primer boot frío); los siguientes es un no-op idempotente. Un boot lento-pero-exitoso
  NO consume crash budget (`MAX_CRASHES=5`/`WINDOW=300` cuenta crashes, no lentitud) — pero el timeout
  por paquete evita un cuelgue indefinido si un paquete no resuelve.
- **Seam**: como los `pre_*` de `start_session()` (`:781-783`, antes del `tmux new-session` en `:797`)
  o al final de `boot_side_effects()` (`:134-176`). Corre como `agent` (privilegios ya bajados en
  `entrypoint.sh:118` vía `su-exec agent`), que es quien puede escribir `/opt/uv` y `/opt/npm-cache`
  (chown'd a `agent`, `Dockerfile:125,211`).
- **Caches: reusar los existentes** (`/opt/uv` con `UV_TOOL_DIR`/`UV_CACHE_DIR`, `/opt/npm-cache` con
  `NPM_CONFIG_CACHE`) — ya están FUERA de `/home/agent` (el montaje de estado no los tapa: `Dockerfile:108-120,189-211`),
  que es exactamente FR-004. No inventar ubicación nueva. `UV_PYTHON_PREFERENCE=only-system` ya resuelve
  el edge case "no auto-descargar un CPython gestionado".
- **Fail-soft (FR-007)**: cada warm es best-effort (`|| warn "… (will resolve on first use)"`,
  patrón `local-bootstrap.sh.tpl:108`); un fallo degrada al comportamiento de 029 (ventana ancha), no
  aborta el boot.
- **Sin secretos (FR-006/SC-005)**: instalar un paquete no lee `.env` ni credenciales; el paso corre
  independiente de la carga de secretos. Instalar `workspace-mcp` no requiere los `GOOGLE_OAUTH_*` que
  su *arranque* sí pide.
- **Testabilidad**: `start_services.sh` es image-baked (no está en `scripts/lib`), los bats lo sourcean
  directo; la función nueva debe guardar side-effects tras `START_SERVICES_NO_RUN`/`BASH_SOURCE`
  (patrón `:1256`) para correr en host sin Docker.

---

## D5 — Alcance de modo local (decisión del operador: paridad de derivación)

**Decisión** (elegida por el operador, 2026-08-17): en local, **arreglar el selector de
`provision_uv_tools` a args-aware** (que cubra el wrapper google-workspace); mantener warm uvx-only
(NO sumar warm de npx en local); corre en `--login` como hoy.

**Rationale (medido)**: `provision_uv_tools` (`local-bootstrap.sh.tpl:90-110`) ya warmea uvx en
`--login`, pero con el selector `command=="uvx"` que NO ve el wrapper (D3). El warm de npx no existe en
local (`provision_node_links` solo symlinkea node/npm/npx, `:116-139`); y `--regenerate` solo RENDERIZA
el bootstrap, no lo ejecuta (`setup.sh:2364`) — solo `--login` lo corre. La paridad de **derivación**
cierra la clase del incidente (el wrapper) en ambos modos; el gap de npx-en-local y el de
warm-en-regenerate son **preexistentes, separados del incidente**, y quedan fuera de 030 (documentados
como deuda conocida). Sin `sudo` (el bootstrap escribe en `~/.local/bin` y caches del HOME del operador).

---

## D6 — Single-source de la derivación: `scripts/lib/mcp_warm.sh`

**Decisión**: la derivación + el warm viven en una lib nueva `scripts/lib/mcp_warm.sh` (host, testeable
por bats en aislamiento, side-effects guardados por `BASH_SOURCE`). Expone:
- `mcp_warm_targets <mcp_json_path>` — emite líneas `uvx<TAB><pkg>` / `npx<TAB><pkg>` (pura, sin red).
- `mcp_warm_run <mcp_json_path>` — ejecuta el warm timeout-bounded + fail-soft (docker boot).

**Distribución** (patrón medido de libs compartidas host↔docker):
- **Host bats**: sourcean `scripts/lib/mcp_warm.sh` directo.
- **Docker boot**: se mirrorea a `docker/scripts/lib/mcp_warm.sh` por el mismo mecanismo que
  `mcp-catalog.sh` (mirror en scaffold, ver `setup.sh` mirror; alternativa: git-track + COPY como
  `backup_config.sh`) y `start_services.sh` la sourcea. **Gotcha `docker-lib-needs-explicit-copy`**: sin
  la línea de mirror/COPY, docker corre código viejo → el plan/tasks lo verifica.
- **Local**: `provision_uv_tools` usa la MISMA derivación (`mcp_warm_targets`), evitando duplicar el
  jq. La ubicación exacta de la lib para el bootstrap local (copiada al workspace vs sourced) se fija en
  tasks; el invariante es **una sola fuente de la derivación**.

**Rationale**: Principio I (fuente única) y VI (no duplicar). La derivación es no-trivial (parseo de
flags) y compartida por tres consumidores (docker boot, local bootstrap, tests) → merece una lib.

---

## D7 — DOCKER_E2E: obligatorio; forma del gate

**Decisión**: la feature REQUIERE DOCKER_E2E (toca `start_services.sh` y posiblemente `Dockerfile`,
ambos image-baked, `Dockerfile:231`). Se difiere a un host Docker (sin daemon en esta sesión), como
016/017/026. La suite host bats (sin Docker) cubre la derivación pura y el saneo.

**Forma del e2e (SC-001, medido)** — reusar el patrón offline de `docker-e2e-vault.bats:207-224` y
`docker-e2e-versions.bats`:
- `docker compose run` **no tiene** flag `--network`; el "corte de red" es el flag offline del gestor
  (`UV_OFFLINE=1 uvx <pkg> --help` / `uv tool list | grep <pkg>` para uvx; `npm exec --offline
  --prefer-offline …` para npx). Un hit offline = éxito; un intento de registro = fallo. Es una prueba
  MÁS fuerte que un corte de namespace.
- Scaffold de un agente que declara un MCP estilo-overlay (`workspace-mcp`, el paquete del incidente) →
  `docker compose build` → recrear → probar OFFLINE con `-u agent` y entrypoint override.
- **RED**: build con el warm de boot desactivado por build-arg (patrón `QMD_NATIVE_TOOLCHAIN=0` de
  `docker-e2e-qmd.bats:417`) → la prueba offline falla → prueba de que el paso es load-bearing.
- **FR-004**: `test -d /opt/uv` y `test -d /opt/npm-cache` fuera del bind-mount.

**Riesgo abierto (a verificar al correr el e2e)**: que `uv --offline`/`UV_OFFLINE=1` efectivamente
FALLE sobre un cache frío (a diferencia de `npm --offline`, ya probado en vault-e2e, el comportamiento
offline de uv no está verificado en el repo). Si no falla en frío, el caso RED del e2e sería un
falso-verde; el quickstart incluye un paso para confirmarlo en el host Docker antes de confiar en el
gate.

---

## D8 — Precedentes a reusar

- **029** (env plumbing a ambos modos): si se necesita un toggle/knob (p. ej. un timeout de warm por
  paquete configurable), reusar `docker-compose.yml.tpl` `environment:` + `remote-control.env.tpl` +
  saneo en render + backfill `has()`. Para 030 el warm es interno; un knob de timeout es opcional.
- **016/013** (caches off-mount): `/opt/uv`, `/opt/npm-cache`, symlink `bunx`, `UV_PYTHON_PREFERENCE`.
- **versions.sh** (Principio VI, single-source de pins): `AGENTIC_FLOOR_MCP_*` para el catálogo; los
  paquetes de overlay son unpinned por diseño (se warmean al spec de `.mcp.json`).
- **027** `provision_uv_tools` (`uv tool install <pkg> --with mcp==<lib>`): base del warm uvx.

---

## Preguntas abiertas: NINGUNA que bloquee el diseño

La incógnita central del brief (dónde vive `custom-apply` y el reparto de repos) quedó resuelta (D1).
El único ítem no verificable en esta sesión es el comportamiento offline de `uv` (D7), que es un gate de
ejecución del e2e (host Docker), no una decisión de diseño; el quickstart lo agenda.
