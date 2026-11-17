# Research: Un repositorio privado por agente para su trabajo y su respaldo completo

**Feature**: `046-agent-backup-repo` | **Fecha**: 2026-11-13 | **Spec**: [spec.md](spec.md)

Este documento reúne lo que se midió y se leyó para diseñar la feature, y las decisiones que salen de ahí. Cada medición dice dónde se hizo. Nada de lo medido tocó un agente: todo fue de solo lectura, o corrió en un directorio temporal del Mac. Las mediciones M13 a M18 y las decisiones D19 a D26 salieron al generar las tareas. Las mediciones M19 a M21 y las decisiones D27 a D36 salieron del análisis de consistencia del 14-11-2026.

## Mediciones

### M1. Sin credencial, el acceso al repositorio privado falla (medido)

En el Mac, con `git` 2.50.1, sin configuración global ni ayudante de credenciales, y con las mismas variables que usan las librerías (`GIT_TERMINAL_PROMPT=0` y un `GIT_ASKPASS` que no responde):

```text
git ls-remote https://github.com/rodrigo-hinojosa/linus-workspace-agent-admin
rc=128  fatal: could not read Username for 'https://github.com': terminal prompts disabled
```

Confirma la inferencia del spec: un respaldo en modo docker contra un repositorio privado de GitHub falla hoy por autenticación, porque las librerías no entregan ninguna credencial.

Hallazgo lateral: las librerías fijan `GIT_ASKPASS=/bin/true`. Esa ruta existe en la imagen (busybox) y no existe en macOS, donde `true` está en `/usr/bin`. En macOS git avisa `cannot exec '/bin/true'` y termina igual sin preguntar, así que el efecto es el mismo.

### M2. Un askpass que lee la credencial del entorno autentica contra GitHub (medido)

Un script de seis líneas responde a las dos preguntas de git: a `Username*` contesta `x-access-token` y a `Password*` contesta el valor de una variable de entorno. Con ese script en `GIT_ASKPASS`:

| Caso | Resultado |
| --- | --- |
| `git ls-remote` del repositorio privado, usuario `x-access-token` | rc 0, 1 referencia |
| El mismo, con usuario `git` | rc 0, 1 referencia |
| Veces que el valor de la credencial aparece en la traza de git (`GIT_TRACE=1`) | 0 |

La credencial de la prueba fue la del `gh` del operador, que nunca se imprimió. La de los agentes es un token personal (`GITHUB_PAT`) y usa el mismo mecanismo de autenticación básica por https.

Un error del primer intento que conviene recordar: en `VAR=valor env -i ... VAR="$VAR" comando`, el shell expande `"$VAR"` antes de aplicar la asignación del prefijo, así que el comando recibe la variable vacía. La credencial se exporta en un subshell.

### M3. Un servidor git local con autenticación sirve como doble de prueba (medido)

Prototipo: un servidor HTTP en Python (solo biblioteca estándar, sin `HTTPServer.server_bind`) que valida la contraseña de la autenticación básica y pasa cada petición a `git http-backend`. En el Mac, sobre un directorio temporal:

| Caso | Resultado |
| --- | --- |
| `ls-remote` sin credencial | rc 128; el servidor responde 401 |
| `ls-remote` con la credencial equivocada | rc 128 |
| `clone` con el askpass | rc 0 |
| `push` de una rama huérfana con un archivo de 5 MB | rc 0; la rama existe en el servidor (un POST de 5.244.921 bytes) |
| Valor de la credencial en la traza de git, en la configuración del clon y en la URL del remoto | 0 apariciones |
| Valor de la credencial en el log del servidor | 0 apariciones |

Con esto las pruebas del host pueden ejercer el empuje autenticado real, sin GitHub y sin Docker. El prototipo está en el scratchpad de la sesión y la versión de la feature va en `tests/fixtures/backup-repo/git-auth-server.py`.

`git-http-backend` existe en el Mac (viene con el git de Xcode). En la imagen del agente no existe (medido en linus: `/usr/libexec/git-core/git-http-backend` no está), así que en la prueba de extremo a extremo el servidor corre en el host y el contenedor lo alcanza por `host.docker.internal`.

### M4. Límites del servicio (leído en la documentación de GitHub, 13-11-2026)

- Git avisa cuando un archivo supera 50 MiB.
- GitHub bloquea los archivos de más de 100 MiB.
- Recomienda que un repositorio quede bajo 1 GB, y "recomienda fuertemente" que quede bajo 5 GB.
- La página no fija un límite para el tamaño de un empuje.

### M5. Cómo guarda y retoma sesiones Claude Code (leído en su documentación; sin medir)

- Los historiales son archivos JSONL en `<config>/projects/<proyecto>/<id-de-sesión>.jsonl`, donde `<proyecto>` es la ruta del directorio de trabajo con los caracteres no alfanuméricos reemplazados por `-`. Para `/workspace` eso da `-workspace`, que es lo medido en los contenedores.
- `claude --continue` reabre la sesión más reciente del directorio actual, y `claude --resume <ruta>` acepta la ruta absoluta de un `.jsonl`.
- Al retomar, una sesión compactada continúa desde el resumen de la última compactación, así que retomar no exige cargar todo el archivo.
- Los historiales tienen una retención de 30 días por defecto (`cleanupPeriodDays`); en donna no está configurada, así que rige el valor por defecto.
- El formato de cada línea es interno y cambia entre versiones: el respaldo trata los archivos como bytes y no los interpreta.

Lo que **no** está medido: que un historial copiado a un directorio de configuración nuevo se retome con `--continue`. Medirlo exige una sesión autenticada. En el Mac del operador eso obligaría a tocar su configuración real, y en un agente gastaría cuota de su suscripción. Se mide en el gate previo al merge (ver D18), y SC-002 queda condicionado a esa medición.

### M6. Herramientas de la imagen (medido en donna)

| Herramienta | Estado |
| --- | --- |
| `git` | 2.54.0 |
| `age` | 1.3.2 |
| `python3` | 3.14.10, con el módulo `sqlite3` (SQLite 3.53.4) |
| `gzip`, `split`, `sha256sum`, `tar`, `curl`, `jq`, `yq`, `bun` | presentes |
| `sqlite3` (línea de comandos), `openssl`, `zstd`, `xz` | ausentes |
| `git-http-backend` | ausente |
| `/tmp` | tmpfs de 100 MB, con 91,7 MB libres |

En el Mac del operador: `python3` 3.9.6 (el del sistema) y `age` en `/opt/homebrew/bin`. La herramienta de la feature tiene que correr en Python 3.9 (host) y en 3.14 (imagen).

### M7. Forma y tamaño de lo que hay que respaldar (medido en donna)

| Dato | Detalle |
| --- | --- |
| Historial, archivo principal | Un `.jsonl` de 71.952.401 bytes (68,6 MiB) y 7.152 líneas. La línea más larga mide 5.591.856 bytes |
| Historial, carpeta de la sesión | 32,6 MB en `subagents/` y `tool-results/` (86 archivos) |
| Compresión del historial | `gzip` lo deja en 37.333.138 bytes (52 %), en 3 segundos |
| Base de claude-mem | `claude-mem.db` de 13.926.400 bytes, más su `-wal` (4 MB) y su `-shm`. `gzip` la deja en 4.223.479 bytes (30 %) |
| Resto de `~/.claude-mem` | `logs/` 7,7 MB; `backups/` 308 KB; `state/`, `observer-sessions/`, `corpora/`, `settings.json` y marcadores, menos de 40 KB en total |
| Auto-memoria | 3 archivos, 16 KB, en `projects/-workspace/memory/` |

