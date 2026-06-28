# Research: Instalación al boot de plugins de marketplaces de terceros

**Feature**: 009-fix-extra-marketplace-install · **Fecha**: 2026-06-23

Resuelve las incógnitas de diseño previas a Phase 1. Root cause ya confirmado (evidencia runtime + código); aquí se decide el mecanismo del fix.

## Contexto del código (verificado en v0.4.2)

- `OFFICIAL_MARKETPLACE_SOURCE="anthropics/claude-plugins-official"`, `OFFICIAL_MARKETPLACE_NAME="claude-plugins-official"` (start_services.sh:152-153).
- `ensure_official_marketplace` (start_services.sh:488-513): si `marketplace list | grep NAME` ya lo muestra, retorna; si no, `claude plugin marketplace add SOURCE --scope user` y loguea. Cada llamada a `claude` va acotada con `timeout ${MARKETPLACE_CMD_TIMEOUT:-12}` (degrada a llamada directa si `timeout` ausente). Fail-silent (siempre `return 0`).
- `pre_accept_extra_marketplaces` (start_services.sh:458-481): para los marketplaces de terceros declarados, hace `jq` merge en `~/.claude/settings.json` → `.extraKnownMarketplaces`. NO ejecuta `marketplace add` ni confirma. El JSON proviene de `plugin_catalog_marketplaces_json` (scripts/lib/plugin-catalog.sh:93), p.ej. `{"thedotmack":{"source":{"source":"github","repo":"thedotmack/claude-mem"}}}`.
- `modules/plugins/claude-mem.yml`: `spec: claude-mem@thedotmack`, `marketplace: {source: github, repo: thedotmack/claude-mem}`. El "key" del marketplace (`thedotmack`) es el sufijo `@thedotmack` del spec; el repo github es `thedotmack/claude-mem`.
- `retry_plugin_install_bounded` (docker/scripts/lib/plugin-install.sh:30-53): `claude plugin install SPEC`; si el error matchea `'no marketplaces configured|not found in marketplace|unknown marketplace|marketplace .*not found'` retorna **2 (skip transitorio, sin reintento)**.
- `ensure_all_plugins_installed` corre solo dentro de `next_tmux_cmd`, que solo se invoca en respawns de tmux; en estado estable (Case C) la sesión queda viva → el skip nunca se reintenta.

## Decisiones

### D1 — Asegurar cada marketplace de terceros con `marketplace add` confirmado (paralelo al oficial)

**Decisión**: Añadir `ensure_extra_marketplaces` en `start_services.sh`: para cada par `(key, repo)` derivado de `plugin_catalog_marketplaces_json`, si `marketplace list | grep key` no lo muestra, ejecutar `claude plugin marketplace add <repo> --scope user`; idempotente (skip si ya presente), cada llamada a `claude` acotada con `timeout ${MARKETPLACE_CMD_TIMEOUT:-12}` (degrada a directa si ausente), fail-silent (`return 0`). Estructura espejo de `ensure_official_marketplace`.

**Rationale**: El root cause es que el marketplace de terceros nunca se *resuelve* (clona) antes de instalar su plugin — solo se declara en `extraKnownMarketplaces`. El oficial sí se resuelve con `marketplace add` confirmado y por eso sus plugins instalan. Aplicar el mismo patrón cierra la asimetría en la raíz. El `timeout` mantiene el Principio IV (un clon lento sobre VirtioFS no debe colgar el boot).

**Alternativas consideradas**:
- *Solo reintentar el skip rc=2*: rechazada — no resuelve la causa (el marketplace sigue sin clonar); reintentar `plugin install` sin `marketplace add` volvería a fallar.
- *Confiar solo en `extraKnownMarketplaces`*: es el estado actual y es justamente lo que falla. Rechazada.

### D2 — Mantener `pre_accept_extra_marketplaces`; añadir `ensure_extra_marketplaces` y ordenarla antes del install

