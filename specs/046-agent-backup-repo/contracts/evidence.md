# Contrato: evidencia

**Feature**: `046-agent-backup-repo` | Cubre FR-021, FR-022 y FR-023, y los criterios SC-001 a SC-010.

La evidencia tiene tres niveles: la suite del host, la prueba de extremo a extremo en un contenedor real, y el gate de integración contra GitHub privado real antes del merge. El operador sustituyó linus por el piloto aislado del M4 el 16-11-2026; sus límites están en [local-pilot.md](local-pilot.md). Los pasos están en [quickstart.md](../quickstart.md).

## V1. El doble de prueba: un servidor git con autenticación

`tests/fixtures/backup-repo/git-auth-server.py`, derivado del prototipo de M3 de [research.md](../research.md).

| Propiedad | Valor |
| --- | --- |
| Dependencias | Python 3 (biblioteca estándar) y `git http-backend` |
| Repositorios | Los bare de `GIT_TEST_ROOT` |
| Dirección | `127.0.0.1` por defecto; `0.0.0.0` con `GIT_TEST_BIND` para la prueba de extremo a extremo |
| Puerto | Efímero; lo escribe en `GIT_TEST_PORT_FILE` |
| Autenticación | Básica. La contraseña debe ser igual al contenido de `GIT_TEST_TOKEN_FILE`, que se lee en cada petición |
| Modos | Las palabras de `GIT_TEST_MODE_FILE`, que se lee en cada petición |
| Log | `GIT_TEST_LOG`: una línea por petición, con el código, la ruta, el servicio (`upload-pack` o `receive-pack`) y `auth=ok`, `auth=bad`, `auth=none` o `auth=anon`. Nunca la credencial |

Como la credencial y los modos se leen en cada petición, una prueba los cambia sin reiniciar el servidor.

| Palabra en el archivo de modos | Efecto |
| --- | --- |
| `anon-read` | Sirve las lecturas sin credencial y sigue exigiéndola para los empujes: un repositorio "público" |
| `anon-error-once` | Responde 500 a la próxima petición sin credencial, en vez de pedirla. Vale una sola vez |
| `stall-anon-once` | Acepta la próxima petición sin credencial y no la responde. Vale una sola vez |
| `deny-push` | Responde 403 a los empujes |
| `stall-auth`, `stall-push` | Acepta toda petición de esa clase y no la responde |

Los dos modos de un solo uso existen por cómo habla git: toda operación autenticada empieza con una petición sin credencial, que el servidor rechaza con 401 (medido el 14-11-2026 con git 2.53.0). Un modo que afectara a toda petición sin credencial rompería también la consulta autenticada, y el veredicto "no comprobado" no se podría producir. Por lo mismo, una prueba no detecta la sonda anónima contando peticiones `auth=none`: mira `anon_checked_epoch` en el registro del destino y el código de las respuestas.

Reglas del arnés (`tests/helper-backup-repo.bash`), tomadas de los gotchas de `CLAUDE.md`:

- el servidor no usa `HTTPServer.server_bind`, que en el runner macOS de la CI tarda decenas de segundos;
- se lanza cerrando los descriptores de bats (`3>&- 4>&-`) y se mata en `teardown`;
- cada prueba usa un valor centinela propio como credencial y otro por cada fuente de datos, para poder buscarlos después;
- los comandos de git del propio arnés corren con una configuración global y de sistema vacías. Las unidades que el arnés lanza no heredan esas variables: corren con un `HOME` propio y vacío, para que la prueba del `~/.gitconfig` hostil pruebe el aislamiento de producción;
- toda prueba de restauración corre con un `HOME` propio y vacío, para que ninguna toque las llaves del operador;
- donde el host no tiene `timeout` o `flock`, como el Mac, el arnés pone en el PATH los suyos (`tests/fixtures/backup-repo/bin/`), y solo esos: sin `timeout`, las pruebas de los topes no terminarían;
- las pruebas cargan `setup.sh` o `start_services.sh` dentro del cuerpo de la prueba, nunca en `setup()`;
- **una dependencia que falta**: en un equipo de desarrollo, la prueba se salta con su motivo. Con la variable `CI` definida, **falla**: un runner sin `git http-backend`, `age`, `age-keygen`, `python3` o `ssh-keygen` no puede dejar la suite en verde sin haberla corrido.