El historial se comprime mucho menos de lo que se esperaba, probablemente porque lleva adjuntos codificados en líneas de varios megabytes.

### M8. Los agentes sin fork ya corren los cron de respaldo (medido en cbum y donna)

El crontab de un agente sin fork tiene las líneas de `backup-vault` (cada hora) y de `backup-config` (diaria). Cada corrida termina con `agent.yml has no scaffold.fork.url — nothing to back up to` en su propio log: `backup-vault.log` tiene 63 líneas en cbum y 2.157 en donna. `backup-identity.log` no existe, porque el watchdog omite la unidad de identidad cuando no hay fork.

**Esto corrige el spec.** El primer borrador decía que un agente sin fork y sin repositorio "no escribe ninguna línea". Lo correcto es que no empuja nada y que sus logs reciben las mismas líneas que hoy.

### M9. Llaves públicas del operador (medido, dato público)

`https://github.com/rodrigo-hinojosa.keys` lista 5 llaves: 4 `ssh-ed25519` y 1 `ssh-rsa`. `fetch_github_ssh_key` (`setup.sh:187-205`) toma la primera `ssh-ed25519`. Nada indica a qué equipo corresponde, así que el operador puede terminar cifrando para una llave cuya parte privada no tiene a mano.

### M10. Cómo clonan hoy las unidades (leído en código)

Cada unidad clona el repositorio entero una vez (`git clone --no-checkout`, por ejemplo `scripts/lib/backup_vault.sh:137`) y después trae solo su rama. Contra el repositorio de un agente, ese primer clon traería todas las ramas de trabajo y el historial completo de las demás ramas de respaldo, una vez por unidad.

### M11. Un fork de un repositorio público no puede ser privado (leído en código)

`setup.sh:646-649` lo documenta ("GitHub 422") y por eso el wizard detecta la visibilidad del template antes de crear el fork. El spec lo tenía como "registrado, sin reverificar".

### M12. `GITHUB_PAT` solo se escribe si el MCP de GitHub está activo (leído en código)

`setup.sh:1333` escribe `GITHUB_PAT` en el archivo de secretos solo cuando `github_enabled` es verdadero. Un agente con repositorio asociado y sin el MCP de GitHub quedaría sin credencial.

### M13. El archivo de secretos no está donde la unidad de identidad lo busca (medido en los tres agentes, 13-11-2026)

La unidad de identidad lee el archivo de secretos dentro del directorio de estado (`docker/scripts/lib/backup_identity.sh:72,152-154`), y los dos lugares que la llaman le pasan `/workspace/.state` (`docker/scripts/heartbeatctl:60` y `docker/scripts/start_services.sh:1154`).

| Dato | donna | linus | cbum |
| --- | --- | --- | --- |
| Archivo de secretos en la raíz del workspace | presente, legible por `agent` | presente, legible por `agent` | presente, legible por `agent` |
| Archivo de secretos dentro del directorio de estado | ausente | ausente | ausente |

Ningún código copia el archivo al directorio de estado (búsqueda en todo el árbol versionado: solo lo nombran la propia librería y sus pruebas).

**Consecuencia**: en un agente docker real la unidad nunca genera el archivo cifrado de secretos, aunque tenga llave pública. El modo `full` no cifra nada. Las pruebas no lo ven por dos razones: las del host escriben el archivo dentro del directorio de estado (`tests/backup-identity-git.bats:88`), y la de extremo a extremo corre sin llave (`tests/docker-e2e-backup-identity.bats:60`). La restauración, en cambio, sí escribe en la raíz del workspace (`setup.sh:1820`).

**Esto corrige el diseño**: ver D19. Solo se midió la presencia de los archivos, nunca su contenido.

### M14. Cómo se autentican los agentes (medido, solo presencia)

| Agente | `CLAUDE_CODE_OAUTH_TOKEN` en el entorno | Archivo de login que deja `/login` |
| --- | --- | --- |
| linus | definida | ausente |
| donna | definida | presente, sin cambios desde el 12-09-2026 |
| cbum | definida | presente, del 12-11-2026 |

Los tres llevan el token de Claude en su archivo de secretos, así que restaurar ese archivo les devuelve la sesión. El archivo de login no está en la lista de la unidad de identidad (`backup_identity.sh:33-36`).

### M15. El archivo de configuración vivo de Claude no es el que respalda la unidad (medido)

Con `CLAUDE_CONFIG_DIR=/home/agent/.claude`, Claude Code guarda su configuración global en `/home/agent/.claude/.claude.json`, que pesa de 72 a 76 KiB. El `.claude.json` de la lista de identidad es otro: `/home/agent/.claude.json`, un archivo de 389 a 509 bytes que no cambia desde el arranque del contenedor.

Las copias que Claude Code deja en `.claude/backups/` muestran cada cuánto reescribe el archivo vivo:

| Agente | Reescrituras observadas |
| --- | --- |
| linus y cbum, sin conversación | Una cada 6 horas |
| donna, durante una conversación | 16:28, 16:29, 16:30, 16:33 y 16:34 del 13-11-2026: hasta una por minuto |

El arranque vuelve a sembrar en ese archivo lo que el launcher necesita (`pre_seed_onboarding`, `docker/scripts/start_services.sh:542`).

**Consecuencia**: los archivos de la lista de identidad casi no cambian entre arranques, así que la unidad empuja poco. El archivo vivo no se agrega a la lista: haría empujar a la unidad una vez por minuto mientras el agente conversa.

### M16. Estado del agente que ninguna unidad cubre (medido, solo nombres y tamaños)

| Agente | Qué | Dónde |
| --- | --- | --- |
| donna | El overlay de `custom-config`, con las credenciales de Google de sus MCP | `/workspace/.custom/` |
| donna | La configuración de una feature propia, `registro-costos` | `/home/agent/.config/donna/` |
| donna | Un skill de proyecto propio | `/workspace/.claude/skills/registro-costos` |
| donna | Adjuntos descargados por el MCP de Google y recibidos por Telegram | `/home/agent/.workspace-mcp/` (2,2 MB) y `.claude/channels/telegram/inbox/` (3,6 MB) |
| linus | Configuración de proyecto de Claude: agentes, comandos y skills | `/workspace/.claude/` |
| linus | Otros clones | `/workspace/repos/` y `/workspace/linus-workspace-agent-admin/` |
| cbum | Nada fuera de las rutas conocidas | No aplica |

El launcher no puede saber de antemano dónde guarda su estado una feature que el agente se construyó. Ver D21 y D22.

### M17. El directorio de claude-mem tiene más de una base y archivos que cambian solos (medido en cbum)

- Además de `claude-mem.db`, hay una segunda base, `work-view-reviews.db`.
- El worker reescribe varios archivos sin que haya conversación: `worker.pid`, `worker-heartbeat.json`, `observer-health.json`, `supervisor.json`, `telemetry.json`, `telemetry-daily.json` y el directorio `run/`.

Ver D23.

### M18. La copia de una base SQLite con la API de respaldo es determinista (medido en el Mac)

Con Python 3.9.6 y SQLite 3.51.0, sobre una base de prueba en un directorio temporal:

