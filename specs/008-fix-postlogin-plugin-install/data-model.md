# Data Model: Reparar auto-instalación de plugins post-login

Bug fix de supervisor/build/test. Sin entidades de datos persistentes nuevas ni esquema. Las "entidades" son funciones y artefactos de build.

## Entidades conceptuales

### `ensure_official_marketplace` (función de supervisor)

- **Qué representa**: registro idempotente del marketplace oficial en el boot path.
- **Estado relevante**: registrado / no registrado (derivado de `claude plugin marketplace list`).
- **Cambio**: las llamadas a `claude` quedan acotadas por `timeout` con degradación; sigue fail-silent (retorna 0).
- **Invariante**: nunca bloquea el boot.

### `retry_plugin_install_bounded` (función de `plugin-install.sh`)

- **Qué representa**: retry acotado de instalación de plugin con presupuesto + registro de fallas (feature 004 US2; clasificación marketplace-not-found de 006 US4).
- **Estado**: definida ⇄ indefinida en runtime (según si el lib se sourcea).
- **Cambio**: pasa de indefinida (path legacy) a definida (lib copiado a la imagen).
- **Transición**: `legacy (indefinida)` → `bounded (definida)` al agregar el COPY.

### Stub `claude` (doble de prueba del E2E)

- **Qué representa**: CLI falso que modela el lag de auth en el contenedor de test.
- **Cambio**: amplía la cobertura de subcomandos `plugin` (marketplace list/add, plugin list) para no bloquear el boot.
- **Invariante**: solo la sesión interactiva duerme; los subcomandos `plugin` retornan rápido.

## No aplica

- Sin almacenamiento nuevo, sin migraciones, sin máquina de estados de runtime nueva. El state file de fallas de plugin (`scripts/heartbeat/...`) lo gestiona el `plugin-install.sh` ya existente, que este feature solo hace llegar a la imagen.
