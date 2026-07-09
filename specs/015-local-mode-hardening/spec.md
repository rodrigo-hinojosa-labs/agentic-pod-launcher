# Feature Specification: Local-mode & docker RAG hardening (post first hardware gate)

**Feature Branch**: `015-local-mode-hardening`

**Created**: 2026-07-09

**Status**: Draft

**Input**: Cuatro defectos del launcher destapados por el PRIMER gate de hardware real (2026-07-08) al desplegar 012+013+014 en vivo sobre mclaren (RPi5, Debian glibc, modo local systemd) y ferrari (RPi5, modo docker, vault Cencosud de 2696 páginas). El gate confirmó que 014 (wiki-grafo + normalización + upgrade aditivo) funciona en ambos modos, pero los cuatro bugs sólo se parchearon en los hosts en vivo; el código del launcher sigue sin arreglar, así que cualquier agente nuevo los repite.

## Contexto

Los gates de hardware de 013 y 014 quedan **cerrados** por ese despliegue: 013 verificó el almacenamiento qmd bajo `.state` (no `~/.cache`); 014 se validó sobre datos reales (grafo con nodes 2696, edges 11817, broken_links 13, frontmatter_violations 14; upgrade aditivo con cero mutación de las 2696 páginas). Esta feature es el **hardening** de los defectos que ese gate encontró: llevarlos del parche-de-host al código, con cobertura test-first, y re-correr el gate confirmatorio.

Los parches de host ya aplicados (mclaren: `claude_cli` absoluto + bun glibc; ferrari: `/tmp` a 512m) sirven de **referencia del comportamiento esperado**, no de solución final.

## Clarifications

### Session 2026-07-09

- D: US1 — ¿Cómo resolver `claude_cli` para que la unit no quede rota tras un `--regenerate` headless? → A: Persistir en `agent.yml` la ruta absoluta al symlink estable resuelta en el scaffold; `--regenerate` la usa si es absoluta+ejecutable, si no re-resuelve por los candidatos conocidos y persiste, y **falla ruidosamente** si ninguno resuelve (single source, Principle I).
- D: US3 — ¿Cómo evitar el ENOSPC de `/tmp` por el cache de `bunx` (~98MB)? → A: **Routear** los consumidores pesados (cache de `bunx`/qmd y los `mktemp` del runner wiki-graph) a un `TMPDIR` **host-backed bajo `.state`**, dejando el tmpfs `/tmp` sin agrandar; el runner queda robusto a `/tmp` lleno por diseño.
- D: US4 — El fix de causa raíz del wrapper qmd-reindex en docker requiere ferrari (inalcanzable). ¿Alcance en 015? → A: Sólo la **observabilidad** que no requiere ferrari (quitar `2>/dev/null`, loguear env efectivo y error real, instrumentar la comparación contra el binario); el fix de causa raíz se **defiere** al gate confirmatorio cuando ferrari sea alcanzable.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - La unit del agente local arranca aunque `--regenerate` corra headless (Priority: P1)

Un operador regenera un workspace en modo local desde una sesión no interactiva (SSH sin login shell, cron, CI). El servicio systemd del agente debe quedar con un `ExecStart` que systemd pueda resolver, sin depender del `PATH` del shell que ejecutó `--regenerate`.

**Why this priority**: Es el bug CRÍTICO — deja al agente en `203/EXEC` restart-loop hasta agotar el start-limit (agente caído). Afecta a todo agente local cuyo `claude` viva en `~/.local/bin` (el default del native installer de Claude Code hoy).

**Independent Test**: Sobre un fixture donde `claude` existe sólo en `~/.local/bin` (fuera del PATH del manager de systemd) y `--regenerate` corre en un shell sin ese directorio en PATH, la unit renderizada trae un `ExecStart` con ruta **absoluta ejecutable**, no el literal `claude`.

**Acceptance Scenarios**:

1. **Given** un host donde `claude` está sólo en `~/.local/bin`, **When** se corre `--regenerate` en un shell no-login (sin `~/.local/bin` en PATH), **Then** la unit del agente tiene `ExecStart=<ruta-absoluta>/claude …` y systemd la arranca sin `203/EXEC`.
2. **Given** que Claude Code se actualiza (el binario versionado cambia detrás del symlink estable), **When** el agente reinicia, **Then** el `ExecStart` sigue siendo válido (apunta al symlink estable, no a una versión concreta).
3. **Given** que `claude` no se puede resolver a una ruta ejecutable en ningún candidato conocido, **When** se regenera, **Then** el proceso **falla ruidosamente** (mensaje accionable) en vez de emitir una unit rota silenciosa.