| Caso | Resultado |
| --- | --- |
| Dos copias seguidas de una base sin cambios, en modo WAL y con un escritor abierto | El mismo SHA-256; `integrity_check` da `ok` |
| Una copia después de agregar 10 filas | Otro SHA-256, con las 10 filas |
| Una copia antes y otra después de que el escritor cierra y se vacía el WAL | El mismo SHA-256 |
| Copia en bruto del archivo principal, sin su `-wal` | No sirve: la tabla no existe en la copia |

Con esto, una base sin cambios no produce un respaldo nuevo, y el vaciado del WAL tampoco. En la imagen (Python 3.14.10 y SQLite 3.53.4) lo comprueba la prueba de extremo a extremo, con un segundo ciclo que no debe crear commits.

### M19. `age` pide la passphrase de una llave ssh en cada invocación (medido en el Mac, 14-11-2026)

Con `age` 1.3.1 y un par `ssh-ed25519` de prueba con passphrase, en un directorio temporal:

| Caso | Resultado |
| --- | --- |
| Descifrar 3 bloques, una invocación por bloque, con terminal | 3 preguntas por la passphrase; los 3 bloques se recuperan |
| Descifrar 1 bloque sin terminal | Código 1; no descifra |

`age` no usa `ssh-agent`. Con un bloque por megabyte, restaurar el historial de donna pediría la passphrase más de cien veces. Ver D27.

### M20. La imagen trae lo que necesitan la llave de datos y el candado (medido en los tres agentes, 14-11-2026)

| Herramienta | Estado |
| --- | --- |
| `age-keygen`, `flock` y `timeout` | Presentes, en `/usr/bin` |
| `age` | 1.3.1 en linus; 1.3.2 en donna y en cbum |
| `~/.gitconfig` del agente | No existe en ninguno de los tres |

En el Mac del operador no hay `timeout`, `gtimeout` ni `flock` (medido el 14-11-2026). Las pruebas del host llevan los suyos.

### M21. Lo que el análisis leyó en el código (14-11-2026)

- `configure_identity_backup` solo se llama desde el scaffold (`setup.sh:2005`). `--regenerate` no fija la llave pública.
- El supervisor lanza la unidad de identidad con `timeout 90` (`docker/scripts/start_services.sh:389`), y la vuelve a lanzar cada vez que el hash difiere del registrado, con un único freno de 60 segundos (`:1137` y `:1164-1167`).
- `ask_validated` no termina al llegar al fin de la entrada: vuelve a preguntar para siempre (`scripts/lib/wizard.sh:76-94`).
- El diagnóstico sale con código 2 antes de su parte de respaldos si el contenedor no existe o no corre (`scripts/agentctl:440` y `:452`).
- El nightly `docker-e2e` instala `yq` y `bats`, y no instala `age` (`.github/workflows/docker-e2e.yml:65-81`).
- El motor de plantillas reemplaza por nada un bloque condicional que no se renderiza, y deja los saltos de línea que rodean a sus etiquetas (`scripts/lib/render.sh:170-172`). El bloque de docker de `modules/next-steps.*.tpl` ya es un solo `{{#if}}`, y el motor no admite anidarlos.
- `tests/schema.bats:21-36` fija las claves de primer nivel de `tests/fixtures/sample-agent-with-vault.yml`, y `tests/quickstart-doc.bats:164-177` fija la lista de validadores del wizard.

## Decisiones

### D1. La asociación vive en `agent.yml`, bajo `backup.repo`

- **Decisión**: claves nuevas `backup.repo.url`, `backup.repo.allow_unverified` y `backup.sensitive`, más `features.memory_backup.{enabled,schedule}` y `features.history_backup.{enabled,schedule}`. El detalle está en [data-model.md](data-model.md).
- **Razón**: Principio I. `backup.identity.recipient` ya vive bajo `backup`, y los interruptores de las unidades existentes ya viven bajo `features.*_backup`.
- **Alternativa descartada**: reutilizar `scaffold.fork.url`. Mezclaría dos conceptos que el operador pidió separar, y `--sync-template` trataría el repositorio del agente como un fork del template.

### D2. Una sola regla de destino, en una librería nueva

- **Decisión**: `docker/scripts/lib/backup_dest.sh` define `backup_dest_resolve`, que responde `repo <url>`, `fork <url>` o `none`. Las cinco unidades, el watchdog y `backup-status` la llaman. La librería también entrega las variables de entorno de git, la comprobación de privacidad y la marca de pertenencia.
- **Razón**: FR-002 pide una sola regla. Hoy la lectura de `scaffold.fork.url` está repetida en siete lugares.
- **Límite**: la librería no arma árboles, no hace commits, no empuja y no calcula el hash de ninguna unidad. Lo único que escribe en el archivo de estado de una unidad es el registro de su último intento. Cada unidad conserva su librería, su rama, su caché y su archivo de estado.
- **Alternativa descartada**: repetir la regla en cada unidad. Cinco copias de una regla con tres casos se desincronizan.

### D3. La credencial llega a git por un askpass que lee el entorno

- **Decisión**: un script horneado, `docker/scripts/git-askpass-agent.sh`, responde las preguntas de git con `x-access-token` y con el valor de `GITHUB_PAT`. Las unidades lo ponen en `GIT_ASKPASS` solo cuando el destino es un repositorio asociado y la variable existe.
- **Razón**: medido en M2 y M3. El valor no aparece en los argumentos, en la URL ni en la configuración de git, que es lo que exige FR-007.
- **Alternativas descartadas**:
  - una URL con la credencial embebida, como hace el flujo del fork en el host (`setup.sh:1599`): deja el valor en `.git/config`;
  - `http.extraheader`: el valor queda en la configuración o en los argumentos;
  - un almacén de credenciales en disco: es otro archivo con el secreto;
  - `gh`: no está en la imagen.
- **Lo que no cambia**: el destino fork sigue sin credencial, como hoy. Por M1 se infiere que tampoco puede empujar a GitHub desde el contenedor; arreglarlo queda fuera de alcance (FR-018) y se anota como hallazgo lateral.

### D4. La privacidad se comprueba con el propio git

- **Decisión**: el repositorio se considera privado cuando un `ls-remote` sin credencial es rechazado por falta de credencial y uno con credencial funciona. Si el anónimo funciona, es público y no se empuja. Si el anónimo falla por otra razón, no se pudo comprobar y tampoco se empuja (D31). La sonda anónima se guarda con su fecha y se repite cada 24 horas, o antes si cambia la URL o el último veredicto no fue "privado". La consulta autenticada corre en cada ciclo (D20).
- **Razón**: no gasta la cuota de la API y no exige interpretar respuestas con la credencial puesta. El `ls-remote` autenticado es además la comprobación previa de cada unidad: si falla, la unidad termina en segundos (SC-006).
- **Excepción**: `backup.repo.allow_unverified: true` acepta un destino cuya privacidad no se pudo comprobar. Es lo que FR-005 llama aceptarlo de forma explícita. No salta la sonda anónima y nunca habilita un repositorio público (D31).
- **Alternativa descartada**: consultar la API de GitHub. Ata la feature a un proveedor.

### D5. Cada rama de respaldo lleva una marca de pertenencia

- **Decisión**: en un repositorio asociado, la raíz de cada rama de respaldo tiene `.agentic-pod-backup.json`, con el agente y la unidad. Antes de escribir en una rama que ya existe, la unidad lee la marca: si falta, o si nombra a otro agente, no escribe y lo informa.
- **Razón**: FR-004 y dos casos borde (rama ajena con el mismo nombre, y dos agentes en un mismo repositorio).
- **Límite**: en el destino fork no se escribe ni se exige la marca, para que su árbol no cambie (FR-018).