**Decisión**: No eliminar `pre_accept_extra_marketplaces` (el merge en `extraKnownMarketplaces` puede seguir siendo necesario para que la CLI reconozca `@key` en specs y es barato/sin red). Encadenar en `next_tmux_cmd`: `pre_accept_extra_marketplaces` → `ensure_extra_marketplaces` (nuevo) → `ensure_official_marketplace` → `ensure_all_plugins_installed`. Así todo marketplace de terceros queda resuelto antes del loop de instalación.

**Rationale**: Cambio aditivo y de bajo riesgo; preserva el comportamiento existente y solo agrega el paso de resolución que faltaba. Consolidar/eliminar `extraKnownMarketplaces` sería una limpieza separada fuera de alcance.

**Alternativas consideradas**: *Reemplazar `pre_accept_extra_marketplaces` por el `add`*: rechazada por ahora — mayor superficie de cambio y riesgo de regresión en la resolución de `@key`; se deja como posible consolidación futura (Principio VI, "consolidar al tocar" no obliga aquí porque no es un pin duplicado).

### D3 — Derivación de `(key, repo)`

**Decisión**: Reutilizar `plugin_catalog_marketplaces_json /workspace/agent.yml` y extraer con `jq` los pares `key` (clave del objeto) y `repo` (`.[key].source.repo`). Iterar y registrar cada uno. Sin nuevos descriptores ni cambios de catálogo.

**Rationale**: La fuente de verdad ya existe y está espejada al build context (sobrevive `--regenerate`). No se introduce duplicación.

### D4 — Estrategia de tests (Principio III, test-first)

**Decisión**:
- *Host-side (sin Docker)*, nuevo archivo `tests/start-services-extra-marketplace.bats`, sourcea `start_services.sh` con `START_SERVICES_NO_RUN=1` (patrón de `tests/start-services-marketplace.bats` del fix 008). Casos: (a) registra un marketplace de terceros ausente vía `marketplace add` y confirma; (b) idempotente — no re-agrega si ya está en `marketplace list`; (c) acotado — ante un `claude` que cuelga retorna dentro del límite (shim de `timeout` en macOS); (d) degrada si `timeout` ausente; (e) no-op si `claude` ausente. Escritos y en rojo antes de implementar.
- *DOCKER_E2E*: extender el camino post-login para declarar un plugin de marketplace de terceros y afirmar su instalación al boot. El stub `claude` del e2e debe manejar `plugin marketplace add <repo-de-terceros>` y `plugin install <plugin>@<key>` (hoy solo maneja la familia oficial). Reusar la infraestructura de `tests/docker-e2e-postlogin.bats`.

**Rationale**: Cobertura host-side rápida del nuevo helper + cobertura E2E del camino que ocultó el bug (cierra FR-008/FR-009 y el hueco de proceso de US3).

### D5 — Acotación y portabilidad de `timeout`

**Decisión**: Reusar el patrón del fix 008: `_to="timeout ${MARKETPLACE_CMD_TIMEOUT:-12}"` solo si `command -v timeout`; en macOS host (sin `timeout`) los tests proveen un shim en PATH. La variable `MARKETPLACE_CMD_TIMEOUT` ya existe y se reutiliza (sin nueva config).

**Rationale**: Consistencia con el código existente; evita introducir un segundo mecanismo de acotación.

## Asunciones a validar en E2E

- `claude plugin marketplace add <owner>/<repo>` registra el marketplace de terceros con el `key` esperado (el sufijo `@key` del spec), igual que el oficial registra `claude-plugins-official`. Confirmado parcialmente en runtime: tras el boot, `marketplace list` mostró `thedotmack — GitHub (thedotmack/claude-mem)`. El E2E lo fija como contrato.
- El stub `claude` del e2e puede emular `marketplace add` de terceros de forma no bloqueante (igual que ya emula la familia oficial tras el fix 008).
