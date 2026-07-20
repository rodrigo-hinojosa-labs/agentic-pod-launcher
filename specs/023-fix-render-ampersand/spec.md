# Feature Specification: el motor de render deja de corromper valores con `&`

**Feature Branch**: `023-fix-render-ampersand`

**Created**: 2026-07-19

**Status**: Draft

**Input**: bug encontrado el 2026-07-19 mientras se cerraba la feature 022; ajeno a esa
rama y presente en `main`. Contexto medido abajo.

## Contexto medido

Todo lo de esta sección fue **medido**, no inferido. Lo que no se midió está en
"Preguntas abiertas".

El motor de render expande los `{{campo}}` de un bloque `{{#each}}` con sustitución de
parámetros de bash (`scripts/lib/render.sh:90` y `:95`). Desde **bash 5.2**, un `&` sin
escapar en el *reemplazo* de `${var//patrón/reemplazo}` significa "todo el texto
coincidente" — un cambio de compatibilidad con ksh93. El mismo comando, en tres bash:

| bash | resultado para el valor `A&B` |
|---|---|
| 3.2.57 (`/bin/bash`, macOS) | `ref=A&Bv=x` — correcto |
| 5.3.15 (Homebrew, el que resuelve `env bash`) | `ref=A{{url}}Bv=x` — **corrupto** |
| 5.2.37 (**mclaren**, host de agente en producción) | `ref=A{{u}}Bv=x` — **corrupto** |

El `&` se sustituye por el propio placeholder que se estaba reemplazando. Sin error, sin
warning, sin código de salida distinto de cero: **corrupción silenciosa**.

**Está vivo en producción.** mclaren corre bash 5.2.37 y reproduce la corrupción. No es
un problema teórico ni exclusivo del entorno de desarrollo.

**Hoy no hay datos dañados en mclaren**: su `agent.yml` no tiene filas `.mcps.atlassian`
y ninguno de esos campos contiene `&` (conteo 0). El riesgo es de materialización futura,
no de daño ya ocurrido — al menos en ese host.

**Superficie exacta** (verificada por grep, no inferida):

- `{{#each}}` tiene **dos** consumidores, ambos sobre `MCPS_ATLASSIAN`:
  `modules/mcp-json.tpl:48` y `modules/env-example.tpl:14`. Los campos por fila son
  `name`, `url`, `email`.
- `env-example.tpl:15-19` escribe `{{url}}` y `{{email}}` **directo** a líneas del `.env`
  generado. `mcp-json.tpl:49` usa `{{name}}`/`{{NAME}}` para componer el nombre del
  servidor MCP y de las variables de entorno.
- Las otras cuatro sustituciones `${x//…}` del repo (`schema.sh:137`,
  `wizard-validators.sh:103`, `wiki_graph.sh:394`, `setup.sh:161`) usan reemplazos
  **literales** sin `&`. Las dos líneas de `render.sh` son el único sitio donde el
  reemplazo proviene de datos del operador.
- `render.sh` **no** está espejado a `docker/` (`find docker -name render.sh` vacío; el
  `Dockerfile` no lo copia). Es host-side puro.

**El patrón correcto ya existe en el mismo archivo.** `render.sh:105-110` sustituye el
`full_match` del bloque vía `REPL="$expanded" perl -0777 -e '… s/$full/$ENV{REPL}/e …'`,
y su comentario (`:100-104`) explica que se hace así justamente para que el valor no se
interprete. Las dos líneas de sustitución de *campos* nunca pasaron por esa protección.

**Cómo se manifiesta hoy**: `tests/render.bats:71` ("preserves literal `$1` and `\1`")
queda rojo bajo bash ≥5.2 y verde bajo 3.2 (`render.bats` da 11/11 con `PATH=/bin:$PATH`).
Ese test se escribió para otro riesgo y caza este de rebote, porque su valor de prueba
contiene un `&`. Su nombre no menciona el `&`, así que el síntoma apunta al diagnóstico
equivocado.

**Contradicción con lo que el repo declara**: `CLAUDE.md` afirma que el launcher corre
sobre bash sin piso de versión. La afirmación es cierta sobre los *constructos* usados y
falsa sobre la *equivalencia de comportamiento*: 3.2 y 5.2+ producen salidas distintas
para la misma entrada. Consecuencia práctica: un mismo commit da verde o rojo según la
máquina, y nada lo declara.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - un valor de configuración llega intacto al artefacto (Priority: P1)

