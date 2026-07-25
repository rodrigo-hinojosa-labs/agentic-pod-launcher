# Feature Specification: reiniciar el agente deja de romper el enlace del cliente

**Feature Branch**: `024-fix-session-restart-retire`

**Created**: 2026-07-20

**Status**: Draft

**Input**: Bug medido en hardware vivo durante el gate T051 de la feature 022 (mclaren, 2026-07-20 00:21:22). El gate corrió DESPUÉS del merge de 022 (PR #80, merge `ab4bb32`), así que el defecto está en `main` hoy.

## Contexto medido

Esta sección registra **solo hechos verificados**, cada uno con su fuente. Es el
insumo del diseño, no el diseño.

### El comportamiento observado

Un `systemctl restart` de un agente en modo local, con una sesión **viva y
conectada**, retira el puntero de sesión y anuncia una sesión nueva. El enlace
que el operador tenía abierto en su cliente muere sin aviso.

Journal de mclaren, medido, no inferido:

```text
00:21:22 systemd[1]: Stopping agent-mclaren-admin.service...
00:21:22 claude[1154300]: ·✔︎· Connected · mclaren-admin        <- sesión VIVA en el instante del stop
00:21:22 claude[1154300]: .../session_01Fbg3Cg1ywYaeAx32UsHot8  <- sessionId anterior
00:21:22 systemd[1]: agent-mclaren-admin.service: Deactivated successfully.
00:21:22 agent-session-check.sh[591196]: retired a stale session pointer (previous exit_code=exited)
00:21:24 claude[591215]: .../session_01A1obgNuL2XkXLX7bdr6nQV  <- sessionId NUEVO
```

Evidencia lateral en el mismo host: quedó un hermano `bridge-pointer.retired.json`
y el `sessionId` del puntero cambió respecto de la foto tomada antes del reinicio.

### La causa, verificada en el código

`scripts/lib/session_pointer.sh:212-224`:

```bash
session_decide() {
  local marker="$1" state="$2"
  if [ "$state" != "present" ]; then printf 'noop\n'; return 0; fi
  if [ "$marker" = "killed" ]; then printf 'keep\n'; else printf 'retire\n'; fi
  return 0
}
```

El `marker` es el campo `exit_code` del marcador de salida
(`session_exit_marker_read` → `_session_marker_field`, `:149-171`), que a su vez
guarda el `$EXIT_CODE` que systemd entrega al `ExecStopPost`
(`session_exit_marker_write`, `:129-147`; invocado desde
`modules/local-session-exit.sh.tpl`, montado en la unit por
`modules/systemd-remote-control.service.tpl:44`).

**El supuesto de 022 era que `$EXIT_CODE` distingue "la sesión terminó y el
proceso salió solo" de "systemd detuvo el servicio". No los distingue.** Claude
Code atrapa `SIGTERM` y sale con código 0, así que systemd reporta `exited` en
ambos casos (`Deactivated successfully` en la traza de arriba). El valor `killed`
solo aparecería si el proceso NO atrapara la señal. Como sí la atrapa, la rama
`keep` es prácticamente inalcanzable y la regla se comporta como *retirar
siempre*.

### Información disponible que la decisión no usa

`session_exit_marker_write` (`:137`) persiste **tres** valores —
`service_result`, `exit_code`, `exit_status`— pero `session_decide` solo consume
`exit_code`. Un `grep` sobre `scripts/`, `modules/` y `tests/` confirma que
`service_result` no participa de ninguna decisión: aparece únicamente en la
escritura y en aserciones de test. Si alguno de los otros dos campos discrimina,
el dato ya se está guardando y nadie lo mira.

### Por qué es una regresión y no un caso simplemente no cubierto

`research.md` R2 de la feature 022 **midió** que, antes de ese cambio, un
`systemctl restart` limpio preservaba el `sessionId` y dejaba al agente
alcanzable con el **mismo** enlace. Ese comportamiento se perdió.

La ironía acota el diseño: la propia investigación de 022 concluyó que "limpiar
siempre al boot habría sido regresión" —está escrito así en `CLAUDE.md`— y el
código entregado se comporta exactamente así, porque el discriminador elegido
colapsa los dos casos en uno. El criterio **SC-009 de 022** ("un restart de una
sesión viva preserva el enlace del cliente") **falla en hardware**.

### Gravedad observada

Es degradación de experiencia, no caída. Tras el retiro el agente queda `active`
y alcanzable, pero en un enlace nuevo; el anterior muere. Medido en el mismo
gate: la unit quedó `active`, `NRestarts=0`, y el operador confirmó que la sesión
remota funcionaba —en el enlace nuevo—. Nada en el diagnóstico avisa que el
enlace viejo se perdió.

### Lo que la suite no vio

`bats tests/` da **1159 ok / 0 not ok** bajo bash 5.3.15 y 3.2.57, con
`tests/session-pointer.bats` y `tests/local-session-hooks.bats` cubriendo esta
lib. Ningún test lo cazó porque todos alimentan el marcador con valores
elegidos por el propio test; ninguno ejercita **qué valor entrega systemd de
verdad** cuando detiene un proceso que atrapa `SIGTERM`. El límite de la
cobertura host es real y hay que declararlo, no taparlo.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - reiniciar el servicio no le quita la conversación al operador (Priority: P1)

El operador reinicia el agente por una razón cualquiera —aplicar una
configuración nueva, un `--regenerate`, mantenimiento del host— mientras tiene
una conversación abierta desde el celular. Al volver, sigue en la misma
conversación: el enlace que tenía guardado continúa sirviendo.

**Why this priority**: es el defecto medido y el que rompe una expectativa que el
sistema cumplía antes. Sin esto, cualquier operación de mantenimiento le cuesta
la conversación al operador, en silencio.

**Independent Test**: reiniciar el servicio con una sesión conectada y comprobar,
desde el cliente, que el enlace previo sigue funcionando y que el identificador
de sesión no cambió.

**Acceptance Scenarios**:

1. **Given** un agente con una sesión conectada y un puntero vivo, **When** el
   operador reinicia el servicio, **Then** el puntero se conserva, no aparece
   hermano retirado, y el cliente sigue alcanzando la misma conversación.
2. **Given** el mismo estado, **When** el operador detiene y luego arranca el
   servicio en dos pasos, **Then** el resultado es idéntico al del reinicio.
3. **Given** el mismo estado, **When** el host se reinicia por completo,
   **Then** el comportamiento es el que la investigación determine como correcto
   para ese caso, y queda declarado explícitamente en vez de quedar implícito.

---

### User Story 2 - una sesión que termina sola sigue limpiándose (Priority: P1)

Cuando la conversación se cierra desde el cliente, la sesión se completa y el
proceso sale por su cuenta. El agente debe volver a estar disponible anunciando
una sesión nueva, sin intervención manual.

**Why this priority**: es exactamente lo que 022 vino a arreglar. El arreglo de
US1 no puede reintroducir el bug original —quedaría el agente inalcanzable, que
es peor que perder un enlace—. Van juntas: una sin la otra deja el sistema roto
por el otro lado.

**Independent Test**: terminar la conversación desde el cliente y comprobar que
el agente vuelve a estar alcanzable sin tocar nada en el host.

**Acceptance Scenarios**:

1. **Given** un agente cuya sesión se completó y cuyo proceso salió solo,
   **When** el servicio se revive automáticamente, **Then** el puntero rancio se
   retira y se anuncia una sesión nueva alcanzable.
2. **Given** ese mismo caso, **Then** el puntero retirado se conserva como
   evidencia forense en vez de borrarse.

---

### User Story 3 - el operador puede saber cuál de los dos casos ocurrió (Priority: P2)

Tras un arranque, el operador puede averiguar por qué se detuvo el proceso
anterior y qué decidió el sistema al respecto, sin reconstruirlo a mano.

**Why this priority**: el defecto de 022 sobrevivió a la revisión y a la suite
porque la decisión no era observable —el único rastro es una línea de log que
afirma "stale" sin decir en qué se basó—. Que la razón sea legible es lo que
permite cazar la próxima divergencia en vez de descubrirla en producción.

**Independent Test**: leer la salida del diagnóstico y del registro tras cada uno
de los dos casos, y comprobar que nombran la causa y la decisión.

**Acceptance Scenarios**:

1. **Given** un arranque posterior a una parada iniciada por el operador,
   **When** se consulta el diagnóstico, **Then** informa que la parada fue
   externa y que el puntero se conservó.
2. **Given** un arranque posterior a una sesión que terminó sola, **When** se
   consulta el diagnóstico, **Then** informa que la sesión terminó y que el
   puntero se retiró.

### Edge Cases

- **El marcador no existe** (primer arranque, o el `ExecStopPost` no llegó a
  correr porque el proceso murió por `SIGKILL` u OOM). No puede tratarse como
  "salió solo" por defecto si eso implica retirar un puntero potencialmente vivo.
- **El marcador está corrupto o truncado.** Ya cubierto por 022 como "no se puede
  determinar"; el arreglo no debe degradar esa lectura ni convertirla en un valor
  válido por accidente.
- **El proceso muere por señal sin atrapar** (`SIGKILL`, OOM killer): el único
  caso en que hoy aparece `killed`. Debe seguir decidiéndose de forma explícita.
- **Dos arranques compitiendo** por el mismo marcador: 022 ya resuelve el consumo
  único vía `rename`; el arreglo no puede introducir una segunda ruta que lo lea
  sin consumirlo.
- **`--regenerate` sin reinstalar la unit** (el caso `sudo` no disponible, medido
  en mclaren): los artefactos quedan staged y la unit instalada sigue con la
  lógica vieja. El diagnóstico debe delatar esa divergencia.
- **El agente detenido a propósito y no reiniciado**: al arrancar días después,
  la sesión conservada casi seguro ya no existe del lado del relay.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: El sistema MUST conservar el puntero de sesión cuando la parada del
  proceso anterior fue iniciada externamente (reinicio, detención o apagado
  ordenado del servicio), incluso si el proceso salió con código 0.
- **FR-002**: El sistema MUST retirar el puntero de sesión cuando el proceso
  anterior salió por su cuenta al completarse su sesión.
- **FR-003**: El sistema MUST distinguir los dos casos anteriores mediante una
  señal cuya diferencia haya sido **medida** contra el gestor de servicios real
  del host del agente, no deducida de documentación ni de razonamiento.
- **FR-004**: Cuando la causa de la parada no se pueda determinar (marcador
  ausente, corrupto o de forma desconocida), el sistema MUST elegir la opción que
  no destruya trabajo del operador, y MUST registrar que decidió bajo
  incertidumbre.
- **FR-005**: El retiro de un puntero MUST seguir preservándolo como evidencia
  (renombrado, nunca borrado).
- **FR-006**: El sistema MUST NOT introducir ningún mecanismo que sondee,
  muestree o infiera periódicamente si una sesión sigue viva. La decisión ocurre
  una sola vez por arranque, sobre un hecho ya registrado.
- **FR-007**: El registro de cada arranque MUST nombrar la causa de la parada
  anterior y la decisión tomada, de forma legible sin herramientas extra.
- **FR-008**: El diagnóstico del agente MUST informar la última decisión y MUST
  delatar cuando la unidad instalada no coincide con la que el workspace
  generaría.
- **FR-009**: El comportamiento MUST sobrevivir a una regeneración desde la
  fuente de verdad de configuración, sin edición manual de artefactos derivados.
- **FR-010**: La suite host MUST cubrir la regla de decisión para todos los
  valores que el gestor de servicios pueda entregar, incluidos los medidos en
  FR-003, con un test cuyo nombre identifique el caso del reinicio.
- **FR-011**: La documentación MUST declarar explícitamente qué parte de este
  comportamiento la suite host NO puede verificar y qué gate lo cubre.
- **FR-012**: El modo contenedor MUST permanecer sin cambios.

### Key Entities

- **Puntero de sesión**: el enlace que asocia al agente con una conversación del
  cliente. Su presencia o ausencia al arrancar determina si el operador conserva
  su conversación. Entrada no confiable.
- **Marcador de salida**: registro que deja el proceso anterior al detenerse,
  describiendo cómo terminó. Hoy guarda tres valores y solo uno se consulta.
  Es de consumo único.
- **Causa de parada**: la clasificación que interesa —parada externa frente a
  fin de sesión—. Es lo que hoy no se puede derivar del dato disponible.
- **Decisión**: conservar, retirar o no hacer nada. Debe ser observable después
  del hecho.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Reiniciar el servicio con una conversación abierta conserva el
  enlace del operador en el 100% de los intentos, verificado desde el cliente en
  el host real del agente, en al menos dos reinicios consecutivos.
- **SC-002**: Cerrar la conversación desde el cliente deja al agente alcanzable
  otra vez sin ninguna acción manual en el host, verificado desde el cliente.
- **SC-003**: Tras cada arranque, la causa de la parada anterior y la decisión
  tomada son legibles en el registro y en el diagnóstico, sin consultar el código.
- **SC-004**: La suite host pasa completa en las dos versiones de bash
  soportadas, y al menos un test falla —por su nombre— si se revierte la regla de
  decisión al comportamiento actual.
- **SC-005**: La diferencia de señal que sustenta FR-003 queda registrada como
  medición reproducible: comando, host, salida observada.
- **SC-006**: El gate de hardware se ejecuta **antes** del merge y queda
  documentado, cubriendo SC-001, SC-002 y SC-003.
- **SC-007**: Un arranque con marcador ausente o corrupto no destruye un puntero
  vivo, y deja constancia de haber decidido bajo incertidumbre.

## Assumptions

- El defecto es exclusivo del modo local; el modo contenedor no tiene puntero de
  sesión ni unidades de servicio y queda fuera de alcance.
- El host del agente es Linux con systemd. La suite corre en macOS, donde ese
  gestor no existe: por eso FR-003 exige medición en el host real y SC-006 exige
  gate de hardware.
- Se asume que Claude Code seguirá atrapando `SIGTERM` y saliendo con código 0.
  Si dejara de hacerlo, la regla actual empezaría a funcionar por accidente; el
  arreglo no debe depender de ese comportamiento del proveedor en ninguna
  dirección.
- Conservar un puntero cuya sesión ya expiró del lado del servidor reproduce el
  bug original de 022. Se asume que la investigación determinará si eso obliga a
  acotar la conservación por tiempo o por alguna otra condición.
- El agente de referencia para el gate es mclaren, donde 022 ya está desplegado y
  el defecto fue medido.

## Preguntas abiertas

Se registran aquí, sin prejuzgar, para que la investigación las cierre
**midiendo**. No son requisitos.

1. **Cuál es el discriminador correcto.** Candidato **NO VERIFICADO**: que la
   ejecución de un comando de parada solo ocurra cuando el gestor detiene el
   servicio, y no cuando el proceso sale por su cuenta. Hay que comprobarlo
   contra systemd real antes de construir encima —es la lección de este mismo
   gate—. Evaluar también si `service_result` o `exit_status`, ya persistidos y
   hoy ignorados, aportan lo que `exit_code` no aporta.
2. **La frecuencia relativa de los dos casos.** En mclaren se contaron 4 paradas
   iniciadas por systemd y 0 salidas propias, **pero el journal solo retenía ~2
   días** (desde el 18 de julio 13:57): la muestra no permite concluir. Si los
   reinicios resultaran mucho más frecuentes que las sesiones que terminan solas,
   022 estaría rompiendo el caso común para arreglar el raro, y eso cambiaría la
   urgencia y quizá el diseño.
3. **Si basta con dejar de romper el enlace o hay que restaurarlo.** Hoy, tras
   retirar, se anuncia una sesión nueva alcanzable. Decidir si conservar el
   puntero en el caso externo es suficiente.
4. **Qué hacer en un reinicio del host.** Es una parada externa por definición,
   pero la sesión conservada puede llevar horas muerta del lado del relay.
   022 midió DOS veces que la reutilización del proveedor restauraba el mismo
   enlace; hay que confirmar si eso sigue valiendo tras un apagado largo.
