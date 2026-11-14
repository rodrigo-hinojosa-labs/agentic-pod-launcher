# Feature Specification: Un repositorio privado por agente para su trabajo y su respaldo completo

**Feature Branch**: `046-agent-backup-repo`

**Created**: 2026-11-13

**Status**: Draft

**Input**: Pedido del operador (13-11-2026). El launcher debe permitir, como configuración opcional y además del fork, asociar a cada agente un repositorio privado propio. En ese repositorio el agente escribe sus features particulares y queda respaldado todo lo necesario para recuperarlo por completo: trabajo, configuración y memorias. Hoy existen dos de esos repositorios, el de donna y el de linus, pero el launcher no los conoce y ningún respaldo llega a ellos. Después del merge hay que actualizar a donna, linus y cbum.

## Contexto

**El pedido.** Cada agente tiene asociado, de forma opcional, un repositorio privado con dos papeles:

1. **Trabajo**: ahí el agente escribe las features que trabaja de forma particular, con spec-kit.
2. **Respaldo**: ahí queda todo lo que hace falta para que el agente sea recuperable por completo.

El fork sigue existiendo como hasta ahora; el repositorio del agente es un concepto aparte.

**Lo que hay en los dos repositorios (medido el 13-11-2026).** `rodrigo-hinojosa/donna-workspace-agent-admin` y `rodrigo-hinojosa/linus-workspace-agent-admin` son privados, no son forks y solo tienen ramas de trabajo:

- **donna**: `main` y `002-registro-costos`, con 451 archivos y 4,3 MB de código, pruebas, specs y skills. Tiene 99 commits, del 20-08 al 11-11-2026, todos con la identidad del operador.
- **linus**: solo `main`, con el bootstrap de spec-kit (32 archivos, 2 commits del 17-08-2026).

Ninguno guarda nada del estado del agente: ni vault, ni persona, ni `agent.yml`, ni memorias. Hoy cumplen el papel de trabajo y no el de respaldo.

**Lo que hay en los agentes (medido en ferrari el 13-11-2026).**

- donna, linus y cbum se crearon sin fork: `scaffold.fork.owner` está vacío, su workspace no tiene ningún remoto de git y no existe ningún archivo de estado de respaldo. Ningún respaldo del launcher empujó nunca nada: los cron de vault y de configuración corren igual, no encuentran destino y dejan una línea en su propio log (2.157 en donna). Su vault se replica por Syncthing.
- La persona vive en `personas/<agente>.md` y no está en ningún repositorio remoto. donna la tiene modificada sin commit en su git local desde agosto; linus no tiene ningún commit local.
- La instrucción "este es tu repositorio" no está en la persona ni en el `CLAUDE.md`: vive en la auto-memoria de Claude de donna y de linus, y en páginas del vault de linus. cbum no tiene ninguna.
- Los clones dentro de los contenedores están atrasados (donna en la rama `master`, con su último commit del 20-08-2026). La sesión no tiene configurada ninguna forma de autenticar git: no hay ayudante de credenciales, ni `gh`, ni llaves ssh. Sí tiene `GITHUB_PAT` en el entorno, que usa el MCP de GitHub.

**Cómo respalda hoy el launcher (leído en código, `main` = `10f22a7`).** Hay tres unidades independientes, cada una en su rama huérfana del fork:

- `backup/identity`: `.claude.json`, `.claude/settings.json`, el `access.json` de Telegram, la configuración de plugins y el archivo de secretos cifrado para una llave pública del operador. Medido el 13-11-2026: en un agente docker la unidad busca el archivo de secretos en el directorio de estado, donde no existe, así que nunca lo cifra.
- `backup/vault`: el markdown del vault.
- `backup/config`: solo `agent.yml`.

Las tres dependen de `scaffold.fork.url`. Sin fork ninguna empuja nada: el watchdog no calcula el hash de la identidad, los cron de vault y de configuración terminan con una línea de "sin destino", y el destinatario del cifrado no se configura porque se obtiene del dueño del fork. La plantilla del `CLAUDE.md` le dice al agente que sin fork no hay respaldos.

**Por qué eso deja a la flota sin respaldo.**

- El template es público, y la flota se creó sin fork porque un fork de un repositorio público no puede ser privado.
- Aunque hubiera un destino privado, el contenedor no tiene cómo autenticarse para empujar. Las librerías de respaldo clonan y empujan una URL https sin credencial y con las preguntas interactivas desactivadas, y ningún componente configura una credencial para git. `GITHUB_FORK_PAT` solo se usa en el host, al crear el fork.
- La prueba de extremo a extremo del respaldo usa un repositorio local montado, así que el empuje autenticado contra GitHub no lo ejerce ninguna prueba.

**Lo que falta para que un agente sea recuperable.**

| Dato | Dónde vive | Tamaño medido | Respaldo hoy |
| --- | --- | --- | --- |
| Configuración (`agent.yml`) | Workspace | Pequeño | Unidad `config`, que no corre sin fork |
| Identidad | `.state/` | Pequeño | Unidad `identity`, que no corre sin fork |
| Secretos del agente, incluido su token de Claude | Archivo de secretos, en la raíz del workspace | Pequeño | Ninguno: la unidad `identity` lo busca en otro lugar |
| Vault | `.state/.vault` | 14 a 51 páginas, hasta 484 KB | Unidad `vault`, que no corre sin fork; Syncthing |
| Persona | `personas/<agente>.md` | 28 a 52 KB | Ninguno |
| Auto-memoria de Claude | `.state/.claude/projects/` | 0 a 4 archivos, hasta 20 KB | Ninguno |
| Base de claude-mem | `.state/.claude-mem/` | 5,8 a 25,5 MB | Ninguno |
| Historial de conversaciones | `.state/.claude/projects/` | Hasta 68,6 MiB en un solo archivo, más 32,6 MB en la carpeta de la sesión (donna) | Ninguno |
| Trabajo del agente | Ramas de trabajo de su repositorio | 4,3 MB en donna | El propio repositorio, cuando se empuja |
| Configuración de proyecto de Claude (skills, comandos, agentes) | `.claude/`, en la raíz del workspace | Pequeño | Ninguno |
| Estado de un overlay o de una feature propia del agente | Rutas que el launcher no conoce | Variable: en donna, sus credenciales de Google y la configuración de su feature de costos | Ninguno |

**Restricciones que el diseño no puede romper.**