### D6. Cinco unidades: se amplía `config` y se agregan `memory` e `history`

- **Decisión**:
  - `backup/config` suma `personas/`, `CLAUDE.md`, `docker-compose.override.yml` y la configuración de proyecto de Claude (D21), solo cuando el destino es un repositorio asociado;
  - `backup/memory` (nueva) lleva la auto-memoria, el directorio de claude-mem y las rutas adicionales que declare el operador (D22);
  - `backup/history` (nueva) lleva el historial de conversaciones;
  - `backup/vault` conserva su contenido;
  - `backup/identity` conserva su lista de archivos y pasa a cifrar el archivo de secretos real (D19).
- **Razón**: la persona es configuración en claro y cabe en `config`. Las memorias y el historial tienen otro tamaño, otra cadencia y otra sensibilidad: meterlos en `identity` haría que cada cambio de identidad moviera decenas de megabytes.
- **Consecuencia**: el Principio V fija tres ramas. Se enmienda de forma explícita (D15).

### D7. Qué viaja cifrado

- **Decisión**:

  | Contenido | Agente sin marcar | Agente de datos sensibles |
  | --- | --- | --- |
  | `agent.yml` | En claro | En claro |
  | Persona, `CLAUDE.md`, configuración de proyecto de Claude y `docker-compose.override.yml` | En claro | Cifrados (D28) |
  | Identidad | Como hoy: archivos en claro y secretos cifrados | Igual |
  | Vault | En claro, como hoy | Cifrado |
  | Auto-memoria | En claro | Cifrada |
  | Base y estado de claude-mem | Cifrados | Cifrados |
  | Historial | Cifrado | Cifrado |
  | Rutas adicionales (D22) | Cifradas | Cifradas |

- **Razón**: el operador eligió cifrado por agente, con donna y linus en claro. El historial se cifra siempre porque guarda en bruto todo lo que pasó por la conversación, incluidos secretos; es el default declarado en el spec. La base de claude-mem guarda observaciones de esas mismas conversaciones, así que pertenece a la misma clase. Además es un archivo binario: "en claro" no la haría legible en GitHub.
- **Cambio respecto del spec**: el spec decía que en un agente sin marcar "las memorias van en claro". Queda acotado a la auto-memoria, que sí es texto. Se corrige FR-009 y se declara en Assumptions.
- **Sin llave no se sube**: si falta la llave pública del operador, lo que debe ir cifrado no corre (FR-010).

### D8. Un almacén por bloques para lo cifrado

- **Decisión**: lo cifrado se guarda en un directorio `store/` de su rama, con este formato:
  - cada archivo se parte en bloques de 1 MiB;
  - cada bloque se comprime con gzip, se cifra con `age` y se guarda con el nombre del SHA-256 del archivo cifrado (D37; hasta el 15-11-2026, del bloque en claro);
  - un manifiesto cifrado lista cada archivo con su tamaño, su hash y sus bloques;
  - un bloque que ya está en la rama no se vuelve a cifrar ni a subir.
- **Razón**:
  - ningún archivo del repositorio supera 1 MiB, así que el límite de 100 MiB (M4) deja de importar aunque el historial crezca;
  - `age` cifra distinto cada vez: sin una forma de reconocer un bloque ya subido, cada ciclo subiría todo de nuevo (D37: un mapa local);
  - el historial solo crece por el final, así que un ciclo normal sube el último bloque y los nuevos.
- **Costo estimado con los datos de donna**: la primera subida es de unos 55 MB (el historial comprimido, la carpeta de la sesión y la base). Cada ciclo diario sube como máximo 1 MiB del último bloque del historial, lo nuevo del día y los bloques de la base que cambiaron (4,2 MB si cambian todos). Treinta ciclos suman unos 200 MB en el peor caso, bajo el límite de 1 GB de SC-007.
- **Riesgo aceptado, revocado el 15-11-2026 (D37)**: los nombres de los bloques revelaban el hash de su contenido. La revisión independiente mostró que alcanza con adivinar: un archivo de un solo bloque con pocos valores posibles se confirma probándolos, y eso es justo lo que protege la marca de datos sensibles.
- **Riesgo a observar**: si Claude Code reescribe un historial en vez de agregarle líneas, sus bloques cambian todos y ese ciclo sube el archivo entero. Sigue siendo correcto, solo más caro. El gate mide cuántos bloques se reutilizan entre dos días.
- **Alternativas descartadas**:
  - un archivo cifrado por cada archivo de origen: el historial de donna ya pesa 68,6 MiB y se volvería a subir entero cada día;
  - Git LFS: agrega un servicio, una cuota y una dependencia que la imagen no trae;
  - recortar la historia de la rama con empujes forzados: no hace falta. Borrar la rama remota basta, porque el ciclo siguiente la recrea con un solo commit (D35).
- **Con qué llave se cifra**: con una llave de datos propia de cada almacén, no directo con la del operador (D27).

### D9. La herramienta del almacén se escribe en Python

- **Decisión**: `docker/scripts/backup_store.py`, solo con la biblioteca estándar, con los subcomandos `digest`, `pack`, `unpack`, `sqlite-snapshot` y `fingerprint`. Se prueba desde bats, como el parchador de Telegram.
- **Razón**: hace falta manejar bytes por rangos, calcular hashes, comprimir, escribir un manifiesto JSON y copiar una base SQLite en uso. Python ya está en la imagen (M6) y trae todo eso. En bash harían falta `split`, aritmética de rangos y un archivo temporal por bloque, y la copia de SQLite necesitaría Python igual, porque la imagen no trae el cliente de SQLite.
- **Restricción**: tiene que correr en Python 3.9 (el del host del operador, que restaura) y en 3.14 (la imagen).
- **Alternativa descartada**: instalar el cliente de SQLite y hacerlo todo en bash. Agrega un paquete a la imagen y deja la parte binaria en el lenguaje menos apto.

### D10. Capturas consistentes

- **Decisión**:
  - toda base SQLite se copia con la API de respaldo de SQLite (`Connection.backup`), que entrega una copia consistente aunque haya escrituras en curso y un `-wal` pendiente; nunca se copia el archivo en bruto. La herramienta reconoce la base por su cabecera, no por su nombre (D23);
  - cada `.jsonl` se lee hasta su último salto de línea, para que una línea a medio escribir no quede cortada en el respaldo.
- **Razón**: FR-011.

### D11. Clones livianos y un clon de trabajo sin las ramas de respaldo

- **Decisión**:
  - con un repositorio asociado, cada unidad prepara su caché con `git init` más `git fetch --depth 1` de su propia rama;
  - el clon de trabajo del agente vive en `/workspace/agent-repo`. El arranque lo crea si falta, en segundo plano y con tiempo máximo, y le configura dos cosas: una exclusión de `refs/heads/backup/*` en su `fetch`, y un ayudante de credenciales acotado al servidor del repositorio;
  - si el directorio ya existe, el arranque solo asegura esas dos configuraciones y no toca ramas ni archivos.
- **Razón**: por M10, sin esto cada unidad bajaría todas las ramas de trabajo y el historial de las demás ramas de respaldo. El agente, por su parte, no necesita bajar cientos de megabytes cifrados para trabajar.
- **Límite**: el destino fork conserva su forma de clonar.

### D12. El agente publica su trabajo con un ayudante de credenciales acotado