Un operador escribe en `agent.yml` un valor que contiene `&` — típicamente una URL con
query string. Al scaffoldear o al correr `--regenerate`, ese valor debe aparecer carácter
por carácter en el `.env` y en el `.mcp.json` generados, sin importar qué versión de bash
tenga el host.

**Why this priority**: es el bug. Sin esto, la configuración del operador se reescribe
sola, en silencio, y el síntoma aparece mucho después y lejos: un MCP que no autentica,
una URL que no resuelve. El costo de diagnóstico es altísimo comparado con el de la causa.

**Independent Test**: renderizar una plantilla con un valor que contenga `&` y comparar la
salida con el valor original, byte a byte, bajo cada bash disponible en el host.

**Acceptance Scenarios**:

1. **Given** un `agent.yml` con `url: "https://x.example/p?a=1&b=2"`, **When** se
   renderiza `env-example.tpl`, **Then** la línea generada contiene exactamente
   `https://x.example/p?a=1&b=2`.
2. **Given** el mismo `agent.yml`, **When** se renderiza bajo bash 3.2 y bajo bash ≥5.2,
   **Then** ambas salidas son byte-idénticas entre sí.
3. **Given** un valor con `&` **y** con `$1` / `\1`, **When** se renderiza, **Then** los
   tres se preservan literales — el arreglo no debe reintroducir el riesgo que
   `:105-110` ya cubría.

---

### User Story 2 - el rojo del test nombra su propia causa (Priority: P2)

Quien corra la suite y vea un rojo debe poder leer del nombre del test qué invariante se
rompió, sin reconstruir el diagnóstico desde cero.

**Why this priority**: hoy el `&` se detecta desde un test llamado "preserves literal `$1`
and `\1`". Ese nombre mandó la investigación inicial hacia la interpolación de perl, que
no tenía nada que ver. Un test dedicado convierte una hora de diagnóstico en una línea de
lectura.

**Independent Test**: introducir a propósito el defecto del `&` y confirmar que el test
que se pone rojo es el que lo nombra.

**Acceptance Scenarios**:

1. **Given** el defecto presente, **When** corre la suite, **Then** falla un test cuyo
   nombre menciona explícitamente el `&` y la preservación literal.
2. **Given** el arreglo aplicado, **When** corre la suite bajo cualquier bash del host,
   **Then** ese test pasa y el de `$1`/`\1` también.

---

### User Story 3 - la suite dice bajo qué bash corrió (Priority: P3)

Quien lea un resultado de la suite debe saber con qué intérprete se obtuvo, y el proyecto
debe declarar qué versiones sostiene.

**Why this priority**: la razón por la que este bug vivió sin detectarse es que la suite
corrió durante meses bajo un bash y hoy bajo otro, sin que nada lo declarara ni lo
registrara. Mientras eso siga así, cualquier invariante sensible a la versión puede volver
a esconderse. Es P3 porque no arregla el bug — evita la próxima clase entera de bugs como
este.

**Independent Test**: correr la suite y verificar que informa la versión del intérprete;
verificar que la documentación declara el rango sostenido y coincide con lo medido.

**Acceptance Scenarios**:

1. **Given** la suite corriendo, **When** termina, **Then** el resultado permite saber qué
   versión de bash se usó.
2. **Given** la documentación del proyecto, **When** se contrasta con el comportamiento
   medido, **Then** no afirma equivalencia entre versiones que no la tienen.

---

### Edge Cases

- Un valor formado **solo** por `&`, o con `&` al principio o al final.
- `&&`, `\&` y `&` ya escapado escrito a mano por el operador — cada uno debe salir tal
  cual se escribió.
- Un valor que contenga a la vez `&`, `$1`, `\1` y `{{` — la combinación adversarial.
- Un valor vacío o ausente (`null` de yq): el comportamiento actual no debe cambiar.
- La variante en mayúsculas (`render.sh:95`, `{{CAMPO}}`) tiene el mismo defecto que la de
  minúsculas y debe quedar cubierta por separado; arreglar una sola dejaría el bug vivo
  por la otra mitad.
- Un `agent.yml` **sin** ningún `&`: la salida de `--regenerate` debe quedar byte-idéntica
  a la actual. Esta es la prueba de no-regresión que protege a los workspaces desplegados.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: El sistema MUST reproducir literalmente cualquier valor de `agent.yml` al
  expandir un campo dentro de un bloque `{{#each}}`, incluido el carácter `&`.
- **FR-002**: El sistema MUST producir salida idéntica para la misma entrada bajo bash 3.2
  y bajo bash 5.2 o superior.