- **Constitución, Principio I**: `agent.yml` es la fuente única, y todo cambio sobrevive a `--regenerate`.
- **Principio II**: no se agregan capacidades, mounts ni ejecuciones como root.
- **Principio IV**: el respaldo es idempotente y falla en silencio, sin tumbar al supervisor.
- **Principio V**: los respaldos son tres ramas huérfanas independientes que no se fusionan en una sola primitiva; cada una puede faltar; `.state/` nunca se commitea ni se loguea; y se preserva `setup.sh --restore-from-fork`. Agregar una unidad de respaldo exige enmendar este principio de forma explícita.
- **La persona de CBum** prohíbe subir datos de salud o de entrenamiento a GitHub o a cualquier repositorio, y su decisión D3 descartó otra copia de datos de salud en la nube. El vault y las memorias de CBum, y los del futuro agente médico, contienen datos de salud.

### Estado de cada afirmación

| Afirmación | Estado | Fuente |
| --- | --- | --- |
| Los dos repositorios son privados, no son forks, solo tienen ramas de trabajo y no guardan estado del agente ni nombres de archivo con forma de secreto | Medido (13-11-2026) | Consulta de solo lectura a la API de GitHub: metadatos, ramas, árbol y commits |
| donna: 451 archivos, 4,3 MB y 99 commits del 20-08 al 11-11-2026; linus: 32 archivos y 2 commits del 17-08-2026 | Medido | La misma consulta |
| El trabajo diario del repositorio de donna se hace fuera del contenedor | Inferido: todos los commits llevan la identidad del operador y el clon del contenedor no avanza desde el 20-08-2026 | La misma consulta y el clon en el contenedor |
| donna, linus y cbum no tienen fork, ni remotos de git, ni archivos de estado de respaldo | Medido (ferrari) | `agent.yml`, `git remote` y `scripts/heartbeat/` de cada workspace |
| La persona no está en ningún repositorio remoto; donna la tiene sin commit y linus no tiene commits locales | Medido | `git status` y `git rev-list` de cada workspace |
| La instrucción sobre el repositorio vive en la auto-memoria de donna y de linus, y en el vault de linus | Medido | Búsqueda del nombre del repositorio en persona, `CLAUDE.md`, auto-memoria y vault |
| La sesión del agente no tiene ayudante de credenciales, ni `gh`, ni llaves ssh, y sí tiene `GITHUB_PAT` | Medido (solo presencia, nunca valores) | Sonda de solo lectura en los tres contenedores |
| Tamaños de persona, auto-memoria, claude-mem, historial y vault | Medido | `du` y conteos dentro de cada contenedor |
| Todo el respaldo depende de `scaffold.fork.url` | Leído en código | `docker/scripts/heartbeatctl:778,851,917,957,1003,1043`; `docker/scripts/start_services.sh:1119-1128`; `modules/local-vault-backup.sh.tpl:39` |
| Sin dueño de fork no se configura el destinatario del cifrado | Leído en código | `setup.sh:214-217` |
| Las tres unidades y su contenido; la persona, las memorias y el historial no entran en ninguna | Leído en código | `docker/scripts/lib/backup_identity.sh:33-36,152-155`; `docker/scripts/lib/backup_config.sh:79`; `scripts/lib/backup_vault.sh` |
| El contenedor no tiene vía de credenciales para empujar | Leído en código | `docker/scripts/lib/backup_identity.sh:19-25,109`; sin `credential.helper`, `insteadOf` ni netrc en `docker/`, `scripts/` ni el compose |
| `GITHUB_FORK_PAT` solo se usa en el host | Leído en código | `setup.sh:1544,1599`; `scripts/agentctl:1376` |
| Un respaldo en modo docker contra un repositorio privado de GitHub falla hoy por autenticación | Medido en el plan: sin credencial, `git ls-remote` del repositorio privado termina con 128 | `research.md`, M1 |
| Un askpass que lee la credencial del entorno autentica contra GitHub sin exponerla | Medido en el plan | `research.md`, M2 y M3 |
| Un agente sin fork corre igual los cron de vault y de configuración, que dejan una línea de "sin destino" por corrida | Medido (cbum y donna) | `research.md`, M8 |
| La prueba de extremo a extremo usa un repositorio local montado | Leído en código | `tests/docker-e2e-backup-identity.bats:12-15` |
| Un fork de un repositorio público no puede ser privado | Leído en código | `setup.sh:646-649`, que documenta el error 422 de GitHub |
| La restauración existe y sigue el orden config, identity, vault | Leído en código | `setup.sh:1795`; Principio V de la constitución |
| La plantilla le dice al agente que sin fork no hay respaldos | Leído en código | `modules/claude-md.tpl:234` |
| La persona de CBum prohíbe subir datos de salud a un repositorio | Leído | Ficha de CBum, "Reglas de operación" y decisión D3 |
| GitHub avisa sobre 50 MiB por archivo, bloquea sobre 100 MiB y recomienda repositorios bajo 1 GB | Leído en su documentación (13-11-2026) | `research.md`, M4 |
| Restaurar el historial permite que el agente retome su última conversación | Documentado por Claude Code; sin medir: se mide en el gate previo al merge | `research.md`, M5 y D18 |
| En los tres agentes, el archivo de secretos está en la raíz del workspace y no en el directorio de estado, que es donde lo busca la unidad de identidad | Medido (13-11-2026) y leído en código | `research.md`, M13 |
| Los tres agentes llevan el token de Claude en su archivo de secretos | Medido (solo presencia) | `research.md`, M14 |
| Claude Code reescribe su archivo de configuración vivo hasta una vez por minuto durante una conversación | Medido (donna) | `research.md`, M15 |
| donna guarda estado fuera de las rutas que el launcher conoce: su overlay, con credenciales de Google, y la configuración de una feature propia | Medido (solo nombres y tamaños) | `research.md`, M16 |
| La copia de una base SQLite hecha con la API de respaldo es determinista | Medido en el Mac | `research.md`, M18 |
| `age` pide la passphrase de una llave ssh en cada invocación, y sin terminal no descifra | Medido en el Mac (14-11-2026) | `research.md`, M19 |
| La imagen del agente trae `age-keygen`, `flock` y `timeout` | Medido en los tres agentes (14-11-2026) | `research.md`, M20 |
| `--regenerate` no fija la llave pública; el supervisor reintenta la identidad cada 60 segundos mientras su hash difiera; el nightly no instala `age` | Leído en código (14-11-2026) | `research.md`, M21 |

## Clarifications

### Session 2026-11-13

