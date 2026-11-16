# Data Model: Un repositorio privado por agente para su trabajo y su respaldo completo

**Feature**: `046-agent-backup-repo` | **Fecha**: 2026-11-13, corregido el 14-11-2026 tras el análisis de consistencia

Las decisiones que justifican cada forma están en [research.md](research.md). Las rutas del contenedor asumen `/workspace` como workspace y `/home/agent` como `.state/`.

## 1. Claves de `agent.yml`

### Claves nuevas

| Clave | Tipo | Valor por defecto | Regla |
| --- | --- | --- | --- |
| `backup.repo.url` | texto | `""` | Vacío significa sin repositorio asociado. Si no está vacío, debe tener la forma `https://github.com/<dueño>/<nombre>`, con `.git` opcional al final, sin credenciales ni espacios |
| `backup.repo.allow_unverified` | booleano | `false` | En `true`, se acepta un destino cuya privacidad no se pudo comprobar. Nunca habilita un repositorio público |
| `backup.sensitive` | booleano | `false` | En `true`, el vault, la auto-memoria y la configuración, salvo `agent.yml`, viajan cifrados |
| `backup.extra_paths` | lista de textos | `[]` | Cada entrada es una ruta relativa a la raíz del workspace. Se normaliza antes de validar: sin `./` al comienzo ni `/` al final. No está vacía, no es `.`, no empieza con `/` y no tiene ningún segmento `..`. No puede ser `.state`, ni estar bajo `.state/.cache` o bajo `agent-repo`, ni tener un componente `.git`, ni ser una ruta reservada del launcher: `setup.sh`, `VERSION`, `agent.yml`, `CLAUDE.md`, `NEXT_STEPS.md`, `.mcp.json`, `.gitignore`, `docker-compose.yml`, `docker-compose.override.yml`, el archivo de secretos y sus variantes, ni nada bajo `scripts/`, `docker/`, `modules/`, `tests/`, `personas/` o `.github/` (`memory_extra_path_reserved`, una sola fuente para el respaldo y la restauración). El archivo que deja el login de `/login` nunca viaja, aunque esté dentro de una entrada. Una entrada que no cumple, o que no existe, se omite y se informa |
| `features.memory_backup.enabled` | booleano | `true` | Habilita la unidad `memory` |
| `features.memory_backup.schedule` | cron de 5 campos | `"40 3 * * *"` | Cinco campos válidos; se admite `*` y `*/N` en todos, incluido el minuto |
| `features.history_backup.enabled` | booleano | `true` | Habilita la unidad `history` |
| `features.history_backup.schedule` | cron de 5 campos | `"50 3 * * *"` | La misma regla |

- El wizard las escribe en el heredoc de `agent.yml`. `--regenerate` las completa en un `agent.yml` anterior con `has()`, nunca con `//`, para no pisar un `false` explícito del operador.
- Los booleanos entran a `_SCHEMA_BOOLEANS` de `scripts/lib/schema.sh`.
- Las unidades `memory` e `history` solo corren cuando el destino es un repositorio asociado. Con fork o sin destino no se agregan sus líneas de cron.
- Lo que nombra `backup.extra_paths` viaja siempre cifrado, dentro de la unidad `memory` (sección 5). Sirve para el estado que el launcher no conoce: el de un overlay, o el de una feature que el agente se construyó.
- La regla de la URL tiene una costura para las pruebas: con `BACKUP_DEST_ALLOW_HTTP=1` se admite además `http://` hacia `127.0.0.1`, `localhost` y `host.docker.internal`, con cualquier puerto y cualquier ruta.

### Claves que ya existen y cambian de alcance

| Clave | Cambio |
| --- | --- |
| `backup.identity.recipient` | Sigue siendo una llave pública `ssh-ed25519` o `ssh-rsa`. Ahora es la llave del operador para todo lo cifrado, no solo para los secretos |
| `features.identity_backup.enabled` | Con fork o sin destino, sin cambios: la línea diaria de cron existe solo si vale `true`. Con un repositorio asociado, la línea existe salvo que valga `false` de forma explícita |
| `features.identity_backup.schedule`, `features.config_backup.*`, `vault.backup_schedule` | Sin cambios |
| `scaffold.fork.*` | Sin cambios |