---

### User Story 2 - qmd arranca en modo local sobre un host glibc (Priority: P1)

Un operador habilita qmd (búsqueda híbrida) en un agente local corriendo sobre una distro glibc (Debian/Ubuntu). El runtime `bun`/`bunx` que provisiona el launcher debe **ejecutar** en ese host.

**Why this priority**: Sin esto qmd no arranca en local sobre glibc (la mayoría de las distros bare-metal): el `bun` provisionado es una build musl que no ejecuta (`cannot execute: required file not found`). Bloquea toda la búsqueda híbrida en modo local, la mitad del valor del RAG.

**Independent Test**: En un host glibc, tras el provisioning de runtimes, `bun --version` y `bunx --version` **ejecutan** (rc 0), y el reindex qmd puede invocar `bunx @tobilu/qmd`.

**Acceptance Scenarios**:

1. **Given** un host aarch64/x86_64 con glibc, **When** el launcher provisiona `bun`, **Then** el binario instalado ejecuta (no es una build musl con intérprete `/lib/ld-musl-*` ausente).
2. **Given** un host musl (Alpine, p.ej. la imagen docker), **When** se provisiona `bun`, **Then** se elige la build musl (comportamiento docker sin cambios).
3. **Given** que el provisioning se re-ejecuta (idempotencia), **When** `bun` ya está presente y ejecuta, **Then** no se re-baja ni se pisa con una build incompatible.

---

### User Story 3 - wiki-graph y qmd conviven sin quedarse sin espacio en `/tmp` (docker) (Priority: P1)

Un agente en modo docker con qmd habilitado corre el mantenimiento programado (reindex qmd + derivación del wiki-grafo) sobre un vault grande. Ninguno de los dos debe fallar por falta de espacio en `/tmp`, y si un paso batch topa con un error de infraestructura (p.ej. sin espacio), el estado debe **registrarlo**, no tragárselo.

**Why this priority**: `bunx` deja ~98MB de paquete qmd en el tmpfs `/tmp` de 100MB → cualquier otro consumidor de `/tmp` (el runner wiki-graph, el propio qmd) falla con "No space left on device". El síntoma se veía como un falso "aggregation failed" porque el error de infraestructura quedaba silenciado.

**Independent Test**: Con qmd habilitado y el paquete `bunx` ya cacheado ocupando su espacio, el runner wiki-graph corre sobre un vault grande y **completa** (state `ok`, artefactos escritos); ante un `/tmp` artificialmente lleno, el estado reporta un error de infraestructura legible en vez de un conteo cero silencioso.

**Acceptance Scenarios**:

1. **Given** un contenedor con qmd habilitado y el cache de `bunx` presente, **When** corre `wiki-graph`, **Then** el runner completa con `last_status: ok` y escribe `.graph/{graph,backlinks,findings}.json` con conteos reales.
2. **Given** el mismo contenedor, **When** corre el reindex qmd, **Then** `collection add`/`update`/`embed` disponen de espacio y no fallan por ENOSPC.
3. **Given** un fallo de infraestructura durante la agregación (p.ej. sin espacio para escribir temporales), **When** el runner termina, **Then** el state file registra el error real (no un `aggregation failed` genérico con stderr vacío) para diagnóstico.

---

### User Story 4 - El reindex qmd programado indexa de verdad en docker (Priority: P2)

Un agente en modo docker con qmd habilitado deja que el reindex programado construya y mantenga el índice. El wrapper del launcher debe lograr lo que el binario qmd logra a mano.

**Why this priority**: Tras resolver el espacio, el binario qmd funciona a mano (`collection add`/`update` rc 0) pero el wrapper `qmd-reindex` sigue fallando en docker. Sin esto la búsqueda híbrida no se refresca sola en docker. Es P2: secundario al desbloqueo de US3 y depende de un host docker alcanzable para el diagnóstico de causa raíz.