- Q: ¿Qué debe incluir el respaldo para considerar al agente "100% recuperable"? → A: Todo: configuración, identidad, vault, persona, memorias (auto-memoria y base de claude-mem) y también el historial de conversaciones.
- Q: CBum y el futuro agente médico guardan datos de salud, y la persona de CBum prohíbe subirlos a un repositorio. ¿Cómo se respaldan? → A: Con cifrado por agente. Cada agente se puede marcar como de datos sensibles; en esos, el vault y las memorias se cifran dentro del agente antes de empujar. Donna y Linus siguen en claro. La regla de la persona de CBum se ajusta para permitir el respaldo cifrado.
- Q: ¿Con qué credencial empuja cada agente a su repositorio? → A: Con la credencial amplia que ya tienen (`GITHUB_PAT`), sin crear una por agente.

### Session 2026-11-13 (plan)

Correcciones que salieron de las mediciones del plan. No son respuestas del operador.

- Un agente sin fork sí corre los cron de vault y de configuración, y cada corrida deja una línea en su log. El primer borrador decía "sin ruido". Se corrigieron el contexto, la historia 1, FR-002, FR-018 y SC-004.
- "Memorias en claro" queda acotado a la auto-memoria. La base de claude-mem viaja siempre cifrada, igual que el historial. Se corrigieron la historia 2, FR-009, las entidades y las Assumptions.
- Sin repositorio asociado, el contexto del agente queda idéntico al de hoy, así que SC-004 ya no tiene ninguna excepción. Se corrigió FR-015.

### Session 2026-11-13 (tasks)

Tres decisiones del operador sobre lo que se midió al generar las tareas (`research.md`, M13 a M18 y D19 a D26):

- Q: donna guarda estado que ninguna unidad cubre: su overlay con credenciales de Google, la configuración de su feature de costos y un skill propio. ¿Se incluye en la feature? → A: Sí. `config` suma la configuración de proyecto de Claude, y el operador declara rutas adicionales que viajan cifradas.
- Q: ¿Qué se hace con el login que deja `/login`, que hoy no está en ningún respaldo? → A: Queda fuera. La flota se autentica con el token de su archivo de secretos, que sí viaja cifrado.
- Q: ¿La feature se entrega en un PR o en dos? → A: En un solo PR.

Lo que cambió en el spec por esas mediciones:

- **Defecto corregido**: la unidad de identidad nunca cifró el archivo de secretos de un agente docker, porque lo busca donde no está. Con un repositorio asociado pasa a cifrar el de la raíz del workspace. Se corrigieron el contexto, FR-008 y la historia 3.
- **Hueco corregido**: un ciclo sin cambios no consultaba al destino, así que no habría visto una credencial vencida ni una rama de respaldo borrada. Ahora cada ciclo hace una consulta autenticada. Se corrigió FR-013.
- **Alcance ampliado, aprobado por el operador**: `config` suma la configuración de proyecto de Claude, y el operador puede declarar rutas adicionales que viajan cifradas (FR-025 y FR-026). Sin esto, donna volvería de una restauración sin sus credenciales de Google y sin la configuración de su feature de costos.
- **Promesa acotada**: el agente restaurado no pide iniciar sesión si se autentica con el token de su archivo de secretos, como los tres de la flota. El login de `/login` no viaja en el respaldo. Se corrigieron la historia 3, SC-002 y las Assumptions.
- **Alcance aclarado**: la asociación es solo del modo docker, y en modo local el wizard no hace la pregunta (FR-003 y FR-019).

### Session 2026-11-14 (análisis)

El análisis de consistencia (`/speckit-analyze`) dio 44 hallazgos: 2 críticos, 15 altos, 21 medios y 6 bajos. Se remediaron todos. Cuatro eran decisiones del operador:

- Q: Al cambiar la llave del operador, los bloques ya subidos quedaban cifrados para la llave anterior, y `age` pide la passphrase de una llave ssh una vez por bloque. ¿Cómo se cifra el almacén? → A: Con una llave de datos propia de cada almacén, que viaja cifrada para la llave del operador. Al cambiar la llave del operador, el almacén se cifra de nuevo, completo.
- Q: En un agente de datos sensibles, la persona y el resto de la configuración viajaban en claro. ¿Se cifran? → A: Sí. En un agente sensible solo `agent.yml` viaja en claro.
- Q: `--regenerate` nunca fija la llave pública, así que un agente que ya existe adoptaba la feature sin llave. ¿Quién la fija? → A: El operador, con un paso explícito que muestra la huella de la llave. Regenerar solo avisa que falta.
- Q: SC-002 pedía comparar por hash archivos que se capturan transformados, y comprobar que un agente restaurado no pide iniciar sesión, cuando el ensayo no lo arranca. ¿Qué se mide? → A: Lo que se puede medir: la comparación contra lo respaldado, el archivo de secretos y el emparejamiento restaurados, y que la conversación se retoma. El workspace restaurado no se arranca.

Lo que cambió en el spec por los demás hallazgos:

- **La comprobación de privacidad ya no falla abierta**: una sonda que falla por la red cuenta como "no comprobado", y con eso no se empuja. El destino tiene que ser un repositorio de GitHub (FR-005).
- **El respaldo no se atasca ni se pisa**: el supervisor no reintenta un mismo contenido que acaba de fallar antes de 15 minutos, dos corridas de una unidad no se pisan, y la configuración de git del agente no altera el respaldo (FR-013).
- **El crecimiento tiene una señal y un recorte** (FR-012 y FR-017).
- **Dos topes separados en SC-006**: el de la comprobación previa y el del empuje.
- **La enmienda de la constitución** enumera lo que las unidades pueden compartir y lo que viaja cifrado (FR-020).

Dos revisiones independientes de la remediación, de solo lectura, cerraron lo que quedaba abierto. Lo que cambió en el spec:

- **Agente marcado como sensible con fork**: su vault no se empuja en claro (FR-009 y FR-018).
- **La llave al restaurar**: sin una llave indicada, valen las llaves por defecto de hoy, para toda pieza cifrada (FR-014).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Un agente sin fork respalda en su repositorio privado (Priority: P1)

El operador asocia un repositorio privado a un agente. Desde ese momento, los respaldos que el launcher ya sabe hacer llegan a ese repositorio con la credencial de GitHub que el agente ya tiene, sin que haga falta un fork.

**Why this priority**: es la base de todo lo demás. Hoy los tres agentes docker no tienen ningún respaldo del launcher, y sin un destino y una credencial ninguna otra historia puede funcionar.

**Independent Test**: se asocia un repositorio de prueba a un agente sin fork, se fuerza el ciclo de respaldo y se comprueba que las unidades llegaron al repositorio y que sus ramas de trabajo no cambiaron.

**Acceptance Scenarios**:

1. **Given** un agente sin fork, con un repositorio asociado y la credencial de GitHub en su archivo de secretos, **When** corre el ciclo de respaldo, **Then** cada unidad habilitada queda en una rama de respaldo de ese repositorio y el estado local registra la fecha y el commit.
2. **Given** ese agente sin cambios desde el último respaldo, **When** corre otro ciclo, **Then** no se crea ningún commit nuevo.
3. **Given** un repositorio con ramas de trabajo, **When** corren varios ciclos de respaldo, **Then** la cabeza de cada rama de trabajo es la misma que antes.
4. **Given** un agente con fork y sin repositorio asociado, **When** corre el ciclo de respaldo, **Then** se comporta igual que hoy.
5. **Given** un agente sin fork y sin repositorio asociado, **When** pasa el tiempo, **Then** no empuja nada y se comporta como hoy: el supervisor no escribe nada, y cada cron de respaldo deja su línea de "sin destino" en su propio log.
6. **Given** un agente cuya credencial falta, venció o no tiene permiso, **When** corre el ciclo, **Then** el respaldo termina dentro de su tiempo máximo, el supervisor sigue corriendo y el diagnóstico muestra la falla.
7. **Given** una URL que apunta a un repositorio público, **When** corre el ciclo, **Then** el launcher no empuja nada y lo informa.
8. **Given** un repositorio cuya privacidad no se pudo comprobar, **When** corre el ciclo, **Then** el launcher no empuja nada y lo informa, salvo que el operador haya aceptado ese destino de forma explícita.
9. **Given** un respaldo de identidad que acaba de fallar, **When** el supervisor vuelve a revisar sin que el contenido haya cambiado, **Then** no lo reintenta antes de 15 minutos.

---

### User Story 2 - El respaldo cubre todo lo que hace recuperable al agente (Priority: P1)

El respaldo deja de limitarse a identidad, vault y `agent.yml`. Incluye también la persona, las memorias y el historial de conversaciones del agente, de modo que perder el host no signifique perder quién es el agente, lo que aprendió ni el hilo de su trabajo.

**Why this priority**: es lo que el operador pidió con "100% recuperable". Hoy la persona de donna y la de linus existen en un solo disco.

**Independent Test**: se cambia la persona, se agrega una memoria y se alarga el historial en un agente de prueba, se fuerza el ciclo y se comprueba que los tres cambios están en el respaldo y que lo que debe ir cifrado no se puede leer en el repositorio.

**Acceptance Scenarios**:

1. **Given** un agente con repositorio asociado, **When** el operador cambia su persona, **Then** el cambio queda en el respaldo dentro del ciclo programado.
2. **Given** ese agente, **When** su memoria gana una entrada, **Then** la entrada queda en el respaldo dentro del ciclo programado.
3. **Given** una memoria que se está escribiendo mientras corre el respaldo, **When** se restaura esa copia, **Then** se abre sin corrupción.
4. **Given** un agente con historial de conversaciones, **When** corre el respaldo, **Then** el historial queda completo en el repositorio, cifrado, aunque uno de sus archivos supere el tamaño máximo por archivo del servicio.
5. **Given** un agente marcado como de datos sensibles, **When** corre el respaldo, **Then** su vault, sus memorias, su historial y su configuración, salvo `agent.yml`, llegan cifrados y no se pueden leer en el repositorio sin la llave del operador.
6. **Given** un agente sin marcar, **When** corre el respaldo, **Then** su configuración, su vault y su auto-memoria llegan en claro, y su historial, su base de claude-mem, sus rutas adicionales y su archivo de secretos llegan cifrados.
7. **Given** un agente al que le falta la llave pública del operador, **When** corre el respaldo, **Then** lo que debe ir cifrado no se sube y el diagnóstico lo dice.
8. **Given** treinta ciclos de respaldo con cambios en las memorias y en el historial, **When** se mide el repositorio, **Then** su tamaño sigue bajo el límite de SC-007.
9. **Given** un agente cuyo operador declaró rutas adicionales, **When** corre el respaldo, **Then** esas rutas llegan cifradas, y una ruta que no existe o que sale del workspace se omite y se informa.
10. **Given** un agente con skills o comandos de proyecto, **When** corre el respaldo, **Then** quedan en el respaldo junto con su persona.
11. **Given** un agente cuyo operador cambió su llave, **When** corre el ciclo siguiente de cada unidad cifrada, **Then** todo lo cifrado queda legible con la llave nueva.

---

### User Story 3 - El operador recupera un agente completo desde su repositorio (Priority: P1)

Con el repositorio del agente y su llave, el operador reconstruye el agente en un host limpio: misma configuración, misma persona, mismas credenciales, mismo vault, mismas memorias y mismo historial de conversaciones.

**Why this priority**: un respaldo que nunca se restauró no es un respaldo. Sin esta historia, "recuperable" queda sin demostrar.

**Independent Test**: en un directorio limpio se restaura un agente desde su repositorio y se compara cada archivo con lo respaldado: por su hash contra el origen los que viajan tal cual, y contra la lista de lo capturado las bases y los historiales.

**Acceptance Scenarios**:

1. **Given** un host limpio, la URL del repositorio y la llave del operador, **When** el operador corre la restauración, **Then** el workspace queda con la misma configuración, persona, identidad, vault, memorias e historial que tenía el agente en su último respaldo.
2. **Given** un repositorio al que le falta una unidad, **When** corre la restauración, **Then** las demás se restauran y el resultado dice cuál faltó.
3. **Given** una restauración sin la llave del operador, **When** termina, **Then** lo cifrado no se restaura, lo demás sí, y el resultado lo dice de forma explícita.
4. **Given** un agente que se autentica con el token de su archivo de secretos, **When** se restaura, **Then** el archivo de secretos y el emparejamiento del canal restaurados son los del original, y su última conversación se retoma con el historial restaurado.
5. **Given** un agente con fork, **When** el operador usa la restauración que ya existía, **Then** funciona igual que hoy.
6. **Given** un agente que solo inició sesión con `/login`, **When** se restaura, **Then** todo lo demás vuelve y el resultado avisa que hay que iniciar sesión de nuevo.
7. **Given** una llave del operador con passphrase, **When** corre la restauración, **Then** la passphrase se pide una vez por pieza cifrada, y no una vez por bloque.

---

### User Story 4 - El agente conoce su repositorio y trabaja en él sin tocar los respaldos (Priority: P2)

El agente sabe, desde su contexto y no desde una memoria que alguien le escribió a mano, cuál es su repositorio, para qué sirve y qué parte es del launcher. Puede publicar su trabajo en las ramas de trabajo con la misma credencial de GitHub.

**Why this priority**: hoy esa instrucción vive en la auto-memoria de dos agentes y no existe en el tercero. Si la memoria se pierde, el agente olvida su repositorio.

