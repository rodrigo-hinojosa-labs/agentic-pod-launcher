# Implementation Plan: Un repositorio privado por agente para su trabajo y su respaldo completo

**Branch**: `046-agent-backup-repo` | **Date**: 2026-11-13, corregido el 14-11-2026 tras el análisis de consistencia | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/046-agent-backup-repo/spec.md`

## Summary

Hoy los respaldos del launcher dependen del fork, y ningún agente de la flota tiene fork, así que nada se respalda. Además, el contenedor no tiene cómo autenticarse para empujar, y la persona, las memorias y el historial no entran en ninguna unidad.

La feature agrega a `agent.yml` la asociación opcional de un repositorio privado por agente, y construye sobre ella cinco piezas:

1. **Una regla de destino única**: el repositorio asociado si existe; si no, el fork; si no, nada. Con fork o sin destino, el comportamiento es el de hoy.
2. **Una vía de credenciales**: un askpass horneado que lee `GITHUB_PAT` del entorno. El valor no pasa por argumentos, URL ni configuración de git (medido).
3. **Cobertura completa**: `identity` pasa a cifrar el archivo de secretos real, que hoy no llega al respaldo; `config` suma la persona, el `CLAUDE.md` y la configuración de proyecto de Claude; nacen dos unidades, `memory` e `history`; y el operador puede declarar rutas adicionales. Lo que puede llevar secretos o datos sensibles viaja cifrado, en un almacén por bloques que no vuelve a subir lo que ya está. Cada almacén tiene su propia llave de datos, que viaja cifrada para la llave del operador.
4. **Restauración** de las cinco unidades desde el repositorio, con la llave del operador.
5. **Superficie**: una pregunta en el wizard, una sección en el contexto del agente, un clon de trabajo con su credencial y un comando de estado que alimenta el diagnóstico.

Además, el camino nuevo no falla abierto ni se atasca: la privacidad que no se pudo comprobar no cuenta como privada, cada unidad tiene su candado y sus topes, y el supervisor no insiste con un contenido que acaba de fallar.

El Principio V de la constitución fija tres ramas de respaldo, así que la feature lo enmienda de forma explícita (1.0.1 a 1.1.0) antes de tocar código.

## Technical Context

**Language/Version**: bash 3.2 y 5.x en el host; `sh` POSIX y bash en la imagen; Python 3.9 a 3.14, solo con la biblioteca estándar, para la herramienta del almacén.

**Primary Dependencies**: `git`, `age`, `age-keygen`, `python3`, `gzip`, `flock`, `timeout`, `yq` y `jq`, todos ya presentes en la imagen (medido: git 2.54.0, age 1.3.1 y 1.3.2, Python 3.14.10 con SQLite 3.53.4; M6 y M20 de [research.md](research.md)). No se agrega ningún paquete.

**Storage**: el repositorio privado del agente en GitHub, con ramas huérfanas `backup/*`; archivos de estado JSON en `scripts/heartbeat/`; cachés de clon bajo `.state/.cache/`.

**Testing**: `bats` en el host, en los dos bash, con un servidor git local con autenticación como doble de prueba; `DOCKER_E2E=1` para el contenedor real; y un gate de integración por consola en Docker del M4 contra un repositorio privado real antes del merge (sustitución de linus aprobada el 16-11-2026, `contracts/local-pilot.md`).

**Alcance del piloto aprobado**: contenido de prueba, primitivas horneadas y GitHub reales, sin cron, supervisor ni canales conectados. Se comprueban las cinco unidades, idempotencia, ramas de trabajo y recuperación comparada. M5 fue autorizado por separado y pasó el 17-11-2026 con tres invocaciones de un turno; el resultado y sus límites están en `pilot-m4-results.md`. El contenido vivo, los inventarios, los archivos en claro y la salud de linus/donna/cbum se validan al desplegar; linus pasa primero, con reversión disponible, antes de ampliar a la flota. No cambia el contrato de datos ni el código del producto.

**Target Platform**: agentes en modo docker (Alpine, aarch64 en ferrari y amd64 en la CI). El modo local no cambia.

**Project Type**: herramienta de línea de comandos en bash que genera workspaces; código horneado en una imagen de contenedor.

**Performance Goals**: un ciclo sin cambios hace una sola consulta autenticada de cabezas, sin clonar ni empujar; un ciclo diario normal del historial sube como máximo el último bloque de 1 MiB y lo nuevo del día.

**Constraints**:

- ninguna unidad bloquea ni reinicia al supervisor; con credencial inválida o sin red, su comprobación previa termina en 2 minutos como máximo, y un empuje que se cuelga se corta en su tope (SC-006);
- dos corridas de una misma unidad nunca comparten caché: cada unidad tiene su candado;
- con un repositorio asociado, el git de los respaldos ignora la configuración global y la de sistema;
- la parte privada de una llave de datos nunca queda en claro en el disco del agente;
- ningún archivo del repositorio supera 1 MiB en las unidades cifradas, así que el límite de 100 MiB del servicio no aplica;
- nada temporal va a `/tmp`, que es un tmpfs de 100 MB;
- con fork o sin destino, los mensajes, los códigos de salida, los archivos de estado, el crontab y el `CLAUDE.md` son idénticos a los de `main`.

**Scale/Scope**: cuatro agentes (donna, linus, cbum y el futuro agente médico). El más grande hoy es donna: 68,6 MiB de historial en un archivo, 32,6 MB en la carpeta de su sesión y una base de 13,9 MB. Código nuevo estimado: una herramienta en Python, cuatro librerías de shell, dos scripts de credenciales, cambios en `heartbeatctl`, `start_services.sh`, `setup.sh` y `agentctl`, y 124 pruebas del host más 8 de extremo a extremo.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principio | Estado | Cómo se cumple |
| --- | --- | --- |
| I. `agent.yml` es la fuente única | Cumple | La asociación, la marca de datos sensibles y los interruptores de las unidades nuevas viven en `agent.yml`. El contexto del agente y el crontab se derivan de ahí, y `--regenerate` completa las claves que falten |
| II. Contenedor de mínimo privilegio | Cumple | No hay capacidades, mounts ni ejecuciones como root nuevas. Todo corre como `agent`. Los scripts de credenciales son de root, de solo lectura, y solo leen una variable que el contenedor ya tiene |
| III. Pruebas primero, en el host | Cumple | Seis suites nuevas de bats que corren sin Docker, con el empuje autenticado ejercido contra un servidor local. La prueba de extremo a extremo va con `DOCKER_E2E=1` |
| IV. Idempotente y con falla silenciosa | Cumple | Cada unidad decide por hash, tiene tiempos máximos y nunca termina al supervisor. Los rechazos por política salen con 0 y quedan visibles en el estado |
| V. El workspace es el agente; respaldos en tres ramas | **Requiere enmienda** | La feature agrega dos unidades y un conjunto cerrado de piezas compartidas que no hacen commits: destino, credencial, privacidad, marca, candado, registro del intento y almacén. Ver Complexity Tracking |
| VI. Dependencias fijadas | Cumple | No se agregan paquetes ni versiones. `VERSION` pasa de 0.31.0 a 0.32.0, con su entrada en el CHANGELOG |

**Revisión posterior al diseño (13-11-2026)**: el diseño de las fases 0 y 1 no agrega ninguna violación. La única sigue siendo la del Principio V, y queda resuelta con la enmienda de [contracts/constitution-amendment.md](contracts/constitution-amendment.md), que es la primera tarea de implementación.

**Revisión al generar las tareas (13-11-2026)**: las mediciones M13 a M18 corrigieron el diseño (decisiones D19 a D26 de [research.md](research.md)). Ninguna agrega una violación: no hay capacidades, mounts ni ramas nuevas, y las rutas adicionales viajan dentro de la unidad `memory`.

**Revisión tras el análisis (14-11-2026)**: el análisis de consistencia encontró dos defectos en el texto de la enmienda, que son los que importan para este gate:

- decía que las unidades comparten "exactamente dos cosas", y el diseño comparte siete piezas;
- su regla de cifrado era más amplia que lo que el diseño cifra, así que un agente sin marcar la habría violado con su vault en claro.

Los dos se corrigieron en [contracts/constitution-amendment.md](contracts/constitution-amendment.md): la enmienda enumera ahora lo que se puede compartir y lo que tiene que viajar cifrado. Las decisiones D27 a D36 no agregan capacidades, mounts, ramas ni paquetes.

## Project Structure

### Documentation (this feature)

```text
specs/046-agent-backup-repo/
├── plan.md              # Este archivo
├── research.md          # Mediciones M1 a M21 y decisiones D1 a D36
├── data-model.md        # Claves de agent.yml, estados, ramas y almacén
├── quickstart.md        # Cómo validar, del host al despliegue
├── contracts/
│   ├── destination-and-credential.md
│   ├── backup-units.md
│   ├── block-store.md
│   ├── restore.md
│   ├── agent-surface.md
│   ├── constitution-amendment.md
│   └── evidence.md
├── checklists/
│   └── requirements.md
├── tools/
│   └── sc007_sim.py     # El simulador de SC-007, versionado
└── tasks.md             # Lo genera /speckit-tasks
```

### Source Code (repository root)

```text
.specify/memory/constitution.md          # enmienda 1.0.1 -> 1.1.0

.github/workflows/docker-e2e.yml         # un paso que instala age en el nightly

docker/
├── Dockerfile                           # una línea COPY por cada archivo nuevo
└── scripts/
    ├── backup_store.py                  # NUEVO: almacén por bloques
    ├── git-askpass-agent.sh                # NUEVO: askpass de los respaldos
    ├── git-credential-agent.sh             # NUEVO: ayudante del clon de trabajo
    ├── heartbeatctl                     # regla de destino, dos comandos nuevos, backup-status, cron
    ├── start_services.sh                # destino, plazo y tope en el disparador de identidad; clon de trabajo
    └── lib/
        ├── backup_dest.sh               # NUEVO: destino, credencial, privacidad, marca, candado, registro
        ├── agent_repo.sh                # NUEVO: el clon de trabajo
        ├── backup_memory.sh             # NUEVO: auto-memoria, claude-mem y rutas adicionales
        ├── backup_history.sh            # NUEVO
        ├── backup_identity.sh           # camino repo con su envoltorio de git; marca; secretos de la raíz
        └── backup_config.sh             # lo mismo, más el contenido ampliado y su forma cifrada

scripts/
├── agentctl                             # diagnóstico de respaldos
└── lib/
    ├── backup_vault.sh                  # camino repo con su envoltorio de git; marca; modo cifrado
    ├── wizard-validators.sh             # validate_backup_repo_url
    └── schema.sh                        # claves nuevas

modules/
├── claude-md.tpl                        # sección de respaldos y sección del repositorio
├── env-example.tpl                      # GITHUB_PAT también con repositorio
├── next-steps.en.tpl
└── next-steps.es.tpl

setup.sh                                 # wizard, heredoc, backfill, avisos, llave pública, restauración, nuke
.gitignore                               # /agent-repo/

tests/
├── backup-dest.bats                     # NUEVO
├── backup-store.bats                    # NUEVO
├── backup-repo-units.bats               # NUEVO
├── backup-repo-restore.bats             # NUEVO
├── agent-repo-surface.bats              # NUEVO
├── backup-status.bats                   # NUEVO
├── docker-e2e-backup-repo.bats          # NUEVO
├── helper-backup-repo.bash              # NUEVO: el arnés de las seis suites
├── fixtures/backup-repo/                # NUEVO: el servidor de prueba, los dorados y los dobles de timeout y flock
├── helper.bash                          # una respuesta más en wizard_answers
├── e2e-smoke.bats                       # una respuesta más
├── schema.bats                          # marcadores derivados y la clave backup
├── quickstart-doc.bats                  # el validador y el bloque nuevos
└── fixtures/sample-agent*.yml           # claves nuevas

docs/ (incluidos los dos quickstart), .claude/commands/quickstart.md,
README.md, CHANGELOG.md, VERSION, CLAUDE.md
```

**Structure Decision**: se mantiene la estructura del repositorio. Lo que corre dentro del contenedor va bajo `docker/` y exige la prueba de extremo a extremo. La librería del vault sigue en `scripts/lib/`, porque la comparte el modo local, y su camino cifrado solo se activa desde `heartbeatctl`. Las librerías nuevas no se espejan a `scripts/lib/`, porque el modo local queda fuera de alcance (FR-019).

## Orden de implementación (para `/speckit-tasks`)

El orden sigue las dependencias entre archivos, no solo la prioridad de las historias.

1. **Preparación**: línea base de la suite en los dos bash, sobre una copia aislada de `origin/main`.
2. **Fundación**:
   - la enmienda de la constitución;
   - las claves de `agent.yml`, el esquema y los fixtures;
   - el servidor de prueba;
   - `backup_dest.sh` y el askpass.
3. **Historia 1**: las tres unidades que ya existen usan la regla de destino, la credencial y la marca, e `identity` cifra el archivo de secretos real. Es el mínimo entregable: con esto, un agente sin fork ya respalda identidad, secretos, vault y configuración.
4. **Historia 2**: la herramienta del almacén; `config` ampliada; `memory`, con las rutas adicionales; `history`; el vault cifrado.
5. **Historia 3**: la restauración de las cinco unidades.
6. **Historia 4**: el wizard, el contexto del agente, el clon de trabajo y su ayudante de credenciales.
7. **Historia 5**: `backup-status` y el diagnóstico.
8. **Pulido**: documentación, CHANGELOG, `VERSION`, mutaciones, revisión independiente y gate completo en los dos bash.
9. **Historia 6**, con compuertas: la prueba de extremo a extremo, el gate en linus, el PR, y después del merge el despliegue.

Cada historia se cierra con sus pruebas en verde en los dos bash antes de empezar la siguiente.

## Complexity Tracking

| Violación | Por qué hace falta | Alternativa más simple, y por qué se descarta |
| --- | --- | --- |
| El Principio V fija tres ramas de respaldo y la feature agrega `backup/memory` y `backup/history` | El operador pidió que el agente sea recuperable por completo, incluidas las memorias y el historial. Esos datos tienen otro tamaño, otra cadencia y otra sensibilidad que los de las tres ramas actuales | Meterlos en `backup/identity`: cada cambio de identidad, que se revisa cada 60 segundos, arrastraría decenas de megabytes. Meterlos en `backup/vault`: mezclaría contenido en claro con contenido siempre cifrado. Se enmienda el principio en vez de forzarlo |
| El Principio V prohíbe fusionar las unidades en una primitiva compartida, y la feature agrega `backup_dest.sh`, que todas llaman | FR-002 exige una sola regla de destino, y la credencial tiene que resolverse igual en todas. Hoy la lectura del destino está repetida en siete lugares | Repetir la regla en cada unidad: cinco copias de una regla con tres casos se desincronizan. La librería queda acotada a destino, credencial, privacidad, marca, candado y registro del intento; no arma árboles, no hace commits y no empuja, y la enmienda enumera esa lista |
| Una herramienta en Python (`backup_store.py`) en un proyecto de bash | Hay que partir archivos binarios en bloques, calcular hashes, comprimir, cifrar, escribir un manifiesto y copiar una base SQLite en uso | Hacerlo en bash: exige `split`, aritmética de rangos y un temporal por bloque, y la copia de SQLite necesita Python igual, porque la imagen no trae el cliente de SQLite. El proyecto ya tiene un precedente horneado en Python, el parchador de Telegram |
| Una llave de datos por almacén, además de la llave del operador | Cifrar directo para la llave del operador dejaba ilegibles los bloques ya subidos cuando esa llave cambiaba, y `age` pide la passphrase de una llave ssh una vez por archivo (M19) | Seguir cifrando directo y volver a cifrar al cambiar la llave: corrige lo primero y deja la passphrase por bloque, más de cien veces en el historial de donna. Lo decidió el operador el 14-11-2026 (D27) |