**Independent Test**: La parte verificable ahora — con el reindex fallando, el error real de qmd es **visible** (no oculto por `2>/dev/null`) y el env efectivo queda registrado para diagnóstico. La construcción efectiva del índice (sqlite presente bajo el almacenamiento resuelto, `last_status: ok` equivalente al binario directo) es el **gate confirmatorio** en hardware, pendiente hasta que ferrari sea alcanzable.

**Acceptance Scenarios**:

1. **Given** un contenedor docker con qmd habilitado, **When** corre el reindex programado del wrapper, **Then** construye/actualiza el índice (sqlite presente) y reporta `ok` — igual que la invocación directa del binario.
2. **Given** que el reindex del wrapper falla, **When** se inspecciona el log/estado, **Then** el error de qmd es **visible** (no oculto por redirección a `/dev/null`) para permitir diagnóstico.

---

### Edge Cases

- `--regenerate` corrido como root vs como el operador: la resolución de `claude` debe considerar el `HOME`/usuario correcto del agente, no el de quien ejecuta.
- Host sin `claude` en ningún candidato conocido: fallo ruidoso, no unit rota.
- Host sin `unzip` al provisionar `bun`: mensaje accionable (ya existente) y qmd marcado como no-disponible con honestidad en `doctor`.
- Vault muy grande (miles de páginas): el runner wiki-graph y qmd deben tener espacio de temporales proporcional, sin asumir un `/tmp` fijo pequeño.
- Idempotencia: re-provisionar `bun` glibc no debe reintroducir la build musl; re-regenerar no debe revertir el `ExecStart` absoluto ni el dimensionamiento de temporales.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: La unit systemd del agente en modo local MUST invocar a Claude por una ruta que systemd resuelva por sí mismo (absoluta y ejecutable), independiente del `PATH` del shell que ejecutó `--regenerate`.
- **FR-002**: El scaffold MUST resolver la ruta de Claude a una ruta **absoluta y ejecutable** que apunte a una referencia **estable** (el symlink del native installer, `~/.local/bin/claude`) y persistirla en `agent.yml` (`deployment.claude_cli`); `--regenerate` MUST usar ese valor si es absoluto+ejecutable y, si no lo es o falta, re-resolverlo por los candidatos conocidos y persistirlo (Principle I, single source).
- **FR-003**: Si Claude no se puede resolver a una ruta ejecutable en los candidatos conocidos, el launcher MUST **fallar ruidosamente** con un mensaje accionable en vez de emitir una unit inarrancable.
- **FR-004**: El provisioning de `bun` en modo local MUST detectar la libc del host (glibc vs musl) y instalar la build de `bun` que **ejecuta** en ese host; el modo docker (Alpine/musl) conserva su build musl.
- **FR-005**: El provisioning de runtimes MUST ser idempotente: si `bun` ya está presente y ejecuta, no lo re-baja ni lo reemplaza por una build incompatible.
- **FR-006**: En modo docker con qmd habilitado, los consumidores pesados de temporales (cache de `bunx`/qmd y los `mktemp` del runner wiki-graph) MUST usar un `TMPDIR` **host-backed bajo `.state`** en vez del tmpfs `/tmp` (RAM), de modo que operen sobre un vault grande sin fallar por falta de espacio; el runner wiki-graph MUST usar su propio `TMPDIR` host-backed y ser robusto a un `/tmp` lleno.
- **FR-007**: Los pasos batch (reindex qmd, derivación wiki-graph) MUST registrar los errores de infraestructura (p.ej. sin espacio) en su state file/log en vez de silenciarlos y reportar un resultado vacío engañoso (refina Principle IV: fail-silent no equivale a error-swallow).
- **FR-008**: El reindex qmd programado en modo docker MUST hacer **observable** su error real cuando falle (sin redirección a `/dev/null`; env efectivo y salida de qmd capturados) — en alcance de 015. El fix de causa raíz para que el wrapper construya/actualice el índice de forma equivalente a la invocación directa del binario qmd se **defiere** al gate confirmatorio en hardware (requiere ferrari alcanzable).
- **FR-009**: Todos los cambios MUST sobrevivir `./setup.sh --regenerate` y mantener la paridad de libs espejadas `scripts/lib/` ↔ `docker/scripts/lib/` con su línea `COPY` (decisiones heredadas).
- **FR-010**: Cada cambio de comportamiento MUST venir con cobertura `bats` host-side escrita antes de la implementación (Principle III); los cambios que toquen `docker/` o el runtime docker de qmd/wiki-graph MUST pasar `DOCKER_E2E`.