**Independent Test**: se regenera un agente con repositorio asociado y se comprueba que su contexto nombra el repositorio y la regla; se regenera uno sin repositorio y se comprueba que la sección no aparece.

**Acceptance Scenarios**:

1. **Given** un agente con repositorio asociado, **When** se regenera su contexto, **Then** el contexto nombra el repositorio, sus dos papeles y la regla de no tocar las ramas de respaldo, y le dice qué estado no queda cubierto.
2. **Given** un agente sin repositorio asociado, **When** se regenera su contexto, **Then** no aparece esa sección y el texto sobre respaldos dice la verdad para su caso.
3. **Given** un agente con repositorio asociado, **When** publica una rama de trabajo desde su clon de trabajo, **Then** el empuje funciona con la credencial ya configurada, sin pasos manuales ni preguntas interactivas.
4. **Given** un agente que borró por error una rama de respaldo, o la modificó sin quitarle su marca de pertenencia, **When** corre el ciclo siguiente, **Then** la rama vuelve a reflejar el estado actual del agente.
5. **Given** una rama de respaldo a la que le quitaron la marca de pertenencia, **When** corre el ciclo siguiente, **Then** el launcher no escribe en ella y el diagnóstico lo dice, hasta que el operador la borra.

---

### User Story 5 - El operador ve si el respaldo está al día (Priority: P2)

El diagnóstico del agente dice, por cada unidad, a dónde va, cuándo fue el último respaldo correcto y si el último intento falló. También avisa cuando hay trabajo sin publicar en el clon de trabajo.

**Why this priority**: el respaldo falla en silencio por diseño. Sin una señal visible puede estar roto durante semanas, como hoy.

**Independent Test**: se provoca una falla de credencial, se corre el diagnóstico y se comprueba que la muestra sin exponer ningún secreto.

**Acceptance Scenarios**:

1. **Given** un agente con respaldos al día, **When** el operador corre el diagnóstico, **Then** ve por cada unidad el destino, la fecha del último respaldo correcto y el resultado del último intento.
2. **Given** una unidad cuyo último respaldo correcto es más antiguo que el umbral, **When** corre el diagnóstico, **Then** aparece una advertencia.
3. **Given** un clon de trabajo con commits sin publicar, **When** corre el diagnóstico, **Then** aparece una advertencia que dice cuántos son.
4. **Given** cualquier resultado del diagnóstico, **When** se revisa su salida, **Then** no contiene el valor de ninguna credencial.
5. **Given** una ruta adicional declarada que no existe, **When** corre el diagnóstico, **Then** aparece una advertencia que la nombra.
6. **Given** un respaldo cuyo tamaño se acerca al límite recomendado del repositorio, **When** corre el diagnóstico, **Then** aparece una advertencia.

---

### User Story 6 - La mejora se demuestra y llega a la flota (Priority: P3)

Antes del merge se demuestra el empuje autenticado contra un repositorio privado real. Después del merge, donna, linus y cbum quedan con su repositorio asociado y un respaldo verificado.

**Why this priority**: ninguna prueba ejerce hoy el empuje autenticado, así que la evidencia local no basta. El despliegue es lo que le entrega el valor al operador.

**Independent Test**: en un agente real, con la imagen de la rama, se asocia su repositorio, se fuerza el ciclo y se verifican las ramas de respaldo en GitHub y las ramas de trabajo intactas.

**Acceptance Scenarios**:

1. **Given** un agente real con la imagen de la rama y su repositorio asociado, **When** corre el ciclo de respaldo, **Then** las unidades quedan en GitHub y las ramas de trabajo no cambian.
2. **Given** ese respaldo, **When** se restaura en un directorio limpio sin arrancar el workspace restaurado, **Then** cada unidad coincide con lo respaldado.
3. **Given** el merge hecho, **When** el operador despliega, **Then** donna, linus y cbum tienen un respaldo verificado de cada unidad habilitada.

---

### Edge Cases

- **Repositorio público o que no se puede comprobar**: si el launcher no puede confirmar que el repositorio es privado, no empuja. Una comprobación que falla por la red cuenta como no comprobado, no como privado.
- **Repositorio en un servidor que no es GitHub**: no se admite. La credencial es de GitHub y no se le entrega a otro servidor.
- **Dos agentes con el mismo repositorio**: el segundo no pisa los respaldos del primero; detecta que las ramas son de otro agente, no escribe y lo informa.
- **Rama con el nombre de una rama de respaldo, pero ajena**: si existe y no la creó el launcher, no se escribe en ella y se informa.
- **Repositorio vacío** o con una rama principal que no se llama `main`: el respaldo funciona igual, y el clon de trabajo nunca deja extraída una rama de respaldo. Se recomienda crear el repositorio con un commit inicial en `main`.
- **Archivo sobre el tamaño que acepta el servicio**: no puede quedar fuera del respaldo. El historial de donna ya tiene un archivo de 68,6 MiB y sigue creciendo, así que el diseño debe respaldarlo completo aunque supere ese máximo.
- **Sin red durante días**: al volver, el ciclo siguiente respalda el estado actual sin acumular intentos pendientes.
- **Credencial rotada**: basta con actualizar el archivo de secretos y recrear el contenedor; ningún otro archivo guarda la credencial.
- **Llave del operador perdida**: lo cifrado no se puede recuperar. El diagnóstico muestra la huella de la llave para la que se cifra.
- **Llave del operador cambiada**: lo cifrado se vuelve a subir completo, para la llave nueva. Lo que estaba cifrado para la anterior sale de la cabeza del respaldo.
- **Llave del operador con passphrase**: la restauración la pide una vez por pieza cifrada, y necesita una terminal.
- **Trabajo sin publicar en el clon de trabajo**: no está respaldado; lo avisa el diagnóstico (historia 5).
- **Ensayo de restauración con el agente original vivo**: el ensayo no arranca el workspace restaurado, porque dos procesos con el mismo token de Claude y el mismo bot de Telegram se pisan.
- **Agente de datos sensibles**: la persona de CBum le prohíbe subir datos de salud a un repositorio. Con el respaldo cifrado de FR-009, el operador ajusta esa regla en el mismo despliegue para que permita solo ese respaldo.
- **Falta la llave pública del operador**: lo que debe ir cifrado no se sube en claro. Esas unidades no corren y el diagnóstico lo dice.
- **El historial guarda secretos que pasaron por la conversación**: por eso viaja cifrado en todos los agentes, también en los que no están marcados como sensibles.
- **Agente con repositorio asociado y sin credencial de GitHub**: el respaldo no corre y el diagnóstico dice qué falta.
- **El agente cambia `agent.yml` en caliente** (por ejemplo con `heartbeatctl`): la asociación se conserva.
- **Credencial que deja de servir sin que cambie el contenido**: se detecta igual en el ciclo siguiente, porque cada ciclo consulta al destino.
- **Agente que solo inició sesión con `/login`**: ese login no viaja en el respaldo. Después de restaurar hay que iniciar sesión de nuevo.
- **Estado que el agente guarda donde el launcher no sabe**: no se respalda hasta que el operador declara la ruta. El contexto del agente le pide avisar.
- **Ruta adicional que apunta fuera del workspace**: se rechaza.
- **Asociación declarada en un agente de modo local**: no tiene efecto, y regenerar deja una advertencia.
- **Agente marcado como sensible, con fork y sin repositorio**: su vault no se empuja. En modo local la marca no se honra, y regenerar lo advierte.
- **Dos corridas de la misma unidad a la vez** (el cron y una manual): la segunda no corre, y lo dice.
- **Respaldo que falla una y otra vez**: el supervisor no reintenta el mismo contenido antes de 15 minutos.
- **Historial que Claude Code borró por su retención de 30 días**: sale también de la cabeza del respaldo, que refleja el estado actual del agente.
- **El repositorio crece con los meses**: el diagnóstico avisa, y borrar una rama de respaldo la recorta sin tocar las ramas de trabajo.
- **El agente escribe su propia configuración global de git**: no altera los respaldos.

