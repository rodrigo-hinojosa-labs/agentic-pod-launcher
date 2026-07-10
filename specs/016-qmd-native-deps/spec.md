# Feature Specification: qmd deps nativas en Alpine (fix root-cause de BUG 4)

**Feature Branch**: `016-qmd-native-deps`

**Created**: 2026-07-10

**Status**: Draft

**Input**: Fix del root-cause de BUG 4 — el reindex de qmd falla en modo docker (imagen Alpine musl aarch64) porque `@tobilu/qmd@2.5.3` arrastra dependencias nativas sin prebuilt musl y la imagen no tiene compilador. BUG 4 quedó diferido en la feature 015 (solo observabilidad, US4); esa observabilidad, desplegada en vivo en ferrari el 2026-07-10, reveló el error real. Un workflow de investigación multi-agente (17 agentes, 2026-07-10) verificó el root-cause contra el código de qmd (tag v2.5.3) y el registry npm.

## Contexto y root-cause (verificado)

El RAG semántico del agente (qmd) **no indexa en modo docker**: `heartbeatctl qmd-reindex` reporta `last_status=error` de forma persistente (536+ corridas en ferrari). En modo local (mclaren, Debian glibc con toolchain) qmd **sí** indexa. El fallo es exclusivo de la imagen Alpine musl aarch64.

qmd corre siempre en **runtime** vía `bunx @tobilu/qmd@2.5.3`, que instala/compila el paquete bajo `/home/agent/.cache/qmd/tmp/` (bind-mount `.state`) — nunca en `docker build`. Por eso ningún artefacto horneado en la imagen bajo `/home/agent` sobrevive (el bind-mount `./.state:/home/agent` lo enmascara). La instalación arrastra **dos** familias de módulos nativos que en Alpine musl no tienen binario ejecutable:

1. **`tree-sitter-*`** (`tree-sitter-typescript@0.23.2` + go/python/rust) — `optionalDependencies`, install-script `node-gyp-build`. Los prebuilds publicados son glibc-only; en musl el `dlopen` del `.node` glibc falla → cae a `node-gyp rebuild` → sin compilador C/C++ → `install script from "tree-sitter-typescript" exited with 1` → **bunx aborta `qmd update` completo**. Ironía: qmd **no usa** el binding nativo en runtime; usa `web-tree-sitter` (WASM, dependencia dura) con el `.wasm` prebuilt que ya viaja en el tarball. Para el vault markdown (2696 páginas) tree-sitter ni se ejerce (markdown siempre usa regex; el AST solo aplica a código con `--chunk-strategy auto`).

2. **`node-llama-cpp@3.18.1`** (el muro real) — **dependencia dura**, necesaria para `qmd embed` (embeddings locales, modelo ~300MB). Tampoco tiene prebuilt musl → build desde fuente con `cmake-js`; el `cmake` que auto-descarga suele ser binario glibc → no ejecuta en musl. La doc oficial de node-llama-cpp desaconseja Alpine (hazard musl conocido: stack de hilos 128KB → overflow de `std::regex`).

**Consecuencia de diseño:** un fix que solo salte la compilación (p.ej. `--ignore-scripts`) arregla `update` (tree-sitter, que qmd no necesita) pero **deja `embed` roto** (node-llama-cpp sí es necesario para el RAG semántico). El fix debe restaurar **ambos** caminos, o eliminar la necesidad del embed local.

## Clarifications

### Session 2026-07-10

- Q: ¿Alcance de 016 — embed semántico completo en docker, o solo que el reindex/update deje de fallar? → A: **Embed completo** — el RAG semántico (embed) debe quedar operativo en docker.
- Q: ¿Dirección técnica del fix en docker? → A: **Opción A — mantener Alpine** (toolchain en la imagen y/o saltar los install-scripts nativos; el detalle se fija en el plan); NO cambiar el base OS.
- Q: ¿Nivel de realismo del gate DOCKER_E2E? → A: **qmd real end-to-end** — des-stubear `bunx` y ejercer `update` y `embed` reales.