### Marcadores derivados para las plantillas

`setup.sh` los exporta después de cargar el contexto. No se guardan en `agent.yml`. `BACKUP_REPO_URL` no es derivado: sale del aplanado de `backup.repo.url`.

| Marcador | Valor |
| --- | --- |
| `BACKUP_REPO_ENABLED` | `true` si `backup.repo.url` no está vacío **y** `deployment.mode` es `docker`; `false` en otro caso |
| `BACKUP_REPO_WORKDIR` | `/workspace/agent-repo` |
| `BACKUP_REPO_NEXT_STEPS` | El bloque de `NEXT_STEPS.md` sobre el repositorio del agente, ya renderizado; vacío sin repositorio. Existe porque el bloque de docker de esa plantilla ya es un condicional, y el motor no admite anidarlos |
| `GITHUB_PAT_NEEDED` | `true` si el MCP de GitHub está activo o `BACKUP_REPO_ENABLED` es `true` |

## 2. Secretos

| Variable | Dónde vive | Quién la usa |
| --- | --- | --- |
| `GITHUB_PAT` | Solo en el archivo de secretos del workspace; llega al contenedor por el `env_file` de compose | El MCP de GitHub (como hoy), el askpass de los respaldos y el ayudante de credenciales del clon de trabajo |

- El wizard la escribe cuando el MCP de GitHub está activo **o** cuando hay un repositorio asociado.
- Su valor nunca se escribe en `agent.yml`, en un log, en un argumento, en una URL ni en la configuración de git.

## 3. Destino resuelto

`backup_dest_resolve` devuelve un tipo y una URL:

| Tipo | Condición | Efecto |
| --- | --- | --- |
| `repo` | `backup.repo.url` no está vacío | Camino nuevo: credencial, comprobación de privacidad, marca de pertenencia y las cinco unidades |
| `fork` | En otro caso, `scaffold.fork.url` no está vacío | Camino actual, sin cambios: tres unidades y sin credencial |
| `none` | Ninguno de los dos | Camino actual, sin cambios: cada cron escribe su línea de "sin destino" |

### Registro del destino

Archivo `scripts/heartbeat/backup-dest.json`, que solo se escribe con el tipo `repo`:

```json
{
  "url": "https://github.com/owner/name",
  "verdict": "private",
  "checked_at": "2026-11-13T15:00:00Z",
  "checked_epoch": 1794582000,
  "anon_checked_at": "2026-11-13T04:00:00Z",
  "anon_checked_epoch": 1794542400
}
```

| `verdict` | Significado | Se empuja |
| --- | --- | --- |
| `private` | El servidor rechazó la sonda anónima por falta de credencial, y la consulta autenticada funciona | Sí |
| `unverified-allowed` | La sonda anónima falló por otra razón, la consulta autenticada funciona y `allow_unverified` está activo | Sí |
| `unverified` | La sonda anónima falló por otra razón y `allow_unverified` no está activo | No |
| `public` | La sonda anónima funcionó | No, tampoco con `allow_unverified` |
| `unreachable` | La consulta autenticada falló (credencial, red o repositorio inexistente), o la URL no cumple la regla | No |

- `checked_*` es el momento de la última consulta autenticada, que corre en cada ciclo.
- `anon_checked_*` es el momento de la última sonda anónima. Esa sonda no se repite mientras el veredicto sea `private`, la URL no cambie y hayan pasado menos de 86.400 segundos desde `anon_checked_epoch`. Con cualquier otro veredicto se repite en la corrida siguiente.
- Los plazos se calculan con los campos en segundos. Las fechas ISO son para leer.

## 4. Estado por unidad

Archivos `scripts/heartbeat/<unidad>-backup.json`, con `<unidad>` en `identity`, `vault`, `config`, `memory` o `history`.

| Campo | Existe hoy | Contenido |
| --- | --- | --- |
| `hash` | Sí | Hash del contenido que está respaldado en el destino |
| `mode` | Solo en `identity` | `full` o `partial` |
| `last_commit` | Sí | Commit de la rama que contiene ese contenido |
| `last_push` | Sí | Fecha del último respaldo correcto: ISO 8601, en UTC y terminada en `Z`, como hoy |
| `last_attempt`, `last_attempt_epoch` | Nuevos | Momento del último intento, en ISO y en segundos |
| `last_result` | Nuevo | Uno de los resultados de la tabla siguiente |
| `attempt_hash` | Nuevo | Hash del contenido que se intentó respaldar la última vez. Vacío si el intento terminó antes de calcularlo |
| `store_recipient` | Nuevo, solo en unidades con almacén | La parte pública de la llave de datos de su almacén |