- **Decisión**: `docker/scripts/git-credential-agent.sh` responde al protocolo de ayudantes de git con `GITHUB_PAT`. Se configura solo en el clon de trabajo y solo para el servidor del repositorio (`credential.<servidor>.helper`).
- **Razón**: FR-016. La configuración del clon guarda la ruta del script y no el valor.
- **Alternativa descartada**: exportar `GIT_ASKPASS` en toda la sesión del agente. Autenticaría cualquier operación de git del agente en cualquier repositorio, y eso amplía sus permisos más allá de lo pedido.

### D13. `GITHUB_PAT` se pide aunque el MCP de GitHub no esté activo

- **Decisión**: el wizard pregunta por la asociación justo después del paso del fork. Si el operador asocia un repositorio y no activa el MCP de GitHub, el wizard pide igual el token, y `GITHUB_PAT` se escribe en el archivo de secretos cuando hay MCP o hay repositorio.
- **Razón**: M12 y FR-003.
- **Alcance**: la pregunta solo aparece en modo docker (D25).

### D14. El diagnóstico sale de un solo comando dentro del contenedor

- **Decisión**: `heartbeatctl backup-status [--json]` entrega, por unidad, el destino, el último respaldo correcto y el resultado del último intento; además el veredicto de privacidad, la huella de la llave pública y los commits sin publicar del clon de trabajo. `agentctl doctor` lo llama y lo muestra. Si el contenedor corre y ese comando falla, el diagnóstico lee los archivos de estado. Con el contenedor caído no hay nada que cambiar: el diagnóstico ya termina antes de llegar a los respaldos (M21).
- **Razón**: FR-017, con una sola implementación de la regla de destino (D2).

### D15. Enmienda de la constitución (1.0.1 a 1.1.0)

- **Decisión**: el Principio V pasa de tres a cinco ramas independientes, enumera lo que las unidades pueden compartir (nada que arme árboles, haga commits o empuje), extiende el orden de restauración (config, identity, vault, memory, history) y fija la lista cerrada de lo que viaja cifrado. La línea de "Scope discipline" deja de decir "three".
- **Razón**: FR-020. Es una guía ampliada de forma material, así que el bump es MINOR según la propia constitución.
- **Cuándo**: es la primera tarea de implementación, antes de cualquier cambio de código.

### D16. Restauración

- **Decisión**: `restore_from_fork` gana dos pasos, `memory` e `history`, y aprende a leer la unidad `config` ampliada y un vault cifrado. Lo cifrado se abre con la llave que el operador pasa en `--identity-key`. Se agrega `--restore-from-repo` como alias de `--restore-from-fork`.
- **Requisitos del host**: `python3` 3.9 o superior y `age`. Si falta alguno, o no se pasa la llave, lo cifrado se omite y el resultado lo dice; lo demás se restaura (US3, escenario 3).

### D17. La llave para la que se cifra

- **Decisión**: se sigue usando `backup.identity.recipient`, que ahora vale para todo lo cifrado. Sin fork, `configure_identity_backup` obtiene el dueño de la URL del repositorio asociado. Al elegir una llave de GitHub, el launcher muestra su huella y su comentario y avisa que hay que confirmar que se tiene la parte privada. El operador puede fijar otra con `heartbeatctl backup-identity --configure-key`, que ya existe. Eso vale para un agente nuevo: en uno que ya existe, la llave se fija siempre con ese comando (D29).
- **Razón**: FR-010 y M9.
- **Alternativa descartada**: cifrar para todas las llaves del operador. Exige una lista en `agent.yml` y cambia la unidad de identidad; se puede sumar después.

### D18. Evidencia antes del merge

- **Decisión**: tres niveles, en este orden.
  1. **Suite del host**, con pruebas primero, en bash 3.2 y 5.x. El empuje autenticado se ejerce contra el servidor de M3.
  2. **Prueba de extremo a extremo** en un contenedor real, con el servidor de M3 en el host.
  3. **Gate en linus**, con compuerta del operador: la imagen de la rama, su repositorio real asociado, un ciclo forzado de cada unidad y un ensayo de restauración en un directorio limpio, sin arrancar el canal.
- **La medición pendiente de M5 se hace en ese gate**: el historial restaurado se copia a un directorio de configuración temporal dentro del agente, con los mismos enlaces de autenticación que usa el heartbeat, y se corre `claude -p --continue` desde `/workspace`. Si no retoma la conversación, SC-002 se enmienda antes del merge.
- **Razón**: FR-021 y FR-022. Ninguna prueba ejerce hoy el empuje autenticado, y dos features anteriores (021 y 022) pagaron caro haber hecho el gate real después del merge.

### D19. Con un repositorio asociado, la unidad de identidad cifra el archivo de secretos de la raíz del workspace

- **Decisión**: la librería de identidad recibe la ruta del archivo de secretos como un argumento opcional.
  - Con un repositorio asociado, `heartbeatctl` y el supervisor le pasan el de la raíz del workspace.
  - Sin ese argumento, sigue leyendo el del directorio de estado, como hoy.
  - El nombre del archivo cifrado dentro de la rama no cambia, así que la restauración lo sigue encontrando.
  - La restauración deja el archivo descifrado con modo 0600.
- **Razón**: M13, FR-008 y FR-009. Sin esto el respaldo no lleva ninguna credencial, y un agente restaurado no arranca.
- **Regla derivada**: el supervisor y el comando calculan el mismo hash, con la misma ruta. Si difieren, el supervisor dispara la unidad cada 60 segundos para siempre.
- **Lo que no cambia**: el destino fork conserva el defecto (FR-018). Queda como hallazgo lateral, con su issue.

### D20. Cada ciclo consulta al destino, aunque no haya cambios

- **Decisión**: con un repositorio asociado, cada corrida hace una consulta autenticada de las cabezas del repositorio (`git ls-remote --heads`, con un tope de 60 segundos). De esa consulta salen tres cosas:
  - la comprobación de que la credencial sirve;
  - la mitad autenticada del veredicto de privacidad;
  - la cabeza remota de la rama de la unidad.

  Una unidad solo termina en `no-change` si su hash no cambió **y** la cabeza remota es el commit que tiene registrado. La sonda anónima sigue guardándose 24 horas.
- **Razón**: SC-006 pide que una credencial que dejó de servir se vea en el ciclo siguiente, y la historia 4 pide que una rama de respaldo borrada vuelva en el ciclo siguiente. Con el diseño anterior, un ciclo sin cambios no tocaba la red y no veía ninguna de las dos cosas.
- **Costo**: una consulta liviana por unidad y por ciclo. En un día normal son 24 de `vault` y una de cada una de las otras cuatro. El supervisor no suma consultas mientras la identidad no cambie, y tras un intento fallido espera 15 minutos antes de repetir (D32).
- **Consecuencia para identidad**: con un repositorio asociado tiene su línea diaria de cron, salvo que `features.identity_backup.enabled` sea `false` de forma explícita. Sin esa línea, la unidad solo corre cuando cambia su hash y nunca verificaría el destino.

### D21. `config` incluye la configuración de proyecto de Claude

- **Decisión**: con un repositorio asociado, `backup/config` suma la configuración de proyecto de Claude, que vive en `.claude/` de la raíz del workspace. Entra una lista cerrada: `settings.json`, `skills/`, `commands/`, `agents/`, `hooks/` y `output-styles/`. Todo lo demás de ese directorio queda fuera, incluidos `settings.local.json`, los `*.lock` y `worktrees/`, donde Claude Code deja árboles completos. Va en claro, como la persona, salvo en un agente sensible (D28).
- **Razón**: M16. Es configuración del agente y hoy existe en un solo disco.