### Decisión de mecanismo (resuelta)

El **qué** (qmd indexa y embebe en docker) está fijado por los requisitos. El **cómo** se resolvió en clarify: **Opción A — mantener Alpine con toolchain**, con `embed` **en alcance**. La tabla de opciones queda como referencia del análisis:

| Opción | Mecanismo | Pros | Contras / riesgo |
|--------|-----------|------|------------------|
| **A — Toolchain en imagen** | `apk add` de compilador C/C++ (`build-base` + `cmake` + `linux-headers`, posible `py3-setuptools`) en la etapa final de `docker/Dockerfile` | Cambio acotado, mantiene Alpine, mantiene el contrato `bunx` | Bloat de imagen (~decenas de MB) → **violación justificada** del principio de imagen mínima; `embed`/node-llama-cpp en musl es **riesgo alto** (cmake glibc, hazard std::regex) — requiere validación real |
| **B — Base glibc** | Cambiar `BASE_IMAGE` a un base glibc aarch64 (debian-slim / node-slim) | Resuelve de raíz (prebuilds glibc cargan sin compilar) | Migración pesada y de alto riesgo: crond busybox→cron, `su-exec`→`gosu`, apk→apt, modelo de privilegios (`cap_drop ALL` + `no-new-privileges`), user/group agent, reproducibilidad |
| **C — Embeddings remotos** | Configurar qmd para usar un backend de embeddings remoto en vez de node-llama-cpp local | Elimina el muro nativo del embed por completo; imagen mínima intacta | Requiere confirmar soporte en qmd 2.5.3; introduce dependencia de red/servicio externo y posible costo/latencia; el vault sale del host |

**Resolución (clarify 2026-07-10):** **A (mantener Alpine + toolchain)** con **embed en alcance** — máxima funcionalidad (RAG semántico completo) sin cambiar el base OS ni sacar el vault del host. Tensión asumida y **riesgo técnico principal**: `node-llama-cpp`/`llama.cpp` en Alpine musl aarch64 no tiene prebuilt musl → hay que compilarlo con el `cmake` de Alpine (apk), NO el `cmake` glibc que node-llama-cpp auto-descarga; existe además un hazard musl conocido (stack de hilos 128KB → `std::regex`). Si el gate confirmatorio en ferrari demuestra que el embed no compila/corre en musl, se reevalúan B (base glibc) o C (embeddings remotos) como **fallback documentado**. La Opción A mantiene "Alpine, single-stage" (constitución literal **intacta** — no requiere enmienda); el bloat de toolchain (~decenas de MB) es una violación del *espíritu* minimalista que se registra en el Complexity Tracking del plan (Principle II — capacidades y privilegios — permanece intacto).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - qmd `update`/reindex completa en modo docker (Priority: P1)

Como operador de un agente en modo docker con vault + qmd habilitados, cuando el reindex se dispara (cron, watcher o manual), el índice se construye sin abortar por dependencias nativas.

**Why this priority**: es el síntoma directo de BUG 4 (`last_status=error` persistente). Sin esto no hay índice de búsqueda; el RAG queda inoperante en docker.

**Independent Test**: en un contenedor recién construido con vault poblado, `heartbeatctl qmd-reindex` (o el subcomando de update) termina con éxito y el estado pasa a `ok` con un índice no vacío; se puede verificar sin tocar el embed.

**Acceptance Scenarios**:

1. **Given** un agente docker con `vault.qmd.enabled=true` y vault con documentos markdown, **When** se ejecuta el reindex, **Then** `qmd update` completa sin abortar y el estado registrado es `ok` (no `error`).
2. **Given** el mismo agente, **When** se inspecciona el store de qmd tras el reindex, **Then** existe un índice con documentos indexados (> 0), persistido bajo `.state`.
3. **Given** un vault solo-markdown, **When** corre el update, **Then** el resultado no depende de compilar `tree-sitter-typescript` (el camino markdown usa regex/WASM).

---