- **FR-003**: El sistema MUST aplicar la misma protección a la variante en minúsculas y a
  la variante en mayúsculas de la sustitución de campos.
- **FR-004**: El sistema MUST seguir preservando `$1`, `$2`, `\1`, `\2` literales — el
  arreglo no puede reintroducir el riesgo que la sustitución del bloque ya cubre.
- **FR-005**: El sistema MUST dejar byte-idéntica la salida de un `--regenerate` sobre un
  `agent.yml` que no contenga `&`.
- **FR-006**: La suite MUST incluir un test cuyo nombre identifique explícitamente la
  preservación literal del `&`.
- **FR-007**: El sistema MUST mantener el modo docker sin cambios; el motor de render es
  host-side y no se despliega dentro de la imagen.
- **FR-008**: El proyecto MUST declarar en su documentación qué versiones de bash
  sostiene, y esa declaración MUST corresponder al comportamiento medido.
- **FR-009**: La ejecución de la suite MUST permitir saber con qué versión de bash se
  obtuvo el resultado.

### Key Entities

- **Valor de campo**: el texto que el operador escribe en un ítem de arreglo de
  `agent.yml` (`name`, `url`, `email`). Es dato no confiable desde el punto de vista del
  motor: puede contener cualquier carácter, y ninguno debe tener significado especial.
- **Bloque repetido**: la porción de plantilla que se expande una vez por fila del
  arreglo. Sus campos son el único punto donde hoy entra dato del operador a una
  sustitución.
- **Artefacto generado**: el `.env` y el `.mcp.json` del workspace. Son el destino final
  del valor y el lugar donde una corrupción pasa inadvertida.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Un valor con `&` sobrevive el render sin alteración: comparación byte a byte
  contra el valor original, resultado idéntico.
- **SC-002**: La misma entrada renderizada bajo bash 3.2 y bajo bash ≥5.2 produce salidas
  byte-idénticas.
- **SC-003**: Con el defecto reintroducido a propósito, al menos un test se pone rojo, y su
  nombre menciona el `&`.
- **SC-004**: La suite completa queda en cero fallas bajo **cada** versión de bash
  disponible en el host de desarrollo — hoy 3.2 y 5.3.
- **SC-005**: Un `--regenerate` sobre un `agent.yml` sin `&` produce artefactos
  byte-idénticos a los que produce hoy.
- **SC-006**: Los tres casos adversariales (`&` solo, `&` junto a `$1`/`\1`, `&` en los
  bordes del valor) pasan.

## Assumptions

- El arreglo es de código, no de datos: no se detectó ningún `agent.yml` real con un valor
  afectado (medido en mclaren; ferrari pendiente). Si la investigación encuentra uno, la
  remediación de datos se agrega al alcance.
- El alcance es la sustitución de campos de `{{#each}}`. Las otras cuatro sustituciones del
  repo se revisaron y usan reemplazos literales; se dejan como están.
- No se agrega dependencia nueva: el mecanismo seguro que se adoptará ya se usa en el mismo
  archivo, así que no cambia el conjunto de herramientas requeridas en el host.
- La corrección de la afirmación sobre bash en la documentación entra en esta feature por
  ser la causa de que el bug pasara inadvertido, no como tarea de docs suelta.

## Preguntas abiertas

Se listan aparte para que nadie las lea como hechos medidos.

1. **ferrari**: no se midió su versión de bash ni se revisó su `agent.yml` — el túnel SSH
   está caído (pendiente de re-autenticación en el navegador). Debe medirse antes de cerrar
   la feature, aunque no bloquea el arreglo.
2. **Cuál mecanismo adoptar**: hay al menos tres candidatos y ninguno está prefijado.
   Enrutar por el mismo perl que ya usa el archivo es el más consistente; escapar el `&` en
   el valor **parece una trampa** porque no es portable — en bash 3.2 un `\&` insertaría un
   backslash literal, arreglando 5.2 y rompiendo 3.2; y un modo de compatibilidad de bash
   ataría el repo a una bandera que puede desaparecer. Hay que **medirlo**, no razonarlo.
3. **Piso o matriz de versiones**: decidir si el proyecto declara 3.2+ y lo prueba en ambas,
   o si sube el piso. Afecta a FR-008/FR-009 y al costo de correr la suite.
4. **Por qué cambió el bash que resuelve `bats` a mitad de sesión**: la suite pasó de 3.2 a
   5.3 sin que nadie lo declarara. No se determinó la causa. Importa para saber si el
   resultado de la suite es reproducible entre corridas del mismo equipo.
