# Protocolo de evidencia y compuertas

## 1. Estados que no deben confundirse

- **Diseño**: este plan y sus contratos. No acredita el fix.
- **Host**: ROJO/VERDE, controles negativos y mutaciones en bash 3.2 y 5.x.
- **Docker inducido**: ejecución del cuerpo real con orden de setup controlado.
- **Docker normal**: escenario corregido sin wrapper ni gates.
- **CI**: workflow e2e manual verde en Linux amd64, sobre el commit corregido, antes del PR.

La publicación de la rama y el dispatch requieren su autorización cuando se alcance esa compuerta. La elección de evidencia en clarify no ejecuta esas operaciones. Cada fase de Spec Kit se inicia por separado.

## 2. Herramientas de reproducción propuestas

Se implementarán `specs/050-e2e-qmd-boot-race/tools/reproduce.py` y `tools/start-services-gate.sh`. Interfaz nueva de la primera, todavía no disponible en la fase de plan:

```text
python3 specs/050-e2e-qmd-boot-race/tools/reproduce.py \
  --baseline a45beaefaa68da17ce16d956351337bd5ce3b9d5 \
  --candidate-root <absolute-repository-path> \
  --output-dir <absolute-evidence-directory>
```

El comando ejecutará en serie las cuatro filas de la matriz y generará TAP, logs y un resumen por fila. El directorio de salida será nuevo o vacío y quedará fuera del checkout; la herramienta no acepta evidencia de una corrida previa. Retorna 0 solo cuando las cuatro filas producen su resultado **esperado**; un control-gate vencido o un rojo por otra causa retorna no cero y se clasifica como arnés/infraestructura, no como reproducción válida.

La herramienta obtiene la base mediante `git archive`, sin worktree ni checkout de la rama activa. Crea snapshots temporales de base y candidato, superponiendo únicamente los archivos de prueba autorizados del working tree actual. Verifica que el runtime del candidato sea idéntico a la base; registra hashes de los tests probados y del supervisor original. No copia `AGENTS.md` sin seguimiento, el vault personal, `.git`, `.state` ni archivos de credenciales del checkout.

El coordinador y el wrapper se congelan al iniciar: el hash registrado y las copias de cada fila usan esos mismos bytes. Antes de copiar se rechaza una edición concurrente de cualquiera de las dos fuentes, para no aceptar evidencia de herramientas mezcladas. La revisión de implementación del 24-11-2026 y su control ROJO/VERDE están en el Registro de `tasks.md`.

Las únicas diferencias adicionales de las copias son instrumentación de gates y aislamiento común del cron/vault en el fixture. No se reescriben las aserciones originales para lograr el resultado esperado. El original y el candidato usan el mismo aislamiento; las diferencias de setup y aserciones del candidato son las que se están evaluando.

## 3. Cableado y privilegios

El entrypoint original ejecuta el supervisor como `agent`. Un override exclusivo del contenedor de reproducción monta el wrapper de solo lectura sobre `/opt/agent-admin/scripts/start_services.sh` y deja una copia byte-idéntica del supervisor original en `/workspace/.e2e/050/start_services.original.sh`.

El wrapper sourcea esa copia sin ejecutar su `main`, renombra la función real de setup a un nombre propio del arnés, instala la envoltura y llama al `main` original. No se cambia `docker/` en el repositorio, no se ejecuta como root, no se añaden capacidades ni se cambia `_run_watchdog`. El smoke del arnés debe verificar usuario `agent`, hash original, llegada al gate y ejecución del boot original antes de aceptar la matriz.

Cada caso usa un `COMPOSE_PROJECT_NAME` único, generado para esa corrida y propagado a todas las llamadas Compose del Bats, su teardown y el coordinador. Un snapshot distinto no basta: el fixture conserva el nombre de contenedor fijo `qmd-migrate-e2e`. Antes del up, el preflight rechaza ese nombre si ya está ocupado, sin reutilizar, detener ni borrar el contenedor existente. Si aparece una colisión después del preflight, se invalida el caso y la limpieza sigue limitada al proyecto propio.

Tras crear recursos, el smoke verifica que sus labels `com.docker.compose.project` coincidan con el proyecto asignado. El registro guarda proyecto, nombre/ID de contenedor y labels observadas; la limpieza solo actúa sobre esa identidad y nunca intenta resolver una colisión borrando recursos ajenos. El control sin Docker simula un recurso ajeno y exige rechazo antes de up, sin llamadas de down sobre él.

Un mero `command:` de Compose no sirve porque el entrypoint termina en un exec fijo. Detener el motor QMD tampoco acredita el fast path del candidato, que no llama al motor.

## 4. Órdenes controlados

