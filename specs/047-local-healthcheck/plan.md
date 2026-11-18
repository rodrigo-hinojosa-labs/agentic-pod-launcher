# Implementation Plan: Healthcheck local sin falsos avisos de login

**Branch**: `047-local-healthcheck` | **Date**: 2026-11-17 | **Spec**: [spec.md](spec.md)

**Input**: [Especificación de 047](spec.md), #111; tres decisiones de specify y tres aclaraciones posteriores integradas. Solo esta feature.

## Summary

Corregir el diagnóstico local para distinguir acceso renovable, renovación vencida y pérdida comprobada del login; reconocer conexiones de todos los procesos de la unidad; y emitir avisos por cambios, con siete días de anticipación y reintentos desde los treinta minutos. Los envíos dependen de un registro durable y se suspenden si no puede persistirse. Una recuperación solo avisa si hubo algún aviso confirmado del episodio.

El diseño conserva el CLI renderizado y añade una biblioteca renderizada exclusivamente en modo local. Usa jq, systemd/cgroup v2, proc y ss para observar; JSON privado, flock y commits atómicos sincronizados para avisos. Un job Linux aislado valida la composición real antes del merge. Las decisiones y fuentes están en [research.md](research.md).

## Technical Context

**Language/Version**: bash compatible con 3.2 y 5.x. Producción local en Linux; oráculos sintéticos en macOS 3.2 y Linux 5.x. Python 3 solo en fixtures de integración, no como nueva dependencia del healthcheck.

**Primary Dependencies**: jq; systemctl y journalctl; cgroup v2/proc; ss de iproute2; GNU coreutils timeout y sync; flock de util-linux; curl para avisos opcionales. Las ausencias se diagnostican sin afirmar salud comprobada ni enviar sin exclusión. yq se usa para render/tests, con el pin existente del CI.

**Storage**: `.state/local-healthcheck.json`, schema 1, máximo 16 KiB y modo 0600; `.state/.local-healthcheck.lock`, inode estable, modo 0600. Temporales únicos privados dentro de .state, retirados al terminar. No tokens, payloads ni journal crudo en el registro durable.

**Testing**: BATS sin Docker, secuencial en los dos bash; regresión local/021/SIGPIPE/render; mutaciones dirigidas; shellcheck; comparación de artefactos Docker; gate Linux real separado de `bats tests/`. El arnés inyecta dobles estrictos de timeout/sync y bloqueo efectivo para los casos sintéticos, sin depender de coreutils instalado en el Mac; N30/N31 comprueban señales, orden y fallas. El gate Linux usa las herramientas reales. La línea base focal de specify dio 21/21 por bash con stderr vacío; aún no existe evidencia del código nuevo.

**Target Platform**: agentes locales supervisados por systemd de sistema, ejecutados como el operador. cgroup v2 soportado para atribución; jerarquía desconocida, permisos insuficientes o lectura inestable producen WARN verificable. Docker conserva comportamiento funcional.

**Project Type**: launcher y plantillas de CLI/helper local.

**Performance Goals**: deadline global monotónico de 60 s desde la entrada al CLI, antes de leer configuración; observación con hasta 25 s y avisos con hasta 30 s desde que termina esa observación. Ambos se limitan por el deadline global de H5, incluido cleanup y margen TERM/KILL; ninguna operación reinicia un plazo ya establecido. Un envío como máximo por evaluación; curl 5 s conexión/15 s total y límite externo de 20 s, siempre recortados por el remanente. Reintento del mismo aviso solo después de 1800 s contabilizados. N31 valida el CLI completo con reloj controlado; el objetivo <=60 s se limita a fallas acotables de procesos de usuario, no almacenamiento/kernel bloqueados fuera de su control.

**Constraints**: ningún login/modelo/reparación automática; configuración de avisos y códigos 0/1/2 preservados; sin nuevas capacidades, EnvironmentFile o mirrors Docker; no dos BATS simultáneos en el mismo worktree; cambios de comportamiento test-first; sin commit, push, CI manual, servicio vivo o despliegue en esta fase.

