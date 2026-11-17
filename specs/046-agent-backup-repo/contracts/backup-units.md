# Contrato: las cinco unidades de respaldo

**Feature**: `046-agent-backup-repo` | Cubre FR-008, FR-009, FR-010, FR-011, FR-012 y FR-013.

Cada unidad sigue siendo independiente: su librería, su rama, su caché de clon, su hash, su armado del árbol, su commit y su archivo de estado. Lo que comparten está en [destination-and-credential.md](destination-and-credential.md) y en [block-store.md](block-store.md), y ninguna de esas piezas arma un árbol, hace un commit ni empuja. Las formas de los datos están en [data-model.md](../data-model.md).

## U1. Flujo común con un repositorio asociado

Cada comando `heartbeatctl backup-<unidad>` sigue estos pasos. Con el tipo `fork` o `none` no entra a este flujo: corre el código de hoy.

| Paso | Qué hace | Si no puede seguir |
| --- | --- | --- |
| 1 | Resuelve el destino (C1) | Con `fork` o `none`, sigue el camino actual |
| 2 | Toma el candado de su unidad (C7) | Tomado: un mensaje, código 0 y ningún registro |
| 3 | Comprueba que `GITHUB_PAT` existe | `no-credential` |
| 4 | Arma la lista de sus fuentes | Sin ninguna fuente: `nothing-to-back-up` |
| 5 | Si alguna fuente debe ir cifrada, comprueba la llave pública del operador | `no-recipient` |
| 6 | Calcula el hash de la unidad | `error` |
| 7 | Comprueba la privacidad y consulta las cabezas del repositorio (C3) | `not-private`, `unverified` o `unreachable` |
| 8 | Si el hash es el del estado y la cabeza remota de su rama es el commit del estado, termina | `no-change` |
| 9 | Prepara su caché: `git init`, remoto y, si la rama existe, `fetch --depth 1` | `unreachable` |
| 10 | Comprueba la marca de pertenencia (C4) | `foreign-branch` u `other-agent` |
| 11 | Arma el árbol: copia lo que va en claro, empaqueta lo cifrado y escribe la marca | `error` |
| 12 | Hace el commit y empuja. Si el árbol es igual al de la cabeza remota, no hay commit | `push-failed`; sin commit, `no-change` |
| 13 | Escribe el estado y suelta el candado | No aplica |

- **Sin red hasta el paso 7**: los pasos 3 a 6 no tocan la red. Una falla de configuración termina sin ninguna conexión, y nada que deba ir cifrado se prepara sin llave.
- **`--dry-run`**: el comando se detiene después del paso 6 y dice si el hash cambió, como hoy. No registra nada: ni el estado de la unidad ni `backup-dest.json`, también cuando termina antes por falta de credencial (el supervisor y `backup-status` leen ese registro).
- **El paso 7 corre en cada ciclo**, también cuando no hay cambios. Es lo que detecta una credencial que dejó de servir, una rama de respaldo borrada y un cambio de repositorio (D20 de [research.md](../research.md)).
- **Un ciclo sin cambios** hace esa única consulta: no clona, no trae la rama y no empuja.
- **Si la rama remota no existe**, la caché de la unidad se crea de nuevo, vacía, y la rama nace con un solo commit. Es lo que hace que borrar una rama remota sirva para recortar su historia (D35).
- **El árbol de cada commit reemplaza al anterior**, como hoy, con una excepción: mientras la unidad use el almacén, `store/` se conserva entre commits, porque de ahí sale la reutilización de bloques. Si la unidad deja de usarlo, `store/` sale del árbol.
- **Las salidas tempranas de hoy** (`no identity files yet`, `vault not enabled`, `vault dir ... does not exist yet` y `agent.yml missing`) se conservan con cualquier destino: un mensaje, código 0 y ningún registro.

### Estado después de cada corrida

Con el tipo `repo`, toda escritura del estado fusiona: conserva los campos que no cambia (sección 4 de [data-model.md](../data-model.md)).