- Los campos nuevos solo se escriben con el tipo `repo`. Con `fork` o `none` el archivo queda exactamente como hoy, y por eso un agente sin destino sigue sin archivo de estado.
- Toda escritura del estado con el tipo `repo` fusiona: conserva los campos que no cambia.
- **Árbol idéntico**: si la unidad arma su árbol y resulta igual al de la cabeza remota, no hay commit. El estado queda con `hash` igual al actual, `last_commit` igual a la cabeza remota y `last_push` igual al que ya tenía o, si no tenía, a la fecha de ese commit, en el mismo formato. Es el caso de un agente recién restaurado, para lo que viaja en claro. Una unidad con algo cifrado en su árbol hace un commit cada vez que empaqueta, porque `age` cifra distinto cada vez: en ese mismo caso sube un commit chico, sin bloques nuevos (U1 de [contracts/backup-units.md](contracts/backup-units.md)).

### Resultados de un intento

| `last_result` | Cuándo | Código de salida |
| --- | --- | --- |
| `ok` | Se empujó un commit | 0 |
| `no-change` | El hash es el del estado y la cabeza remota de la rama es el commit del estado; o el árbol resultó idéntico al de la cabeza remota | 0 |
| `nothing-to-back-up` | La unidad no tiene ninguna fuente | 0 |
| `no-credential` | Falta `GITHUB_PAT` | 0 |
| `no-recipient` | La unidad tiene contenido que debe ir cifrado y falta la llave pública | 0 |
| `not-private` | El veredicto es `public` | 0 |
| `unverified` | El veredicto es `unverified` | 0 |
| `foreign-branch` | La rama existe y no tiene la marca del launcher | 0 |
| `other-agent` | La marca nombra a otro agente | 0 |
| `unreachable` | La consulta autenticada o el `fetch` de la rama fallaron | 2 |
| `push-failed` | El empuje falló o agotó su tiempo | 2 |
| `error` | Falló el armado del árbol o la herramienta del almacén | 2 |

- Los rechazos por política salen con 0 para que el cron no los trate como error; quedan visibles en el estado y en el diagnóstico. Las fallas transitorias salen con 2, como la falla de empuje de hoy.
- Una corrida que encuentra tomado el candado de su unidad sale con 0 y un mensaje, y no escribe ningún resultado: la corrida que lo tiene es la que registra.

## 5. Ramas de respaldo en un repositorio asociado

Todas son huérfanas y llevan la marca de pertenencia en su raíz.

### Marca de pertenencia

Archivo `.agentic-pod-backup.json`:

```json
{ "schema": 1, "agent": "linus", "unit": "history" }
```

| Estado de la rama remota | Resultado |
| --- | --- |
| No existe | Se crea con la marca |
| Existe, con marca del mismo agente y la misma unidad | Se escribe: el árbol nuevo reemplaza al que haya, aunque alguien lo hubiera modificado |
| Existe sin marca | `foreign-branch`: no se escribe. Si era una rama propia a la que le quitaron la marca, el operador la borra y el ciclo siguiente la recrea |
| Existe con marca de otro agente | `other-agent`: no se escribe |

### `backup/config`

En un agente sin marcar:

```text
.agentic-pod-backup.json
agent.yml
CLAUDE.md
personas/<agente>.md
docker-compose.override.yml      (solo si existe)
.claude/                         (configuración de proyecto de Claude, solo lo de la lista)
```

En un agente de datos sensibles:

```text
.agentic-pod-backup.json
agent.yml                        (en claro: hace falta para empezar una restauración)
store/                           (cifrado: todo lo demás)
```