## Requirements *(mandatory)*

### Functional Requirements

**Asociación y destino**

- **FR-001**: `agent.yml` admite, de forma opcional, la asociación de un repositorio privado al agente. Por defecto no hay ninguna, y la asociación sobrevive a `--regenerate` y a los cambios en caliente de `agent.yml`.
- **FR-002**: El destino de los respaldos se resuelve con una sola regla para todas las unidades: el repositorio asociado si existe; si no, el fork, como hoy; si no hay ninguno, no se respalda nada, como hoy.
- **FR-003**: El wizard ofrece la asociación como un paso opcional, con "no" por defecto, y solo en modo docker. Si el operador la acepta y el agente todavía no tiene la credencial de GitHub, el wizard la pide antes de terminar. Un agente que ya existe la adopta declarándola en `agent.yml`, regenerando y fijando su llave (FR-010), sin volver a crearlo.
- **FR-004**: El launcher escribe solo en sus ramas de respaldo. Nunca crea, modifica ni borra ramas de trabajo ni su historial. Si una rama con nombre de respaldo existe y no es suya, o pertenece a otro agente, no escribe en ella y lo informa.
- **FR-005**: Antes de empujar, el launcher comprueba que el repositorio asociado es privado. Si es público, o no lo puede comprobar, no empuja; una comprobación que falla por la red cuenta como no comprobado. El operador puede declarar de forma explícita que acepta un destino que no se puede comprobar, y esa aceptación nunca habilita un repositorio público. El repositorio asociado tiene que estar en GitHub.

**Credencial**

- **FR-006**: El agente empuja con la credencial de GitHub que ya tiene en su archivo de secretos, la misma que usa su MCP de GitHub. No se crea una credencial por agente. Si un agente con repositorio asociado no la tiene, el respaldo no corre y el diagnóstico dice qué falta.
- **FR-007**: La credencial vive solo en el archivo de secretos del workspace. Su valor no aparece en `agent.yml`, en los logs, en los argumentos de ningún proceso, en la configuración de git de ningún clon ni en la URL de ningún remoto.

**Cobertura**

- **FR-008**: El respaldo cubre la configuración (incluida la configuración de proyecto de Claude del workspace), la identidad, los secretos del agente, el vault, la persona, las memorias (la auto-memoria de Claude y la base de claude-mem), el historial de conversaciones y las rutas adicionales que declare el operador (FR-025).
- **FR-009**: Cada agente se puede marcar en `agent.yml` como de datos sensibles. El contenido se trata así:
  - en un agente marcado, el vault, las memorias, el historial y la configuración, salvo `agent.yml`, se cifran dentro del agente antes de empujar;
  - un agente marcado que tiene fork y no tiene repositorio asociado no empuja su vault: un fork no lleva contenido cifrado, y el vault de un agente marcado no viaja en claro;
  - en un agente sin marcar, la configuración, el vault y la auto-memoria van en claro;
  - en todos los agentes, el archivo de secretos, el historial de conversaciones, la base de claude-mem y las rutas adicionales viajan siempre cifrados;
  - la llave privada del operador nunca entra al contenedor ni al repositorio.
- **FR-010**: La llave pública del operador, para la que se cifra, se puede configurar sin fork. Hoy sale del dueño del fork, y un agente sin fork no tiene cómo definirla.
  - En un agente nuevo, el wizard propone una y muestra su huella.
  - En un agente que ya existe, el operador la fija con un paso explícito, que también muestra su huella. Regenerar no elige ninguna: avisa que falta.
  - Si falta, lo que debe ir cifrado no se sube en claro: esas unidades no corren y el diagnóstico lo dice.
  - Si cambia, lo cifrado vuelve a quedar legible con la llave vigente en el ciclo siguiente de cada unidad.
- **FR-011**: Una unidad que se captura mientras el agente está escribiendo queda en un estado que se puede restaurar sin corrupción.
- **FR-012**: Cuando no hay cambios no se crea ningún commit. El crecimiento del repositorio por los respaldos se mide a 30 ciclos (SC-007). Más allá, el diagnóstico avisa cuando el respaldo se acerca al límite recomendado, y el operador puede recortar una rama de respaldo sin tocar las de trabajo. Ningún dato cubierto por FR-008 queda fuera del respaldo por su tamaño: un archivo que supera el máximo por archivo del servicio se respalda igual, completo.

**Comportamiento ante fallas**

- **FR-013**: Todo respaldo es no interactivo, tiene un tiempo máximo y nunca detiene ni reinicia al supervisor. Una falla queda registrada y se reintenta en el ciclo siguiente. Cada ciclo comprueba el acceso al destino y el estado de su rama, también cuando no hay cambios. Dos corridas de una misma unidad no se pisan. El supervisor no reintenta un mismo contenido que acaba de fallar antes de 15 minutos. La configuración de git que el agente tenga en su directorio personal no altera el respaldo.

**Restauración**

- **FR-014**: La restauración acepta el repositorio del agente como origen y recupera todas las unidades respaldadas en un orden definido. Cada unidad es opcional, y el resultado dice qué se restauró y qué no. La forma de invocarla que ya existe sigue funcionando con un fork. La restauración avisa cuando el agente restaurado va a necesitar un inicio de sesión manual, y cuando trae un archivo que cambia los privilegios del contenedor. Con una llave con passphrase, la pide una vez por pieza cifrada. Si no se indica una llave, prueba las mismas llaves por defecto que prueba hoy.

