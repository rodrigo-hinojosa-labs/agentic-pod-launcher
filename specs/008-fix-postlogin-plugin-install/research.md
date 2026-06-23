# Research: Reparar auto-instalación de plugins post-login

Bug fix con root cause confirmado empíricamente (evidencia runtime: árbol de procesos del contenedor colgado; + análisis estático del supervisor; + verificación contra la imagen viva). La investigación fija las decisiones de implementación.

## D1 — Stub del E2E: alcance de subcomandos `plugin`

- **Decisión**: el stub `claude` de `tests/docker-e2e-postlogin.bats` maneja explícitamente todos los subcomandos `plugin` que el boot/instalación invoca y responde no bloqueante: `plugin marketplace list` (salida vacía, exit 0), `plugin marketplace add` (exit 0), `plugin install <spec>` (lógica actual: sentinel si hay creds, si no error de auth), `plugin list` (exit 0). El `exec sleep 86400` se reserva SOLO para la invocación de sesión (bare `claude`).
- **Rationale**: el árbol de procesos del contenedor colgado mostró `grep -q claude-plugins-official` esperando un pipe abierto por `sleep 86400` — el stub caía a sleep para `marketplace list`. El supervisor (006) llama `claude plugin marketplace list | grep` ANTES de tmux; con el lib de retry presente (US3) el path acotado puede invocar `claude plugin list`/`install`. Cubrir toda la familia `plugin` evita un cuelgue residual.
- **Alternativas consideradas**: (a) solo agregar `marketplace` al stub — insuficiente si el path de retry acotado (US3) invoca `plugin list`; se descarta por frágil. (b) hacer que el stub responda exit 0 a CUALQUIER cosa salvo bare claude — demasiado laxo, escondería futuros subcomandos no modelados. La whitelist explícita de la familia `plugin` es el punto medio.

## D2 — Hardening: `timeout` en `ensure_official_marketplace`

- **Decisión**: envolver las llamadas a `claude` dentro de `ensure_official_marketplace` (`plugin marketplace list` y `plugin marketplace add`) con `timeout <N>` (N del orden de 10-15s), degradando a la llamada directa si `command -v timeout` es falso. Mantener fail-silent (retorna 0, loguea WARN si el timeout dispara).
- **Rationale**: Principio IV (degradar con gracia, no colgar el supervisor). El bug probó que un `claude` que no responde en este punto brickea el boot antes del watchdog, sin auto-recuperación. `timeout` (busybox) está en la imagen Alpine. La degradación evita romper entornos donde `timeout` no esté en PATH.
- **Alternativas consideradas**: (a) correr `ensure_official_marketplace` en background con `&` — complica la sincronización con el resto de `next_tmux_cmd` y el orden de registro antes de instalar; se descarta. (b) mover el registro del marketplace al watchdog loop (post-tmux) en vez del boot path — cambio más invasivo de orden, fuera del alcance del fix; el `timeout` es la mínima intervención que cierra el riesgo. (c) sin degradación si falta `timeout` — rechazado: rompería un entorno sin `timeout`.

## D3 — Entrega: una línea `COPY` en el Dockerfile (sin tocar el mirror)

- **Decisión**: agregar `COPY scripts/lib/plugin-install.sh /opt/agent-admin/scripts/lib/plugin-install.sh` en `docker/Dockerfile`, junto al bloque de libs image-only (líneas 214-219). NO modificar `setup.sh::mirror_catalog_to_docker`.
- **Rationale**: verificado que `plugin-install.sh` vive en `docker/scripts/lib/` (image-only, como `interval.sh`/`state.sh`/`backup_*.sh`), y el árbol `docker/` se copia wholesale al workspace (test `docker-setup.bats:76`), por lo que YA está en el build context (`./docker`). El único eslabón faltante es la línea `COPY`. `mirror_catalog_to_docker` es solo para libs **compartidas** de `scripts/lib/` host-launcher (plugin-catalog/vault/mcp-catalog), que NO están en `docker/` y por eso necesitan stagearse; `plugin-install.sh` no aplica.
- **Alternativas consideradas**: (a) agregarlo al mirror (recomendación inicial del agente de análisis) — INCORRECTO: el source `$dest/scripts/lib/plugin-install.sh` no existe (el archivo es image-only). Verificado: `ls scripts/lib/plugin-install.sh` → no such file. (b) mover el lib a `scripts/lib/` (host) y mirrorearlo — cambio innecesario de categoría; el lib es image-only por diseño (solo lo usa el supervisor). Se descarta.

## D4 — Validación: host-side primero, runtime después

- **Decisión**: TDD host-side para US2 (test que stubea un `claude` colgado y verifica que `ensure_official_marketplace` retorna acotado) y US3 (test que verifica la línea `COPY` en el Dockerfile y la presencia de `plugin-install.sh` en `<dest>/docker/scripts/lib/` tras scaffold). US1 se valida con `DOCKER_E2E=1 bats tests/docker-e2e-postlogin.bats`. Validación final: rebuild de imagen + suite E2E completa a verde.
- **Rationale**: Principio III (test-first, host-runnable; Docker gated). Sourcear `start_services.sh` host-side requiere el guard `BASH_SOURCE` (main "$@" no debe correr al sourcear) — verificar que `ensure_official_marketplace` es invocable aislada, como hacen los tests `start-services-*.bats` existentes.
- **Alternativas consideradas**: solo validar con DOCKER_E2E — rechazado: viola test-first host-side y deja la lógica de US2/US3 sin cobertura rápida.

## Riesgo / nota de verificación

`ensure_official_marketplace` debe ser sourceable/invocable host-side. Los tests `start-services-watchdog.bats`/`start-services-postlogin-retry.bats` ya sourcean `start_services.sh` con un guard; se reutiliza ese patrón. Confirmar en implementación que `CLAUDE_CONFIG_DIR_VAL`, `OFFICIAL_MARKETPLACE_NAME`/`_SOURCE` y `log` están definidos o se pueden stubear en el harness host-side.