- De `personas/` se excluyen las copias `*.bak*`.
- De `.claude/`, que es el directorio de la raíz del workspace, entra una lista cerrada: `settings.json`, `skills/`, `commands/`, `agents/`, `hooks/` y `output-styles/`. Todo lo demás queda fuera, incluidos `settings.local.json`, los `*.lock` y `worktrees/`.
- `CLAUDE.md` es un archivo derivado, y se respalda igual: el operador lo puede editar, y entonces `--regenerate` ya no lo reproduce.

### `backup/identity`

La lista de archivos de hoy (`.claude.json`, `.claude/settings.json`, el `access.json` de Telegram y `.claude/plugins/config`), los secretos cifrados (`.env.age`) y la marca.

- El archivo de secretos que se cifra es el de la raíz del workspace, `/workspace/.env`, y no el del directorio de estado, donde no existe (M13 y D19 de [research.md](research.md)). El nombre del archivo cifrado dentro de la rama es el de hoy.
- Los secretos se cifran directo para la llave del operador, como hoy. Es un solo archivo, así que no usa el almacén.
- La lista en claro es la misma en un agente sensible. No lleva datos de salud; se revisa en el despliegue de cada agente.

### `backup/vault`

- **Agente sin marcar**: el markdown del vault, con su estructura, como hoy, más la marca.
- **Agente de datos sensibles**: solo la marca y un `store/` (sección 6) con los mismos archivos.
- **Agente de datos sensibles con fork y sin repositorio**: el vault no se empuja. Un fork no lleva almacén, y el vault de un agente sensible no viaja en claro.

### `backup/memory`

```text
.agentic-pod-backup.json
auto-memory/<proyecto>/<archivo>     (en claro; solo en un agente sin marcar)
store/                               (cifrado: claude-mem, rutas adicionales y, en un agente sensible, la auto-memoria)
```

| Origen en el contenedor | Ruta lógica | Agente sin marcar | Agente sensible |
| --- | --- | --- | --- |
| `/home/agent/.claude/projects/<proyecto>/memory/**` | `auto-memory/<proyecto>/...` | En claro | En `store/` |
| Cada base SQLite de `/home/agent/.claude-mem/` (copia consistente) | `claude-mem/<nombre>` | En `store/` | En `store/` |
| El resto de `/home/agent/.claude-mem/**` | `claude-mem/...` | En `store/` | En `store/` |
| Cada ruta de `backup.extra_paths`, leída bajo `/workspace/` | `extra/<ruta>` | En `store/` | En `store/` |

- Exclusiones de `.claude-mem`: `logs/`, `backups/`, `run/`, `*.pid`, `telemetry*.json`, `*heartbeat*.json`, `*health*.json` y `supervisor.json` (M17 de [research.md](research.md)).
- En cualquier origen se omiten los archivos `*-wal`, `*-shm` y `*-journal` que acompañan a una base SQLite.
- Una ruta adicional puede ser un archivo o un directorio. Los enlaces simbólicos no se siguen, y dentro de un directorio no se recorren los subdirectorios `.git`.

### `backup/history`

```text
.agentic-pod-backup.json
store/                               (cifrado, siempre)
```

Origen: `/home/agent/.claude/projects/**`, salvo los directorios `memory/`. Ruta lógica: `projects/<proyecto>/...`. El directorio de configuración aislado del heartbeat no se incluye.

El respaldo refleja el estado actual del agente. Lo que Claude Code borra por su retención de 30 días sale también de la cabeza de la rama, y queda solo en su historia.

## 6. Almacén por bloques (`store/`)

```text
store/key.age                                          la llave de datos, cifrada para la llave del operador
store/recipient                                        la parte pública de la llave de datos, en claro
store/operator                                         la huella de la llave del operador para la que se cifró key.age
store/manifest.json.age                                cifrado para la llave de datos
store/blocks/<2 hex>/<sha256 del bloque cifrado>.age  cifrados para la llave de datos
```

### Llave de datos

- Es un par de llaves de `age`, propio de cada almacén, que la herramienta genera con `age-keygen` (D27 de [research.md](research.md)).
- La parte privada solo existe en memoria mientras se genera. Lo único que queda de ella es `key.age`.
- `recipient` y `operator` son texto de una línea. No son secretos.
- El almacén **rota** (genera un par nuevo, descarta todos sus bloques y cifra todo de nuevo) en tres casos:
  - no tiene llave todavía;
  - la huella de `operator` no es la de la llave del operador vigente;
  - `recipient` no coincide con el que la unidad tiene registrado en su estado (`store_recipient`).