### D22. Rutas adicionales que declara el operador

- **Decisión**: `backup.extra_paths` es una lista de rutas relativas a la raíz del workspace.
  - La unidad `memory` las empaqueta en su almacén cifrado, bajo `extra/`.
  - La restauración las devuelve a la misma ruta.
  - Siempre van cifradas, porque el launcher no sabe qué contienen.
  - No se aceptan `.state` entero, nada bajo `.state/.cache`, el clon de trabajo ni una ruta con un componente `.git`: son cachés, o harían que la unidad se respalde a sí misma.
  - El contexto del agente le dice que el estado que cree fuera de las rutas cubiertas no se respalda hasta que el operador lo declare.
  - El despliegue incluye un inventario por agente, para decidir qué se declara.
- **Razón**: M16, y el pedido del operador de que el agente sea recuperable por completo. El overlay de donna guarda credenciales de Google, y su feature de costos guarda configuración propia.
- **Decisión del operador (13-11-2026)**: incluirlo en esta feature, junto con D21.
- **Alternativas descartadas**:
  - respaldar todo el directorio de estado salvo una lista de cachés: una caché nueva de varios gigabytes entraría sola al repositorio;
  - una sexta unidad: más superficie para el mismo resultado;
  - un informe automático de "estado sin clasificar": útil, pero obliga al launcher a mantener la lista de lo que cada herramienta regenera. Queda como mejora posterior.

### D23. Captura genérica de bases SQLite y exclusiones de claude-mem

- **Decisión**:
  - la herramienta del almacén reconoce una base SQLite por su cabecera de 16 bytes y la captura siempre con la API de respaldo, sea cual sea su nombre;
  - los archivos `-wal`, `-shm` y `-journal` no se empaquetan;
  - del directorio de claude-mem se excluyen `logs/`, `backups/`, `run/`, `*.pid`, `telemetry*.json`, `*heartbeat*.json`, `*health*.json` y `supervisor.json`.
- **Razón**: M17 y FR-011. Sin las exclusiones, la unidad `memory` crearía un commit en cada ciclo aunque el agente no haya conversado.

### D24. Lo que queda fuera a propósito

- **El archivo de login que deja `/login`**: la flota se autentica con el token del archivo de secretos (M14). Un agente que solo use `/login` tiene que volver a iniciar sesión después de restaurar. Respaldarlo sumaría otra credencial fuera del host, y su token de renovación rota: una copia restaurada puede invalidar la sesión del original.
- **El archivo de configuración vivo de Claude** (M15): cambia demasiado seguido, y el arranque vuelve a sembrar lo que el launcher necesita. Lo que se pierde son los servidores MCP agregados a mano con `claude mcp add`.
- **Lo regenerable**: la caché de plugins, las cachés de herramientas, el índice de qmd, los archivos derivados y los archivos de sistema del launcher.

**Decisión del operador (13-11-2026)**: el login de `/login` queda fuera.

El detalle está en la sección 9 de [data-model.md](data-model.md).

### D25. La asociación es solo del modo docker

- **Decisión**: el wizard hace la pregunta solo en modo docker, como la de voz. `BACKUP_REPO_ENABLED` vale `true` solo si hay URL y el modo es docker. En modo local, un `agent.yml` con URL deja una advertencia al regenerar y no cambia ningún archivo derivado.
- **Razón**: FR-019.

### D26. Los dos scripts de credenciales llevan extensión `.sh`

- **Decisión**: `docker/scripts/git-askpass-agent.sh` y `docker/scripts/git-credential-agent.sh`.
- **Razón**: el job `shellcheck` de la CI elige los archivos por extensión (`.github/workflows/shellcheck.yml`). Sin ella habría que editar el workflow.

### D27. Una llave de datos por almacén (decisión del operador, 14-11-2026)

- **Decisión**: cada almacén tiene su propio par de llaves de `age`, generado dentro del agente con `age-keygen`.
  - La parte privada viaja en `store/key.age`, cifrada para la llave pública del operador. No queda en el disco del agente.
  - La parte pública va en `store/recipient`, en claro. Con ella se cifran los bloques y el manifiesto.
  - `store/operator` guarda la huella de la llave del operador para la que se cifró `key.age`.
- **Al restaurar**: la llave del operador se usa una sola vez, para abrir `key.age`. Lo demás se descifra con la llave de datos, sin preguntar nada.
- **Al cambiar la llave del operador**: el almacén genera un par nuevo, descarta todos sus bloques y cifra todo de nuevo. Es una subida completa, y es la única forma de que el respaldo quede legible con la llave vigente.
- **En las unidades**: el hash de una unidad con almacén incluye la llave pública del operador. Cambiarla hace que la unidad vuelva a empaquetar, y ahí el almacén rota.
- **Contra un cambio hecho en el repositorio**: la unidad recuerda en su estado la parte pública de su almacén. Si la que trae el repositorio no coincide con la recordada, no cifra para ella: rota el almacén.
- **Razón**: M19, y el defecto que encontró el análisis: los bloques ya subidos no se volvían a cifrar al cambiar la llave, así que el respaldo quedaba ilegible con la llave vigente sin que nada lo avisara.
- **Alternativa descartada**: seguir cifrando directo para la llave del operador y volver a cifrar al cambiarla. Corrige el segundo problema y deja la passphrase por bloque.
- **Riesgo aceptado**: después de perder su estado local, la unidad confía en la parte pública que encuentra en el repositorio. Quien pudiera escribir en el repositorio en ese momento podría hacer que los bloques nuevos se cifren para él.

### D28. En un agente sensible, la configuración también viaja cifrada (decisión del operador, 14-11-2026)

- **Decisión**: con `backup.sensitive: true`, la rama `backup/config` lleva `agent.yml` en claro y todo lo demás en su almacén: la persona, el `CLAUDE.md`, la configuración de proyecto de Claude y `docker-compose.override.yml`.
- **Por qué `agent.yml` queda en claro**: hace falta para empezar una restauración y no lleva datos de salud.
- **Con fork y sin repositorio**: un fork no lleva almacén, así que el vault de un agente sensible no se empuja ahí. En modo local la marca no se honra, y regenerar lo advierte.
- **Razón**: la persona de CBum solo admite el respaldo cifrado, y la persona misma puede describir la salud del operador.
- **Lo que sigue en claro en un agente sensible**: la lista de la unidad de identidad (ajustes de Claude, lista de emparejamiento de Telegram y configuración de plugins). No lleva datos de salud; se revisa en el despliegue de cada agente.

### D29. En un agente que ya existe, la llave se fija con un paso explícito (decisión del operador, 14-11-2026)

- **Decisión**: `--regenerate` no elige ninguna llave. Si hay repositorio asociado y falta la llave, o falta `GITHUB_PAT` en el archivo de secretos, lo avisa con el comando que hay que correr. `heartbeatctl backup-identity --configure-key` muestra la huella de la llave que fija.
- **Para un agente nuevo**: el wizard sigue proponiendo la primera llave `ssh-ed25519` del dueño en GitHub, con su huella (D17).
- **Razón**: M21 (el camino de `--regenerate` nunca fijó la llave) y M9 (el operador tiene 5 llaves en GitHub). Una llave elegida a ciegas puede ser una cuya parte privada no está a mano.

