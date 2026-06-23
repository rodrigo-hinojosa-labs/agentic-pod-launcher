# Feature Specification: Reparar auto-instalación de plugins post-login (DOCKER_E2E a verde)

**Feature Branch**: `008-fix-postlogin-plugin-install`

**Created**: 2026-06-23

**Status**: Draft

**Input**: durante la validación E2E completa post-006/007 se detectó que `tests/docker-e2e-postlogin.bats` falla consistentemente (el plugin del canal no se auto-instala tras el flip de credenciales). Root cause confirmado con evidencia runtime + estática: tres defectos encadenados — un gap del stub que cuelga el boot, falta de timeout defensivo, y un lib de retry que nunca llega a la imagen.

## Contexto

La suite `DOCKER_E2E=1 bats tests/docker-e2e-*.bats` está en **11 tests, 1 fallando** desde el merge de 006/007 (el E2E no se corrió durante 006). La falla expuso tres defectos:

1. **Boot colgado (gap de test, alta):** 006 agregó `ensure_official_marketplace()` en `docker/scripts/start_services.sh`, invocada sincrónicamente desde `next_tmux_cmd` (vía `cmd=$(next_tmux_cmd)` en `start_session`, que corre **antes** de `_run_watchdog`). Hace `claude plugin marketplace list 2>/dev/null | grep -q "$OFFICIAL_MARKETPLACE_NAME"`. El stub `claude` del test (de feature 004) solo implementa `plugin install`; para `marketplace list` cae a `exec sleep 86400` → el pipe nunca cierra → `grep` bloquea → `start_session` se cuelga en la command-substitution → tmux nunca arranca → el watchdog nunca corre → el retry post-login nunca se ejecuta → 0 instalaciones. El `claude` real no cuelga (es operación local); es un gap del stub.

2. **Sin timeout defensivo (hardening prod, media):** `ensure_official_marketplace` llama a `claude` en el boot path sin acotar el tiempo. Si el `claude` real alguna vez cuelga ahí, el supervisor se bloquea antes de tmux/watchdog → contenedor unhealthy sin auto-recuperación. Viola el Principio IV (degradar con gracia, no colgar el supervisor).

3. **Lib de retry no llega a la imagen (defecto prod, baja-media):** `docker/scripts/lib/plugin-install.sh` está en el repo (categoría **image-only**, junto a `interval.sh`/`state.sh`/`backup_*.sh` bajo `docker/scripts/lib/`) y se copia al workspace vía la copia wholesale del árbol `docker/`, **pero el Dockerfile no tiene la línea `COPY`** que lo lleve a `/opt/agent-admin/scripts/lib/`. Verificado contra la imagen viva: `/opt/agent-admin/scripts/lib/` no lo contiene. Como `retry_plugin_install_bounded()` se define solo ahí, en runtime queda indefinido → `start_services.sh` cae al path legacy de instalación. El retry acotado de 004 US2 y la clasificación "marketplace not found vs not authenticated" de 006 US4 son **código muerto en la imagen**. Los plugins igual instalan (path legacy + reintentos del watchdog), así que el happy path funciona; se pierde el presupuesto acotado, el registro de fallas y la observabilidad de US4. (Nota: `mirror_catalog_to_docker` NO interviene — ese mirror es solo para libs **compartidas** de `scripts/lib/` host-launcher; `plugin-install.sh` es image-only y ya está en el build context.)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - El test post-login vuelve a verde (Priority: P1)

Como mantenedor del launcher, al correr `DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats` quiero que pase, de modo que la suite E2E completa vuelva a 0 fallas y el seam de integración del retro post-login quede verificado.

**Why this priority**: Es la falla que rompe la suite hoy. Sin esto, DOCKER_E2E no es señal confiable.

**Independent Test**: `DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats` → pasa. Y la suite E2E completa → 0 fallas.

**Acceptance Scenarios**:

1. **Given** el supervisor que en boot llama `claude plugin marketplace list/add` (006), **When** el test boota el contenedor con su stub `claude`, **Then** el stub responde a los subcomandos `plugin marketplace` (y `plugin list`) de forma no bloqueante → el boot completa, tmux arranca y el watchdog entra a su loop.
2. **Given** el contenedor booteado sin auth, **When** pasan ~15s, **Then** el plugin del canal NO está instalado (sentinel ausente).
3. **Given** el flip de credenciales (`.credentials.json` creado), **When** el watchdog detecta el flip, **Then** dentro del presupuesto el plugin del canal queda instalado (sentinel `.installed-ok` presente) sin intervención manual.