| Caso | Qué queda en el estado |
| --- | --- |
| Se empujó un commit | `hash`, `last_commit` y `last_push` nuevos; `last_result: ok` |
| Sin cambios (paso 8) | Solo el registro del intento |
| Árbol idéntico al de la cabeza remota (paso 12) | `hash` igual al actual, `last_commit` igual a la cabeza remota y `last_push` igual al que ya tenía o, si no tenía, a la fecha de ese commit; `last_result: no-change` |
| Cualquier otro resultado | Solo el registro del intento, con `attempt_hash` si el hash ya se había calculado |

- **Una unidad con algo cifrado en su árbol hace un commit cada vez que empaqueta**, porque `age` cifra distinto cada vez. Por eso una unidad con almacén que perdió su estado, como la de un agente recién restaurado, hace en su primer ciclo un commit chico, que solo cambia el manifiesto; `identity` en modo `full` hace uno que solo cambia los secretos cifrados. El caso del árbol idéntico vale para lo que viaja en claro.
- **El `hash` que se guarda** es el del paso 6, sobre todos los archivos de la unidad, los que viajan en claro y los del almacén. Si un archivo cambió entre ese cálculo y el empaquetado, el ciclo siguiente lo ve como un cambio.
- **`last_push`** va siempre en ISO 8601, en UTC y terminado en `Z`, que es lo que el diagnóstico sabe leer. La fecha de un commit se convierte a ese formato.
- **Las unidades con almacén**:
  - calculan su hash con `digest`, con la marca de datos sensibles y la llave pública del operador en `--extra`;
  - empaquetan con `pack`, al que le pasan esa llave en `--recipients` y el `store_recipient` de su estado, si lo tienen, en `--expect-recipient`;
  - guardan como `store_recipient` la `recipient` que `pack` devuelve.

  Así, un cambio de la llave del operador cambia el hash, la unidad vuelve a empaquetar y su almacén rota.

### Mensajes

Los mensajes del camino `fork` y del camino `none` no cambian. `<u>` es el nombre de la unidad.

| Resultado | Código | Mensaje |
| --- | --- | --- |
| `ok` | 0 | `backup-<u>: <8 hex> pushed` (en `identity`, seguido de un espacio y `(<modo>)`, como hoy) |
| `no-change` (paso 8) | 0 | `backup-<u>: no changes since last backup (hash <hash>)`, como hoy |
| `no-change` (paso 12) | 0 | `backup-<u>: no changes after stage-diff (hash <hash>)`, como hoy |
| `nothing-to-back-up` | 0 | `backup-<u>: nothing to back up yet` |
| `no-credential` | 0 | `backup-<u>: no GITHUB_PAT in the environment - cannot push to the agent repository` |
| `no-recipient` | 0 | `backup-<u>: no encryption key (backup.identity.recipient) - nothing pushed` |
| `not-private` | 0 | `backup-<u>: the repository is public - refusing to push` |
| `unverified` | 0 | `backup-<u>: could not verify that the repository is private - refusing to push` |
| `foreign-branch` | 0 | `backup-<u>: branch backup/<u> exists and is not a launcher backup - refusing to write` |
| `other-agent` | 0 | `backup-<u>: branch backup/<u> belongs to another agent - refusing to write` |
| `unreachable` | 2 | `backup-<u>: repository unreachable (credential, network or missing repository)` |
| `push-failed` | 2 | `backup-<u>: push failed` (por stderr, como hoy) |
| `error` | 2 | `backup-<u>: could not build the backup (<motivo>)` (por stderr), precedida de la línea de la herramienta del almacén cuando la causa está ahí (`backup_store: ...`, sin contenido: S4) |
| Candado tomado | 0 | `backup-<u>: another run holds the lock - skipping` |
| El almacén rotó su llave | No aplica | `backup-<u>: store key rotated (<motivo>) - full upload` |
| Agente sensible con fork y sin repositorio | 0 | `backup-vault: this agent is marked as sensitive and has no agent repository - not pushing the vault in plaintext` |
| Ruta adicional omitida | No aplica | `backup-memory: skipping extra path '<ruta>' (<motivo>)`, con motivo `not relative`, `not allowed`, `outside the workspace` o `missing` |