## V2. Suite del host

Todas las pruebas son nuevas. Se escriben antes que el código, y cada una se ve fallar antes de pasar, salvo las ocho que nacen en verde a propósito (más abajo).

### `tests/backup-dest.bats`

| Id | Afirma |
| --- | --- |
| TD01 a TD03 | La regla de destino: `repo`, `fork` y `none`, con valores vacíos, `null` y `agent.yml` ausente |
| TD04 y TD05 | La selección del askpass y sus respuestas; no imprime nada más |
| TD06 | Veredicto `private`: el servidor pide credencial a la sonda anónima, y la consulta autenticada funciona |
| TD07 | Veredicto `public`: la sonda anónima funciona |
| TD08 | Veredicto `unreachable`: con una credencial equivocada y con un puerto cerrado |
| TD09 | Veredicto `unverified-allowed`: la sonda anónima falla por otra razón, la consulta autenticada funciona y `allow_unverified` está activo. El registro y el log muestran que la sonda anónima se hizo |
| TD10 | La sonda anónima no se repite dentro de las 24 horas contadas desde la última sonda anónima, aunque haya corridas intermedias; vencido el plazo se repite; un cambio de URL la fuerza; y la consulta autenticada corre siempre |
| TD11 | Las URL que se rechazan sin hacer ninguna petición: `http://` sin la costura de prueba, con credenciales embebidas, con forma ssh, de otro servidor que no es GitHub, y `http://` hacia un servidor que no es local aun con la costura |
| TD12 | La marca de pertenencia: `new`, `ok`, `foreign` y `other-agent` |
| TD13 | El registro del intento conserva los campos previos, es atómico y guarda el momento en segundos y el hash intentado |
| TD14 | El valor centinela de la credencial no queda en ningún archivo, log ni argumento |
| TD15 | `backup_dest_branch_head` entrega el commit de la rama pedida, y vacío si la rama no existe |
| TD16 | Veredicto `unverified`: la sonda anónima falla por otra razón, o agota su tope, y `allow_unverified` no está activo. Ese veredicto no se reutiliza: la corrida siguiente repite la sonda |
| TD17 | Con `allow_unverified` activo y un repositorio que responde sin credencial, el veredicto es `public` |
| TD18 | Una consulta que el servidor no responde termina dentro de su tope: `unreachable` si es la autenticada |

### `tests/backup-store.bats`

| Id | Afirma |
| --- | --- |
| TS01 a TS04 | Ida y vuelta byte a byte: texto, binario de varios bloques, archivo vacío, y muchos archivos con rutas anidadas y espacios |
| TS05 y TS06 | Reutilización: el segundo `pack` no escribe bloques ni rota, y un archivo que crece solo escribe el último bloque y los nuevos |
| TS07 | Los bloques sin referencia se borran |
| TS08 y TS09 | No hay contenido en claro en el almacén, salvo `recipient` y `operator`, y el manifiesto está cifrado |
| TS10 a TS12 | Llave equivocada, bloque alterado y ruta maliciosa en el manifiesto: sale con el código correcto y no escribe nada |
| TS13 | Un `.jsonl` con la última línea incompleta se empaqueta sin ella |
| TS14 | La copia de una base SQLite con escrituras en curso pasa la verificación de integridad y contiene lo escrito antes de la copia |
| TS15 | El hash de `digest` coincide con el de `pack` y cambia con `--extra` |
| TS16 | La huella coincide con la de `ssh-keygen -lf` |
| TS17 | El archivo compila con el Python del host, cuya versión queda en la salida de la prueba |
| TS18 | `pack` y `digest` reconocen una base SQLite por su cabecera, con cualquier nombre, y empaquetan la copia consistente; dos corridas sin cambios dan el mismo hash; los archivos `-wal`, `-shm` y `-journal` se omiten |
| TS19 | Al cambiar la llave del operador, `pack` rota: cifra todos los bloques de nuevo, el almacén se abre con la llave nueva y ya no se abre con la anterior |
| TS20 | `unpack` invoca a `age` con la llave del operador exactamente una vez, con cualquier cantidad de bloques, y ni `pack` ni `unpack` dejan la llave de datos en claro en un archivo |
| TS21 | Con `--expect-recipient` distinto de la `recipient` del almacén, `pack` rota y ningún bloque queda cifrado para la que traía; sin esa opción, la conserva |
| TS22 | `digest --list` entrega la ruta lógica, el tamaño y el SHA-256 de cada archivo tal como se captura, y coincide con lo que `unpack` reconstruye |