### D30. SC-002 se acota a lo que se mide (decisión del operador, 14-11-2026)

- **Decisión**: SC-002 exige que lo restaurado coincida con lo respaldado, que el archivo de secretos y el emparejamiento de Telegram restaurados sean los del original, y que la conversación se retome con el historial restaurado. Que el agente no pida iniciar sesión se sigue de lo primero y no se mide por separado: el ensayo no arranca el workspace restaurado.
- **Cómo se compara**: los archivos que viajan tal cual, por su SHA-256 contra el origen. Los que se capturan (una base SQLite, un `.jsonl`), contra la lista que entrega `backup_store.py digest --list` dentro del agente, porque la copia consistente de una base no tiene los bytes del archivo vivo (M18).
- **Razón**: arrancar el workspace restaurado junto al original son dos sesiones con el mismo token de Claude y el mismo bot de Telegram.

### D31. La comprobación de privacidad no falla abierta, y el destino es GitHub

- **Decisión**:
  - la sonda anónima solo cuenta como "privado" si el servidor la rechaza por falta de credencial. Cualquier otra falla da el veredicto `unverified`, y con él no se empuja;
  - `backup.repo.allow_unverified: true` permite empujar con `unverified`. No salta la sonda y nunca habilita un repositorio que respondió sin credencial;
  - la URL tiene que ser `https://github.com/<dueño>/<nombre>`. La costura de las pruebas solo admite `http://` hacia `127.0.0.1`, `localhost` y `host.docker.internal`.
- **Razón**: FR-005 dice que si la privacidad no se puede comprobar, no se empuja. Una sonda que falla por la red no comprueba nada. Y con una URL de otro servidor, el askpass le entregaría el token a ese servidor y la llave pública se buscaría en la cuenta de GitHub de otra persona.

### D32. Reintentos, topes, candado y aislamiento de git

- **El supervisor no insiste**: tras un intento sin éxito, no vuelve a lanzar la unidad de identidad por el mismo contenido antes de 15 minutos. Un contenido nuevo la lanza de inmediato. El estado guarda el hash de lo que se intentó respaldar; un intento que terminó antes de calcularlo, como el de un agente sin credencial, frena igual. Un estado ilegible no hace fallar al supervisor.
- **El tope externo del disparador** pasa a 300 segundos con `-k 10` cuando hay repositorio asociado, porque el peor caso del flujo nuevo suma 240. Con fork queda en 90, como hoy.
- **El `fetch` de `memory` y de `history`** usa el tope largo del empuje: tras restaurar, o si se pierde la caché, tiene que bajar el almacén entero.
- **Un candado por unidad** (`flock -n`): el cron, el supervisor y una corrida manual no pisan la misma caché. La unidad lo suelta de forma explícita al terminar, por la lección de 044.
- **Git aislado**: con un repositorio asociado, el git de los respaldos ignora la configuración global y la de sistema. El agente puede escribir su propio `~/.gitconfig`, y un `insteadOf` o una firma obligatoria romperían el respaldo sin que las pruebas lo vean.

### D33. El estado dice lo que hay en el destino

- **Árbol idéntico**: si la unidad arma su árbol y resulta igual al de la cabeza remota, no hay commit, y el estado queda con el hash actual, con la cabeza remota como último commit y con una fecha de último respaldo. Es el caso de un agente recién restaurado, para lo que viaja en claro.
- **Con algo cifrado en el árbol**: `age` cifra distinto cada vez, así que una unidad con almacén que perdió su estado hace un commit chico, que solo cambia el manifiesto y no sube ningún bloque. `identity` en modo `full` hace uno que solo cambia los secretos cifrados.
- **Si la rama remota no existe**: la caché de la unidad se crea de nuevo, y la rama nace con un solo commit.
- **Fechas**: el registro del destino y el estado guardan también los segundos desde la época, para no depender de cómo cada `date` interpreta una fecha ISO.
- **`memory`**: su hash cubre todos sus archivos, los que van en claro y los del almacén. Gana dos resultados: `nothing-to-back-up` y `error`.

### D34. Repositorio vacío y rama por defecto

- **Decisión**: si el remoto no tiene ninguna rama de trabajo (está vacío, o solo tiene ramas `backup/*`), el clon de trabajo queda con una rama `main` local sin commits. Nunca se extrae una rama `backup/*`.
- **Recomendación para el operador**: crear el repositorio con un commit inicial en `main`. Se cree que GitHub toma como rama por defecto la primera que recibe, y en un repositorio vacío sería una de respaldo. No está medido.
- **Si el clon no se pudo crear en el arranque**: la unidad `config` lo vuelve a intentar en cada corrida.

### D35. Crecimiento: una señal y una forma de recortar

- **La señal**: `backup-status` informa el tamaño de la caché de cada unidad, que es una buena aproximación de lo que su rama ocupa. El diagnóstico advierte cuando la suma pasa de 800 MB.
- **El recorte**: borrar la rama remota de la unidad. El ciclo siguiente la recrea con un solo commit, y el servicio descarta la historia vieja.
- **Lo que el respaldo refleja**: el estado actual del agente. Lo que Claude Code borra por su retención de 30 días sale también de la cabeza de la rama, y queda solo en su historia hasta el próximo recorte.
- **El simulador de SC-007** se versiona en `specs/046-agent-backup-repo/tools/sc007_sim.py`.
- **Razón**: SC-007 mide 30 ciclos. La base de claude-mem puede sumar hasta 4,2 MB por día, y nada del diseño anterior avisaba cuando el repositorio se acercaba a 1 GB.

### D36. Restauración: con marca de pertenencia, unidad mixta y temporal

- **Con marca o sin ella**: los pasos de `memory` e `history` se intentan siempre, en silencio. Sus líneas y el resumen final solo se imprimen cuando alguna rama del origen trae la marca de pertenencia. Con un fork de tres ramas, la salida es la de hoy.
- **Unidad mixta**: "completa o nada" vale para lo que viene en el almacén de una unidad. Sin llave, lo que viene en claro se restaura y lo cifrado se omite, con su línea.
- **Temporal**: lo descifrado se arma en un directorio dentro del destino, con modo 0700, que se borra al terminar, también ante una interrupción.
- **Qué llave**: la regla de hoy vale para toda pieza cifrada: la llave indicada y, si no, las dos llaves ssh por defecto del operador.

### D37. Los bloques se nombran por el archivo cifrado (decisión del operador, 15-11-2026)