### User Story 2 - qmd `embed` (embeddings semánticos) opera en modo docker (Priority: P1)

Como operador, el RAG **semántico** (búsqueda por similitud) funciona en docker: qmd genera y consulta embeddings sin fallar por el módulo nativo de inferencia.

**Why this priority**: `embed` es el corazón del RAG semántico y depende de `node-llama-cpp`, el muro real en Alpine musl. Un fix que solo arregle `update` deja el RAG a medias.

**Independent Test**: en el contenedor, la operación de embed sobre un conjunto mínimo de documentos completa con éxito y una consulta semántica devuelve resultados; verificable independientemente del reindex léxico.

**Acceptance Scenarios**:

1. **Given** un agente docker con qmd habilitado, **When** se ejecuta el paso de embed, **Then** completa sin error de módulo nativo y produce vectores consultables.
2. **Given** embeddings generados, **When** se hace una consulta semántica, **Then** devuelve resultados relevantes (no un fallo de backend).
3. **Given** que el modelo de embeddings pesa cientos de MB, **When** corre el embed por primera vez, **Then** los timeouts/watchdog del wrapper toleran la ventana de descarga/preparación sin marcar falso fallo.

---

### User Story 3 - DOCKER_E2E ejerce qmd real (des-stubear bunx) (Priority: P2)

Como mantenedor del launcher, la suite DOCKER_E2E ejecuta un `update` **y** un `embed` reales contra la imagen construida, de modo que un fallo de dependencia nativa se detecte en CI, no en producción.

**Why this priority**: el DOCKER_E2E actual **stubea `bunx`**, por eso nunca detectó BUG 4. Sin des-stubear, cualquier fix pasaría CI verde sin ejercer jamás la compilación/carga real.

**Independent Test**: correr `DOCKER_E2E=1 bats` sobre el archivo de qmd; el test construye la imagen y ejerce update+embed reales sobre un vault mínimo, fallando si cualquiera de los dos aborta.

**Acceptance Scenarios**:

1. **Given** la suite DOCKER_E2E de qmd, **When** se ejecuta, **Then** invoca qmd real (no un stub de `bunx`) para update y embed.
2. **Given** una imagen sin el fix, **When** corre el DOCKER_E2E nuevo, **Then** el test **falla** (reproduce BUG 4) — prueba de que el gate tiene poder de detección.
3. **Given** una imagen con el fix, **When** corre el DOCKER_E2E, **Then** update y embed pasan end-to-end.

---

### User Story 4 - Guardrail de versión de qmd (Priority: P2)

Como mantenedor, un cambio del pin de qmd exige re-verificar conscientemente las suposiciones del fix, para no romper el arreglo en silencio.

**Why this priority**: en la rama 2.6.x de qmd los `tree-sitter-*` pasaron de `optionalDependencies` a dependencias **duras**; un bump ingenuo invalidaría cualquier fix basado en "optional" y volvería obligatoria la compilación. El pin actual es 2.5.3.

**Independent Test**: un test que fija la cadena de versión esperada; cambiar `vault.qmd.version` sin actualizar el test/checklist rompe el test, forzando la re-verificación.

**Acceptance Scenarios**:

1. **Given** el pin `vault.qmd.version` en 2.5.3, **When** alguien lo modifica sin actualizar el guardrail, **Then** un test falla y exige seguir el checklist pre-bump.
2. **Given** el checklist pre-bump, **When** se evalúa una versión destino, **Then** cubre: clasificación de deps de los grammars, presencia del `.wasm`, y disponibilidad de prebuilt musl o vigencia del mecanismo elegido.

---

### User Story 5 - Prerequisito de toolchain en modo local documentado/verificado (Priority: P3)

Como operador que despliega en modo **local** sobre un host limpio (sin compilador), el sistema deja claro (o verifica) el prerequisito de toolchain, para que el mismo fallo de build no reaparezca fuera de docker.

**Why this priority**: mclaren funcionó solo porque el host ya tenía `gcc`. Un host local limpio repetiría el fallo. Es P3 porque el fallo confirmado es docker; local es preventivo.