### `tests/backup-repo-units.bats`

| Id | Afirma |
| --- | --- |
| TU01 y TU02 | `identity` llega al repositorio con su marca y su estado, también a un repositorio vacío; un segundo ciclo no crea commits, tampoco con `--gc` (SC-001) |
| TU03 | Tras 10 ciclos de las unidades, las referencias del repositorio que no son de respaldo son las mismas, con las mismas cabezas, y las de respaldo son exactamente una por unidad (SC-003) |
| TU04 y TU05 | `config` ampliada con repositorio, y solo `agent.yml` con fork |
| TU06 y TU07 | `vault` en claro sin marca, y sin ningún `.md` en claro con la marca de datos sensibles; con la marca y un fork en vez de repositorio, no se empuja |
| TU08 a TU10 | `memory`: auto-memoria en claro y claude-mem cifrado, y un cambio solo en la auto-memoria crea un commit; todo cifrado si el agente es sensible; la base sale de la copia consistente |
| TU11 y TU12 | `history`: solo `store/`, sin centinelas, con líneas completas; un historial que crece sube pocos bloques |
| TU13 a TU16 | Sin credencial, credencial equivocada, repositorio público y sin llave pública: el resultado correcto y ningún empuje |
| TU17 y TU18 | Rama ajena y rama de otro agente: no se escribe |
| TU19 y TU20 | Con `none` y con `fork`, los mensajes, los códigos y los archivos de estado son los de `main`; un fork no recibe la credencial ni la marca |
| TU21 | El crontab solo gana líneas con repositorio; con `fork` o `none` es idéntico al de `main`, comparado con un archivo dorado |
| TU22 | Una unidad que falla no impide a las demás, y un veredicto `unreachable` no se reutiliza en la corrida siguiente |
| TU23 | Una rama de respaldo borrada se vuelve a crear en el ciclo siguiente, aunque el contenido no haya cambiado; una rama modificada que conserva la marca vuelve a tener el árbol de la unidad; y una a la que le quitaron la marca no se escribe |
| TU24 | Con la disposición real de un agente (el archivo de secretos en la raíz del workspace y ninguno en el directorio de estado), `identity` sube los secretos cifrados, su descifrado coincide con el original y el centinela no aparece en claro |
| TU25 | Un cambio en el archivo de secretos hace que el supervisor dispare `identity`; después de un respaldo correcto, no la vuelve a disparar |
| TU26 | Sin cambios de contenido, una credencial que dejó de servir da `unreachable` en el ciclo siguiente, y cuando vuelve a servir da `no-change` (SC-006) |
| TU27 | `config` con repositorio incluye la lista cerrada del directorio `.claude/` del workspace, y nada más de ese directorio |
| TU28 | Las rutas adicionales llegan cifradas bajo `extra/`; una entrada absoluta, con `..`, inexistente, no permitida (también `.` y las formas sin normalizar) o que sale del workspace se omite con su aviso |
| TU29 | Con repositorio, el crontab tiene la línea diaria de `identity`, salvo con `enabled: false` explícito, y un cambio en caliente de otra clave la conserva |
| TU30 | Un segundo ciclo de `memory` en el que solo cambiaron archivos volátiles de claude-mem no crea commits |
| TU31 | Cada archivo versionado bajo `docker/scripts/` tiene su línea `COPY` en el Dockerfile |
| TU32 | Con repositorio, `--configure-key` muestra la huella de la llave y deja a `identity` en modo `full` |
| TU33 | Una unidad en claro que perdió su estado no crea commits, completa su estado desde el destino y en el ciclo siguiente no hace ningún `fetch`; una unidad con almacén, en el mismo caso, no sube ningún bloque |
| TU34 | Tras un intento fallido, también el de un agente sin credencial, el supervisor no vuelve a disparar `identity` por el mismo contenido antes de 15 minutos; un contenido nuevo la dispara de inmediato; un estado ilegible no lo hace fallar; y el tope del disparador es 300 segundos con repositorio y 90 con fork |
| TU35 | En un agente sensible, `backup/config` trae solo la marca, `agent.yml` y `store/`, y el centinela de la persona no aparece; sin llave pública termina en `no-recipient` |
| TU36 | Un empuje de `identity` o de `vault` que el servidor no responde termina en su tope con `push-failed`, deja su registro y suelta el candado |
| TU37 | Con el candado de la unidad tomado, una corrida avisa, sale con 0 y no escribe nada; al soltarse, la siguiente corre |
| TU38 | Un `~/.gitconfig` con una redirección `insteadOf` y con firma obligatoria no cambia el resultado de un respaldo con repositorio |
| TU39 | `memory` e `history` sin credencial, con un repositorio público, con una rama ajena y con una rama de otro agente: el resultado correcto y ningún empuje. Sin ninguna fuente, `nothing-to-back-up`. Un empuje de `history` que el servidor no responde termina en su tope |
| TU40 | Tras cambiar la llave del operador con `--configure-key`, el ciclo siguiente de una unidad con almacén lo cifra todo de nuevo, y se abre con la llave nueva y no con la anterior. Si alguien reemplaza en la rama la parte pública de la llave de datos, el ciclo siguiente rota, y la llave ajena no abre nada |