## U2. `identity`

- **Lista de archivos**: la de hoy.
- **Archivo de secretos**: con un repositorio asociado, el de la raíz del workspace (D19 de [research.md](../research.md)). `identity_hash` lo recibe como un argumento opcional; sin ese argumento lee el del directorio de estado, como hoy. Es el único cambio en una función que ya existe: el camino `repo` arma su árbol con funciones propias.
- **Una sola fuente para esa ruta**: `identity_secrets_file TIPO WORKSPACE DIR_DE_ESTADO` entrega la ruta que corresponde al tipo de destino. La usan `heartbeatctl` y el supervisor, para que los dos calculen el mismo hash.
- **Cifrado**: como hoy, directo para la llave del operador. Con llave, los secretos van cifrados (`full`); sin llave, se omiten (`partial`) y la unidad corre igual. Por eso `identity` nunca termina en `no-recipient`.
- **Disparadores**: los de hoy, más una línea diaria de cron con un repositorio asociado (U7). `_identity_backup_fork_configured` pasa a responder "hay destino" con la regla de C1, sin cambiar de nombre.

### El supervisor no insiste

Con un repositorio asociado, `_check_identity_backup` decide así en cada revisión:

| Situación | Dispara la unidad |
| --- | --- |
| `features.identity_backup.enabled` es `false` (solo con repositorio; con fork, la regla de `main`) | No |
| El hash actual es el `hash` del estado | No |
| El último intento no terminó en `ok` ni en `no-change`, su `attempt_hash` es el hash actual o está vacío, y pasaron menos de 900 segundos desde `last_attempt_epoch` | No |
| Cualquier otro caso | Sí |

- Un `attempt_hash` vacío es el de un intento que terminó antes de calcular el hash, como el de un agente sin credencial. Frena igual.
- **Un estado ilegible** (un archivo truncado, o un `last_attempt_epoch` que no es un número) cuenta como si no hubiera intento anterior. La función devuelve 0 siempre: el supervisor la llama bajo `set -euo pipefail`.
- `agent.yml` sale de una sola fuente, el del workspace, para la regla de destino y para la llave pública.
- El plazo es `IDENTITY_BACKUP_RETRY_S`, 900 por defecto. Un contenido nuevo dispara de inmediato.
- La línea de log del disparo nombra el resultado del intento anterior, si lo hubo.
- El disparador corre la unidad con `timeout -k 10 300` (C6). Con fork, la regla y el tope son los de hoy.
- El cuerpo de `_run_watchdog` no cambia.

### La llave del operador

`heartbeatctl backup-identity --configure-key <ruta|llave pública>` ya existe: fija `backup.identity.recipient` y corre la unidad. Con un repositorio asociado gana dos líneas, después de `recipient updated`:

```text
backup-identity: key fingerprint SHA256:<huella> (<comentario>)
backup-identity: encrypted units re-encrypt for this key on their next run (full upload)
```

Es el paso con que un agente que ya existe fija su llave (D29 de [research.md](../research.md)). Con fork o sin destino, su salida es la de hoy.

## U3. `config`

- **Con fork**: solo `agent.yml`, como hoy.
- **Con repositorio asociado, agente sin marcar**: `agent.yml`, `CLAUDE.md`, `personas/` (sin las copias `*.bak*`), `docker-compose.override.yml` si existe, y la lista cerrada del directorio `.claude/` de la raíz del workspace: `settings.json`, `skills/`, `commands/`, `agents/`, `hooks/` y `output-styles/`. Todo en claro.
- **Con repositorio asociado, agente de datos sensibles**: `agent.yml` en claro y todo lo demás en `store/` (D28 de [research.md](../research.md)). Sin llave pública, termina en `no-recipient`.
- **Hash**: con repositorio, el de la sección 6 de [data-model.md](../data-model.md), sobre todos los archivos incluidos. Con fork, `config_hash`, como hoy.
- **Cadencia**: la de hoy, `30 3 * * *`.
- **Clon de trabajo**: con un repositorio asociado, al terminar con cualquier resultado, el comando llama a `agent_repo_ensure` (A4 de [agent-surface.md](agent-surface.md)). Así un clon que no se pudo crear en el arranque se vuelve a intentar cada día. Su falla no cambia el resultado ni el código de salida de la unidad.