**Early:** la llamada real de setup termina y el coordinador observa `returned` con retorno 0 antes de ejecutar la inspección inicial del test. En base se exige además la evidencia `setup: complete`; en candidato, `setup: already done` y ausencia de replace. El marcador presembrado por sí solo no acredita el orden.

**Late:** el wrapper anuncia `entered` y queda esperando antes de llamar a setup real. El coordinador acredita que no hay `returned`, deja ejecutar la inspección original y, si fue aceptada, escribe `release`. Después exige observar `returned` con retorno 0 y la evidencia de setup correspondiente a base/candidato antes de permitir el primer tick. El orden acreditado es inspección -> release -> returned -> tick 1; no basta con escribir release. Cualquier contención restante se resuelve con el ayudante existente.

El control del coordinador que recibe `release` pero nunca produce `returned` debe invalidar D2/D4 por vencimiento, incluso si el reindex simulado podría completar la migración. Ni el teardown ni un setup terminado por la limpieza sustituyen ese retorno real. Se conserva el límite de 90 s por señal.

Las inserciones del coordinador se realizan en anclas únicas de las copias de prueba; ancla ausente o duplicada es error. Cada caso usa gates y workspace nuevos. Gates y evidencia están fuera del vault para no disparar al watcher.

Las esperas nuevas de gates tienen un límite de 90 s por señal y muestran qué señal faltó; no se aumenta ningún timeout del e2e normal. El runner limita además cada caso, excluida la construcción de imagen, a 1.800 s y guarda la salida en archivo para que un huérfano no retenga una tubería. Al terminar o fallar, libera gates, termina procesos y retira solo el proyecto Compose propio. No borra imágenes ni cachés compartidos.

## 5. Matriz local exigida

| Fila | Fuente | Orden | Resultado esperado |
| --- | --- | --- | --- |
| D1 | Base, fixture sin marcador de setup | Early | Rojo en bash 5.x en la aserción original de `SKIPPED`; setup completado y gates acreditados |
| D2 | Base | Late | Verde; precondición original antes del setup y `returned` válido tras release, antes de tick 1 |
| D3 | Candidato, setup presembrado | Early | Verde; migración pendiente antes de tick 1, un replace e idempotencia |
| D4 | Candidato | Late | Verde con las comprobaciones de D3 y `returned` válido tras release, antes de tick 1 |

El host de Bats para la matriz usa bash 5.x, donde la aserción original está activa. El ocultamiento de las dos aserciones originales bajo 3.2 queda demostrado por las sondas y el oráculo host. No se exige falsamente que el e2e anterior caiga en ambos bash.

Si D1 falla en otra línea, o falta una señal de gate, la fila es inconcluyente. D2/D4 sin retorno real tras release no son verdes válidos aunque sus ticks pasen. Si D2 no pasa por otra causa, se corrige el arnés o se clasifica la infraestructura y se repite; no se anota como evidencia de #117. No se muta producto ni se atribuye una frecuencia de CI a esta matriz inducida.

## 6. Regresión y CI

1. ROJO del oráculo nuevo contra las secciones anteriores donde corresponda; controles del propio arnés sanos.
2. VERDE del oráculo corregido y catálogo de mutaciones en ambos bash; B2 y las 26 pruebas de locks conservadas.
3. Matriz D1-D4 y corrida local del e2e corregido sin inyección; guardar hashes.
4. Revisión independiente de solo lectura antes del gate completo. Ejecutar la suite host completa secuencialmente en ambos bash y shellcheck; medir la base y comparar tests/skips por motivo. No ejecutar simultáneamente ambas suites.
5. Congelar el código probado; con autorización, commits, push y dispatch normal del workflow existente. No hay ensayo de alertas (`alert_trial` queda en false), ni cambios de workflow o secretos nuevos.
6. Exigir conclusión verde del workflow y del job e2e, arquitectura Linux amd64 registrada, resumen sin fallos y línea `ok` de la prueba por su título, sin `# skip`. Una conclusión verde global que no ejecutó ese test no satisface el gate. Registrar commit, run ID y URL antes de abrir PR.

La herramienta inducida no corre en CI. El workflow manual ejecuta la suite normal existente, incluida la prueba modificada. Los checks habituales del PR siguen siendo necesarios, pero no sustituyen este dispatch. Si el código cambia después de la evidencia, revalidar lo afectado y asegurar que el commit publicado contiene exactamente el código probado.

## 7. Alcance de publicación

Durante plan solo se generan artefactos de diseño. Las herramientas, el código de pruebas y `tasks.md` se crean en sus fases. PR y merge conservan sus compuertas; no se modifica ni reinicia ningún agente desplegado para este fix de pruebas.