### `tests/backup-repo-restore.bats`

| Id | Afirma |
| --- | --- |
| TR01 | Restauración completa con llave: lo que viaja tal cual coincide por hash con su origen, y lo capturado coincide con `digest --list` (SC-002) |
| TR02 a TR04 | Falta una unidad, falta la llave o falta `python3`: lo demás se restaura y el motivo queda dicho |
| TR05 | Una falla de integridad no deja archivos parciales |
| TR06 | La restauración desde un fork con tres ramas da la salida de `main`, comparada con un archivo dorado |
| TR07 a TR09 | El alias `--restore-from-repo`, un vault cifrado, y que una restauración trae el contenido de sus unidades sin copiar la marca ni los archivos de la llave de datos |
| TR10 | El archivo de secretos restaurado queda en la raíz del workspace, con modo 0600 y el mismo hash que el original; sin token de Claude, sale su aviso |
| TR11 | El directorio `.claude/` de proyecto se restaura en la raíz |
| TR12 | Las rutas adicionales vuelven a su ruta, también una bajo `.state/`; una ruta lógica absoluta o con `..` se rechaza |
| TR13 | La configuración cifrada de un agente sensible: con llave vuelve completa; sin llave vuelve solo `agent.yml`, con su línea |
| TR14 | En una unidad mixta sin llave, lo que va en claro se restaura y lo cifrado se omite; al terminar no queda el directorio temporal, tampoco tras una falla; y un override restaurado deja su aviso |

### `tests/agent-repo-surface.bats`