**Scale/Scope**: un workspace por agente; hasta 1024 candidatos de proceso por observación, con deadline y salida unknown si se excede el límite. Un solo aviso pendiente vigente y un episodio de notificación abierto por workspace. VERSION prevista 0.32.0→0.33.0, a verificar de nuevo al implementar/rebasar.

## Constitution Check

*GATE: evaluación previa a Phase 0 y repetida tras Phase 1. PASS aquí significa diseño conforme, no gates de ejecución aprobados.*

| Principio / gate | Evaluación previa | Revisión posterior al diseño |
| --- | --- | --- |
| I. Fuente única y regenerate | Los dos artefactos locales se derivan de plantillas en la rama local existente; no se editan generados | PASS: prueba de dos regeneraciones y source guards; sin nueva configuración duplicada |
| II. Privilegios | No se toca imagen, compose, capabilities ni ejecución del agente Docker | PASS: el sudo del gate solo administra fixtures en VM desechable; el healthcheck de prueba corre sin root |
| III. Test-first y host | Pruebas sintéticas host en ambos bash y casos RED antes de cambiar cada comportamiento | PASS: gate real separado; sin sudo, servicios o Docker en `bats tests/`; shellcheck de scripts y renders |
| IV. Idempotencia y degradación | Se conserva el veredicto aun si falla el registro, lock o envío | PASS: suspensión de avisos sin fallback unlocked; reserva durable antes de red; fallas explícitas, sin depender de errexit |
| V. Estado durable | Registro y lock bajo .state, sin secretos ni datos crudos | PASS: lock estable, temporal único, sync archivo/directorio y validación cerrada; no cambia backup ni restore |
| VI. Dependencias y versión | No Python/SQLite nuevos de producción; uso de herramientas Linux | PASS: versión documentada, nuevo job con etiqueta explícita y yq single-sourced; versiones efectivas registradas |
| Regenerate / documentación | UI y política deben sobrevivir regenerate y quedar documentadas | PASS: contracts, quickstart y cambios previstos de docs/VERSION/CHANGELOG |
| Gate Linux pre-merge | No basta la simulación del host | PASS de diseño: integración real obligatoria FR-023/SC-009; todavía no ejecutada |

No hay violaciones nuevas que requieran enmienda constitucional. La excepción local del Principio II pertenece a 011 y no se amplía. Una alteración futura de privileges o del alcance Docker obliga a rehacer este chequeo.

## Project Structure

### Documentation (this feature)

```text
specs/047-local-healthcheck/
├── spec.md
├── intake.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── health-verdict.md
│   ├── notice-state.md
│   └── validation.md
├── checklists/requirements.md
└── tasks.md                    # fase posterior; no creado por plan
```

### Source Code (repository root)

Archivos previstos para implementación; esta fase no los modifica:

```text
modules/local-healthcheck.sh.tpl             # CLI y coordinación
modules/local-healthcheck-lib.sh.tpl         # nueva biblioteca pura, render local
setup.sh                                    # un render adicional solo local
.github/workflows/test.yml                   # job Linux + pin yq único
.github/scripts/local-healthcheck-integration.sh
tests/local-healthcheck.bats                 # fixtures/exigencias previas actualizadas
tests/local-healthcheck-auth.bats            # auth y journal
tests/local-healthcheck-processes.bats       # proc/cgroup/socket e identidad
tests/local-healthcheck-notices.bats         # transiciones/commit/clock/concurrencia
tests/helper-local-healthcheck.bash
tests/fixtures/local-healthcheck/            # stubs y fixtures sintéticos/gate
tests/sigpipe-boot-paths.bats                 # ejecutar clasificador real
tests/local-render.bats                      # par CLI/biblioteca, unidad preservada
tests/regenerate.bats                        # render local y ausencia en Docker
tests/ci-workflows.bats                      # guardias del job y comandos shell
VERSION / CHANGELOG.md
README.md / docs/getting-started.md / docs/architecture.md
docs/adding-a-notifier.md                    # contrato local separado del heartbeat
CLAUDE.md                                   # actualización manual, sin hooks destructivos
```

