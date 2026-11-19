# Validación de 047

**Date**: 2026-11-17
**Scope**: #111, local healthcheck. Diseño en [plan.md](plan.md), [veredicto](contracts/health-verdict.md), [avisos](contracts/notice-state.md) y [validación](contracts/validation.md).

Los tests, helper y script Linux están implementados en el worktree047. Esta guía conserva el
procedimiento; los resultados efectivamente ejecutados y la fuente validada están en el Registro
de [tasks.md](tasks.md). La integración Linux real sigue pendiente de CI antes del merge; no se
confunde con los oráculos del host ni con la prueba del receptor en loopback del M4.
La evidencia histórica de specify está en intake.md.

## 1. Checkout, autoridad y herramientas

Trabajar en el worktree 047 y comprobar rama/estado antes de ejecutar. No usar el selector de la copia principal, que continúa apuntando a 046. Conservar el trabajo y las notas de aquel worktree.

```bash
cd /Users/rodrigo-hinojosa/Documents/Cencosud/Claude/Agents/agentic-pod-launcher/.claude/worktrees/047-local-healthcheck
pwd
git branch --show-current
git status --short
```

Esperado: rama `047-local-healthcheck`; cambios solo de esta feature. Verificar bash 5.x, /bin/bash 3.2, BATS, yq/jq y shellcheck. El host no necesita Docker ni systemd para los tests sintéticos. El arnés proporciona dobles estrictos de timeout/sync en su PATH privado y bloqueo efectivo; no depende de coreutils instalado en el Mac. N30/N31 verifican señales/recolección, orden de flush y fallas; el gate Linux utiliza herramientas reales. No se leen credenciales reales.

## 2. Línea base y RED

En una copia aislada de la base, medir la suite completa sin editar sus fuentes en paralelo. Conservar stdout, stderr, versión efectiva de bash y huellas. La base local de referencia tenía VERSION 0.32.0; verificar cualquier cambio remoto antes de un rebase/bump.

Implementar primero los casos que fallen por el comportamiento de #111: acceso vencido renovable, conexión en hijo y avisos repetidos. Confirmar el motivo del RED; no aceptar un fallo por falta de fixture, lock o biblioteca como prueba del defecto. Después ejecutar cada arreglo con sus pruebas.

## 3. Oráculos focales en secuencia

Desde el árbol ya implementado, una ejecución a la vez:

```bash
PATH="/opt/homebrew/bin:$PATH" bats --tap tests/local-healthcheck*.bats tests/sigpipe-boot-paths.bats tests/local-render.bats
PATH="/bin:$PATH" bats --tap tests/local-healthcheck*.bats tests/sigpipe-boot-paths.bats tests/local-render.bats
```

Esperado: los dos bash efectivos impresos y todos los casos del [contrato V2](contracts/validation.md) ejecutados, sin fallas ni nuevas saltadas. El esperado numérico lo fija tasks sobre la línea base y el inventario real de tests, no el número de filas de diseño.

Comprobar especialmente:

- Login completo, raíz mcpOAuth distractora y límites de siete días/vencimiento.
- Terminal y acceso renovable en líneas distintas y ambos órdenes; journal grande por archivo, sin SIGPIPE ni E2BIG.
- Procesos principal/hijo/nieto y ajenos, FD/proc fijado, restart y permisos.
- Cero envíos si el precommit no se acredita; confirmación exige API y commit.
- Reintentos a 0/30/60 minutos con reloj simulado, no esperas reales; reserva después de restart y retroceso seguido de corrección del reloj, sin contabilizar dos veces el mismo intervalo.
- Recuperación solo tras algún aviso confirmado; D→W→D y deuda de recuperación tras una nueva alarma.
- Lock real del arnés, dos procesos concurrentes, deadline y KILL; centinelas ausentes de argv, env del transporte, salida y registro.
- N31 compone el CLI completo desde configuración hasta cleanup contra el global de 60 s, con observación de hasta 25 s y avisos de hasta 30 s después de observar, siempre limitados por el global; ningún cambio de fase ni margen TERM/KILL renueva el plazo.

No simular un payload grande mediante una variable exportada. Si falla algo, conservar evidencia y diagnosticar antes de modificar código.

## 4. Render, estáticas y regresión

Renderizar en un workspace temporal sintético, install_service:false y CLI ficticio. No regenerar ni instalar sobre un agente vivo. Confirmar el par de archivos locales, dos regeneraciones equivalentes, sus source guards y los invariantes de la unidad/timer. Aplicar shellcheck al CLI y biblioteca renderizados además del comando exacto del CI.

Comparar los artefactos funcionales Docker de base/candidato con la misma configuración, separando solo la identificación de versión. No se espera cambio de compose, código horneado o privilegios; una diferencia distinta obliga a revisar el alcance.

Ejecutar el catálogo de mutaciones en copias aisladas, en los dos bash y sin dos BATS simultáneos. Después, gate host completo sobre el árbol congelado, también secuencial. Registrar plan TAP completo, conteos y saltadas por motivo, stderr y duración; no declarar 2104 como esperado final si se añadieron o reemplazaron pruebas.

## 5. Gate Linux en CI, antes del merge

El PR debe ejecutar automáticamente el job `local-healthcheck-integration` en ubuntu-24.04. Detalles de preparación, diez escenarios y limpieza: [V4/V5](contracts/validation.md). El job tiene diez minutos y falla si faltan prerequisitos; no puede producir un verde de saltadas.

El gate crea únicamente servicios transitorios y red de prueba con datos ficticios. El healthcheck corre como UID no root y usa proc, systemd y ss reales. La preparación privilegiada pertenece solo a la VM desechable; no usa ferrari, perfiles, tokens o bots de la flota. No lanzar un workflow manual por esta guía sin su compuerta.

Tras publicar con autorización, las consultas siguientes son de lectura:

```bash
gh run list --repo rodrigo-hinojosa-labs/agentic-pod-launcher --workflow test.yml --branch 047-local-healthcheck --json databaseId,headSha,status,conclusion,url
```

Verificar la cabeza, el job y evidencia completa de L01 a L10. Esperado:

```text
047 integration summary: total=10 executed=10 skipped=0 failed=0
```

Comprobar UID no root, versiones efectivas, cgroups/inodes/PIDs ficticios y limpieza confirmada. El resumen solo no sustituye esos registros. No atribuir a PID reutilizado real lo que solo fue un restart; ese caso tiene un oráculo sintético además del handle proc documentado.

## 6. Cierre

Conservar revisión independiente, mutaciones, renders, gates y fuente exacta en el Registro de tasks. El nuevo check Linux y los checks previos deben estar verdes sobre la cabeza que se propone mergear. Confirmación de Telegram significa recepción de API más registro durable, no lectura humana; respuesta/commit incierto puede duplicar un mensaje remoto al reintentar.

El merge lo hace el operador. Desplegar en un agente local real y observarlo es posterior y requiere su compuerta; no se exige una espera previa de 24 horas en la flota. No mezclar ese despliegue con T083 a T085 de 046.