| Id | Afirma |
| --- | --- |
| TA01 a TA03 | El wizard: muestra la pregunta y sin asociación no cambia nada; con asociación pide el token; y con una URL inválida sin terminal termina con código 1 en vez de quedarse preguntando. Su validador da el mismo resultado que la librería para cada URL de la tabla compartida |
| TA04 y TA05 | `--regenerate` completa las claves sin pisar un `false`, y el esquema valida los tipos y la regla de la URL |
| TA06 | Sin repositorio, la sección de respaldos del `CLAUDE.md` renderizado es idéntica byte a byte a la de `origin/main`, comparada con un archivo dorado, y el archivo no trae ninguna cadena nueva (SC-004) |
| TA07 y TA08 | Con repositorio aparecen las dos secciones, con el aviso de lo que no se cubre; la URL y la ruta del clon aparecen renderizadas en `CLAUDE.md` y en `NEXT_STEPS.md`, y no queda ningún `{{` |
| TA09 | En un agente nuevo, la llave pública se obtiene del dueño del repositorio, y se muestra su huella |
| TA10 a TA12 | El clon de trabajo: se crea con sus dos configuraciones; no toca uno existente, y `backup-config` lo vuelve a crear si falta; y el agente empuja desde él sin que la credencial quede en `.git/config` |
| TA13 a TA15 | El `.gitignore`, el render del modo local sin ninguna cadena nueva (FR-019), y las filas nuevas de `NEXT_STEPS.md` con la línea de `GITHUB_PAT` del ejemplo de secretos |
| TA16 | En modo local el wizard no hace la pregunta; con una URL en `agent.yml`, el contexto del agente no gana la sección del repositorio y regenerar deja la advertencia; y con la marca de datos sensibles, regenerar advierte que no se honra |
| TA17 | `backup.extra_paths` se completa con una lista vacía, y el esquema rechaza un valor que no es una lista |
| TA18 | En modo docker, `--regenerate` avisa si falta la llave pública o `GITHUB_PAT`, sin mostrar ningún valor, y no fija ninguna llave |
| TA19 | El clon de trabajo ante un repositorio vacío, uno que solo tiene ramas de respaldo, uno con otra rama por defecto y uno cuya rama por defecto es de respaldo: nunca queda extraída una rama `backup/*` |
| TA20 | `--uninstall --nuke` avisa si el clon de trabajo tiene commits sin publicar o archivos sin commitear |

### `tests/backup-status.bats`

| Id | Afirma |
| --- | --- |
| TB01 y TB02 | La forma del JSON con repositorio, con fork y sin destino |
| TB03 y TB04 | El umbral de antigüedad y el último intento fallido |
| TB05 | Los commits sin publicar y los archivos sin commitear del clon de trabajo |
| TB06 | El valor centinela de la credencial no aparece en la salida |
| TB07 y TB08 | Las líneas del diagnóstico con repositorio, y la salida de `main` sin repositorio |
| TB09 | `backup-status` informa cuántas rutas adicionales hay declaradas y cuáles no existen |
| TB10 | `backup-status` informa el tamaño de cada caché; el diagnóstico advierte cuando la suma pasa del umbral y cuando falta el clon de trabajo; y si el comando falla con el contenedor arriba, lee los archivos de estado |

### Pruebas que nacen en verde

Ocho pruebas guardan que algo **no** cambie, así que pasan también contra `origin/main`: TU05, TU19, TU20, TU31, TR06, TA06, TA14 y TB08. El catálogo de mutaciones prueba que cada una puede fallar. Todas las demás se ven en rojo antes del código que las hace pasar.

### Pruebas existentes que cambian

- `wizard_answers()` de `tests/helper.bash` y el arreglo de `tests/e2e-smoke.bats`: una respuesta más.
- `tests/schema.bats`: los marcadores derivados en sus dos listas `known_external`, y `backup` en la lista de claves de primer nivel de `sample-agent-with-vault.yml`.
- `tests/quickstart-doc.bats`: el validador nuevo, el bloque nuevo y el marcador nuevo de `wizard_answers()`.
- `tests/fixtures/sample-agent.yml` y `sample-agent-with-vault.yml`: las claves nuevas.
- `tests/nightly-alert.bats:1431` (N30), que fija la lista de ids de los pasos del nightly: gana `install_age` entre `install_bats` y `verify_deps` (V4). Las otras dos que miran ese workflow (`tests/ci-workflows.bats` y `tests/qmd-embed-nightly.bats`) siguen en verde sin editarse.

Ninguna otra prueba existente se edita. Las de respaldo y restauración que ya existen son el control de que el camino del fork no cambió.

### Archivos dorados

La CI clona sin historia, así que una prueba no puede comparar contra `origin/main`. Lo que debe quedar "idéntico al de `main`" se compara con archivos generados una vez desde `origin/main` `10f22a7` y commiteados en `tests/fixtures/backup-repo/`:

| Archivo | Qué guarda |
| --- | --- |
| `agent-fork.yml` y `crontab-fork.golden` | Un `agent.yml` con fork y el crontab que le genera `heartbeatctl reload` |
| `claude-md-backups-section.golden` | La sección de respaldos del `CLAUDE.md` renderizado |
| `restore-fork-output.golden` | La salida de una restauración desde un fork de tres ramas |

La comparación completa de todos los archivos derivados contra `origin/main` es una medición del cierre local, no una prueba.

### Conteo esperado

La línea base se mide al comenzar la implementación, en una copia aislada de `origin/main` y en los dos bash. El total esperado es esa línea base más las pruebas nuevas, con 0 `not ok` en bash 3.2 y en 5.x (SC-009).

| Suite | Pruebas |
| --- | --- |
| `tests/backup-dest.bats` | 18 |
| `tests/backup-store.bats` | 22 |
| `tests/backup-repo-units.bats` | 40 |
| `tests/backup-repo-restore.bats` | 14 |
| `tests/agent-repo-surface.bats` | 20 |
| `tests/backup-status.bats` | 10 |
| **Host** | **124** |
| `tests/docker-e2e-backup-repo.bats` (saltadas en el host) | 8 |
| **Total que suma la suite** | **132** |

## V3. Mutaciones

Cada mutación se aplica sobre una copia, y debe hacer caer al menos una prueba en los dos bash. La lista vive en un solo lugar, [tasks.md](../tasks.md), para que no haya dos copias que se separen. Estas son las reglas que esa lista cumple:

- **Una variante por fila**: una fila que dice "A o B" son dos mutaciones.
- **Toda prueba tiene su mutación**: cada una de las 124 cae con al menos una, incluidas las ocho que nacen en verde.
- **Toda guardia de seguridad tiene la suya**: la credencial, la privacidad, la marca de pertenencia, el cifrado, la rotación de la llave de datos, el candado, el plazo del supervisor y las rutas adicionales.
- **El control**: las pruebas finales contra el código de `origin/main` caen todas, salvo las ocho que nacen en verde.
- **La clase SIGPIPE** se planta con un comando externo, no con un builtin, y cada doble de prueba usa valores distintos para cada fuente.

## V4. Prueba de extremo a extremo

`tests/docker-e2e-backup-repo.bats`, con `DOCKER_E2E=1`. El servidor de V1 corre en el host, y el contenedor lo alcanza por `host.docker.internal`, que la prueba agrega al compose del agente de prueba con `host-gateway`.

| Id | Afirma |
| --- | --- |
| TE1 | Con repositorio asociado, un ciclo forzado deja las cinco ramas con su marca, y la de identidad trae los secretos cifrados |
| TE2 | Un segundo ciclo no crea commits |
| TE3 | El arranque crea el clon de trabajo con sus dos configuraciones, el agente empuja una rama de trabajo, y las cabezas de las ramas de trabajo no cambian por los respaldos |
| TE4 | Con la credencial equivocada, las unidades terminan dentro del tope y el contenedor sigue sano, sin reinicios |
| TE5 | En un agente sensible, ningún objeto de las ramas de respaldo contiene los centinelas del vault, de las memorias, del historial ni de la persona |
| TE6 | Una unidad lanzada por `crond` empuja: el trabajo recibe la credencial |
| TE7 | La restauración en un directorio del host, desde el repositorio que llenó el contenedor, coincide con las dos listas de R7 de [restore.md](restore.md) |
| TE8 | `backup-status --json` dentro del contenedor, sin el valor de la credencial en su salida ni en los logs |

- El total del e2e pasa de 54 a 62 casos.
- **El nightly**: TE7 descifra en el runner, y el workflow `docker-e2e` no instala `age` (M21 de [research.md](../research.md)). Gana un paso propio que lo instala, sin tocar el texto de los pasos que otras features congelaron. La primera nocturna posterior al merge debe decir `total=62 executed=62 skipped=0`.

## V5. Gate previo al merge, piloto de consola en el M4