**El agente y su repositorio**

- **FR-015**: El contexto del agente, derivado de `agent.yml`, nombra su repositorio, sus dos papeles y la regla de no tocar las ramas de respaldo, y le dice qué estado no queda cubierto. La sección no aparece en un agente sin repositorio, cuyo contexto queda idéntico al de hoy: su texto sobre respaldos ya es verdadero para ese caso. En un agente con repositorio, ese texto se reemplaza por uno que describe sus cinco ramas.
- **FR-016**: El agente puede traer y publicar las ramas de trabajo de su repositorio con la credencial de FR-006, desde un clon de trabajo en una ubicación fija del workspace.

**Diagnóstico**

- **FR-017**: El diagnóstico muestra, por cada unidad, el destino, la fecha del último respaldo correcto y el resultado del último intento. Advierte cuando el último respaldo correcto supera un umbral de antigüedad, cuando el último intento falló, cuando la privacidad del destino no está comprobada, cuando una ruta adicional declarada no existe, cuando el clon de trabajo falta o tiene commits sin publicar, y cuando el respaldo se acerca al límite de tamaño. Nunca imprime un secreto.

**Compatibilidad y alcance**

- **FR-018**: Un agente sin repositorio asociado no cambia: con fork respalda como hoy, y sin fork sigue sin respaldos, con los mismos mensajes de hoy en sus logs. La única excepción es la de FR-009: un agente con fork que el operador marque como de datos sensibles deja de empujar su vault.
- **FR-019**: El modo local no cambia: para un mismo `agent.yml` sin repositorio asociado, su render es idéntico al de `main`. Una asociación declarada en modo local no tiene efecto y se advierte.
- **FR-020**: Si el diseño agrega una unidad de respaldo a las tres que fija el Principio V, la constitución se enmienda de forma explícita en la misma feature, antes de implementar. La enmienda dice además qué pueden compartir las unidades y qué tiene que viajar cifrado.

**Evidencia y despliegue**

- **FR-021**: La feature se desarrolla con pruebas primero en la suite del host, en bash 3.2 y en 5.x, y con una prueba de extremo a extremo en un contenedor real que ejerza el empuje autenticado, que hoy no ejerce ninguna prueba.
- **FR-022**: Antes del merge se demuestra el respaldo completo y un ensayo de restauración contra un repositorio privado real, en un agente con la imagen de la rama. Es un paso del operador, con compuerta.
- **FR-023**: Después del merge, el operador despliega en donna, linus y cbum: donna y linus con sus repositorios actuales, y cbum con uno nuevo y marcado como de datos sensibles. Cada despliegue lleva su respaldo previo de la imagen y deja registrado el primer respaldo verificado.
- **FR-024**: La feature actualiza `CHANGELOG.md`, `VERSION` y la documentación del launcher que describe los respaldos.

**Estado propio del agente**

- **FR-025**: El operador puede declarar en `agent.yml` rutas adicionales del workspace que deben respaldarse. Viajan siempre cifradas y se restauran en su misma ruta. Una ruta que sale del workspace se rechaza. Sirven para el estado que el launcher no conoce: el de un overlay, o el de una feature que el agente se construyó.
- **FR-026**: El despliegue de cada agente incluye un inventario del estado que ninguna unidad cubre, y deja registrada la decisión sobre cada entrada: declararla como ruta adicional o dejarla fuera.

### Key Entities

- **Repositorio del agente**: el repositorio privado asociado a un agente. Tiene ramas de trabajo, que son del agente y del operador, y ramas de respaldo, que son del launcher.
- **Rama de trabajo**: cualquier rama del repositorio que no es de respaldo. El launcher no la toca.
- **Unidad de respaldo**: un conjunto independiente de datos con su propia rama, su propio hash y su propio estado. Hoy son tres: identidad, vault y configuración. Con un repositorio asociado son cinco: se suman las memorias y el historial.
- **Credencial de GitHub**: la que el agente ya tiene en su archivo de secretos y usa su MCP de GitHub. Da acceso a todos los repositorios de la cuenta del operador; con ella se empujan los respaldos y el trabajo.
- **Agente de datos sensibles**: un agente marcado así en `agent.yml`. Su vault, sus memorias, su historial y su configuración, salvo `agent.yml`, se respaldan cifrados.
- **Memorias**: la auto-memoria de Claude, que es texto, y la base de claude-mem del agente, que viaja siempre cifrada.
- **Historial de conversaciones**: los registros de las sesiones del agente. Se respalda siempre cifrado.
- **Llave del operador**: la llave para la que se cifra lo sensible. Su parte privada queda solo en manos del operador.
- **Llave de datos**: una llave propia de cada almacén cifrado, que genera el agente. Con ella se cifra el contenido, y ella misma viaja cifrada para la llave del operador.
- **Estado de respaldo**: el registro local, por unidad, del último hash, el último commit, la fecha y el resultado del último intento.
- **Clon de trabajo**: la copia del repositorio dentro del workspace donde el agente desarrolla sus features.
- **Ruta adicional**: una ruta del workspace que el operador declara para que se respalde cifrada. Cubre el estado que el launcher no conoce.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En un agente sin fork y con repositorio asociado, al forzar el ciclo, el 100 % de las unidades habilitadas queda en el repositorio y su estado local registra el éxito. Un segundo ciclo sin cambios crea 0 commits.
- **SC-002**: En un ensayo de restauración sobre un directorio limpio, el 100 % de los archivos restaurados coincide con lo respaldado: por su hash contra el origen los que viajan tal cual, incluidos el archivo de secretos y el emparejamiento del canal, y contra la lista de lo capturado las bases y los historiales. La última conversación se retoma con el historial restaurado. El workspace restaurado no se arranca.
- **SC-003**: Tras 10 ciclos de respaldo sobre un repositorio con ramas de trabajo, la cabeza de cada rama de trabajo es idéntica a la inicial: 0 cambios.
- **SC-004**: Para un `agent.yml` sin repositorio asociado, los archivos derivados y el crontab tienen 0 bytes de diferencia con los de `main`. Un agente sin fork y sin repositorio hace 0 empujes, y sus logs reciben las mismas líneas que con `main`.
- **SC-005**: El valor de la credencial aparece 0 veces en `agent.yml`, en los logs, en los argumentos de los procesos, en la configuración de git de los clones, en las URL de los remotos y en el repositorio. Lo que FR-009 manda cifrar no se puede leer en el repositorio sin la llave del operador: hay 0 archivos en claro de ese contenido. Tras un cambio de la llave del operador, el 100 % de lo cifrado se abre con la llave nueva.
- **SC-006**: Con la credencial inválida o el destino inalcanzable, cada unidad termina en 3 minutos como máximo, sin llegar a empujar. Un empuje que se cuelga se corta en su tope: 60 segundos, o 15 minutos en las memorias y el historial. En los dos casos, el supervisor registra 0 reinicios por esa causa y el diagnóstico muestra la falla en el ciclo siguiente.
- **SC-007**: Con datos del tamaño de los del agente más grande de hoy (un historial de 68,6 MiB en un archivo, 32,6 MB en la carpeta de su sesión y una base de 13,9 MB), ningún empuje es rechazado por tamaño y el 100 % del historial queda respaldado. Tras 30 ciclos simulados con cambios diarios en las memorias y en el historial, el repositorio queda bajo 1 GB.
- **SC-008**: El 100 % de los agentes con repositorio asociado tiene en su contexto la sección que lo nombra, y el 0 % de los agentes sin repositorio la tiene.
- **SC-009**: La suite del host da la línea base medida más las pruebas nuevas, con 0 `not ok` en bash 3.2 y en 5.x. Cada prueba nueva cae contra `origin/main` o con su mutación.
- **SC-010**: Tras el despliegue, donna, linus y cbum tienen al menos un respaldo verificado de cada unidad habilitada, 0 cambios en sus ramas de trabajo y 0 reinicios atribuibles al cambio en sus primeras 24 horas. En cbum, marcado como de datos sensibles, hay 0 archivos en claro de su vault, sus memorias, su historial y su configuración, salvo `agent.yml`. El inventario de FR-026 de cada agente no tiene entradas sin decisión, y el 100 % de las rutas adicionales de donna está en su respaldo.