### Bloque

- Tamaño en claro: 1.048.576 bytes como máximo; el último de cada archivo puede ser más corto.
- Contenido del archivo: el bloque comprimido con gzip y después cifrado con `age` para la llave de datos. Un bloque que no se comprime puede pesar algo más de 1 MiB.
- Nombre: el SHA-256 del **archivo cifrado**, en hexadecimal, y nunca el del bloque en claro: quien lee el repositorio no puede confirmar el contenido de un archivo pequeño probando valores (D37 de [research.md](research.md)). Los dos primeros caracteres forman el subdirectorio. El manifiesto, cifrado, guarda el SHA-256 de cada bloque en claro.
- **Mapa de bloques** (`<caché>/<unidad>-repo.blockmap`, fuera de todo árbol que se commitea): relaciona el SHA-256 de cada bloque en claro con el nombre de su archivo cifrado, para la llave de datos vigente. Un bloque que el mapa registra, y cuyo archivo existe en la rama, no se vuelve a cifrar. Si el almacén rota o el mapa se pierde, todos los bloques se cifran de nuevo y el ciclo es una subida completa.

### Manifiesto

`manifest.json.age` es este JSON, cifrado:

```json
{
  "schema": 1,
  "unit": "history",
  "block_size": 1048576,
  "files": [
    {
      "path": "projects/-workspace/472b42af.jsonl",
      "size": 71952401,
      "mode": "600",
      "sha256": "<hash del archivo tal como se capturó>",
      "blocks": [{"name": "<sha256 del bloque 1 cifrado>", "sha256": "<sha256 del bloque 1 en claro>"},
                 {"name": "<sha256 del bloque 2 cifrado>", "sha256": "<sha256 del bloque 2 en claro>"}]
    }
  ]
}
```

- `files` va ordenado por `path`.
- Un archivo vacío tiene `size` 0 y `blocks` vacío.
- Los `path` son relativos, usan `/` y no pueden contener `..` ni un segmento `.git` (en mayúsculas o minúsculas), ni empezar con `/`. El `mode` se restaura sin los bits setuid, setgid y sticky.
- `size` y `sha256` son los de lo que se capturó. En una base SQLite son los de la copia consistente, no los del archivo vivo; en un `.jsonl`, los de lo leído hasta su último salto de línea.

### Reglas de captura

| Archivo | Regla |
| --- | --- |
| `*.jsonl` | Se lee hasta su último salto de línea. Si no tiene ninguno, se omite en ese ciclo |
| Una base SQLite, reconocida por su cabecera de 16 bytes | Se respalda una copia hecha con la API de respaldo de SQLite, nunca el archivo en bruto |
| Cualquier otro | Se lee completo, hasta el tamaño que tenía al abrirlo |

### Hash de una unidad

- Con un repositorio asociado, `config`, `memory` e `history` calculan su hash con la herramienta del almacén: SHA-256 sobre la lista ordenada de `ruta lógica`, `tamaño` y `sha256` de **todos** sus archivos, los que van en claro y los que van al almacén, seguida de `sensitive=<valor>` y de la llave pública del operador.
- `vault` usa esa misma regla cuando va cifrado, y su función de hoy cuando va en claro.
- `identity` conserva su función de hoy, con la ruta del archivo de secretos que corresponde (D19).
- Así un cambio en cualquier archivo, en la marca de datos sensibles o en la llave del operador produce un respaldo nuevo.
- El valor que queda en el estado es el de este cálculo, que se hace antes de empaquetar y cubre todos los archivos de la unidad. Si un archivo cambia entre el cálculo y el empaquetado, el ciclo siguiente lo ve como un cambio y vuelve a respaldar.

## 7. Clon de trabajo