## U4. `vault`

- **Agente sin marcar, o destino fork**: el árbol de markdown de hoy.
- **Agente de datos sensibles con repositorio asociado**: los mismos archivos que entrega `vault_list_markdown`, dentro de `store/`. El árbol no contiene ningún `.md` en claro.
- **Cambio de marca**: al pasar un agente a sensible, el commit siguiente elimina los `.md` en claro del árbol. Los commits anteriores siguen en la historia de la rama; el despliegue lo advierte, y el recorte de D35 los quita.
- **Cadencia**: la de hoy, cada hora por defecto.

- **Agente de datos sensibles con fork y sin repositorio**: `backup-vault` no empuja nada y lo dice, con código 0. El vault de un agente sensible no viaja en claro a ningún destino. En modo local la marca no se honra, y regenerar lo advierte (A2 de [agent-surface.md](agent-surface.md)).

La librería del vault es compartida con el modo local (`scripts/lib/backup_vault.sh`). El camino cifrado solo se activa desde `heartbeatctl`, que no existe en modo local.

## U5. `memory` (nueva)

- **Librería**: `docker/scripts/lib/backup_memory.sh`. **Comando**: `heartbeatctl backup-memory [--dry-run]`.
- **Fuentes**: la auto-memoria de cada proyecto, el directorio de claude-mem y las rutas de `backup.extra_paths`, con las exclusiones de la sección 5 de [data-model.md](../data-model.md).
- **Rutas adicionales**: cada entrada se normaliza y se valida con la regla de `backup.extra_paths` y, además, se resuelve: una que salga del workspace se omite. Dentro de un directorio aceptado no se recorren los subdirectorios `.git`. Una entrada que no cumple, o que no existe, se omite con una línea que la nombra, y la unidad sigue. Los enlaces simbólicos no se siguen.
- **Captura de las bases**: `backup_store.py` reconoce cada base SQLite por su cabecera y empaqueta una copia consistente, que deja en el directorio de trabajo de la unidad (`--snapshot-dir`). La copia es determinista: una base sin cambios no produce un respaldo nuevo (M18 de [research.md](../research.md)).
- **Cifrado**: claude-mem y las rutas adicionales siempre van en `store/`. La auto-memoria va en claro en un agente sin marcar y en `store/` en uno sensible.
- **Hash**: cubre todos sus archivos, los que van en claro y los que van al almacén. Un cambio que solo toca la auto-memoria produce un respaldo nuevo.
- **Cadencia**: `features.memory_backup.schedule`, `40 3 * * *` por defecto.
- **Sin fuentes**: sin auto-memoria, sin directorio de claude-mem y sin rutas adicionales, termina en `nothing-to-back-up`.

## U6. `history` (nueva)

- **Librería**: `docker/scripts/lib/backup_history.sh`. **Comando**: `heartbeatctl backup-history [--dry-run]`.
- **Fuentes**: `/home/agent/.claude/projects/**`, salvo los directorios `memory/`. El directorio de configuración aislado del heartbeat no entra.
- **Captura**: los `.jsonl` se leen hasta su último salto de línea (sección 6 de [data-model.md](../data-model.md)).
- **Cifrado**: siempre, en `store/`.
- **Cadencia**: `features.history_backup.schedule`, `50 3 * * *` por defecto.
- **Sin fuentes**: si el directorio de proyectos no existe o no tiene ningún archivo, termina en `nothing-to-back-up`.
- **Lo que refleja**: el estado actual. Lo que Claude Code borra por su retención de 30 días sale también de la cabeza de la rama.

## U7. Cron

`heartbeatctl reload` agrega una línea por cada unidad nueva solo cuando se cumplen las tres condiciones:

1. el destino resuelto es `repo`;
2. la unidad está habilitada;
3. su `schedule` es un cron válido de cinco campos. A diferencia del aviso semanal de 037, aquí se admite `*` y `*/N` también en el minuto.

```text
<schedule> /usr/local/bin/heartbeatctl backup-memory >> /workspace/scripts/heartbeat/logs/backup-memory.log 2>&1
<schedule> /usr/local/bin/heartbeatctl backup-history >> /workspace/scripts/heartbeat/logs/backup-history.log 2>&1
```

- Las dos líneas se concatenan al último renglón del crontab generado, como el aviso semanal de 037: un crontab sin ellas no gana ni una línea en blanco.
- Con un repositorio asociado, la línea diaria de `identity` existe salvo que `features.identity_backup.enabled` sea `false` de forma explícita (D20 de [research.md](../research.md)). Con `fork` o `none` existe solo si vale `true`, como hoy.
- Con `fork` o `none`, el crontab generado es idéntico byte a byte al de `main`.
- Un `schedule` inválido omite esa línea y deja una advertencia en el log del arranque que nombra la clave y no el valor, igual que el aviso semanal de 037.
- Un cambio en caliente de otra clave (por ejemplo `heartbeatctl set-interval`) conserva `backup.repo.url` y estas líneas.

## U8. Directorios de trabajo y mantención

- Las cachés de clon siguen bajo `/home/agent/.cache/`, una por unidad, dentro de `.state/`. La del camino `repo` es distinta de la del camino `fork`.
- La copia de una base, el archivo de cabezas, el archivo con la llave pública del operador y cualquier temporal van dentro de la caché de la unidad, fuera de su árbol. Nunca en `/tmp`, que es un tmpfs de 100 MB (M6 de [research.md](../research.md)).
- `--gc`, en las tres unidades que ya lo tienen: con un repositorio asociado corre `git gc` sobre la caché del camino `repo`, si existe, **bajo el candado de la unidad** (un disparo del supervisor podría estar haciendo un commit ahí), y después la unidad. Con el candado tomado no corre el `gc`, y la corrida que sigue lo informa. Con fork, hace lo de hoy.
- **Recorte de una rama** (D35): el operador borra la rama remota de la unidad. El ciclo siguiente la recrea con un solo commit, y su caché se crea de nuevo.

## U9. Invariantes

- **I1**: lo que la sección D7 de [research.md](../research.md) manda cifrar nunca se escribe en claro en el árbol de un commit, ni siquiera de forma transitoria dentro del directorio que se va a commitear.
- **I2**: sin llave pública, ninguna unidad sube en claro lo que debía ir cifrado.
- **I3**: un segundo ciclo sin cambios no crea commits (SC-001).
- **I4**: ninguna unidad lee, escribe ni borra una rama que no sea la suya. Ningún empuje usa `--all`, `--mirror` ni una referencia que no sea `refs/heads/backup/<unidad>`.
- **I5**: una unidad que falla no impide que las demás corran.
- **I6**: después de un respaldo correcto de `identity`, el supervisor calcula el mismo hash que quedó en el estado y no vuelve a disparar la unidad.
- **I7**: una ruta adicional nunca hace que una unidad lea fuera del workspace.
- **I8**: el archivo de secretos de la raíz del workspace nunca se copia en claro al árbol de un commit ni a la caché de una unidad.
- **I9**: dos corridas simultáneas de una misma unidad nunca trabajan sobre la misma caché.
- **I10**: después de un intento fallido de `identity`, el supervisor no vuelve a dispararla por el mismo contenido antes de 900 segundos.
- **I11**: el `~/.gitconfig` del agente no cambia el resultado de ningún respaldo con un repositorio asociado.
- **I12**: una unidad cuyo empuje se cuelga termina en su tope (C6) con `push-failed`, y deja su registro.
- **I13**: el vault de un agente sensible no se empuja en claro a un fork.
- **I14**: después de un cambio de la llave del operador, el ciclo siguiente de cada unidad con almacén rota su llave de datos.