**Independent Test**: en un host local sin toolchain, el doctor/healthcheck o la documentación de prerequisitos advierte del requisito antes de que el reindex falle en silencio.

**Acceptance Scenarios**:

1. **Given** un host local sin compilador, **When** se prepara/verifica el agente, **Then** el prerequisito de toolchain se documenta o se detecta con un mensaje accionable (no un fallo opaco de build).

---

### Edge Cases

- **Primer arranque frío**: el primer update/embed compila o descarga artefactos pesados; los timeouts del wrapper deben tolerarlo sin marcar falso fallo ni dejar el estado en `error` transitorio confuso.
- **Sin egress de red**: node-gyp/cmake/modelo requieren descarga; si el contenedor no tiene salida, el fallo debe reportarse con causa clara (observabilidad de 015), no como `error` genérico.
- **`/tmp` bajo presión**: el build de módulos nativos escribe artefactos; debe usar el TMPDIR host-backed de 015 (US3) para no llenar el tmpfs de RAM (ENOSPC).
- **Bump de qmd fuera de banda**: cambiar el pin sin re-verificar deja el fix inválido (cubierto por US4).
- **Modo local intacto**: cualquier cambio de la imagen docker no debe alterar el comportamiento del modo local que ya funciona.
- **Embed no compila/corre en musl (riesgo principal)**: si `node-llama-cpp`/`llama.cpp` no compila o no arranca en Alpine musl aarch64 pese al toolchain (cmake de Alpine, hazard `std::regex`), el sistema MUST reportarlo con causa clara (observabilidad de 015) y el equipo reevalúa el fallback B/C — NO debe quedar un `embed` roto en silencio.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: En modo docker, el reindex de qmd (`update`) MUST completar sin abortar por dependencias nativas y dejar el estado en `ok` con un índice no vacío persistido bajo `.state`.
- **FR-002**: En modo docker, la operación de embeddings de qmd (`embed`) MUST completar con éxito y producir vectores consultables por búsqueda semántica.
- **FR-003**: El fix MUST restaurar ambos caminos (léxico/update y semántico/embed) o eliminar la necesidad del embed local; NO es aceptable arreglar solo `update` y dejar `embed` roto.
- **FR-004**: El fix MUST ser agnóstico al contenido del vault y no requerir compilar `tree-sitter-typescript` para indexar markdown (el camino markdown usa regex/WASM).
- **FR-005**: El comportamiento del **modo local** (que ya indexa) MUST permanecer sin regresión tras el cambio.
- **FR-006**: El DOCKER_E2E de qmd MUST ejercer `update` y `embed` **reales** (sin stub de `bunx`) sobre la imagen construida, y MUST fallar contra una imagen sin el fix (poder de detección demostrado).
- **FR-007**: El sistema MUST mantener el pin de qmd single-source en `agent.yml` (`vault.qmd.version`, hoy 2.5.3) y MUST incluir un guardrail (test + checklist pre-bump) que impida subir la versión sin re-verificar las suposiciones del fix.
- **FR-008**: El build/instalación de módulos nativos MUST usar el TMPDIR host-backed bajo `.state` (heredado de 015 US3) para no llenar el tmpfs de `/tmp` (evitar ENOSPC).
- **FR-009**: Cualquier fallo residual del reindex/embed MUST quedar observable (causa real, redactada) en el estado/log, conservando la mejora de observabilidad de 015 (fail-silent que registra, no traga).
- **FR-010**: La imagen MUST permanecer **Alpine single-stage** (constitución literal intacta; el base OS NO cambia bajo el mecanismo A elegido). El bloat de toolchain que introduzca el fix MUST documentarse en el Complexity Tracking del plan como violación del *espíritu* minimalista; Principle II (capacidades y privilegios) permanece intacto.
- **FR-011**: Los cambios en libs espejadas (`scripts/lib` ↔ `docker/scripts/lib`) y su `COPY` en el Dockerfile MUST mantener la paridad del mirror; cualquier archivo nuevo requiere su línea `COPY` explícita.
- **FR-012**: El prerequisito de toolchain para modo local en hosts limpios MUST documentarse o detectarse con un mensaje accionable (no un fallo opaco de build).

