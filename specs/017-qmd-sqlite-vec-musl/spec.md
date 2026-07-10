# Feature Specification: qmd sqlite-vec en Alpine musl (cierre del embed semántico)

**Feature Branch**: `017-qmd-sqlite-vec-musl`

**Created**: 2026-07-10

**Status**: Draft

**Input**: Fix del tercer muro nativo del embed semántico en docker/musl. Completa el US2 (embed) de la feature 016, que se mergeó (PR #71, `14169cf`) sin correr su gate DOCKER_E2E. Al correr ese gate se confirmó: léxico verde, embed rojo, porque el prebuilt de `sqlite-vec` es glibc y no carga en musl.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - El agente dockerizado indexa y busca semánticamente (Priority: P1)

Un operador despliega un agente en modo `docker` (imagen Alpine musl) con RAG habilitado sobre su vault. El agente ejecuta el reindexado periódico: indexa léxicamente **y** genera embeddings vectoriales, de modo que las búsquedas semánticas (`qmd query`/`vsearch`, y el MCP de qmd que el agente usa en conversación) devuelven resultados por significado, no solo por coincidencia de palabras.

**Why this priority**: Es el valor central de la feature y cierra el criterio US2 de 016 que quedó incumplido en musl. Sin esto, un agente dockerizado tiene RAG léxico pero no semántico: "animal sobre el pc" no encuentra "el gato duerme sobre el teclado del computador". Hoy, además, en ferrari el reindexado falla por completo (BUG 4), así que el agente no tiene RAG utilizable.

**Independent Test**: En la imagen Alpine musl real, correr el pipeline de producción `collection add → update → embed → vsearch` sobre un vault mínimo y verificar que `embed` termina con éxito (chunks embebidos) y `vsearch` devuelve un match semántico. Verificable sin tocar el modo local ni otras features.

**Acceptance Scenarios**:

1. **Given** un agente en modo docker (Alpine musl aarch64) con vault y RAG habilitado, **When** corre el reindexado (`qmd embed`), **Then** los embeddings se generan sin error y el estado de reindexado reporta éxito (no "sqlite-vec extension is unavailable").
2. **Given** un índice con embeddings ya generados, **When** el operador o el agente ejecuta una búsqueda semántica, **Then** la extensión vectorial `vec0` está cargada y la búsqueda devuelve resultados por similitud vectorial.
3. **Given** un host en modo local (glibc), **When** corre el mismo reindexado, **Then** el comportamiento no cambia respecto de 016 (el prebuilt glibc ya cargaba): el embed sigue funcionando y no se introduce regresión.

---

### User Story 2 - El gate DOCKER_E2E ejercita el embed real (Priority: P2)

El mantenedor corre el gate DOCKER_E2E y este ejecuta un `embed` + `vsearch` **reales** de punta a punta (no un stub de `bunx --version` ni solo el arranque del MCP), de modo que esta clase de fallo —un binding nativo que no carga en musl— no pueda volver a pasar un merge sin ser detectada.

**Why this priority**: 016 se mergeó porque el e2e nunca ejerció el binding real; el stub de `bunx` y la Fase A que solo corría `--help` ocultaron el muro. Cerrar el gate es lo que convierte el fix en una garantía reproducible en vez de una verificación manual de una sola vez.

**Independent Test**: Correr `DOCKER_E2E=1 QMD_EMBED_E2E=1 bats tests/docker-e2e-qmd.bats` y confirmar que el tier de embed construye la imagen, corre el pipeline real y asevera el hit semántico; y que un build con el toolchain deshabilitado (`--build-arg QMD_NATIVE_TOOLCHAIN=0`) detecta el fallo (RED).

**Acceptance Scenarios**:

1. **Given** la imagen construida con el toolchain habilitado, **When** corre el tier de embed del DOCKER_E2E, **Then** el pipeline real `embed`+`vsearch` pasa y asevera un resultado semántico.
2. **Given** el mismo test, **When** se inspecciona la Fase A, **Then** usa el path de producción (`_qmd_run`/prefijo gestionado), no `bunx` directo, y discrimina por carga real del binding vectorial.

---

### User Story 3 - Guardrail de versión qmd/sqlite-vec (Priority: P3)

El mantenedor no puede bumpear `qmd` (y con él, transitivamente, `sqlite-vec`) sin que un test lo obligue a re-verificar la compatibilidad musl del binding vectorial.

**Why this priority**: El fix compila una versión concreta de la amalgamación de `sqlite-vec` (la que arrastra `qmd@2.5.3`). Un bump de qmd puede cambiar esa versión y su fuente, invalidando el shim de compilación silenciosamente. Es la misma disciplina de "pins deliberados, no drift" del Principle VI, con el patrón de tests-touchpoint ya usado en el proyecto.

**Independent Test**: Un test bats host falla si el par de versión (qmd / sqlite-vec esperado) cambia sin actualizar el contrato de compilación. Verificable en la suite host sin Docker.

**Acceptance Scenarios**:

1. **Given** el pin de qmd y la versión esperada de sqlite-vec, **When** alguien cambia el pin de qmd sin actualizar el contrato, **Then** un test host falla señalando que hay que re-verificar la compilación musl de sqlite-vec.

---

### Edge Cases

- **Host glibc en modo local**: el fix no debe activarse (el prebuilt glibc ya carga). La sustitución del binario ocurre solo cuando la libc objetivo es musl.
- **Toolchain deshabilitado** (`QMD_NATIVE_TOOLCHAIN=0`): sin compilador no se puede producir el `vec0.so` musl; el embed queda no disponible. El sistema debe degradar de forma observable (léxico sigue funcionando; el embed reporta la causa) y no crashear el reindexado ni el supervisor.
- **Descarga de la amalgamación falla en build**: si la fuente de sqlite-vec no está disponible al construir la imagen, el build debe fallar de forma clara (fail-loud en build-time), no producir una imagen que aparente estar completa y falle en runtime.
- **Bind-mount `.state` enmascara el prefijo**: un artefacto compilado dentro del prefijo en build no sobrevive al montaje de `.state` en runtime; el binario musl debe residir en una ruta de la imagen no enmascarada y copiarse al prefijo en el arranque del reindexado.
- **Prefijo ya provisto / binario ya sustituido**: la sustitución debe ser idempotente (re-ejecutable sin duplicar trabajo ni corromper el prefijo), verificando que el binario en uso es musl antes de reemplazar.
- **El `.so.so` como síntoma**: el mensaje "vec0.so.so: No such file or directory" es un efecto del fallback de dos intentos de SQLite sobre un dlopen que falla; el fix se valida por carga exitosa del binding, no por la ausencia de ese string.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: En modo docker sobre libc musl, el sistema MUST proveer al motor de RAG una extensión vectorial `sqlite-vec` que cargue en musl (linkeada contra musl, sin dependencias glibc), en lugar del prebuilt glibc que trae el paquete.
- **FR-002**: El binario vectorial musl MUST producirse de forma determinista y sin acceso a red en runtime (compilado en tiempo de build de la imagen a partir de una fuente de versión fija), y MUST residir en una ruta de la imagen que el bind-mount de `.state` no enmascare.
- **FR-003**: Durante el aprovisionamiento del prefijo gestionado de qmd, el sistema MUST sustituir el prebuilt glibc por el binario musl, de forma idempotente y solo cuando la libc objetivo sea musl; en glibc (modo local) MUST dejar el prefijo sin tocar.
- **FR-004**: Tras el fix, el pipeline `embed` MUST completar con éxito en musl (generar y almacenar vectores) y `vsearch`/`query` MUST devolver resultados por similitud vectorial; el reindexado MUST reportar el resultado del embed en su estado observable.
- **FR-005**: El modo local (glibc) MUST permanecer sin cambios de comportamiento respecto de 016 (sin regresión en su embed, que ya funciona).
- **FR-006**: El DOCKER_E2E MUST ejercitar un `embed` + `vsearch` reales de punta a punta contra el path de producción y aseverar un resultado semántico; MUST dejar de usar stubs (`bunx --version`/solo arranque de MCP) para la validación del binding, y su Fase A MUST usar el path de producción, no `bunx` directo.
- **FR-007**: El DOCKER_E2E MUST poder detectar el fallo (RED) cuando el toolchain está deshabilitado, para probar que el gate discrimina la ausencia del binding musl.
- **FR-008**: El sistema MUST fijar, mediante un test host, la correspondencia entre el pin de qmd y la versión de sqlite-vec cuya compilación musl está soportada, de modo que un bump de qmd obligue a re-verificar.
- **FR-009**: Las bibliotecas compartidas modificadas (`scripts/lib/qmd_index.sh` y su espejo `docker/scripts/lib/`) MUST mantenerse espejadas vía el mecanismo de COPY existente; el cambio MUST sobrevivir `./setup.sh --regenerate`.
- **FR-010**: El fix MUST NOT introducir secretos en argv/journal, MUST NOT cambiar el OS base ni el modelo de privilegios del contenedor (Principle II), y su costo (artefacto compilado ~150KB + toolchain de build ya presente por 016) MUST registrarse en Complexity Tracking del plan.
- **FR-011**: Los cambios de contrato al usuario/mantenedor MUST reflejarse en `CHANGELOG.md` y en `VERSION` (0.10.0 → 0.11.0).

### Key Entities *(include if data involved)*

- **Binario vectorial `vec0` (sqlite-vec)**: la extensión SQLite que provee la virtual table `vec0` para almacenar/consultar embeddings. Atributo clave: la libc contra la que está linkeada (glibc prebuilt vs musl compilado). Es la unidad que se sustituye.
- **Prefijo gestionado de qmd**: el directorio bajo la caché (`~/.cache/qmd/pkg`, sobre `.state`) donde vive el `node_modules` de qmd instalado en runtime, incluido el paquete de sqlite-vec cuyo binario se sustituye.
- **Fuente de sqlite-vec (amalgamación)**: el archivo `.c` único de versión fija desde el que se compila el binario musl en build.
- **Estado de reindexado**: el archivo de estado del heartbeat de reindexado que reporta si el embed tuvo éxito o degradó, y por qué (observabilidad de 015-US4).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En la imagen Alpine musl aarch64 real, el pipeline `collection add → update → embed → vsearch` completa con `embed` exitoso y `vsearch` devuelve al menos un match semántico (una consulta sin solapamiento léxico con el documento recupera el documento correcto).
- **SC-002**: Cero regresión en modo local (glibc): el embed que ya funcionaba sigue funcionando sin cambios.
- **SC-003**: El gate DOCKER_E2E, con el toolchain habilitado, pasa el tier de embed real; con el toolchain deshabilitado, falla (RED). El resultado es reproducible, no una verificación manual de una vez.
- **SC-004**: La suite host completa (`bats tests/`) queda verde y `shellcheck -S error` limpio, con los nuevos tests (embed e2e des-stubeado, guardrail de versión) incluidos.
- **SC-005**: Gate confirmatorio en ferrari: el reindexado real embebe sobre el vault real, el wiki-graph sigue correcto sobre ~2696 páginas, y `/tmp` no se llena (sin ENOSPC).

## Assumptions

- El toolchain de compilación (`build-base`/`cc`, `cmake`, `linux-headers`, `libgomp`) ya está en la imagen desde 016, gateado por `QMD_NATIVE_TOOLCHAIN`; este fix lo reutiliza y no agrega un stage nuevo (imagen Alpine single-stage intacta, Principle II).
- La detección de libc (`_libc_variant`, 015-US2) es la fuente de verdad para gatear la sustitución musl vs glibc.
- La observabilidad del reindexado (015-US4) y el `TMPDIR` host-backed bajo `.state` (015-US3) son prerequisitos ya presentes; este fix se apoya en ellos y no los altera.
- node-llama-cpp (la inferencia del embed) ya está resuelto por 016: la verificación de esta sesión mostró que descarga el modelo y embebe sin SIGSEGV una vez que sqlite-vec carga; sqlite-vec era el único muro restante del embed en musl.
- El pin de qmd permanece en 2.5.3 (single-source en `agent.yml vault.qmd.version`); la versión de sqlite-vec (0.1.9) es la que arrastra ese pin.
- La estrategia concreta de compilación/sustitución (build-time bake + copia en runtime vs otras) se fija en `/speckit-plan`/`/speckit-clarify`; esta spec fija el QUÉ y los criterios de aceptación, no el CÓMO exacto.