### Key Entities

- **Ruta del CLI de Claude (`deployment.claude_cli` / `CLAUDE_BIN`)**: la referencia que termina en el `ExecStart` de la unit; debe ser absoluta, ejecutable y estable.
- **Build de `bun` provisionada**: artefacto de runtime cuya variante (glibc/musl) debe corresponder a la libc del host.
- **Almacenamiento de temporales (`/tmp` tmpfs / `TMPDIR`)**: espacio de scratch compartido por `bunx`, qmd y el runner wiki-graph en el contenedor.
- **State files de batch (`wiki-graph.json`, `qmd-index.json`, logs de reindex)**: deben reflejar errores de infraestructura reales, no resultados vacíos silenciosos.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En un host glibc con `claude` sólo en `~/.local/bin`, un `--regenerate` headless produce una unit que systemd arranca al primer intento (0 fallos `203/EXEC`).
- **SC-002**: En un host glibc, tras el provisioning, `bun --version` ejecuta con rc 0 (100% de las corridas), habilitando el reindex qmd.
- **SC-003**: En modo docker con qmd habilitado y `bunx` cacheado, el runner wiki-graph completa con `last_status: ok` sobre un vault de miles de páginas, sin fallos por falta de espacio.
- **SC-004**: Ante un fallo de infraestructura inyectado (sin espacio para temporales), el state file del paso batch contiene un mensaje de error de infraestructura legible (no un conteo cero silencioso) en el 100% de los casos.
- **SC-005** (gate confirmatorio, requiere ferrari): En modo docker, una corrida del reindex qmd programado deja un índice consultable (sqlite presente) y reporta `ok`, equivalente a la invocación directa del binario. La parte de US4 verificable ahora —el error real del reindex es visible, no silenciado— queda cubierta por la suite host y `DOCKER_E2E`.
- **SC-006**: La suite host (`bats tests/`) queda verde y `shellcheck -S error` limpio; el `DOCKER_E2E` obligatorio pasa; ningún parche de host queda como única fuente del arreglo (todos reproducibles por `--regenerate`/rebuild desde el código).

## Assumptions

- Los parches de host ya aplicados (mclaren `claude_cli` absoluto + bun glibc; ferrari `/tmp` 512m) son **referencia de comportamiento esperado**; el fix definitivo vive en el código del launcher y hará converger a esos hosts vía `--regenerate`/rebuild limpios.
- El símbolo estable para la ruta de Claude es el symlink del native installer (`~/.local/bin/claude`), que persiste a través de actualizaciones del binario versionado.
- **Resuelto (US3, ver Clarifications):** los temporales pesados se **routean a un `TMPDIR` host-backed bajo `.state`** (el tmpfs `/tmp` no se agranda); el runner wiki-graph usa su propio `TMPDIR` y es robusto a `/tmp` lleno.
- **Resuelto (US1, ver Clarifications):** `claude_cli` se resuelve a ruta absoluta en el scaffold y se **persiste en `agent.yml`**; `--regenerate` la usa si es válida, si no re-resuelve por candidatos y persiste, y falla ruidosamente si ninguno resuelve.
- **Resuelto (US4, ver Clarifications):** 015 entrega sólo la **observabilidad** del reindex (verificable por host/`DOCKER_E2E`); el fix de causa raíz y su verificación (índice construido) son el **gate confirmatorio** en hardware, que requiere que ferrari vuelva a ser alcanzable (túnel Cloudflare del operador; infra del usuario, fuera del alcance del launcher).
- Versión del launcher pasa a **0.9.0**; `CHANGELOG.md` registra el hardening (Principle VI).

## Out of Scope

- Cambios al motor qmd o su esquema de colecciones; nuevas capacidades de RAG (014 ya cerró el grafo).
- Modificar el contenido de los vaults existentes (los parches de host aplicados quedan).
- El acceso por túnel Cloudflare a los hosts (infra del usuario).
- Reintroducir diseños revertidos (p.ej. bridge watchdog) sin resolver su modo de falla documentado.