### Key Entities

- **Paquete qmd** (`@tobilu/qmd`, pin 2.5.3 en `agent.yml`): motor de RAG; se instala en runtime vía `bunx`. Fuente única de verdad de la versión.
- **Módulos nativos de qmd**: `tree-sitter-*` (opcionales, WASM-en-runtime) y `node-llama-cpp` (duro, embeddings locales) — el punto de fallo en Alpine musl.
- **Imagen del contenedor** (`docker/Dockerfile`): hoy Alpine musl aarch64 single-stage sin compilador; objeto del fix bajo la opción A/B.
- **Wrappers qmd** (`scripts/lib/qmd_index.sh`, espejado a `docker/scripts/lib/`): invocan `bunx qmd`; rutean TMPDIR a `.state`; portan la observabilidad de 015.
- **Suite DOCKER_E2E de qmd**: gate que hoy stubea `bunx`; debe ejercer qmd real.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En un contenedor docker recién construido con vault poblado, el reindex de qmd deja `last_status=ok` (no `error`) y un índice con ≥ 1 documento, en 0 intentos fallidos por dependencia nativa.
- **SC-002**: Una búsqueda semántica sobre el vault devuelve resultados relevantes en modo docker (embed operativo), donde antes el embed no corría.
- **SC-003**: El DOCKER_E2E de qmd ejerce update+embed reales y **falla** sobre una imagen sin el fix y **pasa** sobre una imagen con el fix (poder de detección verificado en ambos sentidos).
- **SC-004**: La suite host completa queda verde y `shellcheck -S error` limpio; sin regresión del modo local (mclaren sigue indexando).
- **SC-005**: En el gate confirmatorio de hardware (ferrari, Alpine musl aarch64 real), qmd-reindex indexa de verdad, la búsqueda semántica responde, wiki-graph sigue `ok` sobre las 2696 páginas, y `/tmp` no se llena (sin ENOSPC).
- **SC-006**: Un intento de cambiar `vault.qmd.version` sin actualizar el guardrail hace fallar un test (el bump no puede pasar en silencio).

## Assumptions

- El fallo confirmado es **exclusivo de docker/Alpine musl aarch64**; el modo local (glibc con toolchain) ya funciona y solo se cubre de forma preventiva (US5).
- **Mecanismo resuelto (clarify 2026-07-10): Opción A — mantener Alpine con toolchain**, con `embed` **en alcance**. El detalle (toolchain completo vs saltar install-scripts nativos) se fija en `/speckit-plan`. Riesgo principal: el build de `node-llama-cpp`/`llama.cpp` en musl aarch64; **fallback documentado** a B (base glibc) o C (embeddings remotos) si el gate ferrari lo invalida.
- El pin de qmd permanece en **2.5.3** (decisión heredada, single-source en `agent.yml`); no se bumpea en esta feature (guardrail US4).
- El TMPDIR host-backed bajo `.state` (feature 015 US3) está desplegado y es prerequisito; el build de módulos nativos lo reutiliza.
- Las libs `scripts/lib/*` se espejan a `docker/scripts/lib/*` con `COPY` explícito (decisión heredada); la paridad del mirror se mantiene.
- El gate DOCKER_E2E de la feature 015 (pendiente aparte) queda **absorbido** aquí al des-stubear `bunx` para qmd.
- El contenedor tiene egress de red para descargar headers de node/cmake/modelo de embeddings (confirmado por el funcionamiento de mclaren con el mismo flujo).
- Fuera de alcance: cambios al motor/esquema de qmd, features de RAG nuevas, y tocar el contenido de los vaults.
- Versionado: VERSION 0.9.0 → 0.10.0; CHANGELOG actualizado; sin exponer secretos en argv/journal.