**Structure Decision**: la biblioteca vive como plantilla local, no en un árbol compartido con código horneado. El setup la emite junto al CLI como `scripts/local/agent-healthcheck-lib.sh`; la unidad conserva User, ExecStart y SuccessExitStatus. Se conservan su servicio y timer sin nuevos privilegios ni frecuencia. Los fixtures de gate se ejecutan por script explícito, fuera del descubrimiento BATS estándar.

## Phase 0: Outline & Research

Completada por diseño en [research.md](research.md): forma de OAuth, clasificación de journal, atribución de sockets, persistencia, máquina de avisos, tiempo/reintentos, gate Linux y compatibilidad. Las fuentes oficiales resuelven las interfaces; no sustituyen las mediciones del gate futuro.

No quedan decisiones técnicas bloqueantes sin resolver. Se mantiene el límite conocido de entrega incierta cuando la respuesta de Telegram o su persistencia no se completa.

## Phase 1: Design & Contracts

- [data-model.md](data-model.md): observación, episodio, versiones, pendiente y transiciones.
- [contracts/health-verdict.md](contracts/health-verdict.md): observación y salida 0/1/2.
- [contracts/notice-state.md](contracts/notice-state.md): persistencia, exclusión, entrega, tiempo y privacidad.
- [contracts/validation.md](contracts/validation.md): oráculos, gate Linux y evidencia de aceptación.
- [quickstart.md](quickstart.md): guía de validación de la implementación futura, sin cuerpos de código completos.

## Secuencia prevista, sin generar tareas

1. Fijar la base completa y los fixtures herméticos; comprobar que el RED corresponde al defecto, no a una dependencia ausente.
2. Crear la biblioteca/render local y actualizar los helpers de tests sin perder los guardias 021 y SIGPIPE.
3. Implementar diagnóstico de login/journal y pertenencia real con sus casos RED/GREEN.
4. Implementar reducer/registro, concurrencia y entrega, con fallas de commit/red y reloj inyectadas antes del arreglo.
5. Implementar el gate Linux y su job; registrar el UID real y las evidencias de kernel/systemd, sin mocks de pertenencia.
6. Revisar de forma independiente el diff y mutaciones; cerrar hallazgos antes de congelar el árbol.
7. Gate host completo en ambos bash, shellcheck, renders/Docker funcional y gate Linux pre-merge. Registrar huellas, conteos efectivos y duraciones.
8. VERSION, docs y publicación mediante sus compuertas. El merge y el despliegue siguen siendo del operador.

Los escenarios de aceptación del contrato no fijan todavía un número físico de tests nuevos. tasks deberá asignar cada caso a un test y calcular el esperado sobre la línea base medida, preservando el recuento de saltadas por motivo.

## Complexity Tracking

Vacío: ninguna violación nueva. JSON y funciones de shell mantienen las dependencias actuales. La separación CLI/biblioteca y el fixture Linux son necesarios para probar la composición que no cubre una simulación.

## Riesgos y cierre

- Un ack remoto sin commit durable puede duplicarse al reintentar; se conserva como entrega incierta.
- Permisos proc, cgroup distinto o carga superior al presupuesto producen WARN de verificación incompleta, no un falso OK.
- La etiqueta de runner puede actualizarse dentro de 24.04: evidencia de versiones obligatoria; prerequisitos ausentes hacen fallar el gate.
- La integración Linux aún no fue medida. No proponer merge con solo los BATS ni atribuir un resultado real a este diseño.
- Este comando termina en Phase 1: no crea tasks.md ni implementación, no invoca la fase siguiente y no publica Git.