Es un paso del operador, con compuerta, aprobado el 16-11-2026 en sustitución del objetivo linus. Se usa un agente aislado con datos sintéticos y el repositorio privado real `rodrigo-hinojosa/agentic-046-recovery-gate`; no se acredita el contenido vivo de ferrari. Aplican [P1 a P5](local-pilot.md). Lo que debe quedar registrado:

1. el workspace aislado, la imagen etiquetada aparte y sus hashes contra la fuente validada, sin sustituir imágenes o archivos de agentes existentes;
2. las cabezas de `main` y de las demás ramas de trabajo en GitHub, anotadas **antes** de fijar `backup.repo.url`;
3. la asociación del repositorio del piloto y la llave pública M4 fijada con `--configure-key`, cuya privada ya abrió la prueba sintética del operador;
4. el `CLAUDE.md` vivo del agente, con la sección `## Your repository`;
5. un ciclo forzado de las cinco unidades, con el commit de cada rama en GitHub y la duración de cada empuje;
6. las cabezas de las ramas de trabajo, iguales a las del punto 2;
7. un segundo ciclo sin commits;
8. el ensayo de restauración de R7 de [restore.md](restore.md), con sus dos comparaciones, incluido el archivo de secretos, sin mostrar su contenido;
9. la medición de M5: si un historial restaurado se retoma con `claude -p --continue`, con autorización de cuota separada;
10. cuántos bloques del historial se reutilizaron entre dos ciclos con conversación de por medio;
11. el contenedor de consola activo, con 0 reinicios y sin escritores de mantenimiento; declarar que no tiene canal ni supervisor en ejecución;
12. el inventario cerrado de datos de prueba y su extra path, con las decisiones de cobertura; los inventarios de agentes vivos quedan en V6;
13. la revisión de los archivos sintéticos que viajan en claro. La revisión de la lista viva de identidad/configuración de cada agente se conserva en V6.

Si el punto 9 falla, SC-002 se enmienda antes del merge. Si falla cualquiera de los demás, no se propone el merge.

## V6. Despliegue, después del merge

Antes de ampliar a donna y cbum, linus completa el gate operacional que no cubre el piloto: respaldo de imagen `agentic-pod:linus-pre046` y archivos de sistema, cabezas remotas previas, inventario de FR-026 con decisión de cada entrada y del clon con trabajo sin publicar, revisión de archivos en claro, actualización y overlay, asociación, llave, ciclos y restauración comparada del estado real, salud del canal y doctor. Ante una falla se vuelve a la imagen y archivos guardados y se detiene la ampliación. No marcar estos puntos hechos por los datos sintéticos del M4.

Un agente a la vez, con el procedimiento de actualización del `README.md` y el reinicio de la flota (stop, 150 s, up):

| Agente | Repositorio | Marca de datos sensibles | Particularidad |
| --- | --- | --- | --- |
| linus | `linus-workspace-agent-admin` | No | Gate operacional pendiente antes de ampliar a donna/cbum; su clon actual en `/workspace/linus-workspace-agent-admin` tiene un commit local posterior al remoto y se revisa a mano |
| donna | `donna-workspace-agent-admin` | No | Su primer empuje de historial es el más grande; su clon actual en `~/donna-workspace-agent-admin` está atrasado; declara como rutas adicionales su overlay y la configuración de su feature de costos (M16 de [research.md](../research.md)); después de regenerar hay que volver a aplicar su overlay |
| cbum | Uno nuevo, que crea el operador con un commit inicial en `main` | Sí | El operador ajusta la regla de su persona que prohíbe subir datos de salud a un repositorio |

Para cada agente:

- antes de asociar el repositorio se hace el inventario de D22 y se decide qué rutas adicionales declarar;
- la llave pública se fija con `--configure-key`, y el operador confirma su huella;
- se comprueba que el `CLAUDE.md` vivo ganó la sección `## Your repository`. Si el agente lo tenía editado, `--regenerate` lo preserva y hay que forzar el render;
- se le avisa al agente, o se corrige su auto-memoria, que su clon de trabajo es ahora `/workspace/agent-repo`;
- se registra el primer respaldo verificado de cada unidad, las ramas de trabajo intactas y 24 horas sin reinicios (SC-010).