---

### User Story 2 - El boot no se cuelga si claude se cuelga (Priority: P2)

Como operador, quiero que el supervisor degrade con gracia si `claude plugin marketplace list` alguna vez no responde, de modo que un claude colgado no brickee el arranque del contenedor antes de que el watchdog pueda recuperarlo.

**Why this priority**: Hardening del modo de falla que este bug probó (catastrófico y silencioso). No bloquea US1 pero cierra un riesgo real de producción alineado al Principio IV.

**Independent Test**: host-side, stubear `claude` para que cuelgue en `marketplace list` y verificar que `ensure_official_marketplace` retorna dentro de un tiempo acotado (no cuelga indefinidamente).

**Acceptance Scenarios**:

1. **Given** un `claude` que cuelga en `plugin marketplace list`, **When** corre `ensure_official_marketplace`, **Then** la función retorna dentro de un límite acotado y registra una advertencia, en vez de bloquear el boot.
2. **Given** la imagen Alpine con `timeout` (busybox) disponible, **When** se acotan las llamadas a `claude`, **Then** el comportamiento del happy path (marketplace ya registrado, o registro exitoso) no cambia.

---

### User Story 3 - El retry acotado realmente corre en la imagen (Priority: P3)

Como mantenedor, quiero que `docker/scripts/lib/plugin-install.sh` llegue a la imagen, de modo que `retry_plugin_install_bounded` (feature 004 US2) y la clasificación de errores de marketplace (006 US4) se ejecuten en runtime en vez de caer al path legacy.

**Why this priority**: Restaura funcionalidad ya entregada pero muerta en la imagen. Severidad menor (el happy path instala vía legacy), pero hace que el seam post-login pruebe lo que dice probar y recupera la observabilidad/resiliencia.

**Independent Test**: host-side, verificar que el Dockerfile copia `scripts/lib/plugin-install.sh` (línea `COPY` análoga a las otras libs image-only); en runtime (DOCKER_E2E) verificar que `/opt/agent-admin/scripts/lib/plugin-install.sh` existe y `retry_plugin_install_bounded` está definido.

**Acceptance Scenarios**:

1. **Given** el Dockerfile, **When** se inspecciona, **Then** incluye `COPY scripts/lib/plugin-install.sh /opt/agent-admin/scripts/lib/plugin-install.sh` con el mismo patrón que las otras libs image-only (interval/state/backup_*).
2. **Given** una imagen construida, **When** se inspecciona `/opt/agent-admin/scripts/lib/`, **Then** `plugin-install.sh` está presente y, al sourcear `start_services.sh`, `retry_plugin_install_bounded` queda definido (no se toma el path legacy).
3. **Given** el flip post-login con el lib presente, **When** el watchdog instala el plugin, **Then** usa el path de retry acotado (no el legacy).

### Edge Cases