| Propiedad | Valor |
| --- | --- |
| Ruta | `/workspace/agent-repo` (en el host, `<workspace>/agent-repo`) |
| Lo crea | El arranque del contenedor, como `agent`, en segundo plano y con tiempo máximo, solo si falta. Si no pudo, la unidad `config` lo vuelve a intentar en cada corrida |
| `remote.origin.fetch` | `+refs/heads/*:refs/remotes/origin/*` y además `^refs/heads/backup/*` |
| `credential.<esquema>://<servidor>.helper` | Un valor vacío y después la ruta de `git-credential-agent.sh`. El vacío reinicia la lista de ayudantes heredada de la configuración global y de sistema: un `credential.helper=store` ahí guardaría el token en claro |
| `user.name`, `user.email` | `user.name` y `user.email` de `agent.yml`, solo si el clon no los tiene |
| Rama que queda extraída | La primera que exista, en este orden: la rama por defecto del remoto, si es una rama de trabajo; `main`; la primera rama de trabajo en orden alfabético. Si el remoto no tiene ninguna rama de trabajo (está vacío, o solo tiene ramas `backup/*`), una rama `main` local sin commits |
| En el `.gitignore` del workspace | `/agent-repo/` |

Si el directorio ya existe, solo se aseguran las dos configuraciones de `fetch` y de credencial. No se tocan ramas, archivos ni commits. Nunca se extrae una rama `backup/*`.

## 8. Restauración: de la rama al workspace

| Orden | Rama | Destino en el workspace restaurado |
| --- | --- | --- |
| 1 | `backup/config` | `agent.yml`, `CLAUDE.md`, `personas/`, `docker-compose.override.yml` y `.claude/`, en la raíz. Si la rama trae `store/`, lo que no es `agent.yml` sale de ahí |
| 2 | `backup/identity` | `.state/`, como hoy. Los secretos descifrados van a `.env`, en la raíz, con modo 0600 |
| 3 | `backup/vault` | La ruta de `vault.path`; si hay `store/`, se descifra |
| 4 | `backup/memory` | `auto-memory/<proyecto>/` va a `.state/.claude/projects/<proyecto>/memory/`; `claude-mem/` va a `.state/.claude-mem/`; y `extra/<ruta>` va a `<ruta>`, relativa a la raíz |
| 5 | `backup/history` | `projects/` va a `.state/.claude/projects/` |

- La marca de pertenencia y los tres archivos de la llave de datos no se copian. Cada rama puede faltar.
- Lo descifrado se arma en `<destino>/.restore-tmp/`, con modo 0700, y se mueve a su lugar cuando la unidad pasó su verificación. Ese directorio se borra al terminar, también ante una interrupción.

## 9. Lo que ninguna unidad cubre

Decisión D24 de [research.md](research.md). La documentación de la feature repite esta tabla, para que "recuperable por completo" no prometa más de lo que entrega.

| Dato | Por qué queda fuera | Cómo se recupera |
| --- | --- | --- |
| Archivos de sistema del launcher (`scripts/`, `docker/`, `modules/`, `setup.sh`) | Salen del launcher | La restauración corre desde un clon del launcher |
| Archivos derivados (`.mcp.json`, `docker-compose.yml`, `heartbeat.conf`, `NEXT_STEPS.md`) | Se generan desde `agent.yml` | `./setup.sh --regenerate` |
| La línea base del `CLAUDE.md` que guarda 038 (`.state/launcher/`) | Se genera al regenerar | `./setup.sh --regenerate`; si el `CLAUDE.md` restaurado tenía ediciones, queda preservado, como hoy |
| Caché de plugins, cachés de herramientas (`.cache`, `.bun`, `.npm`, `.local`), índice y modelos de qmd | Regenerables | Se reinstalan en el arranque |
| Archivo de configuración vivo de Claude (`.claude/.claude.json`) | Se reescribe hasta una vez por minuto (M15) | El arranque siembra lo que el launcher necesita. Se pierden los servidores MCP agregados a mano con `claude mcp add` |
| Archivo de login que deja `/login` | La flota usa el token del archivo de secretos (M14), y su token de renovación rota | Un agente que solo use `/login` vuelve a iniciar sesión |
| Historial que Claude Code ya borró por su retención de 30 días | El respaldo refleja el estado actual | Queda en la historia de la rama hasta el próximo recorte |
| Adjuntos recibidos por Telegram, logs y estado del heartbeat | Operacionales | No se recuperan |
| Otros repositorios clonados en el workspace | Cada uno tiene su remoto | Se vuelven a clonar |
| Estado de un overlay o de una feature propia que el operador no declaró | El launcher no lo conoce | Se declara en `backup.extra_paths` |