## Assumptions

- Los repositorios viven en GitHub, en la cuenta personal del operador, y siguen el nombre `<agente>-workspace-agent-admin`. El launcher solo admite repositorios de GitHub como destino. El de cbum lo crea el operador, con un commit inicial en `main`.
- Cuando un agente tiene fork y repositorio asociado, los respaldos van al repositorio. El fork conserva su papel de sincronizar con el template.
- El launcher no crea repositorios: solo asocia uno que ya existe.
- El cambio agrega funcionalidad, así que el bump por defecto es MINOR (0.31.0 a 0.32.0), con su entrada en el CHANGELOG. Es un default declarado, reversible antes del PR.
- El límite de 1 GB de SC-007 y el tamaño máximo por archivo salen de la documentación de GitHub, leída el 13-11-2026: avisa sobre 50 MiB por archivo, bloquea sobre 100 MiB y recomienda repositorios bajo 1 GB.
- El tope de 3 minutos de SC-006 cubre la comprobación previa de cada unidad, que son dos consultas de 60 segundos como máximo. El empuje tiene su propio tope. El umbral de antigüedad del diagnóstico (FR-017) lo fija el plan según la cadencia de cada unidad.
- El gate previo al merge se hace en linus, que es el agente con menos riesgo: su repositorio casi no tiene contenido y no maneja datos de salud. El plan puede proponer otro.
- La prueba de extremo a extremo local corre en el Mac del operador, con compuerta, como en las features anteriores.
- El merge es del operador.
- El operador ajusta la regla de la persona de CBum en el mismo despliegue, para que permita el respaldo cifrado del launcher y nada más.
- El historial de conversaciones se cifra en todos los agentes, también en los que no están marcados como sensibles: guarda en bruto todo lo que pasó por la conversación, y eso puede incluir secretos. Es un default declarado; el operador puede pedir que en los agentes sin marcar vaya en claro.
- La credencial de GitHub es amplia: da acceso de escritura a todos los repositorios de la cuenta. La feature no cambia quién la tiene hoy, porque los tres agentes ya la tienen en su entorno, pero un agente nuevo que quiera respaldo la necesita.
- Restaurar el historial permite retomar la conversación. Lo documenta Claude Code, pero no está medido: se mide en el gate previo al merge y, si no retoma, SC-002 se enmienda antes del merge.
- La base de claude-mem también se cifra en todos los agentes: guarda observaciones de las mismas conversaciones y es un archivo binario, que en claro tampoco se podría leer en GitHub. Es un default declarado en el plan.
- El camino de un agente marcado como sensible se ejerce en la prueba de extremo a extremo y en el despliegue de cbum.
- La flota se autentica con el token de Claude de su archivo de secretos (medido el 13-11-2026 en los tres agentes). El login de `/login` no viaja en el respaldo, así que un agente que solo use `/login` necesita un inicio de sesión manual después de restaurar. Lo decidió el operador el 13-11-2026.
- La configuración de proyecto de Claude y las rutas adicionales se agregaron al generar las tareas, por lo medido en donna. El operador aprobó esa ampliación el 13-11-2026.
- El respaldo refleja el estado actual del agente. Claude Code borra los historiales de más de 30 días, y esos dejan de estar en la cabeza del respaldo.
- El cifrado protege la confidencialidad de lo respaldado, no su autenticidad. La restauración confía en el control de acceso del repositorio, igual que hoy.
- Una unidad con contenido cifrado hace un commit cada vez que empaqueta, aunque el contenido no haya cambiado, porque el cifrado no es determinista. El ciclo sin cambios de SC-001 no llega a empaquetar.
- Las cuatro decisiones del operador del 14-11-2026 (la llave de datos, la configuración cifrada de un agente sensible, la llave fijada con un paso explícito y SC-002 acotado) salieron del análisis de consistencia.

## Out of Scope

- Cambiar el flujo del fork o `--sync-template`.
- Mover o reorganizar el contenido de trabajo que ya está en los repositorios de donna y de linus.
- Crear al agente Doctor Milagro; nace después, ya con esta feature.
- Versionar las personas en el repositorio `agentic-pod-launcher-custom-config`.
- Reemplazar o cambiar la réplica del vault por Syncthing.
- Agregar unidades de respaldo nuevas al modo local.
- Respaldar otros repositorios clonados dentro del workspace: cada uno tiene su propio remoto.
- Automatizar pull requests o revisiones sobre las ramas de trabajo.
- Respaldar el archivo de configuración vivo de Claude y el login de `/login`.
- Detectar de forma automática el estado que ninguna unidad cubre: se hace con un inventario en el despliegue.
- Corregir la unidad de identidad para el destino fork: queda como hallazgo lateral, con su issue.
- Admitir como destino un repositorio que no esté en GitHub.
- Firmar los respaldos o verificar su autenticidad al restaurar.