- **Happy path real (no test):** con `claude` real, `marketplace list` responde rápido; el timeout de US2 nunca dispara. El cambio no debe alterar el boot normal.
- **Marketplace ya registrado:** `ensure_official_marketplace` retorna temprano (grep encuentra el nombre); no llama a `marketplace add`.
- **El lib presente pero el stub incompleto:** si el stub del test no maneja algún subcomando que el path de retry acotado invoque, el boot podría colgarse de nuevo — el stub debe cubrir todos los subcomandos `plugin` que el boot/install usa (`marketplace list/add`, `plugin install`, `plugin list`).
- **`timeout` ausente:** si por alguna razón `timeout` no está en PATH, la guarda debe degradar a la llamada directa (no romper el boot) — preferir `command -v timeout` antes de usarlo.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: La suite `DOCKER_E2E=1 bats tests/docker-e2e-*.bats` DEBE terminar con 0 fallas tras el cambio.
- **FR-002**: El stub `claude` de `tests/docker-e2e-postlogin.bats` DEBE responder de forma no bloqueante a todos los subcomandos `plugin` que el boot/instalación invoca (`plugin marketplace list`, `plugin marketplace add`, `plugin install`, `plugin list`), reservando el `exec sleep` solo para la invocación de sesión interactiva (bare `claude`).
- **FR-003**: `ensure_official_marketplace` en `docker/scripts/start_services.sh` DEBE acotar sus llamadas a `claude` con un timeout, de modo que un `claude` que no responde no bloquee el boot; DEBE degradar a llamada directa si `timeout` no está disponible, y permanecer fail-silent (retorna 0, loguea advertencia).
- **FR-004**: `docker/Dockerfile` DEBE incluir `COPY scripts/lib/plugin-install.sh /opt/agent-admin/scripts/lib/plugin-install.sh` con el mismo patrón que las otras libs image-only (interval/state/backup_*, líneas 214-219).
- **FR-005**: La entrega NO DEBE requerir cambios en `setup.sh::mirror_catalog_to_docker`: `plugin-install.sh` es image-only (vive en `docker/scripts/lib/`) y ya llega al build context vía la copia wholesale del árbol `docker/`. Un test DEBE verificar que el archivo está presente en `<dest>/docker/scripts/lib/plugin-install.sh` tras el scaffold (sin tocar el mirror, que es solo para libs compartidas de `scripts/lib/`).
- **FR-006**: En una imagen construida, `retry_plugin_install_bounded` DEBE quedar definido en runtime al sourcear `start_services.sh` (no tomar el path legacy de `start_services.sh:214`).
- **FR-007**: La cobertura de test DEBE ser test-first: agregar tests host-side (sin Docker) que fallen antes del cambio y pasen después, para US2 (no-cuelgue/timeout) y US3 (Dockerfile copia + setup stagea plugin-install.sh).
- **FR-008**: La suite host-side por defecto (`bats tests/`, sin Docker) DEBE quedar verde.
- **FR-009**: El modelo de menor privilegio del contenedor (Principio II) DEBE permanecer intacto; no se agregan capabilities, mounts ni accesos.
- **FR-010**: El feature DEBE incluir entrada en `CHANGELOG.md` y bump de patch en `VERSION` (0.4.1 → 0.4.2).

### Key Entities

- **`ensure_official_marketplace`** (función del supervisor): registra el marketplace oficial en boot; hoy llama a `claude` sin timeout y puede colgar el boot.
- **`retry_plugin_install_bounded`** (función de `plugin-install.sh`): retry acotado de instalación de plugins (004 US2); hoy indefinida en runtime por delivery gap.
- **Stub `claude`** (en el test E2E): doble de prueba que modela el lag de auth; hoy incompleto para los subcomandos que 006 introdujo en el boot.
- **Copia wholesale del árbol `docker/`** (en `setup.sh::scaffold`): lleva todo `docker/` (incl. `docker/scripts/lib/plugin-install.sh`) al workspace; ya funciona. El gap está aguas abajo: el Dockerfile no copia el archivo a la imagen.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `DOCKER_E2E=1 bats tests/docker-e2e-*.bats` pasa de 1 falla a 0 fallas (11/11).
- **SC-002**: `bats tests/` (host, sin Docker) queda verde, incluyendo los nuevos tests de US2 y US3.
- **SC-003**: En una imagen recién construida, `/opt/agent-admin/scripts/lib/plugin-install.sh` existe y `command -v retry_plugin_install_bounded` (al sourcear el supervisor) es verdadero.
- **SC-004**: Inyectando un `claude` que cuelga en `marketplace list`, `ensure_official_marketplace` retorna en ≤ el timeout configurado (orden de segundos), no indefinidamente.
- **SC-005**: El boot normal (claude real, marketplace ya registrado) no cambia de comportamiento observable.

## Assumptions

- El contrato MCP/canal y el flujo de auth headless (006) son correctos; este feature solo repara el camino de instalación de plugins y su entrega en la imagen. Verificado: en `rodri-cenco-admin` vivo, auth/marketplace/plugins/onboarding funcionan; el defecto está en el retry acotado (path legacy) y en el stub del E2E.
- `timeout` (busybox) está disponible en la imagen Alpine 3.20+; se usará con degradación a llamada directa si está ausente.
- El path legacy de instalación seguirá existiendo como fallback; este feature no lo elimina, solo hace que el path de retry acotado esté disponible y se prefiera.
- La validación final requiere rebuild de imagen y `DOCKER_E2E=1`; la suite host-side cubre la lógica sin Docker (Principio III).
- No hay impacto en secretos ni en el modelo de backup; los cambios son en supervisor (image-baked), Dockerfile (image-baked), setup.sh (host-launcher) y tests.