- **Origen**: la revisión independiente de T073 objetó el riesgo aceptado de D8. El operador eligió "HMAC con la llave de datos".
- **Por qué no es literalmente un HMAC**: `pack` nunca tiene la parte privada de la llave de datos. Solo la tiene `key.age`, cifrada para la llave del operador (S1), y el agente no puede abrirla. Una llave nueva de nombres guardada en el agente sería otro secreto que respaldar.
- **Decisión**: el nombre de un bloque es el SHA-256 de su archivo cifrado, que no dice nada del contenido. `age` cifra distinto cada vez, así que para reutilizar un bloque la unidad lleva un mapa local (`<caché>/<unidad>-repo.blockmap`) del SHA-256 de cada bloque en claro al nombre de su archivo, válido solo para la llave de datos vigente y fuera de todo árbol que se commitea. El manifiesto, cifrado, guarda el SHA-256 de cada bloque en claro. Al restaurar, `unpack` verifica el nombre de cada archivo antes de descifrarlo, y el contenido descifrado contra el manifiesto.
- **Lo que cumple de lo pedido**: los nombres no revelan el contenido; la deduplicación dentro de un almacén sigue igual mientras exista el mapa; no hace falta migrar nada, porque ningún agente tiene todavía un almacén.
- **Costo**: si el mapa se pierde (una caché borrada, o la primera corrida tras una restauración en otro equipo), el ciclo siguiente cifra y sube todo de nuevo, y los bloques viejos se borran de la rama. Es el mismo costo de una rotación. **El operador lo aceptó el 15-11-2026**, frente a dos alternativas: guardar el mapa junto al estado de la unidad (sobrevive a perder la caché, no a una restauración, y exige que nunca se commitee) o una llave de nombres por agente respaldada con los secretos (sobrevive a todo, a costa de tocar el manejo de secretos). TU33 afirma esa subida única y el no-change que la sigue; TU40, que tras una rotación ningún nombre viejo queda.
- **Lo que no cambia**: `age` sigue sin autenticar (S5 de [block-store.md](contracts/block-store.md)); quien escribe el repositorio puede reemplazar un respaldo. R9 de [restore.md](contracts/restore.md) acota lo que una restauración escribe.

### D38. El gate previo al merge se ejecuta en el M4 (decisión del operador, 16-11-2026)

- **Contexto**: ferrari no está accesible; el operador necesita llegar a casa y reiniciarlo. Código y gates automatizados ya están validados y la privada M4 abrió su prueba sintética. La falta de acceso impide certificar el estado vivo de la flota.
- **Decisión**: piloto aislado por consola en Docker del M4, con repositorio privado real nuevo `rodrigo-hinojosa/agentic-046-recovery-gate`. Se conservan las cinco unidades reales, la verificación de ramas/idempotencia y la restauración comparada antes del merge. M5 mantiene autorización separada.
- **Límites**: datos sintéticos, sin bots ni perfiles copiados, sin supervisor o cron concurrente. No acredita el inventario, los archivos en claro o el canal de linus. Esas comprobaciones y la restauración con datos vivos pasan a la validación operacional de linus antes de ampliar a donna/cbum; FR-023, FR-026 y SC-010 siguen pendientes. El código del producto no cambia por esta elección.
- **Procedimiento**: `contracts/local-pilot.md`, evidence V5 y quickstart sección 4. No omitir fallas ni aceptar rc 0 sin refs, estados y comparaciones completas. La privada se usa solo en la Terminal del operador.

### Resultado posterior de M5 (17-11-2026)

La medición que estaba pendiente al escribir M5/D18 se completó con el piloto M4 de D38, sin tocar el perfil del Mac. Claude Code 2.1.170 y el modelo efectivo `claude-sonnet-4-6` retomaron la misma sesión y devolvieron el marcador esperado desde un JSONL de 2.329 bytes restaurado por 046. El perfil vacío respondió UNKNOWN después de existir la conversación del productor. Se usaron tres invocaciones de un turno, con OAuth entregado aparte, sin herramientas/MCPs y con un lector que solo recibió el archivo recuperado. Se retiraron los lectores y temporales. Esto mide continuación del historial en ese caso; no recuperación del login o del canal vivo. Resultados y límites en [pilot-m4-results.md](pilot-m4-results.md). Las notas originales M5/D18 se conservan como investigación previa.

## Hallazgos laterales, fuera de alcance

- **El respaldo al fork tampoco puede empujar desde el contenedor** (inferido de M1): usa el mismo camino sin credencial. Hoy no afecta a nadie, porque ningún agente de la flota tiene fork.
- **Con destino fork, la unidad de identidad tampoco cifra el archivo de secretos** (M13). El `README.md` dice que la restauración devuelve el login de `/login`, y ese archivo no está en la lista de la unidad (M14). Las dos cosas van a un issue.
- **El wizard escribe un bloque `features.review` que nadie lee** (`setup.sh:1279`); el que vale es `features.heartbeat.review`. Ya se había visto al redactar la ficha de Doctor Milagro.
- **`fetch_github_ssh_key` usa `printf ... | grep -m 1` bajo `pipefail`**: es la forma de carrera por SIGPIPE que documenta `CLAUDE.md`. Con la respuesta de `.keys`, de menos de 1 KB, no se dispara.
- **`backup_store.py` carga en memoria todos los archivos de una unidad a la vez** (revisión de T073): en donna, el historial y claude-mem suman hoy unos 95 MB. Cabe con holgura, pero crece. El operador decidió (15-11-2026) dejarlo para un issue propio: procesar archivo por archivo.
- **Con fork, el supervisor dispara `identity` aunque `features.identity_backup.enabled` sea `false`**: así es en `main`, donde `enabled` solo gobierna la línea de cron. Con repositorio, 046 lo respeta (decisión del operador, 15-11-2026); el camino del fork no cambia (FR-018).

## Riesgos

| Riesgo | Mitigación |
| --- | --- |
| El primer empuje del historial de donna (unos 55 MB) tarda más que el tope de 60 segundos de las unidades actuales | Las unidades nuevas hacen una comprobación previa rápida y dan al empuje un tope propio, más largo y configurable |
| El operador cifra para una llave que no tiene | D29: la llave se fija con un paso explícito, que muestra su huella. Además, el ensayo de restauración del gate |
| Un cron del contenedor no recibe `GITHUB_PAT` | La feature 045 midió que los trabajos de `crond` heredan su entorno. Lo verifica la prueba de extremo a extremo |
| `host.docker.internal` no resuelve en el runner Linux de la CI | La prueba agrega `host.docker.internal:host-gateway` al compose del agente de prueba |
| El token de un agente no tiene permiso de escritura sobre su repositorio | El gate lo comprueba en linus antes del merge, y el despliegue en cada agente |
| El formato del directorio de claude-mem cambia | La unidad respalda todo el directorio salvo una lista corta de exclusiones, sin depender de nombres internos |
| El operador no declara una ruta donde el agente guarda estado propio | El contexto del agente le pide avisar cuando empiece a guardar estado en un lugar nuevo, y el despliegue hace un inventario por agente (D22) |
| La unidad de identidad empuja demasiado seguido ahora que la credencial funciona | Medido en M15: los archivos de su lista no cambian entre arranques. No se le agrega el archivo de configuración vivo. Ante una falla, el supervisor espera 15 minutos (D32) |
| El repositorio crece sin tope a lo largo de los meses | D35: una señal en el diagnóstico y un recorte que no exige empujes forzados |
| GitHub deja una rama de respaldo como rama por defecto de un repositorio vacío | D34: el operador crea el repositorio con un commit en `main`. Sin medir |
| Un archivo volátil de claude-mem que no está en la lista de exclusiones hace que `memory` cree un commit por ciclo | El gate en linus corre dos ciclos seguidos y exige 0 commits en el segundo |
| Quien pueda escribir en el repositorio reemplaza un respaldo por otro contenido, y la restauración lo acepta | Riesgo aceptado: el cifrado da confidencialidad, no autenticidad. Es el mismo modelo del respaldo en claro de hoy, y depende del control de acceso del repositorio. La restauración avisa cuando trae un override de compose, y solo escribe las rutas de su lista, nunca bajo `.git` ni a través de un enlace (R9) |
| Una llave del operador con passphrase se pide varias veces al restaurar | D27 lo acota a una vez por pieza cifrada: tres en un agente sin marcar y hasta cinco en uno sensible (M19) |
